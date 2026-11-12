#!/usr/bin/env bash
# Loaded by portman.sh. Records are data: name family listen first last interval owner.
HY2_DIR=/etc/portman/hy2
HY2_UNIT=portman-hy2.service
HY2_UNIT_FILE=/etc/systemd/system/$HY2_UNIT
HY2_LOCK=/run/lock/portman-hy2.lock
HY2_SAVED_IPTABLES=/etc/iptables
HY2_TABLE=portman_hy2
HY2_MARK='portman-hy2-v1'
HY2_LEGACY_SCRIPT=/usr/local/sbin/hy2-hop-restore.sh

hy2_require() {
    need_root || return 1
    local cmd
    for cmd in nft flock systemctl; do
        has "$cmd" || { error "缺少 ${cmd}，请安装 nftables / util-linux 并使用 systemd"; return 1; }
    done
}

hy2_locked() (
    umask 077
    exec 9>"$HY2_LOCK" && flock -x 9 || return 1
    "$@"
)

hy2_name() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; }
hy2_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
hy2_interval() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 >= 5 && $1 <= 86400 )); }

hy2_validate() {
    local name family listen first last interval owner extra
    while read -r name family listen first last interval owner extra || [[ -n $name ]]; do
        if ! hy2_name "$name" || [[ ! $family =~ ^(4|6|both)$ || ! $owner =~ ^(managed|legacy)$ || -n $extra ]] ||
           ! hy2_port "$listen" || ! hy2_port "$first" || ! hy2_port "$last" ||
           ! hy2_interval "$interval" || (( first >= last || (listen >= first && listen <= last) )); then
            error "HY2 配置格式无效或范围包含监听端口 ($name)"
            return 1
        fi
    done <"$1"
    awk '
        {
            for (i = 1; i < NR; i++) {
                if ($1 == name[i] || (($2 == family[i] || $2 == "both" || family[i] == "both") &&
                    (($4 <= last[i] && $5 >= first[i]) || ($3 >= first[i] && $3 <= last[i]) ||
                     (listen[i] >= $4 && listen[i] <= $5)))) {
                    printf "[错误] HY2 节点 %s 与 %s 的端口配置冲突\n", $1, name[i] > "/dev/stderr"
                    exit 1
                }
            }
            name[NR]=$1; family[NR]=$2; listen[NR]=$3+0; first[NR]=$4+0; last[NR]=$5+0
        }
    ' "$1"
}

hy2_table() {
    awk -v family="$1" -v name="$2" '
        $1 == "table" { active = ($2 == family && $3 == name) }
        active && NF { sub(/^[[:space:]]+/, ""); print }
    '
}

hy2_has_legacy_service() {
    [[ -e $HY2_LEGACY_SCRIPT ]] ||
        [[ $(systemctl show -p LoadState --value hy2-hop.service 2>/dev/null) =~ ^(loaded|masked|error|bad-setting)$ ]]
}

# Check explicit numeric UDP ranges and inline sets. Opaque destination NAT is
# treated as a potential conflict. A known legacy rule must match exactly.
hy2_check_nat() {
    local rules=$1 family=$2 listen=$3 first=$4 last=$5
    awk -v fam="$family" -v dst="$listen" -v lo="$first" -v hi="$last" -v own="$HY2_TABLE" '
        function conflict() {
            printf "[错误] 已有或无法判断的 NAT 规则 (%s %s): %s\n", family, table, $0 > "/dev/stderr"
            failed = 1
        }
        function overlaps(a,b) { return (a <= hi && b >= lo) || (a <= dst && b >= dst) }
        $1 == "table" { family=$2; table=$3; hook=""; next }
        $1 == "chain" { hook=""; next }
        $1 == "type" && $3 == "hook" { hook=$4; sub(/;$/, "", hook) }
        family != fam && family != "inet" { next }
        table == own && family == fam { next }
        hook != "" && hook != "prerouting" { next }
        {
            # Remove trailing comments before interpreting the rule text.
            sub(/[[:space:]]+comment[[:space:]]+".*$/, "")
            if ($0 !~ /(^|[[:space:]])(dnat|redirect|vmap|DNAT|REDIRECT)([[:space:]]|$)/) next
            if ($0 ~ /(^|[[:space:]])tcp dport[[:space:]]/ && $0 !~ /vmap/) next
            if (!match($0, /(^|[[:space:]])udp dport[[:space:]]+/)) { conflict(); next }
            value=substr($0, RSTART+RLENGTH)
            if (value ~ /^\{/) {
                if (!match(value, /^\{[[:space:]0-9,-]+\}[[:space:]]/)) { conflict(); next }
                value=substr(value, 2, RLENGTH-3)
                gsub(/[[:space:]]/, "", value)
            } else {
                if (!match(value, /^[0-9]+(-[0-9]+)?[[:space:]]/)) { conflict(); next }
                value=substr(value, 1, RLENGTH-1)
            }
            n=split(value, ranges, ",")
            for (i=1; i<=n; i++) {
                m=split(ranges[i], ports, "-")
                if (!overlaps(ports[1]+0, (m==2 ? ports[2] : ports[1])+0)) continue
                expected="udp dport " lo "-" hi " counter redirect to :" dst
                line=$0
                sub(/^[[:space:]]+/, "", line)
                if (family==fam && table=="hy2_hop" && hook=="prerouting" && line==expected) exact++
                else conflict()
            }
        }
        END {
            if (failed || exact > 1) exit 2
            if (exact == 1) print "legacy"
            else print "managed"
        }
    ' <<<"$rules"
}

hy2_nat_plan() {
    local config=$1 rules=$2 family=$3 number existing expected name scope listen first last interval owner mode
    [[ $family == ip ]] && number=4 || number=6
    existing=$(hy2_table "$family" "$HY2_TABLE" <<<"$rules") || return 1
    if [[ -n $existing ]] && ! grep -Fxq "comment \"$HY2_MARK\"" <<<"$existing"; then
        error "发现未标记的同名 nftables 表 $family $HY2_TABLE"
        return 1
    fi
    expected=$(
        printf 'table %s %s {\ncomment "%s"\nchain prerouting {\ntype nat hook prerouting priority dstnat; policy accept;\n' "$family" "$HY2_TABLE" "$HY2_MARK"
        while read -r name scope listen first last interval owner; do
            [[ $scope == "$number" || $scope == both ]] || continue
            mode=$(hy2_check_nat "$rules" "$family" "$listen" "$first" "$last") || exit 1
            if [[ $owner == managed && $mode == legacy ]]; then
                error "$name 已有手工 NAT 规则，请重新运行向导登记"
                exit 1
            fi
            if [[ $owner == legacy ]]; then
                if [[ $mode != legacy ]]; then
                    error "$name 的手工 NAT 未加载或已改变，请检查 hy2-hop.service"
                    exit 1
                fi
                continue
            fi
            printf 'fib daddr type local udp dport %s-%s counter redirect to :%s comment "%s:%s"\n' "$first" "$last" "$listen" "$HY2_MARK" "$name"
        done <"$config"
        printf '}\n}\n'
    ) || return 1

    # Match nft's stateless output, which omits counter values. No-op restores
    # preserve counters and do not replace an already correct table.
    [[ $expected == *'fib daddr '* ]] || expected=''
    [[ $existing == "$expected" ]] && return 0
    [[ -z $existing ]] || printf 'delete table %s %s\n' "$family" "$HY2_TABLE"
    [[ -z $expected ]] || printf '%s\n' "$expected"
}

hy2_iptables_nft() { has "$1" && [[ $("$1" --version 2>/dev/null) == *nf_tables* ]]; }

hy2_filter_rule() {
    local cmd=$1 action=$2 listen=$3 range=$4 name=$5
    "$cmd" -w 5 "$action" INPUT -p udp -m udp --dport "$listen" -m conntrack \
        --ctstate DNAT --ctorigdstport "$range" --ctdir ORIGINAL \
        -m comment --comment "$HY2_MARK:$name" -j ACCEPT
}

hy2_filter_read() {
    local cmd=$1 family=$2 rules
    rules=$("$cmd" -w 5 -S INPUT) || return 1
    awk -v family="$family" -v marker="$HY2_MARK:" '
        $1=="-A" && $2=="INPUT" && /-j ACCEPT$/ {
            listen=range=name=""
            for (i=3; i<NF; i++) {
                if ($i=="--dport") listen=$(i+1)
                if ($i=="--ctorigdstport") range=$(i+1)
                if ($i=="--comment") {
                    name=$(i+1); gsub(/"/,"",name)
                    if (index(name,marker)==1) name=substr(name,length(marker)+1)
                    else name=""
                }
            }
            if (name ~ /^[a-zA-Z0-9_-]+$/ && listen ~ /^[0-9]+$/ && range ~ /^[0-9]+:[0-9]+$/)
                print family, listen, range, name
        }
    ' <<<"$rules"
}

# Portman and netfilter-persistent may otherwise save runtime rules into
# rules.v4/v6. Remove only our tagged entries from these snapshots.
hy2_clean_saved() {
    local file tmp
    for file in "$HY2_SAVED_IPTABLES"/rules.v{4,6}; do
        [[ -f $file && ! -L $file ]] || continue
        grep -Eq -- "^-A INPUT .*--comment \"?$HY2_MARK:[a-zA-Z0-9_-]+\"? -j ACCEPT$" "$file" || continue
        tmp=$(mktemp "${file}.portman.XXXXXX") || return 1
        if ! cp -p "$file" "$tmp" ||
           ! sed -E "/^-A INPUT .*--comment \"?$HY2_MARK:[a-zA-Z0-9_-]+\"? -j ACCEPT\$/d" "$file" >"$tmp" ||
           ! mv -f "$tmp" "$file"; then
            rm -f "$tmp"
            return 1
        fi
    done
}

hy2_save_iptables() {
    netfilter-persistent save >/dev/null 2>&1
    hy2_clean_saved || warn '清理持久化快照中的 HY2 模块规则失败，请运行 portman hy2 repair'
}

hy2_filter_undo() {
    local change family listen range name cmd rc=0
    while read -r change family listen range name; do
        [[ -n $change ]] || continue
        [[ $family == 4 ]] && cmd=iptables || cmd=ip6tables
        hy2_filter_rule "$cmd" "$change" "$listen" "$range" "$name" || rc=1
    done <<<"$1"
    return "$rc"
}

hy2_apply() (
    local config=$1 rules tmp old='' desired='' undo='' family cmd name scope listen first last interval owner row
    hy2_validate "$config" || return 1
    rules=$(LC_ALL=C nft -s list ruleset) || return 1
    tmp=$(mktemp) || return 1
    trap 'rm -f "$tmp"' EXIT
    hy2_nat_plan "$config" "$rules" ip >"$tmp" &&
        hy2_nat_plan "$config" "$rules" ip6 >>"$tmp" || return 1
    if [[ -s $tmp ]]; then nft -c -f "$tmp" || return 1; fi

    for family in 4 6; do
        [[ $family == 4 ]] && cmd=iptables || cmd=ip6tables
        hy2_iptables_nft "$cmd" || continue
        old+=$(hy2_filter_read "$cmd" "$family") || return 1
        old+=$'\n'
        [[ $(detect_firewall) == iptables ]] || continue
        while read -r name scope listen first last interval owner; do
            [[ $scope == "$family" || $scope == both ]] || continue
            desired+="$family $listen $first:$last $name"$'\n'
        done <"$config"
    done
    hy2_clean_saved || return 1

    # Append after current jumps/rejects so we do not bypass Fail2Ban or other
    # explicit INPUT policy. Apply new allowances before publishing the NAT.
    while read -r family listen row name; do
        [[ -n $family ]] || continue
        [[ $family == 4 ]] && cmd=iptables || cmd=ip6tables
        if ! hy2_filter_rule "$cmd" -A "$listen" "$row" "$name"; then
            hy2_filter_undo "$undo" || error '部分 INPUT 规则回滚失败，请检查状态'
            return 1
        fi
        undo="-D $family $listen $row $name"$'\n'"$undo"
    done < <(comm -23 <(sed '/^$/d' <<<"$desired" | LC_ALL=C sort) <(sed '/^$/d' <<<"$old" | LC_ALL=C sort))

    while read -r family listen row name; do
        [[ -n $family ]] || continue
        [[ $family == 4 ]] && cmd=iptables || cmd=ip6tables
        if ! hy2_filter_rule "$cmd" -D "$listen" "$row" "$name"; then
            hy2_filter_undo "$undo" || error '部分 INPUT 规则回滚失败，请检查状态'
            return 1
        fi
        undo="-A $family $listen $row $name"$'\n'"$undo"
    done < <(comm -13 <(sed '/^$/d' <<<"$desired" | LC_ALL=C sort) <(sed '/^$/d' <<<"$old" | LC_ALL=C sort))

    if [[ -s $tmp ]] && ! nft -f "$tmp"; then
        hy2_filter_undo "$undo" || error '部分 INPUT 规则回滚失败，请检查状态'
        return 1
    fi
)

hy2_unit_text() {
    cat <<UNIT
# $HY2_MARK
[Unit]
Description=Portman HY2 port hopping
After=nftables.service netfilter-persistent.service portman-restore.service portman-nftables.service hy2-hop.service firewalld.service ufw.service

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH hy2 restore

[Install]
WantedBy=multi-user.target
UNIT
}

hy2_unit_owned() { [[ ! -L $HY2_UNIT_FILE ]] && grep -Fxq "# $HY2_MARK" "$HY2_UNIT_FILE"; }

hy2_enable() {
    if [[ -e $HY2_UNIT_FILE || -L $HY2_UNIT_FILE ]]; then
        hy2_unit_owned || { error "发现同名的非 Portman 服务 $HY2_UNIT"; return 1; }
    else
        (umask 022; set -o noclobber; hy2_unit_text >"$HY2_UNIT_FILE") || return 1
        if ! systemctl daemon-reload; then
            rm -f "$HY2_UNIT_FILE"
            return 1
        fi
    fi
    systemctl enable "$HY2_UNIT" >/dev/null
}

hy2_commit() (
    local action=$1 arg=${2:-} prev=$HY2_DIR/nodes.conf candidate original new_unit=0
    local name family listen first last interval owner
    if [[ $action == reset && ( -e $HY2_UNIT_FILE || -L $HY2_UNIT_FILE ) ]] && ! hy2_unit_owned; then
        error "发现同名的非 Portman 服务 $HY2_UNIT"
        return 1
    fi
    install -d -m 700 "$HY2_DIR" || return 1
    local tmp
    tmp=$(mktemp -d "$HY2_DIR/.apply.XXXXXX") || return 1
    trap 'rm -rf "$tmp"; if [[ $action == reset ]]; then rmdir "$HY2_DIR" 2>/dev/null || true; fi' EXIT
    candidate=$tmp/next; original=$tmp/previous
    if [[ -f $prev ]]; then cat "$prev" >"$original" || return 1; else : >"$original"; fi
    case $action in
        put)
            read -r name family listen first last interval owner <<<"$arg"
            hy2_probe "$family" "$listen" "$first" "$last" || return 1
            [[ $HY2_OWNER == "$owner" ]] || { error 'NAT 状态已变化，请重新运行向导'; return 1; }
            awk -v name="$name" '$1 != name' "$original" >"$candidate" &&
                printf '%s\n' "$arg" >>"$candidate" || return 1 ;;
        remove)
            awk -v name="$arg" '$1 == name { found=1; next } { print } END { if (!found) exit 1 }' \
                "$original" >"$candidate" || { error "节点不存在: $arg"; return 1; } ;;
        rollback)
            [[ -f $prev.bak ]] || { error '没有可回滚的配置'; return 1; }
            cat "$prev.bak" >"$candidate" || return 1 ;;
        reset) : >"$candidate" ;;
        *) return 1 ;;
    esac
    hy2_validate "$candidate" || return 1
    if [[ $action != reset ]]; then
        [[ -e $HY2_UNIT_FILE || -L $HY2_UNIT_FILE ]] || new_unit=1
        if ! hy2_enable; then
            if (( new_unit )) && hy2_unit_owned; then hy2_disable || true; fi
            return 1
        fi
    fi
    if ! hy2_apply "$candidate"; then
        if (( new_unit )) && hy2_unit_owned; then hy2_disable || true; fi
        return 1
    fi
    if [[ $action != reset ]] && ! cmp -s "$candidate" "$original"; then
        if ! cp "$original" "$tmp/backup" || ! mv -f "$tmp/backup" "$prev.bak" ||
           ! mv -f "$candidate" "$prev"; then
            error '配置写入失败，正在恢复上一版规则'
            hy2_apply "$original" || error '运行规则回滚失败，请检查 portman hy2 status'
            if (( new_unit )); then hy2_disable || true; fi
            return 1
        fi
    fi
    if [[ $action == reset ]]; then
        # Commit the empty state before disabling the service. A retry cannot
        # recreate old runtime rules if systemctl disable fails.
        mv -f "$candidate" "$prev" && hy2_disable || return 1
        rm -f "$prev" "$prev.bak" || return 1
    fi
    info 'HY2 配置操作已完成'
)

hy2_disable() {
    [[ -e $HY2_UNIT_FILE || -L $HY2_UNIT_FILE ]] || return 0
    hy2_unit_owned || { error "发现同名的非 Portman 服务 $HY2_UNIT"; return 1; }
    systemctl disable "$HY2_UNIT" >/dev/null && rm -f "$HY2_UNIT_FILE" && systemctl daemon-reload
}

hy2_restore() {
    [[ -f $HY2_DIR/nodes.conf ]] || return 0
    hy2_apply "$HY2_DIR/nodes.conf"
}

# ss prints a netid column with some versions/options. Normalize either layout.
hy2_sockets() {
    local family=$1 output
    output=$(ss "-$family" -H -ulnpe) || return 1
    awk '{
        column=($1=="udp" ? 5 : 4)
        address=$column; port=address
        sub(/^.*:/,"",port); sub(/:[^:]*$/,"",address)
        if (port ~ /^[0-9]+$/) print port, address, substr($0,index($0,$(column+1)))
    }' <<<"$output"
}

hy2_probe() {
    local scope=$1 listen=$2 first=$3 last=$4 rules sockets family number mode selected='' other
    has ss || { error '缺少 ss，请安装 iproute2'; return 1; }
    rules=$(LC_ALL=C nft -s list ruleset) || return 1
    for number in 4 6; do
        [[ $scope == "$number" || $scope == both ]] || continue
        [[ $number == 4 ]] && family=ip || family=ip6
        mode=$(hy2_check_nat "$rules" "$family" "$listen" "$first" "$last") || return 1
        if [[ -n $selected && $selected != "$mode" ]]; then
            error '两种地址族的 NAT 所属不同，请分别登记为两个节点'
            return 1
        fi
        selected=$mode
        sockets=$(hy2_sockets "$number") || return 1
        if [[ $number == 4 ]]; then
            other=$(hy2_sockets 6) || return 1
            sockets+=$'\n'$(awk '/v6only:0([[:space:]]|$)/ && ($2=="*" || $2=="[::]")' <<<"$other")
        fi
        if ! awk -v p="$listen" '$1==p && $2 !~ /^(127\.|\[?::1\]?$|\[?::ffff:127\.)/ { seen=1 } END { exit !seen }' <<<"$sockets"; then
            error "IPv$number 未发现可接收外部流量的 UDP $listen 监听，请先确认 HY2 入站"
            return 1
        fi
        if awk -v a="$first" -v b="$last" '$1>=a && $1<=b { print "  UDP", $0; busy=1 } END { exit !busy }' <<<"$sockets"; then
            error "IPv$number 跳跃范围与已监听的 UDP 端口冲突"
            return 1
        fi
    done
    if [[ $selected == managed ]] && hy2_has_legacy_service &&
       ! grep -Eq '^table (ip|ip6|inet) hy2_hop \{' <<<"$rules"; then
        error '发现手工恢复服务或脚本，但当前没有 hy2_hop 表，无法判断开机时是否冲突'
        return 1
    fi
    HY2_OWNER=$selected
}

hy2_examples() {
    local selected=${1:-} name family listen first last interval owner found=0
    if [[ -f $HY2_DIR/nodes.conf ]]; then
        while read -r name family listen first last interval owner; do
            [[ -z $selected || $selected == "$name" ]] || continue
            found=1
            cat <<EXAMPLE
[$name] 3x-ui / Xray
  HY2 入站保持 UDP ${listen}。客户端跳跃范围填写 $first-${last}。
  面板的 UDP Hop / Hop Ports 若仅用于导出客户端，可填同一范围。
  若当前版本会自行绑定跳跃端口或写 NAT，请只保留一种跳跃实现。

[$name] Mihomo / Sub-Store（合并到已导出的 HY2 节点，保留认证和 TLS 参数）
  type: hysteria2
  port: $listen
  ports: "$first-$last"
  hop-interval: $interval

  云安全组 (IP 族: $family)：允许入站 UDP $first-${last}。
  若有使用固定端口的客户端，也放行 UDP ${listen}。
EXAMPLE
        done <"$HY2_DIR/nodes.conf"
    fi
    (( found )) || { error '没有匹配的 HY2 节点'; return 1; }
}

hy2_firewall_hint() {
    local backend cmd
    backend=$(detect_firewall)
    printf '入站防火墙: %s\n' "$(firewall_name "$backend")"
    if [[ $backend == iptables ]]; then
        for cmd in iptables ip6tables; do
            hy2_iptables_nft "$cmd" || { warn "$cmd 未使用 nf_tables，该地址族需手工放行"; continue; }
            printf '%s: 只在 INPUT 末尾放行匹配目标端口和原始跳跃范围的 DNAT 流量。\n' "$cmd"
            printf '  更早的 DROP/REJECT、其他 nftables 链及云安全组仍可拦截。\n'
        done
    else
        warn '请在当前防火墙放行重定向后的 UDP 监听端口。Portman 原生 nftables 白名单可用 portman open <监听端口> udp。'
    fi
}

hy2_status() {
    local rules family cmd table
    rules=$(nft list ruleset) || return 1
    if [[ -s $HY2_DIR/nodes.conf ]]; then
        echo '节点（名称 地址族 监听 起始 结束 间隔 所属）'
        sed 's/^/  /' "$HY2_DIR/nodes.conf"
    else
        echo '尚未登记 HY2 节点'
    fi
    if systemctl is-enabled "$HY2_UNIT" >/dev/null 2>&1; then
        echo 'Portman HY2 开机恢复已启用'
        systemctl show "$HY2_UNIT" -p ActiveState -p Result
    fi
    if hy2_has_legacy_service; then
        echo '发现手工 hy2-hop.service 或恢复脚本'
        systemctl show hy2-hop.service -p LoadState -p UnitFileState -p ActiveState -p Result
    fi
    for family in ip ip6 inet; do
        for table in "$HY2_TABLE" hy2_hop; do
            hy2_table "$family" "$table" <<<"$rules"
        done
    done
    hy2_firewall_hint
    for cmd in iptables ip6tables; do
        if hy2_iptables_nft "$cmd"; then
            "$cmd" -w 5 -nvxL INPUT | awk -v tag="$HY2_MARK:" 'index($0,tag)'
        fi
    done
    if has ss; then
        for family in 4 6; do
            printf '\nIPv%s UDP 监听\n' "$family"
            hy2_sockets "$family"
        done
    fi
    echo '用外部客户端连接并等待跳跃，再对照 NAT packets、INPUT 计数和客户端连通性。'
}

hy2_wizard() {
    local name family listen first last interval old_family=4 old_listen= old_first= old_last= old_interval=30
    local sockets candidates
    read -rp '节点名称（同名更新）: ' name || return 1
    hy2_name "$name" || { error '名称须为 1–32 位字母、数字、连字符或下划线，首位为字母或数字'; return 1; }
    if [[ -f $HY2_DIR/nodes.conf ]]; then
        read -r _ old_family old_listen old_first old_last old_interval _ \
            < <(awk -v name="$name" '$1==name { print; exit }' "$HY2_DIR/nodes.conf")
    fi
    old_family=${old_family:-4}
    read -rp "地址族 4 / 6 / both [$old_family]: " family || return 1
    family=${family:-$old_family}
    [[ $family =~ ^(4|6|both)$ ]] || { error '请输入 4、6 或 both'; return 1; }
    has ss || { error '缺少 ss，请安装 iproute2'; return 1; }
    sockets=$(hy2_sockets 4) || return 1
    local sockets6
    sockets6=$(hy2_sockets 6) || return 1
    sockets+=$'\n'"$sockets6"
    echo '检测到的 UDP 监听（根据进程提示选择 3x-ui/Xray 或 Hysteria2 入站）'
    printf '%s\n' "$sockets"
    candidates=$(awk 'tolower($0) ~ /xray|hysteria/ && !seen[$1]++ { print $1 }' <<<"$sockets")
    if [[ -z $old_listen && -n $candidates && $candidates != *$'\n'* ]]; then old_listen=$candidates; fi
    read -rp "HY2 UDP 监听端口${old_listen:+ [$old_listen]}: " listen || return 1
    listen=${listen:-$old_listen}
    hy2_port "$listen" || { error '监听端口须为 1–65535 的整数'; return 1; }
    read -rp "UDP 跳跃起始端口${old_first:+ [$old_first]}: " first || return 1
    first=${first:-$old_first}
    hy2_port "$first" || { error '起始端口须为 1–65535 的整数'; return 1; }
    read -rp "UDP 跳跃结束端口${old_last:+ [$old_last]}: " last || return 1
    last=${last:-$old_last}
    if ! hy2_port "$last" || (( first >= last || (listen >= first && listen <= last) )); then
        error '结束端口须大于起始端口且不超过 65535，范围不得包含监听端口'
        return 1
    fi
    read -rp "客户端跳跃间隔，秒 [${old_interval:-30}]: " interval || return 1
    interval=${interval:-${old_interval:-30}}
    hy2_interval "$interval" || { error '跳跃间隔须为 5–86400 秒的整数'; return 1; }
    hy2_probe "$family" "$listen" "$first" "$last" || return 1
    if [[ $HY2_OWNER == legacy ]]; then
        info '发现完全匹配的手工 hy2_hop 规则，将继续由原服务维护 NAT'
        if ! systemctl is-enabled hy2-hop.service >/dev/null 2>&1; then
            warn '请确认手工 NAT 已设置开机恢复；Portman 仅登记该规则'
        fi
    fi
    printf '\n%s · IPv%s · UDP %s-%s → %s · 客户端 %ss\n' "$name" "$family" "$first" "$last" "$listen" "$interval"
    hy2_firewall_hint
    warn "请在云安全组放行入站 UDP $first-${last}；有固定端口客户端时还需放行 UDP $listen"
    confirm_yes '应用并设置开机恢复？' || { cancelled; return 0; }
    hy2_locked hy2_commit put "$name $family $listen $first $last $interval $HY2_OWNER" &&
        hy2_examples "$name"
}

hy2_repair() {
    [[ -f $HY2_DIR/nodes.conf ]] || { error '没有已保存的 HY2 配置'; return 1; }
    hy2_enable && hy2_restore && info '已重新校验并应用 HY2 配置'
}

hy2_menu() {
    local choice name
    while true; do
        printf '\nHY2 端口跳跃管理\n  1. 新增 / 更新节点\n  2. 状态 / 命中诊断\n  3. 客户端配置示例\n  4. 修复 / 重新应用\n  5. 回滚上一版配置\n  6. 移除节点\n  7. 卸载 HY2 配置\n  0. 返回\n'
        read -rp '请选择: ' choice || return 0
        case $choice in
            1) hy2_wizard ;;
            2) hy2_status ;;
            3) hy2_examples ;;
            4) hy2_locked hy2_repair ;;
            5) hy2_dispatch_main rollback ;;
            6) read -rp '要移除的节点名: ' name || return 0
               hy2_dispatch_main remove "$name" ;;
            7) hy2_dispatch_main uninstall ;;
            0|q) return 0 ;;
            *) error '无效选择' ;;
        esac
    done
}

hy2_dispatch_main() {
    local action=${1:-menu} name=${2:-}
    case $action in
        help|-h|--help)
            echo '用法: portman hy2 [menu|status|examples [节点]|repair|rollback|remove 节点|uninstall]'
            return 0 ;;
    esac
    hy2_require || return 1
    case $action in
        menu) hy2_menu ;;
        status) hy2_locked hy2_status ;;
        examples) hy2_examples "$name" ;;
        restore) hy2_locked hy2_restore ;;
        repair) hy2_locked hy2_repair ;;
        rollback) confirm_yes '应用上一版 HY2 配置？' && hy2_locked hy2_commit rollback ;;
        remove)
            hy2_name "$name" || { error '请输入有效节点名'; return 1; }
            confirm_yes "移除 HY2 节点 ${name}？" && hy2_locked hy2_commit remove "$name" ;;
        uninstall)
            confirm_yes '删除 Portman HY2 节点、备份和开机服务？' && hy2_locked hy2_commit reset ;;
        *) error "未知 HY2 命令: $action"; return 1 ;;
    esac
}
