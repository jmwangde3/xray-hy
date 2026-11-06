#!/usr/bin/env bash
# xray-hy / vless:// share-link generation (VLESS share-link standard).

_link_host() {
    local h="$1"
    if [[ "$h" == *:* && "$h" != \[* ]]; then printf '[%s]' "$h"; else printf '%s' "$h"; fi
}

link_uri() {
    local envf="$1" host="" q="" name=""
    node_load "$envf"
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
    local envf="$1" uri
    node_load "$envf"
    uri="$(link_uri "$envf")"
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
    printf '  %s\n' "注意：完整链接等同于访问凭证，请勿公开分享。"
}

link_all() {
    local f n=0
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        n=$((n + 1))
        link_from_env "$f"
    done
    (( n > 0 )) || warn "暂无节点，先用 xhy add 添加一个。"
}

link_qr() {
    local envf="$1" uri
    ensure_optional qrencode
    have_cmd qrencode || die "未安装 qrencode，无法生成二维码。"
    uri="$(link_uri "$envf")"
    qrencode -t ANSIUTF8 "$uri"
}
