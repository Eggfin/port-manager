#!/usr/bin/env bash
# 在一次性 GitHub Actions Runner 上执行，测试 portman 完整安装和更新。
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID == 0 ]] || { echo '请以 root 运行此集成测试'; exit 1; }

source_dir=$PWD
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/bin"
cat > "$temp/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url='' dest=''
while (($#)); do
    case $1 in
        -o) dest=$2; shift 2;;
        http*) url=$1; shift;;
        *) shift;;
    esac
done
case "$url" in
    */portman.sh) source_file=portman.sh;;
    */nft-backend.sh) source_file=nft-backend.sh;;
    */hy2-hop.sh)
        [[ ${FAKE_FAIL_HY2:-0} == 1 ]] && exit 22
        source_file=hy2-hop.sh;;
    */route-report.sh)
        [[ ${FAKE_FAIL_MODULE:-0} == 1 ]] && exit 22
        source_file=route-report.sh;;
    *) echo "unexpected url: $url" >&2; exit 2;;
esac
cp "$MOCK_SOURCE_DIR/$source_file" "$dest"
CURL
chmod +x "$temp/bin/curl"
export PATH="$temp/bin:$PATH" MOCK_SOURCE_DIR="$source_dir"

bash install.sh > "$temp/install.log"
test -x /usr/local/bin/portman
test -x /usr/local/lib/portman/route-report.sh
test -x /usr/local/lib/portman/nft-backend.sh
test -x /usr/local/lib/portman/hy2-hop.sh
/usr/local/bin/portman version | grep -Fq 'v1.8.0'
/usr/local/bin/portman route help > "$temp/route-help"
grep -Fq '默认上海三网快速测试' "$temp/route-help"

# 旧版 portman 仅更新主文件时，新版本首次调用应补装路由模块。
rm -f /usr/local/lib/portman/route-report.sh
/usr/local/bin/portman route help > "$temp/lazy-install.log"
test -x /usr/local/lib/portman/route-report.sh
grep -Fq '路由模块已安装' "$temp/lazy-install.log"

# 旧版更新器未分发 HY2 模块时，交互命令应自动补装。
rm -f /usr/local/lib/portman/hy2-hop.sh
/usr/local/bin/portman hy2 help | grep -Fq 'portman hy2'
cmp /usr/local/lib/portman/hy2-hop.sh "$source_dir/hy2-hop.sh"

# 中途下载失败不应更改已安装的主程序/模块
if FAKE_FAIL_MODULE=1 /usr/local/bin/portman update > "$temp/fail.log" 2>&1; then
    echo 'FAILED: update should fail if module unavailable' >&2
    exit 1
fi
if FAKE_FAIL_HY2=1 /usr/local/bin/portman update > "$temp/fail-hy2.log" 2>&1; then
    echo 'FAILED: update should fail if HY2 module unavailable' >&2
    exit 1
fi
cmp -s /usr/local/lib/portman/hy2-hop.sh "$source_dir/hy2-hop.sh"
cmp -s /usr/local/bin/portman "$source_dir/portman.sh"
cmp -s /usr/local/lib/portman/route-report.sh "$source_dir/route-report.sh"
cmp -s /usr/local/lib/portman/nft-backend.sh "$source_dir/nft-backend.sh"
/usr/local/bin/portman update > "$temp/update.log"
grep -Fq '已经是最新版本' "$temp/update.log"
cmp -s /usr/local/lib/portman/route-report.sh "$source_dir/route-report.sh"
printf '[PASS] 离线安装、菜单模块加载、安装失败不破坏现有文件、更新完整性\n'
