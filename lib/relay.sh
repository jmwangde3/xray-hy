#!/usr/bin/env bash
# xray-hy / relay —— 中转（relay）子命令：把「入口机」的 AI/美区流量，经 xray
# 路由转发到「落地机」出口，绕开直连公网绕路（如硅谷 TATA 绕欧洲）。
#
# 两种角色（同一台机器只扮其一）：
#   land  : 落地/接收端（例：硅谷 sanjose）。开一个 vless/tcp 入站，仅放行入口机
#           公网 IP，出站走默认 freedom（直连落地机本地出口）。
#   entry : 入口/转发端（例：东京 tokyo）。把 geosite(ai/美区)+geoip:us 的流量，
#           经 vless 出站转发到落地机的中继端口；其余海外流量本地 freedom 直出。
#
# 配置管线说明（重要，避免与 nodes.sh 冲突）：
#   - land 仅新增一个 confs/relay_in_<port>.json 入站片段，直接复用基础
#     rebuild_config（它把 confs/*.json 拼成 inbounds），不碰 nodes.sh。
#   - entry 需要自定义 outbounds + routing 规则，而基础 rebuild_config 的
#     outbounds/routing 由函数生成、不接受片段。为避免修改 nodes.sh（与「伪装站
#     TFO」开发会话冲突），这里用 relay_rebuild 本地重新拼装：调用基础 json 函数
#     + 注入 us-relay 出站与路由规则，零依赖（不靠 jq/python）。
#   - 限制：基础 rebuild_config 不含 relay。entry 激活后，若又跑 xhy add/del/edit
#     等触发基础 rebuild 的命令，relay 出站/路由会被覆盖；改完节点后跑
#     `xhy relay reapply` 重新注入即可。
#
# 状态存 $XHY_NODES/relay.env（与节点注册同目录，纳入快照）。

# 全局状态变量（relay_env_save 前由各子命令赋值）
RELAY_ROLE=""; RELAY_PORT=""; RELAY_ALLOW=""; RELAY_UUID=""
RELAY_UPSTREAM=""; RELAY_CATEGORIES=""; RELAY_FW_CHAIN=""

relay_reset_vars() {
    RELAY_ROLE=""; RELAY_PORT=""; RELAY_ALLOW=""; RELAY_UUID=""
    RELAY_UPSTREAM=""; RELAY_CATEGORIES=""; RELAY_FW_CHAIN=""
}

relay_env_save() {
    init_dirs
    local f="$XHY_NODES/relay.env"
    {
        [[ -n "$RELAY_ROLE" ]]       && echo "RELAY_ROLE=$RELAY_ROLE"
        [[ -n "$RELAY_PORT" ]]       && echo "RELAY_PORT=$RELAY_PORT"
        [[ -n "$RELAY_ALLOW" ]]      && echo "RELAY_ALLOW=$RELAY_ALLOW"
        [[ -n "$RELAY_UUID" ]]       && echo "RELAY_UUID=$RELAY_UUID"
        [[ -n "$RELAY_UPSTREAM" ]]   && echo "RELAY_UPSTREAM=$RELAY_UPSTREAM"
        [[ -n "$RELAY_CATEGORIES" ]] && echo "RELAY_CATEGORIES=$RELAY_CATEGORIES"
        [[ -n "$RELAY_FW_CHAIN" ]]   && echo "RELAY_FW_CHAIN=$RELAY_FW_CHAIN"
    } | atomic_write "$f" 0600
}

relay_env_load() {
    local f="$XHY_NODES/relay.env"
    [[ -f "$f" ]] || return 1
    # shellcheck disable=SC1090
    source "$f"
    [[ -n "$RELAY_ROLE" ]]
}

# 生成 land 入站片段（符合 confs/*.json 入站片段格式，被 rebuild_config 拼进 inbounds）
relay_fragment() {
    local port="$1" uuid="$2"
    cat <<EOF
{
  "listen": "0.0.0.0", "port": ${port}, "protocol": "vless",
  "tag": "in-relay-${port}",
  "settings": { "clients": [ { "id": "${uuid}" } ], "decryption": "none" },
  "streamSettings": { "network": "tcp", "security": "none" },
  "sniffing": {"enabled":true,"destOverride":["tls"],"routeOnly":true}
}
EOF
}

# entry 出站（转发到落地机中继端口）
relay_outbounds_json() {
    local up="$RELAY_UPSTREAM" host port
    host="${up%:*}"; port="${up##*:}"
    cat <<EOF
{"protocol":"vless","tag":"us-relay","settings":{"vnext":[{"address":"$host","port":$port,"users":[{"id":"$RELAY_UUID","encryption":"none"}]}]},"streamSettings":{"network":"tcp"}}
EOF
}

# entry 路由规则（注入到 routing.rules 数组最前面）。输出为「逗号分隔的 rule 对象」，无方括号
relay_routing_rules() {
    local cats="$RELAY_CATEGORIES" domains="" sep="" c
    for c in ${cats//,/ }; do
        domains+="$sep\"geosite:$c\""; sep=","
    done
    printf '%s' "{\"type\":\"field\",\"domain\":[$domains],\"outboundTag\":\"us-relay\"},{\"type\":\"field\",\"ip\":[\"geoip:us\"],\"outboundTag\":\"us-relay\"}"
}

# entry 专用重建：调用基础 json 函数 + 注入 relay 出站/路由
relay_rebuild() {
    local joined="" sep="" f
    init_dirs
    [[ "${XHY_SKIP_SNAPSHOT:-0}" == "1" ]] || snapshot_state
    for f in "$XHY_CONFDIR"/*.json; do
        [[ -s "$f" ]] || continue
        joined+="$sep$(cat "$f")"
        sep=","
    done
    # outbounds: 基础 [freedom,blackhole] + relay
    local ob="$(outbounds_json)"
    local ob_inner="${ob#\[}"; ob_inner="${ob_inner%\]}"
    local outbounds="[${ob_inner},$(relay_outbounds_json)]"
    # routing: 基础规则 + 前置 relay 规则
    local rt="$(routing_json)"
    local rt_rules="${rt#*\"rules\":\[}"; rt_rules="${rt_rules%\]*}"
    local new_rules
    if [[ -z "$rt_rules" ]]; then new_rules="$(relay_routing_rules)"
    else new_rules="$(relay_routing_rules),${rt_rules}"; fi
    local routing="{\"domainStrategy\":\"IPIfNonMatch\",\"rules\":[${new_rules}]}"
    {
        printf '{\n  "log": %s,\n' "$(log_json)"
        printf '  "inbounds": [%s],\n' "$joined"
        printf '  "dns": %s,\n' "$(dns_json)"
        printf '  "routing": %s,\n' "$routing"
        printf '  "outbounds": %s,\n' "$outbounds"
        printf '  "policy": %s\n}\n' "$(policy_json)"
    } | atomic_write "$XHY_ETC/config.json" 0600
    ok "配置已重建（含 relay 出站/路由）: $XHY_ETC/config.json"
}

relay_fw_add() {
    local port="$1" allow="$2" chain t
    t=iptables; [[ "$allow" == *:* ]] && t=ip6tables
    if $t -w -L XHY-IN -n >/dev/null 2>&1; then chain=XHY-IN; else chain=INPUT; fi
    $t -w -C "$chain" -p tcp --dport "$port" -s "$allow" -j ACCEPT 2>/dev/null \
        || $t -w -A "$chain" -p tcp --dport "$port" -s "$allow" -m comment --comment "xhy-relay-$port" -j ACCEPT
    RELAY_FW_CHAIN="$chain"
}

relay_fw_del() {
    local port="$1" allow="$2" chain="${3:-XHY-IN}" t
    t=iptables; [[ "$allow" == *:* ]] && t=ip6tables
    $t -w -D "$chain" -p tcp --dport "$port" -s "$allow" -m comment --comment "xhy-relay-$port" -j ACCEPT 2>/dev/null \
        || $t -w -D INPUT -p tcp --dport "$port" -s "$allow" -m comment --comment "xhy-relay-$port" -j ACCEPT 2>/dev/null \
        || true
}

relay_cfg_test() {
    if [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" run -test -c "$XHY_ETC/config.json" >/dev/null 2>&1; then
        ok "config.json 校验通过"
        return 0
    else
        warn "config.json 校验未通过（xray run -test 失败，检查片段 JSON）"
        return 1
    fi
}

# ---------------------------------------------------------------- 子命令

relay_land() {
    local port=14430 allow="" uuid=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)  port="$2"; shift 2 ;;
            --allow) allow="$2"; shift 2 ;;
            --uuid)  uuid="$2"; shift 2 ;;
            *) die "未知参数: $1（用法: xhy relay land [--port N] [--allow <入口机公网IP>] [--uuid UUID]）" ;;
        esac
    done
    relay_reset_vars
    valid_port "$port" || die "端口不合法: $port"
    port_busy "$port" && die "端口 $port 已被占用"
    [[ -z "$allow" ]] && die "缺少 --allow <入口机公网IP>：落地端只放行该 IP 到中继端口"
    [[ -z "$uuid" ]] && uuid="$(uuid_gen)"
    disk_need 1 "中继入站配置"
    relay_fragment "$port" "$uuid" | atomic_write "$XHY_CONFDIR/relay_in_${port}.json" 0644
    relay_fw_add "$port" "$allow"
    rebuild_config
    RELAY_ROLE=land
    RELAY_PORT="$port"
    RELAY_ALLOW="$allow"
    RELAY_UUID="$uuid"
    RELAY_FW_CHAIN="$RELAY_FW_CHAIN"
    relay_env_save
    relay_cfg_test
    local myip="$(public_ip)"
    ok "中继入站已就绪：${myip}:$port（仅放行 $allow）"
    info "把同一 UUID 带到入口机执行："
    printf '    xhy relay entry --to %s:%s --uuid %s\n' "$myip" "$port" "$uuid"
    printf 'vless://%s@%s:%s?encryption=none#relay-land\n' "$uuid" "$myip" "$port"
}

relay_entry() {
    local upstream="" uuid="" categories="openai,anthropic,google,tiktok,netflix"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to) upstream="$2"; shift 2 ;;
            --uuid) uuid="$2"; shift 2 ;;
            --categories) categories="$2"; shift 2 ;;
            *) die "未知参数: $1（用法: xhy relay entry --to <落地IP>:<端口> [--uuid UUID] [--categories a,b,c]）" ;;
        esac
    done
    relay_reset_vars
    [[ "$upstream" == *:* ]] || die "缺少 --to <落地机公网IP>:<端口>"
    [[ -z "$uuid" ]] && uuid="$(uuid_gen)"
    local host="${upstream%:*}" p="${upstream##*:}"
    valid_port "$p" || die "端口不合法: $p"
    disk_need 1 "中继出站配置"
    RELAY_ROLE=entry
    RELAY_UPSTREAM="$upstream"
    RELAY_UUID="$uuid"
    RELAY_CATEGORIES="$categories"
    relay_env_save
    relay_rebuild
    relay_cfg_test
    ok "中继出站已就绪：美区/AI 流量 → $upstream"
    info "落地端用同一 UUID 配置：xhy relay land --allow <本机公网IP> --uuid $uuid"
}

relay_reapply() {
    relay_env_load || die "本机未配置 relay（先跑 xhy relay entry）"
    [[ "$RELAY_ROLE" == "entry" ]] || die "只有入口机需要 reapply"
    relay_rebuild
    ok "已重新注入 relay 出站/路由"
}

relay_status() {
    relay_env_load || { info "本机未配置 relay"; return 0; }
    case "$RELAY_ROLE" in
        land)
            info "角色: 落地(接收端)  端口=$RELAY_PORT  放行源=$RELAY_ALLOW  UUID=$RELAY_UUID"
            ss -H -ltn 2>/dev/null | grep -qE "[:.]${RELAY_PORT}$" && ok "端口 $RELAY_PORT 监听中" || warn "端口 $RELAY_PORT 未监听" ;;
        entry)
            info "角色: 入口(转发端)  落地=$RELAY_UPSTREAM  UUID=$RELAY_UUID  分类=$RELAY_CATEGORIES"
            relay_cfg_test >/dev/null 2>&1 && ok "config.json 含 relay 出站/路由" || warn "config.json 未含 relay（跑 xhy relay reapply）" ;;
    esac
}

relay_test() {
    relay_env_load || { info "本机未配置 relay，无法测试"; return 0; }
    relay_cfg_test || warn "配置校验失败"
    if [[ "$RELAY_ROLE" == "land" ]]; then
        local t=iptables; [[ "$RELAY_ALLOW" == *:* ]] && t=ip6tables
        $t -w -C "${RELAY_FW_CHAIN:-XHY-IN}" -p tcp --dport "$RELAY_PORT" -s "$RELAY_ALLOW" -j ACCEPT >/dev/null 2>&1 \
            && ok "防火墙已放行 $RELAY_ALLOW → :$RELAY_PORT" || warn "防火墙规则缺失"
        ss -H -ltn 2>/dev/null | grep -qE "[:.]${RELAY_PORT}$" && ok "中继端口监听中" || warn "中继端口未监听"
        info "从入口机执行 xhy relay test，并视需要 curl 经本机出口验证"
    else
        local host="${RELAY_UPSTREAM%:*}" p="${RELAY_UPSTREAM##*:}"
        if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$host/$p" 2>/dev/null; then
            ok "入口机能 TCP 连通落地端 $RELAY_UPSTREAM"
        else
            warn "入口机无法 TCP 连通落地端 $RELAY_UPSTREAM（检查落地端防火墙/端口）"
        fi
        info "最终验证：客户端走入口机访问 ipinfo.io 应显示落地端所在地区 IP"
    fi
}

relay_del() {
    relay_env_load || { info "本机无 relay 配置"; return 0; }
    if [[ "$RELAY_ROLE" == "land" ]]; then
        rm -f "$XHY_CONFDIR/relay_in_${RELAY_PORT}.json"
        relay_fw_del "$RELAY_PORT" "$RELAY_ALLOW" "${RELAY_FW_CHAIN:-XHY-IN}"
        rebuild_config
        rm -f "$XHY_NODES/relay.env"
        ok "落地端中继已移除（片段+防火墙+重建）"
    else
        rm -f "$XHY_NODES/relay.env"
        rebuild_config
        ok "入口端 relay 已移除（恢复基础路由）"
    fi
}

cmd_relay() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        land)    relay_land "$@" ;;
        entry)   relay_entry "$@" ;;
        reapply) relay_reapply "$@" ;;
        status)  relay_status "$@" ;;
        test)    relay_test "$@" ;;
        del)     relay_del "$@" ;;
        *)       die "用法: xhy relay <land|entry|reapply|status|test|del>" ;;
    esac
}
