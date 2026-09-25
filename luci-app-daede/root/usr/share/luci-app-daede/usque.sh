#!/bin/sh
# usque.sh - manage the WARP MASQUE tunnel (usque SOCKS5 proxy) from LuCI.
#
#   save                validate staged /tmp/daede-usque-save.json -> /etc/usque/config.json
#   register            run `usque register` in the background (result in the register log)
#   clear               remove the config and stop the service
#   status              print key=value service state
#   probe               tunnel check: ok=<0|1> http=<code> warp=<on|off|?> ms=<n> tool=<0|1>
#   watchdog            cron entry: restart a dead or hung tunnel
#   watchdog-cron A     enable|disable the watchdog crontab entry

CFG="/etc/usque/config.json"
STAGE="/tmp/daede-usque-save.json"
FAILS="/tmp/usque-watchdog.fails"
REG_LOG="/tmp/luci-app-daede.usque-register.log"
REG_LOCK="/tmp/luci-app-daede.usque-register.lock"
CRONTAB="/etc/crontabs/root"
TAG="# luci-app-daede usque-watchdog"
SELF="/usr/share/luci-app-daede/usque.sh"
PROBE_URL="http://cp.cloudflare.com/cdn-cgi/trace"
MAX_CFG=65536

uci_opt() {
	local v
	v="$(uci -q get "usque.config.$1" 2>/dev/null)"
	[ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}

# ---------------------------------------------------------------- status ----
do_status() {
	local installed=0 config=0 enabled=0 running=0 pid="" pids
	local bind port watchdog cron=0

	[ -x /usr/bin/usque ] && installed=1
	[ -s "$CFG" ] && config=1
	[ "$(uci_opt enabled 0)" = "1" ] && enabled=1
	[ "$(uci_opt watchdog 0)" = "1" ] && watchdog=1
	bind="$(uci_opt bind 127.0.0.1)"
	port="$(uci_opt port 1080)"

	pids="$(pidof usque 2>/dev/null)"
	if [ -n "$pids" ]; then
		running=1
		pid="${pids%% *}"
	fi

	[ -f "$CRONTAB" ] && grep -qF "$TAG" "$CRONTAB" 2>/dev/null && cron=1

	printf 'installed=%s\nconfig=%s\nenabled=%s\nrunning=%s\npid=%s\nbind=%s\nport=%s\nwatchdog=%s\ncron=%s\n' \
		"$installed" "$config" "$enabled" "$running" "$pid" \
		"$bind" "$port" "$watchdog" "$cron"
}

# ----------------------------------------------------------------- probe ----
# Dialable host for the probe: a wildcard bind cannot be dialed, and a bare
# IPv6 literal needs brackets for curl's --socks5-hostname.
probe_host() {
	local bind
	bind="$(uci_opt bind 127.0.0.1)"
	case "$bind" in
		''|0.0.0.0) bind="127.0.0.1" ;;
		'::'|'[::]') bind="[::1]" ;;
		'['*) : ;;
		*:*) bind="[$bind]" ;;
	esac
	printf '%s' "$bind"
}

# Staged SOCKS5 handshake over busybox nc (fallback when curl lacks socks5):
# greeting -> connect(cp.cloudflare.com:80) -> GET /cdn-cgi/trace, sleeping
# between steps so a buffered server cannot swallow the later bytes. NUL bytes
# come from /dev/zero — some shells truncate printf output at embedded NULs.
probe_nc() {
	local host="$1" port="$2" out="$3" fifo np

	command -v nc >/dev/null 2>&1 || return 1
	command -v mkfifo >/dev/null 2>&1 || return 1

	fifo="/tmp/usque-probe.$$.fifo"
	rm -f "$fifo"
	mkfifo "$fifo" || return 1
	trap '' PIPE

	nc -w 12 "$host" "$port" < "$fifo" > "$out" 2>/dev/null &
	np=$!
	exec 3>"$fifo" || { kill "$np" 2>/dev/null; rm -f "$fifo"; return 1; }
	rm -f "$fifo"
	kill -0 "$np" 2>/dev/null || { exec 3>&-; return 1; }

	# ver=5 nmethods=1 method=0 (no authentication)
	printf '\005\001' >&3 2>/dev/null && head -c 1 /dev/zero >&3 2>/dev/null || {
		exec 3>&-; kill "$np" 2>/dev/null; return 1
	}
	sleep 1
	# ver=5 cmd=1(connect) rsv=0 atyp=3(len=0x11) cp.cloudflare.com:80
	printf '\005\001' >&3 2>/dev/null && head -c 1 /dev/zero >&3 2>/dev/null &&
		printf '\003\021cp.cloudflare.com' >&3 2>/dev/null &&
		head -c 1 /dev/zero >&3 2>/dev/null && printf 'P' >&3 2>/dev/null || {
		exec 3>&-; kill "$np" 2>/dev/null; return 1
	}
	sleep 2
	printf 'GET /cdn-cgi/trace HTTP/1.0\r\nHost: cp.cloudflare.com\r\nConnection: close\r\n\r\n' >&3 2>/dev/null || true
	sleep 4
	exec 3>&-
	sleep 1
	kill "$np" 2>/dev/null
	wait "$np" 2>/dev/null
	return 0
}

do_probe() {
	local host port res rc code t ms warp ok tool=0 txt

	host="$(probe_host)"
	port="$(uci_opt port 1080)"
	: > "$PROBE_TMP"
	code=""
	t=""

	if command -v curl >/dev/null 2>&1; then
		res="$(curl -s --socks5-hostname "$host:$port" --max-time 10 --connect-timeout 5 \
			-o "$PROBE_TMP" -w '%{http_code} %{time_total}' "$PROBE_URL" 2>"$PROBE_ERR")"
		rc=$?
		# curl exit 2 = option not supported (built without socks5)
		if [ "$rc" != 2 ]; then
			tool=1
			code="$(printf '%s' "$res" | awk '{print $1}')"
			t="$(printf '%s' "$res" | awk '{print $2}')"
			[ -n "$code" ] || code=000
		fi
	fi

	if [ "$tool" = 0 ]; then
		# busybox nc wants a bare IPv6 host, curl wants brackets
		if probe_nc "${host#\[}" "${host%\]}" "$PROBE_TMP"; then
			tool=1
			t=""
		fi
	fi

	txt="$(tr -cd '\11\12\15\40-\176' < "$PROBE_TMP" 2>/dev/null)"
	warp="$(printf '%s\n' "$txt" | sed -n 's/^warp=\([a-z]*\).*/\1/p' | head -n1)"
	if [ -z "$code" ]; then
		code="$(printf '%s\n' "$txt" | grep -o 'HTTP/[0-9.]* [0-9][0-9][0-9]' | head -n1 | awk '{print $2}')"
		[ -n "$code" ] || code=000
	fi

	ok=0
	case "$code" in 200|204|301|302) ok=1 ;; esac
	[ -n "$warp" ] || warp="unknown"
	ms="$(awk -v x="${t:-0}" 'BEGIN{printf "%d", x*1000}')"
	case "$ms" in ''|*[!0-9]*) ms=0 ;; esac

	printf 'ok=%s http=%s warp=%s ms=%s tool=%s\n' "$ok" "$code" "$warp" "$ms" "$tool"
}

# ---------------------------------------------------------------- watchdog --
do_watchdog() {
	local n res ok

	[ "$(uci_opt enabled 0)" = "1" ] || return 0
	[ "$(uci_opt watchdog 0)" = "1" ] || return 0
	[ -s "$CFG" ] || return 0

	if ! pidof usque >/dev/null 2>&1; then
		logger -t usque-watchdog "process not running, restarting"
		/etc/init.d/usque restart >/dev/null 2>&1
		rm -f "$FAILS"
		return 0
	fi

	res="$(do_probe)"
	ok="$(printf '%s' "$res" | sed -n 's/.*ok=\([01]\).*/\1/p')"
	if [ "$(printf '%s' "$res" | sed -n 's/.*tool=\([01]\).*/\1/p')" = "0" ]; then
		# no probe tool on this system — the process check above is all we can do
		return 0
	fi
	if [ "$ok" = "1" ]; then
		rm -f "$FAILS"
		return 0
	fi

	n=""
	[ -f "$FAILS" ] && n="$(cat "$FAILS" 2>/dev/null)"
	case "$n" in ''|*[!0-9]*) n=0 ;; esac
	n=$((n + 1))

	if [ "$n" -ge 2 ]; then
		logger -t usque-watchdog "probe failed ${n}x, restarting ($res)"
		/etc/init.d/usque restart >/dev/null 2>&1
		rm -f "$FAILS"
	else
		echo "$n" > "$FAILS"
		logger -t usque-watchdog "probe failed ${n}x, waiting before restart ($res)"
	fi
	return 0
}

# ------------------------------------------------------------ watchdog cron -
clean_cron() {
	[ -f "$CRONTAB" ] || return 0
	grep -vF -e "$TAG" -e "$SELF" "$CRONTAB" > "$CRONTAB.tmp" 2>/dev/null
	mv "$CRONTAB.tmp" "$CRONTAB"
}

do_watchdog_cron() {
	case "$1" in
		enable)
			clean_cron
			mkdir -p /etc/crontabs
			{
				echo "$TAG"
				echo "*/5 * * * * $SELF watchdog >/dev/null 2>&1"
			} >> "$CRONTAB"
			/etc/init.d/cron enable >/dev/null 2>&1
			;;
		*)
			clean_cron
			;;
	esac
	/etc/init.d/cron restart >/dev/null 2>&1
	return 0
}

sync_watchdog_cron() {
	if [ "$(uci_opt watchdog 0)" = "1" ]; then
		do_watchdog_cron enable
	else
		do_watchdog_cron disable
	fi
}

# ------------------------------------------------------------------- save ----
validate_staged() {
	local f="$1" sz pk epk

	[ -s "$f" ] || { echo "staged config is missing or empty" >&2; return 1; }
	sz="$(wc -c < "$f" | tr -d ' ')"
	if [ "$sz" -gt "$MAX_CFG" ]; then
		echo "config is too large (${sz} bytes, max ${MAX_CFG})" >&2
		return 1
	fi

	if command -v jsonfilter >/dev/null 2>&1; then
		pk="$(jsonfilter -i "$f" -e '@["private_key"]' 2>/dev/null)"
		epk="$(jsonfilter -i "$f" -e '@["endpoint_pub_key"]' 2>/dev/null)"
		if [ -z "$pk" ] || [ -z "$epk" ]; then
			echo "not a valid WARP config: private_key / endpoint_pub_key missing" >&2
			return 1
		fi
		return 0
	fi

	# jsonfilter-less fallback: key presence only (the UI already JSON-parsed it)
	grep -q '"private_key"' "$f" && grep -q '"endpoint_pub_key"' "$f" && return 0
	echo "private_key / endpoint_pub_key missing" >&2
	return 1
}

do_save() {
	validate_staged "$STAGE" || return 1

	mkdir -p /etc/usque
	if ! cp "$STAGE" "$CFG.tmp.$$" 2>/dev/null; then
		echo "cannot write $CFG" >&2
		return 1
	fi
	chmod 600 "$CFG.tmp.$$"
	mv "$CFG.tmp.$$" "$CFG"
	rm -f "$STAGE" "$FAILS"

	if [ "$(uci_opt enabled 0)" = "1" ] && pidof usque >/dev/null 2>&1; then
		/etc/init.d/usque restart >/dev/null 2>&1
	fi
	sync_watchdog_cron
	echo "config saved"
	return 0
}

# ---------------------------------------------------------------- register ---
do_register() {
	local bak="" lockpid=""

	if [ ! -x /usr/bin/usque ]; then
		echo "usque is not installed" >&2
		return 1
	fi
	# a lock left by a killed job would wedge registration until reboot —
	# drop it when its owner is gone (/tmp is cleared on reboot anyway)
	if [ -f "$REG_LOCK" ]; then
		lockpid="$(cat "$REG_LOCK" 2>/dev/null)"
		case "$lockpid" in
			''|*[!0-9]*) rm -f "$REG_LOCK" ;;
			*) kill -0 "$lockpid" 2>/dev/null || rm -f "$REG_LOCK" ;;
		esac
	fi
	if [ -f "$REG_LOCK" ]; then
		echo "registration already in progress" >&2
		return 1
	fi
	if ! ( set -C; echo "$$" > "$REG_LOCK" ) 2>/dev/null; then
		echo "registration already in progress" >&2
		return 1
	fi

	mkdir -p /etc/usque
	if [ -s "$CFG" ]; then
		bak="$CFG.bak.$$"
		cp "$CFG" "$bak" 2>/dev/null || bak=""
	fi

	# fresh log before forking so the UI can never see the previous run's ✓/✗
	: > "$REG_LOG"

	(
		exec >"$REG_LOG" 2>&1
		trap 'rm -f "$REG_LOCK"' EXIT INT TERM

		rc=0
		echo "$(date '+%F %T') registering a new WARP account (can take up to a minute)…"
		/usr/bin/usque -c "$CFG" register || rc=$?
		if [ "$rc" = 0 ] && [ -s "$CFG" ]; then
			chmod 600 "$CFG"
			rm -f "$FAILS"
			if [ "$(uci_opt enabled 0)" = "1" ]; then
				/etc/init.d/usque restart >/dev/null 2>&1
			fi
			rm -f "$bak"
			sync_watchdog_cron
			echo "$(date '+%F %T') ✓ registered"
		else
			# registration failed or left no usable file — put the old one back
			if [ -n "$bak" ] && [ -f "$bak" ]; then
				mv "$bak" "$CFG" 2>/dev/null
				chmod 600 "$CFG" 2>/dev/null
			fi
			echo "$(date '+%F %T') ✗ register failed (rc=$rc)"
		fi
	) </dev/null >/dev/null 2>&1 &

	echo "registration started, see $REG_LOG"
	return 0
}

# ------------------------------------------------------------------ clear ----
do_clear() {
	rm -f "$CFG" "$FAILS"
	if pidof usque >/dev/null 2>&1; then
		/etc/init.d/usque stop >/dev/null 2>&1
	fi
	echo "config removed"
	return 0
}

# ------------------------------------------------------------------- main ----
ACTION="$1"

PROBE_TMP="/tmp/usque-probe.$$.out"
PROBE_ERR="/tmp/usque-probe.$$.err"
trap 'rm -f "$PROBE_TMP" "$PROBE_ERR"' EXIT

case "$ACTION" in
	save)          do_save ;;
	register)      do_register ;;
	clear)         do_clear ;;
	status)        do_status ;;
	probe)         do_probe ;;
	watchdog)      do_watchdog ;;
	watchdog-cron)
		case "$2" in
			enable|disable) do_watchdog_cron "$2" ;;
			*) echo "usage: $0 watchdog-cron <enable|disable>" >&2; exit 64 ;;
		esac
		;;
	*)
		echo "usage: $0 <save|register|clear|status|probe|watchdog|watchdog-cron enable|disable>" >&2
		exit 64
		;;
esac
rc=$?
rm -f "$PROBE_TMP" "$PROBE_ERR"
exit $rc
