#!/usr/bin/env bash
#
# portman 路由检测模块
#   用 NextTrace (MTR JSON v1) 检测 VPS → 国内三网的回程线路，输出中文报告。
#   只做出站探测，不修改防火墙、路由、代理或 SSH 设置。
#
# 由 portman 调用 (portman route ...)，也可以单独运行:
#   bash route-report.sh [help | menu | install | doctor | set | mtr | custom | <地区>] [选项]
#
# 目录:
#   1. 配置与输出
#   2. 地区 / 运营商 / 测试目标
#   3. 依赖检测与安装 (NextTrace / jq)
#   4. 网络识别 (ASN → 中文名称)
#   5. 探测与报告
#   6. 菜单与命令行

# ===========================================================================
# 1. 配置与输出
# ===========================================================================
ROUTE_HOME="${PORTMAN_ROUTE_HOME:-${HOME:-/root}/.config/portman}"
ROUTE_TARGETS="${ROUTE_HOME}/route-targets.tsv"
ROUTE_REPORTS="${PORTMAN_ROUTE_REPORTS:-${HOME:-/root}/portman-reports}"

# NextTrace 官方安装脚本: 优先官方入口，失败时使用官方源码仓库中的脚本
ROUTE_INSTALLER_URLS=(
    https://nxtrace.org/nt
    https://raw.githubusercontent.com/nxtrace/NTrace-core/main/nt_install.sh
)
ROUTE_TIMEOUT=180   # 单个目标的最长探测时间 (秒)
ROUTE_MIN_NT_VERSION="1.7.4"   # NextTrace 从 v1.7.4 起支持 -r --json (MTR JSON v1)

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    CYAN=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; PLAIN=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; PLAIN=""
fi

route_note() { printf '%s[路由]%s %s\n' "$GREEN" "$PLAIN" "$*"; }
route_err()  { printf '%s[路由] 错误：%s%s\n' "$RED" "$PLAIN" "$*" >&2; }

has() { command -v "$1" >/dev/null 2>&1; }

# 用于检测报告标题的一行分隔线
route_rule() { printf '%s============================================%s\n' "$BOLD" "$PLAIN"; }

# ===========================================================================
# 2. 地区 / 运营商 / 测试目标
# ===========================================================================
# 地区、运营商名称归一化: 支持英文、缩写和中文，无法识别时返回 1
route_city() {
    case ${1:-} in
        shanghai|sh|上海|'') echo shanghai ;;
        beijing|bj|北京)     echo beijing ;;
        guangzhou|gz|广州)   echo guangzhou ;;
        suzhou|sz|苏州)      echo suzhou ;;
        *) return 1 ;;
    esac
}

route_city_cn() {
    case $1 in
        shanghai)  echo 上海 ;;
        beijing)   echo 北京 ;;
        guangzhou) echo 广州 ;;
        suzhou)    echo 苏州 ;;
        custom)    echo 自定义 ;;
    esac
}

route_isp() {
    case ${1:-} in
        telecom|ct|电信) echo telecom ;;
        unicom|cu|联通)  echo unicom ;;
        mobile|cm|移动)  echo mobile ;;
        all|三网|'')     echo all ;;
        *) return 1 ;;
    esac
}

route_isp_cn() {
    case $1 in
        telecom) echo 电信 ;;
        unicom)  echo 联通 ;;
        mobile)  echo 移动 ;;
        custom)  echo 自定义 ;;
    esac
}

# 例如: 上海电信
route_name() { printf '%s%s' "$(route_city_cn "$1")" "$(route_isp_cn "$2")"; }

# 只允许 IP / 域名常见字符，防止把参数当成命令执行
route_valid_target() {
    local t=${1:-}
    [[ -n $t && ${#t} -le 253 && $t =~ ^[[:alnum:]][[:alnum:].:_-]*$ ]]
}

# 内置测试目标，仅用于路由定位，不保证所有节点永久响应 ICMP。
# 苏州没有经过核实、可长期使用的三网测试地址，由用户首次使用时配置。
route_builtin_target() {
    case "$1:$2" in
        shanghai:telecom)  echo 202.96.209.133 ;;
        shanghai:unicom)   echo 210.22.97.1 ;;
        shanghai:mobile)   echo 211.136.112.200 ;;
        beijing:telecom)   echo 219.141.140.10 ;;
        beijing:unicom)    echo 202.106.195.68 ;;
        beijing:mobile)    echo 221.179.155.161 ;;
        guangzhou:telecom) echo 58.60.188.222 ;;
        guangzhou:unicom)  echo 210.21.196.6 ;;
        guangzhou:mobile)  echo 120.196.165.24 ;;
        *) return 1 ;;
    esac
}

# 用户保存的目标优先，其次是内置目标
route_target() {
    local saved=""
    if [[ -f $ROUTE_TARGETS ]]; then
        saved=$(awk -F '\t' -v c="$1" -v i="$2" '$1 == c && $2 == i { t = $3 } END { print t }' "$ROUTE_TARGETS")
        if route_valid_target "$saved"; then
            printf '%s\n' "$saved"
            return 0
        fi
    fi
    route_builtin_target "$1" "$2"
}

# 保存测试目标: route_set_target <地区> <运营商> <IP/域名>
route_set_target() {
    local city isp target tmp
    city=$(route_city "${1:-}") || { route_err '地区必须是上海、北京、广州或苏州'; return 2; }
    isp=$(route_isp "${2:-}")   || { route_err '运营商必须是电信、联通或移动'; return 2; }
    [[ $isp != all ]]           || { route_err '设置目标时必须指定一个运营商'; return 2; }
    target=${3:-}
    route_valid_target "$target" || { route_err '目标地址格式不合法'; return 2; }

    mkdir -p "$ROUTE_HOME" && chmod 700 "$ROUTE_HOME" || return 1
    tmp=$(mktemp "${ROUTE_HOME}/.targets.XXXXXX") || return 1
    if [[ -f $ROUTE_TARGETS ]]; then
        awk -F '\t' -v c="$city" -v i="$isp" '($1 != c || $2 != i) && NF == 3' "$ROUTE_TARGETS" >"$tmp"
    fi
    printf '%s\t%s\t%s\n' "$city" "$isp" "$target" >>"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$ROUTE_TARGETS" || return 1
    route_note "已保存：$(route_name "$city" "$isp") → $target"
}

# ===========================================================================
# 3. 依赖检测与安装 (NextTrace / jq)
# ===========================================================================
# 从 `nexttrace --version` 提取语义版本号 (如 1.7.6)；无法识别 (如 dev/测试替身) 时返回 1
route_nt_version() {
    local bin=$1 out first
    out=$("$bin" --version 2>&1) || true
    first=${out%%$'\n'*}
    first=$(printf '%s\n' "$first" | sed $'s/\033\\[[0-9;]*[[:alpha:]]//g')
    if [[ $first =~ [Nn]ext[Tt]race[[:space:]]+v?([0-9]+)\.([0-9]+)\.([0-9]+)([^0-9.]|$) ]]; then
        printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

# 比较语义版本号: $1 >= $2 (格式 X.Y.Z)
route_ver_ge() {
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<<"$1"
    IFS=. read -r b1 b2 b3 <<<"$2"
    a1=$((10#${a1:-0})); a2=$((10#${a2:-0})); a3=$((10#${a3:-0}))
    b1=$((10#${b1:-0})); b2=$((10#${b2:-0})); b3=$((10#${b3:-0}))
    (( a1 > b1 )) && return 0
    (( a1 < b1 )) && return 1
    (( a2 > b2 )) && return 0
    (( a2 < b2 )) && return 1
    (( a3 >= b3 ))
}

# 检查 NextTrace 是否满足最低版本要求。
# 能解析出版本且 < ROUTE_MIN_NT_VERSION 时返回 1；>= 最低版本或 dev/测试替身返回 0。
route_nt_ver_ok() {
    local ver
    ver=$(route_nt_version "$1") || return 0
    route_ver_ge "$ver" "$ROUTE_MIN_NT_VERSION"
}

route_find_nexttrace() {
    local p cmd_p fallback="" seen=":"
    local -a candidates=()
    cmd_p=$(command -v nexttrace 2>/dev/null) || cmd_p=""
    [[ -n $cmd_p ]] && candidates+=("$cmd_p")
    candidates+=(/usr/local/bin/nexttrace /usr/bin/nexttrace "${HOME:-/root}/.local/bin/nexttrace")

    for p in "${candidates[@]}"; do
        [[ -n $p && -x $p ]] || continue
        [[ $seen == *":$p:"* ]] && continue
        seen+="$p:"
        if route_nt_ver_ok "$p"; then
            printf '%s\n' "$p"
            return 0
        fi
        [[ -z $fallback ]] && fallback=$p
    done
    if [[ -n $fallback ]]; then
        printf '%s\n' "$fallback"
        return 0
    fi
    return 1
}

route_doctor() {
    local nt jq_path nt_ok=0 nt_ver cmd_nt cmd_ver
    printf '\n%s===== 路由检测 · 依赖诊断 =====%s\n' "$BOLD" "$PLAIN"
    printf '系统: %s / %s\n' "$(uname -s)" "$(uname -m)"
    printf 'PATH: %s\n' "$PATH"

    nt=$(route_find_nexttrace) || nt=""
    if [[ -n $nt ]]; then
        if route_nt_ver_ok "$nt"; then
            nt_ok=1
            printf '%s[正常]%s NextTrace: %s\n' "$GREEN" "$PLAIN" "$nt"
            "$nt" --version 2>&1 | head -n 2
            cmd_nt=$(command -v nexttrace 2>/dev/null) || cmd_nt=""
            if [[ -n $cmd_nt && $cmd_nt != "$nt" ]] && ! route_nt_ver_ok "$cmd_nt"; then
                cmd_ver=$(route_nt_version "$cmd_nt" || true)
                printf '%s[提示]%s PATH 中的 %s 版本过旧 (v%s)，已自动改用 %s\n' "$YELLOW" "$PLAIN" "$cmd_nt" "$cmd_ver" "$nt"
            fi
        else
            nt_ver=$(route_nt_version "$nt" || true)
            printf '%s[过旧]%s NextTrace: %s（当前 v%s，需要 v%s+ 以支持 -r --json）\n' "$YELLOW" "$PLAIN" "$nt" "$nt_ver" "$ROUTE_MIN_NT_VERSION"
            "$nt" --version 2>&1 | head -n 2
        fi
    else
        printf '%s[缺失]%s NextTrace: 未找到可执行文件\n' "$RED" "$PLAIN"
    fi

    jq_path=$(command -v jq 2>/dev/null) || jq_path=""
    if [[ -n $jq_path ]]; then
        printf '%s[正常]%s jq: %s\n' "$GREEN" "$PLAIN" "$jq_path"
        jq --version 2>&1 | head -n 1
    else
        printf '%s[缺失]%s jq: 未找到可执行文件\n' "$RED" "$PLAIN"
    fi

    if [[ -n $nt && $nt_ok == 1 && -n $jq_path ]]; then
        route_note '依赖检查通过，可以开始检测。'
        return 0
    fi
    route_note '检测依赖未就绪或版本过旧，可运行 portman route install 或选择子菜单 10。'
    return 1
}

# 检测前确认依赖齐全，并把 NextTrace 路径存入 ROUTE_NT_BIN
route_require() {
    local missing=0 nt_ver
    ROUTE_NT_BIN=$(route_find_nexttrace) || ROUTE_NT_BIN=""
    if [[ -z $ROUTE_NT_BIN ]]; then
        route_err 'NextTrace 未找到（不是线路故障）；运行 portman route install 修复。'
        missing=1
    elif ! route_nt_ver_ok "$ROUTE_NT_BIN"; then
        nt_ver=$(route_nt_version "$ROUTE_NT_BIN" || true)
        route_err "NextTrace 版本过旧（当前 v${nt_ver}，需要 v${ROUTE_MIN_NT_VERSION}+ 以支持 -r --json）；运行 portman route install 或选择子菜单 10 升级。"
        missing=1
    fi
    if ! has jq; then
        route_err 'jq 未找到；运行 portman route install 修复。'
        missing=1
    fi
    return "$missing"
}

# 下载 NextTrace 安装脚本到 $1，并做 sh 语法检查
route_fetch_installer() {
    local dest=$1 url ok
    if ! has curl && ! has wget; then
        route_err '缺少 curl 和 wget，无法下载安装脚本'
        return 1
    fi
    for url in "${ROUTE_INSTALLER_URLS[@]}"; do
        rm -f "$dest"
        if has curl; then
            curl -fLsS --connect-timeout 10 --max-time 60 --retry 2 -o "$dest" "$url" && ok=1 || ok=0
        else
            wget -q --timeout=60 -O "$dest" "$url" && ok=1 || ok=0
        fi
        if (( ok )) && [[ -s $dest ]] && sh -n "$dest"; then
            route_note "安装脚本下载成功：$url"
            return 0
        fi
    done
    route_err 'NextTrace 官方安装脚本下载或语法校验失败，检查 DNS/HTTPS/网络后重试。'
    return 1
}

# 用系统包管理器安装一个软件包
route_pkg_install() {
    if has apt-get; then
        apt-get update && apt-get install -y "$1"
    elif has dnf; then
        dnf install -y "$1"
    elif has yum; then
        yum install -y "$1"
    elif has apk; then
        apk add "$1"
    else
        route_err "系统包管理器不受支持，请手动安装 $1。"
        return 1
    fi
}

route_found() { if [[ -n $1 ]]; then echo 已找到; else echo 缺失; fi; }

route_install_deps() {
    local answer installer rc=0 nt jq_path nt_need=0 nt_status nt_ver
    nt=$(route_find_nexttrace) || nt=""
    jq_path=$(command -v jq 2>/dev/null) || jq_path=""
    if [[ -z $nt ]]; then
        nt_need=1
        nt_status='缺失'
    elif ! route_nt_ver_ok "$nt"; then
        nt_need=1
        nt_ver=$(route_nt_version "$nt" || true)
        nt_status="版本过旧 (v${nt_ver}，需 v${ROUTE_MIN_NT_VERSION}+)"
    else
        nt_status='已找到'
    fi

    route_note "当前状态：NextTrace=${nt_status}；jq=$(route_found "$jq_path")"
    if (( nt_need == 0 )) && [[ -n $jq_path ]]; then
        route_note '依赖已齐全，无需重复安装。'
        return 0
    fi
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        route_err '安装依赖需要 root 权限，请使用 root 登录或 sudo portman route install。'
        return 1
    fi

    route_note '安装将使用系统包管理器（jq）及 NextTrace 官方安装脚本（--system）。'
    read -rp '确认安装或升级检测依赖？请输入 y 继续 [y/N]: ' answer || answer=""
    case $answer in
        y|Y|yes|YES) ;;
        *) route_note '未执行安装（已取消）。'; return 1 ;;
    esac

    if [[ -z $jq_path ]]; then
        route_note '正在安装 jq...'
        route_pkg_install jq || rc=$?
        if (( rc != 0 )) || ! has jq; then
            route_err "jq 安装失败（退出码 $rc），请检查上面的包管理器错误信息。"
            return 1
        fi
        route_note "jq 安装完成：$(command -v jq)"
    fi

    if (( nt_need == 1 )); then
        installer=$(mktemp) || { route_err '无法创建临时文件'; return 1; }
        route_note '正在下载 NextTrace 官方安装器...'
        if ! route_fetch_installer "$installer"; then
            rm -f "$installer"
            return 1
        fi
        route_note '正在安装 / 升级 NextTrace 到 /usr/local/bin（系统模式）...'
        # 先下载到文件再执行，保留真实退出码，避免「下载失败 | bash 返回成功」
        if ! sh "$installer" --system; then
            rm -f "$installer"
            route_err 'NextTrace 安装器执行失败，请查看上面的下载/安装错误。'
            return 1
        fi
        rm -f "$installer"
    fi

    # 重新检查安装位置、版本和可执行性，防止「提示成功但找不到命令或仍是旧版」
    if ! route_require; then
        route_err '安装过程结束，但依赖仍未齐全或版本仍过旧。执行 portman route doctor 查看路径。'
        return 1
    fi
    route_note '全部依赖安装并验证成功！'
    route_doctor
}

# ===========================================================================
# 4. 网络识别 (ASN → 中文名称)
#   只根据实际看到的 ASN / IP 判断。经过某段优质骨干不等于全程优质，
#   也绝不把 CN2 简单标成 CN2 GIA。
# ===========================================================================
# 把运营商原始名称转为常见中文叫法，不认识的保持原样
route_owner_name() {
    local lower=${1,,}
    case $lower in
        *iij.ad.jp*|*internet-initiative*|*iij*) echo 'IIJ 日本网络' ;;
        *ntt.net*|*ntt.com*|*ntt\ *)            echo 'NTT 国际网络' ;;
        *lumen*|*level3*)                        echo 'Lumen 国际网络' ;;
        *cogent*)                                echo 'Cogent 国际网络' ;;
        *hurricane*|*he.net*)                    echo 'Hurricane Electric' ;;
        *)                                       echo "${1:-}" ;;
    esac
}

# 单跳的中文网络名称: route_label <ASN> <IP> <运营商原始名称>
route_label() {
    local asn=${1#AS} ip=${2:-} owner=${3:-}
    [[ $asn == '-' ]] && asn=''
    [[ $owner == '-' ]] && owner=''
    if [[ $ip == 59.43.* ]]; then
        echo '中国电信 CN2'
        return
    fi
    case $asn in
        4809)                echo '中国电信 CN2' ;;
        4134)                echo '中国电信 163' ;;
        4812|134774|140293)  echo '中国电信本地网络' ;;
        10099)               echo '中国联通国际 CUG' ;;
        9929)                echo '中国联通 9929' ;;
        4837)                echo '中国联通 169' ;;
        17621|140717)        echo '中国联通本地网络' ;;
        58807)               echo '中国移动 CMIN2' ;;
        58453)               echo '中国移动 CMI' ;;
        9808)                echo '中国移动国内骨干' ;;
        24400|56040|56041)   echo '中国移动本地网络' ;;
        2497)                echo 'IIJ 日本网络' ;;
        2914)                echo 'NTT 国际网络' ;;
        3356)                echo 'Lumen 国际网络' ;;
        174)                 echo 'Cogent 国际网络' ;;
        6939)                echo 'Hurricane Electric' ;;
        1299)                echo 'Arelion 国际网络' ;;
        1054)                echo 'AS1054 上游网络' ;;
        '')
            if [[ -n $owner ]]; then route_owner_name "$owner"; else echo '未识别网络'; fi ;;
        *)
            if [[ -n $owner ]]; then
                printf '%s (AS%s)\n' "$(route_owner_name "$owner")" "$asn"
            else
                printf 'AS%s 网络\n' "$asn"
            fi ;;
    esac
}

# ===========================================================================
# 5. 探测与报告
# ===========================================================================
route_json_valid() {
    jq -e '(.schema_version == 1) and (.stats | type == "array") and (.path_end == null or (.path_end | type == "object"))' \
        "$1" >/dev/null 2>&1
}

# 根据 NextTrace 的结束原因给出中文状态: <path_end.reason> <end_reason>
route_reach_status() {
    [[ $2 == completed ]] || { echo '检测异常/中断'; return; }
    case $1 in
        destination_reached) echo '已到达' ;;
        unreachable)         echo '目标不可达' ;;
        max_hops)            echo '达到最大跳数' ;;
        *)                   echo '未确认到达' ;;
    esac
}

# 打印一条线路的结果 (--detail 时含逐跳明细)，并把一行汇总追加到 summary_file。
# 汇总只使用实际看到的路径信号；中间跳的 ICMP 丢包不算作业务丢包。
#   参数: JSON文件 地区 运营商 目标 detail(0/1) mtr(0/1) [summary_file|-]
route_render() {
    local file=$1 city=$2 isp=$3 ip=$4 detail=$5 mtr=$6 summary_file=${7:--}
    local cn reached reason endhop resolved rows color
    local ttl hopip asn avg received loss stdev country prov loc owner label n
    local path="" last_label=""
    local seen_cn2=0 seen_163=0 seen_9929=0 seen_4837=0 seen_4837_after_9929=0 seen_cmin2=0 seen_cmi=0
    local endavg='—' endloss='—' endjitter='—' summary='未识别'

    cn=$(route_isp_cn "$isp")
    reason=$(jq -r '.path_end.reason // "unknown"' "$file")
    endhop=$(jq -r '.path_end.hop // 0' "$file")
    resolved=$(jq -r '.resolved_ip // ""' "$file")
    reached=$(route_reach_status "$reason" "$(jq -r '.end_reason // "completed"' "$file")")
    rows=$(jq -r '.stats[] | [
            .ttl // 0, .ip // "*", .geo.asnumber // "-", .avg_ms // 0, .received // 0,
            .loss_percent // 0, .stdev_ms // 0, .geo.country // "-", .geo.prov // "-",
            .geo.city // "-", (.geo.owner // .geo.isp // "-")
        ] | map(tostring) | @tsv' "$file")

    if [[ $detail == 1 ]]; then
        printf '\n  %s── %s · %s ──%s\n' "$BOLD" "$(route_name "$city" "$isp")" "$ip" "$PLAIN"
        printf '  %s跳点  IP / ASN / 中文线路                       平均延迟%s\n' "$DIM" "$PLAIN"
    fi

    while IFS=$'\t' read -r ttl hopip asn avg received loss stdev country prov loc owner; do
        [[ -n $ttl ]] || continue
        if [[ $hopip == '*' || -z $hopip ]]; then
            [[ $detail == 1 ]] && printf '  %02d    %s*  (该跳未回应探测)%s\n' "$ttl" "$DIM" "$PLAIN"
            continue
        fi

        label=$(route_label "$asn" "$hopip" "$owner")
        [[ $hopip == 59.43.* ]] && seen_cn2=1
        n=${asn#AS}
        case $n in
            4809)  seen_cn2=1 ;;
            4134)  seen_163=1 ;;
            9929)  seen_9929=1 ;;
            4837)  seen_4837=1; (( seen_9929 )) && seen_4837_after_9929=1 ;;
            58807) seen_cmin2=1 ;;
            58453) seen_cmi=1 ;;
        esac

        # 连续相同的网络只记一次
        if [[ $label != "$last_label" ]]; then
            path+="${path:+ → }$label"
            last_label=$label
        fi

        if [[ $detail == 1 ]]; then
            printf '  %02d    %-16s %-10s %s%s%s\n' "$ttl" "$hopip" "${asn:--}" "$CYAN" "$label" "$PLAIN"
            printf '        地点: %s %s %s · 平均: %.1fms' "${country:--}" "$prov" "$loc" "$avg"
            [[ $mtr == 1 ]] && printf ' · 丢包: %.1f%% · 样本: %s' "$loss" "$received"
            printf '\n'
        fi

        # 只有确认到达时，才用目标本身这一跳的数据作为终点延迟
        if [[ $reached == '已到达' && ( $hopip == "$resolved" || $hopip == "$ip" ) ]]; then
            endavg=$(printf '%.1fms' "$avg")
            endloss=$(printf '%.1f%%' "$loss")
            endjitter=$(printf '%.1fms' "$stdev")
        fi
    done <<<"$rows"

    # 骨干网络特征只在最终汇总里出现；单条线路直接展示实际经过的网络
    case $isp in
        telecom)
            if   (( seen_cn2 )); then summary='中国电信 CN2'
            elif (( seen_163 )); then summary='中国电信 163'
            else summary='网络特征待确认'; fi ;;
        unicom)
            if (( seen_9929 )); then
                summary='中国联通 9929'
                if   (( seen_4837_after_9929 )); then summary+=' → 169'
                elif (( seen_4837 )); then summary+=' / 169'; fi
            elif (( seen_4837 )); then summary='中国联通 169'
            else summary='网络特征待确认'; fi ;;
        mobile)
            if   (( seen_cmin2 )); then summary='中国移动 CMIN2'
            elif (( seen_cmi )); then summary='中国移动 CMI'
            elif [[ $path == *'中国移动国内骨干'* ]]; then summary='中国移动国内骨干'
            else summary='网络特征待确认'; fi ;;
        custom)
            summary='自定义目标' ;;
    esac

    case $reached in
        已到达)       color=$GREEN ;;
        检测异常/中断) color=$RED ;;
        *)            color=$YELLOW ;;
    esac
    printf '\n  %s%s → %s%s\n' "$BOLD" "$cn" "$ip" "$PLAIN"
    printf '  状态：%s%s%s  ·  延迟：%s  ·  跳数：%s\n' "$color" "$reached" "$PLAIN" "$endavg" "${endhop:-0}"
    printf '  经过：%s\n' "${path:-没有可识别的网络跳点}"
    if [[ $mtr == 1 ]]; then
        printf '  MTR：终点丢包 %s · 延迟标准差 %s\n' "$endloss" "$endjitter"
        printf '  %s注: 中间跳丢包可能是 ICMP 限速；重点看最终目标丢包。%s\n' "$DIM" "$PLAIN"
    fi
    if [[ $reached != '已到达' ]]; then
        printf '  %s注意: 未确认到达，不根据最后一个中间跳填充终点延迟。%s\n' "$YELLOW" "$PLAIN"
    fi

    if [[ $summary_file != '-' ]]; then
        printf '%s | %s | %s | %s\n' "$(route_name "$city" "$isp")" "$reached" "$endavg" "$summary" >>"$summary_file"
    fi
}

# 探测一个目标并输出报告
#   参数: 地区 运营商 目标 detail mtr 报告目录(-为不保存) [summary_file|-]
route_probe_one() {
    local city=$1 isp=$2 ip=$3 detail=$4 mtr=$5 outputdir=$6 summary_file=${7:--}
    local raw err count=3 code=0 nt name
    local -a cmd

    nt=${ROUTE_NT_BIN:-}
    if [[ -z $nt ]]; then
        nt=$(route_find_nexttrace) || { route_err '找不到 NextTrace'; return 1; }
    fi
    [[ $mtr == 1 ]] && count=20
    name=$(route_name "$city" "$isp")

    raw=$(mktemp) || return 1
    err=$(mktemp) || { rm -f "$raw"; return 1; }
    printf '\n%s[测试]%s %s → %s %s(每跳 %s 次)%s\n' "$CYAN" "$PLAIN" "$name" "$ip" "$DIM" "$count" "$PLAIN"

    cmd=("$nt" -r --json --language cn --no-rdns -q "$count" "$ip")
    has timeout && cmd=(timeout "$ROUTE_TIMEOUT" "${cmd[@]}")
    "${cmd[@]}" >"$raw" 2>"$err" || code=$?

    if ! route_json_valid "$raw"; then
        local reason='NextTrace 未输出有效 JSON' old_mtr_json=0
        if grep -Eq -- '--mtr.*--json|--json.*--mtr' "$err" "$raw" 2>/dev/null; then
            reason="NextTrace 版本过旧（需 v${ROUTE_MIN_NT_VERSION}+）"
            old_mtr_json=1
        fi
        if [[ $summary_file != '-' ]]; then
            printf '%s | 失败 | — | %s\n' "$name" "$reason" >>"$summary_file"
        fi
        route_err "$name 检测失败 (退出码 $code)"
        if (( old_mtr_json )); then
            route_err "当前 NextTrace 不支持 -r --json（需 v${ROUTE_MIN_NT_VERSION}+）；请运行 portman route install 或选择子菜单 10 升级。"
        fi
        [[ -s $err ]] && sed -n '1,5p' "$err" >&2
        [[ -s $raw ]] && sed -n '1,3p' "$raw" >&2
        rm -f "$raw" "$err"
        return 1
    fi

    [[ $outputdir != '-' ]] && cp "$raw" "$outputdir/${city}-${isp}.json"
    route_render "$raw" "$city" "$isp" "$ip" "$detail" "$mtr" "$summary_file"
    rm -f "$raw" "$err"
    [[ $code == 0 ]]
}

# 依次检测一个地区的一家或三家运营商，最后打印汇总表
route_run_inner() {
    local city=$1 isp=$2 detail=$3 mtr=$4 outputdir=$5
    local -a carriers
    local current ip failures=0 summary_file mode

    summary_file=$(mktemp) || return 1
    if [[ $isp == all ]]; then carriers=(telecom unicom mobile); else carriers=("$isp"); fi
    if [[ $mtr == 1 ]]; then mode='MTR 稳定性'; else mode='快速路由'; fi

    route_rule
    printf '   %s%s三网回程检测%s  |  NextTrace MTR JSON\n' "$BOLD" "$(route_city_cn "$city")" "$PLAIN"
    printf '   模式：%s  ·  方向：VPS → 国内目标\n' "$mode"
    route_rule

    for current in "${carriers[@]}"; do
        ip=$(route_target "$city" "$current") || ip=""
        if [[ -z $ip ]]; then
            printf '%s | 未测试 | — | 未配置目标地址\n' "$(route_name "$city" "$current")" >>"$summary_file"
            route_err "$(route_name "$city" "$current") 缺少已核实目标。使用 portman route set $city $current <IP> 配置"
            failures=$((failures + 1))
            continue
        fi
        route_probe_one "$city" "$current" "$ip" "$detail" "$mtr" "$outputdir" "$summary_file" ||
            failures=$((failures + 1))
    done

    echo
    printf '%s================ 本次路由汇总 ================%s\n' "$BOLD" "$PLAIN"
    printf '地区/运营商 | 状态 | 终点延迟 | 经过的骨干网络\n'
    cat "$summary_file"
    route_rule
    rm -f "$summary_file"

    route_note "本次测试结束：$(( ${#carriers[@]} - failures ))/${#carriers[@]} 个目标产生有效报告。"
    route_note '汇总仅描述实际观测到的骨干；未出现的网络不单独作负面评价。'
    route_note 'VPS 上仅能直接测回程；去程必须由中国境内的测点发起。'
    (( failures == 0 ))
}

# 创建本次报告目录并输出路径: route_report_dir <名称后缀>
route_report_dir() {
    local dir
    dir="$ROUTE_REPORTS/$(date +%Y%m%d_%H%M%S)_$1"
    if ! mkdir -p "$dir" || ! chmod 700 "$dir"; then
        route_err "无法创建报告目录: $dir"
        return 1
    fi
    printf '%s\n' "$dir"
}

# 运行检测命令，同时把输出保存为 $dir/summary.txt，返回检测命令的退出码
#   参数: 报告目录 命令...
route_save_report() {
    local dir=$1 rc
    shift
    "$@" 2>&1 | tee "$dir/summary.txt"
    rc=${PIPESTATUS[0]}
    route_note "报告已保存在 $dir （TXT + 原始 JSON）"
    return "$rc"
}

# 检测预置地区: route_run <地区> <运营商|all> <detail> <mtr> <save>
route_run() {
    local city=$1 isp=$2 detail=$3 mtr=$4 save=$5 dir kind=route
    route_require || return 1
    if [[ $save == 1 ]]; then
        [[ $mtr == 1 ]] && kind=mtr
        dir=$(route_report_dir "${city}_${kind}") || return 1
        route_save_report "$dir" route_run_inner "$city" "$isp" "$detail" "$mtr" "$dir"
        return
    fi
    route_run_inner "$city" "$isp" "$detail" "$mtr" '-'
}

# 检测自定义目标: route_custom <IP/域名> <detail> <mtr> <save>
route_custom() {
    local addr=$1 detail=$2 mtr=$3 save=$4 dir
    route_valid_target "$addr" || { route_err '自定义目标格式不合法'; return 2; }
    route_require || return 1
    if [[ $save == 1 ]]; then
        dir=$(route_report_dir custom) || return 1
        route_save_report "$dir" route_probe_one custom custom "$addr" "$detail" "$mtr" "$dir"
        return
    fi
    route_probe_one custom custom "$addr" "$detail" "$mtr" '-'
}

# ===========================================================================
# 6. 菜单与命令行
# ===========================================================================
route_usage() {
    cat <<'HELP'
路由检测 · NextTrace 中文报告（VPS → 国内回程）

检测:
  portman route                          默认上海三网快速测试
  portman route shanghai [all|ct|cu|cm]  上海；也支持 beijing/guangzhou/suzhou
  portman route beijing --detail         显示每一跳 IP、ASN、中文名称
  portman route guangzhou --save         保存 TXT 汇总与逐运营商原始 JSON
  portman route mtr shanghai --save      每跳 20 次，统计终点丢包与延迟波动
  portman route custom 1.1.1.1 --detail  自定义目标

设置与依赖:
  portman route set suzhou ct 目标IP     设置苏州测试地址（cu=联通，cm=移动）
  portman route menu                     交互菜单
  portman route install                  确认后安装缺失依赖
  portman route doctor                   显示依赖状态、实际路径及版本

参数: --detail 详细逐跳 | --save 保存报告 | --mtr 稳定性测试
提示: 苏州首次使用需指定三网测试 IP，防止误用外地节点。
HELP
}

route_menu() {
    local choice isp ip
    while :; do
        clear 2>/dev/null
        printf '%s===== portman · 三网路由检测 =====%s\n\n' "$BOLD" "$PLAIN"
        printf '  %s检测%s\n' "$CYAN" "$PLAIN"
        echo "   1. 上海三网快速测试 (默认)"
        echo "   2. 上海三网详细逐跳"
        echo "   3. 北京三网测试"
        echo "   4. 广州三网测试"
        echo "   5. 苏州三网测试"
        echo "   6. 上海三网 MTR 稳定性 (每跳 20 次)"
        echo "   7. 自定义目标 IP / 域名"
        printf '  %s设置 · 报告 · 依赖%s\n' "$CYAN" "$PLAIN"
        echo "   8. 配置苏州测试地址"
        echo "   9. 上海三网测试并保存报告"
        echo "  10. 安装 / 修复检测依赖"
        echo "  11. 检查依赖状态"
        echo
        echo "   0. 返回上级"
        echo
        read -rp '请选择 [0-11]: ' choice || return 0
        echo
        case $choice in
            1)  route_run shanghai all 0 0 0 ;;
            2)  route_run shanghai all 1 0 0 ;;
            3)  route_run beijing all 0 0 0 ;;
            4)  route_run guangzhou all 0 0 0 ;;
            5)  route_run suzhou all 0 0 0 ;;
            6)  route_run shanghai all 0 1 0 ;;
            7)  read -rp '目标 IP / 域名: ' ip
                route_custom "$ip" 1 0 0 ;;
            8)  read -rp '运营商 [ct 电信 / cu 联通 / cm 移动]: ' isp
                read -rp '已核实的苏州测试 IP: ' ip
                route_set_target suzhou "$isp" "$ip" ;;
            9)  route_run shanghai all 0 0 1 ;;
            10) route_install_deps ;;
            11) route_doctor ;;
            0|q|"") return 0 ;;
            *)  route_err '无效选择' ;;
        esac
        echo
        read -rp '按回车键继续...' _ || return 0
    done
}

# 解析通用选项，直接修改调用方的 detail / save / mtr 变量；不是选项时返回 1
route_parse_flag() {
    case $1 in
        --detail) detail=1 ;;
        --save)   save=1 ;;
        --mtr)    mtr=1 ;;
        *) return 1 ;;
    esac
}

route_main() {
    local city=shanghai isp=all detail=0 mtr=0 save=0 arg target

    case ${1:-} in
        menu)           route_menu; return ;;
        help|-h|--help) route_usage; return ;;
        install)        route_install_deps; return ;;
        doctor)         route_doctor; return ;;
        set)            shift; route_set_target "${1:-}" "${2:-}" "${3:-}"; return ;;
        mtr)            mtr=1; shift ;;
    esac

    if [[ ${1:-} == custom ]]; then
        target=${2:-}
        shift 2 2>/dev/null || shift
        for arg in "$@"; do
            route_parse_flag "$arg" || { route_err "未知参数：$arg"; return 2; }
        done
        route_custom "$target" "$detail" "$mtr" "$save"
        return
    fi

    for arg in "$@"; do
        route_parse_flag "$arg" && continue
        if route_city "$arg" >/dev/null; then
            city=$(route_city "$arg")
        elif route_isp "$arg" >/dev/null; then
            isp=$(route_isp "$arg")
        else
            route_err "未知参数：$arg"
            route_usage
            return 2
        fi
    done
    route_run "$city" "$isp" "$detail" "$mtr" "$save"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    route_main "$@"
fi
