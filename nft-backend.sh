#!/usr/bin/env bash
# portman native nftables backend. Own only inet portman_filter, never flush all rules.
NFT_STATE_FILE=/etc/portman/nftables-ports.conf
NFT_PREVIOUS_FILE=/etc/portman/nftables-previous.conf
NFT_PENDING_FILE=/etc/portman/nftables-pending.conf
NFT_PENDING_MARK=/etc/portman/nftables-pending.mark
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

nft_persist() {
    if ! has systemctl || [[ ! -d /run/systemd/system ]]; then
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

nft_lockdown() {
    nft_require || return 1
    local keep extra ports protos proto port note
    if nft_owned && [[ ! -f $NFT_STATE_FILE ]]; then
        error '已存在同名但不受 portman 管理的规则表，拒绝覆盖'
        return 1
    fi
    if [[ ! -d /run/systemd/system ]] || ! has systemd-run || ! has systemctl; then
        error '此操作需要 systemd-run 自动回滚支持，以防 SSH 失联'
        return 1
    fi
    if [[ -f $NFT_PENDING_MARK ]]; then
        error '上一次 nftables 修改尚未完成确认，请先处理回滚状态'
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
    warn '只管理 inet portman_filter 表；Fail2Ban 的 f2b-table 完全保留。'
    warn '配置应用后 180 秒内必须验证另一 SSH 登录并输入 yes，否则自动回滚。'
    confirm_yes '确定启用 nftables 入站白名单？' || { cancelled; return 0; }

    install -d -m 700 /etc/portman || return 1
    printf '%s\n' "$keep" | awk 'NF >= 2 && !seen[$1 " " $2]++ { print $1, $2 }' >"$NFT_PENDING_FILE"
    chmod 600 "$NFT_PENDING_FILE"
    nft_validate_state "$NFT_PENDING_FILE" || { rm -f "$NFT_PENDING_FILE"; return 1; }
    if [[ -f $NFT_STATE_FILE ]]; then
        cp -p "$NFT_STATE_FILE" "$NFT_PREVIOUS_FILE" || return 1
    else
        rm -f "$NFT_PREVIOUS_FILE"
    fi
    printf 'pending\n' >"$NFT_PENDING_MARK"
    chmod 600 "$NFT_PENDING_MARK"

    if ! systemd-run --quiet --unit=portman-nft-rollback --on-active=180s "$INSTALL_PATH" nft-rollback; then
        error '无法启动自动回滚定时器，未应用新规则'
        rm -f "$NFT_PENDING_MARK" "$NFT_PENDING_FILE" "$NFT_PREVIOUS_FILE"
        return 1
    fi
    if ! nft_apply "$NFT_PENDING_FILE"; then
        nft_rollback
        return 1
    fi
    echo
    warn '临时规则已应用！请立刻在另一 SSH 窗口验证能否重新登录。'
    if ! confirm_yes '验证成功后，输入 yes 保存；否则回滚'; then
        nft_rollback
        return 1
    fi
    if [[ ! -f $NFT_PENDING_MARK ]]; then
        error '自动回滚已经发生，请重新执行 lockdown'
        return 1
    fi
    nft_cancel_timer
    if [[ ! -f $NFT_PENDING_MARK ]]; then
        error '自动回滚已发生；不会保存失效的配置'
        return 1
    fi
    if ! install -m 600 "$NFT_PENDING_FILE" "$NFT_STATE_FILE" || ! nft_persist; then
        error '持久化失败，正在恢复旧配置'
        if [[ -f $NFT_PREVIOUS_FILE ]]; then
            cp -p "$NFT_PREVIOUS_FILE" "$NFT_STATE_FILE"
        else
            rm -f "$NFT_STATE_FILE"
        fi
        nft_rollback
        return 1
    fi
    rm -f "$NFT_PENDING_MARK" "$NFT_PENDING_FILE" "$NFT_PREVIOUS_FILE"
    info 'nftables 白名单已保存并启用开机恢复；Fail2Ban 规则未修改'
}

