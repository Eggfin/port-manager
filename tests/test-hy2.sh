#!/usr/bin/env bash
# Simulate the host tools. No root, server, or live firewall is needed.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./portman.sh
source ./hy2-hop.sh
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

HY2_DIR=$temp/config
HY2_UNIT_FILE=$temp/$HY2_UNIT
HY2_LOCK=$temp/lock
HY2_LEGACY_SCRIPT=$temp/hy2-hop-restore.sh
HY2_SAVED_IPTABLES=$temp/iptables
mkdir -p "$HY2_SAVED_IPTABLES"
touch "$temp/foreign" "$temp/managed" "$temp/filter4" "$temp/filter6" "$temp/events"
printf '%s\n' '# original legacy script' >"$HY2_LEGACY_SCRIPT"

need_root() { :; }
detect_firewall() { echo iptables; }
if ! has flock; then flock() { :; }; fi
nft() {
    case "$*" in
        'list ruleset'|'-s list ruleset') cat "$temp/foreign" "$temp/managed" ;;
        '-c -f '*) echo nft-check >>"$temp/events"; [[ ! -e $temp/check-fail ]] ;;
        '-f '*)
            echo nft-apply >>"$temp/events"
            [[ ! -e $temp/apply-fail ]] || return 1
            for family in ip ip6; do
                if grep -Eq "^(delete )?table $family $HY2_TABLE( |$)" "$2"; then
                    hy2_table "$family" "$HY2_TABLE" <"$2" >"$temp/$family"
                fi
            done
            cat "$temp"/ip "$temp"/ip6 2>/dev/null >"$temp/managed" || true ;;
        *) return 1 ;;
    esac
}
systemctl() {
    case $1 in
        daemon-reload) echo reload >>"$temp/events" ;;
        show) [[ $* != *LoadState* ]] || echo loaded ;;
        enable) [[ ! -e $temp/enable-fail ]] && touch "$temp/enabled" ;;
        disable) rm -f "$temp/enabled" ;;
        is-enabled) [[ $2 == hy2-hop.service || -f $temp/enabled ]] ;;
        *) return 1 ;;
    esac
}
ss() {
    case $1 in
        -4)
            echo 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=40,fd=8))'
            echo 'udp UNCONN 0 0 0.0.0.0:8443 0.0.0.0:* users:(("xray",pid=40,fd=9))'
            echo 'UNCONN 0 0 127.0.0.1:5300 0.0.0.0:* users:(("dns",pid=50,fd=8))'
            [[ ! -f $temp/busy ]] || echo 'UNCONN 0 0 0.0.0.0:20042 0.0.0.0:*'
            ;;
        -6) echo 'UNCONN 0 0 *:8443 *:* users:(("xray",pid=40,fd=10)) v6only:0' ;;
        *) return 1 ;;
    esac
}
fake_filter() {
    local file=$1 action rule
    shift
    case $1 in
        --version) echo 'iptables v1.8.9 (nf_tables)'; return ;;
        -w) shift 2 ;;
    esac
    action=$1
    shift
    case $action in
        -S) cat "$file" ;;
        -A)
            echo iptables-add >>"$temp/events"
            [[ ! -e $temp/filter-fail ]] || return 1
            printf '%s\n' "-A $*" >>"$file" ;;
        -D)
            rule="-A $*"
            awk -v rule="$rule" '$0 == rule && !deleted { deleted=1; next } { print } END { exit !deleted }' "$file" >"$file.next" &&
                mv "$file.next" "$file" ;;
        -nvxL) cat "$file" ;;
        *) return 1 ;;
    esac
}
iptables() { fake_filter "$temp/filter4" "$@"; }
ip6tables() { fake_filter "$temp/filter6" "$@"; }

reject() { if "$@"; then printf 'Expected rejection: %s\n' "$*" >&2; exit 1; fi; }
contains() { grep -Fq -- "$2" "$1" || { echo "Missing $2 from $1" >&2; exit 1; }; }
legacy() {
    cat >"$temp/foreign" <<'RULES'
table ip hy2_hop {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport 20000-20100 counter redirect to :443
    }
}
table inet f2b-table {
    chain f2b-chain {
        type filter hook input priority filter - 1; policy accept;
    }
}
RULES
}
# Legacy service with no loaded rules is ambiguous, and a listening socket wins.
reject hy2_probe 4 443 20000 20100
legacy
cp "$temp/foreign" "$temp/foreign.before"
touch "$temp/busy"
reject hy2_probe 4 443 20000 20100
rm "$temp/busy"
reject hy2_probe 4 5300 19000 19100
reject hy2_probe 4 443 20001 20101
reject hy2_probe both 443 20000 20100
hy2_probe 4 443 20000 20100
[[ $HY2_OWNER == legacy ]]

printf '%s\n' '-A INPUT -p tcp --dport 22 -j ACCEPT' '-A INPUT -p tcp -j f2b-sshd' >"$temp/filter4"
cp "$temp/filter4" "$temp/filter4.before"
touch "$temp/enable-fail"
reject hy2_locked hy2_commit put 'hk 4 443 20000 20100 30 legacy'
[[ ! -e $HY2_UNIT_FILE && ! -e $HY2_DIR/nodes.conf ]]
rm "$temp/enable-fail"
# Exercise the interactive defaults and legacy registration.
hy2_wizard >"$temp/wizard" <<'INPUT'
hk
4
443
20000
20100

yes
INPUT
contains "$temp/wizard" '继续由原服务维护'
contains "$temp/wizard" 'hop-interval: 30'
contains "$HY2_DIR/nodes.conf" 'hk 4 443 20000 20100 30 legacy'
contains "$HY2_UNIT_FILE" 'After=nftables.service netfilter-persistent.service portman-restore.service'
contains "$HY2_UNIT_FILE" 'ExecStart=/usr/local/bin/portman hy2 restore'
[[ -e $temp/enabled && ! -s $temp/managed ]]
contains "$temp/filter4" '--dport 443 -m conntrack --ctstate DNAT --ctorigdstport 20000:20100'

# New dual-stack node, no reload on an idempotent restore, and no lost INPUT rules.
hy2_locked hy2_commit put 'test both 8443 21000 21100 45 managed'
contains "$temp/managed" 'table ip6 portman_hy2'
contains "$temp/managed" 'fib daddr type local udp dport 21000-21100 counter redirect to :8443'
contains "$temp/filter6" 'portman-hy2-v1:test'
cp "$temp/events" "$temp/events.before"
cp "$temp/filter4" "$temp/filter4.mixed"
hy2_locked hy2_restore
cmp "$temp/events" "$temp/events.before"
cmp "$temp/filter4" "$temp/filter4.mixed"
reject hy2_locked hy2_commit put 'overlap 4 8443 21099 21200 30 managed'
reject hy2_locked hy2_commit put 'invalid 4 8443 30000 29999 30 managed'

# Existing NAT using inline sets, including target port collisions.
cp "$temp/foreign" "$temp/foreign.legacy"
cat >>"$temp/foreign" <<'RULES'
table inet unrelated_nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport { 8443, 22000-22010 } counter redirect to :10000
    }
}
RULES
reject hy2_probe 4 8443 23000 23100
mv "$temp/foreign.legacy" "$temp/foreign"
cp "$temp/managed" "$temp/managed.before"
cp "$HY2_DIR/nodes.conf" "$temp/config.before"
for failure in check-fail filter-fail apply-fail; do
    touch "$temp/$failure"
    reject hy2_locked hy2_commit put 'test both 8443 23000 23100 60 managed'
    rm "$temp/$failure"
    cmp "$temp/config.before" "$HY2_DIR/nodes.conf"
    cmp "$temp/managed.before" "$temp/managed"
    cmp "$temp/filter4.mixed" "$temp/filter4"
done

# Simulated boot: Portman's ordinary SSH/Fail2Ban rules are restored first.
cp "$temp/filter4.before" "$temp/filter4"
: >"$temp/filter6"
: >"$temp/managed"
hy2_dispatch_main restore
hy2_dispatch_main status >"$temp/status"
contains "$temp/status" 'Portman HY2 开机恢复已启用'
contains "$temp/status" 'table ip hy2_hop'
contains "$temp/status" 'table ip6 portman_hy2'
cp "$temp/filter4" "$HY2_SAVED_IPTABLES/rules.v4"
hy2_locked hy2_restore
cmp "$temp/filter4.before" "$HY2_SAVED_IPTABLES/rules.v4"

hy2_dispatch_main remove test <<<yes
[[ ! -s $temp/managed && ! -s $temp/filter6 ]]
hy2_dispatch_main rollback <<<yes
contains "$temp/managed" 'table ip6 portman_hy2'
hy2_dispatch_main uninstall <<<yes
cmp "$temp/filter4.before" "$temp/filter4"
cmp "$temp/foreign.before" "$temp/foreign"
contains "$HY2_LEGACY_SCRIPT" '# original legacy script'
[[ ! -e $HY2_UNIT_FILE && ! -e $HY2_DIR/nodes.conf && ! -e $HY2_DIR/nodes.conf.bak ]]
[[ ! -e $temp/enabled && ! -s $temp/managed && ! -s $temp/filter6 ]]
echo '[PASS] HY2 向导、冲突检测、旧规则兼容、双栈、重启恢复、幂等、失败回滚与卸载隔离'
