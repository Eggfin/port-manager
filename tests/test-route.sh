#!/usr/bin/env bash
# 离线回归测试：所有 NextTrace 输出均为构造样本，并非真实网络实测。
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n portman.sh
bash -n install.sh
bash -n route-report.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/config"
export PATH="$work/bin:$PATH"
export PORTMAN_ROUTE_HOME="$work/config"
export PORTMAN_ROUTE_REPORTS="$work/reports"
export MOCK_TRACE_LOG="$work/nexttrace-args.log"

cat > "$work/bin/nexttrace" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_TRACE_LOG"
target=${!#}
case "$target" in
  202.96.209.133)
    cat <<'JSON'
{"schema_version":1,"version":"mock","resolved_ip":"202.96.209.133","end_reason":"completed","path_end":{"hop":3,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"218.30.48.97","geo":{"asnumber":"AS4134","country":"美国","city":"洛杉矶"},"avg_ms":1.2,"received":3,"loss_percent":0},{"ttl":2,"ip":"59.43.246.237","geo":{"country":"中国","city":"上海"},"avg_ms":125.5,"received":3,"loss_percent":0},{"ttl":3,"ip":"202.96.209.133","geo":{"asnumber":"AS4812","country":"中国","city":"上海"},"avg_ms":125.3,"received":3,"loss_percent":0,"stdev_ms":1.2}]}
JSON
    ;;
  210.22.97.1)
    cat <<'JSON'
{"schema_version":1,"version":"mock","resolved_ip":"210.22.97.1","end_reason":"completed","path_end":{"hop":4,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"162.219.85.161","geo":{"asnumber":"AS10099"},"avg_ms":0.4,"received":3},{"ttl":2,"ip":"218.105.2.93","geo":{"asnumber":"AS9929"},"avg_ms":138.2,"received":3},{"ttl":3,"ip":"219.158.120.17","geo":{"asnumber":"AS4837"},"avg_ms":139.2,"received":3},{"ttl":4,"ip":"210.22.97.1","geo":{"asnumber":"AS17621"},"avg_ms":140.1,"received":3,"loss_percent":0}]}
JSON
    ;;
  211.136.112.200)
    cat <<'JSON'
{"schema_version":1,"version":"mock","resolved_ip":"211.136.112.200","end_reason":"completed","path_end":{"hop":3,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"223.120.201.65","geo":{"asnumber":"AS58807"},"avg_ms":0.6,"received":3},{"ttl":2,"ip":"221.183.92.121","geo":{"asnumber":"AS9808"},"avg_ms":126.1,"received":3},{"ttl":3,"ip":"211.136.112.200","geo":{"asnumber":"AS24400"},"avg_ms":129.3,"received":3,"loss_percent":0}]}
JSON
    ;;
  *)
    cat <<JSON
{"schema_version":1,"version":"mock","resolved_ip":"$target","end_reason":"completed","path_end":{"hop":2,"reason":"max_hops"},"stats":[{"ttl":1,"ip":"203.0.113.1","geo":{"asnumber":"AS4134"},"avg_ms":17,"received":3},{"ttl":2,"ip":"198.51.100.1","geo":{"asnumber":"AS4134"},"avg_ms":19,"received":3}]}
JSON
    ;;
esac
MOCK
chmod +x "$work/bin/nexttrace"

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
expect() { grep -Fq -- "$2" "$1" || fail "未匹配：$2"; }

bash portman.sh version > "$work/version"
expect "$work/version" 'portman v1.8.0'
bash route-report.sh shanghai > "$work/shanghai"
expect "$work/shanghai" '经过：中国电信 163 → 中国电信 CN2 → 中国电信本地网络'
expect "$work/shanghai" '经过：中国联通国际 CUG → 中国联通 9929 → 中国联通 169 → 中国联通本地网络'
expect "$work/shanghai" '经过：中国移动 CMIN2 → 中国移动国内骨干 → 中国移动本地网络'
expect "$work/shanghai" '3/3 个目标产生有效报告'
expect "$work/shanghai" '125.3ms'
expect "$work/shanghai" '140.1ms'
expect "$work/shanghai" '地区/运营商 | 状态 | 终点延迟 | 经过的骨干网络'
expect "$work/shanghai" '上海联通 | 已到达 | 140.1ms | 中国联通 9929 → 169'
if grep -Eq -- '未见 (CN2|9929|CMIN2)|^  线路:' "$work/shanghai"; then fail '快速路由模式不应逐条评价是否经过精品网'; fi


bash route-report.sh shanghai unicom --detail > "$work/detail"
expect "$work/detail" '中国联通 9929'
expect "$work/detail" '219.158.120.17'
bash route-report.sh shanghai mobile --mtr --save > "$work/mtr"
expect "$work/mtr" 'MTR：终点丢包 0.0%'
expect "$MOCK_TRACE_LOG" '-q 20'
test -f "$(find "$work/reports" -name 'shanghai-mobile.json' -print -quit)" || fail '原始 JSON 未保存'
test -f "$(find "$work/reports" -name 'summary.txt' -print -quit)" || fail 'TXT 未保存'

if bash route-report.sh suzhou telecom > "$work/suzhou" 2>&1; then fail '苏州没有配置时应该失败'; fi
expect "$work/suzhou" '缺少已核实目标'
bash route-report.sh set suzhou telecom 8.8.8.8 > "$work/set"
bash route-report.sh suzhou telecom > "$work/suzhou2"
expect "$work/suzhou2" '8.8.8.8'
bash route-report.sh custom 1.1.1.1 --detail > "$work/custom"
expect "$work/custom" '203.0.113.1'
expect "$work/custom" '未确认到达'
expect "$work/custom" '延迟：—'
if bash route-report.sh custom ';rm -rf /' > "$work/invalid" 2>&1; then fail '危险地址应被拒绝'; fi

# 普通线路也必须直接展示实际经过的网络，不出现“未见精品网”式评价。
cat > "$work/bin/nexttrace" <<'PLAIN'
#!/usr/bin/env bash
case "${!#}" in
  202.96.209.133)
    cat <<'JSON'
{"schema_version":1,"resolved_ip":"202.96.209.133","end_reason":"completed","path_end":{"hop":3,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"203.0.113.10","geo":{"asnumber":"AS2497","owner":"iij.ad.jp"},"avg_ms":1,"received":3},{"ttl":2,"ip":"203.0.113.11","geo":{"asnumber":"AS4134"},"avg_ms":90,"received":3},{"ttl":3,"ip":"202.96.209.133","geo":{"asnumber":"AS4812"},"avg_ms":99.4,"received":3}]}
JSON
    ;;
  210.22.97.1)
    cat <<'JSON'
{"schema_version":1,"resolved_ip":"210.22.97.1","end_reason":"completed","path_end":{"hop":3,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"203.0.113.12","geo":{"asnumber":"AS2914","owner":"gin.ntt.net"},"avg_ms":1,"received":3},{"ttl":2,"ip":"203.0.113.13","geo":{"asnumber":"AS4837"},"avg_ms":54,"received":3},{"ttl":3,"ip":"210.22.97.1","geo":{"asnumber":"AS17621"},"avg_ms":59.2,"received":3}]}
JSON
    ;;
  211.136.112.200)
    cat <<'JSON'
{"schema_version":1,"resolved_ip":"211.136.112.200","end_reason":"completed","path_end":{"hop":3,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"203.0.113.14","geo":{"asnumber":"AS3356","owner":"lumen.com"},"avg_ms":1,"received":3},{"ttl":2,"ip":"223.120.1.1","geo":{"asnumber":"AS58453"},"avg_ms":33,"received":3},{"ttl":3,"ip":"211.136.112.200","geo":{"asnumber":"AS24400"},"avg_ms":36.6,"received":3}]}
JSON
    ;;
  *) echo '{"schema_version":1,"stats":[],"path_end":null}';;
esac
PLAIN
chmod +x "$work/bin/nexttrace"
bash route-report.sh shanghai > "$work/ordinary"
expect "$work/ordinary" '经过：IIJ 日本网络 → 中国电信 163 → 中国电信本地网络'
expect "$work/ordinary" '经过：NTT 国际网络 → 中国联通 169 → 中国联通本地网络'
expect "$work/ordinary" '经过：Lumen 国际网络 → 中国移动 CMI → 中国移动本地网络'
expect "$work/ordinary" '上海电信 | 已到达 | 99.4ms | 中国电信 163'
expect "$work/ordinary" '上海联通 | 已到达 | 59.2ms | 中国联通 169'
expect "$work/ordinary" '上海移动 | 已到达 | 36.6ms | 中国移动 CMI'
if grep -Eq -- '未见|全程(9929|CN2|CMIN2)|^  线路:' "$work/ordinary"; then
    fail '普通线路不应被评价为缺少某种精品网'
fi

# 模拟无元数据的 JSON，脚本应保留占位字段，不能误判公网运营商。
cat > "$work/bin/nexttrace" <<'MOCK2'
#!/usr/bin/env bash
cat <<'JSON'
{"schema_version":1,"resolved_ip":"192.0.2.1","end_reason":"completed","path_end":{"hop":1,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"192.0.2.1","avg_ms":0,"received":1}]}
JSON
MOCK2
chmod +x "$work/bin/nexttrace"
bash route-report.sh custom 192.0.2.1 --detail > "$work/emptygeo"
expect "$work/emptygeo" '0.0ms'
expect "$work/emptygeo" '未识别'

printf '[PASS] bash 语法、三网识别、混合路径、中文逐跳、MTR、报告、苏州配置、自定义目标、异常处理\n'
