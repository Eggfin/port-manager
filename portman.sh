#!/usr/bin/env bash
#
# portman - VPS 端口查看与管理工具
#   查看监听端口、协议类型、占用进程、防火墙放行状态，并可放行/关闭指定端口；
#   附带 IPv6 开关、SSH 密钥登录管理和三网路由检测 (route-report.sh 模块)。
#
# 仓库: https://github.com/Eggfin/port-manager
#
# 目录:
#   1. 配置与通用函数
#   2. 端口采集、防火墙识别与端口表
#   3. 防火墙操作: iptables 持久化、放行 / 关闭、一键关闭其他端口
#   4. IPv4 / IPv6
#   5. SSH: 密钥登录、登录记录、公钥管理、安全加固
#   6. 安装维护: 快捷键、更新、卸载、路由模块
#   7. 菜单与命令行

# ===========================================================================
# 1. 配置与通用函数
# ===========================================================================
VERSION="1.7.4"
REPO="Eggfin/port-manager"
RAW_URL="https://raw.githubusercontent.com/${REPO}/main"

# 安装位置
INSTALL_PATH="/usr/local/bin/portman"
BIN_DIR="/usr/local/bin"
ROUTE_MODULE="/usr/local/lib/portman/route-report.sh"
NFT_MODULE="/usr/local/lib/portman/nft-backend.sh"
SHORTCUTS="s S"

# iptables 规则持久化: portman 添加的规则记录在 STATE_FILE，开机由 systemd 服务恢复
STATE_FILE="/etc/portman/iptables.conf"
SERVICE_NAME="portman-restore.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

# IPv6 开关: 文件名以 99-zz 开头，排在 99-sysctl.conf 之后，不会被系统默认配置覆盖
SYSCTL_FILE="/etc/sysctl.d/99-zz-portman-ipv6.conf"

# SSH 配置
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DIR="/etc/ssh/sshd_config.d"
KEY_ONLY_FILE="$SSHD_DIR/00-key-only.conf"
PASSWORD_FILE="$SSHD_DIR/00-password-login.conf"
SSHD_MARK_BEGIN="# >>> portman ssh >>>"
SSHD_MARK_END="# <<< portman ssh <<<"
SSH_CONF="/etc/portman/ssh.conf"
KEY_RE='^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/]+=*( |$)'

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    CYAN=$'\033[36m'; BOLD=$'\033[1m'; PLAIN=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; PLAIN=""
fi

info()  { printf '%s[信息]%s %s\n' "$GREEN" "$PLAIN" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$YELLOW" "$PLAIN" "$*"; }
error() { printf '%s[错误]%s %s\n' "$RED" "$PLAIN" "$*" >&2; }

is_root() { [[ $EUID -eq 0 ]]; }

need_root() {
    is_root && return 0
    error "此操作需要 root 权限，请使用 sudo 或切换到 root 后重试"
    return 1
}

has() { command -v "$1" >/dev/null 2>&1; }

# 询问 [y/N]，只有回答 y 时返回 0
confirm() {
    local ans
    read -rp "$1 [y/N]: " ans
    [[ $ans == [yY] ]]
}

# 高风险操作: 必须输入 yes 才继续
confirm_yes() {
    local ans
    read -rp "$1请输入 yes: " ans
    [[ $ans == yes ]]
}

cancelled() { info "已取消"; }

pause() { read -rp "按回车键返回菜单..." _; }

# 分节标题，例如: ========== IPv4 ==========
title() { printf '%s========== %s ==========%s\n' "$BOLD" "$*" "$PLAIN"; }

# 菜单标题和分组
menu_title() { printf '%s===== %s =====%s\n' "$BOLD" "$*" "$PLAIN"; }
menu_group() { printf '  %s%s%s\n' "$CYAN" "$*" "$PLAIN"; }

download() {
    if has curl; then curl -fsSL "$1" -o "$2"
    elif has wget; then wget -qO "$2" "$1"
    else error "需要 curl 或 wget"; return 1
    fi
}

# 监听地址是否只限本机 (awk 片段，show_ports 与 keep_list 共用)
AWK_IS_LOCAL='function is_local(a) {
    return a ~ /^127\./ || a == "[::1]" || a == "::1" || a ~ /^\[::ffff:127\./ || a ~ /%lo$/
}'

# ===========================================================================
# 2. 端口采集、防火墙识别与端口表
# ===========================================================================
# 采集监听端口，统一输出为: 协议|地址|端口|进程(PID),进程(PID)
collect_listen() {
    if has ss; then
        ss -tulnp 2>/dev/null | awk '
            NR > 1 {
                proto = $1; local_addr = $5
                addr = local_addr; sub(/:[^:]*$/, "", addr)
                port = substr(local_addr, length(addr) + 2)
                procs = ""; s = $0
                while (match(s, /\("[^"]*",pid=[0-9]+/)) {
                    t = substr(s, RSTART + 2, RLENGTH - 2)
                    n = index(t, "\",pid=")
                    item = substr(t, 1, n - 1) "(" substr(t, n + 6) ")"
                    if (index("," procs ",", "," item ",") == 0)
                        procs = procs (procs == "" ? "" : ",") item
                    s = substr(s, RSTART + RLENGTH)
                }
                if (procs == "") procs = "-"
                print proto "|" addr "|" port "|" procs
            }'
    elif has netstat; then
        netstat -tulnp 2>/dev/null | awk '
            $1 ~ /^(tcp|udp)/ {
                proto = $1; sub(/6$/, "", proto)
                if (proto == "tcp" && $6 != "LISTEN") next
                local_addr = $4
                addr = local_addr; sub(/:[^:]*$/, "", addr)
                port = substr(local_addr, length(addr) + 2)
                procs = "-"
                if ($NF ~ /^[0-9]+\//) { split($NF, a, "/"); procs = a[2] "(" a[1] ")" }
                print proto "|" addr "|" port "|" procs
            }'
    else
        error "未找到 ss 或 netstat，请先安装 iproute2 (或 net-tools)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 防火墙识别
# ---------------------------------------------------------------------------
# 输出: ufw | firewalld | iptables | nftables | none
detect_firewall() {
    if has ufw && LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
        echo ufw
    elif has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        echo firewalld
    elif has nft && nft list table inet portman_filter >/dev/null 2>&1; then
        echo nftables
    elif has iptables; then
        echo iptables
    elif has nft && nft list ruleset 2>/dev/null | grep -q "hook input"; then
        echo nftables
    else
        echo none
    fi
}

firewall_name() {
    case $1 in
        ufw)       echo "UFW" ;;
        firewalld) echo "firewalld" ;;
        iptables)  echo "iptables" ;;
        nftables)  echo "nftables" ;;
        none)      echo "未检测到防火墙" ;;
        *)         echo "未知 (需要 root 才能检测)" ;;
    esac
}

# 入站是否默认放行所有端口
fw_default_open() {
    case $1 in
        ufw)
            LC_ALL=C ufw status verbose 2>/dev/null | grep -q "allow (incoming)" ;;
        firewalld)
            [[ $(firewall-cmd --permanent --zone="$(firewall-cmd --get-default-zone 2>/dev/null)" --get-target 2>/dev/null) == ACCEPT ]] ;;
        iptables)
            local rules
            rules=$(iptables -S INPUT 2>/dev/null)
            # 默认策略为 ACCEPT 且没有"全部拒绝"类规则
            grep -q -- "-P INPUT ACCEPT" <<<"$rules" &&
                ! grep -E -- "-j (DROP|REJECT)" <<<"$rules" |
                  grep -vqE -- "--dports? |-s |-i |state|-p icmp" ;;
        none) return 0 ;;
        *) return 1 ;;
    esac
}

# 输出防火墙已放行的端口，每行一个: 协议:起始-结束 (协议可为 any)；默认全部放行时输出 ALL
fw_allowed_list() {
    if fw_default_open "$1"; then echo ALL; else fw_rule_list "$1"; fi
}

# 输出防火墙里明确放行端口的规则，格式同上
fw_rule_list() {
    case $1 in
        ufw)
            # user.rules 里的 tuple 行已把应用配置(如 OpenSSH)解析成了端口号
            cat /etc/ufw/user.rules /etc/ufw/user6.rules 2>/dev/null | awk '
                /^### tuple ###/ && $4 ~ /^(allow|limit)/ && $NF == "in" {
                    proto = $5; dports = $6
                    if (dports == "any") { print proto ":1-65535"; next }
                    n = split(dports, a, ",")
                    for (i = 1; i <= n; i++) { r = a[i]; sub(/:/, "-", r); print proto ":" r }
                }'
            ;;
        firewalld)
            local zone p s
            zone=$(firewall-cmd --get-default-zone 2>/dev/null)
            for p in $(firewall-cmd --zone="$zone" --list-ports 2>/dev/null); do
                echo "${p#*/}:${p%/*}"
            done
            for s in $(firewall-cmd --zone="$zone" --list-services 2>/dev/null); do
                for p in $(firewall-cmd --info-service="$s" 2>/dev/null | awk '$1 == "ports:" { for (i = 2; i <= NF; i++) print $i }'); do
                    echo "${p#*/}:${p%/*}"
                done
            done
            ;;
        iptables)
            iptables -S INPUT 2>/dev/null | awk '/-j ACCEPT/ && /--dports? / {
                proto = "any"; d = ""
                for (i = 1; i <= NF; i++) {
                    if ($i == "-p") proto = $(i + 1)
                    if ($i == "--dport" || $i == "--dports") d = $(i + 1)
                }
                n = split(d, a, ",")
                for (j = 1; j <= n; j++) { r = a[j]; sub(/:/, "-", r); print proto ":" r }
            }'
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 显示端口表
#   $1: all | public | <端口号>
# ---------------------------------------------------------------------------
show_ports() {
    local mode=${1:-all} data fw allowed="" defopen=0
    data=$(collect_listen) || return 1

    if is_root; then
        fw=$(detect_firewall)
        allowed=$(fw_rule_list "$fw" | tr '\n' ' ')
        fw_default_open "$fw" && defopen=1
    else
        fw=unknown
        warn "当前不是 root，进程信息和防火墙状态可能不完整"
    fi

    printf '%s\n' "$data" | LC_ALL=C awk -F'|' \
        -v mode="$mode" -v fw="$fw" -v allowed="$allowed" -v defopen="$defopen" \
        -v G="$GREEN" -v R="$RED" -v Y="$YELLOW" -v C="$CYAN" -v B="$BOLD" -v P="$PLAIN" '
    # 显示宽度: 3 字节的中文按 2 列算，2 字节字符按 1 列算
    function dw(s,   t, n3, n2) {
        t = s; n3 = gsub(/[\340-\357]/, "", t); n2 = gsub(/[\300-\337]/, "", t)
        return length(s) - n3 - n2
    }
    function cell(s, w, color,   pad) {
        pad = w - dw(s); if (pad < 1) pad = 1
        return color s (color == "" ? "" : P) sprintf("%" pad "s", "")
    }
    '"$AWK_IS_LOCAL"'
    function fw_allows(proto, port,   i) {
        if (allow_all) return 1
        for (i = 1; i <= nal; i++)
            if ((ap[i] == "any" || ap[i] == proto) && port >= lo[i] && port <= hi[i]) return 1
        return 0
    }
    function addlist(list, item) {
        if (index("," list ",", "," item ",")) return list
        return list (list == "" ? "" : ",") item
    }
    BEGIN {
        n = split(allowed, tok, " ")
        for (i = 1; i <= n; i++) {
            if (tok[i] == "ALL") { allow_all = 1; continue }
            split(tok[i], t, ":"); r = t[2]
            nal++; ap[nal] = t[1]
            if (index(r, "-")) { split(r, b, "-"); lo[nal] = b[1] + 0; hi[nal] = b[2] + 0 }
            else { lo[nal] = r + 0; hi[nal] = r + 0 }
        }
        while ((getline line < "/etc/services") > 0) {
            sub(/#.*/, "", line); split(line, f, " ")
            if (f[2] != "" && !(f[2] in svc)) svc[f[2]] = f[1]
        }
        split("21/ftp 22/ssh 25/smtp 53/dns 80/http 110/pop3 143/imap 443/https 465/smtps " \
              "587/submission 993/imaps 995/pop3s 1080/socks 1433/mssql 3306/mysql 3389/rdp " \
              "5432/postgresql 5900/vnc 6379/redis 8080/http-alt 8443/https-alt 9000/php-fpm " \
              "11211/memcached 27017/mongodb", d, " ")
        for (i in d) { split(d[i], kv, "/"); common[kv[1]] = kv[2] }
    }
    {
        proto = $1; addr = $2; port = $3; procs = $4
        if (port !~ /^[0-9]+$/) next
        if (mode != "all" && mode != "public" && port != mode) next
        k = proto "/" port
        if (!(k in seen)) { seen[k] = 1; cnt++; key[cnt] = k; KP[k] = proto; KN[k] = port + 0 }
        A[k] = addlist(A[k], addr)
        if (procs != "-") { m = split(procs, pp, ","); for (j = 1; j <= m; j++) PR[k] = addlist(PR[k], pp[j]) }
        if (!is_local(addr)) PUB[k] = 1
    }
    END {
        # 防火墙放行了但没有程序监听的端口也列出来
        if (mode == "all" || mode == "public") {
            for (r = 1; r <= nal; r++) {
                if (lo[r] == 1 && hi[r] == 65535) continue
                if (ap[r] == "any") np = split("tcp udp", rp, " ")
                else { np = 1; rp[1] = ap[r] }
                label = (lo[r] == hi[r]) ? lo[r] : lo[r] "-" hi[r]
                for (q = 1; q <= np; q++) {
                    k = rp[q] "/" label
                    if (k in seen) continue
                    seen[k] = 1; cnt++; key[cnt] = k
                    KP[k] = rp[q]; KN[k] = lo[r]; KL[k] = label; UN[k] = 1
                }
            }
        }
        pw = 8
        for (k in KL) if (length(KL[k]) + 1 > pw) pw = length(KL[k]) + 1
        # 按端口号、协议排序
        for (i = 2; i <= cnt; i++) {
            v = key[i]; j = i - 1
            while (j > 0 && (KN[key[j]] > KN[v] || (KN[key[j]] == KN[v] && key[j] > v))) { key[j + 1] = key[j]; j-- }
            key[j + 1] = v
        }
        printf "%s%s%s%s%s%s%s%s\n", B, cell("协议", 6, ""), cell("端口", pw, ""), cell("范围", 7, ""),
            cell("防火墙", 9, ""), cell("服务", 16, ""), cell("监听地址", 26, ""), "进程(PID)" P
        shown = 0; npub = 0; nblock = 0
        for (i = 1; i <= cnt; i++) {
            k = key[i]; proto = KP[k]; port = KN[k]
            if (UN[k]) {
                nun++
                s = (KL[k] ~ /-/) ? "-" : svc[port "/" proto]
                if (s == "" && KL[k] !~ /-/) s = common[port]
                if (s == "") s = "-"
                printf "%s%s%s%s%s%s%s\n", cell(proto, 6, C), cell(KL[k], pw, ""), cell("-", 7, ""),
                    cell("已放行", 9, G), cell(s, 16, ""), cell("-", 26, ""),
                    Y ((KL[k] ~ /-/) ? "端口范围" : "未使用") P
                continue
            }
            if (mode == "public" && !PUB[k]) continue
            shown++
            s = svc[port "/" proto]; if (s == "") s = common[port]; if (s == "") s = "-"
            if (PUB[k]) {
                npub++; scope = cell("公网", 7, Y)
                if (fw == "unknown" || fw == "nftables") st = cell("未知", 9, "")
                else if (fw == "none") st = cell("无防火墙", 9, Y)
                else if (fw_allows(proto, port)) st = cell("已放行", 9, G)
                else if (defopen) st = cell("默认放行", 9, Y)
                else { st = cell("未放行", 9, R); nblock++ }
            } else {
                scope = cell("本机", 7, ""); st = cell("-", 9, "")
            }
            printf "%s%s%s%s%s%s%s\n", cell(proto, 6, C), cell(port, pw, ""), scope, st,
                cell(s, 16, ""), cell(A[k], 26, ""), (PR[k] == "" ? "-" : PR[k])
        }
        if (shown + nun == 0) {
            if (mode == "all" || mode == "public") { print "  (没有找到监听中的端口)"; exit }
            print "  端口 " mode " 当前没有程序在监听，所以外部无论如何都连不上"
            # 没有程序监听时，单独说明防火墙对这个端口的态度
            printf "  防火墙对该端口:"
            split("tcp udp", pr, " ")
            for (i = 1; i <= 2; i++) {
                if (fw == "unknown" || fw == "nftables") st = "未知"
                else if (fw == "none") st = Y "无防火墙" P
                else if (fw_allows(pr[i], mode + 0)) st = G "已放行 (有放行规则)" P
                else if (defopen) st = Y "默认放行 (没有规则，但防火墙不拦截)" P
                else st = R "未放行 (会被拦截)" P
                printf "  %s %s", pr[i], st
            }
            print ""
            exit
        }
        printf "\n共 %d 个监听项，其中 %d 个对公网监听", shown, npub
        if (nblock > 0) printf "，%s%d 个未被防火墙放行%s", R, nblock, P
        if (nun > 0) printf "，%s%d 项已放行但未使用%s", Y, nun, P
        print ""
    }'

    printf '防火墙: %s' "$(firewall_name "$fw")"
    if (( defopen )) && [[ $fw != none ]]; then
        printf '  %s(入站默认放行：防火墙不拦截任何端口，有程序监听的端口外部都能访问)%s' "$YELLOW" "$PLAIN"
        printf '\n%s如需拦截没在使用的端口，请用主菜单第 6 项「一键关闭其他端口」%s' "$YELLOW" "$PLAIN"
    elif [[ $fw == ufw || $fw == firewalld || $fw == iptables ]]; then
        printf '  %s(入站默认拒绝：只有已放行的端口能访问)%s' "$GREEN" "$PLAIN"
    fi
    echo
    printf '说明: 已放行=有明确放行规则  默认放行=没有规则但防火墙未拦截  未放行=外部无法访问  未使用=已放行但没有程序监听\n'
    printf '      既没有放行规则、也没有程序监听的端口不会列出，可用「查询指定端口」查看\n'
    printf '%s提示: 云服务器(阿里云/腾讯云/AWS 等)还需在控制台「安全组」中放行端口，本脚本无法修改安全组。%s\n' "$YELLOW" "$PLAIN"
}

# ---------------------------------------------------------------------------
# 端口与协议参数解析
# ---------------------------------------------------------------------------
# 支持: 8080 / 80,443 / 8000-8100 / 8000:8100，每行输出一项
parse_ports() {
    local spec=${1// /} tok lo hi
    local -a toks
    if [[ -z $spec ]]; then error "请指定端口"; return 1; fi
    IFS=',' read -ra toks <<<"$spec"
    for tok in "${toks[@]}"; do
        tok=${tok/:/-}
        if [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}
        elif [[ $tok =~ ^[0-9]+$ ]]; then
            lo=$tok; hi=$tok
        else
            error "无效的端口: $tok"; return 1
        fi
        lo=$((10#$lo)); hi=$((10#$hi))
        if (( lo < 1 || hi > 65535 || lo > hi )); then
            error "端口超出范围 (1-65535): $tok"; return 1
        fi
        if (( lo == hi )); then echo "$lo"; else echo "$lo-$hi"; fi
    done
}

parse_proto() {
    case ${1:-tcp} in
        tcp|TCP|t)        echo "tcp" ;;
        udp|UDP|u)        echo "udp" ;;
        both|all|tcp+udp) echo "tcp udp" ;;
        *) error "无效的协议: $1 (可选 tcp / udp / both)"; return 1 ;;
    esac
}

# ===========================================================================
# 3. 防火墙操作
# ===========================================================================
# ---------------------------------------------------------------------------
# iptables 规则持久化
#   portman 把自己添加的规则记录在 STATE_FILE (每行 "allow 协议 端口" 或
#   "policy DROP|ACCEPT")，开机时由 systemd 服务调用 `portman restore` 重新应用。
#   只恢复 portman 的规则，不影响 docker / fail2ban 等。
# ---------------------------------------------------------------------------

# 规则不存在时插入到 INPUT 最前面
ipt_add() {
    local cmd=$1; shift
    $cmd -C INPUT "$@" 2>/dev/null || $cmd -I INPUT "$@" 2>/dev/null
}

# 默认拒绝前必须的基础规则: 回环、已建立的连接、ICMP。不支持连接状态匹配时返回 1
ipt_base() {
    local cmd=$1
    if [[ $cmd == iptables ]]; then ipt_add "$cmd" -p icmp -j ACCEPT
    else ipt_add "$cmd" -p ipv6-icmp -j ACCEPT; fi
    ipt_add "$cmd" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT ||
        ipt_add "$cmd" -m state --state ESTABLISHED,RELATED -j ACCEPT || return 1
    ipt_add "$cmd" -i lo -j ACCEPT
}

state_add() {
    mkdir -p "${STATE_FILE%/*}"
    grep -qx "allow $1 $2" "$STATE_FILE" 2>/dev/null || echo "allow $1 $2" >>"$STATE_FILE"
}

state_del() {
    [[ -f $STATE_FILE ]] && sed -i "/^allow $1 $2\$/d" "$STATE_FILE"
}

state_policy() {
    mkdir -p "${STATE_FILE%/*}"
    [[ -f $STATE_FILE ]] && sed -i '/^policy /d' "$STATE_FILE"
    echo "policy $1" >>"$STATE_FILE"
}

# 开机时重新应用记录的规则 (可重复执行)
restore_rules() {
    [[ -f $STATE_FILE ]] || return 0
    local cmd kw p port policy
    policy=$(awk '$1 == "policy" { v = $2 } END { print v }' "$STATE_FILE")
    for cmd in iptables ip6tables; do
        has $cmd || continue
        while read -r kw p port; do
            [[ $kw == allow ]] && ipt_add "$cmd" -p "$p" --dport "${port/-/:}" -j ACCEPT
        done <"$STATE_FILE"
        if [[ $policy == DROP ]]; then
            ipt_base "$cmd" && $cmd -P INPUT DROP
        elif [[ $policy == ACCEPT ]]; then
            $cmd -P INPUT ACCEPT
        fi
    done
}

install_restore_service() {
    if ! has systemctl || [[ ! -d /run/systemd/system ]]; then
        warn "系统未使用 systemd，规则已生效但重启后会丢失"
        return 1
    fi
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=portman: restore firewall rules
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH restore

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

save_iptables() {
    has netfilter-persistent && netfilter-persistent save >/dev/null 2>&1
    if install_restore_service; then
        info "规则已保存，重启后自动恢复 (记录在 $STATE_FILE)"
    fi
}

remove_restore_service() {
    [[ -f $SERVICE_FILE ]] || return 0
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null
}

# ---------------------------------------------------------------------------
# 放行 / 关闭端口
# ---------------------------------------------------------------------------
open_port() {
    need_root || return 1
    local ports protos fw port p cmd changed=0
    ports=$(parse_ports "$1") || return 1
    protos=$(parse_proto "${2:-tcp}") || return 1
    fw=$(detect_firewall)

    case $fw in
        none)
            info "未检测到防火墙，端口无需放行；只要有程序在监听，就可以从外部访问"
            warn "如果是云服务器，请到控制台「安全组」中放行对应端口"
            return 0 ;;
        nftables)
            nft_dispatch open "$ports" "$protos"
            return $? ;;
    esac

    info "使用 $(firewall_name "$fw") 放行端口..."
    for port in $ports; do
        for p in $protos; do
            case $fw in
                ufw)
                    ufw allow "${port/-/:}/$p" >/dev/null && changed=1 ;;
                firewalld)
                    firewall-cmd --permanent --add-port="$port/$p" >/dev/null && changed=1 ;;
                iptables)
                    for cmd in iptables ip6tables; do
                        has $cmd && ipt_add "$cmd" -p "$p" --dport "${port/-/:}" -j ACCEPT
                    done
                    state_add "$p" "$port"
                    changed=1 ;;
            esac
            printf '  %s✔%s %s/%s\n' "$GREEN" "$PLAIN" "$port" "$p"
        done
    done

    if (( changed )); then
        [[ $fw == firewalld ]] && firewall-cmd --reload >/dev/null
        [[ $fw == iptables ]] && save_iptables
    fi
    info "完成。云服务器请同时确认「安全组」已放行"
}

# 待关闭的端口里是否包含当前 SSH 端口
hits_ssh_port() {
    local ports=$1 sshp port lo hi
    for sshp in $(ssh_ports); do
        for port in $ports; do
            lo=${port%-*}; hi=${port#*-}
            if (( sshp >= lo && sshp <= hi )); then echo "$sshp"; return 0; fi
        done
    done
    return 1
}

close_port() {
    need_root || return 1
    local ports protos fw port p ipt_port cmd sshp
    ports=$(parse_ports "$1") || return 1
    protos=$(parse_proto "${2:-tcp}") || return 1
    fw=$(detect_firewall)

    case $fw in
        none)     warn "未检测到防火墙，没有可删除的放行规则"; return 0 ;;
        nftables) nft_dispatch close "$ports" "$protos"; return $? ;;
    esac

    if sshp=$(hits_ssh_port "$ports"); then
        warn "端口 $sshp 是当前 SSH 端口，关闭后可能导致无法远程登录！"
        confirm "确定要继续吗?" || { cancelled; return 0; }
    fi

    info "使用 $(firewall_name "$fw") 关闭端口..."
    for port in $ports; do
        for p in $protos; do
            case $fw in
                ufw)
                    ufw delete allow "${port/-/:}/$p" >/dev/null 2>&1 ;;
                firewalld)
                    firewall-cmd --permanent --remove-port="$port/$p" >/dev/null 2>&1 ;;
                iptables)
                    ipt_port=${port/-/:}
                    for cmd in iptables ip6tables; do
                        has $cmd || continue
                        while $cmd -C INPUT -p "$p" --dport "$ipt_port" -j ACCEPT 2>/dev/null; do
                            $cmd -D INPUT -p "$p" --dport "$ipt_port" -j ACCEPT
                        done
                    done
                    state_del "$p" "$port" ;;
            esac
            printf '  %s✘%s %s/%s\n' "$RED" "$PLAIN" "$port" "$p"
        done
    done

    [[ $fw == firewalld ]] && firewall-cmd --reload >/dev/null
    if [[ $fw == iptables ]]; then
        save_iptables
        if [[ $(fw_allowed_list iptables) == ALL ]]; then
            warn "iptables 默认策略为 ACCEPT，删除放行规则后端口仍然可以访问"
        fi
    fi
    info "完成"
}

# ---------------------------------------------------------------------------
# 一键关闭其他端口 / 恢复全部放行
# ---------------------------------------------------------------------------
# 当前 SSH 端口: 优先取本次连接的端口，其次是 sshd 正在监听的端口
ssh_ports() {
    {
        [[ -n ${SSH_CONNECTION:-} ]] && awk '{ print $4 }' <<<"$SSH_CONNECTION"
        collect_listen 2>/dev/null | awk -F'|' '$4 ~ /sshd/ { print $3 }'
    } | sort -un
}

# 一键关闭时使用的防火墙: 已启用的 ufw/firewalld 优先，其次是已安装但未启用的 ufw，最后是 iptables
lock_backend() {
    local fw
    fw=$(detect_firewall)
    case $fw in
        ufw|firewalld|nftables) echo "$fw" ;;
        *) if has ufw; then echo ufw-off; else echo "$fw"; fi ;;
    esac
}

# 输出要保留的端口，每行: 协议 端口 说明
keep_list() {
    local p
    {
        collect_listen | awk -F'|' "$AWK_IS_LOCAL"' !is_local($2) { print $1, $3, $4 }'
        p=$(ssh_ports)
        for p in ${p:-22}; do echo "tcp $p SSH"; done
    } | awk '!seen[$1 " " $2]++' | sort -k2,2n -k1,1
}

lockdown() {
    need_root || return 1
    local backend keep extra eprotos port p ans cmd state_ok zone

    backend=$(lock_backend)
    if [[ $backend == none ]]; then
        warn "未检测到可用的防火墙"
        if has apt-get; then
            confirm "是否安装 ufw 防火墙?" || { cancelled; return 0; }
            apt-get update -qq && apt-get install -y -qq ufw || { error "ufw 安装失败"; return 1; }
            backend=ufw-off
        else
            error "请先安装 firewalld 或 iptables"; return 1
        fi
    elif [[ $backend == nftables ]]; then
        nft_dispatch lockdown
        return $?
    fi

    keep=$(keep_list) || return 1
    printf '%s以下正在使用的端口会被保留，其余所有入站端口将被关闭:%s\n\n' "$BOLD" "$PLAIN"
    echo "  协议   端口        进程"
    while read -r p port note; do
        printf '  %s%-6s%s %-11s %s\n' "$CYAN" "$p" "$PLAIN" "$port" "$note"
    done <<<"$keep"
    echo

    read -rp "如需额外保留端口请输入 (如 8080 / 80,443 / 8000-8100)，直接回车跳过: " extra
    if [[ -n $extra ]]; then
        extra=$(parse_ports "$extra") || return 1
        read -rp "额外端口的协议 tcp/udp/both [默认 tcp]: " ans
        eprotos=$(parse_proto "${ans:-tcp}") || return 1
        for port in $extra; do
            for p in $eprotos; do keep+=$'\n'"$p $port 手动添加"; done
        done
    fi

    echo
    warn "将使用 $(firewall_name "${backend%-off}") 设置为「默认拒绝入站」，只放行上面列出的端口"
    warn "SSH 端口会自动保留；已有的放行规则不会被删除"
    confirm_yes "确认执行" || { cancelled; return 0; }

    case $backend in
        ufw|ufw-off)
            while read -r p port _; do
                ufw allow "${port/-/:}/$p" >/dev/null
            done <<<"$keep"
            ufw default deny incoming >/dev/null
            ufw default allow outgoing >/dev/null
            [[ $backend == ufw-off ]] && ufw --force enable >/dev/null
            ;;
        firewalld)
            zone=$(firewall-cmd --get-default-zone)
            while read -r p port _; do
                firewall-cmd --permanent --zone="$zone" --add-port="$port/$p" >/dev/null
            done <<<"$keep"
            if [[ $(firewall-cmd --permanent --zone="$zone" --get-target) == ACCEPT ]]; then
                firewall-cmd --permanent --zone="$zone" --set-target=default >/dev/null
            fi
            firewall-cmd --reload >/dev/null
            ;;
        iptables)
            state_ok=0
            for cmd in iptables ip6tables; do
                has $cmd || continue
                # -I 插入到最前面，所以先插端口规则，再插回环和已建立连接
                while read -r p port _; do
                    ipt_add "$cmd" -p "$p" --dport "${port/-/:}" -j ACCEPT
                done <<<"$keep"
                if ! ipt_base "$cmd"; then
                    error "$cmd 不支持连接状态匹配，为避免断网，未修改默认策略"
                    continue
                fi
                $cmd -P INPUT DROP
                [[ $cmd == iptables ]] && state_ok=1
            done
            while read -r p port _; do state_add "$p" "$port"; done <<<"$keep"
            (( state_ok )) && state_policy DROP
            save_iptables
            ;;
    esac

    info "完成！除上面列出的端口外，其余入站端口已全部关闭"
    info "如需恢复，运行: portman unlock"
    warn "建议先新开一个 SSH 窗口测试能否正常登录，确认后再关闭当前窗口"
}

unlock() {
    need_root || return 1
    local fw cmd
    fw=$(detect_firewall)
    case $fw in
        none)     info "未检测到防火墙，所有端口本来就是放行的"; return 0 ;;
        nftables) nft_dispatch unlock; return $? ;;
    esac

    confirm "将把 $(firewall_name "$fw") 改为「默认放行所有入站端口」，确认?" || { cancelled; return 0; }

    case $fw in
        ufw) ufw default allow incoming >/dev/null ;;
        firewalld)
            firewall-cmd --permanent --zone="$(firewall-cmd --get-default-zone)" --set-target=ACCEPT >/dev/null
            firewall-cmd --reload >/dev/null ;;
        iptables)
            for cmd in iptables ip6tables; do
                has $cmd && $cmd -P INPUT ACCEPT
            done
            state_policy ACCEPT
            save_iptables ;;
    esac
    info "已恢复：所有入站端口均已放行"
}

# ---------------------------------------------------------------------------
# 防火墙状态页
# ---------------------------------------------------------------------------
show_firewall() {
    need_root || return 1
    local fw rules icmp
    fw=$(detect_firewall)

    printf '%s防火墙类型:%s %s\n' "$BOLD" "$PLAIN" "$(firewall_name "$fw")"
    if [[ $fw == nftables ]]; then
        nft_dispatch status
        return
    fi

    printf '%s入站策略:%s   ' "$BOLD" "$PLAIN"
    if [[ $fw == none ]]; then
        printf '%s没有防火墙，所有端口都能从外部访问%s\n' "$YELLOW" "$PLAIN"
    elif fw_default_open "$fw"; then
        printf '%s默认放行 —— 所有端口都能从外部访问%s\n' "$YELLOW" "$PLAIN"
    else
        printf '%s默认拒绝 —— 只有下方已放行的端口能访问%s\n' "$GREEN" "$PLAIN"
    fi

    icmp="允许 (系统默认)"
    if [[ $fw == iptables ]] && ! fw_default_open iptables; then
        if iptables -S INPUT 2>/dev/null | grep -qE -- "-p icmp .*-j ACCEPT|-p icmp -j ACCEPT"; then icmp="允许"
        else icmp="${RED}禁止${PLAIN}"; fi
    elif [[ $fw == none ]] || fw_default_open "$fw"; then
        icmp="允许"
    fi
    printf '%sICMP(ping):%s %s\n' "$BOLD" "$PLAIN" "$icmp"

    if [[ $fw == iptables ]]; then
        printf '%s重启后恢复:%s ' "$BOLD" "$PLAIN"
        if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
            printf '%s已开启%s (规则记录在 %s)\n' "$GREEN" "$PLAIN" "$STATE_FILE"
        else
            printf '%s未开启%s (portman 添加规则后会自动开启)\n' "$YELLOW" "$PLAIN"
        fi
    fi

    [[ $fw == none ]] && return 0

    echo
    printf '%s已放行的端口规则:%s\n' "$BOLD" "$PLAIN"
    rules=$(fw_rule_list "$fw" | awk '!seen[$0]++')
    if [[ -z $rules ]]; then
        echo "  (没有单独的放行规则)"
    else
        echo "  协议     端口          当前使用情况"
        { collect_listen 2>/dev/null; echo "--"; echo "$rules"; } | LC_ALL=C awk -F'|' \
            -v G="$GREEN" -v C="$CYAN" -v P="$PLAIN" '
            $0 == "--" { phase = 1; next }
            phase == 0 { if (!(($1 "/" $3) in L)) L[$1 "/" $3] = $4; next }
            {
                split($0, a, ":"); proto = a[1]; r = a[2]
                if (r ~ /-/) { split(r, b, "-"); if (b[1] == b[2]) r = b[1] }
                if (r == "1-65535") use = "全部端口"
                else if (r ~ /-/) use = "端口范围"
                else {
                    use = ""
                    if (proto != "udp" && (("tcp/" r) in L)) use = "tcp: " L["tcp/" r]
                    if (proto != "tcp" && (("udp/" r) in L)) use = use (use == "" ? "" : "  ") "udp: " L["udp/" r]
                    use = (use == "") ? "无程序监听" : G use P
                }
                if (proto == "any") proto = "tcp/udp"
                printf "  %s%-8s%s %-13s %s\n", C, proto, P, r, use
            }'
    fi

    echo
    printf '%s原始规则:%s\n' "$BOLD" "$PLAIN"
    case $fw in
        ufw)       ufw status numbered ;;
        firewalld) firewall-cmd --list-all ;;
        iptables)
            echo "[IPv4]"; iptables -L INPUT -n --line-numbers
            if has ip6tables; then echo; echo "[IPv6]"; ip6tables -L INPUT -n --line-numbers; fi ;;
    esac
}

# ===========================================================================
# 4. IPv4 / IPv6
#   禁用 IPv6 时写入 SYSCTL_FILE，开机由 systemd-sysctl 自动加载。
# ===========================================================================

# 输出: kernel-off (内核参数禁用) | off (sysctl 禁用) | on
ipv6_state() {
    [[ -d /proc/sys/net/ipv6 ]] || { echo kernel-off; return; }
    local dev
    dev=$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == 1 ]] ||
        [[ -n $dev && $(cat "/proc/sys/net/ipv6/conf/$dev/disable_ipv6" 2>/dev/null) == 1 ]]; then
        echo off
    else
        echo on
    fi
}

# 系统里其他会在开机时禁用 IPv6 的 sysctl 配置
ipv6_other_disablers() {
    grep -lsE '^[[:space:]]*net\.ipv6\.conf\.(all|default)\.disable_ipv6[[:space:]]*=[[:space:]]*1' \
        /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf 2>/dev/null |
        grep -vxF "$SYSCTL_FILE"
}

# 用外部服务检测出口 IP，$1 为 4 或 6
public_ip() {
    local url ip
    for url in https://api64.ipify.org https://icanhazip.com; do
        if has curl; then ip=$(curl -"$1" -fsS -m 5 "$url" 2>/dev/null)
        elif has wget; then ip=$(wget -"$1" -qO- -T 5 "$url" 2>/dev/null)
        else return 1; fi
        ip=$(tr -d '[:space:]' <<<"$ip")
        [[ -n $ip ]] && { echo "$ip"; return 0; }
    done
    return 1
}

print_ip_family() {
    local v=$1 addrs route pub
    addrs=$(ip -o -"$v" addr show scope global 2>/dev/null | awk '{ printf "%s%s %s", (n++ ? "\n          " : ""), $2, $4 }')
    route=$(ip -"$v" route show default 2>/dev/null | head -1)
    printf '本机地址: %s\n' "${addrs:-${YELLOW}无公网地址${PLAIN}}"
    printf '默认路由: %s\n' "${route:-${YELLOW}无${PLAIN}}"
    if [[ -z $route ]]; then
        printf '外网连通: %s✘ 无法访问 (没有默认路由)%s\n' "$RED" "$PLAIN"
    elif pub=$(public_ip "$v"); then
        printf '外网连通: %s✔ 正常%s  出口 IP: %s\n' "$GREEN" "$PLAIN" "$pub"
    else
        printf '外网连通: %s✘ 无法访问外网%s\n' "$RED" "$PLAIN"
    fi
}

show_ip_status() {
    local state others
    if ! has ip; then error "未找到 ip 命令，请先安装 iproute2"; return 1; fi
    info "正在检测网络，最多需要十几秒..."
    echo

    title IPv4
    if [[ -n $(ip -o -4 addr show scope global 2>/dev/null) ]]; then
        printf '状态:     %s已启用%s\n' "$GREEN" "$PLAIN"
    else
        printf '状态:     %s没有 IPv4 地址%s (可能是纯 IPv6 机器)\n' "$YELLOW" "$PLAIN"
    fi
    print_ip_family 4
    echo

    title IPv6
    state=$(ipv6_state)
    case $state in
        on)  printf '状态:     %s已启用%s\n' "$GREEN" "$PLAIN" ;;
        off) printf '状态:     %s已禁用%s\n' "$RED" "$PLAIN" ;;
        kernel-off) printf '状态:     %s已禁用 (内核启动参数 ipv6.disable=1)%s\n' "$RED" "$PLAIN" ;;
    esac
    others=$(ipv6_other_disablers | tr '\n' ' ')
    if [[ -f $SYSCTL_FILE ]]; then
        printf '开机设置: 由 portman 禁用，重启后保持 (%s)\n' "$SYSCTL_FILE"
    elif [[ -n $others ]]; then
        printf '开机设置: 被 %s禁用\n' "$others"
    elif [[ $state != kernel-off ]]; then
        printf '开机设置: 系统默认 (启用)\n'
    fi
    [[ $state == on ]] && print_ip_family 6
}

ipv6_disable() {
    need_root || return 1
    local state server_ip
    state=$(ipv6_state)
    if [[ $state == kernel-off ]]; then info "IPv6 已被内核参数禁用，无需操作"; return 0; fi

    server_ip=$(awk '{ print $3 }' <<<"${SSH_CONNECTION:-}")
    if [[ $server_ip == *:* && $server_ip != ::ffff:* ]]; then
        error "你当前是通过 IPv6 连接的 SSH，禁用后会立即断开。请改用 IPv4 地址连接后再操作"
        return 1
    fi
    if [[ -z $(ip -4 route show default 2>/dev/null) ]]; then
        error "没有检测到 IPv4 默认路由，这台机器可能只有 IPv6，禁用后将无法联网"
        return 1
    fi

    warn "禁用后，服务器的 IPv6 地址会失效，IPv6 入站和出站都将不可用 (本机回环 ::1 保留)"
    confirm "确认禁用 IPv6?" || { cancelled; return 0; }

    cat >"$SYSCTL_FILE" <<'EOF'
# 由 portman 生成: 禁用 IPv6，保留本机回环 ::1
# 删除本文件并重启即可恢复 IPv6，或运行: portman ipv6 on
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null
    info "IPv6 已禁用，重启后保持"
}

ipv6_enable() {
    need_root || return 1
    local state others
    state=$(ipv6_state)
    if [[ $state == kernel-off ]]; then
        error "IPv6 被内核启动参数 ipv6.disable=1 禁用，无法在线开启"
        echo "  请编辑 /etc/default/grub，删除 GRUB_CMDLINE_LINUX 里的 ipv6.disable=1，"
        echo "  然后执行 update-grub (CentOS: grub2-mkconfig -o /boot/grub2/grub.cfg) 并重启"
        return 1
    fi

    rm -f "$SYSCTL_FILE"
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 \
        net.ipv6.conf.lo.disable_ipv6=0 >/dev/null
    info "IPv6 已启用"

    others=$(ipv6_other_disablers)
    if [[ -n $others ]]; then
        warn "以下配置文件会在开机时再次禁用 IPv6，请手动删除其中的 disable_ipv6 = 1:"
        printf '  %s\n' $others
    else
        info "重启后保持启用"
    fi

    sleep 3
    if [[ -z $(ip -o -6 addr show scope global 2>/dev/null) ]]; then
        warn "网卡暂时还没有拿到 IPv6 地址。如果服务商分配了 IPv6，重启服务器后即可恢复"
    fi
}

ipv6_menu() {
    local c
    if [[ $(ipv6_state) == on ]]; then
        printf 'IPv6 当前状态: %s已启用%s\n\n' "$GREEN" "$PLAIN"
    else
        printf 'IPv6 当前状态: %s已禁用%s\n\n' "$RED" "$PLAIN"
    fi
    echo "  1. 禁用 IPv6 (重启后保持)"
    echo "  2. 启用 IPv6 (重启后保持)"
    echo "  0. 返回"
    echo
    read -rp "请选择 [0-2]: " c
    echo
    case $c in
        1) ipv6_disable ;;
        2) ipv6_enable ;;
        *) return 0 ;;
    esac
}

# ===========================================================================
# 5. SSH
# ===========================================================================
# ---------------------------------------------------------------------------
# SSH 密钥登录
#   有 sshd_config.d 时写入 00-key-only.conf (与常见代码片段同名，可互相识别)；
#   否则在 sshd_config 顶部插入带标记的配置块。sshd 取第一次出现的值，所以都排在最前。
# ---------------------------------------------------------------------------

auth_keys_file() { echo "${HOME:-/root}/.ssh/authorized_keys"; }

file_mode() { stat -c %a "$1" 2>/dev/null; }

sshd_bin() {
    local p
    for p in "$(command -v sshd 2>/dev/null)" /usr/sbin/sshd /sbin/sshd; do
        [[ -n $p && -x $p ]] && { echo "$p"; return 0; }
    done
    return 1
}

# sshd 实际生效的配置，每行: 小写键名 值
sshd_effective() {
    local b
    b=$(sshd_bin) || return 1
    "$b" -T 2>/dev/null
}

eff_get() { awk -v k="$2" '$1 == k { print $2; exit }' <<<"$1"; }

# 逐行解析 authorized_keys，每个公钥输出: 行号|类型|指纹|备注
key_entries() {
    local f n=0 line out
    f=$(auth_keys_file)
    [[ -s $f ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if has ssh-keygen; then
            out=$(ssh-keygen -lf /dev/stdin <<<"$line" 2>/dev/null) || continue
            awk -v n="$n" '{
                type = $NF; gsub(/[()]/, "", type); c = ""
                for (i = 3; i < NF; i++) c = c (c == "" ? "" : " ") $i
                if (c == "" || c == "no comment") c = "(无备注)"
                print n "|" type "|" $2 "|" c; exit
            }' <<<"$out"
        elif [[ $line =~ (ssh-[a-z0-9-]+|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]]+(.*))? ]]; then
            echo "$n|${BASH_REMATCH[1]}|-|${BASH_REMATCH[3]:-(无备注)}"
        fi
    done <"$f"
}

# 每行: 类型|指纹|备注
list_keys() { key_entries | cut -d'|' -f2-; }

key_count() { list_keys | grep -c . ; }

print_keys() {
    list_keys | awk -F'|' -v C="$CYAN" -v P="$PLAIN" '{ printf "  %d. %s%-8s%s %s  %s\n", NR, C, $1, P, $2, $3 }'
}

sshd_has_include() {
    grep -Eiq '^[[:space:]]*Include[[:space:]].*sshd_config\.d/' "$SSHD_CONFIG" 2>/dev/null
}

# portman 的配置写法: sshd_config 会 Include sshd_config.d 时用单独文件，否则写到顶部
sshd_conf_mode() { if sshd_has_include; then echo file; else echo block; fi; }

ssh_service_state() {
    local svc
    if has systemctl; then
        for svc in ssh sshd; do
            systemctl is-active --quiet "$svc.service" 2>/dev/null && { echo "运行中 ($svc.service)"; return 0; }
        done
        systemctl is-active --quiet ssh.socket 2>/dev/null && { echo "运行中 (ssh.socket 按需启动)"; return 0; }
    fi
    pgrep -x sshd >/dev/null 2>&1 && { echo "运行中"; return 0; }
    echo "未运行"; return 1
}

reload_sshd() {
    local svc
    if has systemctl; then
        for svc in ssh sshd; do
            if systemctl is-active --quiet "$svc.service" 2>/dev/null; then
                systemctl reload "$svc.service" 2>/dev/null && return 0
            fi
        done
        # socket 按需启动时，每个新连接都会读取最新配置
        systemctl is-active --quiet ssh.socket 2>/dev/null && return 0
    fi
    if has service; then
        service ssh reload >/dev/null 2>&1 || service sshd reload >/dev/null 2>&1
        return
    fi
    return 1
}

# 移除 portman 写入的所有 sshd 配置
clear_sshd_conf() {
    rm -f "$KEY_ONLY_FILE" "$PASSWORD_FILE"
    sed -i "/^$SSHD_MARK_BEGIN\$/,/^$SSHD_MARK_END\$/d" "$SSHD_CONFIG"
}

# 写入 sshd 配置并重载，配置检查失败时自动回滚
#   $1: file | block   $2: 配置文件路径 (file 模式)   $3: 配置内容，为空表示只清除
apply_sshd_conf() {
    local mode=$1 file=$2 content=$3 b bak err main
    b=$(sshd_bin) || { error "未找到 sshd"; return 1; }
    bak=$(mktemp -d)
    cp -p "$SSHD_CONFIG" "$bak/main"
    [[ -f $KEY_ONLY_FILE ]] && cp -p "$KEY_ONLY_FILE" "$bak/keyonly"
    [[ -f $PASSWORD_FILE ]] && cp -p "$PASSWORD_FILE" "$bak/password"

    clear_sshd_conf
    if [[ -n $content ]]; then
        if [[ $mode == file ]]; then
            mkdir -p "$SSHD_DIR"
            printf '# 由 portman 生成\n%s\n' "$content" >"$file"
            chmod 644 "$file"
        else
            main=$(cat "$SSHD_CONFIG")
            printf '%s\n%s\n%s\n%s\n' "$SSHD_MARK_BEGIN" "$content" "$SSHD_MARK_END" "$main" >"$SSHD_CONFIG"
        fi
    fi

    if ! err=$("$b" -t 2>&1); then
        cat "$bak/main" >"$SSHD_CONFIG"
        rm -f "$KEY_ONLY_FILE" "$PASSWORD_FILE"
        [[ -f $bak/keyonly ]] && cp -p "$bak/keyonly" "$KEY_ONLY_FILE"
        [[ -f $bak/password ]] && cp -p "$bak/password" "$PASSWORD_FILE"
        rm -rf "$bak"
        error "sshd 配置检查失败，已自动回滚，没有做任何改动:"
        printf '  %s\n' "$err"
        return 1
    fi
    rm -rf "$bak"
    reload_sshd || warn "sshd 重新加载失败，请手动执行: systemctl restart ssh"
    return 0
}

# 按 sshd 实际读取顺序 (Include 处展开 sshd_config.d) 列出设置某个选项的位置
#   输出: 文件:行号:内容
ordered_setting_sources() {
    local key=$1 item f
    awk -v k="$key" -v file="$SSHD_CONFIG" '
        tolower($1) == "include" && $0 ~ /sshd_config\.d\// { print "@INCLUDE"; next }
        tolower($1) == tolower(k) { print file ":" NR ":" $0 }
    ' "$SSHD_CONFIG" 2>/dev/null | while IFS= read -r item; do
        if [[ $item == @INCLUDE ]]; then
            for f in "$SSHD_DIR"/*.conf; do
                [[ -f $f ]] && grep -HnEi "^[[:space:]]*${key}[[:space:]]" "$f"
            done
        else
            echo "$item"
        fi
    done
}

show_setting_sources() { ordered_setting_sources "$1" | sed 's/^/    /'; }

ssh_add_key() {
    need_root || return 1
    local src=${1:-} last="" url="" tmp keys f line body added=0 dup=0
    [[ -f $SSH_CONF ]] && last=$(sed -n 's/^KEY_SOURCE=//p' "$SSH_CONF" | tail -1)

    if [[ -z $src ]]; then
        echo "公钥来源，支持以下几种:"
        echo "  - Termius / sshid.io 用户名，例如: abc123  (等同于 https://sshid.io/abc123)"
        echo "  - 公钥链接，例如: https://github.com/你的用户名.keys"
        echo "  - 直接粘贴公钥，例如: ssh-ed25519 AAAA... 备注"
        if [[ -n $last ]]; then
            read -rp "请输入 [回车使用上次的 ${last:0:40}]: " src
            src=${src:-$last}
        else
            read -rp "请输入: " src
        fi
    fi
    src=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$src")
    [[ -n $src ]] || { error "没有输入公钥来源"; return 1; }

    tmp=$(mktemp)
    case $src in
        http://*|https://*) url=$src ;;
        ssh-*|ecdsa-*|sk-*) printf '%s\n' "$src" >"$tmp" ;;
        *)
            if [[ $src =~ ^[A-Za-z0-9._-]+$ ]]; then
                url="https://sshid.io/$src"
            else
                rm -f "$tmp"; error "无法识别的公钥来源: $src"; return 1
            fi ;;
    esac
    if [[ -n $url ]]; then
        info "正在获取公钥: $url"
        download "$url" "$tmp" || { rm -f "$tmp"; error "下载失败，请检查链接或用户名"; return 1; }
    fi

    keys=$(tr -d '\r' <"$tmp" | grep -E "$KEY_RE")
    if [[ -z $keys ]]; then
        error "没有获取到有效的公钥，内容开头为: $(head -c 80 "$tmp" | tr '\n' ' ')"
        rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"

    f=$(auth_keys_file)
    mkdir -p "${f%/*}" && chmod 700 "${f%/*}"
    touch "$f" && chmod 600 "$f"
    # 文件末尾没有换行时先补上，避免和新公钥连成一行
    [[ -s $f && -n $(tail -c1 "$f") ]] && echo >>"$f"
    while read -r line; do
        body=$(awk '{ print $2 }' <<<"$line")
        if grep -qF "$body" "$f"; then
            dup=$((dup + 1))
        else
            echo "$line" >>"$f"; added=$((added + 1))
        fi
    done <<<"$keys"
    has restorecon && restorecon -R "${f%/*}" 2>/dev/null

    mkdir -p "${SSH_CONF%/*}"
    printf 'KEY_SOURCE=%s\n' "$src" >"$SSH_CONF"

    info "新写入 $added 个公钥，$dup 个之前已存在"
    echo "当前 $f 中的公钥:"
    print_keys
}

ssh_key_only() {
    need_root || return 1
    local auto=${1:-} n eff kbdkey content pw ans mode
    n=$(key_count)
    if (( n == 0 )); then
        warn "还没有写入任何公钥，直接关闭密码登录会导致无法登录"
        [[ $auto == -y ]] && { error "请先运行: portman ssh addkey <用户名或链接>"; return 1; }
        read -rp "现在写入公钥吗? [Y/n]: " ans
        [[ $ans == [nN] ]] && { cancelled; return 0; }
        ssh_add_key || return 1
        n=$(key_count)
        (( n > 0 )) || return 1
    fi

    eff=$(sshd_effective)
    if [[ -z $eff ]]; then
        error "无法读取 sshd 配置，请先检查: $(sshd_bin) -t"; return 1
    fi
    kbdkey=KbdInteractiveAuthentication
    grep -q '^kbdinteractiveauthentication ' <<<"$eff" || kbdkey=ChallengeResponseAuthentication

    if [[ $auto != -y ]]; then
        echo
        echo "当前已写入 $n 个公钥:"
        print_keys
        echo
        warn "开启后只能用以上公钥对应的密钥登录，密码将无法登录"
        warn "当前 SSH 连接不会断开。开启后请保持此窗口，新开一个 Termius 窗口测试能否登录"
        confirm "确认开启只允许密钥登录?" || { cancelled; return 0; }
    fi

    content="PubkeyAuthentication yes
PasswordAuthentication no
$kbdkey no
PermitRootLogin prohibit-password"

    mode=$(sshd_conf_mode)
    apply_sshd_conf "$mode" "$KEY_ONLY_FILE" "$content" || return 1

    pw=$(eff_get "$(sshd_effective)" passwordauthentication)
    if [[ $pw != no && $mode == file ]]; then
        # sshd_config 里在 Include 之前就设置了密码登录，改为写到 sshd_config 最前面
        apply_sshd_conf block "" "$content" || return 1
        pw=$(eff_get "$(sshd_effective)" passwordauthentication)
    fi

    if [[ $pw == no ]]; then
        info "✅ 已开启只允许密钥登录，配置检查通过并已生效"
        if [[ -n $(ssh_risks) ]]; then
            echo
            warn "发现其他配置文件仍写着开启密码登录 (目前被覆盖，但属于隐患)"
            ssh_harden "$auto"
        fi
        warn "请新开一个窗口用密钥登录测试，确认成功后再关闭当前窗口"
    else
        error "配置已写入，但密码登录实际仍为 $pw，可能被以下配置覆盖:"
        show_setting_sources PasswordAuthentication
        return 1
    fi
}

ssh_password_login() {
    need_root || return 1
    local st eff mode
    st=$(passwd -S root 2>/dev/null | awk '{ print $2 }')
    if [[ $st == L || $st == LK || $st == NP ]]; then
        warn "root 账号当前没有可用的密码，开启后仍无法用密码登录。可先运行 passwd 设置密码"
    fi
    confirm "确认恢复密码登录?" || { cancelled; return 0; }

    apply_sshd_conf file "" "" || return 1
    eff=$(sshd_effective)
    if [[ $(eff_get "$eff" passwordauthentication) != yes || $(eff_get "$eff" permitrootlogin) != yes ]]; then
        # 系统其他配置仍禁止密码登录，写入一条明确开启的配置
        mode=$(sshd_conf_mode)
        apply_sshd_conf "$mode" "$PASSWORD_FILE" "PasswordAuthentication yes
PermitRootLogin yes" || return 1
        eff=$(sshd_effective)
    fi

    if [[ $(eff_get "$eff" passwordauthentication) == yes ]]; then
        info "✅ 已恢复密码登录 (密钥登录同样可用)"
    else
        error "密码登录仍未开启，可能被以下配置覆盖:"
        show_setting_sources PasswordAuthentication
        return 1
    fi
}

yesno() {
    case $1 in
        yes) printf '%s开启%s' "$GREEN" "$PLAIN" ;;
        no)  printf '%s关闭%s' "$RED" "$PLAIN" ;;
        *)   printf '%s' "${1:-未知}" ;;
    esac
}

ssh_status() {
    need_root || return 1
    local f n eff pw kbd pub root ports dmode fmode err svc risks color b

    f=$(auth_keys_file)
    n=$(key_count)
    title 公钥
    printf '公钥文件: %s\n' "$f"
    if (( n > 0 )); then
        printf '写入情况: %s✔ 已写入 %d 个公钥%s\n' "$GREEN" "$n" "$PLAIN"
        print_keys
    else
        printf '写入情况: %s✘ 没有公钥%s\n' "$RED" "$PLAIN"
    fi
    if [[ -f $f ]]; then
        dmode=$(file_mode "${f%/*}"); fmode=$(file_mode "$f")
        if [[ -n $dmode && -n $fmode ]]; then
            if (( (8#$dmode & 8#022) || (8#$fmode & 8#022) )); then
                printf '文件权限: %s✘ .ssh=%s authorized_keys=%s，权限过宽，sshd 会拒绝使用这些公钥%s\n' "$RED" "$dmode" "$fmode" "$PLAIN"
            else
                printf '文件权限: %s✔%s .ssh=%s authorized_keys=%s\n' "$GREEN" "$PLAIN" "$dmode" "$fmode"
            fi
        fi
        grep -q 'Please login as' "$f" 2>/dev/null &&
            warn "部分公钥带有云厂商的登录限制 (Please login as ...)，这些公钥不能直接登录 root"
    fi

    echo
    title "登录方式 (当前生效的配置)"
    eff=$(sshd_effective)
    if [[ -z $eff ]]; then
        if b=$(sshd_bin); then
            error "无法读取 sshd 配置:"
            "$b" -t 2>&1 | sed 's/^/  /'
        else
            error "未找到 sshd，请确认已安装 openssh-server"
        fi
        return 1
    fi
    pw=$(eff_get "$eff" passwordauthentication)
    kbd=$(eff_get "$eff" kbdinteractiveauthentication)
    [[ -z $kbd ]] && kbd=$(eff_get "$eff" challengeresponseauthentication)
    pub=$(eff_get "$eff" pubkeyauthentication)
    root=$(eff_get "$eff" permitrootlogin)
    ports=$(awk '$1 == "port" { printf "%s%s", (n++ ? ", " : ""), $2 }' <<<"$eff")
    printf 'SSH 端口: %s\n' "$ports"
    printf '密钥登录: %s\n' "$(yesno "$pub")"
    printf '密码登录: %s\n' "$(yesno "$pw")"
    printf '键盘交互: %s\n' "$(yesno "$kbd")"
    case $root in
        yes) printf 'root 登录: 允许 (密码和密钥都可以)\n' ;;
        prohibit-password|without-password) printf 'root 登录: 仅允许密钥\n' ;;
        forced-commands-only) printf 'root 登录: 仅允许受限命令\n' ;;
        no)  printf 'root 登录: %s禁止%s\n' "$RED" "$PLAIN" ;;
        *)   printf 'root 登录: %s\n' "$root" ;;
    esac

    echo
    title 配置与服务
    if [[ -f $KEY_ONLY_FILE ]]; then
        printf '只允许密钥: 已配置 (%s)\n' "$KEY_ONLY_FILE"
    elif grep -qxF "$SSHD_MARK_BEGIN" "$SSHD_CONFIG" 2>/dev/null; then
        printf 'portman 配置: 已写入 %s 顶部\n' "$SSHD_CONFIG"
    elif [[ -f $PASSWORD_FILE ]]; then
        printf '密码登录: 已由 portman 强制开启 (%s)\n' "$PASSWORD_FILE"
    else
        printf 'portman 配置: 无 (使用系统默认)\n'
    fi
    echo "密码登录相关设置 (按 sshd 实际读取顺序，第一个生效):"
    ordered_setting_sources PasswordAuthentication | awk -v G="$GREEN" -v Y="$YELLOW" -v P="$PLAIN" '{
        if (NR == 1) { print "    " $0 "  " G "← 生效" P; next }
        if (tolower($0) ~ /[ \t]yes[ \t]*$/) print "    " $0 "  " Y "← 被覆盖，有隐患" P
        else print "    " $0 "  (被覆盖)"
    } END { if (NR == 0) print "    (没有设置，默认开启)" }'
    if err=$("$(sshd_bin)" -t 2>&1); then
        printf '配置检查: %s✔ 通过%s\n' "$GREEN" "$PLAIN"
    else
        printf '配置检查: %s✘ 有错误%s %s\n' "$RED" "$PLAIN" "$err"
    fi
    if svc=$(ssh_service_state); then color=$GREEN; else color=$RED; fi
    printf 'SSH 服务: %s%s%s\n' "$color" "$svc" "$PLAIN"

    echo
    title 结论
    if (( n == 0 )) && [[ $pw == no ]]; then
        printf '%s❌ 密码登录已关闭，但没有任何公钥！请不要断开当前连接，立即写入公钥或恢复密码登录%s\n' "$RED" "$PLAIN"
    elif [[ $pub == yes && $pw == no && $kbd != yes ]] && (( n > 0 )); then
        printf '%s✅ 只允许密钥登录，已生效%s\n' "$GREEN" "$PLAIN"
        risks=$(ssh_risks)
        if [[ -n $risks ]] && key_only_active; then
            printf '%s⚠ 但有 %d 处隐患: 其他配置文件仍写着开启密码登录，目前被覆盖。%s\n' \
                "$YELLOW" "$(wc -l <<<"$risks" | tr -d ' ')" "$PLAIN"
            printf '%s  一旦 00-key-only.conf 被删除或系统重新配置，密码登录会悄悄恢复%s\n' "$YELLOW" "$PLAIN"
            sed 's/^/    /' <<<"$risks"
            echo
            confirm "是否现在加固 (把这些设置改为关闭)?" && ssh_harden -y
        fi
    elif [[ $pw == no ]]; then
        printf '%s⚠ 密码登录已关闭，但键盘交互登录仍开启，仍可能用密码登录%s\n' "$YELLOW" "$PLAIN"
    elif (( n > 0 )); then
        printf '%s⚠ 公钥已写入，但密码登录仍开启。可以使用「一键开启只允许密钥登录」%s\n' "$YELLOW" "$PLAIN"
    else
        printf '%s⚠ 还没有写入公钥，当前使用密码登录%s\n' "$YELLOW" "$PLAIN"
    fi
}

# ---------------------------------------------------------------------------
# SSH 登录记录
# ---------------------------------------------------------------------------
# 日志来源: journal | /var/log/auth.log | /var/log/secure | none
ssh_log_source() {
    if has journalctl && journalctl -q -t sshd -t sshd-session -n 1 -o cat 2>/dev/null | grep -q .; then
        echo journal
    elif [[ -r /var/log/auth.log ]]; then
        echo /var/log/auth.log
    elif [[ -r /var/log/secure ]]; then
        echo /var/log/secure
    else
        echo none
    fi
}

# 读取 sshd 日志: $1 为日志来源，$2 为最近多少小时 (仅 journal 有效，为空表示全部)
# OpenSSH 9.8 起登录相关日志由 sshd-session 进程输出
ssh_log_lines() {
    if [[ $1 == journal ]]; then
        journalctl -q -t sshd -t sshd-session ${2:+--since "$2 hours ago"} -o short-iso --no-pager 2>/dev/null
    else
        grep -E ' sshd(-session)?\[' "$1" 2>/dev/null
    fi
}

# 分析日志，输出带标签的行 (制表符分隔):
#   S 时间 用户 IP 方式 备注    成功登录
#   I 次数 IP                   失败/探测最多的 IP
#   U 次数 用户名               被尝试的用户名
#   T 失败连接数 IP数 密码登录成功次数 首条时间 末条时间
ssh_log_analyze() {
    FPMAP="$1" LC_ALL=C awk '
    BEGIN {
        OFS = "\t"
        n = split(ENVIRON["FPMAP"], a, "\n")
        for (i = 1; i <= n; i++) { split(a[i], b, "|"); if (b[2] != "") fp[b[2]] = b[3] }
    }
    function ts(   t) {
        if ($1 ~ /^[0-9][0-9][0-9][0-9]-/) { t = substr($1, 1, 19); sub("T", " ", t); return t }
        return $1 " " $2 " " $3
    }
    { if (first == "") first = ts(); last = ts() }
    / Accepted / {
        m = ""; f = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "Accepted") { m = $(i + 1); u = $(i + 3); ip = $(i + 5) }
            if ($i ~ /^SHA256:/) f = $i
        }
        if (m == "publickey") { method = "密钥"; note = (f in fp) ? fp[f] : f }
        else { method = (m == "password") ? "密码" : m; note = ""; pwok++ }
        print "S", ts(), u, ip, method, note
        next
    }
    /Failed |Invalid user |authenticating user |invalid user |maximum authentication attempts|Unable to negotiate|banner exchange|Did not receive identification|not allowed because|\[preauth\]/ {
        ip = ""; pt = ""
        for (i = 2; i < NF; i++)
            if ($i == "port" && $(i - 1) ~ /^[0-9a-fA-F.:]+$/ && $(i - 1) ~ /[.:]/) { ip = $(i - 1); pt = $(i + 1); break }
        if (ip == "") next
        sub(/[^0-9].*/, "", pt)
        k = ip " " pt
        # 同一次连接会产生多行日志，按 IP+源端口 去重
        if (!(k in conn)) { conn[k] = 1; nf++; if (!(ip in byip)) nip++; byip[ip]++ }
        u = ""
        for (i = 2; i < NF; i++) {
            if ($i == "user" && ($(i - 1) == "Invalid" || $(i - 1) == "invalid" || $(i - 1) == "authenticating")) u = $(i + 1)
            if ($i == "for" && $(i + 1) != "invalid" && $(i - 1) ~ /^(password|publickey|none)$/) u = $(i + 1)
        }
        if (u != "" && !((k, u) in seenu)) { seenu[k, u] = 1; users[u]++ }
    }
    END {
        for (ip in byip) print "I", byip[ip], ip
        for (u in users) print "U", users[u], u
        print "T", nf + 0, nip + 0, pwok + 0, first, last
    }'
}

ssh_login_log() {
    need_root || return 1
    local hours=${1:-24} src logs result total nip pwok first last me pw
    [[ $hours =~ ^[0-9]+$ && $hours -gt 0 ]] || { error "小时数需要是正整数"; return 1; }

    src=$(ssh_log_source)
    if [[ $src == none ]]; then
        error "找不到 SSH 日志 (journalctl、/var/log/auth.log、/var/log/secure 都不可用)"
        return 1
    fi
    logs=$(ssh_log_lines "$src" "$hours")
    result=$(ssh_log_analyze "$(list_keys)" <<<"$logs")
    IFS=$'\t' read -r _ total nip pwok first last <<<"$(grep '^T' <<<"$result")"
    me=$(awk '{ print $1 }' <<<"${SSH_CONNECTION:-}")

    if [[ $src == journal ]]; then
        title "SSH 登录记录 (最近 $hours 小时)"
        printf '日志来源: systemd journal\n'
    else
        title "SSH 登录记录"
        printf '日志来源: %s (文件里的全部记录: %s ~ %s)\n' "$src" "${first:--}" "${last:--}"
    fi
    echo

    printf '%s失败 / 探测连接:%s ' "$BOLD" "$PLAIN"
    if (( total == 0 )); then
        printf '%s0 次%s\n' "$GREEN" "$PLAIN"
    else
        printf '%s%d 次%s，来自 %d 个 IP\n' "$YELLOW" "$total" "$PLAIN" "$nip"
        echo "尝试最多的 IP:"
        grep '^I' <<<"$result" | sort -t$'\t' -k2,2nr | head -10 |
            awk -F'\t' '{ printf "  %2d. %-20s %d 次\n", NR, $3, $2 }'
        printf '被尝试的用户名: '
        grep '^U' <<<"$result" | sort -t$'\t' -k2,2nr | head -10 |
            awk -F'\t' '{ printf "%s%s(%d)", (NR > 1 ? "  " : ""), $3, $2 } END { print "" }'
    fi
    echo

    printf '%s最近成功登录:%s\n' "$BOLD" "$PLAIN"
    if grep -q '^S' <<<"$result"; then
        grep '^S' <<<"$result" | tail -10 | awk -F'\t' -v me="$me" -v G="$GREEN" -v Y="$YELLOW" -v P="$PLAIN" '{
            mark = ($4 == me) ? "  (当前连接)" : ""
            color = ($5 == "密钥") ? G : Y
            printf "  %s  %-6s %-16s %s%s%s %s%s\n", $2, $3, $4, color, $5, P, $6, mark
        }'
    else
        echo "  (没有记录)"
    fi
    echo

    printf '%s当前在线:%s\n' "$BOLD" "$PLAIN"
    if has who && [[ -n $(who 2>/dev/null) ]]; then
        who | sed 's/^/  /'
    else
        echo "  (没有)"
    fi
    echo

    printf '%s结论:%s\n' "$BOLD" "$PLAIN"
    pw=$(eff_get "$(sshd_effective)" passwordauthentication)
    if [[ $pw == no ]]; then
        printf '  %s✔ 密码登录已关闭，以上失败尝试都不可能成功，不需要 fail2ban%s\n' "$GREEN" "$PLAIN"
    elif (( total > 0 )); then
        printf '  %s⚠ 密码登录仍开启，并且有人在尝试登录，建议开启「只允许密钥登录」%s\n' "$YELLOW" "$PLAIN"
    fi
    if (( pwok > 0 )); then
        printf '  %s⚠ 有 %d 次通过密码登录成功的记录，请确认是你本人%s\n' "$YELLOW" "$pwok" "$PLAIN"
    fi
    echo "  请确认「最近成功登录」里的 IP 都是你自己的"
}

# ---------------------------------------------------------------------------
# 公钥管理
# ---------------------------------------------------------------------------
# 日志中的公钥登录记录，每行: 时间|客户端IP|客户端端口|指纹
key_login_events() {
    local src
    src=$(ssh_log_source)
    [[ $src == none ]] && return 0
    ssh_log_lines "$src" | grep 'Accepted publickey' | awk '{
        t = $1
        if (t ~ /^[0-9][0-9][0-9][0-9]-/) { t = substr(t, 1, 16); sub("T", " ", t) } else t = $1 " " $2 " " $3
        ip = ""; pt = ""; f = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "from") ip = $(i + 1)
            if ($i == "port" && pt == "") pt = $(i + 1)
            if ($i ~ /^SHA256:/) f = $i
        }
        if (f != "") print t "|" ip "|" pt "|" f
    }'
}

# 当前 SSH 连接所用公钥的指纹: $1 为 key_login_events 的输出
current_key_fp() {
    local ip port
    read -r ip port _ <<<"${SSH_CONNECTION:-}"
    [[ -n $port ]] || return 0
    awk -F'|' -v ip="$ip" -v pt="$port" '$2 == ip && $3 == pt { f = $4 } END { print f }' <<<"$1"
}

# 显示带编号的公钥列表，标出最近使用时间和当前连接所用的密钥
# 设置全局变量 KEY_LINES (编号对应的文件行号) 和 KEY_TOTAL
print_keys_detail() {
    local events cur
    events=$(key_login_events)
    cur=$(current_key_fp "$events")
    KEY_LINES=$(key_entries | cut -d'|' -f1 | tr '\n' ' ')
    KEY_TOTAL=$(wc -w <<<"$KEY_LINES" | tr -d ' ')
    if (( KEY_TOTAL == 0 )); then
        echo "  (没有公钥)"; return
    fi
    { echo "$events"; echo "--"; key_entries; } | awk -F'|' -v cur="$cur" \
        -v C="$CYAN" -v G="$GREEN" -v Y="$YELLOW" -v P="$PLAIN" '
        $0 == "--" { phase = 1; next }
        phase == 0 { if ($4 != "") last[$4] = $1; next }
        {
            used = ($3 in last) ? "最近使用 " last[$3] : "日志中没有使用记录"
            mark = ($3 == cur && cur != "") ? "  " G "← 当前连接正在使用" P : ""
            printf "  %d. %s%-8s%s %s  %s%s%s\n     %s%s\n", ++k, C, $2, P, $3, Y, $4, P, used, mark
        }'
}

# 把 "1,3" 这样的编号转为 authorized_keys 的行号 (从大到小，方便删除)
pick_key_lines() {
    local sel=${1// /} tok
    local -a map toks lines=()
    read -ra map <<<"$KEY_LINES"
    [[ -n $sel ]] || return 1
    IFS=',' read -ra toks <<<"$sel"
    for tok in "${toks[@]}"; do
        if [[ ! $tok =~ ^[0-9]+$ ]] || (( tok < 1 || tok > KEY_TOTAL )); then
            error "无效的编号: $tok (可选 1-$KEY_TOTAL)"; return 1
        fi
        lines+=("${map[tok - 1]}")
    done
    printf '%s\n' "${lines[@]}" | sort -rnu
}

ssh_delete_keys() {
    need_root || return 1
    local f sel lines n remain pw cur_fp cur_hit="" line entries
    f=$(auth_keys_file)
    echo "当前公钥:"
    print_keys_detail
    (( KEY_TOTAL > 0 )) || return 0
    echo
    read -rp "输入要删除的编号 (多个用逗号分隔，如 2,3；直接回车取消): " sel
    [[ -n $sel ]] || { cancelled; return 0; }
    lines=$(pick_key_lines "$sel") || return 1
    n=$(grep -c . <<<"$lines")
    remain=$((KEY_TOTAL - n))

    pw=$(eff_get "$(sshd_effective)" passwordauthentication)
    if (( remain == 0 )) && [[ $pw == no ]]; then
        error "密码登录已关闭，删除全部公钥后将无法登录服务器，已拒绝。请至少保留一个公钥"
        return 1
    fi
    (( remain == 0 )) && warn "删除后将没有任何公钥，只能用密码登录"

    # 检查是否包含当前连接使用的密钥
    cur_fp=$(current_key_fp "$(key_login_events)")
    if [[ -n $cur_fp ]]; then
        entries=$(key_entries)
        for line in $lines; do
            [[ $(awk -F'|' -v l="$line" '$1 == l { print $3 }' <<<"$entries") == "$cur_fp" ]] && cur_hit=1
        done
    fi
    if [[ -n $cur_hit ]]; then
        warn "其中包含你当前连接正在使用的密钥！当前连接不会断开，但之后将无法再用它登录"
        confirm_yes "确定删除" || { cancelled; return 0; }
    else
        confirm "确认删除这 $n 个公钥?" || { cancelled; return 0; }
    fi

    cp -p "$f" "$f.bak-portman"
    for line in $lines; do sed -i "${line}d" "$f"; done
    info "已删除 $n 个公钥 (原文件备份为 $f.bak-portman)"
    echo "剩余公钥:"
    print_keys_detail
}

# 修改 authorized_keys 第 $1 行公钥的备注为 $2 (为空则清除)
set_key_comment() {
    local f line=$1 comment=$2 old prefix tmp
    f=$(auth_keys_file)
    old=$(sed -n "${line}p" "$f")
    [[ $old =~ ^(.*(ssh-[a-z0-9-]+|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+)[[:space:]]+[A-Za-z0-9+/]+=*) ]] || return 1
    prefix=${BASH_REMATCH[1]}
    tmp=$(mktemp)
    NEWLINE="$prefix${comment:+ $comment}" awk -v l="$line" 'NR == l { print ENVIRON["NEWLINE"]; next } { print }' \
        "$f" >"$tmp"
    cat "$tmp" >"$f"
    rm -f "$tmp"
}

# 逐个询问每个公钥的备注，回车跳过
ssh_rename_key() {
    need_root || return 1
    local f e line fp comment new changed=0 i=0
    local -a entries=()
    f=$(auth_keys_file)
    echo "当前公钥:"
    print_keys_detail
    (( KEY_TOTAL > 0 )) || return 0
    echo
    echo "依次输入每个公钥的新备注 (如 iPhone / Windows / MacBook)，直接回车保持不变，输入 - 清除备注"
    cp -p "$f" "$f.bak-portman"
    while IFS= read -r e; do entries+=("$e"); done <<<"$(key_entries)"
    for e in "${entries[@]}"; do
        IFS='|' read -r line _ fp comment <<<"$e"
        i=$((i + 1))
        read -rp "  $i. ${fp:0:20}… 当前: $comment → " new || new=""
        new=$(tr -d '\r\n' <<<"$new")
        [[ -z $new ]] && continue
        [[ $new == - ]] && new=""
        set_key_comment "$line" "$new" && changed=$((changed + 1))
    done
    echo
    if (( changed > 0 )); then
        info "已修改 $changed 个备注 (原文件备份为 $f.bak-portman)"
        print_keys_detail
        echo
        info "其他服务器想加上同样的备注，可以用「生成批量备注命令」"
    else
        info "没有修改"
    fi
}

# 按指纹批量设置备注，用于在多台服务器上统一备注
#   参数: 指纹前缀=备注 ...  例如 FkK2Q24cqy46=iPhone
ssh_label_keys() {
    need_root || return 1
    local f arg pfx name entries line fp hit applied=0
    (( $# > 0 )) || { error "用法: portman ssh label 指纹前缀=备注 ...  (指纹前缀可在「管理公钥」里生成)"; return 1; }
    f=$(auth_keys_file)
    [[ -s $f ]] || { error "$f 中没有公钥"; return 1; }
    cp -p "$f" "$f.bak-portman"
    entries=$(key_entries)
    for arg in "$@"; do
        [[ $arg == *=* ]] || { warn "忽略无效参数: $arg"; continue; }
        pfx=${arg%%=*}; name=${arg#*=}
        pfx=${pfx#SHA256:}
        if (( ${#pfx} < 6 )); then warn "指纹前缀太短 (至少 6 位): $pfx"; continue; fi
        hit=""
        while IFS='|' read -r line _ fp _; do
            if [[ ${fp#SHA256:} == "$pfx"* ]]; then
                set_key_comment "$line" "$name" && hit=1
            fi
        done <<<"$entries"
        if [[ -n $hit ]]; then
            printf '  %s✔%s %s → %s\n' "$GREEN" "$PLAIN" "$pfx" "$name"; applied=$((applied + 1))
        else
            printf '  %s-%s %s 这台服务器上没有这个公钥，跳过\n' "$YELLOW" "$PLAIN" "$pfx"
        fi
    done
    info "已设置 $applied 个备注"
}

# 根据当前服务器上已有的备注，生成可在其他服务器执行的批量备注命令
ssh_label_export() {
    local cmd="portman ssh label" n=0 fp comment short
    while IFS='|' read -r _ _ fp comment; do
        [[ -z $fp || $fp == - || $comment == "(无备注)" ]] && continue
        short=${fp#SHA256:}; short=${short:0:12}
        cmd+=" $(printf '%q' "$short=$comment")"
        n=$((n + 1))
    done <<<"$(key_entries)"
    if (( n == 0 )); then
        warn "当前没有带备注的公钥，请先用「修改备注」给公钥起名"
        return 1
    fi
    echo "在其他服务器上执行下面这条命令，即可给相同的公钥加上同样的备注:"
    echo
    printf '  %s%s%s\n' "$CYAN" "$cmd" "$PLAIN"
    echo
    echo "可以存成 Termius 代码片段；新服务器可以接在写入公钥之后:"
    printf '  portman ssh addkey <sshid用户名> && %s && portman ssh keyonly -y\n' "$cmd"
}

ssh_keys_menu() {
    local c
    while true; do
        clear 2>/dev/null
        menu_title 管理公钥
        printf '公钥文件: %s\n\n' "$(auth_keys_file)"
        print_keys_detail
        echo
        echo "  1. 删除公钥"
        echo "  2. 修改备注 (逐个输入，一次改完)"
        echo "  3. 写入新公钥"
        echo "  4. 生成批量备注命令 (在其他服务器上一键加同样的备注)"
        echo "  0. 返回"
        echo
        read -rp "请选择 [0-4]: " c
        echo
        case $c in
            1) ssh_delete_keys ;;
            2) ssh_rename_key ;;
            3) ssh_add_key ;;
            4) ssh_label_export ;;
            0|q|"") return 0 ;;
            *) error "无效选择" ;;
        esac
        echo
        pause
    done
}

# ---------------------------------------------------------------------------
# 安全隐患检测与加固
#   只允许密钥登录靠 00-key-only.conf 抢在最前面生效。其他文件里如果还写着
#   PasswordAuthentication yes 等，一旦 00-key-only.conf 被删，密码登录就会悄悄恢复。
# ---------------------------------------------------------------------------
# 输出: 文件:行号:内容
ssh_risks() {
    local files=("$SSHD_CONFIG")
    [[ -d $SSHD_DIR ]] && files+=("$SSHD_DIR"/*.conf)
    grep -HnEi '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin)[[:space:]]+yes' \
        "${files[@]}" 2>/dev/null | grep -vF -e "$KEY_ONLY_FILE:" -e "$PASSWORD_FILE:"
}

key_only_active() {
    [[ -f $KEY_ONLY_FILE ]] || grep -qxF "$SSHD_MARK_BEGIN" "$SSHD_CONFIG" 2>/dev/null
}

ssh_harden() {
    need_root || return 1
    local auto=${1:-} risks files f b err
    if ! key_only_active; then
        error "还没有开启「只允许密钥登录」，请先开启后再加固"
        return 1
    fi
    risks=$(ssh_risks)
    if [[ -z $risks ]]; then
        info "没有发现隐患，其他配置文件里没有开启密码登录的设置"
        return 0
    fi

    echo "以下设置目前被 portman 的配置覆盖，暂时不生效。"
    echo "但如果 00-key-only.conf 被删除或系统重新配置，它们会让密码登录悄悄恢复:"
    sed 's/^/    /' <<<"$risks"
    echo
    echo "加固会把它们改为: PasswordAuthentication / KbdInteractiveAuthentication no，PermitRootLogin prohibit-password"
    if [[ $auto != -y ]]; then
        confirm "确认加固?" || { cancelled; return 0; }
    fi

    b=$(sshd_bin) || { error "未找到 sshd"; return 1; }
    files=$(cut -d: -f1 <<<"$risks" | sort -u)
    for f in $files; do
        cp -p "$f" "$f.bak-portman"
        awk '{
            l = tolower($0)
            if (l ~ /^[ \t]*(passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication)[ \t]+yes/) sub(/[Yy][Ee][Ss]/, "no")
            else if (l ~ /^[ \t]*permitrootlogin[ \t]+yes/) sub(/[Yy][Ee][Ss]/, "prohibit-password")
            print
        }' "$f.bak-portman" >"$f"
    done

    if ! err=$("$b" -t 2>&1); then
        for f in $files; do cat "$f.bak-portman" >"$f"; done
        error "sshd 配置检查失败，已自动回滚: $err"
        return 1
    fi
    reload_sshd || warn "sshd 重新加载失败，请手动执行: systemctl restart ssh"
    info "✅ 加固完成，已修改 $(wc -l <<<"$risks" | tr -d ' ') 处设置。原文件备份为 *.bak-portman"
}

ssh_menu() {
    local c n pw
    while true; do
        clear 2>/dev/null
        menu_title "SSH 密钥登录"
        if is_root; then
            n=$(key_count)
            pw=$(eff_get "$(sshd_effective)" passwordauthentication)
            printf '  当前: 公钥 %s 个 | 密码登录 %s\n\n' "$n" "$(yesno "$pw")"
        fi
        echo "  1. 查看详细状态 (公钥是否写入、配置是否生效)"
        echo "  2. 写入公钥 (Termius / sshid.io / GitHub / 直接粘贴)"
        echo "  3. 一键开启「只允许密钥登录」(关闭密码登录)"
        echo "  4. 恢复密码登录"
        echo "  5. 查看登录记录 (失败尝试、成功登录、当前在线)"
        echo "  6. 管理公钥 (查看、删除、修改备注)"
        echo "  7. 安全加固 (清除其他配置文件里残留的密码登录设置)"
        echo "  0. 返回主菜单"
        echo
        read -rp "请选择 [0-7]: " c
        echo
        case $c in
            1) ssh_status ;;
            2) ssh_add_key ;;
            3) ssh_key_only ;;
            4) ssh_password_login ;;
            5) read -rp "查看最近多少小时 [默认 24]: " n
               ssh_login_log "${n:-24}" ;;
            6) ssh_keys_menu; continue ;;
            7) ssh_harden ;;
            0|q|"") return 0 ;;
            *) error "无效选择" ;;
        esac
        echo
        pause
    done
}

# ===========================================================================
# 6. 安装维护: 快捷键、更新、卸载、路由模块
# ===========================================================================
# 快捷命令 s / S 是指向 portman 的软链接
is_our_shortcut() {
    [[ -L $1 && $(readlink -f "$1") == "$(readlink -f "$INSTALL_PATH")" ]]
}

setup_shortcuts() {
    need_root || return 1
    local k path existing
    for k in $SHORTCUTS; do
        path="$BIN_DIR/$k"
        existing=$(command -v "$k" 2>/dev/null)
        if is_our_shortcut "$path"; then
            continue
        elif [[ -n $existing && $existing != "$path" ]] || [[ -e $path ]]; then
            warn "系统中已存在命令 $k ($existing)，跳过绑定"
            continue
        fi
        ln -s "$INSTALL_PATH" "$path"
    done
    for k in $SHORTCUTS; do
        if is_our_shortcut "$BIN_DIR/$k"; then
            info "快捷键已绑定: 输入 ${BOLD}$k${PLAIN} 回车即可打开菜单"
            return 0
        fi
    done
}

# 从旧版本更新上来时自动补上快捷命令，不输出任何提示
ensure_shortcuts() {
    is_root && [[ -x $INSTALL_PATH ]] || return 0
    local k
    for k in $SHORTCUTS; do
        [[ -e $BIN_DIR/$k ]] || command -v "$k" >/dev/null 2>&1 || ln -s "$INSTALL_PATH" "$BIN_DIR/$k" 2>/dev/null
    done
}

remove_shortcuts() {
    local k
    for k in $SHORTCUTS; do
        is_our_shortcut "$BIN_DIR/$k" && rm -f "$BIN_DIR/$k"
    done
}

# 下载仓库里的脚本并做语法检查: fetch_script <文件名> <保存到>
fetch_script() {
    download "$RAW_URL/$1" "$2" && bash -n "$2"
}

install_route_module() {
    install -d -m 755 "${ROUTE_MODULE%/*}"
    install -m 755 "$1" "$ROUTE_MODULE"
}

update_self() {
    need_root || return 1
    local tmp module_tmp nft_tmp new
    tmp=$(mktemp)
    module_tmp=$(mktemp)
    nft_tmp=$(mktemp)
    info "正在下载最新版本..."
    # 三个脚本都先通过语法检查，再替换现有程序及模块
    if ! fetch_script portman.sh "$tmp" || ! fetch_script route-report.sh "$module_tmp" ||
       ! fetch_script nft-backend.sh "$nft_tmp"; then
        rm -f "$tmp" "$module_tmp" "$nft_tmp"
        error "下载或语法检查失败，未完成更新；请检查网络"
        return 1
    fi
    install_route_module "$module_tmp"
    install -m 755 "$nft_tmp" "$NFT_MODULE"
    install -m 755 "$tmp" "$INSTALL_PATH"
    rm -f "$tmp" "$module_tmp" "$nft_tmp"

    "$INSTALL_PATH" shortcut >/dev/null
    new=$("$INSTALL_PATH" version)
    if [[ $new == "portman v${VERSION}" ]]; then
        info "已经是最新版本 ($new)。如果刚推送了新版本，GitHub 缓存可能要等几分钟"
    else
        info "已从 v${VERSION} 更新到 ${new#portman }"
    fi
}

uninstall_self() {
    need_root || return 1
    if [[ -f /etc/portman/nftables-pending.mark ]]; then
        error "nftables 回滚等待中，禁止卸载；请先完成验证或等待自动回滚"
        return 1
    fi
    remove_shortcuts
    remove_restore_service
    systemctl disable portman-nftables.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/portman-nftables.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "$INSTALL_PATH" "${STATE_FILE%/*}"
    rm -f "$ROUTE_MODULE" "$NFT_MODULE"
    rmdir "${ROUTE_MODULE%/*}" 2>/dev/null || true
    info "portman 已卸载 (当前防火墙规则保持不变，但重启后不再恢复 portman 的 iptables/nftables 规则)"
    if [[ -f $SYSCTL_FILE ]]; then
        warn "IPv6 仍保持禁用。如需恢复，删除 $SYSCTL_FILE 后重启"
    fi
}

# 运行路由检测模块；模块不存在时先补装
route_dispatch() {
    if [[ ! -r $ROUTE_MODULE ]]; then
        # 从 v1.6.x 升级时，旧版 update 只下载 portman.sh，
        # 所以第一次进入路由功能时从同一仓库补装模块
        need_root || return 1
        local tmp
        tmp=$(mktemp) || return 1
        info "首次使用路由检测，正在补装官方仓库中的路由模块..."
        if fetch_script route-report.sh "$tmp"; then
            install_route_module "$tmp"
            rm -f "$tmp"
            info "路由模块已安装"
        else
            rm -f "$tmp"
            error "路由模块下载或校验失败，请重试或执行 portman update"
            return 1
        fi
    fi
    bash "$ROUTE_MODULE" "$@"
}

# 原生 nftables 模块按需加载：兼容 v1.7.3 的旧更新器（原先只下载两份脚本）。
nft_dispatch() {
    local action=$1 tmp
    shift
    if [[ ! -r $NFT_MODULE ]]; then
        need_root || return 1
        tmp=$(mktemp) || return 1
        info "首次使用 nftables，正在安装官方仓库中的后端模块..."
        if fetch_script nft-backend.sh "$tmp"; then
            install -d -m 755 "${NFT_MODULE%/*}"
            install -m 755 "$tmp" "$NFT_MODULE"
            rm -f "$tmp"
        else
            rm -f "$tmp"
            error "nftables 模块下载/语法检查失败，请执行 portman update"
            return 1
        fi
    fi
    # shellcheck source=nft-backend.sh
    source "$NFT_MODULE"
    nft_dispatch_main "$action" "$@"
}

# ===========================================================================
# 7. 菜单与命令行
# ===========================================================================
usage() {
    cat <<EOF
portman v${VERSION} - VPS 端口查看与管理工具

快捷键: 输入 s (或 S) 回车，等同于 portman，直接打开菜单

【端口】
   1. portman                        打开交互菜单，输入数字选择功能
   2. portman list                   查看所有端口：正在监听的，以及已放行但未使用的
   3. portman public                 只看对公网开放的端口
   4. portman check <端口>           查询某个端口被哪个程序占用
   5. portman open  <端口> [协议]    放行(开启)端口，协议: tcp(默认) / udp / both
   6. portman close <端口> [协议]    关闭端口（删除防火墙放行规则）

【防火墙】
   7. portman lockdown               一键关闭其他端口，只保留正在使用的端口和 SSH
   8. portman unlock                 恢复放行全部端口（撤销第 7 项）
   9. portman fw                     查看防火墙状态和规则

【网络】
  10. portman ip                     查看 IPv4 / IPv6 状态（地址、路由、能否上网）
  11. portman ipv6 off               禁用 IPv6，重启后保持
  12. portman ipv6 on                启用 IPv6，重启后保持

【SSH】
  13. portman ssh                    SSH 密钥登录管理菜单
  14. portman ssh status             查看公钥是否写入、密码登录是否关闭、配置是否生效
  15. portman ssh addkey <来源>      写入公钥，来源可以是 sshid.io 用户名 / 链接 / 公钥本身
  16. portman ssh keyonly [-y]       只允许密钥登录（-y 跳过确认）
  17. portman ssh password           恢复密码登录
  18. portman ssh log [小时]         查看登录记录：失败尝试、成功登录、当前在线（默认 24 小时）
  19. portman ssh keys               管理公钥：查看最近使用时间、删除、修改备注
  20. portman ssh harden [-y]        安全加固：把其他配置文件里残留的密码登录设置改为关闭
      portman ssh label 指纹前缀=备注 ...
                                     按指纹批量加备注，命令可在「管理公钥」里自动生成

【三网路由检测】
  21. portman route                  上海三网回程中文检测（默认）
      portman route menu             路由检测菜单（北京/广州/苏州/自定义）
      portman route mtr --save       MTR 稳定性检测 + 保存报告
      portman route shanghai --detail
                                     展示逐跳中文路径
      portman route set suzhou ct IP 设置苏州电信测试 IP
      portman route help             路由检测的全部用法

【维护】
  22. portman update                 更新到最新版本
  23. portman uninstall              卸载 portman（不影响已有防火墙规则）
  24. portman version                查看当前版本

端口写法:
  8080          单个端口
  80,443        多个端口，用英文逗号分隔
  8000-8100     端口范围

示例:
  portman open 8080                 放行 8080/tcp
  portman open 80,443 tcp           放行 80 和 443 的 tcp
  portman open 10000-10100 both     放行 10000~10100 的 tcp 和 udp
  portman close 8080                关闭 8080/tcp
  portman ssh addkey abc123         从 https://sshid.io/abc123 写入 Termius 公钥
  portman ssh addkey abc123 && portman ssh keyonly -y
                                    新服务器一条命令: 写入公钥并只允许密钥登录
EOF
}

# 主菜单: 按类别分组显示，编号与旧版保持一致
menu() {
    local c port proto
    while true; do
        clear 2>/dev/null
        menu_title "portman v$VERSION · 端口查看与管理"
        if is_our_shortcut "$BIN_DIR/s"; then
            printf '  快捷键: 任意位置输入 %ss%s 回车即可打开本菜单\n' "$CYAN" "$PLAIN"
        fi
        echo
        menu_group "端口"
        echo "   1. 查看所有端口 (正在监听 + 已放行未使用)"
        echo "   2. 只看对公网开放的端口"
        echo "   3. 查询指定端口"
        echo "   4. 放行(开启)端口"
        echo "   5. 关闭端口"
        menu_group "防火墙"
        echo "   6. 一键关闭其他端口 (只保留正在使用的端口)"
        echo "   7. 恢复放行全部端口"
        echo "   8. 查看防火墙状态"
        menu_group "网络"
        echo "   9. 查看 IPv4 / IPv6 状态"
        echo "  10. 开启 / 关闭 IPv6"
        echo "  14. 三网路由检测 (NextTrace 中文报告)"
        menu_group "SSH"
        echo "  11. SSH 密钥登录 (写入公钥、只允许密钥登录)"
        menu_group "维护"
        echo "  12. 更新 portman"
        echo "  13. 卸载 portman"
        echo
        echo "   0. 退出"
        echo
        read -rp "请选择 [0-14]: " c
        echo
        case $c in
            1)  show_ports all ;;
            2)  show_ports public ;;
            3)  read -rp "端口号: " port
                if [[ $port =~ ^[0-9]+$ ]]; then show_ports "$port"; else error "请输入单个端口号"; fi ;;
            4|5)
                read -rp "端口 (如 8080 / 80,443 / 8000-8100): " port
                read -rp "协议 tcp/udp/both [默认 tcp]: " proto
                if [[ $c == 4 ]]; then open_port "$port" "${proto:-tcp}"; else close_port "$port" "${proto:-tcp}"; fi ;;
            6)  lockdown ;;
            7)  unlock ;;
            8)  show_firewall ;;
            9)  show_ip_status ;;
            10) ipv6_menu ;;
            11) ssh_menu; continue ;;
            12) if update_self; then
                    # 用新版本替换当前进程，直接进入新菜单
                    echo; pause
                    exec "$INSTALL_PATH"
                fi ;;
            13) uninstall_self && exit 0 ;;
            14) route_dispatch menu; continue ;;
            0|q) exit 0 ;;
            *)  error "无效选择" ;;
        esac
        echo
        pause
    done
}

main() {
    [[ ${1:-} == uninstall || ${1:-} == restore || ${1:-} == nft-restore || ${1:-} == nft-rollback ]] || ensure_shortcuts
    case ${1:-} in
        restore)         restore_rules ;;
        nft-restore)     nft_dispatch restore ;;
        nft-rollback)    nft_dispatch rollback ;;
        "")              menu ;;
        list|ls|l)       show_ports all ;;
        public|pub)      show_ports public ;;
        check|c)
            [[ ${2:-} =~ ^[0-9]+$ ]] || { error "用法: portman check <端口>"; exit 1; }
            show_ports "$2" ;;
        open|allow)      [[ -n ${2:-} ]] || { usage; exit 1; }; open_port "$2" "${3:-tcp}" ;;
        close|deny)      [[ -n ${2:-} ]] || { usage; exit 1; }; close_port "$2" "${3:-tcp}" ;;
        lockdown|lock)   lockdown ;;
        unlock)          unlock ;;
        fw|firewall)     show_firewall ;;
        ip)              show_ip_status ;;
        ipv6)
            case ${2:-} in
                on)  ipv6_enable ;;
                off) ipv6_disable ;;
                *)   ipv6_menu ;;
            esac ;;
        ssh)
            case ${2:-} in
                status)       ssh_status ;;
                addkey|key)   ssh_add_key "${*:3}" ;;
                keyonly)      ssh_key_only "${3:-}" ;;
                password)     ssh_password_login ;;
                log)          ssh_login_log "${3:-24}" ;;
                keys)         ssh_keys_menu ;;
                delkey)       ssh_delete_keys ;;
                label)        shift 2; ssh_label_keys "$@" ;;
                harden)       ssh_harden "${3:-}" ;;
                *)            ssh_menu ;;
            esac ;;
        route)           shift; route_dispatch "$@" ;;
        update)          update_self ;;
        uninstall)       uninstall_self ;;
        shortcut)        setup_shortcuts ;;
        version|-v|--version) echo "portman v${VERSION}" ;;
        help|-h|--help)  usage ;;
        *)               error "未知命令: $1"; echo; usage; exit 1 ;;
    esac
}

# 被 source 时只加载函数 (便于测试)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
