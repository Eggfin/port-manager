#!/usr/bin/env bash
# portman native nftables backend. Own only inet portman_filter, never flush all rules.
NFT_CONFIG_DIR=${PORTMAN_NFT_CONFIG_DIR:-/etc/portman}
NFT_STATE_FILE="$NFT_CONFIG_DIR/nftables-ports.conf"
NFT_PREVIOUS_FILE="$NFT_CONFIG_DIR/nftables-previous.conf"
NFT_PENDING_FILE="$NFT_CONFIG_DIR/nftables-pending.conf"
NFT_PENDING_MARK="$NFT_CONFIG_DIR/nftables-pending.mark"
NFT_SERVICE_FILE=/etc/systemd/system/portman-nftables.service
NFT_SERVICE_NAME=portman-nftables.service
NFT_ROLLBACK_TIMER=portman-nft-rollback.timer
NFT_TABLE=portman_filter

nft_owned() { nft list table inet "$NFT_TABLE" >/dev/null 2>&1; }
nft_require() {
    need_root || return 1
    has nft || { error '未找到 nft，请先安装 nftables'; return 1; }
}

nft_validate_state() {
    local f=$1 proto port lo hi
    [[ -f $f ]] || { error "白名单文件不存在: $f"; return 1; }
    while read -r proto port rest; do
        [[ -z $proto ]] && continue
        if [[ ! $proto =~ ^(tcp|udp)$ || ! $port =~ ^[0-9]{1,5}(-[0-9]{1,5})?$ || -n $rest ]]; then
            error 'nftables 白名单格式无效'; return 1
        fi
        lo=${port%-*}; hi=${port#*-}
        if (( 10#$lo < 1 || 10#$hi > 65535 || 10#$lo > 10#$hi )); then
            error 'nftables 白名单端口超出范围'; return 1
        fi
    done <"$f"
}

nft_render() {
    local f=$1 proto port _
    nft_validate_state "$f" || return 1
    cat <<'RULES'
table inet portman_filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iifname "lo" accept
        ct state established,related accept
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept
RULES
    while read -r proto port _; do
        [[ -n $proto ]] && printf '        %s dport %s accept\n' "$proto" "$port"
    done <"$f"
    printf '    }\n}\n'
}

# Atomic replace of portman's table, not Fail2Ban/other tables.
nft_apply() {
    local f=$1 tmp
    nft_require || return 1
    tmp=$(mktemp) || return 1
    if nft_owned; then printf 'delete table inet %s\n' "$NFT_TABLE" >"$tmp"; fi
    if ! nft_render "$f" >>"$tmp"; then rm -f "$tmp"; return 1; fi
    if ! nft -c -f "$tmp" || ! nft -f "$tmp"; then
        error 'nftables 校验或应用失败，原规则应保持不变'
        rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
}

nft_systemd_ready() { has systemctl && [[ -d /run/systemd/system ]]; }

nft_persist() {
    if ! nft_systemd_ready; then
        error '缺少 systemd，无法保证重启后恢复；拒绝保存高风险防火墙配置'
        return 1
    fi
    cat >"$NFT_SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=portman: restore its own nftables filter table
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH nft-restore

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload && systemctl enable "$NFT_SERVICE_NAME" >/dev/null
}

nft_restore() {
    nft_require || return 1
    [[ -f $NFT_STATE_FILE ]] || return 0
    nft_apply "$NFT_STATE_FILE"
}
nft_cancel_timer() { systemctl stop "$NFT_ROLLBACK_TIMER" >/dev/null 2>&1 || true; }

# Transient systemd timer calls this after 180 seconds if not confirmed.
nft_rollback() {
    nft_require || return 1
    [[ -f $NFT_PENDING_MARK ]] || return 0
    if [[ -f $NFT_PREVIOUS_FILE ]]; then
        nft_apply "$NFT_PREVIOUS_FILE" || { error '自动回滚失败，请通过云控制台检查'; return 1; }
    elif nft_owned; then
        nft delete table inet "$NFT_TABLE" || { error '无法删除临时 portman 规则表'; return 1; }
    fi
    rm -f "$NFT_PENDING_MARK" "$NFT_PENDING_FILE" "$NFT_PREVIOUS_FILE"
    nft_cancel_timer
    info 'nftables 已恢复修改前的 portman 状态，Fail2Ban 未受影响'
}

# Single confirmation, direct commit, and rollback on command/configuration failures.
# Existing SSH connections and detected SSH listening ports are always preserved.
nft_lockdown() {
    nft_require || return 1
    local keep extra ports protos proto port note had_previous=0
    if nft_owned && [[ ! -f $NFT_STATE_FILE ]]; then
        error '已存在同名但不受 portman 管理的规则表，拒绝覆盖'
        return 1
    fi
    if ! nft_systemd_ready; then
        error '缺少可用的 systemd，不能持久化防火墙规则'
        return 1
    fi
    if [[ -f $NFT_PENDING_MARK ]]; then
        error '检测到旧版未完成的回滚状态；为避免覆盖，拒绝执行'
        return 1
    fi

    keep=$(keep_list) || return 1
    echo '将保留以下正在监听的端口和 SSH，其余入站连接默认拒绝：'
    printf '  %-7s %-11s %s\n' 协议 端口 服务
    while read -r proto port note; do
        [[ -n $proto ]] && printf '  %-7s %-11s %s\n' "$proto" "$port" "$note"
    done <<<"$keep"
    echo
    read -rp '额外保留端口 (80,443 / 8000-8100；留空跳过): ' extra
    if [[ -n $extra ]]; then
        ports=$(parse_ports "$extra") || return 1
        read -rp '协议 tcp/udp/both [默认 tcp]: ' protos
        protos=$(parse_proto "${protos:-tcp}") || return 1
        for port in $ports; do
            for proto in $protos; do keep+=$'\n'"$proto $port 手动保留"; done
        done
    fi
    echo
    warn '只管理 inet portman_filter 表；Fail2Ban 的 f2b-table 保持不变。'
    warn '确认后直接生效并保存；请在执行前核对 SSH 和业务端口。'
    confirm_yes '确认应用并保存 nftables 入站白名单？' || { cancelled; return 0; }

    install -d -m 700 "$NFT_CONFIG_DIR" || return 1
    printf '%s\n' "$keep" | awk 'NF >= 2 && !seen[$1 " " $2]++ { print $1, $2 }' >"$NFT_PENDING_FILE"
    chmod 600 "$NFT_PENDING_FILE"
    nft_validate_state "$NFT_PENDING_FILE" || { rm -f "$NFT_PENDING_FILE"; return 1; }
    if [[ -f $NFT_STATE_FILE ]]; then
        cp -p "$NFT_STATE_FILE" "$NFT_PREVIOUS_FILE" || { rm -f "$NFT_PENDING_FILE"; return 1; }
        had_previous=1
    else
        rm -f "$NFT_PREVIOUS_FILE"
    fi
    printf 'pending\n' >"$NFT_PENDING_MARK"
    chmod 600 "$NFT_PENDING_MARK"

    if ! nft_apply "$NFT_PENDING_FILE"; then
        error '应用失败，正在恢复执行前的规则'
        nft_rollback || return 1
        return 1
    fi
    if ! install -m 600 "$NFT_PENDING_FILE" "$NFT_STATE_FILE" || ! nft_persist; then
        error '保存失败，正在恢复执行前的规则'
        if (( had_previous )); then
            cp -p "$NFT_PREVIOUS_FILE" "$NFT_STATE_FILE"
        else
            rm -f "$NFT_STATE_FILE"
        fi
        nft_rollback || return 1
        if (( ! had_previous )); then
            systemctl disable "$NFT_SERVICE_NAME" >/dev/null 2>&1 || true
            rm -f "$NFT_SERVICE_FILE"
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        return 1
    fi

    rm -f "$NFT_PENDING_MARK" "$NFT_PENDING_FILE" "$NFT_PREVIOUS_FILE"
    info 'nftables 白名单已直接生效并保存；Fail2Ban 规则未修改'
    info '如需撤销 portman 白名单，运行 portman unlock'
}

nft_open_close() {
    nft_require || return 1
    local action=$1 ports=$2 protos=$3 proto port tmp changed=0
    if ! nft_owned && [[ ! -f $NFT_STATE_FILE ]]; then
        if [[ $action == open ]]; then
            warn 'portman 的 nftables 白名单尚未启用；当前其他 nftables 规则是否放行须单独核实'
        else
            error '当前没有 portman 白名单可关闭端口；请先执行 portman lockdown'
            return 1
        fi
        return 0
    fi
    if [[ ! -f $NFT_STATE_FILE ]]; then
        error '发现未登记的 portman 规则表；为避免覆盖，拒绝修改'
        return 1
    fi
    if [[ -f $NFT_PENDING_MARK ]]; then error '有待确认的规则操作，暂不允许修改'; return 1; fi
    tmp=$(mktemp) || return 1
    cp "$NFT_STATE_FILE" "$tmp" || { rm -f "$tmp"; return 1; }
    for port in $ports; do
        for proto in $protos; do
            if [[ $action == open ]]; then
                if ! grep -Fxq "$proto $port" "$tmp"; then
                    printf '%s %s\n' "$proto" "$port" >>"$tmp"
                    changed=1
                fi
            else
                if grep -Fxq "$proto $port" "$tmp"; then
                    grep -Fxv "$proto $port" "$tmp" >"$tmp.filtered" || true
                    mv "$tmp.filtered" "$tmp"
                    changed=1
                else
                    warn "未找到精确的 $proto/$port 放行项（范围规则需按完整范围移除）"
                fi
            fi
        done
    done
    if (( changed )); then
        if ! nft_apply "$tmp"; then rm -f "$tmp"; return 1; fi
        install -m 600 "$tmp" "$NFT_STATE_FILE" || {
            error '配置保存失败，正在恢复磁盘中保留的原规则'
            nft_apply "$NFT_STATE_FILE" || true
            rm -f "$tmp"; return 1
        }
        info '已更新 portman nftables 白名单，并保存到磁盘'
    else
        info '规则未发生变化'
    fi
    rm -f "$tmp"
}

nft_close_ports() {
    local ports=$1 protos=$2 sshp
    if sshp=$(hits_ssh_port "$ports"); then
        error "为了防止远程失联，拒绝关闭 SSH 端口 $sshp；请先改用其他 SSH 端口"
        return 1
    fi
    nft_open_close close "$ports" "$protos"
}

nft_unlock() {
    nft_require || return 1
    if ! nft_owned && [[ ! -f $NFT_STATE_FILE ]]; then
        info '没有由 portman 管理的 nftables 限制规则'
        return 0
    fi
    [[ ! -f $NFT_PENDING_MARK ]] || { error '等待规则确认/回滚中，暂不能解锁'; return 1; }
    confirm_yes '仅删除 portman 端口白名单 (不会清除 Fail2Ban)，确认？' || { cancelled; return 0; }
    if nft_owned; then nft delete table inet "$NFT_TABLE" || return 1; fi
    systemctl disable "$NFT_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$NFT_STATE_FILE" "$NFT_SERVICE_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    info 'portman 入站限制已撤销；Fail2Ban 及其他防火墙规则保持原状'
}

nft_status() {
    nft_require || return 1
    if nft_owned; then
        echo 'portman 独立白名单：已启用（入站默认拒绝）'
        if [[ -f $NFT_STATE_FILE ]]; then
            echo 'portman 已登记的放行规则：'
            sed 's/^/  /' "$NFT_STATE_FILE"
        else
            warn '检测到运行中的规则，但没有对应的持久化配置！'
        fi
        if systemctl is-enabled "$NFT_SERVICE_NAME" >/dev/null 2>&1; then
            echo '开机恢复：已启用'
        else
            warn '开机恢复：未启用'
        fi
    else
        echo 'portman 白名单：未启用；无法仅凭本模块判断其他表是否允许入站'
    fi
    echo '完整原生 nftables 规则 (包括 Fail2Ban)：'
    nft -a list ruleset
}

nft_dispatch_main() {
    case $1 in
        lockdown) nft_lockdown ;;
        unlock) nft_unlock ;;
        open) nft_open_close open "$2" "$3" ;;
        close) nft_close_ports "$2" "$3" ;;
        status) nft_status ;;
        restore) nft_restore ;;
        rollback) nft_rollback ;;
        *) error '未知 nftables 子命令'; return 1 ;;
    esac
}
