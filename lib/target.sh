#!/usr/bin/env bash
# xray-hy / REALITY camouflage site selection and live validation.

TARGETS_FILE="${XHY_SCRIPT_DIR:-$XHY_HOME}/conf/targets.tsv"

# 单文件发布没有 conf/ 目录：数据内嵌在脚本里，首次用到时落盘。
# 落盘的好处是管理员仍可直接编辑该文件增删候选，行为与仓库内一致。
targets_ensure() {
    [[ -s "$TARGETS_FILE" ]] && return 0
    mkdir -p "$(dirname "$TARGETS_FILE")" 2>/dev/null || return 1
    targets_tsv >"$TARGETS_FILE" || return 1
    chmod 0644 "$TARGETS_FILE" 2>/dev/null || true
}

# 仓库内运行时的占位实现；build.sh 会用 conf/targets.tsv 的内嵌副本覆盖它。
targets_tsv() {
    die "缺少伪装站数据文件 $TARGETS_FILE（仓库内请保留 conf/targets.tsv）"
}

target_rows() {
    targets_ensure || die "找不到伪装站数据文件: $TARGETS_FILE"
    [[ -r "$TARGETS_FILE" ]] || die "找不到伪装站数据文件: $TARGETS_FILE"
    # Strip any UTF-8 BOM *before* filtering: a BOM keeps the leading "#" from
    # matching the comment filter, and the header line would then be listed as a
    # region by `xhy target` and parsed as a data row.
    tr -d '\357\273\277' <"$TARGETS_FILE" | grep -vE '^[[:space:]]*(#|$)' || true
}

target_list_regions() {
    target_rows | cut -d'|' -f1 | sort -u | tr '\n' ' '
}

# 是不是 IPv4 字面量。用于区分「dest 写源站 IP」和「dest 写域名」。
# 只认 v4：v6 目标在 REALITY 里罕见，且 "2001:db8::1:443" 的端口切分会误判，
# 与其悄悄给出错误结果，不如明确不支持。
is_ip_literal() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

# 概念说明：target/dest、SNI、serverNames 三个词最容易被混用。
target_help() {
    xhy_t <<'EOF'
  ---- REALITY 名词（这几个词经常被混着说）----
  target / dest  服务端主动去连的「目的地址」，形如 IP:端口 或 域名:端口。
                 REALITY 把未通过认证的探测流量原样转发过去，所以它必须是一个
                 真实存在、长期稳定的 HTTPS 站点 —— 这就是「伪装站」。
  SNI            客户端 TLS 握手时明文声明的域名（ClientHello.server_name）。
                 服务端按 SNI 选证书；REALITY 也拿它判断「像不像正常访问」。
  serverNames    Xray 配置字段，= 允许的 SNI 白名单，一般写一个域名。
                 它必须被 target 的证书覆盖，否则回落握手证书对不上，一眼假。

  ---- 为什么有时要「IP 和域名分开填」----
  站点挂 CDN 时，域名解析到的是 CDN 边缘 IP。此时 dest 若也写域名，REALITY
  就是在替 CDN 做转发，特征不像源站。正确做法：dest 写源站 IP、SNI 仍写域名，
  握手特征与真实站点一致。例：
      target=47.88.102.65:443   SNI=www.easeus.com
  校验会带 --resolve 打这个 IP，验证证书确实覆盖该域名、且没有 CDN 头。

  ---- TFO 与伪装站 ----
  TFO（TCP Fast Open）是 TCP 层的 0-RTT 特性。Xray 的 tcpFastOpen 实测确实
  生效，但我们只在伪装站也支持时才开（xhy add reality 默认 --tfo auto）：
  目标不支持却开，探测者发一个带 cookiereq 的 SYN 就会看到我们回了
  tfo cookie、真实站点没回，一眼可区分。--tfo on / off 可强制覆盖。
  伪装站不承载正常代理流量，它的带宽和延迟不影响代理上网速度，所以 scan
  不把 TFO 纳入打分 —— 先按质量选最优站，再读它的能力。
  scan 的每个候选后面都会标注「TFO 支持 / 不支持」；--require-tfo 只留支持的，
  探测不了或明确不支持都按「不支持」显示（决策上一律关，不做模糊态）。
  --require-tfo 在 /24（或缓存）里没找到时，会自动扩到同机房 /21 再扫一次；
  扩的是不同网段，不会把同一个 /24 白扫两遍。
EOF
}

# Verify a candidate really speaks TLS 1.3 + HTTP/2, does not redirect and is
# not sitting behind a CDN. Xray itself warns that a CDN-fronted target turns
# the node into an open port forwarder.
#
# $1 = target（IP 或域名，可带 :port），$2 = SNI（可省，省则等于 target 的域名部分）。
# target 是 IP 时必须给 SNI：校验会用 --resolve 把 SNI 域名钉到该 IP 上，
# 测的就是「真实回落到这台源站」的效果，而不是公共 DNS 解析出的 CDN 边缘。
# $3 = 可选的 TFO 标记（如「支持」/「不支持」），由扫描模块现场探测后传入，
#      追加在 [ok] 校验行末尾，让每个候选后面都能看到它是否支持被动 TFO。
#      其它调用方（xhy target 手动校验 / pick_target）不传，输出保持原样。
target_validate() {
    local host="$1" sni="${2:-}" tfo_tag="${3:-}" tls_out="" hdr="" rc=0 probe="" use_openssl=0
    [[ -n "$host" ]] || return 1
    host="${host%%:*}"

    if is_ip_literal "$host"; then
        if [[ -z "$sni" ]]; then
            warn "  $host : target 是 IP，必须同时指定 SNI 域名（否则回落到该 IP 时证书对不上）"
            return 1
        fi
        probe="$sni"; use_openssl=1
    else
        probe="${sni:-$host}"
        if [[ "$probe" != "$host" ]]; then use_openssl=1; fi
    fi

    if [[ -x "$XRAY_BIN" ]] && (( use_openssl == 0 )); then
        if XRAY_LOCATION_ASSET="$XRAY_ASSET" \
                "$XRAY_BIN" tls ping "${host}:443" >/tmp/xhy-tlsping.$$ 2>&1; then
            tls_out="$(cat /tmp/xhy-tlsping.$$)"
        fi
    else
        tls_out="$(printf 'Q' | openssl s_client -connect "${host}:443" \
            -servername "$probe" -tls1_3 2>/dev/null \
            | grep -iE 'Protocol|Cipher' | head -5 || true)"
    fi
    rm -f "/tmp/xhy-tlsping.$$"

    if [[ -n "$tls_out" ]] && ! grep -qiE 'TLS ?v?1\.3|TLS_AES|TLS_CHACHA' <<<"$tls_out"; then
        warn "  $probe : 未确认 TLS 1.3"; rc=1
    fi

    if (( use_openssl == 1 )) && is_ip_literal "$host"; then
        hdr="$(curl -sS -I --http2 -m 12 --resolve "${probe}:443:${host}" \
            "https://${probe}/" 2>/dev/null | tr -d '\r' || true)"
    else
        hdr="$(curl -sS -I --http2 -m 12 "https://${probe}/" 2>/dev/null | tr -d '\r' || true)"
    fi
    if [[ -z "$hdr" ]]; then
        if is_ip_literal "$host"; then
            warn "  ${probe} @ ${host} : 无法建立 HTTPS 连接（该 IP 的证书不覆盖此 SNI，或源站不服务该域名）"
        else
            warn "  ${probe} : 无法建立 HTTPS 连接"
        fi
        return 1
    fi
    grep -qiE '^HTTP/2( |$)' <<<"$hdr" || { warn "  ${probe} : 不支持 HTTP/2"; rc=1; }
    if grep -qiE '^location:' <<<"$hdr"; then
        warn "  ${probe} : 会重定向，不适合作为 target"; rc=1
    fi
    if grep -qiE '^(cf-ray|cf-cache-status|x-cache|via):|^server:[[:space:]]*cloudflare' <<<"$hdr"; then
        warn "  ${probe} : 位于 CDN 之后，不推荐作为 REALITY target"; rc=1
    fi
    if (( rc == 0 )); then
        local suffix=""
        if [[ -n "$tfo_tag" ]]; then suffix=" / TFO ${tfo_tag}"; fi
        if is_ip_literal "$host"; then
            ok "  ${probe} @ ${host} : TLS 1.3 / H2 / 无跳转 / 非 CDN（源站直连）${suffix}"
        else
            ok "  ${probe} : TLS 1.3 / H2 / 无跳转 / 非 CDN${suffix}"
        fi
    fi
    return "$rc"
}

target_region() { state_get TARGET_REGION "auto"; }

# Echo "<target> <sni> <label>". Resolution order:
#   1) explicit custom target from state
#   2) best entry of a still-valid scan cache (same datacenter, already verified)
#   3) region chosen by the admin
#   4) auto: match the VPS egress country code
pick_target() {
    local region candidate="" cc="" line r c label tgt sni
    local custom_t custom_s sbest
    custom_t="$(state_get TARGET_CUSTOM '')"
    custom_s="$(state_get TARGET_SNI '')"
    if [[ -n "$custom_t" ]]; then
        printf '%s %s %s\n' "$custom_t" "${custom_s:-${custom_t%%:*}}" "custom"
        return 0
    fi

    # 扫描缓存优先：同机房的真实源站比全球静态表更贴合，而且已经验过一次。
    # XHY_SKIP_SCAN_CACHE=1 可绕过（排查问题时用）。
    if [[ "${XHY_SKIP_SCAN_CACHE:-0}" != "1" ]] && declare -F scanner_cache_valid >/dev/null; then
        if scanner_cache_valid; then
            if sbest="$(scanner_cache_pick_valid)"; then
                printf '%s\n' "$sbest"
                return 0
            fi
            warn "扫描缓存中的候选当前都不可用，回退到内置地区库" >&2
        fi
    fi

    region="$(target_region)"
    if [[ "$region" == "auto" ]]; then
        cc="$(public_country)"
        # All diagnostics MUST go to stderr: stdout is the machine-readable
        # "<target> <sni> <label>" triple consumed by the caller.
        info "VPS 出口国家: ${cc:-未知}，按地区匹配伪装站" >&2
        line="$(target_rows | awk -F'|' -v c="${cc:-__}" 'tolower($2)==tolower(c) {print; exit}')"
        region="$(printf '%s' "$line" | cut -d'|' -f1)"
        [[ -z "$region" ]] && region="other"
    fi

    # Two passes: the region's own candidates first, then the generic
    # auto/other fallbacks. A single pass let the `auto` row (line 1 of the
    # table) win over every region-specific entry, because it is validated
    # first and the loop returns on the first success.
    local pass found=""
    for pass in 1 2; do
        while IFS='|' read -r r c label tgt sni; do
            [[ -z "$tgt" ]] && continue
            if (( pass == 1 )); then
                [[ "$r" == "$region" ]] || continue
            else
                [[ "$r" == "auto" || "$r" == "other" ]] || continue
            fi
            if target_validate "$tgt" "${sni:-${tgt%%:*}}" >&2; then
                found="$tgt|${sni:-${tgt%%:*}}|$label"
                break
            fi
            [[ -z "$candidate" ]] && candidate="$tgt|${sni:-${tgt%%:*}}|$label"
        done < <(target_rows)
        [[ -n "$found" ]] && break
    done

    if [[ -n "$found" ]]; then
        printf '%s\n' "${found//|/ }"
        return 0
    fi
    if [[ -n "$candidate" ]]; then
        warn "该地区候选均未通过完整校验，回退使用第一个（请自行确认可用性）" >&2
        printf '%s\n' "${candidate//|/ }"
        return 0
    fi
    die "没有可用的伪装站候选，请用 xhy target custom <域名> 手动指定。"
}

target_show() {
    local t s cache
    t="$(state_get TARGET_CUSTOM '')"
    s="$(state_get TARGET_SNI '')"
    printf '地区     : %s (可选: %s)\n' "$(target_region)" "$(target_list_regions)"
    if [[ -n "$t" ]]; then
        printf '自定义   : %s  SNI=%s\n' "$t" "${s:-${t%%:*}}"
    else
        printf '自定义   : 未设置（使用地区自动匹配）\n'
    fi
    if declare -F scanner_cache_count >/dev/null && [[ -s "$SCANNER_CACHE" ]]; then
        cache="$(scanner_cache_count) 个候选 / $(scanner_cache_age_h) 小时前"
        if scanner_cache_valid; then
            printf '扫描缓存 : %s（有效，建节点时优先采用）\n' "$cache"
        else
            printf '扫描缓存 : %s（已过期，选项 8 可查看/清除）\n' "$cache"
        fi
    else
        printf '扫描缓存 : 无（选项 7 自动扫描本机机房网段）\n'
    fi
}

# 「指定地区」不该让人背地区代码：列出序号 / 地区 / 国家 / 候选数 / 首个候选。
target_region_table() {
    target_rows | awk -F'|' '
        NF >= 4 && $1 != "" {
            n[$1]++
            if (!($1 in first)) { first[$1] = $4; cc[$1] = $2 }
        }
        END { for (r in n) printf "%s|%s|%d|%s\n", r, cc[r], n[r], first[r] }
    ' | sort
}

# 扫描 → 选出候选 → 可选固定为默认 target → 可选套用到已有 REALITY 节点。
# require_tfo=1 时，若 /24 与同机房 /21 都没有支持被动 TFO 的站点，问一次
# 是否改成不强制重选：支持被动 TFO 的站本来就少，把「扫不到」变成一次选择，
# 而不是让用户回到菜单再猜该去掉哪个开关。
target_scan_flow() {
    local require="${1:-0}" refresh="${2:-0}"
    local -a args=() plain=()
    local sp st ss a
    (( refresh == 1 )) && args+=(--refresh)
    (( require == 1 )) && args+=(--require-tfo)

    if sp="$(scanner_pick ${args[@]+"${args[@]}"})"; then
        read -r st ss _ <<<"$sp"
        ok "最优站点: target=$st SNI=$ss"
        if confirm "固定为当前 target（新建节点直接使用）？" "y"; then
            state_set TARGET_CUSTOM "$st"; state_set TARGET_SNI "$ss"
            ok "已固定 target=$st SNI=$ss"
        fi
        node_retarget_menu "$st" "$ss"
        return 0
    fi

    if (( require == 1 )); then
        warn "本机网段（/24 与同机房 /21）都没有支持被动 TFO 的站点。"
        info "TFO 只省首连 1 个 RTT，伪装站又不承载正常代理流量，不值得为它牺牲站点质量。"
        if confirm "改为不强制 TFO、按质量重选？" "y"; then
            for a in "${args[@]}"; do
                [[ "$a" == "--require-tfo" ]] || plain+=("$a")
            done
            if sp="$(scanner_pick ${plain[@]+"${plain[@]}"})"; then
                read -r st ss _ <<<"$sp"
                ok "最优站点: target=$st SNI=$ss"
                if confirm "固定为当前 target（新建节点直接使用）？" "y"; then
                    state_set TARGET_CUSTOM "$st"; state_set TARGET_SNI "$ss"
                    ok "已固定 target=$st SNI=$ss"
                fi
                node_retarget_menu "$st" "$ss"
                return 0
            fi
        fi
    fi
    warn "自动扫描没有找到可用站点，可改用 1) 按地区，或 3) 手动指定"
    return 1
}

target_menu() {
    while true; do
        printf '\n'
        target_show
        xhy_t <<'EOF'
  1) 按地区自动匹配（按 VPS 出口国家）
  2) 指定地区（列出现有地区与候选数）
  3) 手动指定 target / SNI
  4) 清除自定义设置
  5) 校验指定域名或 IP+SNI
  6) 名词说明（target / dest / SNI / serverNames）
  7) 扫描本机机房网段挑站（可强制 TFO，可替换已有节点）
  8) 查看 / 复核 / 清除扫描缓存
  0) 返回
EOF
        case "$(ask '选择' '0')" in
            1) state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION auto
               info "已设为自动匹配"
               if picked="$(pick_target)"; then
                   read -r pt ps pl <<<"$picked"
                   ok "当前 target: $pt SNI=$ps（来源 $pl）"
               fi ;;
            2) local -a regs=()
               local line idx=0 sel r c n t picked pt ps pl
               mapfile -t regs < <(target_region_table)
               if (( ${#regs[@]} == 0 )); then
                   err "伪装站数据文件里没有候选：$TARGETS_FILE"
                   continue
               fi
               printf '\n  %-3s %-8s %-6s %-6s %s\n' "#" "地区" "国家" "候选" "首个候选"
               printf '  %s\n' "----------------------------------------------------------------------"
               for line in "${regs[@]}"; do
                   idx=$((idx + 1))
                   IFS='|' read -r r c n t <<<"$line"
                   printf '  %-3s %-8s %-6s %-6s %s\n' "$idx" "$r" "${c:--}" "$n" "${t:--}"
               done
               printf '\n'
               sel="$(ask '选择地区编号（也可直接输入地区代码，回车取消）' '')"
               [[ -n "$sel" ]] || continue
               if [[ "$sel" =~ ^[0-9]+$ ]]; then
                   if (( sel < 1 || sel > ${#regs[@]} )); then
                       err "编号超出范围（1-${#regs[@]}）"; continue
                   fi
                   IFS='|' read -r r c n t <<<"${regs[$((sel - 1))]}"
               else
                   line="$(target_region_table | grep -m1 -F "${sel}|" || true)"
                   if [[ -z "$line" ]]; then
                       err "没有这个地区：$sel（可用：$(target_list_regions)）"; continue
                   fi
                   IFS='|' read -r r c n t <<<"$line"
               fi
               state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION "$r"
               ok "地区已设为 $r（国家 ${c:--}，$n 个候选）"
               if picked="$(pick_target)"; then
                   read -r pt ps pl <<<"$picked"
                   ok "当前 target: $pt SNI=$ps（来源 $pl）"
                   if confirm "固定下来（新建节点直接用）？" "y"; then
                       state_set TARGET_CUSTOM "$pt"; state_set TARGET_SNI "$ps"
                       ok "已固定 target=$pt SNI=$ps"
                   fi
               fi ;;
            3) local h s
               xhy_t <<'EOF'
  输入格式（三种都行）：
    www.example.com                     域名，dest 与 SNI 相同
    1.2.3.4:443,sni=www.example.com     源站 IP + 域名 SNI（目标在 CDN 后时用这个）
    www.example.com:8443                非 443 端口
EOF
               h="$(ask 'target（输入 6 可看详细说明）')"
               [[ -n "$h" ]] || continue
               s="${h#*,sni=}"; [[ "$s" == "$h" ]] && s=""
               h="${h%%,*}"
               [[ "$h" == *:* ]] || h="${h}:443"
               if is_ip_literal "${h%%:*}" && [[ -z "$s" ]]; then
                   err "target 是 IP 时必须加 ,sni=域名（dest 用 IP、SNI 用域名，两者不能省）"
                   continue
               fi
               s="${s:-${h%%:*}}"
               target_validate "$h" "$s" || confirm '校验未完全通过，仍要使用？' 'n' || continue
               state_set TARGET_CUSTOM "$h"; state_set TARGET_SNI "$s"
               ok "已固定 target=$h SNI=$s"
               node_retarget_menu "$h" "$s" ;;
            4) state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION auto; ok "已清除" ;;
            5) local v vs
               xhy_t <<'EOF'
  格式同选项 3：域名 / 域名:端口 / IP:端口,sni=域名
EOF
               v="$(ask '要校验的 target')"
               [[ -n "$v" ]] || continue
               vs="${v#*,sni=}"; [[ "$vs" == "$v" ]] && vs=""
               v="${v%%,*}"
               [[ "$v" == *:* ]] || v="${v}:443"
               if is_ip_literal "${v%%:*}" && [[ -z "$vs" ]]; then
                   err "校验 IP 时必须给 ,sni=域名"; continue
               fi
               vs="${vs:-${v%%:*}}"
               target_validate "$v" "$vs" && ok "校验通过" || warn "校验未完全通过（见上面每条原因）" ;;
            6) target_help; ask '按回车继续' '' ;;
            7) local req=0 ref=0
               if [[ -s "$SCANNER_CACHE" ]] && scanner_cache_valid; then
                   if confirm "已有 $(scanner_cache_age_h) 小时前的扫描缓存，重新扫描？" "n"; then
                       ref=1
                   fi
               fi
               if confirm "是否只选支持 TFO 的伪装站？（不强制则按质量选）" "n"; then
                   req=1
               fi
               target_scan_flow "$req" "$ref" ;;
            8) local ca
               ca="$(ask 'list 查看 / verify 复核 / clear 清除' 'list')"
               case "$ca" in
                   list)   scanner_cache_show ;;
                   verify) scanner_cache_verify ;;
                   clear)  scanner_cache_clear ;;
                   *)      scanner_cache_show ;;
               esac ;;
            0) return 0 ;;
        esac
    done
}

limit_fallback_json() {
    # Mitigation for the upstream REALITY warning: unauthenticated traffic is
    # forwarded to the target. Rate-limit that fallback path.
    # 这是配置片段，不是给人看的文本：保持 cat，别走语言过滤器。
    cat <<'EOF'
        "limitFallbackUpload":   { "afterBytes": 0, "bytesPerSec": 65536, "burstBytesPerSec": 131072 },
        "limitFallbackDownload": { "afterBytes": 0, "bytesPerSec": 65536, "burstBytesPerSec": 131072 },
EOF
}
