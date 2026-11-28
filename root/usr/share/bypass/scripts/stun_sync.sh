#!/bin/sh

STUN_URL="https://raw.githubusercontent.com/muink/rfc5780-stun-server/master/valid_hosts_rfc5780.txt"
STUN_CACHE="/tmp/stun_servers.txt"
STUN_ETAG="/tmp/stun_servers.etag"
EXTRA_STATE="/tmp/stun_extra.list"
TABLE="bypass_logic"
SET_NAME="stun_direct"
LOCK_DIR="/tmp/stun_sync.lock"

EXTRA_DOMAINS="
stun.l.google.com
stun1.l.google.com
stun2.l.google.com
stun3.l.google.com
stun4.l.google.com
"

rm -f /etc/config/stun_servers.txt /etc/config/stun_servers.etag 2>/dev/null

nft list table inet $TABLE >/dev/null 2>&1 || exit 1

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

sync_stun() {
    local force="$1"
    local tmp_header="$LOCK_DIR/header"
    local tmp_body="$LOCK_DIR/body"
    local etag=""
    [ -f "$STUN_ETAG" ] && etag=$(cat "$STUN_ETAG")

    if [ -n "$etag" ]; then
        curl -sL -D "$tmp_header" --connect-timeout 5 --max-time 30 -H "If-None-Match: $etag" "$STUN_URL" -o "$tmp_body"
    else
        curl -sL -D "$tmp_header" --connect-timeout 5 --max-time 30 "$STUN_URL" -o "$tmp_body"
    fi
    local status=$(grep "^HTTP/" "$tmp_header" 2>/dev/null | tail -n1 | tr -d '\r' | awk '{print $2}')

    if [ "$status" = "200" ] && [ -s "$tmp_body" ]; then
        grep -i "^etag:" "$tmp_header" | tail -n1 | sed 's/^[^:]*: *//' | tr -d '\r' > "$STUN_ETAG"
        mv "$tmp_body" "$STUN_CACHE"
        force=1
    fi
    rm -f "$tmp_header" "$tmp_body"

    local extra_list=$(printf '%s\n' "$EXTRA_DOMAINS" | grep -vE '^[[:space:]]*(#|$)' | tr -d '\r')
    local old_list=$(cat "$EXTRA_STATE" 2>/dev/null)
    if [ "$extra_list" != "$old_list" ]; then
        force=1
    fi

    local current_empty=$(nft list set inet $TABLE $SET_NAME 2>/dev/null | grep -q "element" && echo 0 || echo 1)
    if [ "$force" != "1" ] && [ "$current_empty" = "0" ]; then
        local last_mod=$(stat -c %Y "$STUN_CACHE" 2>/dev/null || echo 0)
        local now=$(date +%s)
        if [ $((now - last_mod)) -lt 7200 ]; then
            exit 0
        fi
    fi

    if [ ! -s "$STUN_CACHE" ] && [ -z "$extra_list" ]; then
        exit 0
    fi

    logger -t bypass "STUN: Starting DNS resolution for IP set..."
    local domains=$( {
        [ -s "$STUN_CACHE" ] && grep -vE '^#|^$' "$STUN_CACHE"
        [ -n "$extra_list" ] && printf '%s\n' "$extra_list"
    } | tr -d '\r' | awk '{print $1}' | sort -u )
    local nft_cmd="$LOCK_DIR/nft.cmd"
    local add_cmd="$LOCK_DIR/nft.add"
    : > "$add_cmd"

    for domain in $domains; do
        local clean_domain=$(echo "$domain" | awk -F: '{print $1}')
        [ -z "$clean_domain" ] && continue
        local ips=$(nslookup "$clean_domain" 127.0.0.1 2>/dev/null | grep 'Address' | awk '{print $2}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -v '127.0.0.1' | grep -vE '^198\.1[89]\.')
        if [ -n "$ips" ]; then
            for ip in $ips; do
                echo "add element inet $TABLE $SET_NAME { $ip }" >> "$add_cmd"
            done
        fi
    done

    if [ ! -s "$add_cmd" ]; then
        logger -t bypass "STUN: No IP resolved, keeping existing set."
        rm -f "$add_cmd"
        exit 0
    fi

    echo "flush set inet $TABLE $SET_NAME" > "$nft_cmd"
    cat "$add_cmd" >> "$nft_cmd"
    nft -f "$nft_cmd" 2>/dev/null
    rm -f "$nft_cmd" "$add_cmd"

    printf '%s\n' "$extra_list" > "$EXTRA_STATE"

    local final_count=$(nft list set inet $TABLE $SET_NAME 2>/dev/null | tr ',' '\n' | grep -cE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [ -f "$STUN_CACHE" ] && touch "$STUN_CACHE"
    logger -t bypass "STUN: IP set updated with $final_count elements."
}

sync_stun "$1"
