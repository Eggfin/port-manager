#!/usr/bin/env bash
# 中文交互式 REALITY 本机网站部署器。上传后运行：sudo bash reality-site.sh
# 本文件使用 UTF-8 / LF。直接进入部署，必要检查自动执行；异常时说明原因。
# HTTP-01 仅在验证期间临时使用80；网站不提供常驻HTTP入口或自动跳转。
# 接受的适配目标：Ubuntu 20.04/22.04/24.04/26.04，Debian 11/12/13，CentOS Stream 9/10，
# AlmaLinux/Rocky/RHEL/Oracle Linux 8/9/10，Fedora 43/44/45；x86_64 或 aarch64。
# 安装分支不等于实机验证通过；按系统识别，不按 VPS 商家识别。
set -Eeuo pipefail
set +x
export LC_ALL=C

CONFIG=/etc/caddy/Caddyfile
STATE=/etc/caddy/reality-site.state
WEBROOT=/var/www/reality-site
BACKUP_ROOT=/var/backups/reality-site
DOMAIN=''
LOCAL_PORT=8443
EMAIL=''
MANAGED=0
BACKUP=''
STAGE=''
VALIDATION=''
CADDY_INSTALL_MASKED=0
CADDY_INSTALLED_NEW=0
CADDY_CONFIG_APPLIED=0
LOCK_FILE=/run/lock/reality-site.lock

say() { printf '\n%s\n' "$*"; }
die() { printf '\n停止：%s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
state_value() { awk -F= -v key="$1" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$STATE"; }

write_state() {
    printf 'domain=%s\nlocal_port=%s\nemail=%s\ncert_mode=http\nstatus=%s\nconfig_sha256=%s\n' \
        "$DOMAIN" "$LOCAL_PORT" "$EMAIL" "${1:-active}" \
        "$(sha256sum "$CONFIG" | awk '{print $1}')"
}

# Pure platform classification used by deployment and local tests.
platform_family() {
    local os_id="$1" version="$2" name="${3:-}" major="${2%%.*}"
    case "$os_id" in
        ubuntu)
            case "$version" in 20.04|22.04|24.04|26.04) printf apt; return 0 ;; esac ;;
        debian)
            case "$version" in 11|12|13) printf apt; return 0 ;; esac ;;
        centos)
            if [[ "$name" == *Stream* && ( "$major" == 9 || "$major" == 10 ) ]]; then
                printf dnf; return 0
            fi ;;
        rhel|almalinux|rocky|ol)
            case "$major" in 8|9|10) printf dnf; return 0 ;; esac ;;
        fedora)
            case "$version" in 43|44|45) printf dnf; return 0 ;; esac ;;
    esac
    printf '本脚本未适配 %s %s。接受 Ubuntu 20.04/22.04/24.04/26.04、Debian 11/12/13、CentOS Stream 9/10、Alma/Rocky/RHEL/Oracle Linux 8/9/10、Fedora 43/44/45；旧版 CentOS Linux 不在范围内。' "$os_id" "$version"
    return 1
}

supported_arch() { [[ "$1" == x86_64 || "$1" == aarch64 ]]; }

# DNF5 uses a different COPR plugin package. Prefer its explicit executable so
# minimal/newer images do not accidentally install only the DNF4 plugin.
dnf_command() { if has dnf5; then printf dnf5; else printf dnf; fi; }

caddy_copr_target() {
    local os_id="$1" major="${2%%.*}" architecture="$3"
    case "$os_id" in
        fedora) printf 'fedora-%s-%s' "$major" "$architecture" ;;
        centos|rhel|almalinux|rocky|ol) printf 'epel-%s-%s' "$major" "$architecture" ;;
        *) return 1 ;;
    esac
}

load_system_info() {
    [[ -r /etc/os-release ]] || die '版本不兼容：无法读取 /etc/os-release，不能识别系统版本。'
    # shellcheck disable=SC1091
    . /etc/os-release
}

check_system_compatibility() {
    local result architecture
    [[ $(uname -s) == Linux ]] || die '系统不兼容：此脚本仅支持 Linux。'
    load_system_info
    if ! result=$(platform_family "${ID:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}"); then
        printf '\n版本不兼容：%s\n%s\n' "${PRETTY_NAME:-${ID:-未知系统} ${VERSION_ID:-}}" "$result" >&2
        exit 1
    fi
    FAMILY="$result"
    architecture=$(uname -m)
    supported_arch "$architecture" || die "架构不兼容：$architecture；目前只适配 x86_64 和 aarch64。"
}

valid_domain() {
    local name="$1" label
    [[ ${#name} -le 253 && "$name" == *.* && "$name" != *..* ]] || return 1
    [[ "$name" =~ ^[a-z0-9.-]+$ && ! "$name" =~ ^[0-9.]+$ ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$name"
    [[ "$name" != .* && "$name" != *. ]] || return 1
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}

valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{3,4}$ ]] || return 1
    (( 10#$1 >= 1024 && 10#$1 <= 65535 )) || return 1
    [[ "$1" != 2019 ]]
}

port_lines() { ss -H -lntp "sport = :$1"; }
port_busy() {
    local lines
    lines=$(port_lines "$1") || die "无法检查 TCP $1，不能把检查失败当作端口空闲。"
    [[ -n "$lines" ]]
}

suggest_local_port() {
    local preferred="${1:-8443}" candidate
    for candidate in "$preferred" 8443 9443 10443 11443 12443 14443 16443; do
        if ! port_busy "$candidate"; then printf '%s' "$candidate"; return 0; fi
    done
    return 1
}

ask_local_port() {
    local recommended answer
    if (( MANAGED )); then
        printf '复用本机网站端口：%s（更改已部署端口需同步修改 Xray Target）。\n' "$LOCAL_PORT"
        return 0
    fi
    recommended=$(suggest_local_port "$LOCAL_PORT") || die '常用候选端口均被占用，请先查明占用情况。'
    if [[ "$recommended" != "$LOCAL_PORT" ]]; then
        printf '\nTCP %s 已占用：\n' "$LOCAL_PORT"
        port_lines "$LOCAL_PORT"
        printf '已推荐空闲的本机端口：%s。\n' "$recommended"
    fi
    while true; do
        read -r -p "本机 HTTPS 端口 [$recommended]：" answer
        answer=${answer:-$recommended}
        if ! valid_port "$answer"; then
            printf '端口需为 1024–65535、不带前导零，且不能是 Caddy 管理端口 2019，请重新填写。\n'
            continue
        fi
        if port_busy "$answer"; then
            printf 'TCP %s 已占用：\n' "$answer"
            port_lines "$answer"
            recommended=$(suggest_local_port "$LOCAL_PORT") || die '常用候选端口均被占用。'
            printf '可改用推荐端口 %s，或填写其他空闲端口。\n' "$recommended"
            continue
        fi
        LOCAL_PORT="$answer"
        return 0
    done
}

check_platform() {
    check_system_compatibility
    [[ $EUID -eq 0 ]] || die '部署请使用 root，或运行 sudo bash reality-site.sh。'
    [[ -d /run/systemd/system ]] || die '当前不是运行中的 systemd 系统。'
    local package_manager
    if [[ $FAMILY == apt ]]; then package_manager=apt-get; else package_manager=$(dnf_command); fi
    has "$package_manager" || die "没有找到 $package_manager。"
    for tool in ss awk sha256sum flock getent runuser; do
        if ! has "$tool"; then
            if [[ $FAMILY == apt ]]; then
                die "缺少 $tool。此系统的基础工具包为 iproute2、util-linux、gawk、coreutils、libc-bin；请补齐缺失工具后重试。"
            else
                die "缺少 $tool。此系统的基础工具包为 iproute、util-linux、gawk、coreutils、glibc-common；请补齐缺失工具后重试。"
            fi
        fi
    done
}

check_ownership() {
    local certificate_mode
    MANAGED=0
    [[ ! -L "$CONFIG" && ! -L "$STATE" && ! -L "$WEBROOT" ]] || die '配置或网站路径是符号链接，需要人工确认。'
    if [[ -f "$STATE" ]]; then
        [[ -f "$CONFIG" ]] || die '找到部署记录但没有 Caddyfile，需要人工确认。'
        [[ $(state_value config_sha256) == "$(sha256sum "$CONFIG" | awk '{print $1}')" ]] ||
            die 'Caddyfile 在上次部署后被手工改过；为保留这些改动，脚本停止。'
        MANAGED=1
        DOMAIN=$(state_value domain)
        LOCAL_PORT=$(state_value local_port)
        EMAIL=$(state_value email)
        certificate_mode=$(state_value cert_mode)
        [[ -z "$certificate_mode" || "$certificate_mode" == http ]] ||
            die '此精简版只支持 HTTP-01，不能自动更新其他证书验证方式的旧部署；原配置和续期任务保持原样，请先人工迁移。'
        if ! valid_domain "$DOMAIN" || ! valid_port "$LOCAL_PORT"; then die '已有部署记录内容异常。'; fi
    elif has caddy || [[ -e "$CONFIG" || -e "$WEBROOT" ]] ||
         [[ $(systemctl show caddy -p LoadState --value 2>/dev/null) =~ ^(loaded|masked)$ ]]; then
        die "发现已安装的 Caddy、服务或网站文件，但没有本脚本的部署记录。为保留原站点，本次已停止；请先人工审阅 $CONFIG 并决定如何合并，仅安装过 Caddy 也不会自动覆盖。"
    fi
}

managed_caddy_owns_listeners() {
    local listeners="$1" service_pid listener_pid found=0
    (( MANAGED )) || return 1
    service_pid=$(systemctl show caddy -p MainPID --value 2>/dev/null) || return 1
    [[ "$service_pid" =~ ^[1-9][0-9]*$ && "$listeners" == *'"caddy"'* ]] || return 1
    # A matching process name alone is insufficient: every reported owner must
    # be the main process of the systemd service we are about to reload.
    while [[ "$listeners" =~ pid=([0-9]+) ]]; do
        listener_pid=${BASH_REMATCH[1]}
        [[ "$listener_pid" == "$service_pid" ]] || return 1
        found=1
        listeners=${listeners#*"pid=$listener_pid"}
    done
    (( found ))
}

check_available() {
    local port lines
    local -a ports=(80 "$LOCAL_PORT" 2019)
    for port in "${ports[@]}"; do
        lines=$(port_lines "$port")
        [[ -n "$lines" ]] || continue
        if managed_caddy_owns_listeners "$lines"; then
            continue
        fi
        printf '%s\n' "$lines" >&2
        if [[ "$port" == 80 ]]; then
            die 'TCP 80 已被其他服务占用。本版仅支持 HTTP-01，需要公网80可达且验证时可用；请先确认占用用途并处理，本次不会停止占用进程。'
        fi
        die "TCP $port 已被占用。请先查明用途；脚本不会结束进程。"
    done
}

ask_settings() {
    local answer old_domain="$DOMAIN" old_port="$LOCAL_PORT" old_email="$EMAIL"
    read -r -p "网站域名（只填域名）${DOMAIN:+ [$DOMAIN]}：" answer
    DOMAIN=${answer:-$DOMAIN}; DOMAIN=${DOMAIN,,}
    valid_domain "$DOMAIN" || die '域名格式不正确；不要填写 https://、端口、路径或通配符。'
    ask_local_port
    read -r -p "证书联系邮箱（可留空）${EMAIL:+ [$EMAIL]}：" answer
    EMAIL=${answer:-$EMAIL}
    [[ -z "$EMAIL" || "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die '邮箱格式不正确。'
    if (( MANAGED )); then
        [[ "$DOMAIN" == "$old_domain" && "$LOCAL_PORT" == "$old_port" && "$EMAIL" == "$old_email" ]] ||
            die '重复运行支持检查与修复同一站点；更换域名/端口请人工迁移配置，避免意外影响现有节点。'
    fi
    check_available
    getent ahosts "$DOMAIN" >/dev/null || die '本机无法解析该域名。请确认 A/AAAA 记录后重试。'
    say '=== 即将执行的部署 ==='
    printf '域名：%s\n本机网站：127.0.0.1:%s\n网页目录：%s\n' "$DOMAIN" "$LOCAL_PORT" "$WEBROOT"
    if (( MANAGED )); then
        printf '已识别本脚本部署的站点：复用现有 Caddy、域名和证书缓存，备份并更新配置后重载。\n'
    else
        printf '安装官方 Caddy 软件包，写入网站配置，启用并启动 Caddy。\n'
    fi
    printf '证书固定使用 HTTP-01，由 Caddy 自动申请和续期；验证时临时监听80，用完释放。\n'
    printf '网站不提供常驻HTTP网页或HTTP跳转。\n'
    printf '公网 TCP 443 预留给 Xray；REALITY 入站需在 3X-UI 中配置。\n'
    printf '不会修改 SSH、防火墙、安全组、Xray、3X-UI 或系统网络参数。\n'
    printf '请确认：用于访问网站的 A/AAAA 指向本机，已关闭 CDN 代理。\n'
    printf 'HTTP 验证要求公网 TCP 80 确实可达，续期时也需要保持可用。\n'
    if has getenforce && [[ $(getenforce) == Enforcing ]]; then
        printf 'SELinux 为 Enforcing；会保留此状态。自定义网站端口还需符合本机 SELinux 策略。\n'
    fi
    read -r -p '确认以上条件并授权此部署，请输入 DEPLOY（其他输入退出）：' answer
    [[ "$answer" == DEPLOY ]] || { say '已退出。'; exit 0; }
}

install_caddy() {
    (( MANAGED )) && return 0
    local package_manager copr_plugin copr_target
    local -a dependencies
    say '安装官方 Caddy 软件包……'
    # Debian packages start the default :80 site automatically. Mask only this new
    # Caddy unit until our final configuration is ready.
    systemctl mask caddy.service
    CADDY_INSTALL_MASKED=1
    CADDY_INSTALLED_NEW=1
    if [[ $FAMILY == apt ]]; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg apt-transport-https debian-keyring debian-archive-keyring
        curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 \
            https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$STAGE/caddy.key"
        gpg --batch --yes --dearmor -o "$STAGE/caddy.gpg" "$STAGE/caddy.key"
        curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 \
            https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o "$STAGE/caddy.list"
        install -m 644 "$STAGE/caddy.gpg" /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        install -m 644 "$STAGE/caddy.list" /etc/apt/sources.list.d/caddy-stable.list
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
    else
        package_manager=$(dnf_command)
        if [[ "$package_manager" == dnf5 ]]; then copr_plugin=dnf5-plugins; else copr_plugin=dnf-plugins-core; fi
        copr_target=$(caddy_copr_target "$ID" "$VERSION_ID" "$(uname -m)")
        dependencies=(ca-certificates)
        # Minimal EL images may already provide curl through curl-minimal, which
        # conflicts with the full curl package. Keep the working executable.
        if ! has curl; then dependencies+=(curl); fi
        dependencies+=("$copr_plugin")
        "$package_manager" install -y "${dependencies[@]}" || die '安装 Caddy 的基础依赖失败，请检查本系统软件源。'
        # Specify the EL/Fedora build explicitly: derivatives such as Oracle Linux
        # need not be recognized by COPR's automatic distribution detection.
        "$package_manager" copr enable -y @caddy/caddy "$copr_target" || die "无法启用 Caddy 软件源：$copr_target。"
        "$package_manager" install -y caddy || die "安装 Caddy 失败，请检查 $copr_target 软件源和上面的依赖错误。"
    fi
}

unmask_install_caddy() {
    if (( CADDY_INSTALL_MASKED )); then
        systemctl unmask caddy.service
        systemctl daemon-reload
        CADDY_INSTALL_MASKED=0
    fi
}

cleanup_deploy() {
    if (( CADDY_INSTALL_MASKED )); then
        systemctl disable caddy.service >/dev/null 2>&1 || true
        systemctl unmask caddy.service >/dev/null 2>&1 || true
    fi
    if (( CADDY_INSTALLED_NEW && ! CADDY_CONFIG_APPLIED )); then
        systemctl disable --now caddy.service >/dev/null 2>&1 || true
    fi
    [[ -z "$VALIDATION" ]] || rm -f -- "$VALIDATION"
    [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"
}

write_caddyfile() {
    local domain="$1" port="$2" email="${3:-}" root="${4:-/var/www/reality-site}" challenge_bind=0.0.0.0
    # Caddy inherits the site's bind address for ACME unless a global default is
    # set first. Use a public wildcard for challenges; override it below for HTTPS.
    # Go's wildcard IPv6 TCP listener also accepts IPv4 on dual-stack Linux.
    if [[ -r /proc/net/if_inet6 && -n $(</proc/net/if_inet6) ]]; then challenge_bind=::; fi
    printf '# Managed by reality-site.sh. Manual edits disable automatic replacement.\n{\n'
    [[ -z "$email" ]] || printf '    email %s\n' "$email"
    printf '    default_bind %s\n' "$challenge_bind"
    printf '    acme_ca https://acme-v02.api.letsencrypt.org/directory\n'
    printf '    auto_https disable_redirects\n'
    cat <<EOF
    cert_issuer acme {
        disable_tlsalpn_challenge
    }
    default_sni $domain
    servers {
        protocols h1 h2
    }
}
EOF
    # No permanent HTTP server. With redirects disabled, CertMagic starts its
    # HTTP-01 solver only for a challenge and closes it after validation.
    cat <<EOF
# The named address enables certificate management; the catch-all serves IP/no-SNI requests.
https://$domain:$port, https://:$port {
    bind 127.0.0.1
EOF
    cat <<EOF
    root * $root
    encode gzip
    file_server
}
EOF
}

write_page() {
    cat <<'HTML'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="关于旅行、阅读和日常观察的个人笔记。">
<!-- 浏览器标签页标题：改成自己的网站名称。 -->
<title>山间来信 · 个人笔记</title>
<style>
/* 配色、字体、间距可在这里修改；不依赖外部字体或框架。 */
* {
  box-sizing:border-box}
body {
  margin:0;
  background:#f5f3ed;
  color:#26332b;
  font-family:system-ui,-apple-system,"Noto Sans CJK SC",sans-serif;
  line-height:1.9}
main {
  max-width:920px;
  margin:auto;
  padding:64px 28px}
header {
  border-bottom:1px solid #d9ddd1;
  padding-bottom:32px}
small {
  letter-spacing:.18em;
  color:#66775d}
h1 {
  font-size:clamp(34px,6vw,64px);
  line-height:1.3;
  margin:14px 0}
h2 {
  font-size:23px;
  margin-top:30px}
p {
  max-width:700px;
  color:#52604e}
nav {
  display:flex;
  gap:24px;
  margin-top:24px}
a {
  color:#39593d;
  text-underline-offset:5px}
article {
  padding:12px 0 25px;
  border-bottom:1px solid #d9ddd1}
footer {
  margin-top:40px;
  color:#73806c;
  font-size:14px}

</style>
</head>
<body>
<main>
<header>
<small>LETTERS FROM THE HILLS</small>
<!-- 页面站名与下方简介：可以自由替换。 -->
<h1>山间来信</h1>
<p>把途中看到的风景、读过的文字和一些日常想法，慢慢记下来。</p>
<nav>
<a href="#notes">近来的笔记</a>
<a href="#about">关于这里</a>
</nav>
</header>
<!-- 文章区：替换为自己的内容；复制 article 块可以增加文章。 -->
<section id="notes">
<article>
<h2>在散步中找回节奏</h2>
<p>沿着熟悉的路走一会儿，才发现季节已经换了颜色。有些事不用急着想明白，先把眼前的生活照顾好。</p>
</article>
<article>
<h2>给阅读留一点时间</h2>
<p>把手机放远，读完一小节再停下。喜欢的句子记在纸上，过些日子重读，常常会有新的理解。</p>
</article>
</section>
<!-- 关于这里：介绍网站主题、作者或项目。 -->
<section id="about">
<h2>关于这里</h2>
<p>一处安静的个人记录空间。写下旅途、阅读与生活里的小事，也欢迎你在这里停留片刻。</p>
</section>
<footer>山间来信 · Personal notes</footer>
</main>
</body>
</html>
HTML
}

apply_site() {
    local active=0 exec_start config_dir
    local config_arg_re='(^|[[:space:]])--config(=|[[:space:]]+)/etc/caddy/Caddyfile([[:space:];]|$)'
    config_dir=$(dirname "$CONFIG")
    id caddy >/dev/null 2>&1 || die 'Caddy 软件包没有创建 caddy 用户。'
    # Unmask does not start the service; it makes its installed ExecStart visible.
    unmask_install_caddy
    exec_start=$(systemctl show caddy -p ExecStart --value)
    [[ "$exec_start" =~ $config_arg_re ]] || die 'caddy.service 使用了不同的配置路径，需要人工确认。'
    install -d -m 755 "$config_dir" "$WEBROOT"
    write_caddyfile "$DOMAIN" "$LOCAL_PORT" "$EMAIL" "$WEBROOT" > "$STAGE/Caddyfile"
    caddy fmt --overwrite "$STAGE/Caddyfile"
    # Validate under /etc/caddy, with restored labels, rather than asking a confined
    # SELinux user to read a root-created file under /tmp.
    VALIDATION=$(mktemp "$config_dir/.reality-site-validation.XXXXXXXX")
    install -m 644 "$STAGE/Caddyfile" "$VALIDATION"
    if has restorecon; then restorecon "$VALIDATION"; fi
    runuser -u caddy -- caddy validate --config "$VALIDATION" --adapter caddyfile
    rm -f -- "$VALIDATION"
    VALIDATION=''
    install -d -m 700 "$BACKUP_ROOT"
    BACKUP=$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-XXXXXX")
    [[ ! -f "$CONFIG" ]] || cp -p -- "$CONFIG" "$BACKUP/Caddyfile"
    [[ ! -f "$WEBROOT/index.html" ]] || cp -p -- "$WEBROOT/index.html" "$BACKUP/index.html"
    [[ ! -f "$STATE" ]] || cp -p -- "$STATE" "$BACKUP/state"
    # Preserve any page the user has edited since the first install.
    if [[ ! -f "$WEBROOT/index.html" ]]; then
        write_page > "$STAGE/index.html"
        install -m 644 "$STAGE/index.html" "$WEBROOT/index.html"
    fi
    if has restorecon; then restorecon -R "$WEBROOT" "$config_dir"; fi
    systemctl is-active --quiet caddy && active=1
    install -m 644 "$STAGE/Caddyfile" "$CONFIG"
    if has restorecon; then restorecon "$CONFIG"; fi
    if ! { if (( active )); then systemctl reload caddy; else systemctl start caddy; fi; }; then
        if [[ -f "$BACKUP/Caddyfile" ]]; then
            cp -p -- "$BACKUP/Caddyfile" "$CONFIG"
            if (( active )); then systemctl reload caddy || true; fi
        else
            rm -f -- "$CONFIG"
        fi
        if has getenforce && [[ $(getenforce) == Enforcing ]]; then
            printf '\nSELinux 当前为 Enforcing。若日志含 permission denied，请同时检查 AVC 拒绝记录和端口/文件标签；不要直接关闭 SELinux。\n' >&2
        fi
        die "Caddy 应用配置失败；旧配置已恢复。日志：journalctl -u caddy -n 60 --no-pager；备份：$BACKUP"
    fi
    CADDY_CONFIG_APPLIED=1
    write_state active > "$STAGE/state"
    install -m 600 "$STAGE/state" "$STATE"
    systemctl enable caddy
}

verify_site() {
    local attempt status version
    say '配置已应用，检查本机 HTTPS；通过80端口验证时可能仍在等待证书签发，最多等待约 90 秒……'
    for ((attempt=1; attempt<=18; attempt++)); do
        if status=$(curl --noproxy '*' --silent --show-error --max-time 3 \
            --resolve "$DOMAIN:$LOCAL_PORT:127.0.0.1" -o /dev/null -w '%{http_code}' \
            "https://$DOMAIN:$LOCAL_PORT/" 2>/dev/null) && [[ "$status" == 200 ]]; then
            say '本机 HTTPS 验证成功（仅服务器内部）：证书受信任、域名匹配、网页返回 HTTP 200。'
            if [[ $(curl --version) == *HTTP2* ]]; then
                version=$(curl --noproxy '*' --http2 --silent --show-error --max-time 5 \
                    --resolve "$DOMAIN:$LOCAL_PORT:127.0.0.1" -o /dev/null -w '%{http_version}' \
                    "https://$DOMAIN:$LOCAL_PORT/")
                printf '实际协商的 HTTP 版本：%s\n' "$version"
                [[ "$version" == 2 ]] || die '没有协商到 HTTP/2，请检查配置。'
            else
                printf '此 curl 未编译 HTTP/2；配置已启用 h2，实际 H2 握手仍需 Xray tls 工具/客户端确认。\n'
            fi
            printf '\n下一阶段在 3X-UI 填：\n  SNI：%s\n  Target/Dest：127.0.0.1:%s\n  Xver：0\n' "$DOMAIN" "$LOCAL_PORT"
            printf '网页目录：%s（首页文件：index.html）\n配置备份：%s\n' "$WEBROOT" "$BACKUP"
            printf '自定义网页：通过SSH工具的文件管理器上传HTML、CSS、JS和图片，保存后刷新浏览器即可。\n'
            printf '只改网页无需重跑脚本；再次部署会保留已有网页内容。\n'
            printf '\n证书由Caddy自动续期，无需另装证书工具或定时任务。\n'
            printf 'Caddy不再常驻监听80；HTTP-01验证时临时使用，结束后释放。请保留公网80可达且验证时可用。\n'
            printf '最终公网HTTPS地址：https://%s/\n' "$DOMAIN"
            printf '浏览器请明确输入 https://；本网站不提供普通HTTP访问或自动跳转。\n'
            printf '须先由Xray监听公网443并使用上面输出的SNI/Target，才能从浏览器验证此HTTPS地址。\n'
            printf '当前只证明本机网站就绪；公网443回落与真实代理连接尚需分别验证。\n'
            return 0
        fi
        if (( attempt < 18 )); then sleep 2; fi
    done
    printf '\nCaddy 已启动，但本机 HTTPS 尚未验证成功；不能据此认为证书已签发。\n'
    printf '先检查 DNS 的全部 A/AAAA、TCP 80 的本机防火墙和云端安全组、域名的 CAA 限制。\n'
    printf '查看原因：journalctl -u caddy -n 60 --no-pager\n'
    printf 'Caddy 会自动重试；无需反复执行安装或强制重签。\n'
    return 2
}

deploy() {
    local expected_managed expected_config_hash='' expected_state_hash=''
    check_platform
    check_ownership
    expected_managed=$MANAGED
    if (( MANAGED )); then
        expected_config_hash=$(sha256sum "$CONFIG" | awk '{print $1}')
        expected_state_hash=$(sha256sum "$STATE" | awk '{print $1}')
    fi
    ask_settings
    exec 9>"$LOCK_FILE"
    flock -n 9 || die '另一份部署器正在运行。'
    # Prompts may take minutes. Re-check ownership after acquiring the lock, so
    # a manual edit or a completed concurrent deployment cannot be overwritten.
    check_ownership
    [[ "$MANAGED" == "$expected_managed" ]] || die '等待确认期间部署状态发生变化，请重新运行后核对。'
    if (( MANAGED )); then
        [[ "$(sha256sum "$CONFIG" | awk '{print $1}')" == "$expected_config_hash" &&
           "$(sha256sum "$STATE" | awk '{print $1}')" == "$expected_state_hash" ]] ||
            die '等待确认期间配置或部署记录发生变化，本次已停止，请重新运行后核对。'
    fi
    check_available
    umask 077
    STAGE=$(mktemp -d /tmp/reality-site.XXXXXXXX)
    trap cleanup_deploy EXIT
    install_caddy
    if (( ! MANAGED )); then
        # Remember our new Caddy installation so a failed first deployment can
        # be retried without taking over an unrelated installation.
        write_state pending > "$STAGE/state"
        install -m 600 "$STAGE/state" "$STATE"
    fi
    apply_site
    # A verification timeout already explains what remains unresolved. Preserve
    # its exit code without the generic ERR trap claiming installation failed.
    verify_site || exit "$?"
}

main() {
    # Deployment checks the platform before prompts or mutations. Help is always available.
    case "${1:-}" in
        --help|-h)
            printf '用法：bash reality-site.sh [--deploy]\n直接进入部署/修复，系统与端口检查自动执行，异常时显示原因。\n' ;;
        --deploy|'') deploy ;;
        *) die '参数无效，运行 --help 查看用法。' ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap 'printf "\n执行失败（第 %s 行）。已完成的包安装不会自动卸载；请根据上面的错误处理后再运行。\n" "$LINENO" >&2' ERR
    main "$@"
fi
