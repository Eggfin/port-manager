#!/usr/bin/env bash
# 离线回归测试：portman REALITY 本机 HTTPS 网站集成（端口自动检测、一键放行、lockdown 保护、状态查看与子进程隔离）
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_DIR=$PWD

pass=0
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
ok()   { printf '[PASS] %s\n' "$*"; pass=$((pass + 1)); }

# 1. 语法检查
for f in portman.sh install.sh reality-site.sh; do
    bash -n "$f" || fail "bash -n failed: $f"
done
ok "脚本语法检查通过 (portman.sh / install.sh / reality-site.sh)"

temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

# 2. keep_list 自动检测 REALITY 状态文件并保留 TCP 80
(
    # shellcheck source=../portman.sh
    source "$REPO_DIR/portman.sh"
    collect_listen() { printf 'tcp|0.0.0.0|22|sshd(100)\ntcp|0.0.0.0|443|xray(200)\n'; }
    ssh_ports() { printf '22\n'; }

    REALITY_STATE_FILE="$temp/nonexistent.state"
    out_no_state=$(keep_list)
    if grep -qE '^tcp 80 ' <<<"$out_no_state"; then
        fail "未部署 REALITY 时不应自动添加 tcp 80: $out_no_state"
    fi

    REALITY_STATE_FILE="$temp/reality-site.state"
    printf 'domain=example.com\nlocal_port=8443\nstatus=active\n' > "$REALITY_STATE_FILE"
    out_with_state=$(keep_list)
    grep -qE '^tcp 80 REALITY-HTTP-01$' <<<"$out_with_state" || fail "部署 REALITY 后 keep_list 未保留 tcp 80: $out_with_state"
    grep -qE '^tcp 22 ' <<<"$out_with_state" || fail "keep_list 丢失 SSH 端口"
    grep -qE '^tcp 443 ' <<<"$out_with_state" || fail "keep_list 丢失 443 端口"
)
ok "lockdown keep_list 自动识别 reality-site.state 并保留 TCP 80"

# 3. fw_port_state 防火墙端口放行判断
(
    # shellcheck source=../portman.sh
    source "$REPO_DIR/portman.sh"

    [[ $(fw_port_state none tcp 80) == open ]] || fail "none 防火墙应返回 open"

    fw_default_open() { return 0; }
    [[ $(fw_port_state ufw tcp 80) == open ]] || fail "默认放行防火墙应返回 open"

    fw_default_open() { return 1; }
    fw_rule_list() { printf 'tcp:22\ntcp:80\ntcp:400-500\nudp:51820\n'; }
    [[ $(fw_port_state ufw tcp 80) == open ]] || fail "tcp:80 应匹配 open"
    [[ $(fw_port_state ufw tcp 443) == open ]] || fail "tcp:400-500 应匹配 443 open"
    [[ $(fw_port_state ufw tcp 8080) == closed ]] || fail "未放行端口应返回 closed"
    [[ $(fw_port_state ufw tcp 51820) == closed ]] || fail "仅 udp 放行时 tcp 应返回 closed"

    fw_rule_list() { printf 'any:80\n'; }
    [[ $(fw_port_state iptables tcp 80) == open ]] || fail "any:80 应匹配 tcp 80"
)
ok "fw_port_state 正确解析单端口、端口范围和协议匹配"

# 4. reality_check_ports 自动检测与一键放行
(
    # shellcheck source=../portman.sh
    source "$REPO_DIR/portman.sh"
    is_root() { return 0; }
    need_root() { return 0; }
    detect_firewall() { echo ufw; }
    fw_default_open() { return 1; }
    fw_rule_list() { printf 'tcp:22\n'; }

    opened_log="$temp/opened.log"
    open_port() { printf '%s|%s\n' "$1" "$2" >> "$opened_log"; }

    # --open 自动放行 80,443
    : > "$opened_log"
    out=$(reality_check_ports --open)
    grep -Fq '80,443|tcp' "$opened_log" || fail "--open 应自动放行 80,443/tcp"
    grep -Fq '未放行' <<<"$out" || fail "输出应提示未放行"

    # --prompt 回车默认一键放行
    : > "$opened_log"
    printf '\n' | reality_check_ports --prompt >/dev/null
    grep -Fq '80,443|tcp' "$opened_log" || fail "--prompt 默认回车应一键放行 80,443/tcp"

    # --prompt 输入 n 跳过放行
    : > "$opened_log"
    out_skip=$(printf 'n\n' | reality_check_ports --prompt)
    [[ ! -s "$opened_log" ]] || fail "--prompt 输入 n 不应调用 open_port"
    grep -Fq '已跳过放行' <<<"$out_skip" || fail "跳过后应有提示"

    # 80 已放行、443 未放行 -> 仅放行 443
    fw_rule_list() { printf 'tcp:22\ntcp:80\n'; }
    : > "$opened_log"
    reality_check_ports --open >/dev/null
    grep -Fxq '443|tcp' "$opened_log" || fail "仅 443 未放行时应只放行 443/tcp"
)
ok "reality_check_ports 自动检测与一键放行 (80/443) 正常"

# 5. reality_status 状态与 Caddyfile 篡改检测
(
    # shellcheck source=../portman.sh
    source "$REPO_DIR/portman.sh"
    is_root() { return 0; }
    detect_firewall() { echo none; }

    REALITY_STATE_FILE="$temp/missing.state"
    REALITY_CONFIG_FILE="$temp/Caddyfile"
    REALITY_WEBROOT="$temp/www"
    out_empty=$(reality_status)
    grep -Fq '尚未通过本工具部署' <<<"$out_empty" || fail "无状态文件时应提示未部署"

    mkdir -p "$REALITY_WEBROOT"
    printf '<h1>ok</h1>\n' > "$REALITY_WEBROOT/index.html"
    printf 'https://demo.example.com:8443 {}\n' > "$REALITY_CONFIG_FILE"
    if command -v sha256sum >/dev/null 2>&1; then
        sha=$(sha256sum "$REALITY_CONFIG_FILE" | awk '{print $1}')
    else
        sha=$(shasum -a 256 "$REALITY_CONFIG_FILE" | awk '{print $1}')
    fi
    REALITY_STATE_FILE="$temp/active.state"
    cat > "$REALITY_STATE_FILE" <<EOF
domain=demo.example.com
local_port=8443
email=ops@example.com
cert_mode=http
status=active
config_sha256=$sha
EOF
    out_ok=$(reality_status)
    grep -Fq 'demo.example.com' <<<"$out_ok" || fail "status 应展示域名"
    grep -Fq '127.0.0.1:8443' <<<"$out_ok" || fail "status 应展示 Target/Dest"
    grep -Fq '正常' <<<"$out_ok" || fail "Caddyfile 未修改时应显示正常"

    printf '# edited\n' >> "$REALITY_CONFIG_FILE"
    out_mod=$(reality_status)
    grep -Fq '已被手工修改' <<<"$out_mod" || fail "Caddyfile 修改后应提示已被手工修改"
)
ok "reality_status 展示站点信息、3X-UI 参数和 Caddyfile 校验正常"

# 6. reality_deploy 子进程调用与退出码透传
(
    # shellcheck source=../portman.sh
    source "$REPO_DIR/portman.sh"
    is_root() { return 0; }
    need_root() { return 0; }
    detect_firewall() { echo none; }

    REALITY_MODULE="$temp/mock-reality-site.sh"
    cat > "$REALITY_MODULE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'MOCK_REALITY_ARGS=%s\n' "$*"
exit "${MOCK_RC:-0}"
EOF
    chmod +x "$REALITY_MODULE"

    out_dep=$(reality_deploy)
    grep -Fq 'MOCK_REALITY_ARGS=--deploy' <<<"$out_dep" || fail "reality_deploy 未以 --deploy 调用模块"

    rc=0
    MOCK_RC=2 reality_deploy >/dev/null || rc=$?
    [[ $rc -eq 2 ]] || fail "reality_deploy 应透传子进程退出码 2，实际为 $rc"
)
ok "reality_deploy 子进程隔离调用与退出码透传正常"

# 7. 内置 reality-site.sh 核心纯函数冒烟验证
(
    # shellcheck source=../reality-site.sh
    source "$REPO_DIR/reality-site.sh"
    [[ $(platform_family ubuntu 24.04) == apt ]] || fail "Ubuntu 24.04 应识别为 apt"
    [[ $(platform_family debian 13) == apt ]] || fail "Debian 13 应识别为 apt"
    [[ $(platform_family rocky 9.4) == dnf ]] || fail "Rocky 9.4 应识别为 dnf"
    valid_domain "sub.example.com" || fail "合法域名校验失败"
    ! valid_domain "https://example.com" || fail "非法域名应被拒绝"
    valid_port 8443 || fail "8443 应为合法端口"
    ! valid_port 2019 || fail "2019 (Caddy 管理端口) 应被拒绝"
    cf=$(write_caddyfile "sub.example.com" 8443 "ops@example.com" "/var/www/reality-site")
    grep -Fq 'https://sub.example.com:8443' <<<"$cf" || fail "生成的 Caddyfile 缺少站点地址"
    grep -Fq 'bind 127.0.0.1' <<<"$cf" || fail "生成的 Caddyfile 缺少 bind 127.0.0.1"
)
ok "reality-site.sh 核心校验与 Caddyfile 生成正常"

printf '\n全部通过 (%d 项)\n' "$pass"
