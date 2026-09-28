#!/bin/sh
# pkg-info.sh <package>
# Prints "<installed>\t<latest>" for the named package, where either field is
# empty when unknown. Used by the Updates view to decide whether to enable
# the [Upgrade] button.

PKG="$1"
case "$PKG" in
	dae|daed|luci-app-daede) ;;
	*) echo "" ; exit 64 ;;
esac

installed=""
latest=""

# Emit the decompressed contents of a feed list (all lists under
# /var/opkg-lists are gzipped; .sig files are skipped by the caller). Falls
# back to plain cat in case a file ever ships uncompressed.
decompress() {
	gzip -dc "$1" 2>/dev/null || cat "$1" 2>/dev/null
}

if command -v apk >/dev/null 2>&1; then
	if apk info -e "$PKG" >/dev/null 2>&1; then
		installed=$(apk list -I "$PKG" 2>/dev/null | awk -v p="$PKG" '
			$1 ~ "^" p "-" {
				sub("^" p "-", "", $1);
				print $1;
				exit
			}
		')
	fi
	# apk search treats ^ and $ as literal chars (not regex anchors), so the old
	# `apk search "^pkg$"` matched nothing. Enumerate the exact-name package
	# across all feeds via `apk list` and take the highest version. Restricting
	# to "<pkg>-<digit>" avoids sibling names like <pkg>-geoip / luci-app-<pkg>.
	latest=$(apk list "$PKG" 2>/dev/null | awk -v p="$PKG" '
		$1 ~ "^" p "-[0-9]" {
			v = $1; sub("^" p "-", "", v);
			print v
		}
	' | sort -V | tail -1)
elif command -v opkg >/dev/null 2>&1; then
	# Read opkg's databases as plain files instead of shelling out to opkg.
	# opkg takes /var/lock/opkg.lock even for read-only queries, and the
	# Updates view kicks off refresh-index.sh's `opkg update` on load — so
	# every probe either printed nothing ("installed: unknown") or stalled
	# for the length of the update. /usr/lib/opkg/status and the feed lists
	# are always readable, even mid-update, and take milliseconds.
	installed=$(awk -v p="$PKG" '
		$1=="Package:" { f = ($2 == p) }
		f && $1=="Version:" { print $2; exit }
	' /usr/lib/opkg/status 2>/dev/null)
	# Same answer `opkg info` gave: first Version stanza found, feeds first.
	for f in /var/opkg-lists/*; do
		case "$f" in *.sig) continue ;; esac
		[ -f "$f" ] || continue
		latest=$(decompress "$f" | awk -v p="$PKG" '
			$1=="Package:" { f = ($2 == p) }
			f && $1=="Version:" { print $2; exit }
		')
		[ -n "$latest" ] && break
	done
	# Not carried by any feed (luci-app-daede ships only in this repo's
	# releases): `opkg info` then reports just the installed stanza, so
	# latest == installed — mirror that instead of printing "unknown".
	[ -n "$latest" ] || latest="$installed"
fi

case "$PKG" in
	dae|daed)
		case "$installed" in
			20[0-9][0-9].[0-9]*) ;;
			*) installed="" ;;
		esac
		;;
esac

printf '%s\t%s\n' "$installed" "$latest"
