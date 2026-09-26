#!/bin/sh
# usque.sh - manage the WARP MASQUE tunnel (usque SOCKS5 proxy) from LuCI.
#
#   save                validate staged /tmp/daede-usque-save.json -> /etc/usque/config.json
#   register            register a WARP account (direct `usque register`, or via the
#                       usque-custom-pro worker relay when usque.config.register_relay
#                       is set — the P-256 key is generated on the router)
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
# CF returns peer endpoints as "ip:port" / "[v6]:port" — usque wants the bare
# address. Same three cases as the usque-custom-pro browser helper.
strip_endpoint() {
	local s="$1"
	case "$s" in
		'['*)
			s="${s#\[}"
			s="${s%%\]*}"
			;;
		*)
			if printf '%s' "$s" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+$'; then
				s="${s%:*}"
			fi
			;;
	esac
	printf '%s' "$s"
}

# Register through a usque-custom-pro worker (/api/warp/register +
# /api/warp/enroll) instead of talking to api.cloudflareclient.com directly.
# Mirrors the browser flow: the P-256 key is generated locally with openssl,
# only the public key is enrolled. Success is reported by the caller's final
# ✓ line; on failure REG_ERR carries the detail appended to the ✗ line.
register_via_relay() {
	local relay="$1" tmp="" crc http msg id token lic lic2 devname
	local key serial tos priv pub ep4 ep6 ppk ipv4 ipv6

	relay="${relay%/}"
	case "$relay" in
		http://*|https://*) : ;;
		*) REG_ERR="relay URL must start with http:// or https://"; return 1 ;;
	esac

	if ! command -v curl >/dev/null 2>&1; then
		REG_ERR="curl is required for relay registration (opkg install curl)"
		return 1
	fi
	if ! command -v openssl >/dev/null 2>&1; then
		REG_ERR="openssl is required for relay registration (opkg install openssl-util)"
		return 1
	fi
	if [ ! -f /usr/share/libubox/jshn.sh ]; then
		REG_ERR="jshn missing (libubox not installed)"
		return 1
	fi

	tmp="/tmp/usque-relay.$$"
	rm -rf "$tmp"
	if ! mkdir -p "$tmp"; then
		REG_ERR="cannot create $tmp"
		return 1
	fi

	# P-256 keypair: SEC1 DER for the config's private_key, SPKI DER for enroll
	if ! openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/k.pem" 2>/dev/null; then
		REG_ERR="P-256 key generation failed"
		rm -rf "$tmp"
		return 1
	fi
	priv="$(openssl ec -in "$tmp/k.pem" -outform DER 2>/dev/null | base64 | tr -d '\n')"
	pub="$(openssl ec -in "$tmp/k.pem" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')"
	rm -f "$tmp/k.pem"
	if [ -z "$priv" ] || [ -z "$pub" ]; then
		REG_ERR="P-256 key export failed"
		rm -rf "$tmp"
		return 1
	fi

	. /usr/share/libubox/jshn.sh

	# 1/2 device registration — random curve25519 key, as the browser does
	key="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
	serial="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	tos="$(date '+%Y-%m-%dT%H:%M:%S').000$(date '+%z' | sed 's/\(...\)\(..\)$/\1:\2/')"
	json_init
	json_add_string key "$key"
	json_add_string serial_number "$serial"
	json_add_string tos "$tos"
	json_dump > "$tmp/reg.json"

	echo "$(date '+%F %T') 1/2 creating WARP account via relay ${relay}…"
	http="$(curl -sS --max-time 30 \
		-H 'Content-Type: application/json' \
		-H 'X-Usque-Intent: single-register' \
		--data-binary "@$tmp/reg.json" \
		-o "$tmp/reg.out" -w '%{http_code}' \
		"$relay/api/warp/register" 2>"$tmp/curl.err")"
	crc=$?
	if [ "$crc" != 0 ] || [ -z "$http" ]; then
		msg="$(tail -n1 "$tmp/curl.err" 2>/dev/null)"
		REG_ERR="relay unreachable (curl ${crc})${msg:+: ${msg}}"
		rm -rf "$tmp"
		return 1
	fi
	case "$http" in
		2??) : ;;
		*)
			msg=""
			if json_load "$(cat "$tmp/reg.out" 2>/dev/null)" 2>/dev/null; then
				json_get_var msg message
			fi
			[ -n "$msg" ] || msg="$(tail -n1 "$tmp/reg.out" 2>/dev/null | tr -cd '\40-\176' | cut -c1-160)"
			REG_ERR="register HTTP ${http}${msg:+: ${msg}}"
			rm -rf "$tmp"
			return 1
			;;
	esac

	if ! json_load "$(cat "$tmp/reg.out")" 2>/dev/null; then
		REG_ERR="register response is not valid JSON"
		rm -rf "$tmp"
		return 1
	fi
	json_get_var id id
	json_get_var token token
	if json_select account 2>/dev/null; then
		json_get_var lic license
		json_select ..
	fi
	if [ -z "$id" ] || [ -z "$token" ]; then
		REG_ERR="register response missing id/token"
		rm -rf "$tmp"
		return 1
	fi

	# 2/2 MASQUE enrollment — only the public key is sent
	devname="$(tr -cd 'A-Za-z0-9._-' < /proc/sys/kernel/hostname 2>/dev/null | cut -c1-64)"
	[ -n "$devname" ] || devname="OpenWrt"
	json_init
	json_add_string id "$id"
	json_add_string token "$token"
	json_add_string public_key "$pub"
	json_add_string name "$devname"
	json_dump > "$tmp/enr.json"

	echo "$(date '+%F %T') 2/2 enrolling MASQUE key…"
	http="$(curl -sS --max-time 30 \
		-H 'Content-Type: application/json' \
		-H 'X-Usque-Intent: single-register' \
		--data-binary "@$tmp/enr.json" \
		-o "$tmp/enr.out" -w '%{http_code}' \
		"$relay/api/warp/enroll" 2>"$tmp/curl.err")"
	crc=$?
	if [ "$crc" != 0 ] || [ -z "$http" ]; then
		msg="$(tail -n1 "$tmp/curl.err" 2>/dev/null)"
		REG_ERR="relay unreachable (curl ${crc})${msg:+: ${msg}}"
		rm -rf "$tmp"
		return 1
	fi
	case "$http" in
		2??) : ;;
		*)
			msg=""
			if json_load "$(cat "$tmp/enr.out" 2>/dev/null)" 2>/dev/null; then
				json_get_var msg message
			fi
			[ -n "$msg" ] || msg="$(tail -n1 "$tmp/enr.out" 2>/dev/null | tr -cd '\40-\176' | cut -c1-160)"
			REG_ERR="enroll HTTP ${http}${msg:+: ${msg}}"
			rm -rf "$tmp"
			return 1
			;;
	esac

	if ! json_load "$(cat "$tmp/enr.out")" 2>/dev/null; then
		REG_ERR="enroll response is not valid JSON"
		rm -rf "$tmp"
		return 1
	fi
	if json_select config 2>/dev/null; then
		if json_select peers 2>/dev/null; then
			if json_select 0 2>/dev/null; then
				if json_select endpoint 2>/dev/null; then
					json_get_var ep4 v4
					json_get_var ep6 v6
					json_select ..
				fi
				json_get_var ppk public_key
				json_select ..
			fi
			json_select ..
		fi
		if json_select interface 2>/dev/null; then
			if json_select addresses 2>/dev/null; then
				json_get_var ipv4 v4
				json_get_var ipv6 v6
				json_select ..
			fi
			json_select ..
		fi
		json_select ..
	fi
	if json_select account 2>/dev/null; then
		json_get_var lic2 license
		json_select ..
	fi
	[ -n "$lic2" ] && lic="$lic2"
	ep4="$(strip_endpoint "$ep4")"
	ep6="$(strip_endpoint "$ep6")"

	if [ -z "$ppk" ]; then
		REG_ERR="enroll response missing endpoint public_key"
		rm -rf "$tmp"
		return 1
	fi
	if [ -z "$ep4" ] && [ -z "$ep6" ]; then
		REG_ERR="enroll response has no usable MASQUE endpoint"
		rm -rf "$tmp"
		return 1
	fi
	if [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
		REG_ERR="enroll response has no interface address"
		rm -rf "$tmp"
		return 1
	fi

	json_init
	json_add_string private_key "$priv"
	json_add_string endpoint_v4 "$ep4"
	json_add_string endpoint_v6 "$ep6"
	json_add_string endpoint_h2_v4 "162.159.198.2"
	json_add_string endpoint_h2_v6 ""
	json_add_string endpoint_pub_key "$ppk"
	json_add_string license "$lic"
	json_add_string id "$id"
	json_add_string access_token "$token"
	json_add_string ipv4 "$ipv4"
	json_add_string ipv6 "$ipv6"
	if ! json_dump > "$tmp/cfg.json"; then
		REG_ERR="config assembly failed"
		rm -rf "$tmp"
		return 1
	fi
	if ! validate_staged "$tmp/cfg.json"; then
		REG_ERR="assembled config failed validation"
		rm -rf "$tmp"
		return 1
	fi
	if ! cp "$tmp/cfg.json" "$CFG"; then
		REG_ERR="cannot write $CFG"
		rm -rf "$tmp"
		return 1
	fi
	chmod 600 "$CFG"
	rm -rf "$tmp"
	return 0
}

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
		RELAY="$(uci_opt register_relay '')"
		REG_ERR=""
		if [ -n "$RELAY" ]; then
			echo "$(date '+%F %T') registering via relay ${RELAY%/}…"
			register_via_relay "$RELAY" || rc=$?
		else
			echo "$(date '+%F %T') registering a new WARP account (can take up to a minute)…"
			/usr/bin/usque -c "$CFG" register || rc=$?
		fi
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
			echo "$(date '+%F %T') ✗ register failed (rc=$rc)${REG_ERR:+: $REG_ERR}"
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
