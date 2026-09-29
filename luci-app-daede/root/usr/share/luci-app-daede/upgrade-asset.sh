#!/bin/sh
# upgrade-asset.sh <package> <asset_url>
# Install a package from a GitHub release asset URL. Used for forks that
# publish builds as release assets instead of an apk/opkg feed: the Updates
# view calls check-update.sh first, then this to actually install.
#
# Forks to the background like update-pkg.sh; the log is streamed to
# /tmp/luci-app-daede.asset-<pkg>.log and ends with ✓/✗.

PKG="$1"
URL="$2"

case "$PKG" in
	dae|daed|luci-app-daede|usque) ;;
	*)
		echo "usage: $0 <dae|daed|luci-app-daede|usque> <asset_url>" >&2
		exit 64
		;;
esac

[ -n "$URL" ] || { echo "no asset URL provided" >&2; exit 64; }

# Optional proxy prefix for github.com (e.g. https://ghfast.top/).
GH_PROXY="$(uci -q get daede.config.github_proxy)"
[ -n "$GH_PROXY" ] || GH_PROXY="https://ghfast.top/"

LOCK="/tmp/luci-app-daede.asset-${PKG}.lock"
LOG="/tmp/luci-app-daede.asset-${PKG}.log"

if [ -f "$LOCK" ]; then
	mtime=$(date -r "$LOCK" +%s 2>/dev/null || echo 0)
	age=$(( $(date +%s) - mtime ))
	if [ "$age" -lt 300 ]; then
		echo "${PKG} asset install already in progress (age ${age}s)" >&2
		exit 75
	fi
	rm -f "$LOCK"
fi

if ! ( set -C; echo "$$" >"$LOCK" ) 2>/dev/null; then
	echo "${PKG} asset install already in progress" >&2
	exit 75
fi

(
	exec >"$LOG" 2>&1
	trap 'rm -f "$LOCK"' EXIT INT TERM

	echo "$(date '+%F %T') begin asset install: $PKG"
	echo "asset: $URL"

	# Candidate sources, tried in order: the configured proxy first (dead
	# proxies fail fast thanks to --connect-timeout), then direct, then the
	# default mirror. Never depend on a single prefix — a dead configured
	# proxy used to hang for minutes and fail the whole install.
	try_list="$URL"
	case "$URL" in
		https://github.com/*)
			try_list=""
			[ -n "$GH_PROXY" ] && try_list="${GH_PROXY}${URL}"
			try_list="${try_list} ${URL}"
			case "$GH_PROXY" in
				https://ghfast.top/) ;;
				*) try_list="${try_list} https://ghfast.top/${URL}" ;;
			esac
			;;
	esac

	tmp_dir="/tmp/daede-asset.$$"
	mkdir -p "$tmp_dir"

	if command -v apk >/dev/null 2>&1; then
		ext="apk"
	else
		ext="ipk"
	fi
	file="$tmp_dir/${PKG}.${ext}"

	rc=1
	set -f
	for u in $try_list; do
		echo "downloading ${u} ..."
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL --connect-timeout 15 --max-time 180 "$u" -o "$file" 2>&1
			rc=$?
		elif command -v uclient-fetch >/dev/null 2>&1; then
			uclient-fetch -q -O "$file" --timeout=60 "$u" 2>&1
			rc=$?
		else
			wget -qO "$file" --timeout=60 "$u" 2>&1
			rc=$?
		fi
		if [ "$rc" = 0 ] && [ -s "$file" ]; then
			echo "downloaded from ${u}"
			break
		fi
		echo "source failed (rc=$rc), trying next"
		rm -f "$file"
	done
	set +f

	if [ "$rc" != 0 ] || [ ! -s "$file" ]; then
		echo "result: download failed (rc=$rc)"
		echo "$(date '+%F %T') ✗ 失败"
		exit 1
	fi

	echo "downloaded $(wc -c < "$file" 2>/dev/null || echo ?) bytes"

	if command -v apk >/dev/null 2>&1; then
		echo "--- apk add --allow-untrusted $file ---"
		apk add --allow-untrusted "$file" 2>&1
		rc=$?
	elif command -v opkg >/dev/null 2>&1; then
		echo "--- opkg install $file ---"
		opkg install "$file" 2>&1
		rc=$?
	else
		echo "no package manager found"
		echo "$(date '+%F %T') ✗ 失败"
		exit 3
	fi

	if [ "$rc" = 0 ]; then
		echo "result: ${PKG} installed from release asset"
		echo "$(date '+%F %T') ✓ 完成"
	else
		echo "result: install failed (rc=$rc)"
		echo "$(date '+%F %T') ✗ 失败 (rc=$rc)"
	fi

	rm -rf "$tmp_dir"
) </dev/null >/dev/null 2>&1 &

echo "started in background, see $LOG"
exit 0
