#!/usr/bin/env bash
# 完全隔离的依赖安装测试：模拟缺失 jq / NextTrace，不下载也不写入真实系统。
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home"
for tool in bash sh rm mktemp cat chmod head uname sed mkdir cp id; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing test tool: $tool"; exit 1; }
    ln -s "$(command -v "$tool")" "$work/bin/$tool"
done
export MOCK_BIN="$work/bin"
export HOME="$work/home"
cat > "$work/bin/apt-get" <<'APT'
#!/bin/sh
if [ "$1" = update ]; then exit 0; fi
if [ "$1" = install ]; then
    cat > "$MOCK_BIN/jq" <<'JQ'
#!/bin/sh
printf 'jq-test-1.0\n'
JQ
    chmod +x "$MOCK_BIN/jq"
    exit 0
fi
exit 1
APT
cat > "$work/bin/curl" <<'CURL'
#!/bin/sh
[ "${MOCK_FETCH_FAIL:-0}" = 0 ] || exit 22
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
cat > "$out" <<'INSTALLER'
#!/bin/sh
[ "$1" = --system ] || exit 7
cat > "$MOCK_BIN/nexttrace" <<'NT'
#!/bin/sh
printf 'NextTrace v1.7.6 2026-11-06T00:00:00Z test\n'
NT
chmod +x "$MOCK_BIN/nexttrace"
INSTALLER
CURL
chmod +x "$work/bin/apt-get" "$work/bin/curl"
p="$work/bin"
# 没有确认，不执行任何安装；应返回非 0 并说明取消。
if printf 'n\n' | PATH="$p" bash route-report.sh install > "$work/cancel" 2>&1; then
    echo "FAIL: canceled install returned success"; exit 1
fi
grep -Fq '已取消' "$work/cancel"
[ ! -f "$work/bin/jq" ] && [ ! -f "$work/bin/nexttrace" ]

# 下载失败时不可误报成功（jq 可单独成功，NextTrace 必须仍缺失）。
if printf 'y\n' | MOCK_FETCH_FAIL=1 PATH="$p" bash route-report.sh install > "$work/failure" 2>&1; then
    echo "FAIL: installer download failure returned success"; exit 1
fi
grep -Fq '安装脚本下载或语法校验失败' "$work/failure"
[ ! -f "$work/bin/nexttrace" ]

# 正常安装并校验绝对路径、版本与 doctor。
printf 'y\n' | PATH="$p" bash route-report.sh install > "$work/success" 2>&1
grep -Fq '全部依赖安装并验证成功' "$work/success"
grep -Fq "$work/bin/nexttrace" "$work/success"
grep -Fq "$work/bin/jq" "$work/success"
PATH="$p" bash route-report.sh doctor > "$work/doctor"
grep -Fq '依赖检查通过' "$work/doctor"

# 模拟已安装旧版 NextTrace (v1.7.3 < 1.7.4)：doctor 必须报错，install 必须提示升级而非跳过。
cat > "$work/bin/nexttrace" <<'OLDNT'
#!/bin/sh
printf 'NextTrace v1.7.3 2026-08-26T22:30:27Z old\n'
OLDNT
chmod +x "$work/bin/nexttrace"

if PATH="$p" bash route-report.sh doctor > "$work/doctor-old" 2>&1; then
    echo "FAIL: outdated nexttrace doctor returned success"; exit 1
fi
grep -Fq '[过旧]' "$work/doctor-old"
grep -Fq '1.7.3' "$work/doctor-old"
grep -Fq '1.7.4' "$work/doctor-old"

if printf 'n\n' | PATH="$p" bash route-report.sh install > "$work/cancel-upgrade" 2>&1; then
    echo "FAIL: canceled upgrade returned success"; exit 1
fi
grep -Fq '版本过旧' "$work/cancel-upgrade"
grep -Fq '已取消' "$work/cancel-upgrade"
"$work/bin/nexttrace" --version | grep -Fq 'v1.7.3'

printf 'y\n' | PATH="$p" bash route-report.sh install > "$work/upgrade" 2>&1
grep -Fq '版本过旧' "$work/upgrade"
grep -Fq '全部依赖安装并验证成功' "$work/upgrade"
"$work/bin/nexttrace" --version | grep -Fq 'v1.7.6'
PATH="$p" bash route-report.sh doctor > "$work/doctor-upgraded"
grep -Fq '依赖检查通过' "$work/doctor-upgraded"

# 多路径共存：PATH 中有旧版，但 ~/.local/bin 中有新版时应自动选用新版并提示。
cat > "$work/bin/nexttrace" <<'OLDNT2'
#!/bin/sh
printf 'NextTrace v1.7.3 2026-08-26T22:30:27Z old\n'
OLDNT2
chmod +x "$work/bin/nexttrace"
mkdir -p "$work/home/.local/bin"
cat > "$work/home/.local/bin/nexttrace" <<'NEWNT'
#!/bin/sh
printf 'NextTrace v1.7.6 2026-11-06T00:00:00Z new\n'
NEWNT
chmod +x "$work/home/.local/bin/nexttrace"
PATH="$p" HOME="$work/home" bash route-report.sh doctor > "$work/doctor-shadow"
grep -Fq '依赖检查通过' "$work/doctor-shadow"
grep -Fq "$work/home/.local/bin/nexttrace" "$work/doctor-shadow"
grep -Fq '[提示]' "$work/doctor-shadow"

printf '[PASS] 安装取消、安装失败检测、jq/NextTrace 补装、旧版拦截与升级、多路径切换、doctor 验证\n'
