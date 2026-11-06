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
        v="$(grep -m1 '^PORT=' "$f" 2>/dev/null | cut -d= -f2-)"
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
    while IFS= read -r line; do
        [[ "$line" =~ ^[A-Z_]+= ]] || continue
        key="${line%%=*}"; val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"
        case "$key" in
            MODE|PORT|PUBLIC|UUID|NODE_PATH|NODE_HOST|SNI|TARGET|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|FP|CF_DOMAIN|CF_TOKEN_SET|SECURITY|CREATED)
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

rebuild_config() {
    local joined="" sep="" f snap n=0
    init_dirs
    # Snapshot the WHOLE mutable state, not just config.json: restoring only
    # the config while leaving a newly added node's .env / fragment behind
    # produces a silently inconsistent deployment. Keep the 5 most recent.
    if [[ -s "$XHY_ETC/config.json" ]]; then
        snap="$XHY_SNAPSHOTS/state.$(date +%Y%m%d%H%M%S).tar.gz"
        if tar czf "$snap" -C "$XHY_ETC" config.json confs nodes state.env 2>/dev/null; then
            chmod 600 "$snap" 2>/dev/null || true
        else
            rm -f "$snap"
        fi
        while IFS= read -r f; do
            n=$((n + 1))
            if (( n > 5 )); then rm -f "$f"; fi
        done < <(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null)
    fi
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
    while (( $# > 0 )); do
        case "$1" in
            --host)   host="$2"; shift 2 ;;
            --path)   path="$2"; shift 2 ;;
            --sni)    sni="$2"; shift 2 ;;
            --target) target="$2"; shift 2 ;;
            --token)  token="$2"; shift 2 ;;
            --domain) domain="$2"; shift 2 ;;
            --uuid)   uuid="$2"; shift 2 ;;
            --reality) with_reality="1"; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done

    case "$mode" in
        direct|tunnel|reality|xhttp) ;;
        *) die "模式只能是 direct / tunnel / reality / xhttp" ;;
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
                target_validate "$tgt" || confirm "校验未通过，仍要使用？" "n" || return 1
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
    esac

    local envf
    envf="$(node_file "$mode" "$port")"
    node_save "$envf" "${pairs[@]}"

    # Roll back cleanly if the generated JSON is invalid.
    if ! write_fragment "$envf"; then
        rm -f "$envf" "$(node_frag "$mode" "$port")"
        die "inbound 配置生成失败，已回滚"
    fi
    if ! rebuild_config || ! xray_config_test; then
        rm -f "$envf" "$(node_frag "$mode" "$port")"
        rebuild_config >/dev/null
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

node_del() {
    local mode="$1" port="$2" envf
    envf="$(node_file "$mode" "$port")"
    [[ -f "$envf" ]] || die "节点不存在: ${mode}_${port}"
    need_root
    backup_file "$envf"
    rm -f "$envf" "$(node_frag "$mode" "$port")"
    if [[ "$mode" == "tunnel" ]] && ! find "$XHY_NODES" -name 'tunnel_*.env' | grep -q .; then
        remove_cf_service
        rm -f "$XHY_ETC/tunnel.token"
        info "已无 tunnel 节点，cloudflared 服务与 token 已清理"
    fi
    rebuild_config
    xray_config_test && config_reload
    [[ "$(state_get FIREWALL_MODE off)" != "off" ]] && firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet
    ok "节点 ${mode}_${port} 已删除（备份在 $XHY_BACKUP）"
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
    for f in $(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null); do
        printf '%s  (%s bytes)\n' "$f" "$(stat -c%s "$f" 2>/dev/null || echo '?')"
    done
}

rollback_config() {
    local target="${1:-}" pre
    need_root
    if [[ -z "$target" ]]; then
        target="$(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null | head -1)"
    fi
    [[ -s "$target" ]] || die "没有可用的状态快照（快照格式在最近一次更新后改为 state.*.tar.gz）"
    # Save the state we are about to replace, so the rollback itself is undoable.
    pre="$XHY_SNAPSHOTS/state.pre-rollback.$(date +%s).tar.gz"
    tar czf "$pre" -C "$XHY_ETC" config.json confs nodes state.env 2>/dev/null || true
    chmod 600 "$pre" 2>/dev/null || true
    rm -f "$XHY_NODES"/*.env "$XHY_CONFDIR"/*.json
    tar xzf "$target" -C "$XHY_ETC" || die "快照解包失败，当前状态已另存为 $pre"
    chmod 600 "$XHY_ETC/config.json" "$XHY_ETC/state.env" 2>/dev/null || true
    chmod 700 "$XHY_NODES" 2>/dev/null || true
    xray_config_test || die "快照配置校验失败，未重载服务（当前状态备份: $pre）"
    config_reload
    ok "已回滚整套状态到 $target（含节点注册表与配置分片）"
}
