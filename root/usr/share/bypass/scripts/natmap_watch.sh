#!/bin/sh
# usage: natmap_watch.sh [--once] <natmap section id>...

TABLE="bypass_logic"
STATUS_PATH="${STATUS_PATH:-/var/run/natmap}"
INTERVAL="${INTERVAL:-5}"
ONCE=0
[ "$1" = "--once" ] && { ONCE=1; shift; }
SIDS=" $* "
LAST_SIG=""

wan_set() {
    local n d list="" out="" x
    for n in wan wan6; do
        d=$(ifstatus "$n" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
        [ -n "$d" ] && case " $list " in *" $d "*) ;; *) list="$list $d" ;; esac
    done
    [ -z "$list" ] && list=" $(uci -q get network.wan.device || uci -q get network.wan.ifname || echo wan)"
    for x in $list; do out="${out:+$out, }\"$x\""; done
    echo "{ $out }"
}

is_num() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

apply() {
    local f sid proto port inner target n=0 inner_list="" outer_list="" rules="" sig wan err

    [ "$(uci -q get bypass.global.enable_natmap)" = "1" ] || return 0

    for f in "$STATUS_PATH"/*.json; do
        [ -f "$f" ] || continue
        sid=$(jsonfilter -q -i "$f" -e '@.sid') || continue
        case "$SIDS" in *" $sid "*) ;; *) continue ;; esac
        proto=$(jsonfilter -q -i "$f" -e '@.protocol')
        port=$(jsonfilter -q -i "$f" -e '@.port')
        inner=$(jsonfilter -q -i "$f" -e '@.inner_port')
        is_num "$port" && is_num "$inner" || continue

        n=$((n + 1))
        inner_list="$inner_list${inner_list:+, }$inner"

        if [ "$proto" = "udp" ]; then
            outer_list="$outer_list${outer_list:+, }$port"
            target=$(uci -q get natmap."$sid".forward_target)
            case "$target" in ''|*[!0-9a-fA-F.:]*) ;; *)
                rules="$rules
add rule inet $TABLE qb_fix iifname __WAN__ meta nfproto ipv4 tcp dport $port counter dnat ip to $target:$inner
add rule inet $TABLE qb_fix iifname __WAN__ meta nfproto ipv6 tcp dport $port counter dnat to :$inner" ;;
            esac
        fi
    done

    [ "$n" -gt 0 ] || return 0

    sig="$inner_list|$outer_list|$rules"
    [ "$ONCE" = 0 ] && [ "$sig" = "$LAST_SIG" ] && return 0

    wan=$(wan_set)
    err=$({
        echo "flush set inet $TABLE qb_dynamic_ports"
        echo "flush set inet $TABLE qb_outer_ports"
        echo "flush chain inet $TABLE qb_fix"
        [ -n "$inner_list" ] && echo "add element inet $TABLE qb_dynamic_ports { $inner_list }"
        [ -n "$outer_list" ] && echo "add element inet $TABLE qb_outer_ports { $outer_list }"
        [ -n "$rules" ] && echo "$rules" | sed "s|__WAN__|$wan|"
    } | nft -f - 2>&1) || {
        logger -t bypass "Natmap: FAILED to update the qB rules: $(echo "$err" | head -n 2 | tr '\n' ' ')"
        return 1
    }

    LAST_SIG="$sig"
    logger -t bypass "Natmap: qB ports updated (inner: $inner_list, public: ${outer_list:-none})"
}

if [ "$ONCE" = 1 ]; then
    apply
    exit 0
fi

last=""
while :; do
    cur=""
    for f in "$STATUS_PATH"/*.json; do
        [ -f "$f" ] || continue
        line=""
        read -r line < "$f" || [ -n "$line" ] || continue
        cur="$cur$line"
    done
    if [ "$cur" != "$last" ]; then
        last="$cur"
        apply
    fi
    sleep "$INTERVAL"
done
