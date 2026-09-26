#!/bin/sh
# check-update.sh <package>
# Check a GitHub release feed for a newer build of a daede package than the
# one installed locally. Prints "latest<TAB>asset_url" (asset_url empty when
# the local build is already newest or nothing was found).
#
# Why a separate script instead of pkg-info.sh: pkg-info.sh compares against
# the device's apk/opkg feed (the R2 mirror). That feed only ever carries
# upstream builds. A fork that pushes its own tags publishes packages as
# release assets on GitHub instead, so we need a second lookup path that can
# be pointed at an arbitrary repo via uci daede.config.update_repo.

PKG="$1"
case "$PKG" in
	dae|daed|luci-app-daede|usque) ;;
	*) printf '\t\n'; exit 64 ;;
esac

# GitHub repo hosting release assets for this build. Defaults to this fork so
# the button pulls our own builds; set daede.config.update_repo to point it at
# another fork ("user/repo") if needed.
UPDATE_REPO="$(uci -q get daede.config.update_repo)"
[ -n "$UPDATE_REPO" ] || UPDATE_REPO="zjfjm/openwrt-daede"

# Optional prefix for github.com (e.g. https://ghfast.top/) when the device
# cannot reach GitHub directly. Applied to api.github.com too.
GH_PROXY="$(uci -q get daede.config.github_proxy)"
# This fork's own proxy when nothing is configured yet — the GitHub API is
# unreachable from many networks, and an empty probe must not look like
# "already up to date". Set daede.config.github_proxy to override.
[ -n "$GH_PROXY" ] || GH_PROXY="https://gh.845945.xyz/"

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
# A fetch that yields nothing (network/API failure) exits 1 so the caller can
# say "check failed" instead of silently claiming the build is up to date.
api="$(fetch_text "$(with_proxy "https://api.github.com/repos/${UPDATE_REPO}/releases/latest")")"
[ -n "$api" ] || { printf '\t\n'; exit 1; }

# Find the matching asset. luci-app-daede is arch-independent ("_all" ipk;
# its noarch apk is still published once per SDK/arch); dae/daed need the
# device's target arch.
arch=""
if command -v apk >/dev/null 2>&1; then
	arch="$(sed -n "s/^DISTRIB_ARCH=['\"]\([^'\"]*\)['\"].*/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1)"
	[ -n "$arch" ] || arch="$(apk --print-arch 2>/dev/null)"
else
	arch="$(opkg print-architecture 2>/dev/null | awk '/^arch /{print $2}' | tail -n 1)"
fi

# Extract every asset download URL, then pick the right one for this package
# and package manager. Release asset naming (see .github/workflows/release.yml):
#   apk: dae-2026.09.23-r1-aarch64_cortex-a53.apk
#        luci-app-daede-1.16-r1-aarch64_cortex-a53.apk
#   ipk: dae_2026.09.23-r1_aarch64_cortex-a53.ipk
#        luci-app-daede_1.16-r1_all.ipk
asset_urls="$(printf '%s' "$api" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: *"//;s/"$//')"

# No assets at all means the response was an error payload (rate limit, proxy
# error page) rather than a release we can compare against — report failure,
# never "up to date".
if [ -z "$asset_urls" ]; then
	printf '\t\n'
	exit 1
fi

# The arch suffix of whichever asset we accept (the device's own arch, or the
# aarch64_generic fallback). Remembered so the version can be parsed back out
# of the filename below.
match_arch=""

if command -v apk >/dev/null 2>&1; then
	asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}-[^/]*-${arch}\.apk$" | head -n 1)"
	if [ -n "$asset" ]; then
		match_arch="$arch"
	else
		# Fall back to the generic aarch64 build for subtargets without their own.
		asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}-[^/]*-aarch64_generic\.apk$" | head -n 1)"
		match_arch="aarch64_generic"
	fi
else
	if [ "$PKG" = "luci-app-daede" ]; then
		asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}_[^/]*_all\.ipk$" | head -n 1)"
		match_arch="all"
	else
		asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}_[^/]*_${arch}\.ipk$" | head -n 1)"
		if [ -n "$asset" ]; then
			match_arch="$arch"
		else
			asset="$(printf '%s\n' "$asset_urls" | grep -E "/${PKG}_[^/]*_aarch64_generic\.ipk$" | head -n 1)"
			match_arch="aarch64_generic"
		fi
	fi
fi

# No matching asset for this device: nothing to offer.
[ -n "$asset" ] || { printf '\t\n'; exit 0; }

# Parse the version out of the asset filename rather than trusting the release
# tag. The tag is a date stamp shared by every package in the release, while
# the filename carries this package's own PKG_VERSION-PKG_RELEASE (e.g.
# luci-app-daede 1.16-r1). apk/opkg report that same PKG_VERSION after install,
# so this is the only form that compares correctly against the local build.
base="${asset##*/}"
rel_ver="${base#${PKG}[-_]}"
rel_ver="${rel_ver%[-_]${match_arch}.*}"

# Nothing to do when the release is not newer than what we run.
if [ -n "$installed" ] && [ "$rel_ver" = "$installed" ]; then
	printf '\t\n'; exit 0
fi

# Report the release version plus the asset URL so the caller can both render
# "installed → latest" and know which file to install.
printf '%s\t%s\n' "$rel_ver" "$asset"
