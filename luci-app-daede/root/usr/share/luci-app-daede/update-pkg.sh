#!/bin/sh
# update-pkg.sh <dae|daed|luci-app-daede|usque>
# Refresh package indexes and upgrade the named package via apk (25.12+) or
# opkg (24.10); opkg installs it when missing. Forks the work to background
# so the LuCI RPC call returns immediately; the result is streamed to
# /tmp/luci-app-daede.pkg.<name>.log.

PKG="$1"
case "$PKG" in
	dae|daed|luci-app-daede|usque) ;;
	*)
		echo "usage: $0 <dae|daed|luci-app-daede|usque>" >&2
		exit 64
		;;
esac

# run from a /tmp copy so upgrading luci-app-daede (which replaces this script)
# can't corrupt the in-flight upgrade
case "$0" in
	/tmp/.daede-upd-*) ;;
	*)
		_self="/tmp/.daede-upd-$$"
		cp "$0" "$_self" 2>/dev/null && exec sh "$_self" "$@"
		;;
esac

LOCK="/tmp/luci-app-daede.pkg-${PKG}.lock"
LOG="/tmp/luci-app-daede.pkg-${PKG}.log"

if [ -f "$LOCK" ]; then
	mtime=$(date -r "$LOCK" +%s 2>/dev/null || echo 0)
	age=$(( $(date +%s) - mtime ))
	if [ "$age" -lt 300 ]; then
		echo "${PKG} update already in progress (PID $(cat "$LOCK" 2>/dev/null), age ${age}s)" >&2
		exit 75
	fi
	rm -f "$LOCK"
fi

if ! ( set -C; echo "$$" >"$LOCK" ) 2>/dev/null; then
	echo "${PKG} update already in progress" >&2
	exit 75
fi

(
	exec >"$LOG" 2>&1
	trap 'rm -f "$LOCK"; [ "${0#/tmp/.daede-upd-}" != "$0" ] && rm -f "$0"' EXIT INT TERM

	echo "$(date '+%F %T') begin upgrade: $PKG"

	if command -v apk >/dev/null 2>&1; then
		# shared apk lock with the bg index refresh (avoid "Unable to lock database")
		(
			flock 9
			apk update 2>&1
			ver=$(apk list "$PKG" 2>/dev/null | awk -v p="$PKG" '$1 ~ "^" p "-[0-9]" { v=$1; sub("^" p "-", "", v); print v }' | sort -V | tail -1)
			if [ -n "$ver" ]; then
				constraint="$PKG=$ver"
			else
				echo "result: 软件源中没有找到 $PKG，请检查网络或软件源配置"
				exit 1
			fi

			echo "--- apk add -s $constraint ---"
			if ! apk add -s "$constraint" 2>&1; then
				echo "note: apk 预检失败，通常是系统上其它软件包的问题，继续尝试升级"
			fi
			echo "--- apk add $constraint ---"
			apk add "$constraint" 2>&1
			exit 0
		) 9>/tmp/luci-app-daede.apk.lock
		rc=$?
		if [ "$rc" != 0 ]; then
			:
		elif ! apk list --installed 2>/dev/null | grep -q "^${PKG}-"; then
			echo "result: $PKG is not installed"
			rc=1
		elif apk list -u 2>/dev/null | grep -q "^${PKG}-"; then
			echo "result: $PKG still has a pending upgrade"
			rc=1
		else
			echo "result: $PKG is at the latest available version"
			rc=0
		fi
	elif command -v opkg >/dev/null 2>&1; then
		echo "--- opkg update ---"
		opkg update 2>&1
		# opkg upgrade fails on a package that was never installed (usque) —
		# install it instead so the MASQUE page's Install button works
		if opkg status "$PKG" 2>/dev/null | grep -q '^Package:'; then
			echo "--- opkg upgrade $PKG ---"
			opkg upgrade "$PKG" 2>&1
		else
			echo "--- opkg install $PKG ---"
			opkg install "$PKG" 2>&1
		fi
		rc=$?
	else
		echo "no package manager found"
		exit 3
	fi

	# Feed install failed — forks publish packages like usque as GitHub
	# release assets only (no configured feed carries them), so fall back to
	# the same asset path the Updates view uses: probe check-update.sh for
	# the newest matching asset, download it, install from the local file.
	if [ "$rc" != 0 ]; then
		echo "--- feed install failed, falling back to GitHub release asset ---"
		asset_url=$(sh /usr/share/luci-app-daede/check-update.sh "$PKG" 2>/dev/null | cut -f2)
		if [ -n "$asset_url" ]; then
			GH_PROXY="$(uci -q get daede.config.github_proxy)"
			[ -n "$GH_PROXY" ] || GH_PROXY="https://gh.845945.xyz/"
			dl_url="$asset_url"
			case "$dl_url" in
				https://github.com/*)
					[ -n "$GH_PROXY" ] && dl_url="${GH_PROXY}${dl_url}"
					;;
			esac
			if command -v apk >/dev/null 2>&1; then
				ext="apk"
			else
				ext="ipk"
			fi
			tmp_dir="/tmp/daede-pkg.$$"
			rm -rf "$tmp_dir"
			mkdir -p "$tmp_dir"
			file="$tmp_dir/${PKG}.${ext}"
			echo "downloading $dl_url ..."
			if command -v curl >/dev/null 2>&1; then
				curl -fL --max-time 300 "$dl_url" -o "$file" 2>&1
			elif command -v uclient-fetch >/dev/null 2>&1; then
				uclient-fetch -O "$file" --timeout=300 "$dl_url" 2>&1
			else
				wget -qO "$file" --timeout=300 "$dl_url" 2>&1
			fi
			rc=$?
			if [ "$rc" = 0 ] && [ -s "$file" ]; then
				if command -v apk >/dev/null 2>&1; then
					echo "--- apk add --allow-untrusted $file ---"
					apk add --allow-untrusted "$file" 2>&1
					rc=$?
				else
					echo "--- opkg install $file ---"
					opkg install "$file" 2>&1
					rc=$?
				fi
			else
				[ "$rc" = 0 ] && rc=1
				echo "result: release asset download failed"
			fi
			rm -rf "$tmp_dir"
		else
			echo "result: no release asset found for $PKG"
			rc=1
		fi
	fi

	if [ "$rc" = 0 ]; then echo "$(date '+%F %T') ✓ 完成"; else echo "$(date '+%F %T') ✗ 失败 (rc=$rc)"; fi

	# luci-app-daede upgrade replaces ACL JSON — reload rpcd so changes apply.
	if [ "$PKG" = "luci-app-daede" ] && [ "$rc" = "0" ]; then
		echo "reloading rpcd to pick up new ACL"
		/etc/init.d/rpcd reload 2>&1
	fi
) </dev/null >/dev/null 2>&1 &

echo "started in background, see $LOG"
exit 0
