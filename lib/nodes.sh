#!/usr/bin/env bash
# xray-hy / node registry, inbound rendering and full-config rebuild.
# Design: one .env per node (credentials) + one JSON fragment per node
# (a single inbound object). `rebuild_config` merges fragments into a single
# config.json so `xray run -test -c` can validate the whole thing atomically.

# 只返回「真节点」env。$XHY_NODES 里还有 relay.env（中继状态，不是节点）、
# 备份 *.env.bak-*、临时文件；旧版所有遍历点都裸扫 *.env，于是 node_list 出现
# 一行 MODE/PORT/UUID 全空的幽灵记录、node_count 把 relay.env 算成第 2 个节点，
# 而 node_rebuild_all（xhy update config）会拿 relay.env 去 write_fragment，
# 渲染出「未知节点类型: 」直接 rc=1。判据双保险：文件名 <mode>_<port>.env + 有 MODE= 行。
node_env_files() {
    local f base
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        base="${f##*/}"
        [[ "$base" =~ ^[A-Za-z0-9_]+_[0-9]+\.env$ ]] || continue
        grep -q '^MODE=' "$f" 2>/dev/null || continue
        printf '%s\n' "$f"
    done
}

node_file()   { printf '%s/%s_%s.env' "$XHY_NODES" "$1" "$2"; }
node_frag()   { printf '%s/%s_%s.json' "$XHY_CONFDIR" "$1" "$2"; }
node_exists() { [[ -f "$(node_file "$1" "$2")" ]]; }
node_count()  { node_env_files | wc -l; }

# A port must be unique across ALL modes, not just within one mode.
port_used_by_node() {
    local p="$1" f v
    for f in $(node_env_files); do
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
    TFO=""; MASQ_MODE=""
    while IFS= read -r line; do
        # Keys may contain digits (PIN_B64, BRUTAL_UP); [A-Z_]+ would silently
        # skip them and produce an empty pinSHA256 in the share link.
        [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue
        key="${line%%=*}"; val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"
        case "$key" in
            MODE|PORT|PUBLIC|UUID|NODE_PATH|NODE_HOST|SNI|TARGET|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|FP|CF_DOMAIN|CF_TOKEN_SET|SECURITY|CREATED|PROTO|AUTH|CERT_FILE|KEY_FILE|PIN_B64|PIN_HEX|MASQ_URL|BRUTAL_UP|BRUTAL_DOWN|TFO|MASQ_MODE)
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
    [[ "$lvl" == "none" ]] && { printf '{"loglevel":"none"}'; return 0; }
    dir="$(json_escape "$XHY_LOGDIR")"
    # access log 记录每条连接的源 IP + 时间 + 目标，纯转发服务器不需要，
    # 且是磁盘 IO 与隐私的双重负担。排障时 `xhy config set ACCESS_LOG on`。
    if [[ "$(state_get ACCESS_LOG off)" == "on" ]]; then
        printf '{"loglevel":"%s","access":"%s/xray-access.log","error":"%s/xray-error.log"}' \
            "$lvl" "$dir" "$dir"
    else
        printf '{"loglevel":"%s","access":"none","error":"%s/xray-error.log"}' \
            "$lvl" "$dir"
    fi
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
    # v1.13.0：官方 geosite 的 category-ads-all 只有 905 条（Loyalsoldier 版 199 451
    # 条），单靠它会漏掉一大批。带上 category-ads（官方 845 / Loyalsoldier 849，
    # 两边几乎一致），官方版也能挡住主体，不依赖某一家的大表。
    [[ "$(state_get BLOCK_ADS off)" == "on" ]] && \
        rules+=('{"type":"field","domain":["geosite:category-ads","geosite:category-ads-all"],"outboundTag":"block"}')
    local joined="" sep=""
    local r
    for r in "${rules[@]}"; do joined+="$sep$r"; sep=","; done
    printf '{"domainStrategy":"IPIfNonMatch","rules":[%s]}' "$joined"
}

outbounds_json() {
    printf '[{"protocol":"freedom","tag":"direct","settings":{}},{"protocol":"blackhole","tag":"block"}]'
}

policy_json() {
    # bufferSize 单位 KB，是每连接单向缓冲。默认 512；跨境高 BDP 链路可调到
    # 1024，但 1G 内存机器上 1024 × 2 方向 × 200 并发就是 400MB，别盲目加。
    # stats* 全关：REALITY / hy2 都是单用户或小规模，流量统计只会白烧内存。
    printf '{"levels":{"0":{"handshake":4,"connIdle":300,"uplinkOnly":2,"downlinkOnly":5,"bufferSize":%s}},"system":{"statsInboundUplink":false,"statsInboundDownlink":false,"statsOutboundUplink":false,"statsOutboundDownlink":false}}' \
        "$(state_get BUFFER_SIZE 512)"
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
    snap="$(mktemp "$XHY_SNAPSHOTS/state.$(date +%Y%m%d%H%M%S).XXXXXX")" ||
        { warn "无法创建状态快照临时文件"; return 0; }
    # `cd` instead of `tar -C`: a path containing ":" is read as host:path by
    # GNU tar, which silently produced empty snapshots in mixed environments.
    if ( cd "$XHY_ETC" && tar czf "$snap" confs nodes certs state.env ) 2>/dev/null &&
       mv -f "$snap" "$snap.tar.gz"; then
        chmod 600 "$snap.tar.gz" 2>/dev/null || true
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
    local joined="" sep="" f cfg
    init_dirs || return 1
    if [[ -e "$XHY_NODES/relay.env" ]]; then
        relay_env_load || { err "relay 状态无效，保留原配置"; return 1; }
    fi
    [[ "${XHY_SKIP_SNAPSHOT:-0}" == "1" ]] || snapshot_state
    for f in "$XHY_CONFDIR"/*.json; do
        [[ -s "$f" ]] || continue
        joined+="$sep$(cat "$f")"
        sep=","
    done
    # 扩展钩子（默认空实现，见下方 extra_* 定义）。relay 覆盖它们注入自己的
    # 出站与前置路由，这样 add/edit/del 触发的基础重建不会再把 relay 冲掉。
    local ob ob_extra rt rt_head rules rules_extra inner
    ob="$(outbounds_json)"
    ob_extra="$(extra_outbounds_json)"
    if [[ -n "$ob_extra" ]]; then
        inner="${ob#\[}"; inner="${inner%\]}"
        ob="[${inner},${ob_extra}]"
    fi
    rt="$(routing_json)"
    rt_head="${rt%%\"rules\":\[*}"
    # 兜底：万一 routing_json 以后改了字段顺序/换了 key 名，退回一个合法骨架，
    # 而不是把整段 JSON 拼坏（拼坏了 xray 直接起不来）。
    [[ "$rt_head" == "$rt" ]] && rt_head='{"domainStrategy":"IPIfNonMatch",'
    rules="${rt#*\"rules\":\[}"; rules="${rules%\]*}"
    rules_extra="$(extra_routing_rules_json)"
    if [[ -n "$rules_extra" ]]; then
        if [[ -n "$rules" ]]; then rules="${rules_extra},${rules}"; else rules="$rules_extra"; fi
    fi
    # 另两个钩子：balancer 必须落在 routing 对象内、rules 之前；observatory
    # 是顶层字段。两者位置不同，只能分开给（硬塞进 rules 里 xray 会直接报错）。
    local rh_extra top_extra
    rh_extra="$(extra_routing_head_json)"
    if [[ -n "$rh_extra" ]]; then rh_extra="${rh_extra},"; fi
    top_extra="$(extra_top_json)"
    cfg="$(mktemp "$XHY_ETC/.config.XXXXXX")" || return 1
    # Newer Xray checks the file extension even with -format json.
    mv -f "$cfg" "$cfg.json" || { rm -f "$cfg"; return 1; }
    cfg+=".json"
    if ! {
        printf '{\n  "log": %s,\n' "$(log_json)"
        printf '  "inbounds": [%s],\n' "$joined"
        printf '  "dns": %s,\n' "$(dns_json)"
        printf '  "routing": %s%s"rules":[%s]},\n' "$rt_head" "$rh_extra" "$rules"
        printf '  "outbounds": %s,\n' "$ob"
        if [[ -n "$top_extra" ]]; then
            printf '  "policy": %s,\n  %s\n}\n' "$(policy_json)" "$top_extra"
        else
            printf '  "policy": %s\n}\n' "$(policy_json)"
        fi
    } >"$cfg" || ! xray_config_test "$cfg" || ! mv -f "$cfg" "$XHY_ETC/config.json"; then
        rm -f "$cfg"
        return 1
    fi
    ok "配置已重建: $XHY_ETC/config.json ($(node_count) 个节点)"
}

# 钩子：outbound 追加项（输出形如 {"protocol":...}，多个用逗号分隔；空 = 不追加）
#       前置路由规则（输出形如 {....},{....}，无外层方括号；空 = 不插）
# 由 relay.sh 覆盖。放在这里而不是让模块各抄一份 rebuild_config —— 抄一份就会
# 随着基础管线改动慢慢漂移（relay 第一版正是如此，还漏了 config_reload）。
extra_outbounds_json() { :; }
extra_routing_rules_json() { :; }
#        routing 对象内、"rules" 之前的字段（输出形如 "balancers":[...]；空 = 不插）
#        顶层 JSON 追加字段（输出形如 "burstObservatory":{...}；空 = 不插）
extra_routing_head_json() { :; }
extra_top_json() { :; }

sniffing_json() {
    local override='["tls"]'
    case "${MODE:-}" in
        # 明文 WS：只有 http 头可嗅探
        direct|tunnel) override='["http","tls"]' ;;
        # hy2 自身就是 QUIC，再解析一次 quic 是纯开销
        hy2)           override='["tls"]' ;;
        # reality / xhttp --reality：全程 TLS 1.3
        *)             override='["tls"]' ;;
    esac
    printf '"sniffing":{"enabled":true,"destOverride":%s,"routeOnly":true}' "$override"
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
    "wsSettings": { "path": "${NODE_PATH}", "host": "${NODE_HOST}" },
    $(sockopt_json)
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
    "wsSettings": { "path": "${NODE_PATH}", "host": "${CF_DOMAIN}" },
    $(sockopt_json)
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
    },
    $(sockopt_json)
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
    "xhttpSettings": { "path": "${NODE_PATH}", "host": "${NODE_HOST}", "mode": "auto" },
    $(sockopt_json)
  },
  $(sniffing_json)
}
EOF
}

# Xray's native Hysteria2 inbound (v26.3.27+). Verified with `xray run -test`:
# protocol "hysteria", version 2, network "hysteria", security "tls", alpn h3.
render_hy2() {
    local qp="" masq masq_block
    [[ -n "$BRUTAL_UP" ]] && qp="\"brutalUp\": \"${BRUTAL_UP}\""
    if [[ -n "$BRUTAL_DOWN" ]]; then
        [[ -n "$qp" ]] && qp+=", "
        qp+="\"brutalDown\": \"${BRUTAL_DOWN}\""
    fi
    masq="$(json_escape "$MASQ_URL")"
    if [[ "${MASQ_MODE:-string}" == "proxy" ]]; then
        # 反代真站最像，但被扫描时未认证流量会经你机器转发 = 拿你的带宽
        masq_block="\"masquerade\": { \"type\": \"proxy\", \"url\": \"${masq}\", \"rewriteHost\": true }"
    else
        masq_block="\"masquerade\": { \"type\": \"string\", \"statusCode\": 200, \"headers\": { \"content-type\": \"text/html\" }, \"content\": \"<html><head><title>Welcome to nginx!</title></head><body><h1>Welcome to nginx!</h1></body></html>\" }"
    fi
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
      ${masq_block}
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
    printf '%s\n' "$content" | atomic_write "$frag" 0600
}

# ---------------------------------------------------------------------------
# node creation
# ---------------------------------------------------------------------------

# node_add MODE PORT [--host H] [--path P] [--sni S] [--target T]
#                    [--token TOKEN] [--domain D] [--reality] [--uuid U]
#                    [--scan] [--scan-cidr CIDR] [--scan-refresh]
#                    [--masq-proxy] [--tfo auto|on|off]
node_add() { config_transaction _node_add "$@"; }

_node_add() {
    local mode="$1" port="$2"; shift 2
    local host="" path="" sni="" target="" token="" domain="" uuid="" with_reality="0"
    local masq="" up="" down=""
    local use_scan="0" scan_cidr="" scan_refresh="0"
    local masq_mode="string" tfo_opt="auto" tfo_val="0"
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
            --tfo)    tfo_opt="$2"; shift 2 ;;
            --masq-proxy) masq_mode="proxy"; shift ;;
            --reality) with_reality="1"; shift ;;
            --scan)        use_scan="1"; shift ;;
            --scan-cidr)   scan_cidr="$2"; shift 2 ;;
            --scan-refresh) scan_refresh="1"; shift ;;
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

    # 自动扫描伪装站（--scan）。放在这里而不是各分支里：reality 与
    # xhttp --reality 都走同一段解析，扫出来的结果就是普通的 --target/--sni，
    # 后面的校验、渲染、回滚逻辑完全不用改。
    if [[ "$use_scan" == "1" && -z "$target" ]]; then
        if [[ "$mode" != "reality" && "$with_reality" != "1" ]]; then
            warn "--scan 只对 REALITY 类节点有意义（reality / xhttp --reality），已忽略"
        else
            local -a scargs=()
            local sp sl
            if [[ "$scan_refresh" == "1" ]]; then scargs+=(--refresh); fi
            if [[ -n "$scan_cidr" ]]; then scargs+=(--cidr "$scan_cidr"); fi
            if sp="$(scanner_pick ${scargs[@]+"${scargs[@]}"})"; then
                read -r target sni sl <<<"$sp"
                info "自动扫描选中: target=$target SNI=$sni（来源 scan${sl:+ $sl}）"
            else
                warn "自动扫描没有找到可用站点，回退到内置伪装站库"
                target=""
            fi
        fi
    fi

    local public=1 priv="" pub="" sid="" tgt="" t_sni="" label="" security="none"
    local pairs=() picked="" kp=""
    if [[ -n "$target" && "$target" != *:* ]]; then target="${target}:443"; fi

    snapshot_state
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
            tfo_val="$(tfo_decide "$tfo_opt" "${tgt%%:*}" "${tgt##*:}" "$t_sni")"
            if [[ "$tfo_val" == "1" ]]; then
                info "伪装站支持 TFO → 本节点 tcpFastOpen=true（--tfo off 可覆盖）"
            else
                info "伪装站不支持 TFO → 本节点 tcpFastOpen=false（--tfo on 可覆盖）"
            fi
            pairs=(
                "MODE=reality" "PORT=$port" "PUBLIC=1" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$host" "SNI=$t_sni" "TARGET=$tgt"
                "PRIVATE_KEY=$priv" "PUBLIC_KEY=$pub" "SHORT_ID=$sid"
                "FP=chrome" "SECURITY=reality" "TFO=$tfo_val" "CREATED=$(date -Is)"
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
            tfo_val="$(tfo_decide "$tfo_opt" "${tgt:-}" "${tgt##*:}" "${t_sni:-$host}")"
            pairs=(
                "MODE=xhttp" "PORT=$port" "PUBLIC=1" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$host" "SNI=${t_sni:-$host}" "TARGET=${tgt:-}"
                "PRIVATE_KEY=${priv:-}" "PUBLIC_KEY=${pub:-}" "SHORT_ID=${sid:-}"
                "FP=chrome" "SECURITY=$security" "TFO=$tfo_val" "CREATED=$(date -Is)"
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
                printf '%s' "$token" | atomic_write "$XHY_ETC/tunnel.token" 0600 || return 1
            fi
            [[ -s "$XHY_ETC/tunnel.token" ]] || die "tunnel 模式需要 --token <Cloudflare Tunnel Token>（也可预先写入 $XHY_ETC/tunnel.token）"
            [[ -x "$CF_BIN" ]] || cloudflared_install
            pairs=(
                "MODE=tunnel" "PORT=$port" "PUBLIC=0" "UUID=$uuid" "NODE_PATH=$path"
                "NODE_HOST=$domain" "CF_DOMAIN=$domain" "CF_TOKEN_SET=1"
                "SECURITY=none" "CREATED=$(date -Is)"
            ) ;;
        hy2)
            local hy2sni masq_url crt key pin64 pinhex
            hy2sni="${sni:-www.bing.com}"
            masq_url="${masq:-https://www.bing.com/}"
            if [[ -n "$up" || -n "$down" ]]; then
                warn "Brutal 会无视丢包、按设定速率持续发包：按流量计费的实例会产生真实账单，"
                warn "共享/突发带宽实例可能被云厂商限速或判定滥用。仅在带宽独占时使用。"
            fi
            read -r crt key pin64 pinhex <<<"$(hy2_gen_cert "$port" "$hy2sni")"
            [[ -s "$crt" && -s "$key" ]] || die "Hysteria2 自签证书生成失败"
            pairs=(
                "MODE=hy2" "PORT=$port" "PUBLIC=1" "PROTO=udp"
                "UUID=$uuid" "AUTH=$uuid" "NODE_HOST=$host"
                "SNI=$hy2sni" "CERT_FILE=$crt" "KEY_FILE=$key"
                "PIN_B64=$pin64" "PIN_HEX=$pinhex" "MASQ_URL=$masq_url"
                "BRUTAL_UP=$up" "BRUTAL_DOWN=$down"
                "TFO=0" "MASQ_MODE=$masq_mode"
                "SECURITY=tls" "CREATED=$(date -Is)"
            )
            info "Hysteria2 走 UDP $port，防火墙会自动放行 UDP；客户端需支持 hy2（sing-box / mihomo / v2rayN）" ;;
    esac

    local envf
    envf="$(node_file "$mode" "$port")"
    node_save "$envf" "${pairs[@]}" || return 1
    write_fragment "$envf" || return 1
    XHY_SKIP_SNAPSHOT=1 rebuild_config || return 1

    if [[ "$mode" == "tunnel" ]]; then
        info "Cloudflare 控制台请把 Public Hostname 的 Service 指向 http://127.0.0.1:${port}，路径与 WS path 一致: ${path}"
    fi
    config_reload --validated || return 1
    if [[ "$mode" == tunnel ]]; then
        install_cf_service || return 1
        svc_start "$SVC_CF" || return 1
    fi
    if [[ "$(state_get FIREWALL_MODE off)" != "off" ]]; then
        firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet || return 1
    fi
    ok "节点 ${mode}_${port} 已添加"
    link_from_env "$envf"
}

# ---------------------------------------------------------------------------
# node editing
# ---------------------------------------------------------------------------

# node_env_update <env-file> KEY=VALUE...
# 就地改写注册表：命中的键替换，其余行（含注释与将来新增的字段）原样保留，
# 新键追加到末尾。不要「重新拼一遍 pairs」——那样会顺手丢掉后来加的键。
node_env_update() {
    local f="$1"; shift
    local -A kv=()
    local pair k line
    local -a out=()
    for pair in "$@"; do kv["${pair%%=*}"]="${pair#*=}"; done
    while IFS= read -r line; do
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
            k="${BASH_REMATCH[1]}"
            if [[ -n "${kv[$k]+x}" ]]; then
                out+=("$k=${kv[$k]}")
                unset 'kv[$k]'
                continue
            fi
        fi
        out+=("$line")
    done <"$f"
    for k in "${!kv[@]}"; do out+=("$k=${kv[$k]}"); done
    printf '%s\n' "${out[@]}" | atomic_write "$f" 0600
}

# node_edit_apply MODE PORT KEY=VALUE...
# 落盘 + 重建 + 校验 + 重启。改端口等于重命名注册表文件；hy2 改端口或 SNI
# 必须重签证书（文件名带端口、SAN 带 SNI），否则客户端的 pinSHA256 会失配。
node_edit_apply() { config_transaction _node_edit_apply "$@"; }

_node_edit_apply() {
    local mode="$1" port="$2"; shift 2
    local old_envf new_envf new_mode="$mode" new_port="$port"
    local o_sni="" o_cert="" o_key="" pair clash=""
    need_root
    init_dirs
    old_envf="$(node_file "$mode" "$port")"
    [[ -f "$old_envf" ]] || die "节点不存在: ${mode}_${port}"
    node_load "$old_envf"
    o_sni="$SNI"; o_cert="$CERT_FILE"; o_key="$KEY_FILE"

    for pair in "$@"; do
        case "${pair%%=*}" in
            PORT) new_port="${pair#*=}" ;;
            MODE) new_mode="${pair#*=}" ;;
        esac
    done
    valid_port "$new_port" || die "端口不合法: $new_port"
    if [[ "$new_port" != "$port" ]]; then
        clash="$(port_used_by_node "$new_port")" || true
        if [[ -n "$clash" && "$clash" != "${mode}_${port}" ]]; then
            die "端口 $new_port 已被节点 $clash 占用（不同模式也不能共用端口）"
        fi
        if port_busy "$new_port"; then
            warn "端口 $new_port 已被其它进程占用（可能是旧进程尚未退出）"
            confirm "仍要继续？" "n" || return 1
        fi
    fi

    backup_file "$old_envf"
    snapshot_state
    node_env_update "$old_envf" "$@" || return 1

    if [[ "$new_port" != "$port" ]]; then
        new_envf="$(node_file "$new_mode" "$new_port")"
        mv -f "$old_envf" "$new_envf" || return 1
        rm -f "$(node_frag "$mode" "$port")" || return 1
    else
        new_envf="$old_envf"
    fi

    node_load "$new_envf"
    if [[ "$MODE" == "hy2" ]]; then
        if [[ "$PORT" != "$port" ]] || [[ "$SNI" != "$o_sni" ]]; then
            local crt key pin64 pinhex
            read -r crt key pin64 pinhex <<<"$(hy2_gen_cert "$PORT" "$SNI")" || return 1
            node_env_update "$new_envf" "CERT_FILE=$crt" "KEY_FILE=$key" \
                "PIN_B64=$pin64" "PIN_HEX=$pinhex" || return 1
            if [[ -n "$o_cert" && "$o_cert" != "$crt" && -f "$o_cert" ]]; then
                rm -f "$o_cert" "$o_key"
            fi
            info "已按新的端口 / SNI 重签 Hysteria2 证书，客户端的 pinSHA256 需要更新"
        fi
    fi

    write_fragment "$new_envf" || return 1
    XHY_SKIP_SNAPSHOT=1 rebuild_config || return 1
    config_reload --validated || return 1
    if [[ "$(state_get FIREWALL_MODE off)" != "off" ]]; then
        firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet || return 1
    fi
    ok "节点 ${new_mode}_${new_port} 已更新"
    link_from_env "$new_envf" 2>/dev/null || true
    return 0
}

# node_edit [MODE PORT]
# 交互式编辑：先列出全部当前值，逐项回车即保持。只对相关模式询问相关字段。
node_edit() {
    local mode="${1:-}" port="${2:-}"
    need_root
    init_dirs
    if [[ -z "$mode" || -z "$port" ]]; then
        node_pick || return 1
        mode="$MODE"; port="$PORT"
    fi
    local envf
    envf="$(node_file "$mode" "$port")"
    [[ -f "$envf" ]] || die "节点不存在: ${mode}_${port}"
    node_load "$envf"

    local o_port="$PORT" o_uuid="$UUID" o_path="$NODE_PATH" o_host="$NODE_HOST"
    local o_sni="$SNI" o_tgt="$TARGET" o_fp="$FP" o_sec="$SECURITY" o_sid="$SHORT_ID"
    local o_masq="$MASQ_URL" o_masqmode="$MASQ_MODE" o_up="$BRUTAL_UP" o_down="$BRUTAL_DOWN"
    local -a changes=()
    local v cur_tfo tfo_choice="" new_tgt new_sni pair

    cur_tfo="false"; [[ "$TFO" == "1" ]] && cur_tfo="true"
    printf '\n'
    printf '节点 %s_%s（%s）\n' "$mode" "$port" "${o_sec:-none}"
    printf '  %-14s %s\n' '连接地址' "${o_host:-?}"
    printf '  %-14s %s\n' 'UUID' "${o_uuid:-?}"
    printf '  %-14s %s\n' '路径' "${o_path:-?}"
    if [[ "$o_sec" == "reality" ]]; then
        printf '  %-14s %s\n' 'target' "${o_tgt:-?}"
        printf '  %-14s %s\n' 'SNI' "${o_sni:-?}"
        printf '  %-14s %s\n' 'shortId' "${o_sid:-?}"
        printf '  %-14s %s（当前 tcpFastOpen=%s）\n' '指纹 / TFO' "${o_fp:-chrome}" "$cur_tfo"
    elif [[ "$o_sec" == "tls" ]]; then
        printf '  %-14s %s\n' 'SNI' "${o_sni:-?}"
        printf '  %-14s %s（%s）\n' '伪装' "${o_masq:-?}" "${o_masqmode:-string}"
        printf '  %-14s up=%s down=%s\n' 'Brutal' "${o_up:-off}" "${o_down:-off}"
    fi
    printf '\n直接回车 = 保持原值。\n'

    v="$(ask '端口' "$o_port")"
    [[ "$v" != "$o_port" ]] && changes+=("PORT=$v")
    v="$(ask '连接地址（域名或 IP）' "$o_host")"
    [[ "$v" != "$o_host" ]] && changes+=("NODE_HOST=$v")
    v="$(ask 'UUID（输入 new 重新生成）' "$o_uuid")"
    if [[ "$v" == "new" ]]; then changes+=("UUID=$(uuid_gen)")
    elif [[ "$v" != "$o_uuid" ]]; then changes+=("UUID=$v"); fi
    v="$(ask '路径' "$o_path")"
    if [[ -n "$v" && "$v" != "$o_path" ]]; then
        [[ "$v" == /* ]] || v="/$v"
        changes+=("NODE_PATH=$v")
    fi

    case "$o_sec" in
        reality)
            v="$(ask '伪装站 target（IP:端口 或 域名:端口）' "$o_tgt")"
            [[ "$v" != "$o_tgt" ]] && changes+=("TARGET=$v")
            v="$(ask 'SNI（target 是 IP 时必填域名）' "$o_sni")"
            [[ "$v" != "$o_sni" ]] && changes+=("SNI=$v")
            v="$(ask 'shortId（输入 new 重新生成，客户端需同步）' "$o_sid")"
            if [[ "$v" == "new" ]]; then changes+=("SHORT_ID=$(rand_hex 8)")
            elif [[ "$v" != "$o_sid" ]]; then changes+=("SHORT_ID=$v"); fi
            v="$(ask '指纹 fp' "$o_fp")"
            [[ "$v" != "$o_fp" ]] && changes+=("FP=$v")
            tfo_choice="$(ask 'TFO auto/on/off（auto = 按新 target 重新探测）' 'auto')" ;;
        tls)
            v="$(ask 'SNI（改这个会重签自签证书）' "$o_sni")"
            [[ "$v" != "$o_sni" ]] && changes+=("SNI=$v")
            v="$(ask '伪装 URL' "$o_masq")"
            [[ "$v" != "$o_masq" ]] && changes+=("MASQ_URL=$v")
            v="$(ask '伪装模式 string/proxy' "$o_masqmode")"
            [[ "$v" != "$o_masqmode" ]] && changes+=("MASQ_MODE=$v")
            v="$(ask 'Brutal 上行 Mbps（空=不启用）' "$o_up")"
            [[ "$v" != "$o_up" ]] && changes+=("BRUTAL_UP=$v")
            v="$(ask 'Brutal 下行 Mbps（空=不启用）' "$o_down")"
            [[ "$v" != "$o_down" ]] && changes+=("BRUTAL_DOWN=$v") ;;
    esac

    if (( ${#changes[@]} == 0 )); then
        info "没有改动"
        return 0
    fi

    # TFO 必须在 TARGET/SNI 定稿之后再算：auto 要探测的是新目标，不是旧的。
    if [[ "$o_sec" == "reality" ]]; then
        new_tgt="$o_tgt"; new_sni="$o_sni"
        for pair in "${changes[@]}"; do
            case "${pair%%=*}" in
                TARGET) new_tgt="${pair#*=}" ;;
                SNI)    new_sni="${pair#*=}" ;;
            esac
        done
        case "$tfo_choice" in
            on)   changes+=("TFO=1") ;;
            off)  changes+=("TFO=0") ;;
            auto) changes+=("TFO=$(tfo_decide auto "${new_tgt%%:*}" "${new_tgt##*:}" "$new_sni")") ;;
        esac
    fi

    printf '\n将要修改：\n'
    for pair in "${changes[@]}"; do printf '  %s\n' "$pair"; done
    confirm "确认应用？" "y" || return 1
    node_edit_apply "$mode" "$port" "${changes[@]}"
}

# node_retarget MODE PORT TARGET SNI [auto|on|off]
# 换伪装站：REALITY 私钥与 shortId 不受影响，只换 TARGET/SNI 并重判 TFO。
node_retarget() {
    local mode="$1" port="$2" tgt="$3" sni="$4" tfo_opt="${5:-auto}"
    local envf tfo_val
    envf="$(node_file "$mode" "$port")"
    [[ -f "$envf" ]] || { err "节点不存在: ${mode}_${port}"; return 1; }
    node_load "$envf"
    [[ "$SECURITY" == "reality" ]] || { err "只有 REALITY 节点有伪装站（当前 $SECURITY）"; return 1; }
    [[ -n "$tgt" ]] || { err "target 为空"; return 1; }
    [[ "$tgt" == *:* ]] || tgt="${tgt}:443"
    sni="${sni:-${tgt%%:*}}"
    tfo_val="$(tfo_decide "$tfo_opt" "${tgt%%:*}" "${tgt##*:}" "$sni")"
    info "${mode}_${port}: target=${tgt} SNI=${sni} TFO=${tfo_val}"
    node_edit_apply "$mode" "$port" "TARGET=$tgt" "SNI=$sni" "TFO=$tfo_val"
}

# node_retarget_menu TARGET SNI
# 扫描出更好的伪装站之后，问要不要套用到已有的 REALITY 节点上。
# 支持 all / 逗号分隔的多选 / 单个编号；回车 = 一个都不换。
node_retarget_menu() {
    local tgt="$1" sni="$2"
    local -a modes=() ports=() tgts=() snis=()
    local f i=0 pick item
    local -a sel=()
    if [[ -z "$tgt" ]]; then
        info "没有新的伪装站可应用"
        return 0
    fi
    for f in $(node_env_files); do
        [[ -f "$f" ]] || continue
        node_load "$f"
        [[ "$SECURITY" == "reality" ]] || continue
        modes+=("$MODE"); ports+=("$PORT"); tgts+=("$TARGET"); snis+=("$SNI")
    done
    if (( ${#ports[@]} == 0 )); then
        info "当前没有 REALITY 节点，新伪装站已记为默认 target，下次新建节点会用"
        return 0
    fi

    printf '\n  新伪装站: target=%s SNI=%s\n' "$tgt" "$sni"
    printf '  已存在的 REALITY 节点：\n'
    printf '  %-3s %-16s %-34s %s\n' "#" "节点" "当前 target" "当前 SNI"
    printf '  %s\n' "--------------------------------------------------------------------------"
    for (( i = 0; i < ${#ports[@]}; i++ )); do
        printf '  %-3s %-16s %-34s %s\n' "$((i + 1))" "${modes[$i]}_${ports[$i]}" \
            "${tgts[$i]:-?}" "${snis[$i]:-?}"
    done
    pick="$(ask '替换哪些（all / 1,3 / 回车=不换）' '')"
    [[ -n "$pick" ]] || { info "保持原 target 不变"; return 0; }

    if [[ "$pick" == "all" ]]; then
        for (( i = 0; i < ${#ports[@]}; i++ )); do sel+=("$i"); done
    else
        local IFS_BAK="$IFS"
        IFS=','
        for item in $pick; do
            item="${item// /}"
            if [[ "$item" =~ ^[0-9]+$ ]] && (( item >= 1 && item <= ${#ports[@]} )); then
                sel+=("$((item - 1))")
            fi
        done
        IFS="$IFS_BAK"
    fi
    if (( ${#sel[@]} == 0 )); then
        warn "没有匹配的编号，未做任何替换"
        return 0
    fi

    local rc=0
    for i in "${sel[@]}"; do
        printf '\n'
        info "替换 ${modes[$i]}_${ports[$i]} 的伪装站…"
        node_retarget "${modes[$i]}" "${ports[$i]}" "$tgt" "$sni" auto || {
            warn "${modes[$i]}_${ports[$i]} 替换失败，已跳过"
            rc=1
        }
    done
    if (( rc == 0 )); then
        ok "已完成 ${#sel[@]} 个节点的伪装站替换"
    fi
    return "$rc"
}

# 交互式选择节点：列出编号 → 选中后把该节点的字段载入全局 MODE/PORT 等。
# 供菜单「编辑 / 删除节点」与不带参数的 `xhy del` 使用；取消返回 1。
node_pick() {
    local -a files=()
    local f i=0 pick
    for f in $(node_env_files); do
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

node_del() { config_transaction _node_del "$@"; }

_node_del() {
    local mode="$1" port="$2" envf
    envf="$(node_file "$mode" "$port")"
    [[ -f "$envf" ]] || die "节点不存在: ${mode}_${port}"
    need_root
    backup_file "$envf"
    snapshot_state          # before the registry changes: undoable delete
    rm -f "$envf" "$(node_frag "$mode" "$port")" || return 1
    if [[ "$mode" == "hy2" ]]; then
        rm -f "$XHY_CERTS/hy2_${port}.crt" "$XHY_CERTS/hy2_${port}.key"
        info "已清理该 Hysteria2 节点的自签证书"
    fi
    XHY_SKIP_SNAPSHOT=1 rebuild_config || return 1
    config_reload --validated || return 1
    if [[ "$(state_get FIREWALL_MODE off)" != "off" ]]; then
        firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet || return 1
    fi
    if [[ "$mode" == "tunnel" ]] && ! find "$XHY_NODES" -name 'tunnel_*.env' | grep -q .; then
        remove_cf_service
        rm -f "$XHY_ETC/tunnel.token"
        info "已无 tunnel 节点，cloudflared 服务与 token 已清理"
    fi
    ok "节点 ${mode}_${port} 已删除（凭据备份在 $XHY_BACKUP，可用 xhy snapshots 回滚整套状态）"
}

node_list() {
    local f mode port uuid sec created
    printf '%-10s %-7s %-6s %-38s %-10s %s\n' "模式" "端口" "公网" "UUID" "安全" "创建时间"
    printf '%s\n' "--------------------------------------------------------------------------------------------"
    for f in $(node_env_files); do
        [[ -f "$f" ]] || continue
        node_load "$f"
        printf '%-10s %-7s %-6s %-38s %-10s %s\n' \
            "$MODE" "$PORT" "$([[ "$PUBLIC" == 1 ]] && echo yes || echo no)" \
            "$UUID" "${SECURITY:-none}" "${CREATED:-?}"
    done
    (( $(node_count) > 0 )) || printf '(暂无节点)\n'
}

node_rebuild_all() { config_transaction _node_rebuild_all "$@"; }

_node_rebuild_all() {
    need_root
    init_dirs || return 1
    [[ "${XHY_SKIP_SNAPSHOT:-0}" == 1 ]] || snapshot_state
    render_registered_fragments || return 1
    XHY_SKIP_SNAPSHOT=1 rebuild_config || return 1
    config_reload --validated
}

render_registered_fragments() {
    local f
    while IFS= read -r f; do
        write_fragment "$f" || { err "重建 ${f##*/} 失败"; return 1; }
    done < <(node_env_files)
    relay_render_land
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

rollback_config() { config_transaction _rollback_config "$@"; }

_rollback_config() {
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
    rm -f "$XHY_NODES"/*.env "$XHY_CONFDIR"/*.json || return 1
    ( cd "$XHY_ETC" && tar xzf "$target" ) || die "快照解包失败，当前状态已另存为 $pre"
    chmod 700 "$XHY_NODES" "$XHY_CERTS" 2>/dev/null || true
    # Re-render every fragment from the restored registry, then validate and
    # reload. Older snapshots that still carry config.json are handled the same
    # way: the file is simply overwritten by the rebuild.
    XHY_SKIP_SNAPSHOT=1 node_rebuild_all || die "回滚后的配置校验失败（当前状态备份: $pre）"
    ok "已回滚整套状态到 $target（节点注册表、配置分片、证书均已恢复并重新渲染）"
}
