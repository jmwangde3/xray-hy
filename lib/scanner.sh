#!/usr/bin/env bash
# xray-hy / REALITY 伪装站自动发现（XTLS/RealiTLScanner）+ 结果缓存。
#
# 为什么需要它：conf/targets.tsv 是一份全球静态候选表，而最合适的伪装站往往
# 就在 VPS 自己的机房里 —— 同一个 /24、同一家运营商、TLS 握手个位数毫秒，
# 而且机架不拆它就一直在。RealiTLScanner 能把一个网段里所有 TLS 1.3 + HTTP/2
# 的站点列出来；这个模块负责排序、用**真实 SNI** 逐个验证，并把结果缓存下来，
# 下次建 REALITY 节点不必再扫一遍。
#
# 两个容易踩的点，实现里都做了处理：
#   1. 扫描器看到的是「该 IP 在无 SNI 时给出的默认证书」，CN 可能是 *.example.com。
#      REALITY 回落时会带 serverNames[0] 去握手，所以必须换成具体域名再用
#      curl --resolve 验证证书确实覆盖它，否则回落到源站时证书对不上号。
#   2. 本机 443 上跑的就是 REALITY，扫描会看到「自己回落到 target 的那张证书」，
#      不排除就会把自己选成 target，流量自我循环。
#
# 缓存格式（TSV，前两行是元数据，其余按 score 降序）：
#   # xray-hy scan-cache 1
#   # epoch=<unix> at=<iso> cidr=<...> tool=<ver>
#   score  ip  sni  target  appconnect_ms  http_code  size  issuer  tls  at

SCANNER_REPO="XTLS/RealiTLScanner"
SCANNER_VER="${SCANNER_VER:-v0.2.3}"
XHY_TOOLS_DIR="${XHY_TOOLS_DIR:-/usr/local/lib/xray-hy-tools}"
SCANNER_BIN="${SCANNER_BIN:-$XHY_TOOLS_DIR/RealiTLScanner}"
SCANNER_CACHE="${SCANNER_CACHE:-$XHY_ETC/scan-cache.tsv}"
SCANNER_WORK="${SCANNER_WORK:-$XHY_ETC/scan}"
SCANNER_TTL="${SCANNER_TTL:-604800}"        # 缓存有效期，秒（默认 7 天）
SCANNER_MAX_VERIFY="${SCANNER_MAX_VERIFY:-48}"
SCANNER_BUDGET="${SCANNER_BUDGET:-180}"     # 验证阶段总时长上限，秒
SCANNER_THREADS="${SCANNER_THREADS:-128}"
SCANNER_TIMEOUT="${SCANNER_TIMEOUT:-4}"

# 下面这些函数的 stdout 会被 `best="$(scanner_pick)"` 捕获，只允许输出最终
# 三元组 "<target> <sni> <label>"。所有进度/诊断一律走 stderr。
sc_info() { info "$@" >&2; }
sc_ok()   { ok   "$@" >&2; }

# ---------------------------------------------------------------------------
# 二进制获取
# ---------------------------------------------------------------------------

# 官方只发 linux-amd64 / linux-arm64 两个 Linux 资产。
scanner_asset() {
    case "$XHY_ARCH" in
        64)        printf 'linux-amd64' ;;
        arm64-v8a) printf 'linux-arm64' ;;
        *)         return 1 ;;
    esac
}

# 能不能跑起来。musl 系统缺 glibc loader 时是 127/not found，不是崩溃。
scanner_smoke() {
    local out="" rc=0
    [[ -x "$SCANNER_BIN" ]] || return 1
    out="$("$SCANNER_BIN" 2>&1)" || rc=$?
    (( rc == 127 )) && return 1
    grep -q -- '-addr' <<<"$out"
}

scanner_ensure() {
    local asset tmp rc=0
    if scanner_smoke; then return 0; fi
    if ! asset="$(scanner_asset)"; then
        err "RealiTLScanner 只提供 linux-amd64 / linux-arm64，当前架构 $XHY_ARCH 用不了"
        err "改用内置地区库: xhy target → 1) 按地区自动匹配，或手动指定 target/SNI"
        return 1
    fi
    need_root
    install -d -m 0755 "$XHY_TOOLS_DIR" || return 1
    tmp="$(mktemp "$XHY_TOOLS_DIR/.rts.XXXXXX")" || return 1
    sc_info "下载 RealiTLScanner $SCANNER_VER ($asset，约 4 MB)"
    if ! fetch "https://github.com/${SCANNER_REPO}/releases/download/${SCANNER_VER}/RealiTLScanner-${asset}" "$tmp"; then
        rm -f "$tmp"
        err "RealiTLScanner 下载失败。GitHub 不通时只能用内置地区库。"
        return 1
    fi
    if [[ "$(head -c 4 "$tmp" 2>/dev/null)" != $'\x7fELF' ]]; then
        rm -f "$tmp"
        err "下载内容不是 ELF 二进制（可能被劫持/重定向），已中止"
        return 1
    fi
    chmod 0755 "$tmp"
    install -m 0755 "$tmp" "$SCANNER_BIN" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    if ! scanner_smoke; then
        # 官方二进制是 glibc 动态链接的；Alpine 是 musl，直接跑会 "not found"。
        if [[ "$XHY_DISTRO" == "alpine" ]]; then
            sc_info "RealiTLScanner 需要 glibc 兼容层（Alpine/musl），安装 libc6-compat ..."
            pkg_install libc6-compat >/dev/null 2>&1 || true
            if ! scanner_smoke; then
                pkg_install gcompat >/dev/null 2>&1 || true
            fi
        fi
        if ! scanner_smoke; then
            err "RealiTLScanner 无法运行（架构或运行库不匹配）：$SCANNER_BIN"
            err "Alpine 可手工修复: apk add libc6-compat gcompat"
            return 1
        fi
        sc_ok "glibc 兼容层已装好，扫描器可用"
    fi
    sc_ok "扫描器就绪: $SCANNER_BIN ($SCANNER_VER)"
}

# ---------------------------------------------------------------------------
# 网段推导
# ---------------------------------------------------------------------------

# cidr_truncate <ipv4> <prefix> —— 把 IP 归到指定前缀的网络地址
cidr_truncate() {
    local ip="$1" p="$2"
    is_ip_literal "$ip" || return 1
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 8 && p <= 32 )) || return 1
    awk -v ip="$ip" -v p="$p" 'BEGIN {
        n = split(ip, a, ".")
        if (n != 4) exit 1
        v = a[1] * 16777216 + a[2] * 65536 + a[3] * 256 + a[4]
        block = 2 ^ (32 - p)
        net = int(v / block) * block
        printf "%d.%d.%d.%d/%d", int(net / 16777216) % 256, int(net / 65536) % 256, int(net / 256) % 256, net % 256, p
    }'
}

# 默认扫本机公网 IP 所在的 /24：同机架、最低延迟、最容易长期存在。
scanner_default_cidr() {
    local ip
    ip="$(public_ip || true)"
    is_ip_literal "$ip" || return 1
    cidr_truncate "$ip" 24
}

# ---------------------------------------------------------------------------
# 候选过滤与打分（纯函数，离线可测）
# ---------------------------------------------------------------------------

# CN -> 可用于 SNI 的具体域名（通配符证书给两个猜测，按顺序试）
scanner_sni_candidates() {
    local cn="${1,,}" base
    base="${cn#\*.}"
    case "$cn" in
        \*.*) printf '%s %s\n' "www.${base}" "${base}" ;;
        *)    printf '%s\n' "$base" ;;
    esac
}

# 这个 CN 适合当伪装站吗？排除的不是「证书无效」，而是「一眼就是代理/测试环境」。
scanner_domain_ok() {
    local d="${1,,}" lab
    local -a labels=()
    # 通配符证书的 "*." 是证书属性，不是域名的一部分；去掉后再按标签判断。
    d="${d#\*.}"
    [[ -n "$d" ]] || return 1
    case "$d" in
        *" "*|*/*|*:*) return 1 ;;
        *kubernetes*|*ingress*|*localhost*|*example.com|*example.net|*example.org|*invalid) return 1 ;;
        *.local|*.internal|*.lan|*.test|*.home|*.arpa|*.onion) return 1 ;;
        # 这类 CN 说明这台机器只是别人的反代/CDN 边缘，拿到的是厂商证书而不是
        # 站点自己的证书，回落时会露馅。
        *cloudflare.com|*cloudflare.net|*fastly.net|*akamaiedge.net) return 1 ;;
    esac
    [[ "$d" == *.* ]] || return 1
    IFS='.' read -r -a labels <<<"$d"
    (( ${#labels[@]} >= 2 )) || return 1
    for lab in "${labels[@]}"; do
        [[ "$lab" =~ ^[a-z0-9-]+$ ]] || return 1
        case "$lab" in
            api|vpn|proxy|proxies|sub|subs|subscribe|subscription|node|nodes|airport|\
            test|testing|dev|develop|staging|stage|demo|alpha|beta|sandbox|\
            chatgpt|openai|claude|gemini|copilot|grok|\
            ss|ssr|v2ray|xray|clash|trojan|hysteria|hy2|reality|tunnel|relay|forward)
                return 1 ;;
        esac
    done
    if [[ "${labels[0]}" =~ ^[0-9]+$ ]]; then return 1; fi
    return 0
}

# scanner_score <appconnect_ms> <http_code> <size> <wildcard 0|1> <www 0|1>
# 分数只用于排序，不做合格判定（合格与否由 scanner_probe 决定）。
#
# 不把 TFO 能力纳入打分（它是 --require-tfo 的硬过滤项，但不加权）：
#   - TFO 只是我们服务端 listen socket 的行为，跟随目标即可（见 sockopt.sh
#     的 target_tfo_detect / tfo_decide），不需要目标「优先支持」；
#   - 支持被动 TFO 的 HTTPS 站点在公网上是少数，加权会把候选池往冷门站带，
#     削弱抗探测可信度；
#   - 伪装站不承载正常代理流量（REALITY 只把未认证探测转发过去），它的带宽和
#     延迟不影响代理上网速度，凑 TFO 换来的只是首连省 1 RTT。
# 顺序：先按质量打分 → 展示短名单时现场探测 TFO → 需要则硬过滤 → 用户选。
# 是否强制由用户在 xhy scan / xhy target 里选，默认不强制。
scanner_score() {
    local ms="${1:-9999}" code="${2:-0}" size="${3:-0}" wild="${4:-0}" www="${5:-0}" s=100
    [[ "$ms" =~ ^[0-9]+$ ]] || ms=9999
    (( ms <= 0 )) && ms=9999
    # 同机房通常 <10ms。每 10ms 扣 3 分，最低 70：延迟差一点不该盖过站点质量。
    s=$(( s - (ms / 10) * 3 ))
    (( s < 70 )) && s=70
    case "$code" in
        200)      s=$(( s + 15 )) ;;
        204|206)  s=$(( s + 8 )) ;;
        401|403)  s=$(( s - 15 )) ;;
        404|410)  s=$(( s - 20 )) ;;
        5??)      s=$(( s - 30 )) ;;
    esac
    (( size > 2000 )) && s=$(( s + 6 ))
    (( wild == 1 )) && s=$(( s - 4 ))
    # www. 是最常见的访问形态，回落时看起来最像普通用户访问。
    (( www == 1 )) && s=$(( s + 2 ))
    printf '%d' "$s"
}

# CSV -> 候选 TSV（ip \t cn \t issuer \t tls \t alpn）
# RealiTLScanner 只写「TLS 1.3 + h2 + 有 CN + 有 issuer」的行，这里再做一次
# 防御性过滤，并按列尾定位（issuer 里可能带逗号，不能简单按第 9/10 列取）。
scanner_candidates() {
    local csv="$1" tab=$'\t'
    [[ -s "$csv" ]] || return 1
    awk -F',' -v OFS="$tab" '
        NR > 1 && NF >= 11 {
            ip = $1; tls = $(NF - 8); alpn = $(NF - 7); cn = $(NF - 2); iss = $(NF - 1)
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", cn)
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", iss)
            if (tls !~ /1\.3/ || alpn !~ /h2/ || cn == "") next
            print ip, cn, iss, tls, alpn
        }' "$csv" | sort -u
}

# 用真实 SNI 打这台 IP。成功时输出：
#   <http_version>|<appconnect_ms>|<http_code>|<size>|<redirect 0/1>|<cdn 0/1>
# 故意不带 -k：证书必须真的覆盖这个域名，否则 RELITY 回落时看到的就是错证书。
scanner_probe() {
    local ip="$1" sni="$2" d rc=0 met hv ac code size ms redir=0 cdn=0
    d="$(mktemp -d "${TMPDIR:-/tmp}/xhy-probe.XXXXXX")" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$d'" RETURN
    curl -sS --tlsv1.3 --http2 --max-time 8 \
        --resolve "${sni}:443:${ip}" \
        -D "$d/h" -o /dev/null \
        -w '%{http_version}|%{time_appconnect}|%{http_code}|%{size_download}' \
        "https://${sni}/" >"$d/m" 2>/dev/null || rc=$?
    (( rc == 0 )) || return 1
    [[ -s "$d/m" ]] || return 1
    met="$(cat "$d/m")"
    IFS='|' read -r hv ac code size <<<"$met"
    [[ "$hv" == "2" ]] || return 1
    [[ -n "$code" && "$code" != "000" ]] || return 1
    ms="$(awk -v v="${ac:-0}" 'BEGIN { printf "%d", v * 1000 }')"
    if grep -qiE '^location:' "$d/h"; then redir=1; fi
    case "$code" in 30[12378]) redir=1 ;; esac
    if grep -qiE '^(cf-ray|cf-cache-status|x-cache|via):|^server:[[:space:]]*cloudflare' "$d/h"; then
        cdn=1
    fi
    printf '%s|%s|%s|%s|%s|%s\n' "$hv" "$ms" "$code" "$size" "$redir" "$cdn"
}

# CSV -> 已排序的合格候选 TSV（就是缓存的数据行格式）
scanner_rank() {
    local csv="$1" out="$2" tab=$'\t'
    local ip cn iss tls alpn sni res hv ms code size redir cdn sc
    local self4 self6 total=0 keep=0 t0 now
    : >"$out"
    self4="$(public_ip || true)"
    self6="$(public_ip6 || true)"
    total="$(scanner_candidates "$csv" | wc -l | tr -d ' ')"
    t0="$(date +%s)"
    while IFS="$tab" read -r ip cn iss tls alpn; do
        [[ -n "$ip" ]] || continue
        # 本机 443 就是 REALITY：不排掉会把自己选成 target。
        if [[ -n "$self4" && "$ip" == "$self4" ]]; then continue; fi
        if [[ -n "$self6" && "$ip" == "$self6" ]]; then continue; fi
        scanner_domain_ok "$cn" || continue
        if (( keep >= SCANNER_MAX_VERIFY )); then break; fi
        now="$(date +%s)"
        if (( now - t0 > SCANNER_BUDGET )); then
            warn "验证阶段超过 ${SCANNER_BUDGET}s，用已完成的 $keep 个候选继续"
            break
        fi
        for sni in $(scanner_sni_candidates "$cn"); do
            if ! res="$(scanner_probe "$ip" "$sni")"; then continue; fi
            IFS='|' read -r hv ms code size redir cdn <<<"$res"
            if (( redir == 1 || cdn == 1 )); then continue; fi
            local ww=0 wc=0
            if [[ "$cn" == \*.* ]]; then ww=1; fi
            if [[ "${sni#www.}" != "$sni" ]]; then wc=1; fi
            sc="$(scanner_score "$ms" "$code" "$size" "$ww" "$wc")" 
            printf '%s\t%s\t%s\t%s:443\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$sc" "$ip" "$sni" "$ip" "$ms" "$code" "$size" "$iss" "$tls" "$(date -Is)" >>"$out"
            keep=$(( keep + 1 ))
            sc_info "  + ${sni} @ ${ip}  ${ms}ms  HTTP ${code}  ${size}B  score ${sc}"
            break
        done
    done < <(scanner_candidates "$csv")
    (( keep > 0 )) || return 1
    # 分数相同的按握手延迟升序，再按行内容定序（避免每次扫描结果漂移）。
    sort -t "$tab" -k1,1nr -k5,5n "$out" >"$out.sorted" && mv -f "$out.sorted" "$out"
    sc_ok "验证完成：$keep 个可用候选（共 $total 个去重候选）"
}

# ---------------------------------------------------------------------------
# 缓存
# ---------------------------------------------------------------------------

scanner_cache_epoch() {
    sed -n 's/^# epoch=\([0-9][0-9]*\).*/\1/p' "$SCANNER_CACHE" 2>/dev/null | head -1
}

scanner_cache_age_h() {
    local epoch now
    epoch="$(scanner_cache_epoch)"
    if [[ -z "$epoch" ]]; then printf '?'; return 0; fi
    now="$(date +%s)"
    printf '%s' "$(( (now - epoch) / 3600 ))"
}

scanner_cache_valid() {
    local epoch now
    [[ -s "$SCANNER_CACHE" ]] || return 1
    epoch="$(scanner_cache_epoch)"
    [[ -n "$epoch" ]] || return 1
    now="$(date +%s)"
    (( now - epoch <= SCANNER_TTL ))
}

scanner_cache_count() {
    local n="0"
    [[ -s "$SCANNER_CACHE" ]] || { printf '0'; return 0; }
    n="$(grep -vc '^#' "$SCANNER_CACHE" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

scanner_cache_best() {
    local tab=$'\t'
    [[ -s "$SCANNER_CACHE" ]] || return 1
    { grep -v '^#' "$SCANNER_CACHE" 2>/dev/null || true; } | sort -t "$tab" -k1,1nr -k5,5n
}

# 同 ip|sni 只留分数最高的那条。
scanner_cache_merge() {
    local old="$1" new="$2" tab=$'\t'
    { grep -v '^#' "$old" 2>/dev/null || true; cat "$new"; } \
        | awk -F"$tab" '
            {
                k = $2 "|" $3
                s = $1 + 0
                if (!(k in score) || s > score[k]) { score[k] = s; line[k] = $0 }
            }
            END { for (k in line) print line[k] }' \
        | sort -t "$tab" -k1,1nr -k5,5n
}

# scanner_cache_save <cidr> <ranked.tsv> [replace 0|1]
scanner_cache_save() {
    local cidr="$1" rows="$2" replace="${3:-0}" tmp tab=$'\t'
    [[ -s "$rows" ]] || return 1
    # 不用 `install -d -m`：目录已存在时它会去 chmod，MSYS / 只读挂载上会返回
    # 非零，缓存就写不进去了。权限失败不影响功能，忽略即可（与 init_dirs 一致）。
    mkdir -p "$(dirname "$SCANNER_CACHE")" || return 1
    chmod 0700 "$(dirname "$SCANNER_CACHE")" 2>/dev/null || true
    tmp="$(mktemp "${SCANNER_CACHE}.XXXXXX")" || return 1
    {
        printf '# xray-hy scan-cache 1\n'
        printf '# epoch=%s at=%s cidr=%s tool=%s\n' \
            "$(date +%s)" "$(date -Is)" "$cidr" "$SCANNER_VER"
        if [[ "$replace" == "0" ]] && scanner_cache_valid; then
            scanner_cache_merge "$SCANNER_CACHE" "$rows"
        else
            sort -t "$tab" -k1,1nr -k5,5n "$rows"
        fi
    } >"$tmp" || { rm -f "$tmp"; return 1; }
    install -m 0600 "$tmp" "$SCANNER_CACHE" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp" || true
}

scanner_cache_clear() {
    rm -f "$SCANNER_CACHE" && sc_ok "已清除扫描缓存"
}

scanner_cache_show() {
    local sc ip sni tgt ms code size iss tls at epoch at_iso tfo
    if [[ ! -s "$SCANNER_CACHE" ]]; then
        warn "暂无扫描缓存（xhy scan 扫一次就会存下来）"
        return 0
    fi
    epoch="$(scanner_cache_epoch)"
    at_iso="$(sed -n 's/^# .*at=\([^ ]*\).*/\1/p' "$SCANNER_CACHE" 2>/dev/null | head -1)"
    printf '缓存文件 : %s\n' "$SCANNER_CACHE"
    printf '扫描时间 : %s（%s 小时前，有效期 %s 小时）\n' \
        "${at_iso:-?}" "$(scanner_cache_age_h)" "$(( SCANNER_TTL / 3600 ))"
    if scanner_cache_valid; then printf '状态     : 有效（建节点时会被直接采用）\n'
    else printf '状态     : 已过期（下次自动扫描会重扫）\n'; fi
    printf '\n  %-4s %-16s %-34s %7s %5s %9s  %-6s %s\n' "分数" "IP" "SNI" "握手" "HTTP" "大小" "TFO" "签发者"
    printf '  %s\n' "--------------------------------------------------------------------------------------------------"
    printf '  TFO 列为现场探测结果（不写入缓存；探测不了按不支持处理）\n'
    while IFS=$'\t' read -r sc ip sni tgt ms code size iss tls at; do
        [[ -n "$ip" ]] || continue
        tfo="$(scanner_tfo_tag "$(scanner_tfo_of "$ip" "$sni")")"
        printf '  %-4s %-16s %-34s %5sms %5s %8sB  %-6s %s\n' \
            "$sc" "$ip" "$sni" "$ms" "$code" "$size" "$tfo" "$iss"
    done < <(scanner_cache_best)
    printf '\n'
}

scanner_cache_verify() {
    local sc ip sni tgt ms code size iss tls at tmp keep=0 drop=0 hdr tfo
    [[ -s "$SCANNER_CACHE" ]] || { warn "暂无扫描缓存"; return 1; }
    tmp="$(mktemp "${SCANNER_CACHE}.XXXXXX")" || return 1
    hdr="$(head -2 "$SCANNER_CACHE" | grep '^#' || true)"
    {
        printf '%s\n' "$hdr"
        while IFS=$'\t' read -r sc ip sni tgt ms code size iss tls at; do
            [[ -n "$ip" ]] || continue
            tfo="$(scanner_tfo_tag "$(scanner_tfo_of "$ip" "$sni")")"
            if target_validate "$tgt" "$sni" "$tfo" >&2; then
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$sc" "$ip" "$sni" "$tgt" "$ms" "$code" "$size" "$iss" "$tls" "$at"
                keep=$(( keep + 1 ))
            else
                drop=$(( drop + 1 ))
            fi
        done < <(scanner_cache_best)
    } >"$tmp"
    install -m 0600 "$tmp" "$SCANNER_CACHE"
    rm -f "$tmp" || true
    if (( keep == 0 )); then
        rm -f "$SCANNER_CACHE"
        warn "所有缓存候选都已失效，缓存已清空（下次会重新扫描）"
        return 1
    fi
    sc_ok "复核完成：保留 $keep 个，剔除 $drop 个"
}

# 逐个拿缓存候选做 REALITY 级校验，返回第一个可用的 "<target> <sni> scan"。
# target_validate 的 stdout 必须转到 stderr，否则会污染调用方捕获的三元组。
scanner_cache_pick_valid() {
    local sc ip sni tgt ms code size iss tls at
    while IFS=$'\t' read -r sc ip sni tgt ms code size iss tls at; do
        [[ -n "$tgt" ]] || continue
        if target_validate "$tgt" "$sni" >&2; then
            printf '%s %s scan\n' "$tgt" "$sni"
            return 0
        fi
    done < <(scanner_cache_best)
    return 1
}

# ---------------------------------------------------------------------------
# 候选短名单与 TFO 选项
# ---------------------------------------------------------------------------
#
# TFO 能力不写进缓存：它是站点当前配置，7 天 TTL 的缓存反而可能过期。
# 展示短名单时现场探测（同机房约 0.1s），并用关联数组在同一次调用内去重。
# 打分不因 TFO 加权（scanner_score 注释），但 --require-tfo 会做硬过滤。

SCANNER_SHORTLIST="${SCANNER_SHORTLIST:-5}"   # 最终展示给用户挑的候选数
SCANNER_TFO_POOL="${SCANNER_TFO_POOL:-12}"    # require-tfo 时最多探多少个
# 不能用 declare -A：本文件是被 load_libs() 在函数内 source 的，declare
# 会创建局部变量，函数返回后它退化成普通索引数组、字符串下标触发算术错误。
# 用空格分隔的 "ip|sni=0/1" 字符串做去重，无作用域问题。
XHY_TFO_CACHE=""

# scanner_tfo_of <ip> <sni> -> 1（支持）/ 0（不支持或判不了）
scanner_tfo_of() {
    local k="${1}|${2}" r
    case " $XHY_TFO_CACHE " in
        *" $k=1 "*) printf '1'; return 0 ;;
        *" $k=0 "*) printf '0'; return 0 ;;
    esac
    if target_tfo_detect "$1" 443 "$2"; then r=1; else r=0; fi
    XHY_TFO_CACHE="$XHY_TFO_CACHE $k=$r"
    printf '%s' "$r"
}

# scanner_tfo_tag <1|0> -> 「支持」/「不支持」。
# 探测失败（工具缺失、远端无响应）与明确不支持一并显示「不支持」：
# 决策上两者都按关闭处理，不给用户一个看起来「可能能用」的模糊态。
scanner_tfo_tag() {
    if [[ "${1:-0}" == "1" ]]; then printf '支持'; else printf '不支持'; fi
}

# 从缓存挑 3–5 个候选展示给用户选。
# stdout 只输出最终 "<target> <sni> scan"；列表与提示一律走 stderr，
# 因为调用方是 `best="$(scanner_pick)"`。
# 非交互（读不到 /dev/tty）时自动取第 1 个，脚本化调用不会被卡住。
scanner_shortlist() {
    local require="${1:-0}" want="${2:-$SCANNER_SHORTLIST}" pool
    local -a tgts=() snis=() scs=() mss=() codes=() tfos=()
    local sc ip sni tgt ms code size iss tls at tfo n=0 ans="" pick=0 i
    if (( require == 1 )); then
        pool="$SCANNER_TFO_POOL"
    else
        pool=$(( want * 3 ))
    fi
    XHY_TFO_CACHE=""
    while IFS=$'\t' read -r sc ip sni tgt ms code size iss tls at; do
        [[ -n "$tgt" ]] || continue
        (( n >= pool )) && break
        n=$(( n + 1 ))
        # 先现场探测 TFO，把标记随 target_validate 一起打印：即使该候选被
        # --require-tfo 过滤掉，用户也能看到「这个站到底支不支持」，而不是
        # 只看到最后一句「没有支持 TFO 的站点」。探测结果在同次调用内缓存。
        tfo="$(scanner_tfo_of "$ip" "$sni")"
        target_validate "$tgt" "$sni" "$(scanner_tfo_tag "$tfo")" >&2 || continue
        if (( require == 1 )) && [[ "$tfo" != "1" ]]; then continue; fi
        tgts+=("$tgt"); snis+=("$sni"); scs+=("$sc")
        mss+=("$ms"); codes+=("$code"); tfos+=("$tfo")
        (( ${#tgts[@]} >= want )) && break
    done < <(scanner_cache_best)

    if (( ${#tgts[@]} == 0 )); then
        if (( require == 1 )); then
            warn "前 $pool 个候选都不支持被动 TFO（上面每个站点后已标注 TFO 结果）。可去掉 --require-tfo 按质量选、换 --cidr 网段，或 xhy scan --refresh 重扫。"
        else
            warn "缓存里没有通过校验的候选，请 xhy scan --refresh 重扫。"
        fi
        return 1
    fi

    {
        printf '\n  候选伪装站（按质量排序；TFO=目标是否支持被动 TFO）\n'
        printf '  %-3s %-5s %-16s %-34s %8s %6s  %s\n' "#" "分数" "IP" "SNI" "握手" "HTTP" "TFO"
        printf '  %s\n' "--------------------------------------------------------------------------------------------"
        for (( i=0; i<${#tgts[@]}; i++ )); do
            if [[ "${tfos[$i]}" == "1" ]]; then tfo="支持"; else tfo="—"; fi
            printf '  %-3s %-5s %-16s %-34s %6sms %6s  %s\n' \
                "$(( i + 1 ))" "${scs[$i]}" "${tgts[$i]%%:*}" "${snis[$i]}" \
                "${mss[$i]}" "${codes[$i]}" "$tfo"
        done
        if (( require == 1 )); then
            printf '  （已按「必须支持 TFO」过滤）\n'
        else
            printf '  （未强制 TFO；列表里也可能含支持 TFO 的站点）\n'
        fi
        printf '\n'
    } >&2

    printf '  选哪个 [1-%d]（回车=1，0=自动取最高分）: ' "${#tgts[@]}" >&2
    if read -r ans </dev/tty 2>/dev/null; then :; else ans=""; fi
    printf '\n' >&2
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#tgts[@]} )); then
        pick=$(( ans - 1 ))
    fi
    printf '%s %s scan\n' "${tgts[$pick]}" "${snis[$pick]}"
    sc_ok "已选: target=${tgts[$pick]} SNI=${snis[$pick]}（TFO=${tfos[$pick]}）"
    return 0
}

# ---------------------------------------------------------------------------
# 扫描与选择
# ---------------------------------------------------------------------------

scanner_scan() {
    local cidr="$1" ts csv log ranked n uniq
    scanner_ensure || return 1
    install -d -m 0700 "$SCANNER_WORK" || return 1
    ts="$(date +%s)"
    csv="$SCANNER_WORK/scan-${ts}.csv"
    log="$csv.log"
    sc_info "扫描 $cidr（端口 443，thread ${SCANNER_THREADS}，超时 ${SCANNER_TIMEOUT}s/主机）..."
    if ! "$SCANNER_BIN" -addr "$cidr" -port 443 -thread "$SCANNER_THREADS" \
            -timeout "$SCANNER_TIMEOUT" -out "$csv" >"$log" 2>&1; then
        err "扫描失败，日志: $log" >&2
        return 1
    fi
    n=$(( $(wc -l <"$csv" | tr -d ' ') - 1 ))
    uniq="$(scanner_candidates "$csv" | wc -l | tr -d ' ')"
    if (( n <= 0 )); then
        warn "$cidr 内没有 TLS 1.3 + HTTP/2 站点（日志: $log）"
        return 1
    fi
    sc_info "命中 ${uniq:-0} 个 TLS 1.3 + h2 站点（$n 条记录，按域名去重），逐个用真实 SNI 验证（最多 ${SCANNER_MAX_VERIFY} 个）..."
    ranked="$SCANNER_WORK/ranked-${ts}.tsv"
    if ! scanner_rank "$csv" "$ranked"; then
        warn "没有既非 CDN、又不跳转、证书可校验的站点（日志: $log）"
        return 1
    fi
    scanner_cache_save "$cidr" "$ranked" 0 || return 1
    scanner_prune_work
    sc_ok "结果已缓存: $SCANNER_CACHE"
}

# 只保留最近 5 次扫描产物，别把 /etc 撑大（每次 CSV 只有几十 KB，但会累积）。
scanner_prune_work() {
    local f n=0
    [[ -d "$SCANNER_WORK" ]] || return 0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        n=$(( n + 1 ))
        if (( n > 10 )); then rm -f "$f"; fi
    done < <(ls -1t "$SCANNER_WORK"/scan-*.csv "$SCANNER_WORK"/ranked-*.tsv 2>/dev/null || true)
    return 0
}

# 输出 "<target> <sni> <label>"：优先用有效缓存，否则扫本机 /24（不够再扩 /21）。
#   scanner_pick [--refresh] [--cidr 1.2.3.0/24] [--require-tfo]
# --require-tfo：只展示支持被动 TFO 的候选；默认不强制（按质量选，可能含 TFO 站）。
scanner_pick() {
    local refresh=0 cidr="" best wide require_tfo=0
    while (( $# > 0 )); do
        case "$1" in
            --refresh) refresh=1; shift ;;
            --cidr)    cidr="${2:?--cidr 需要网段}"; shift 2 ;;
            --require-tfo) require_tfo=1; shift ;;
            -*)        die "未知参数: $1（可用 --refresh / --cidr / --require-tfo）" ;;
            *)         cidr="$1"; shift ;;
        esac
    done

    if (( refresh == 0 )) && scanner_cache_valid; then
        sc_info "使用扫描缓存（$(scanner_cache_age_h) 小时前，$(scanner_cache_count) 个候选；--refresh 可强制重扫）"
        if best="$(scanner_shortlist "$require_tfo")"; then
            printf '%s\n' "$best"
            return 0
        fi
        # require-tfo 过滤为空 ≠ 缓存失效。同一个 /24 的站点集合是稳定的，
        # 重扫一遍大概率还是这几个、还是都不支持，只会把同样的 [ok] 行再打
        # 一次（早期版本就是这么误导人的）。直接失败并给出可选路径。
        if (( require_tfo == 1 )); then
            err "缓存候选都不支持被动 TFO（逐个结果见上面每行的 TFO 标记）" >&2
            err "可去掉 --require-tfo 按质量选，或 xhy scan --cidr <其它网段> --require-tfo 换网段；确要重扫加 --refresh" >&2
            return 1
        fi
        warn "缓存里的候选都已失效，重新扫描"
    fi

    if [[ -z "$cidr" ]]; then
        if ! cidr="$(scanner_default_cidr)"; then
            err "无法确定本机公网网段，请显式指定: xhy scan 1.2.3.0/24" >&2
            return 1
        fi
    fi

    if ! scanner_scan "$cidr"; then
        case "$cidr" in
            */24)
                wide="$(cidr_truncate "${cidr%%/*}" 21)" || wide=""
                if [[ -n "$wide" ]]; then
                    warn "$cidr 无合格候选，扩大到同机房 $wide 再试一次"
                    scanner_scan "$wide" || return 1
                else
                    return 1
                fi ;;
            *) return 1 ;;
        esac
    fi

    if best="$(scanner_shortlist "$require_tfo")"; then
        printf '%s\n' "$best"
        return 0
    fi
    if (( require_tfo == 1 )); then
        err "扫描完成，但新扫出的候选都不支持被动 TFO（xhy scan --list 可看每个站点的 TFO 标记）" >&2
        err "可去掉 --require-tfo 按质量选，或换 --cidr 网段再试" >&2
    else
        err "扫描完成但没有可用站点（xhy scan --list 查看候选与失败原因）" >&2
    fi
    return 1
}
