#!/usr/bin/env bash
# xray-hy / vless:// share-link generation (VLESS share-link standard).

# 由 cmd_link 按 --qr / --png 设置；link_from_env 在链接下方追加二维码。
LINK_QR="${LINK_QR:-0}"
LINK_QR_OUT="${LINK_QR_OUT:-}"
LINK_QR_MULTI="${LINK_QR_MULTI:-0}"

_link_host() {
    local h="$1"
    if [[ "$h" == *:* && "$h" != \[* ]]; then printf '[%s]' "$h"; else printf '%s' "$h"; fi
}

# 节点 env 一定有 MODE= 行；同目录的 relay.env 是中继状态文件（无 MODE），
# 不是节点。旧版 link_all 把 *.env 全遍历，遇到 relay.env 会让 link_uri 报
# 「未知模式」并把 xhy link --qr 整个退出码带成 1（落地机必现）。
link_node_files() {
    local f
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        grep -q '^MODE=' "$f" 2>/dev/null || continue
        printf '%s\n' "$f"
    done
}

link_uri() {
    local envf="$1" host_ov="${2:-}" host="" q="" name=""
    node_load "$envf"
    # host_ov：生成 IPv6 变体链接时覆盖连接地址（不影响 vless ws 的 Host 头，
    # 那个必须保持真实域名/源地址，否则回源或伪装会错）。
    [[ -n "$host_ov" ]] && NODE_HOST="$host_ov"
    name="xray-hy-${MODE}-${PORT}"
    case "$MODE" in
        direct)
            host="$(_link_host "$NODE_HOST")"
            q="encryption=none&security=none&type=ws&host=$(url_encode "$NODE_HOST")&path=$(url_encode "$NODE_PATH")"
            printf 'vless://%s@%s:%s?%s#%s\n' "$UUID" "$host" "$PORT" "$q" "$name" ;;
        tunnel)
            host="$(_link_host "$CF_DOMAIN")"
            q="encryption=none&security=tls&type=ws&host=$(url_encode "$CF_DOMAIN")&path=$(url_encode "$NODE_PATH")&sni=$(url_encode "$CF_DOMAIN")&fp=chrome"
            printf 'vless://%s@%s:443?%s#%s\n' "$UUID" "$host" "$q" "$name" ;;
        reality)
            host="$(_link_host "$NODE_HOST")"
            q="encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(url_encode "$SNI")&fp=chrome&pbk=$(url_encode "$PUBLIC_KEY")&sid=$(url_encode "$SHORT_ID")&type=tcp"
            printf 'vless://%s@%s:%s?%s#%s\n' "$UUID" "$host" "$PORT" "$q" "$name" ;;
        xhttp)
            host="$(_link_host "$NODE_HOST")"
            q="encryption=none&type=xhttp&path=$(url_encode "$NODE_PATH")&host=$(url_encode "$NODE_HOST")&mode=auto"
            if [[ "${SECURITY:-none}" == "reality" ]]; then
                q="encryption=none&security=reality&type=xhttp&path=$(url_encode "$NODE_PATH")&host=$(url_encode "$NODE_HOST")&mode=auto&sni=$(url_encode "$SNI")&fp=chrome&pbk=$(url_encode "$PUBLIC_KEY")&sid=$(url_encode "$SHORT_ID")"
            fi
            printf 'vless://%s@%s:%s?%s#%s\n' "$UUID" "$host" "$PORT" "$q" "$name" ;;
        hy2)
            host="$(_link_host "$NODE_HOST")"
            # Self-signed cert: pin its SHA-256 instead of insecure=1.
            q="pinSHA256=$(url_encode "$PIN_B64")&sni=$(url_encode "$SNI")"
            printf 'hysteria2://%s@%s:%s?%s#%s\n' \
                "$(url_encode "$AUTH")" "$host" "$PORT" "$q" "$name" ;;
        *) err "未知模式: $MODE"; return 1 ;;
    esac
}

link_from_env() {
    local envf="$1" uri uri6=""
    node_load "$envf"
    uri="$(link_uri "$envf")"
    # IPv6 变体：仅当节点地址是 IPv4 字面量、服务器有 v6 出口、且节点确实
    # 双栈监听（DUAL_STACK=on -> bind ::）时才有意义；域名本身有 AAAA 的话
    # 同一条链接就覆盖双栈，不需要变体。
    if [[ "${NODE_HOST:-}" =~ ^[0-9.]+$ ]] && [[ "$(state_get DUAL_STACK off)" == "on" ]]; then
        local _ip6
        _ip6="$(public_ip6 || true)"
        if [[ -n "$_ip6" && "$_ip6" != "$NODE_HOST" ]]; then
            uri6="$(link_uri "$envf" "$_ip6" || true)"
        fi
    fi
    printf '\n'
    printf '  节点     : %s_%s\n' "$MODE" "$PORT"
    printf '  地址     : %s\n' "${NODE_HOST:-$CF_DOMAIN}"
    printf '  端口     : %s\n' "$PORT"
    printf '  UUID     : %s\n' "$UUID"
    [[ -n "${NODE_PATH:-}" ]] && printf '  路径     : %s\n' "$NODE_PATH"
    [[ -n "${SNI:-}" ]]       && printf '  SNI      : %s\n' "$SNI"
    [[ -n "${TARGET:-}" ]]    && printf '  Target   : %s\n' "$TARGET"
    [[ -n "${PUBLIC_KEY:-}" ]] && printf '  公钥 pbk : %s\n' "$PUBLIC_KEY"
    [[ -n "${SHORT_ID:-}" ]]  && printf '  shortId  : %s\n' "$SHORT_ID"
    if [[ "$MODE" == "hy2" ]]; then
        printf '  传输     : UDP / QUIC (Hysteria2, Xray 内置入站)\n'
        printf '  伪装站   : %s\n' "$MASQ_URL"
        printf '  证书     : %s\n' "$CERT_FILE"
        printf '  指纹 SHA256: %s\n' "$PIN_HEX"
        printf '  简易链接（跳过证书校验，不推荐）: hysteria2://%s@%s:%s?insecure=1&sni=%s#xray-hy-hy2-%s\n' \
            "$AUTH" "$(_link_host "$NODE_HOST")" "$PORT" "$SNI" "$PORT"
    fi
    printf '\n  %s\n\n' "$uri"
    [[ -n "$uri6" ]] && printf '  IPv6 变体: %s\n\n' "$uri6"
    if (( LINK_QR == 1 )); then
        printf '\n'
        link_qr "$envf" "$LINK_QR_OUT"
    fi
    printf '  %s\n' "注意：完整链接等同于访问凭证，请勿公开分享。"
}

link_all() {
    local f n=0
    while IFS= read -r f; do
        n=$((n + 1))
        link_from_env "$f"
    done < <(link_node_files)
    (( n > 0 )) || warn "暂无节点，先用 xhy add 添加一个。"
}

# 生成二维码：终端里直接给手机扫，或 --png 存成 0600 图片文件再传到手机。
# 二维码内容就是完整的 vless:// / hysteria2:// 链接（含凭证），所以 PNG 必须 0600。
link_qr() {
    local envf="$1" out="${2:-}" uri t fname base
    ensure_optional qrencode
    have_cmd qrencode || die "未安装 qrencode，无法生成二维码（Alpine: apk add --no-cache -X <community-mirror> libqrencode-tools）"
    uri="$(link_uri "$envf")"
    if [[ -n "$out" ]]; then
        fname="$out"
        # 多节点 + --png：按 MODE_PORT 加后缀，避免互相覆盖。
        if (( LINK_QR_MULTI == 1 )); then
            base="${out%.png}"
            [[ "$out" == *.png ]] || base="$out"
            fname="${base}-${MODE:-node}_${PORT:-0}.png"
        fi
        qrencode -t PNG -o "$fname" "$uri" || { err "二维码生成失败: $fname"; return 1; }
        chmod 600 "$fname"
        ok "二维码已写入 $fname（0600，含凭证，勿公开）"
        return 0
    fi
    # 控制台 / 英文模式用 ANSI：纯 ASCII 字节 + 颜色，不依赖 UTF-8 半块字形；
    # 普通 UTF-8 终端用 ANSIUTF8：1 字符/模块，扫起来最清楚。
    t="ANSIUTF8"
    case "${TERM:-}" in linux|vt100|vt102|ansi|cons25|sun) t="ANSI" ;; esac
    [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]] && t="ANSI"
    printf '  二维码（手机 App 扫码导入）：\n'
    qrencode -t "$t" "$uri"
}
