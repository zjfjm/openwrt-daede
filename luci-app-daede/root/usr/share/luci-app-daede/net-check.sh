#!/bin/sh
# net-check.sh - egress-IP + website-access probes for the daede Settings
# page card (router side; daed proxies the router's own WAN-bound traffic, so
# these reflect what a LAN client gets). Ported from OpenClash
# luasrc/view/openclash/myip.htm + controller/openclash.lua action_myip_check
# and action_website_check (GPL-3.0, https://github.com/vernesong/OpenClash).
#
# Prints one JSON object per line (NDJSON):
#   {"service":"pcol","ip":"1.2.3.4","geo_hex":"..."}   hex = raw GBK bytes
#   {"service":"ipip","ip":"...","geo":"中国 浙江 宁波 电信"}
#   {"service":"ipsb","ip":"...","geo":"China Warp"}
#   {"service":"ipify","geo":"China Warp"}
#   {"domain":"github.com","success":true,"response_time":1612}
#   {"domain":"...","success":false,"error":"timeout"}
#   {"complete":true}
#
# geo_hex is decoded client-side (UTF-8 first, GBK fallback) because the
# pconline response body is GBK and must not be fed to JSON.parse raw.

TMP="/tmp/daede-netcheck.$$"
mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
Z="$(date +%s)"

json_str() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# raw bytes -> hex (frontend TextDecoder utf-8/gbk); needs hexdump
hex_of() {
	if command -v hexdump >/dev/null 2>&1; then
		printf '%s' "$1" | hexdump -v -e '1/1 "%02x"'
	fi
}

json_field() {
	# $1=file $2=key -> value of "key":"value" (ASCII keys only)
	sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p' "$1" | head -n1
}

# ---- website latency: 4 domains x 2 urls (favicon first, bare url fallback)
# mirrors latency_test(): rt = TLS handshake (appconnect) when present
parse_lat() {
	[ -s "$1" ] || return 0
	awk -F, '
		NF == 4 { code = $1 + 0; total = $2 + 0; conn = $3 + 0; app = $4 + 0 }
		NF == 3 { code = $1 + 0; total = $2 + 0; conn = 0;      app = $3 + 0 }
		NF < 3  { exit }
		{
			rt = (app > 0) ? int(app * 1000) : ((conn > 0) ? int(conn * 1000) : int(total * 1000))
			if ((code >= 200 && code < 400) || code == 403 || code == 404)
				print "OK " rt
			else
				print "ERR HTTP " code
			exit
		}' "$1"
}

# ---- IP services (4 concurrent) ----
curl -SsL -m 10 -A "$UA" "https://whois.pconline.com.cn/ipJson.jsp?json=true&z=$Z" -o "$TMP/pcol" 2>/dev/null &
curl -SsL -m 10 -A "$UA" "http://myip.ipip.net?z=$Z" -o "$TMP/ipip" 2>/dev/null &
curl -SsL -m 10 -A "$UA" "https://api.ip.sb/geoip?z=$Z" -o "$TMP/ipsb" 2>/dev/null &
curl -SsL -m 10 -A "$UA" "https://api.ipify.org/?format=json&z=$Z" -o "$TMP/ipify" 2>/dev/null &

DOMAINS="www.baidu.com|s1.music.126.net/style|github.com|www.youtube.com"
n=0
OLDIFS=$IFS
IFS='|'
for d in $DOMAINS; do
	n=$((n + 1))
	curl -sI -m 10 --connect-timeout 3 -A "$UA" \
		-w '%{http_code},%{time_total},%{time_connect},%{time_appconnect}' \
		-o /dev/null "https://$d/favicon.ico" >"$TMP/l$n.1" 2>/dev/null &
	curl -sI -m 10 --connect-timeout 3 -A "$UA" \
		-w '%{http_code},%{time_total},%{time_connect},%{time_appconnect}' \
		-o /dev/null "https://$d" >"$TMP/l$n.2" 2>/dev/null &
done
IFS=$OLDIFS
wait

# ---- emit IP results ----
if [ -s "$TMP/pcol" ]; then
	tr -d '\n\r' <"$TMP/pcol" >"$TMP/pcol.1"
	ip="$(json_field "$TMP/pcol.1" ip)"
	pro="$(json_field "$TMP/pcol.1" pro)"
	city="$(json_field "$TMP/pcol.1" city)"
	addr="$(json_field "$TMP/pcol.1" addr)"
	isp="$(printf '%s' "$addr" | sed 's/^.*[[:space:]]//')"
	geo="$(printf '%s %s %s' "$pro" "$city" "$isp" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
	if [ -n "$ip" ]; then
		printf '{"service":"pcol","ip":"%s","geo_hex":"%s"}\n' "$(json_str "$ip")" "$(hex_of "$geo")"
	fi
fi

if [ -s "$TMP/ipip" ]; then
	ip="$(sed -n 's/.*当前 IP：\([0-9a-fA-F:.]*\).*/\1/p' "$TMP/ipip" | head -n1)"
	geo="$(sed -n 's/.*来自于：\(.*\)/\1/p' "$TMP/ipip" | head -n1 | tr -d '\r' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
	if [ -n "$ip" ]; then
		printf '{"service":"ipip","ip":"%s","geo":"%s"}\n' "$(json_str "$ip")" "$(json_str "$geo")"
	fi
fi

if [ -s "$TMP/ipsb" ]; then
	ip="$(json_field "$TMP/ipsb" ip)"
	country="$(json_field "$TMP/ipsb" country)"
	isp="$(json_field "$TMP/ipsb" isp)"
	if [ -n "$ip" ]; then
		printf '{"service":"ipsb","ip":"%s","geo":"%s"}\n' \
			"$(json_str "$ip")" "$(json_str "$country $isp" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
	fi
fi

if [ -s "$TMP/ipify" ]; then
	ip="$(json_field "$TMP/ipify" ip)"
	if [ -n "$ip" ]; then
		printf '{"service":"ipify","ip":"%s"}\n' "$(json_str "$ip")"
		curl -SsL -m 10 -A "$UA" "https://api.ip.sb/geoip/$(json_str "$ip")" -o "$TMP/ipify.geo" 2>/dev/null
		if [ -s "$TMP/ipify.geo" ]; then
			country="$(json_field "$TMP/ipify.geo" country)"
			isp="$(json_field "$TMP/ipify.geo" isp)"
			printf '{"service":"ipify","geo":"%s"}\n' \
				"$(json_str "$country $isp" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
		fi
	fi
fi

# ---- emit latency results ----
n=0
IFS='|'
for d in $DOMAINS; do
	n=$((n + 1))
	r="$(parse_lat "$TMP/l$n.1")"
	[ -n "$r" ] || r="$(parse_lat "$TMP/l$n.2")"
	if [ -z "$r" ]; then
		printf '{"domain":"%s","success":false,"error":"timeout"}\n' "$d"
	elif [ "${r%% *}" = "OK" ]; then
		printf '{"domain":"%s","success":true,"response_time":%s}\n' "$d" "${r#* }"
	else
		printf '{"domain":"%s","success":false,"error":"%s"}\n' "$d" "${r#* }"
	fi
done
IFS=$OLDIFS

echo '{"complete":true}'
