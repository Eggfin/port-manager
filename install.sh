#!/usr/bin/env bash
#
# portman 一键安装脚本
#   bash <(curl -fsSL https://raw.githubusercontent.com/Eggfin/port-manager/main/install.sh)
#
# 安装内容:
#   /usr/local/bin/portman                   主程序
#   /usr/local/lib/portman/route-report.sh   三网路由检测模块
#   /usr/local/lib/portman/nft-backend.sh     原生 nftables 后端
#   /usr/local/lib/portman/hy2-hop.sh         HY2 端口跳跃管理

set -e

REPO="Eggfin/port-manager"
RAW_URL="https://raw.githubusercontent.com/${REPO}/main"
INSTALL_PATH="/usr/local/bin/portman"
ROUTE_MODULE="/usr/local/lib/portman/route-report.sh"
NFT_MODULE="/usr/local/lib/portman/nft-backend.sh"
HY2_MODULE="/usr/local/lib/portman/hy2-hop.sh"

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; PLAIN=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; PLAIN=""
fi

info()  { echo "${GREEN}[信息]${PLAIN} $*"; }
warn()  { echo "${YELLOW}[信息]${PLAIN} $*"; }
error() { echo "${RED}[错误]${PLAIN} $*" >&2; }
has()   { command -v "$1" >/dev/null 2>&1; }

# 下载 $RAW_URL/$1 到 $2
download() {
    if has curl; then
        curl -fsSL "$RAW_URL/$1" -o "$2"
    elif has wget; then
        wget -qO "$2" "$RAW_URL/$1"
    else
        error "需要 curl 或 wget"
        exit 1
    fi
}

if [[ $EUID -ne 0 ]]; then
    error "请使用 root 运行安装脚本 (或在命令前加 sudo)"
    exit 1
fi

# 缺少 ss / netstat 时尝试安装 iproute2
if ! has ss && ! has netstat; then
    warn "正在安装 iproute2..."
    if has apt-get; then
        apt-get update -qq && apt-get install -y -qq iproute2
    elif has dnf; then
        dnf install -y -q iproute
    elif has yum; then
        yum install -y -q iproute
    elif has apk; then
        apk add --quiet iproute2
    fi
fi

temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

info "正在下载 portman..."
for script in portman.sh route-report.sh nft-backend.sh hy2-hop.sh; do
    download "$script" "$temp/$script"
    bash -n "$temp/$script"
done

install -d -m 755 "${ROUTE_MODULE%/*}"
install -m 755 "$temp/route-report.sh" "$ROUTE_MODULE"
install -m 755 "$temp/nft-backend.sh" "$NFT_MODULE"
install -m 755 "$temp/hy2-hop.sh" "$HY2_MODULE"
install -m 755 "$temp/portman.sh" "$INSTALL_PATH"

info "安装完成: $("$INSTALL_PATH" version)"
"$INSTALL_PATH" shortcut
echo
cat <<'EOF'
常用命令:
  0. s                     快捷键：输入 s 回车，直接打开菜单
  1. portman               打开交互菜单，输入数字选择功能
  2. portman list          查看所有端口：正在监听的，以及已放行但未使用的
  3. portman public        只看对公网开放的端口
  4. portman check 80      查询某个端口被谁占用
  5. portman open 8080     放行(开启) 8080 端口，默认 tcp
  6. portman close 8080    关闭 8080 端口（删除放行规则）
  7. portman lockdown      一键关闭其他端口，只保留正在使用的端口
  8. portman unlock        恢复放行全部端口
  9. portman fw            查看防火墙状态和规则
 10. portman ip            查看 IPv4 / IPv6 状态
 11. portman ipv6 off/on   关闭 / 开启 IPv6，重启后保持
 12. portman ssh           SSH 密钥登录：写入公钥、只允许密钥登录、查看状态
 13. portman route         默认上海三网回程检测，支持 MTR / 详细报告 / 保存文件
 14. portman help          查看全部命令和用法示例
 15. portman hy2           HY2 端口跳跃管理
EOF
