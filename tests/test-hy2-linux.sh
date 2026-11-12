#!/usr/bin/env bash
# Run as root on an isolated Linux CI runner. All network changes use test
# namespaces. A UDP echo socket substitutes for Xray to test packet delivery.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID == 0 ]] || exit 1
temp=$(mktemp -d)
server="pm-hy2-server-$$"
client="pm-hy2-client-$$"
cleanup() {
    if [[ -n ${echo_pid:-} ]]; then kill "$echo_pid" 2>/dev/null || true; fi
    ip netns del "$client" 2>/dev/null || true
    ip netns del "$server" 2>/dev/null || true
    rm -rf "$temp"
}
trap cleanup EXIT

ip netns add "$server"
ip netns add "$client"
ip -n "$server" link add pm0 type veth peer name pm0 netns "$client"
for ns in "$server" "$client"; do
    ip -n "$ns" link set lo up
    ip -n "$ns" link set pm0 up
done
ip -n "$server" address add 192.0.2.1/24 dev pm0
ip -n "$client" address add 192.0.2.2/24 dev pm0
ip -n "$server" -6 address add 2001:db8::1/64 dev pm0 nodad
ip -n "$client" -6 address add 2001:db8::2/64 dev pm0 nodad

ip netns exec "$server" python3 -u - "$temp/ready" <<'PY' &
import pathlib
import selectors
import socket
import sys

selector = selectors.DefaultSelector()
for family, host, port in [
    (socket.AF_INET, "0.0.0.0", 443),
    (socket.AF_INET, "0.0.0.0", 8443),
    (socket.AF_INET6, "::", 8443),
]:
    listener = socket.socket(family, socket.SOCK_DGRAM)
    if family == socket.AF_INET6:
        listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    listener.bind((host, port))
    selector.register(listener, selectors.EVENT_READ)
pathlib.Path(sys.argv[1]).touch()
while True:
    for key, _ in selector.select():
        data, peer = key.fileobj.recvfrom(256)
        key.fileobj.sendto(data, peer)
PY
echo_pid=$!
for ((attempt=0; attempt<50; attempt++)); do
    [[ ! -f $temp/ready ]] || break
    sleep 0.1
done
test -f "$temp/ready"

cat >"$temp/server.sh" <<'BASH'
set -euo pipefail
source ./portman.sh
source ./hy2-hop.sh
temp=$1
phase=$2
HY2_DIR=$temp/config
HY2_UNIT_FILE=$temp/$HY2_UNIT
HY2_LOCK=$temp/lock
HY2_LEGACY_SCRIPT=$temp/hy2-hop-restore.sh
HY2_SAVED_IPTABLES=$temp/iptables
detect_firewall() { echo iptables; }
systemctl() {
    case $1 in
        show) [[ $* != *LoadState* ]] || echo loaded ;;
        enable|disable|daemon-reload|is-enabled) : ;;
        *) return 1 ;;
    esac
}

case $phase in
    setup)
        iptables -P INPUT DROP
        ip6tables -P INPUT DROP
        ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
        iptables -N f2b-sshd
        iptables -A INPUT -p tcp --dport 22 -j f2b-sshd
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        iptables-save >"$temp/filter.before"
        nft -f - <<'RULES'
table ip hy2_hop {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport 20000-20100 counter redirect to :443
    }
}
RULES
        nft -s list table ip hy2_hop >"$temp/legacy.before"
        hy2_locked hy2_commit put 'legacy 4 443 20000 20100 30 legacy'
        hy2_locked hy2_commit put 'dual both 8443 21000 21100 30 managed'
        ;;
    verify)
        nft -a list table ip portman_hy2 >"$temp/rule.v4"
        nft -a list table ip6 portman_hy2 >"$temp/rule.v6"
        for file in "$temp/rule.v4" "$temp/rule.v6"; do
            grep -Eq 'counter packets [1-9][0-9]* bytes' "$file"
        done
        nft list table ip hy2_hop | grep -Eq 'counter packets [1-9][0-9]* bytes'
        hy2_locked hy2_restore
        nft -a list table ip portman_hy2 | diff - "$temp/rule.v4"
        nft -a list table ip6 portman_hy2 | diff - "$temp/rule.v6"
        iptables -nvxL INPUT | awk '/portman-hy2-v1:dual/ && $1>0 {ok=1} END {exit !ok}'
        ip6tables -nvxL INPUT | awk '/portman-hy2-v1:dual/ && $1>0 {ok=1} END {exit !ok}'
        # Simulate loss of runtime rules before service restore.
        nft delete table ip portman_hy2
        nft delete table ip6 portman_hy2
        hy2_filter_rule iptables -D 8443 21000:21100 dual
        hy2_filter_rule ip6tables -D 8443 21000:21100 dual
        hy2_locked hy2_restore
        nft list table ip6 portman_hy2 >/dev/null
        ;;
    cleanup)
        hy2_locked hy2_commit reset
        if nft list table ip portman_hy2 2>/dev/null || nft list table ip6 portman_hy2 2>/dev/null; then
            echo 'HY2 table survived removal' >&2
            exit 1
        fi
        nft -s list table ip hy2_hop | diff - "$temp/legacy.before"
        iptables-save | sed '/^#/d' >"$temp/filter.after"
        sed '/^#/d' "$temp/filter.before" | diff - "$temp/filter.after"
        ;;
esac
BASH

send_packets() {
    ip netns exec "$client" python3 - <<'PY'
import socket

for family, host, port in [
    (socket.AF_INET, "192.0.2.1", 20020),
    (socket.AF_INET, "192.0.2.1", 21020),
    (socket.AF_INET6, "2001:db8::1", 21020),
]:
    with socket.socket(family, socket.SOCK_DGRAM) as client:
        client.settimeout(3)
        client.sendto(b"portman-hy2", (host, port))
        reply, peer = client.recvfrom(256)
        assert reply == b"portman-hy2" and peer[1] == port, (reply, peer)
PY
}

ip netns exec "$server" bash "$temp/server.sh" "$temp" setup
send_packets
ip netns exec "$server" bash "$temp/server.sh" "$temp" verify
send_packets
ip netns exec "$server" bash "$temp/server.sh" "$temp" cleanup
echo '[PASS] Linux IPv4/IPv6 重定向、真实 UDP 回包和计数、规则幂等及卸载隔离'
