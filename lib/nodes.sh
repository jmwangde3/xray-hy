#!/usr/bin/env bash
# xray-hy / node registry, inbound rendering and full-config rebuild.
# Design: one .env per node (credentials) + one JSON fragment per node
# (a single inbound object). `rebuild_config` merges fragments into a single
# config.json so `xray run -test -c` can validate the whole thing atomically.

node_file()   { printf '%s/%s_%s.env' "$XHY_NODES" "$1" "$2"; }
node_frag()   { printf '%s/%s_%s.json' "$XHY_CONFDIR" "$1" "$2"; }
node_exists() { [[ -f "$(node_file "$1" "$2")" ]]; }
node_count()  { find "$XHY_NODES" -maxdepth 1 -name '*.env' -type f 2>/dev/null | wc -l; }

# A port must be unique across ALL modes, not just within one mode.
port_used_by_node() {
    local p="$1" f v
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        v="$(grep -m1 '^PORT=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        if [[ "$v" == "$p" ]]; then basename "$f" .env; return 0; fi
    done
    return 1
}

# "::" listens on both v4 and v6 (when bindv6only=0). Opt-in because some VPS
# ship with IPv6 disabled, where "::" would fail to bind at all.
listen_addr() {
    if [[ "$(state_get DUAL_STACK off)" == "on" ]]; then printf '::'; else printf '0.0.0.0'; fi
}

node_load() {
    local f="$1" line key val
    MODE=""; PORT=""; PUBLIC=""; UUID=""; NODE_PATH=""; NODE_HOST=""
    SNI=""; TARGET=""; PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
    FP=""; CF_DOMAIN=""; CF_TOKEN_SET=""; SECURITY="none"; CREATED=""
    PROTO="tcp"; AUTH=""; CERT_FILE=""; KEY_FILE=""; PIN_B64=""; PIN_HEX=""
    MASQ_URL=""; BRUTAL_UP=""; BRUTAL_DOWN=""
    while IFS= read -r line; do
        # Keys may contain digits (PIN_B64, BRUTAL_UP); [A-Z_]+ would silently
        # skip them and produce an empty pinSHA256 in the share link.
        [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue
        key="${line%%=*}"; val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"
        case "$key" in
            MODE|PORT|PUBLIC|UUID|NODE_PATH|NODE_HOST|SNI|TARGET|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|FP|CF_DOMAIN|CF_TOKEN_SET|SECURITY|CREATED|PROTO|AUTH|CERT_FILE|KEY_FILE|PIN_B64|PIN_HEX|MASQ_URL|BRUTAL_UP|BRUTAL_DOWN)
                printf -v "$key" '%s' "$val" ;;
        esac
    done <"$f"
}

node_save() {
    local f="$1"; shift
    local kv
    {
        for kv in "$@"; do printf '%s\n' "$kv"; done
    } | atomic_write "$f" 0600
}

log_json() {
    local lvl dir
    lvl="$(state_get LOG_LEVEL warning)"
    [[ "$lvl" == "none" ]] && { printf '{"loglevel":"none"}'; return; }
    dir="$(json_escape "$XHY_LOGDIR")"
    printf '{"loglevel":"%s","access":"%s/xray-access.log","error":"%s/xray-error.log"}' \
        "$lvl" "$dir" "$dir"
}

dns_json() {
    case "$(state_get DNS_PROVIDER cloudflare)" in
        cloudflare) printf '{"servers":["https+local://1.1.1.1/dns-query","localhost"]}' ;;
        quad9)      printf '{"servers":["https+local://dns.quad9.net/dns-query","localhost"]}' ;;
        dns-sb)     printf '{"servers":["https+local://doh.dns.sb/dns-query","localhost"]}' ;;
        system)     printf '{"servers":["localhost"]}' ;;
        *)          printf '{"servers":["https+local://1.1.1.1/dns-query","localhost"]}' ;;
    esac
}

routing_json() {
    local rules=()
    [[ "$(state_get BLOCK_BT on)" == "on" ]] && \
        rules+=('{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}')
    [[ "$(state_get BLOCK_PRIVATE on)" == "on" ]] && \
        rules+=('{"type":"field","ip":["geoip:private"],"outboundTag":"block"}')
    [[ "$(state_get BLOCK_CN off)" == "on" ]] && \
        rules+=('{"type":"field","ip":["geoip:cn"],"outboundTag":"block"}')
    [[ "$(state_get BLOCK_ADS off)" == "on" ]] && \
        rules+=('{"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"}')
    local joined="" sep=""
    local r
    for r in "${rules[@]}"; do joined+="$sep$r"; sep=","; done
    printf '{"domainStrategy":"IPIfNonMatch","rules":[%s]}' "$joined"
}

outbounds_json() {
    printf '[{"protocol":"freedom","tag":"direct","settings":{}},{"protocol":"blackhole","tag":"block"}]'
}

# Snapshot the *source of truth* only: node registry, config fragments, hy2
# certificates and settings. config.json is deliberately excluded because it is
# derived from those files -- archiving it alongside a post-delete registry
# (node_del removes the .env first, then rebuilds) would capture a config that
# references a node whose credentials no longer exist. A restore always
# re-renders fragments from the registry, so any snapshot is self-healing.
snapshot_state() {
    local snap f n=0
    [[ -d "$XHY_NODES" ]] || return 0
    snap="$XHY_SNAPSHOTS/state.$(date +%Y%m%d%H%M%S).tar.gz"
    # `cd` instead of `tar -C`: a path containing ":" is read as host:path by
    # GNU tar, which silently produced empty snapshots in mixed environments.
    if ( cd "$XHY_ETC" && tar czf "$snap" confs nodes certs state.env ) 2>/dev/null; then
        chmod 600 "$snap" 2>/dev/null || true
    else
        rm -f "$snap"
        warn "状态快照创建失败（$XHY_ETC）；xhy rollback 将没有可用快照"
        return 0
    fi
    while IFS= read -r f; do
        n=$((n + 1))
        if (( n > 5 )); then rm -f "$f"; fi
    done < <(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null)
}

rebuild_config() {
    local joined="" sep="" f
    init_dirs
    [[ "${XHY_SKIP_SNAPSHOT:-0}" == "1" ]] || snapshot_state
    for f in "$XHY_CONFDIR"/*.json; do
        [[ -s "$f" ]] || continue
        joined+="$sep$(cat "$f")"
        sep=","
    done
    {
        printf '{\n  "log": %s,\n' "$(log_json)"
        printf '  "inbounds": [%s],\n' "$joined"
        printf '  "dns": %s,\n' "$(dns_json)"
        printf '  "routing": %s,\n' "$(routing_json)"
        printf '  "outbounds": %s\n}\n' "$(outbounds_json)"
    } | atomic_write "$XHY_ETC/config.json" 0600
    ok "配置已重建: $XHY_ETC/config.json ($(node_count) 个节点)"
}

sniffing_json() {
    printf '"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}'
}

# ---------------------------------------------------------------------------
# inbound fragment renderers. Each reads the corresponding .env file.
# ---------------------------------------------------------------------------

render_inbound() {
    local env="$1" mode
    node_load "$env"
    mode="$MODE"
    case "$mode" in
        direct)  render_direct ;;
        tunnel)  render_tunnel ;;
        reality) render_reality ;;
        xhttp)   render_xhttp ;;
        hy2)     render_hy2 ;;
        *) err "未知节点类型: $mode"; return 1 ;;
    esac
}

render_direct() {
    cat <<EOF
{
  "listen": "$(listen_addr)", "port": ${PORT}, "protocol": "vless",
  "tag": "in-direct-${PORT}",
  "settings": { "clients": [ { "id": "${UUID}", "email": "direct-${PORT}" } ], "decryption": "none" },
  "streamSettings": {
    "network": "ws", "security": "none",
    "wsSettings": { "path": "${NODE_PATH}", "host": "${NODE_HOST}" }
  },
  $(sniffing_json)
}
EOF
}

render_tunnel() {
    cat <<EOF
{
  "listen": "127.0.0.1", "port": ${PORT}, "protocol": "vless",
  "tag": "in-tunnel-${PORT}",
  "settings": { "clients": [ { "id": "${UUID}", "email": "tunnel-${PORT}" } ], "decryption": "none" },
  "streamSettings": {
    "network": "ws", "security": "none",
    "wsSettings": { "path": "${NODE_PATH}", "host": "${CF_DOMAIN}" }
  },
  $(sniffing_json)
}
EOF
}

render_reality() {
    cat <<EOF
{
  "listen": "$(listen_addr)", "port": ${PORT}, "protocol": "vless",
  "tag": "in-reality-${PORT}",
  "settings": {
    "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision", "email": "reality-${PORT}" } ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp", "security": "reality",
    "realitySettings": {
      "show": false,
      "target": "${TARGET}",
      "serverNames": [ "${SNI}" ],
      "privateKey": "${PRIVATE_KEY}",
      "shortIds": [ "${SHORT_ID}" ],
$(limit_fallback_json)
      "xver": 0
    }
  },
  $(sniffing_json)
}
EOF
}

render_xhttp() {
    local sec_block="" reality_block=""
    if [[ "${SECURITY:-none}" == "reality" ]]; then
        sec_block='"security": "reality",'
        reality_block=$(cat <<EOF
    "realitySettings": {
      "show": false,
      "target": "${TARGET}",
      "serverNames": [ "${SNI}" ],
      "privateKey": "${PRIVATE_KEY}",
      "shortIds": [ "${SHORT_ID}" ],
$(limit_fallback_json)
      "xver": 0
    },
EOF
)
    else
        sec_block='"security": "none",'
    fi
    cat <<EOF
{
  "listen": "$(listen_addr)", "port": ${PORT}, "protocol": "vless",
  "tag": "in-xhttp-${PORT}",
  "settings": { "clients": [ { "id": "${UUID}", "email": "xhttp-${PORT}" } ], "decryption": "none" },
  "streamSettings": {
    "network": "xhttp", ${sec_block}
${reality_block}
    "xhttpSettings": { "path": "${NODE_PATH}", "host": "${NODE_HOST}", "mode": "auto" }
  },
  $(sniffing_json)
}
EOF
}

# Xray's native Hysteria2 inbound (v26.3.27+). Verified with `xray run -test`:
# protocol "hysteria", version 2, network "hysteria", security "tls", alpn h3.
render_hy2() {
    local qp="" masq
    [[ -n "$BRUTAL_UP" ]] && qp="\"brutalUp\": \"${BRUTAL_UP}\""
    if [[ -n "$BRUTAL_DOWN" ]]; then
        [[ -n "$qp" ]] && qp+=", "
        qp+="\"brutalDown\": \"${BRUTAL_DOWN}\""
    fi
    masq="$(json_escape "$MASQ_URL")"
    cat <<EOF
{
  "listen": "$(listen_addr)", "port": ${PORT}, "protocol": "hysteria",
  "tag": "in-hy2-${PORT}",
  "settings": {
    "version": 2,
    "clients": [ { "auth": "${AUTH}", "email": "hy2-${PORT}" } ]
  },
  "streamSettings": {
    "network": "hysteria", "security": "tls",
    "hysteriaSettings": {
      "version": 2,
      "masquerade": { "type": "proxy", "url": "${masq}", "rewriteHost": true }
    },
    "tlsSettings": {
      "alpn": [ "h3" ],
      "certificates": [ { "certificateFile": "${CERT_FILE}", "keyFile": "${KEY_FILE}" } ]
    },
    "finalmask": { "quicParams": { ${qp} } }
  },
  $(sniffing_json)
}
EOF
}

write_fragment() {
    local env="$1" m p frag content
    # Resolve the destination BEFORE rendering: in a pipeline both sides are
    # expanded concurrently, so $MODE/$PORT would still be unset here.
    node_load "$env"
    m="$MODE"; p="$PORT"
    frag="$(node_frag "$m" "$p")"
    content="$(render_inbound "$env")" || return 1
    printf '%s\n' "$content" | atomic_write "$frag" 0644
}

# ---------------------------------------------------------------------------
# node creation
# ---------------------------------------------------------------------------

# node_add MODE PORT [--host H] [--path P] [--sni S] [--target T]
#                    [--token TOKEN] [--domain D] [--reality] [--uuid U]
node_add() {
    local mode="$1" port="$2"; shift 2
    local host="" path="" sni="" target="" token="" domain="" uuid="" with_reality="0"
    local masq="" up="" down=""
    while (( $# > 0 )); do
        case "$1" in
            --host)   host="$2"; shift 2 ;;
            --path)   path="$2"; shift 2 ;;
            --sni)    sni="$2"; shift 2 ;;
            --target) target="$2"; shift 2 ;;
            --token)  token="$2"; shift 2 ;;
            --domain) domain="$2"; shift 2 ;;
            --uuid)   uuid="$2"; shift 2 ;;
            --masq)   masq="$2"; shift 2 ;;
            --up)     up="$2"; shift 2 ;;
            --down)   down="$2"; shift 2 ;;
            --reality) with_reality="1"; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done

    case "$mode" in
        direct|tunnel|reality|xhttp|hy2) ;;
        *) die "模式只能是 direct / tunnel / reality / xhttp / hy2" ;;
    esac
    valid_port "$port" || die "端口不合法: $port"
    local clash
    clash="$(port_used_by_node "$port")" || true
    [[ -n "$clash" ]] && die "端口 $port 已被节点 ${clash} 占用（不同模式也不能共用端口）"
    need_root
    init_dirs
    [[ -x "$XRAY_BIN" ]] || die "尚未安装 Xray，请先运行: xhy install"

    if port_busy "$port"; then
        warn "端口 $port 已被占用，请确认不是其它服务。"
        confirm "仍要继续？" "n" || return 1
    fi

    uuid="${uuid:-$(uuid_gen)}"
    path="${path:-$(rand_path)}"
    host="${host:-$(public_ip)}"
    [[ "$path" == /* ]] || path="/$path"

    local public=1 priv="" pub="" sid="" tgt="" t_sni="" label="" security="none"
    local pairs=() picked="" kp=""
    if [[ -n "$target" && "$target" != *:* ]]; then target="${target}:443"; fi

    case "$mode" in
        reality)
            if [[ -n "$target" ]]; then
                tgt="$target"; t_sni="${sni:-${target%%:*}}"
                if is_ip_literal "${tgt%%:*}" && [[ -z "$sni" ]]; then
                    die "target 是 IP 时必须同时给 --sni 域名（dest=IP、SNI=域名，例：--target 1.2.3.4:443 --sni www.example.com）"
                fi
                target_validate "$tgt" "$t_sni" || confirm "校验未通过，仍要使用？" "n" || return 1
            else
                picked="$(pick_target)" || return 1
                [[ -n "$picked" ]] || { err "伪装站选择失败"; return 1; }
                read -r tgt t_sni label <<<"$picked"
                [[ -n "$sni" ]] && t_sni="$sni"
            fi
            kp="$(x25519_keypair)" || return 1
            read -r priv pub <<<"$kp"
            [[ -n "$priv" && -n "$pub" ]] || { err "x25519 密钥生成失败"; return 1; }
            sid="$(rand_hex 8)"
            pairs=(
                "MODE=reality" "PORT=$port" "PUBLIC=1" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$host" "SNI=$t_sni" "TARGET=$tgt"
                "PRIVATE_KEY=$priv" "PUBLIC_KEY=$pub" "SHORT_ID=$sid"
                "FP=chrome" "SECURITY=reality" "CREATED=$(date -Is)"
            ) ;;
        xhttp)
            if [[ "$with_reality" == "1" || -n "$target" ]]; then
                security="reality"
                if [[ -n "$target" ]]; then
                    tgt="$target"; t_sni="${sni:-${target%%:*}}"
                    if is_ip_literal "${tgt%%:*}" && [[ -z "$sni" ]]; then
                        die "target 是 IP 时必须同时给 --sni 域名（dest=IP、SNI=域名）"
                    fi
                    target_validate "$tgt" "$t_sni" || confirm "校验未通过，仍要使用？" "n" || return 1
                else
                    picked="$(pick_target)" || return 1
                    [[ -n "$picked" ]] || { err "伪装站选择失败"; return 1; }
                    read -r tgt t_sni label <<<"$picked"
                    [[ -n "$sni" ]] && t_sni="$sni"
                fi
                kp="$(x25519_keypair)" || return 1
                read -r priv pub <<<"$kp"
                [[ -n "$priv" && -n "$pub" ]] || { err "x25519 密钥生成失败"; return 1; }
                sid="$(rand_hex 8)"
            fi
            pairs=(
                "MODE=xhttp" "PORT=$port" "PUBLIC=1" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$host" "SNI=${t_sni:-$host}" "TARGET=${tgt:-}"
                "PRIVATE_KEY=${priv:-}" "PUBLIC_KEY=${pub:-}" "SHORT_ID=${sid:-}"
                "FP=chrome" "SECURITY=$security" "CREATED=$(date -Is)"
            ) ;;
        direct)
            pairs=(
                "MODE=direct" "PORT=$port" "PUBLIC=1" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$host" "SECURITY=none" "CREATED=$(date -Is)"
            ) ;;
        tunnel)
            public=0
            domain="${domain:-}"
            [[ -n "$domain" ]] || die "tunnel 模式需要 --domain <CF 公开主机名>"
            token="${token:-}"
            if [[ -n "$token" ]]; then
                printf '%s' "$token" | atomic_write "$XHY_ETC/tunnel.token" 0600
            fi
            [[ -s "$XHY_ETC/tunnel.token" ]] || die "tunnel 模式需要 --token <Cloudflare Tunnel Token>（也可预先写入 $XHY_ETC/tunnel.token）"
            [[ -x "$CF_BIN" ]] || cloudflared_install
            install_cf_service
            svc_restart "$SVC_CF" || warn "cloudflared 启动失败，请在 CF 控制台确认 Tunnel 配置"
            pairs=(
                "MODE=tunnel" "PORT=$port" "PUBLIC=0" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$domain" "CF_DOMAIN=$domain" "CF_TOKEN_SET=1"
                "SECURITY=none" "CREATED=$(date -Is)"
            ) ;;
        hy2)
            local hy2sni masq_url crt key pin64 pinhex
            hy2sni="${sni:-www.bing.com}"
            masq_url="${masq:-https://www.bing.com/}"
            read -r crt key pin64 pinhex <<<"$(hy2_gen_cert "$port" "$hy2sni")"
            [[ -s "$crt" && -s "$key" ]] || die "Hysteria2 自签证书生成失败"
            pairs=(
                "MODE=hy2" "PORT=$port" "PUBLIC=1" "PROTO=udp"
                "UUID=$uuid" "AUTH=$uuid" "NODE_HOST=$host"
                "SNI=$hy2sni" "CERT_FILE=$crt" "KEY_FILE=$key"
                "PIN_B64=$pin64" "PIN_HEX=$pinhex" "MASQ_URL=$masq_url"
                "BRUTAL_UP=$up" "BRUTAL_DOWN=$down"
                "SECURITY=tls" "CREATED=$(date -Is)"
            )
            info "Hysteria2 走 UDP $port，防火墙会自动放行 UDP；客户端需支持 hy2（sing-box / mihomo / v2rayN）" ;;
    esac

    local envf
    envf="$(node_file "$mode" "$port")"
    # Snapshot BEFORE the registry changes, so a snapshot always represents a
    # state you can go back to (an "after add" snapshot would be useless).
    snapshot_state
    node_save "$envf" "${pairs[@]}"

    # Roll back cleanly if the generated JSON is invalid.
    if ! write_fragment "$envf"; then
        rm -f "$envf" "$(node_frag "$mode" "$port")"
        die "inbound 配置生成失败，已回滚"
    fi
    if ! XHY_SKIP_SNAPSHOT=1 rebuild_config || ! xray_config_test; then
        rm -f "$envf" "$(node_frag "$mode" "$port")"
        XHY_SKIP_SNAPSHOT=1 rebuild_config >/dev/null
        err "配置校验失败，新节点已回滚，原有节点不受影响。"
        return 1
    fi

    if [[ "$mode" == "tunnel" ]]; then
        info "Cloudflare 控制台请把 Public Hostname 的 Service 指向 http://127.0.0.1:${port}，路径与 WS path 一致: ${path}"
    fi
    config_reload || { err "服务重启失败，节点配置已写入但未生效"; return 1; }
    if [[ "$(state_get FIREWALL_MODE off)" != "off" ]]; then
        firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet
    fi
    ok "节点 ${mode}_${port} 已添加"
    link_from_env "$envf"
}

# 交互式选择节点：列出编号 → 选中后把该节点的字段载入全局 MODE/PORT 等。
# 供菜单「删除节点」与不带参数的 `xhy del` 使用；取消返回 1。
node_pick() {
    local -a files=()
    local f i=0 pick
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        files+=("$f")
    done
    if (( ${#files[@]} == 0 )); then
        warn "暂无节点"
        return 1
    fi
    printf '  %-3s %-8s %-6s %-30s %s\n' "#" "模式" "端口" "连接地址 / SNI" "创建时间"
    printf '  %s\n' "-------------------------------------------------------------------------"
    for f in "${files[@]}"; do
        node_load "$f"
        i=$((i + 1))
        printf '  %-3s %-8s %-6s %-30s %s\n' "$i" "$MODE" "$PORT" \
            "${SNI:-${NODE_HOST:-?}}" "${CREATED:-?}"
    done
    pick="$(ask '选择节点编号（回车取消）' '')"
    [[ -n "$pick" ]] || return 1
    if [[ ! "$pick" =~ ^[0-9]+$ ]]; then
        err "请输入数字编号"
        return 1
    fi
    if (( pick < 1 || pick > ${#files[@]} )); then
        err "编号超出范围（1-${#files[@]}）"
        return 1
    fi
    node_load "${files[$((pick - 1))]}"
    ok "已选择节点 ${MODE}_${PORT}"
}

node_del() {
    local mode="$1" port="$2" envf
    envf="$(node_file "$mode" "$port")"
    [[ -f "$envf" ]] || die "节点不存在: ${mode}_${port}"
    need_root
    backup_file "$envf"
    snapshot_state          # before the registry changes: undoable delete
    rm -f "$envf" "$(node_frag "$mode" "$port")"
    if [[ "$mode" == "hy2" ]]; then
        rm -f "$XHY_CERTS/hy2_${port}.crt" "$XHY_CERTS/hy2_${port}.key"
        info "已清理该 Hysteria2 节点的自签证书"
    fi
    if [[ "$mode" == "tunnel" ]] && ! find "$XHY_NODES" -name 'tunnel_*.env' | grep -q .; then
        remove_cf_service
        rm -f "$XHY_ETC/tunnel.token"
        info "已无 tunnel 节点，cloudflared 服务与 token 已清理"
    fi
    XHY_SKIP_SNAPSHOT=1 rebuild_config
    xray_config_test && config_reload
    [[ "$(state_get FIREWALL_MODE off)" != "off" ]] && firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet
    ok "节点 ${mode}_${port} 已删除（凭据备份在 $XHY_BACKUP，可用 xhy snapshots 回滚整套状态）"
}

node_list() {
    local f mode port uuid sec created
    printf '%-10s %-7s %-6s %-38s %-10s %s\n' "模式" "端口" "公网" "UUID" "安全" "创建时间"
    printf '%s\n' "--------------------------------------------------------------------------------------------"
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        node_load "$f"
        printf '%-10s %-7s %-6s %-38s %-10s %s\n' \
            "$MODE" "$PORT" "$([[ "$PUBLIC" == 1 ]] && echo yes || echo no)" \
            "$UUID" "${SECURITY:-none}" "${CREATED:-?}"
    done
    (( $(node_count) > 0 )) || printf '(暂无节点)\n'
}

node_rebuild_all() {
    local f
    need_root
    init_dirs
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        write_fragment "$f" || die "重建 ${f##*/} 失败"
    done
    rebuild_config
    xray_config_test || { err "重建后的配置校验失败"; return 1; }
    config_reload || warn "配置已写入，但服务未能重启（尚未 install 或服务未启用？）"
}

list_snapshots() {
    local f
    if ! ls "$XHY_SNAPSHOTS"/state.*.tar.gz >/dev/null 2>&1; then
        warn "暂无快照"; return 0
    fi
    for f in $(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null || true); do
        printf '%s  (%s bytes)\n' "$f" "$(stat -c%s "$f" 2>/dev/null || echo '?')"
    done
}

rollback_config() {
    local target="${1:-}" pre
    need_root
    if [[ -z "$target" ]]; then
        target="$(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null | head -1 || true)"
    fi
    [[ -s "$target" ]] || die "没有可用的状态快照（快照格式：state.*.tar.gz）"
    # Save the state we are about to replace, so the rollback itself is undoable.
    pre="$XHY_SNAPSHOTS/state.pre-rollback.$(date +%s).tar.gz"
    ( cd "$XHY_ETC" && tar czf "$pre" confs nodes certs state.env ) 2>/dev/null || true
    chmod 600 "$pre" 2>/dev/null || true
    # Clear first: files that exist now but not in the snapshot must disappear,
    # otherwise the restore produces a union of two states.
    rm -f "$XHY_NODES"/*.env "$XHY_CONFDIR"/*.json
    ( cd "$XHY_ETC" && tar xzf "$target" ) || die "快照解包失败，当前状态已另存为 $pre"
    chmod 700 "$XHY_NODES" "$XHY_CERTS" 2>/dev/null || true
    # Re-render every fragment from the restored registry, then validate and
    # reload. Older snapshots that still carry config.json are handled the same
    # way: the file is simply overwritten by the rebuild.
    XHY_SKIP_SNAPSHOT=1 node_rebuild_all || die "回滚后的配置校验失败（当前状态备份: $pre）"
    ok "已回滚整套状态到 $target（节点注册表、配置分片、证书均已恢复并重新渲染）"
}
