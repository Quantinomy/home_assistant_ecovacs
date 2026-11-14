#!/bin/sh
# NetworkManager dispatcher script: keeps devices on a Wi-Fi hotspot off the
# internet and redirects their DNS and Bumper's ports to this machine.
# $1 = interface, $2 = action, CONNECTION_UUID set by the dispatcher.

iface="$1"
action="$2"

mode=$(nmcli -g 802-11-wireless.mode connection show "$CONNECTION_UUID" 2>/dev/null)
[ "$mode" = ap ] || exit 0

case "$action" in
up)
    nft delete table inet iot 2>/dev/null
    nft -f - <<EOF
table inet iot {
    chain block_forward {
        type filter hook forward priority -10;
        # Docker-published ports (e.g. Bumper) are DNATed to a container and forwarded
        iifname "$iface" ct status dnat accept
        iifname "$iface" counter log prefix "iot-drop: " drop
    }
    chain redirect_local {
        type nat hook prerouting priority dstnat;
        iifname "$iface" tcp dport { 443, 5223, 8007, 8883 } redirect
        iifname "$iface" meta l4proto { tcp, udp } th dport 53 redirect to :53
    }
}
EOF
    ;;
down)
    nft delete table inet iot 2>/dev/null
    ;;
esac
