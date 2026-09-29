#!/bin/sh
# check-update.sh <package>
# Check a GitHub release feed for a newer build of a daede package than the
# one installed locally. Prints "latest<TAB>asset_url" (asset_url empty when
# the local build is already newest or nothing was found).
#
# Why a separate script instead of pkg-info.sh: pkg-info.sh compares against
# the device's apk/opkg feed (the R2 mirror). That feed only ever carries
# upstream builds. This project publishes its own packages as GitHub release
# assets instead, so this script checks the fixed zjfjm/openwrt-daede feed.

PKG="$1"
case "$PKG" in
	dae|daed|luci-app-daede|usque) ;;
	*) printf '\t\n'; exit 64 ;;
esac

# Throttle: one real API check per package every 30 minutes, server-side so
# it holds across page reloads, tabs and devices. The Updates page gets
# opened constantly while the unauthenticated GitHub API allows only
# 60 requests/hour — opening the page therefore runs a check at most once
# per 30 minutes, and any reopen inside that window just replays the cached
# result from /tmp. The second argument "--force" (the Check Updates
# button) bypasses the window; "--real" is this script's own re-entry
# marker for the uncached run, whose stdout is captured and cached.
STAMP="/tmp/luci-app-daede.chk.${PKG}.ts"
COUT="/tmp/luci-app-daede.chk.${PKG}.out"
CCODE="/tmp/luci-app-daede.chk.${PKG}.code"
if [ "$2" != "--force" ] && [ "$2" != "--real" ] && [ -f "$STAMP" ] && [ -s "$COUT" ]; then
	stamp="$(cat "$STAMP" 2>/dev/null)"
	case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
	age=$(( $(date +%s) - stamp ))
	if [ "$age" -ge 0 ] && [ "$age" -lt 1800 ]; then
		cat "$COUT"
		code="$(cat "$CCODE" 2>/dev/null)"
		case "$code" in ''|*[!0-9]*) code=0 ;; esac
		exit "$code"
	fi
fi
if [ "$2" != "--real" ]; then
	out="$(sh "$0" "$PKG" --real)"
	rc=$?
	printf '%s\n' "$out"
	printf '%s' "$out" > "$COUT"
	printf '%s' "$rc" > "$CCODE"
	date +%s > "$STAMP"
	exit "$rc"
fi

# GitHub repo hosting release assets for this build. Fixed to this project's
# own repository — this is a self-built fork, the Updates page does not offer
# switching the release feed.
UPDATE_REPO="zjfjm/openwrt-daede"

# Optional prefix for github.com (e.g. https://ghfast.top/) when the device
# cannot reach GitHub directly. Applied to api.github.com too, but only as a
# fallback: mirrors that rewrite the path answer /https://api.github.com/...
# with 404, so prefixing the API unconditionally made every release check fail.
GH_PROXY="$(uci -q get daede.config.github_proxy)"
[ -n "$GH_PROXY" ] || GH_PROXY="https://ghfast.top/"

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

# Installed version — read straight from opkg's status file, exactly like
# pkg-info.sh. `opkg status` takes /var/lock/opkg.lock even read-only, and
# refresh-index.sh's background `opkg update` holds it for ~18s on load; an
# empty installed version would then wrongly render an identical release as
# an upgrade (or nothing at all). The file itself is always readable.
installed=""
if command -v apk >/dev/null 2>&1; then
	installed=$(apk list -I "$PKG" 2>/dev/null | awk -v p="$PKG" '
		$1 ~ "^" p "-" { sub("^" p "-", "", $1); print $1; exit }
	')
elif command -v opkg >/dev/null 2>&1; then
	installed=$(awk -v p="$PKG" '
		$1=="Package:" { f = ($2 == p) }
		f && $1=="Version:" { print $2; exit }
	' /usr/lib/opkg/status 2>/dev/null)
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
#
# Direct first, then the configured mirror: mirrors prefix the path
# ("proxy/https://api.github.com/...") and the default one answers that with
# 404, so going through it unconditionally always looked like "check failed".
api_url="https://api.github.com/repos/${UPDATE_REPO}/releases/latest"

# Conditional request against a /tmp copy of the previous response. A 304
# from GitHub does NOT count against the unauthenticated rate limit
# (60 requests/hour), so the Updates page can keep polling without burning
# the budget — previously an open tab exhausted it in ~20 minutes and every
# row flipped to "release check failed" for the rest of the hour. A 200
# stores the body plus a fresh ETag for the next round; the cache key
# follows the configured repo so switching repos never serves stale data.
API_TAG="$(printf '%s' "$UPDATE_REPO" | tr -c 'A-Za-z0-9._-' '_')"
API_CACHE="/tmp/luci-app-daede.api.${API_TAG}"
api=""
if command -v curl >/dev/null 2>&1; then
	etag=""
	[ -f "$API_CACHE.etag" ] && etag="$(cat "$API_CACHE.etag" 2>/dev/null)"
	hdr="/tmp/luci-app-daede.hdr.$$"
	if [ -n "$etag" ]; then
		code="$(curl -sS --max-time 20 -D "$hdr" -o "$API_CACHE.tmp" -H "If-None-Match: $etag" -w '%{http_code}' "$api_url" 2>/dev/null)"
	else
		code="$(curl -sS --max-time 20 -D "$hdr" -o "$API_CACHE.tmp" -w '%{http_code}' "$api_url" 2>/dev/null)"
	fi
	case "$code" in
		200)
			if api="$(cat "$API_CACHE.tmp" 2>/dev/null)" && [ -n "$api" ] && printf '%s' "$api" > "$API_CACHE.body"; then
				new_etag="$(grep -i '^etag:' "$hdr" 2>/dev/null | sed 's/^[Ee][Tt][Aa][Gg]: *//' | tr -d '\r')"
				[ -n "$new_etag" ] && printf '%s' "$new_etag" > "$API_CACHE.etag"
			fi
			;;
		304) # Not modified: reuse the cached body (request was free).
			api="$(cat "$API_CACHE.body" 2>/dev/null)"
			;;
		*)   # Error payload (rate limit JSON etc) — classified below.
			api="$(cat "$API_CACHE.tmp" 2>/dev/null)"
			;;
	esac
	rm -f "$hdr" "$API_CACHE.tmp"
else
	api="$(fetch_text "$api_url")"
fi

case "$api" in
	*browser_download_url*) ;;
	*) # Direct API unusable (blocked/rate-limited/error payload): retry via mirror.
	   proxied="$(fetch_text "$(with_proxy "$api_url")")"
	   case "$proxied" in
		   *browser_download_url*) api="$proxied" ;;
	   esac
	   ;;
esac

# Classify the failure: rate limiting is not a proxy problem, so it gets
# its own exit code (2) and UI message instead of "set the GitHub Proxy
# and retry" — a proxy cannot lift an IP-level limit here.
case "$api" in
	*browser_download_url*) ;;
	*rate\ limit*|*rate-limit*)
		printf '\t\n'
		exit 2
		;;
	*)
		printf '\t\n'
		exit 1
		;;
esac

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
