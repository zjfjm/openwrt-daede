#!/bin/sh
# check-update.sh <package>
# Check a GitHub release feed for a newer build of a daede package than the
# one installed locally. Prints "latest<TAB>asset_url" (asset_url empty when
# the local build is already newest or nothing was found).
#
# Why a separate script instead of pkg-info.sh: pkg-info.sh compares against
# the device's apk/opkg feed (the R2 mirror). That feed only ever carries
# kenzok8's builds. A fork that pushes its own tags publishes packages as
# release assets on GitHub instead, so we need a second lookup path that can
# be pointed at an arbitrary repo via uci daede.config.update_repo.

PKG="$1"
case "$PKG" in
	dae|daed|luci-app-daede) ;;
	*) printf '\t\n'; exit 64 ;;
esac

# GitHub repo hosting release assets for this build. Defaults to upstream so
# the button works out of the box; set daede.config.update_repo to your own
# fork ("user/repo") to pull your builds instead.
UPDATE_REPO="$(uci -q get daede.config.update_repo)"
[ -n "$UPDATE_REPO" ] || UPDATE_REPO="kenzok8/openwrt-daede"

# Optional prefix for github.com (e.g. https://ghfast.top/) when the device
# cannot reach GitHub directly. Applied to api.github.com too.
GH_PROXY="$(uci -q get daede.config.github_proxy)"

fetch_text() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --max-time 20 "$1" 2>/dev/null
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -qO- --timeout=20 "$1" 2>/dev/null
	else
		wget -qO- --timeout=20 "$1" 2>/dev/null
	fi
}

with_proxy() {
	case "$1" in
		https://github.com/*|https://api.github.com/*)
			[ -n "$GH_PROXY" ] && printf '%s%s\n' "$GH_PROXY" "$1" || printf '%s\n' "$1"
			;;
		*)
			printf '%s\n' "$1"
			;;
	esac
}

# Installed version, same extraction as pkg-info.sh.
installed=""
if command -v apk >/dev/null 2>&1; then
	installed=$(apk list -I "$PKG" 2>/dev/null | awk -v p="$PKG" '
		$1 ~ "^" p "-" { sub("^" p "-", "", $1); print $1; exit }
	')
elif command -v opkg >/dev/null 2>&1; then
	installed=$(opkg status "$PKG" 2>/dev/null | awk -F': ' '$1=="Version"{print $2; exit}')
fi

# dae/daed release versions are date-stamped; keep the same sanity filter as
# pkg-info.sh so a bogus installed string never looks like an upgrade target.
case "$PKG" in
	dae|daed)
		case "$installed" in
			20[0-9][0-9].[0-9]*) ;;
			*) installed="" ;;
		esac
		;;
esac

# Ask the GitHub API for the latest release. Use the Releases API (not the
# Tags API) because we need the asset list to download packages from.
api="$(fetch_text "$(with_proxy "https://api.github.com/repos/${UPDATE_REPO}/releases/latest")")"
[ -n "$api" ] || { printf '\t\n'; exit 0; }

tag="$(printf '%s' "$api" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$tag" ] || { printf '\t\n'; exit 0; }

# Strip the leading "v" from the tag (v2026.9.23 -> 2026.9.23) so it compares
# against the installed version, which has no "v" prefix.
rel_ver="${tag#v}"

# Nothing to do when the release is not newer than what we run.
if [ -n "$installed" ] && [ "$rel_ver" = "$installed" ]; then
	printf '\t\n'; exit 0
fi

# Find the matching asset. luci-app-daede is arch-independent ("_all" ipk /
# no arch suffix in apk); dae/daed need the device's target arch.
arch=""
if command -v apk >/dev/null 2>&1; then
	arch="$(sed -n "s/^DISTRIB_ARCH=['\"]\([^'\"]*\)['\"].*/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1)"
	[ -n "$arch" ] || arch="$(apk --print-arch 2>/dev/null)"
else
	arch="$(opkg print-architecture 2>/dev/null | awk '/^arch /{print $2}' | tail -n 1)"
fi

# Extract every asset download URL, then pick the right one for this package
# and package manager. Release asset naming (see .github/workflows/release.yml):
#   apk: dae-2026.9.23-1-aarch64_cortex-a53.apk, luci-app-daede-2026.9.23-1.apk
#   ipk: dae_2026.9.23-1_aarch64_cortex-a53.ipk, luci-app-daede_2026.9.23-1_all.ipk
asset=""
asset_urls="$(printf '%s' "$api" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: *"//;s/"$//')"

if command -v apk >/dev/null 2>&1; then
	if [ "$PKG" = "luci-app-daede" ]; then
		asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}-[^/]*\.apk$" | head -n 1)"
	else
		asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}-[^/]*-${arch}\.apk$" | head -n 1)"
		# Fall back to the generic aarch64 build for subtargets without their own.
		[ -n "$asset" ] || asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}-[^/]*-aarch64_generic\.apk$" | head -n 1)"
	fi
else
	if [ "$PKG" = "luci-app-daede" ]; then
		asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}_[^/]*_all\.ipk$" | head -n 1)"
	else
		asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}_[^/]*_${arch}\.ipk$" | head -n 1)"
		[ -n "$asset" ] || asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}_[^/]*_aarch64_generic\.ipk$" | head -n 1)"
	fi
fi

# Report the release version plus the asset URL so the caller can both render
# "installed → latest" and know which file to install.
printf '%s\t%s\n' "$rel_ver" "$asset"
