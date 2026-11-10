#!/usr/bin/env bash
# 离线 nftables 回归：模拟 nft 命令，不触碰 runner 的真实防火墙。
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n portman.sh
bash -n nft-backend.sh
# shellcheck source=../portman.sh
source ./portman.sh
# shellcheck source=../nft-backend.sh
source ./nft-backend.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
NFT_STATE_FILE="$work/ports.conf"
NFT_PREVIOUS_FILE="$work/previous.conf"
NFT_PENDING_FILE="$work/pending.conf"
NFT_PENDING_MARK="$work/pending.mark"
nft_cancel_timer() { :; }
fail() { echo "[FAIL] $*" >&2; exit 1; }
assert_contains() { grep -Fq "$2" "$1" || fail "missing: $2"; }

nft() {
    case $1 in
        list)
            case $2 in
                table) test -f "$work/owned";;
                ruleset) echo 'table inet f2b-table { chain input { type filter hook input priority -1; policy accept; } }';;
            esac ;;
        -c)
            [[ $2 == -f ]] && grep -Fq 'table inet portman_filter {' "$3" ;;
        -f)
            cp "$2" "$work/applied"
            touch "$work/owned" ;;
        delete)
            [[ $2 == table && $3 == inet && $4 == portman_filter ]] || fail 'non-owned table deleted'
            rm -f "$work/owned" ;;
        *) fail "unexpected nft command: $*" ;;
    esac
}

cat >"$NFT_STATE_FILE" <<'RULES'
tcp 22
udp 443
tcp 8000-8100
RULES
nft_render "$NFT_STATE_FILE" >"$work/rendered"
assert_contains "$work/rendered" 'type filter hook input priority 0; policy drop;'
assert_contains "$work/rendered" 'ct state established,related accept'
assert_contains "$work/rendered" 'iifname "lo" accept'
assert_contains "$work/rendered" 'meta l4proto ipv6-icmp accept'
assert_contains "$work/rendered" 'tcp dport 22 accept'
assert_contains "$work/rendered" 'udp dport 443 accept'
assert_contains "$work/rendered" 'tcp dport 8000-8100 accept'
if grep -Eq 'flush ruleset|delete table inet f2b-table' "$work/rendered"; then fail 'other rules altered'; fi

printf 'tcp 22; delete table inet f2b-table\n' >"$work/invalid"
if nft_validate_state "$work/invalid" >/dev/null 2>&1; then fail 'untrusted input accepted'; fi
printf 'udp 65536\n' >"$work/invalid"
if nft_validate_state "$work/invalid" >/dev/null 2>&1; then fail 'out-of-range port accepted'; fi

nft_apply "$NFT_STATE_FILE"
assert_contains "$work/applied" 'table inet portman_filter {'
if grep -Fq 'delete table' "$work/applied"; then fail 'first deploy should not delete tables'; fi
nft_apply "$NFT_STATE_FILE"
assert_contains "$work/applied" 'delete table inet portman_filter'
if grep -Fq 'delete table inet f2b-table' "$work/applied"; then fail 'Fail2Ban affected'; fi

nft_open_close open '8443' 'tcp'
assert_contains "$NFT_STATE_FILE" 'tcp 8443'
nft_open_close close '8443' 'tcp'
if grep -Fq 'tcp 8443' "$NFT_STATE_FILE"; then fail 'close did not remove allow'; fi

hits_ssh_port() { echo 22; return 0; }
if nft_close_ports '22' 'tcp' >/dev/null 2>&1; then fail 'SSH port closure allowed'; fi

cp "$NFT_STATE_FILE" "$NFT_PREVIOUS_FILE"
touch "$NFT_PENDING_MARK"
nft_rollback
[[ ! -e $NFT_PENDING_MARK ]] || fail 'rollback marker not removed'
assert_contains "$work/applied" 'tcp dport 22 accept'
echo '[PASS] nft syntax, rule isolation, validation, atomic apply, port open/close, SSH protection and rollback'
