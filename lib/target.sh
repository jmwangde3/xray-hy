#!/usr/bin/env bash
# xray-hy / REALITY camouflage site selection and live validation.

TARGETS_FILE="${XHY_SCRIPT_DIR:-$XHY_HOME}/conf/targets.tsv"

target_rows() {
    [[ -r "$TARGETS_FILE" ]] || die "找不到伪装站数据文件: $TARGETS_FILE"
    # Strip any UTF-8 BOM *before* filtering: a BOM keeps the leading "#" from
    # matching the comment filter, and the header line would then be listed as a
    # region by `xhy target` and parsed as a data row.
    tr -d '\357\273\277' <"$TARGETS_FILE" | grep -vE '^[[:space:]]*(#|$)'
}

target_list_regions() {
    target_rows | cut -d'|' -f1 | sort -u | tr '\n' ' '
}

# Verify a candidate really speaks TLS 1.3 + HTTP/2, does not redirect and is
# not sitting behind a CDN. Xray itself warns that a CDN-fronted target turns
# the node into an open port forwarder.
target_validate() {
    local host="$1" tls_out="" hdr="" rc=0
    [[ -n "$host" ]] || return 1
    host="${host%%:*}"

    if [[ -x "$XRAY_BIN" ]] && XRAY_LOCATION_ASSET="$XRAY_ASSET" \
            "$XRAY_BIN" tls ping "${host}:443" >/tmp/xhy-tlsping.$$ 2>&1; then
        tls_out="$(cat /tmp/xhy-tlsping.$$)"
    else
        tls_out="$(printf 'Q' | openssl s_client -connect "${host}:443" \
            -servername "$host" -tls1_3 2>/dev/null | grep -iE 'Protocol|Cipher' | head -5)"
    fi
    rm -f "/tmp/xhy-tlsping.$$"

    if [[ -n "$tls_out" ]] && ! grep -qiE 'TLS ?v?1\.3|TLS_AES|TLS_CHACHA' <<<"$tls_out"; then
        warn "  $host : 未确认 TLS 1.3"; rc=1
    fi

    hdr="$(curl -sS -I --http2 -m 12 "https://${host}/" 2>/dev/null | tr -d '\r')"
    if [[ -z "$hdr" ]]; then
        warn "  $host : 无法建立 HTTPS 连接"; return 1
    fi
    grep -qiE '^HTTP/2( |$)' <<<"$hdr" || { warn "  $host : 不支持 HTTP/2"; rc=1; }
    if grep -qiE '^location:' <<<"$hdr"; then
        warn "  $host : 会重定向，不适合作为 target"; rc=1
    fi
    if grep -qiE '^(cf-ray|cf-cache-status|x-cache|via):|^server:[[:space:]]*cloudflare' <<<"$hdr"; then
        warn "  $host : 位于 CDN 之后，不推荐作为 REALITY target"; rc=1
    fi
    (( rc == 0 )) && ok "  $host : TLS 1.3 / H2 / 无跳转 / 非 CDN"
    return "$rc"
}

target_region() { state_get TARGET_REGION "auto"; }

# Echo "<target> <sni> <label>". Resolution order:
#   1) explicit custom target from state
#   2) region chosen by the admin
#   3) auto: match the VPS egress country code
pick_target() {
    local region candidate="" cc="" line r c label tgt sni
    local custom_t custom_s
    custom_t="$(state_get TARGET_CUSTOM '')"
    custom_s="$(state_get TARGET_SNI '')"
    if [[ -n "$custom_t" ]]; then
        printf '%s %s %s\n' "$custom_t" "${custom_s:-${custom_t%%:*}}" "custom"
        return 0
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
            if target_validate "$tgt" >&2; then
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
    local t s
    t="$(state_get TARGET_CUSTOM '')"
    s="$(state_get TARGET_SNI '')"
    printf '地区     : %s (可选: %s)\n' "$(target_region)" "$(target_list_regions)"
    if [[ -n "$t" ]]; then
        printf '自定义   : %s  SNI=%s\n' "$t" "${s:-${t%%:*}}"
    else
        printf '自定义   : 未设置（使用地区自动匹配）\n'
    fi
}

target_menu() {
    while true; do
        printf '\n'
        target_show
        cat <<'EOF'
  1) 按地区自动匹配（按 VPS 出口国家）
  2) 指定地区
  3) 手动指定 target / SNI
  4) 清除自定义设置
  5) 校验指定域名
  0) 返回
EOF
        case "$(ask '选择' '0')" in
            1) state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION auto
               info "已设为自动匹配"; pick_target ;;
            2) local r; r="$(ask '地区代码' "$(target_region)")"
               target_rows | grep -q "^${r}|" || { warn "可用地区: $(target_list_regions)"; continue; }
               state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION "$r"; pick_target ;;
            3) local h s; h="$(ask 'target 域名(可带 :443)')"
               [[ -n "$h" ]] || continue
               [[ "$h" == *:* ]] || h="${h}:443"
               s="$(ask 'SNI' "${h%%:*}")"
               target_validate "$h" || confirm '校验未完全通过，仍要使用？' 'n' || continue
               state_set TARGET_CUSTOM "$h"; state_set TARGET_SNI "$s"
               ok "已固定 target=$h SNI=$s" ;;
            4) state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION auto; ok "已清除" ;;
            5) local v; v="$(ask '要校验的域名')"; [[ -n "$v" ]] && target_validate "$v" ;;
            0) return 0 ;;
        esac
    done
}

limit_fallback_json() {
    # Mitigation for the upstream REALITY warning: unauthenticated traffic is
    # forwarded to the target. Rate-limit that fallback path.
    cat <<'EOF'
        "limitFallbackUpload":   { "afterBytes": 0, "bytesPerSec": 65536, "burstBytesPerSec": 131072 },
        "limitFallbackDownload": { "afterBytes": 0, "bytesPerSec": 65536, "burstBytesPerSec": 131072 },
EOF
}
