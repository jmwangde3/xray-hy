#!/usr/bin/env bash
# xray-hy / relay —— 中转（relay）子命令：把「入口机」的 AI / 美区流量，经 xray
# 路由转发到「落地机」出口，绕开直连公网绕路（例：硅谷回程 TATA 绕欧洲 235ms，
# 东京回程 56ms，东京→硅谷走阿里云骨干 107ms）。
#
# 两种角色（同一台机器只扮其一）：
#   land  : 落地/接收端（例：硅谷）。开一个 vless/tcp 入站，仅放行入口机公网 IP，
#           出站走默认 freedom（直连落地机本地出口）。
#   entry : 入口/转发端（例：东京）。把 geosite(AI/美区) + 可选 geoip:us 的流量，
#           经 vless 出站转发到落地机的中继端口；其余海外流量本地 freedom 直出。
#
# 配置管线（v1.9.4 重构，重要）：
#   - 两角色都只走**同一个** rebuild_config。nodes.sh 里留了两个空钩子
#     `extra_outbounds_json` / `extra_routing_rules_json`，本文件覆盖它们：
#     entry 角色激活时自动追加 us-relay 出站与前置路由规则，其他情况恒为空，
#     既有输出逐字节不变。
#   - 好处：xhy add / edit / del / config set 触发的基础 rebuild **不再覆盖**
#     relay（v1.9.3 及以前的已知限制 1 就是这个），不需要每次手动 reapply。
#   - land 只需要一个入站片段 confs/relay_in_<port>.json，天然被基础管线捡走。
#   - 纯 bash 字符串拼接，零外部依赖（Alpine 上不一定有 jq/python）。
#
# 状态存 $XHY_NODES/relay.env（0600，与节点注册同目录，纳入快照）。

RELAY_DEFAULT_PORT=14430
RELAY_DEFAULT_CATEGORIES="openai,anthropic,google,tiktok,netflix"
RELAY_DEFAULT_TAG="us-relay"

# 落地失联自动回落（v1.11.0）：balancer 由 burstObservatory 探活，落地机不可达
# 时把命中中继规则的连接交给 direct 出站，而不是黑洞掉。宁可拿到东京 IP，
# 也别让家里的 AI 流量静默全断。
RELAY_FALLBACK_DEFAULT="on"
RELAY_PROBE_URL_DEFAULT="https://www.gstatic.com/generate_204"
RELAY_PROBE_INTERVAL_DEFAULT="1m"
RELAY_PROBE_SAMPLING_DEFAULT="3"
RELAY_PROBE_TIMEOUT_DEFAULT="5s"

# 全局状态（relay_env_save 之前由各子命令赋值；relay_env_load 从文件读回）
RELAY_ROLE=""; RELAY_PORT=""; RELAY_ALLOW=""; RELAY_UUID=""
RELAY_UPSTREAM=""; RELAY_CATEGORIES=""; RELAY_FW_CHAIN=""
RELAY_SECURITY=""; RELAY_SNI=""; RELAY_PIN=""
RELAY_CERT=""; RELAY_KEY=""; RELAY_GEOIP_US=""; RELAY_TAG=""
RELAY_FALLBACK=""; RELAY_TFO=""

relay_reset_vars() {
    RELAY_ROLE=""; RELAY_PORT=""; RELAY_ALLOW=""; RELAY_UUID=""
    RELAY_UPSTREAM=""; RELAY_CATEGORIES=""; RELAY_FW_CHAIN=""
    RELAY_SECURITY=""; RELAY_SNI=""; RELAY_PIN=""
    RELAY_CERT=""; RELAY_KEY=""; RELAY_GEOIP_US=""; RELAY_TAG=""
    RELAY_FALLBACK=""; RELAY_TFO=""
}

# ---------------------------------------------------------------------------
# 输出：自带双语句对
#
# i18n 的 en 模式是「中文短语 → 英文短语」的整句替换 + 非 ASCII 抹成空格。
# 没有词条的新句子会被**整句吃掉变空白**（relay 第一版在 XHY_LANG=en 的机器上
# 就是这个表现）。这里不往共用词表里塞长句（词表按长词优先匹配，新整句容易和
# 旧词条互相吞），改为每条消息就地给中英两份，按当前语言选一份。
# ---------------------------------------------------------------------------
relay_say() {
    local lvl="$1" zh="$2" en="${3:-$2}" s
    if [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]]; then s="$en"; else s="$zh"; fi
    case "$lvl" in
        ok)   ok "$s" ;;
        warn) warn "$s" ;;
        err)  err "$s" ;;
        *)    info "$s" ;;
    esac
}

relay_usage() {
    if [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]]; then
        cat <<'EOF'
Usage: xhy relay <command> [options]

  land     Open a landing (receiving) inbound on this host.
           xhy relay land --allow <entry-public-ip> [--port 14430] [--uuid UUID]
                          [--tls] [--tls-cert FILE --tls-key FILE] [--sni NAME] [--ip ADDR]
  entry    Forward AI/US traffic to the landing host.
           xhy relay entry --to <land-ip>:<port> [--uuid UUID]
                          [--categories a,b,c|ai|media|none] [--no-geoip-us]
                          [--tls] [--sni NAME] [--pin HEX] [--tag TAG]
                          [--no-fallback] [--no-tfo]
  reapply  Re-inject after the config was rebuilt / restored from a snapshot.
  status   Show this host's role, port, upstream and live checks.
  test     Self-check: config shape, listening port, firewall rule, TCP reachability.
  export   Print the command to run on the peer host (and a vless:// link).
  del      Remove this host's relay config, firewall rule and fragment.

Defaults: port 14430, categories openai,anthropic,google,tiktok,netflix, tag us-relay.
Transport: security=none, always. Both ends are yours and this hop runs on the cloud
           backbone; client-to-site TLS is already end-to-end, so a second TLS layer
           only costs a handshake per connection and one AES pass per byte on the land.
           --tls/--sni/--pin are retired no-ops, kept only for script compatibility.
Fallback: on by default. A balancer probes the landing host every 60s and switches
          to direct when it is unreachable. --no-fallback restores the old hard pin.
Cloud security group: allow TCP <port> from the entry IP only (iptables is not enough).
EOF
        return 0
    fi
    cat <<'EOF'
用法: xhy relay <子命令> [选项]

  land     在本机开落地（接收）入站。只放行入口机 IP。
           xhy relay land --allow <入口机公网IP> [--port 14430] [--uuid UUID]
                          [--tls] [--tls-cert FILE --tls-key FILE] [--sni NAME] [--ip ADDR]
  entry    把 AI / 美区流量转发到落地机。
           xhy relay entry --to <落地机IP>:<端口> [--uuid UUID]
                          [--categories a,b,c|ai|media|none] [--no-geoip-us]
                          [--tls] [--sni NAME] [--pin HEX] [--tag TAG]
                          [--no-fallback] [--no-tfo]
  reapply  配置被重建 / 从快照还原后重新注入（改造后一般用不到了，留作兜底）
  status   看本机角色、端口、上游与实时检查
  test     自检：配置形状、端口监听、防火墙规则、TCP 连通性与往返耗时
  export   打印对端要执行的那条命令（以及 vless:// 链接）
  del      移除本机 relay 配置、防火墙规则、入站片段

默认值：端口 14430、分类 openai,anthropic,google,tiktok,netflix、出站标签 us-relay。
传输：security=none，恒明文。两端自有、走云内网，客户端到目标站的 TLS 已端到端，
      再套一层只多一次握手 + 落地机每字节一遍 AES，还多四个故障面。
      --tls / --sni / --pin 已停用，只保留参数位以免老脚本报错。
回落：默认开。balancer 每 60s 探活落地机，不可达时切 direct 出站，
      不会让 AI 分类流量静默黑洞。--no-fallback 回到 v1.10.x 的死指行为。
云安全组要单独放行：入方向 TCP <端口>，源只填入口机 IP（只改 iptables 不够）。
EOF
}

# ---------------------------------------------------------------------------
# 状态文件
# ---------------------------------------------------------------------------
relay_env_save() {
    init_dirs
    {
        printf 'RELAY_ROLE=%s\n' "$RELAY_ROLE"
        [[ -n "$RELAY_PORT" ]]       && printf 'RELAY_PORT=%s\n' "$RELAY_PORT"
        [[ -n "$RELAY_ALLOW" ]]      && printf 'RELAY_ALLOW=%s\n' "$RELAY_ALLOW"
        [[ -n "$RELAY_UUID" ]]       && printf 'RELAY_UUID=%s\n' "$RELAY_UUID"
        [[ -n "$RELAY_UPSTREAM" ]]   && printf 'RELAY_UPSTREAM=%s\n' "$RELAY_UPSTREAM"
        [[ -n "$RELAY_CATEGORIES" ]] && printf 'RELAY_CATEGORIES=%s\n' "$RELAY_CATEGORIES"
        [[ -n "$RELAY_FW_CHAIN" ]]   && printf 'RELAY_FW_CHAIN=%s\n' "$RELAY_FW_CHAIN"
        [[ -n "$RELAY_SECURITY" ]]   && printf 'RELAY_SECURITY=%s\n' "$RELAY_SECURITY"
        [[ -n "$RELAY_SNI" ]]        && printf 'RELAY_SNI=%s\n' "$RELAY_SNI"
        [[ -n "$RELAY_PIN" ]]        && printf 'RELAY_PIN=%s\n' "$RELAY_PIN"
        [[ -n "$RELAY_CERT" ]]       && printf 'RELAY_CERT=%s\n' "$RELAY_CERT"
        [[ -n "$RELAY_KEY" ]]        && printf 'RELAY_KEY=%s\n' "$RELAY_KEY"
        [[ -n "$RELAY_GEOIP_US" ]]   && printf 'RELAY_GEOIP_US=%s\n' "$RELAY_GEOIP_US"
        [[ -n "$RELAY_TAG" ]]        && printf 'RELAY_TAG=%s\n' "$RELAY_TAG"
        [[ -n "$RELAY_FALLBACK" ]]   && printf 'RELAY_FALLBACK=%s\n' "$RELAY_FALLBACK"
        [[ -n "$RELAY_TFO" ]]        && printf 'RELAY_TFO=%s\n' "$RELAY_TFO"
    } | atomic_write "$XHY_NODES/relay.env" 0600 || return 1
    return 0
}

# 每次都真读文件：rebuild_config 的钩子会调它，而 relay_del 会先删文件再重建，
# 一旦做了缓存，删完还会拿旧值注入出一条指向已删端口的出站。
relay_env_load() {
    local f="$XHY_NODES/relay.env"
    [[ -f "$f" ]] || return 1
    # shellcheck disable=SC1090
    source "$f"
    [[ -n "$RELAY_ROLE" ]] || return 1
    # 从 v1.10.x 升级：老 relay.env 可能写着 security=tls + pin + 证书路径。
    # 这一版起恒明文，读的时候就地把这些字段降级，老机器不用重配，
    # config.json 也不会再产出任何 tlsSettings。
    RELAY_SECURITY="none"
    RELAY_SNI=""; RELAY_PIN=""; RELAY_CERT=""; RELAY_KEY=""
    return 0
}

# ---------------------------------------------------------------------------
# 解析与校验
# ---------------------------------------------------------------------------

# 1.2.3.4:14430 / [2001:db8::1]:14430 → 输出 "host port"；不合法返回 1。
# 无方括号的裸 IPv6 有歧义（段里全是冒号），要求加方括号。
relay_split_upstream() {
    local up="${1:-}" h p
    [[ -n "$up" ]] || return 1
    if [[ "$up" == \[*\]:* ]]; then
        h="${up#[}"; h="${h%%]*}"
        p="${up##*]:}"
    elif [[ "$up" == *:* && "${up%:*}" != *:* ]]; then
        h="${up%:*}"; p="${up##*:}"
    else
        return 1
    fi
    [[ -n "$h" && -n "$p" ]] || return 1
    printf '%s %s' "$h" "$p"
}

relay_valid_host() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._:-]+$ ]]
}

# 分类名直接拼进 geosite:<name> 和 JSON，必须限定字符集，否则一个引号就能把
# 配置写坏（JSON 直接非法，xray 起不来）。
relay_norm_categories() {
    local in="${1:-}" c out="" seen=" "
    # 预设，省得每次手打一长串
    case "$in" in
        default|"") in="$RELAY_DEFAULT_CATEGORIES" ;;
        ai)         in="openai,anthropic,google" ;;
        media)      in="netflix,tiktok,youtube" ;;
        none)       in="" ;;
    esac
    for c in ${in//,/ }; do
        if [[ ! "$c" =~ ^[A-Za-z0-9_-]+$ ]]; then
            relay_say err "分类名不合法：$c（只允许字母数字下划线连字符）" \
                         "invalid category: $c (letters, digits, _ and - only)"
            return 1
        fi
        [[ "$seen" == *" $c "* ]] && continue
        seen+="$c "
        out+="${out:+,}$c"
    done
    printf '%s' "$out"
}

relay_out_tag() { printf '%s' "${RELAY_TAG:-$RELAY_DEFAULT_TAG}"; }

# ---------------------------------------------------------------------------
# JSON 片段
# ---------------------------------------------------------------------------

# 证书 pin 统一成小写 64 位 hex：Xray 26.x 的 pinnedPeerCertSha256 只吃 hex。
# 入参可以是 hex（大小写均可，含冒号分隔的都认）或旧版的 base64；空入参返回空。
relay_pin_hex() {
    local pin="${1:-}" hex
    pin="${pin//[[:space:]]/}"; pin="${pin//:/}"
    [[ -n "$pin" ]] || return 0
    if [[ "$pin" =~ ^[0-9a-fA-F]{64}$ ]]; then
        printf '%s' "${pin,,}"
        return 0
    fi
    hex="$(printf '%s' "$pin" | base64 -d 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n' || true)"
    if [[ ! "$hex" =~ ^[0-9a-f]{64}$ ]]; then
        relay_say err "证书 pin 无法识别（要 64 位 hex，或旧版 base64）：${pin:0:16}…" \
                      "unrecognised certificate pin (want 64 hex chars, or legacy base64)"
        return 1
    fi
    printf '%s' "$hex"
}

# ---------------------------------------------------------------------------
# v1.11.0 起：中继这一跳恒为明文（security=none），两端 security 一律不写 tls。
#
# 理由：两端都是自己的机器、这一跳走云厂商跨地域内网。客户端到目标站的 TLS
# 本来就是端到端的（落地机只转密文），中间再套一层 TLS 防的是一个拿不到骨干
# 设备的中间人，却要每条新连接多一次 TLS 握手、落地机每字节一遍 AES-GCM，
# 还平白多出证书过期 / SAN 不匹配 / pin 对不上 / SNI 写错四个故障面。
#
# 下面的 TLS 生成函数（relay_pin_hex / relay_tls_ensure / relay_tls_pin_of）
# 保留但不接入：将来若这一跳改成跨公网、或落地机不是自己的，恢复这两个
# stream 函数里的调用点即可，不用重写。--tls 等参数也保留为兼容占位。
# ---------------------------------------------------------------------------

# $1 = 上游地址（保留参数，明文模式下不再用于 SNI）
relay_stream_client_json() {
    printf '{"network":"tcp","security":"none"}'
}

relay_stream_server_json() {
    printf '{"network":"tcp","security":"none"}'
}

# land 入站片段（一个标准 inbound 对象，被 rebuild_config 拼进 inbounds）
#
# v1.11.2：入站必须和出站一样带 sockopt。内核 net.ipv4.tcp_fastopen=3 只是允许位
# （bit0=client / bit1=server），服务端真正的开关是 listen socket 上的
# setsockopt(TCP_FASTOPEN, qlen)。之前只有 entry 出站写了 tcpFastOpen:true，
# land 入站没写 → 东京发 TFO SYN（带 early data / cookie req），硅谷 listener
# 按普通三次握手处理，early data 被丢弃，实测 TcpExtTCPFastOpenPassive=0 /
# TCPFastOpenActive=0 —— 这一跳的 TFO 全程没生效，省不到那一个 107 ms RTT。
# 两端都是自有机器，不存在「伪装站不支持被动 TFO」的兼容问题，故默认恒开，
# 与 relay_sockopt_json 共用同一套开关（--no-tfo / RELAY_TFO=off 可关）。
relay_fragment() {
    local port="$1" uuid="$2" stream so
    stream="$(relay_stream_server_json)"
    so="$(relay_sockopt_json)"
    cat <<EOF
{
  "listen": "$(listen_addr)", "port": ${port}, "protocol": "vless",
  "tag": "in-relay-${port}",
  "settings": { "clients": [ { "id": "${uuid}" } ], "decryption": "none" },
  "streamSettings": ${stream},
  "sockopt":${so}
}
EOF
}

# 中继这一跳的两端都是自己的机器，TFO 不存在「伪装站不支持」的兼容问题，
# 默认打开：省掉每条新连接的一次 TCP 握手往返。BBR 跟随系统是否可用。
relay_sockopt_json() {
    local tfo="true" cc=""
    if [[ "${RELAY_TFO:-on}" == "off" ]]; then tfo="false"; fi
    if declare -F sockopt_cc_available >/dev/null 2>&1 && sockopt_cc_available; then
        cc=',"tcpcongestion":"bbr"'
    fi
    printf '{"tcpFastOpen":%s,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpMptcp":false%s}' "$tfo" "$cc"
}

# entry 出站（转发到落地机中继端口）
relay_outbound_json() {
    local hp host port ss so
    hp="$(relay_split_upstream "$RELAY_UPSTREAM")" || return 1
    host="${hp% *}"; port="${hp##* }"
    [[ "$host" == "$RELAY_UPSTREAM" ]] && return 1
    # 流传输片段单独取，失败就别产出半截 JSON（坏 JSON 会让 xray 起不来）
    ss="$(relay_stream_client_json "$host")" || { relay_say err "中继出站片段生成失败" "failed to build relay outbound stream"; return 1; }
    so="$(relay_sockopt_json)"
    printf '{"protocol":"vless","tag":"%s","settings":{"vnext":[{"address":"%s","port":%s,"users":[{"id":"%s","encryption":"none"}]}]},"streamSettings":%s,"sockopt":%s}' \
        "$(relay_out_tag)" "$host" "$port" "$RELAY_UUID" "$ss" "$so"
}

# ---------------------------------------------------------------------------
# 失联回落（v1.11.0）
#
# 原方案的问题：路由规则死指 us-relay，落地机一挂，AI 分类流量直接黑洞 ——
# 既不报错也不切走，家里只会看到「网卡住了」。这里给 balancer 配 fallback，
# 由 burstObservatory 定时探活，候选全部 down 时交给 direct 出站。
#
# 为什么 leastPing 而不是 leastLoad：候选只有一个，leastLoad 的负载窗口在
# 单节点上没有意义；leastPing 的语义（探活失败即剔除）正是要的。
# ---------------------------------------------------------------------------
relay_fallback_on() {
    [[ "${RELAY_FALLBACK:-$RELAY_FALLBACK_DEFAULT}" != "off" ]]
}

relay_lb_tag() { printf '%s-lb' "$(relay_out_tag)"; }

# 路由规则该指向谁：开了回落指向 balancer，关掉直接指出站（v1.10.x 行为）
relay_target_tag() {
    if relay_fallback_on; then relay_lb_tag; else relay_out_tag; fi
}

# entry 路由规则：输出「逗号分隔的 rule 对象」，无外层方括号（钩子约定）。
# 顺序有意义：域名规则在前、geoip:us 在后，域名命中就不再解析 IP。
relay_routing_rules_json() {
    local c out="" doms="" sep="" tgt key
    tgt="$(relay_target_tag)"
    # Xray 26.x：routing 规则指向 balancer 必须用 balancerTag；写成 outboundTag
    # 会被 dispatcher 当成一个不存在的出站（non existing outTag: us-relay-lb）
    # 直接丢包，AI 分类流量全 000。回落关掉时指裸出站，仍用 outboundTag。
    key="outboundTag"
    if relay_fallback_on; then key="balancerTag"; fi
    for c in ${RELAY_CATEGORIES//,/ }; do
        [[ -n "$c" ]] || continue
        doms+="${sep}\"geosite:${c}\""; sep=","
    done
    if [[ -n "$doms" ]]; then
        out="{\"type\":\"field\",\"domain\":[${doms}],\"${key}\":\"${tgt}\"}"
    fi
    if [[ "${RELAY_GEOIP_US:-on}" != "off" ]]; then
        [[ -n "$out" ]] && out+=","
        out+="{\"type\":\"field\",\"ip\":[\"geoip:us\"],\"${key}\":\"${tgt}\"}"
    fi
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 覆盖 nodes.sh 的空钩子：只有 entry 角色且状态完整时才注入
# ---------------------------------------------------------------------------
relay_entry_active() {
    relay_env_load || return 1
    [[ "$RELAY_ROLE" == "entry" ]] || return 1
    [[ -n "$RELAY_UPSTREAM" && -n "$RELAY_UUID" ]]
}

extra_outbounds_json() {
    relay_entry_active || return 0
    relay_outbound_json
}

extra_routing_rules_json() {
    relay_entry_active || return 0
    relay_routing_rules_json
}

# routing 对象内、rules 之前：balancer 定义
extra_routing_head_json() {
    relay_entry_active || return 0
    relay_fallback_on || return 0
    printf '"balancers":[{"tag":"%s","selector":["%s"],"fallbackTag":"direct","strategy":{"type":"leastPing"}}]' \
        "$(relay_lb_tag)" "$(relay_out_tag)"
}

# 顶层：探活器。探测目标必须选一个「从落地机看一定可达」的 204 端点，
# gstatic 的 generate_204 是最省流量的通用选择，且不依赖落地机所在地区。
extra_top_json() {
    relay_entry_active || return 0
    relay_fallback_on || return 0
    printf '"burstObservatory":{"subjectSelector":["%s"],"pingConfig":{"destination":"%s","interval":"%s","sampling":%s,"timeout":"%s"}}' \
        "$(relay_out_tag)" \
        "${RELAY_PROBE_URL:-$RELAY_PROBE_URL_DEFAULT}" \
        "${RELAY_PROBE_INTERVAL:-$RELAY_PROBE_INTERVAL_DEFAULT}" \
        "${RELAY_PROBE_SAMPLING:-$RELAY_PROBE_SAMPLING_DEFAULT}" \
        "${RELAY_PROBE_TIMEOUT:-$RELAY_PROBE_TIMEOUT_DEFAULT}"
}

# ---------------------------------------------------------------------------
# 应用（重建 + 校验 + 热重载）
# ---------------------------------------------------------------------------

# 注意：v1.9.3 及以前 relay 只 rebuild、不 reload —— 配置写进文件但**没生效**，
# 必须手工 xhy service restart 才通。这里统一走 config_reload。
relay_apply() {
    XHY_SKIP_SNAPSHOT=1 rebuild_config || return 1
    if ! xray_config_test >/dev/null 2>&1; then
        xray_config_test || true
        relay_say err "配置校验失败，未重启服务（先看上面的报错）" \
                     "config test failed; service not restarted"
        return 1
    fi
    config_reload || return 1
    return 0
}

# 兼容旧文档 / 旧脚本里的调用名
relay_rebuild() { relay_apply; }

relay_cfg_test() {
    if xray_config_test >/dev/null 2>&1; then
        relay_say ok "config.json 校验通过" "config.json OK"
        return 0
    fi
    relay_say warn "config.json 校验未通过（看 xhy relay test 的具体报错）" \
                  "config.json failed validation (see xhy relay test)"
    return 1
}

relay_config_has() { grep -q -- "$1" "$XHY_ETC/config.json" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 防火墙（只做本机 iptables；云安全组要另外开）
# ---------------------------------------------------------------------------
relay_fw_chain() {
    local t="$1"
    if $t -w -L "${FW_CHAIN:-XHY-IN}" -n >/dev/null 2>&1; then
        printf '%s' "${FW_CHAIN:-XHY-IN}"
    else
        printf 'INPUT'
    fi
}

relay_fw_add() {
    local port="$1" allow="$2" t chain
    t=iptables; [[ "$allow" == *:* ]] && t=ip6tables
    chain="$(relay_fw_chain "$t")"
    # 带 comment 一起比对：只比「端口+源」的话，一条别人加的同类规则会让 -C 命中，
    # 于是我们这条带注释的规则永远加不上，之后 relay_del 按注释删也删不掉。
    $t -w -C "$chain" -p tcp --dport "$port" -s "$allow" \
        -m comment --comment "xhy-relay-$port" -j ACCEPT 2>/dev/null && {
        printf '%s' "$chain"; return 0; }
    $t -w -A "$chain" -p tcp --dport "$port" -s "$allow" \
        -m comment --comment "xhy-relay-$port" -j ACCEPT 2>/dev/null \
        || { relay_say warn "防火墙规则写入失败（$t $chain）" "failed to add firewall rule ($t $chain)"; return 1; }
    printf '%s' "$chain"
}

relay_fw_del() {
    local port="$1" allow="$2" chain="${3:-}" t
    [[ -n "$port" && -n "$allow" ]] || return 0
    t=iptables; [[ "$allow" == *:* ]] && t=ip6tables
    local c
    for c in "$chain" "${FW_CHAIN:-XHY-IN}" INPUT; do
        [[ -n "$c" ]] || continue
        $t -w -D "$c" -p tcp --dport "$port" -s "$allow" \
            -m comment --comment "xhy-relay-$port" -j ACCEPT 2>/dev/null && return 0
    done
    return 0
}

relay_fw_present() {
    local port="$1" allow="$2" t chain
    t=iptables; [[ "$allow" == *:* ]] && t=ip6tables
    chain="${RELAY_FW_CHAIN:-$(relay_fw_chain "$t")}"
    $t -w -C "$chain" -p tcp --dport "$port" -s "$allow" \
        -m comment --comment "xhy-relay-$port" -j ACCEPT >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# TLS（可选）：自签证书 + 证书链 pin
#
# 不加 TLS 时是明文 vless，安全性完全靠「只放行入口机 IP」；跨公网 + 换 IP 就
# 裸奔。加 TLS 后即使源 IP 限制被绕开，没有 pin 也连不上。
# ---------------------------------------------------------------------------
relay_tls_pin_of() {
    # Xray >= 26.x 的 pinnedPeerCertSha256 只吃「hex」，不是 base64。
    # 旧版用 base64 会导致 x509: certificate signed by unknown authority。
    local crt="$1" raw
    have_cmd openssl || return 1
    raw="$(openssl x509 -in "$crt" -outform DER 2>/dev/null \
        | openssl dgst -sha256 -hex 2>/dev/null)"
    [[ -n "$raw" ]] || return 1
    printf '%s' "${raw##* }" | tr -d '\r\n' | tr 'A-F' 'a-f'
}

relay_tls_ensure() {
    local port="$1" sni="$2" crt="${3:-}" key="${4:-}"
    if [[ -n "$crt" || -n "$key" ]]; then
        [[ -s "${crt:-/nonexistent}" && -s "${key:-/nonexistent}" ]] \
            || { relay_say err "--tls-cert / --tls-key 指向的文件不存在或为空" \
                               "--tls-cert / --tls-key file missing or empty"; return 1; }
        RELAY_CERT="$crt"; RELAY_KEY="$key"
        RELAY_SNI="${sni:-$(basename "$crt" .crt)}"
        return 0
    fi
    have_cmd openssl || {
        relay_say err "--tls 需要 openssl 生成自签证书（apk add openssl），或改用 --tls-cert/--tls-key 指定已有证书" \
                     "--tls needs openssl for a self-signed cert (apk add openssl), or pass --tls-cert/--tls-key"
        return 1; }
    init_dirs
    crt="$XHY_CERTS/relay_${port}.crt"
    key="$XHY_CERTS/relay_${port}.key"
    RELAY_SNI="${sni:-relay-${port}}"
    # 历史版本只写了 CN 没写 SAN，Go 1.27 / Xray 26.x 会直接拒
    # （x509: certificate relies on legacy Common Name field, use SANs instead）。
    # 遇到这种旧证书就地重签，别让用户手动删。
    if [[ -s "$crt" ]] && ! openssl x509 -in "$crt" -noout -text 2>/dev/null \
            | grep -q "Subject Alternative Name"; then
        relay_say info "旧证书缺 SAN，重签：$crt" "legacy cert lacks SAN, re-issuing: $crt"
        rm -f "$crt" "$key"
    fi
    if [[ ! -s "$crt" || ! -s "$key" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=${RELAY_SNI:-relay}" \
            -addext "subjectAltName=DNS:${RELAY_SNI:-relay}" \
            -keyout "$key" -out "$crt" >/dev/null 2>&1 \
            || { relay_say err "自签证书生成失败" "self-signed certificate generation failed"; return 1; }
        chmod 600 "$key" 2>/dev/null || true
        relay_say info "已生成自签证书：$crt" "generated self-signed cert: $crt"
    fi
    RELAY_CERT="$crt"; RELAY_KEY="$key"
    return 0
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

# 同机换角色时，把另一侧留下的东西清掉，免得 config 里同时挂着入站和出站。
# 片段一律按前缀扫：历史上手改过端口的话，只删「当前端口」会留下野片段。
relay_remove_fragments() {
    local f
    for f in "$XHY_CONFDIR"/relay_in_*.json; do
        [[ -f "$f" ]] || continue
        rm -f "$f"
    done
    return 0
}

relay_clean_land_state() {
    relay_remove_fragments
    [[ -n "$RELAY_PORT" && -n "$RELAY_ALLOW" ]] && relay_fw_del "$RELAY_PORT" "$RELAY_ALLOW" "$RELAY_FW_CHAIN"
    return 0
}

relay_port_owned() {
    [[ -f "$XHY_CONFDIR/relay_in_${1}.json" ]]
}

relay_land() {
    local port="$RELAY_DEFAULT_PORT" allow="" uuid="" tls=0 crt="" key="" sni="" myip=""
    while (( $# > 0 )); do
        case "$1" in
            --port)     (( $# >= 2 )) || die "--port 缺少参数"; port="$2"; shift 2 ;;
            --allow)    (( $# >= 2 )) || die "--allow 缺少参数"; allow="$2"; shift 2 ;;
            --uuid)     (( $# >= 2 )) || die "--uuid 缺少参数"; uuid="$2"; shift 2 ;;
            --ip)       (( $# >= 2 )) || die "--ip 缺少参数"; myip="$2"; shift 2 ;;
            --tls)      tls=1; shift ;;
            --tls-cert) (( $# >= 2 )) || die "--tls-cert 缺少参数"; crt="$2"; tls=1; shift 2 ;;
            --tls-key)  (( $# >= 2 )) || die "--tls-key 缺少参数"; key="$2"; tls=1; shift 2 ;;
            --sni)      (( $# >= 2 )) || die "--sni 缺少参数"; sni="$2"; shift 2 ;;
            -h|--help)  relay_usage; return 0 ;;
            *) die "未知参数: $1（xhy relay land --help 看用法）" ;;
        esac
    done
    need_root
    init_dirs
    valid_port "$port" || die "端口不合法: $port"
    [[ -n "$allow" ]] || die "缺少 --allow <入口机公网IP>：落地端只放行该 IP 到中继端口"
    relay_valid_host "$allow" || die "--allow 不是合法 IP: $allow"
    [[ -n "$uuid" ]] || uuid="$(uuid_gen)"
    [[ "$uuid" =~ ^[A-Za-z0-9-]+$ ]] || die "UUID 不合法: $uuid"

    # 同机换角色：先把 entry 的旧状态读出来，后面统一清
    relay_env_load >/dev/null 2>&1 || true
    local prev_role="${RELAY_ROLE:-}" prev_port="${RELAY_PORT:-}" prev_allow="${RELAY_ALLOW:-}"
    relay_reset_vars

    # 重新跑同一个 land（改 UUID / 加 TLS）时端口本来就是自己在听，别被 port_busy 挡住
    if port_busy "$port" && ! relay_port_owned "$port"; then
        die "端口 $port 已被占用（ss -lntp | grep $port 看是谁）"
    fi
    disk_need 1 "中继入站配置" || return 1

    [[ "${XHY_SKIP_SNAPSHOT:-0}" == "1" ]] || snapshot_state
    RELAY_ROLE=land
    RELAY_PORT="$port"
    RELAY_ALLOW="$allow"
    RELAY_UUID="$uuid"
    RELAY_CATEGORIES=""
    RELAY_UPSTREAM=""
    RELAY_GEOIP_US=""
    RELAY_TAG=""
    RELAY_SECURITY="none"
    if (( tls )); then
        relay_say warn "v1.11.0 起中继这一跳恒为明文，--tls 已停用（参数忽略）" \
                      "relay hop is always plaintext since v1.11.0; --tls retired (ignored)"
    fi

    # 旧 land 换了端口/UUID → 先删旧片段与旧规则；同端口则原地覆盖
    if [[ "$prev_role" == "land" && -n "$prev_port" && "$prev_port" != "$port" ]]; then
        rm -f "$XHY_CONFDIR/relay_in_${prev_port}.json"
        relay_fw_del "$prev_port" "$prev_allow" ""
    fi
    relay_fragment "$port" "$uuid" | atomic_write "$XHY_CONFDIR/relay_in_${port}.json" 0644 \
        || die "入站片段写入失败: $XHY_CONFDIR/relay_in_${port}.json"
    relay_fw_add "$port" "$allow" >/dev/null || true
    RELAY_FW_CHAIN="$(relay_fw_chain iptables)"

    relay_env_save || return 1
    relay_apply || return 1

    [[ -n "$myip" ]] || myip="$(public_ip)"
    relay_say ok "中继入站已就绪：${myip}:${port}（仅放行 ${allow}）" \
                "relay inbound ready: ${myip}:${port} (allow ${allow} only)"
    relay_say info "明文 vless（security=none）：两端自有、走云内网时推荐，省掉每条新连接一次 TLS 握手" \
                  "plaintext vless (security=none): recommended for owned-to-owned traffic on a cloud backbone; saves one TLS handshake per connection"
    relay_say info "云安全组记得放行：入方向 TCP ${port}，源 ${allow}/32" \
                  "also open the cloud security group: inbound TCP ${port} from ${allow}/32"
    relay_say info "把下面这条带到入口机执行：" "run this on the entry host:"
    relay_entry_hint "$myip"
    return 0
}

# 打印入口机该执行的命令（land 侧用）
relay_entry_hint() {
    local ip="$1"
    printf '    xhy relay entry --to %s:%s --uuid %s\n' "$ip" "$RELAY_PORT" "$RELAY_UUID"
    printf 'vless://%s@%s:%s?encryption=none&security=none&type=tcp#relay-land\n' \
        "$RELAY_UUID" "$ip" "$RELAY_PORT"
}

relay_entry() {
    local upstream="" uuid="" categories="" geoip="on" tls=0 sni="" pin="" tag="" fb="" tfo=""
    while (( $# > 0 )); do
        case "$1" in
            --to)         (( $# >= 2 )) || die "--to 缺少参数"; upstream="$2"; shift 2 ;;
            --uuid)       (( $# >= 2 )) || die "--uuid 缺少参数"; uuid="$2"; shift 2 ;;
            --categories) (( $# >= 2 )) || die "--categories 缺少参数"; categories="$2"; shift 2 ;;
            --geoip-us)   (( $# >= 2 )) || die "--geoip-us 缺少参数"; geoip="$2"; shift 2 ;;
            --no-geoip-us) geoip="off"; shift ;;
            --tls)        tls=1; shift ;;
            --sni)        (( $# >= 2 )) || die "--sni 缺少参数"; sni="$2"; shift 2 ;;
            --pin)        (( $# >= 2 )) || die "--pin 缺少参数"; pin="$2"; tls=1; shift 2 ;;
            --tag)        (( $# >= 2 )) || die "--tag 缺少参数"; tag="$2"; shift 2 ;;
            --fallback)   (( $# >= 2 )) || die "--fallback 缺少参数"; fb="$2"; shift 2 ;;
            --no-fallback) fb="off"; shift ;;
            --tfo)        (( $# >= 2 )) || die "--tfo 缺少参数"; tfo="$2"; shift 2 ;;
            --no-tfo)     tfo="off"; shift ;;
            -h|--help)    relay_usage; return 0 ;;
            *) die "未知参数: $1（xhy relay entry --help 看用法）" ;;
        esac
    done
    need_root
    init_dirs

    local hp host p
    hp="$(relay_split_upstream "$upstream")" \
        || die "--to 需要 <IP>:<端口>（IPv6 写成 [2001:db8::1]:14430）"
    host="${hp% *}"; p="${hp##* }"
    relay_valid_host "$host" || die "--to 地址不合法: $host"
    valid_port "$p" || die "端口不合法: $p"
    [[ -n "$uuid" ]] || uuid="$(uuid_gen)"
    [[ "$uuid" =~ ^[A-Za-z0-9-]+$ ]] || die "UUID 不合法: $uuid"
    categories="$(relay_norm_categories "${categories:-$RELAY_DEFAULT_CATEGORIES}")" || return 1
    [[ "$geoip" == "on" || "$geoip" == "off" ]] || die "--geoip-us 只接受 on / off"
    [[ -n "$tag" ]] && { relay_valid_host "$tag" || die "--tag 不合法: $tag"; }
    [[ -z "$fb" || "$fb" == "on" || "$fb" == "off" ]] || die "--fallback 只接受 on / off"

    # 同机原本是 land → 摘掉入站片段与防火墙规则（角色互斥）
    relay_env_load >/dev/null 2>&1 || true
    local prev_role="${RELAY_ROLE:-}" prev_port="${RELAY_PORT:-}" prev_allow="${RELAY_ALLOW:-}"
    relay_reset_vars
    if [[ "$prev_role" == "land" ]]; then
        relay_remove_fragments
        [[ -n "$prev_port" ]] && relay_fw_del "$prev_port" "$prev_allow" ""
        relay_say info "本机原为落地端，已移除入站片段与防火墙规则" \
                      "this host was a landing node; inbound fragment and firewall rule removed"
    fi
    disk_need 1 "中继出站配置" || return 1

    [[ "${XHY_SKIP_SNAPSHOT:-0}" == "1" ]] || snapshot_state
    RELAY_ROLE=entry
    RELAY_UPSTREAM="$upstream"
    RELAY_UUID="$uuid"
    RELAY_CATEGORIES="$categories"
    RELAY_GEOIP_US="$geoip"
    RELAY_TAG="$tag"
    RELAY_FALLBACK="${fb:-$RELAY_FALLBACK_DEFAULT}"
    RELAY_TFO="${tfo:-on}"
    RELAY_SECURITY="none"
    RELAY_SNI=""; RELAY_PIN=""; RELAY_CERT=""; RELAY_KEY=""
    if (( tls )); then
        relay_say warn "v1.11.0 起中继这一跳恒为明文，--tls / --sni / --pin 已停用（参数忽略）" \
                      "relay hop is always plaintext since v1.11.0; --tls/--sni/--pin retired (ignored)"
    fi
    relay_env_save || return 1
    relay_apply || return 1

    relay_say ok "中继出站已就绪：流量 → ${RELAY_UPSTREAM}" \
                "relay outbound ready: traffic -> ${RELAY_UPSTREAM}"
    relay_say info "分类=${categories:-无}  geoip:us=${geoip}  标签=$(relay_out_tag)" \
                  "categories=${categories:-none}  geoip:us=${geoip}  tag=$(relay_out_tag)"
    if relay_fallback_on; then
        relay_say info "失联回落已开：balancer $(relay_lb_tag) → direct（探活 ${RELAY_PROBE_INTERVAL:-$RELAY_PROBE_INTERVAL_DEFAULT}）" \
                      "fallback on: balancer $(relay_lb_tag) -> direct (probe ${RELAY_PROBE_INTERVAL:-$RELAY_PROBE_INTERVAL_DEFAULT})"
    else
        relay_say warn "失联回落已关：落地机不可达时这些流量直接断掉，不会切 direct" \
                      "fallback off: relayed traffic blacks out when the landing host is unreachable"
    fi
    relay_say info "这一跳恒为明文（security=none），无 TLS 握手 / 无 AES 开销" \
                  "hop is always plaintext (security=none); no TLS handshake, no AES overhead"
    relay_tcp_probe "$host" "$p" || true
    relay_say info "落地端用同一 UUID 配置：xhy relay land --allow <本机公网IP> --uuid $uuid" \
                  "configure the landing side with the same UUID: xhy relay land --allow <this-ip> --uuid $uuid"
    return 0
}

relay_export() {
    relay_env_load || die "本机未配置 relay（先跑 xhy relay land / entry）"
    if [[ "$RELAY_ROLE" == "land" ]]; then
        local ip; ip="$(public_ip)"
        relay_say info "在入口机执行：" "run on the entry host:"
        relay_entry_hint "$ip"
    else
        local allow lp
        allow="$(public_ip)"
        lp="${RELAY_UPSTREAM##*:}"
        relay_say info "在落地机执行（源 IP 用本机公网 IP）：" \
                      "run on the landing host (allow this host's public IP):"
        printf '    xhy relay land --allow %s --port %s --uuid %s\n' \
            "$allow" "$lp" "$RELAY_UUID"
        printf 'vless://%s@%s?encryption=none&security=none&type=tcp#relay-land\n' \
            "$RELAY_UUID" "$RELAY_UPSTREAM"
    fi
    return 0
}

relay_reapply() {
    relay_env_load || die "本机未配置 relay（先跑 xhy relay land / entry）"
    if [[ "$RELAY_ROLE" == "land" ]]; then
        local f="$XHY_CONFDIR/relay_in_${RELAY_PORT}.json"
        if [[ ! -f "$f" ]]; then
            relay_say info "入站片段缺失，按 relay.env 重建" "inbound fragment missing; re-rendering"
            relay_fragment "$RELAY_PORT" "$RELAY_UUID" | atomic_write "$f" 0644 \
                || die "片段写入失败: $f"
        fi
        relay_fw_add "$RELAY_PORT" "$RELAY_ALLOW" >/dev/null || true
    fi
    relay_apply || return 1
    relay_say ok "已重新注入并生效" "re-injected and reloaded"
    return 0
}

relay_port_listening() {
    local p="$1"
    if have_cmd ss; then
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    else
        return 1
    fi
}

# TCP 往返（毫秒）。连不上返回 1。只用于给个量级，不做精细基准。
relay_tcp_probe() {
    local host="$1" port="$2" t0 t1 ms
    [[ "${XHY_RELAY_NO_TCP:-0}" == "1" ]] && return 0
    t0="$(date +%s%N 2>/dev/null || echo 0)"
    if timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
        t1="$(date +%s%N 2>/dev/null || echo 0)"
        if [[ "$t0" != "0" && "$t1" != "0" ]]; then
            ms=$(( (t1 - t0) / 1000000 ))
            relay_say ok "TCP 连通 ${host}:${port}（握手往返 ${ms} ms）" \
                        "TCP reachable ${host}:${port} (${ms} ms handshake RTT)"
        else
            relay_say ok "TCP 连通 ${host}:${port}" "TCP reachable ${host}:${port}"
        fi
        return 0
    fi
    relay_say warn "连不上 ${host}:${port}：查落地端 firewall / 云安全组 / xray 是否在跑" \
                  "cannot reach ${host}:${port}: check landing firewall / security group / xray"
    return 1
}

relay_status() {
    local brief=0
    [[ "${1:-}" == "--brief" ]] && brief=1
    if ! relay_env_load; then
        [[ "$brief" == "1" ]] && return 0
        relay_say info "本机未配置 relay" "relay not configured on this host"
        return 0
    fi
    if [[ "$brief" == "1" ]]; then
        case "$RELAY_ROLE" in
            land)  printf 'relay     : land :%s ← %s\n' "$RELAY_PORT" "$RELAY_ALLOW" ;;
            entry) printf 'relay     : entry → %s（%s）\n' "$RELAY_UPSTREAM" "${RELAY_CATEGORIES:-仅 geoip:us}" ;;
        esac
        return 0
    fi
    case "$RELAY_ROLE" in
        land)
            relay_say info "角色: 落地端（接收）" "role: land (receiver)"
            printf '  端口   : %s\n' "$RELAY_PORT"
            printf '  放行源 : %s\n' "$RELAY_ALLOW"
            printf '  传输   : none（明文 vless）\n' 
            printf '  UUID   : %s\n' "$RELAY_UUID"
            relay_port_listening "$RELAY_PORT" && relay_say ok "端口 ${RELAY_PORT} 监听中" "port ${RELAY_PORT} listening" \
                || relay_say warn "端口 ${RELAY_PORT} 未监听" "port ${RELAY_PORT} not listening"
            relay_fw_present "$RELAY_PORT" "$RELAY_ALLOW" && relay_say ok "防火墙已放行 ${RELAY_ALLOW}" "firewall allows ${RELAY_ALLOW}" \
                || relay_say warn "防火墙规则缺失（xhy relay reapply）" "firewall rule missing (xhy relay reapply)"
            relay_config_has "in-relay-${RELAY_PORT}" && relay_say ok "config 含入站 in-relay-${RELAY_PORT}" "config has inbound in-relay-${RELAY_PORT}" \
                || relay_say warn "config 未含入站（xhy relay reapply）" "config lacks inbound (xhy relay reapply)"
            ;;
        entry)
            local n=0 fbs
            relay_say info "角色: 入口端（转发）" "role: entry (forwarder)"
            printf '  上游   : %s\n' "$RELAY_UPSTREAM"
            printf '  传输   : none（明文 vless）\n' 
            printf '  分类   : %s\n' "${RELAY_CATEGORIES:-（无，仅 geoip:us）}"
            printf '  geoip  : %s\n' "${RELAY_GEOIP_US:-on}"
            printf '  标签   : %s\n' "$(relay_out_tag)"
            if relay_fallback_on; then
                fbs="on（$(relay_lb_tag) → direct，探活 $(relay_out_tag)）"
            else
                fbs="off（死指 $(relay_out_tag)）"
            fi
            printf '  回落   : %s\n' "$fbs"
            printf '  UUID   : %s\n' "$RELAY_UUID"
            n="$(grep -o "\"$(relay_out_tag)\"" "$XHY_ETC/config.json" 2>/dev/null | wc -l | tr -d ' ')"
            if [[ "${n:-0}" -ge 2 ]]; then
                relay_say ok "config 含 $(relay_out_tag) 出站 + 路由（${n} 处引用）" \
                            "config has $(relay_out_tag) outbound + rules (${n} refs)"
            else
                relay_say warn "config 未含 relay（xhy relay reapply）" "config lacks relay (xhy relay reapply)"
            fi
            ;;
    esac
    return 0
}

relay_test() {
    relay_env_load || { relay_say info "本机未配置 relay，无需测试" "relay not configured"; return 0; }
    relay_cfg_test || true
    if [[ "$RELAY_ROLE" == "land" ]]; then
        relay_port_listening "$RELAY_PORT" && relay_say ok "端口 ${RELAY_PORT} 监听中" "port ${RELAY_PORT} listening" \
            || relay_say warn "端口 ${RELAY_PORT} 未监听（xhy service status）" "port ${RELAY_PORT} not listening"
        relay_fw_present "$RELAY_PORT" "$RELAY_ALLOW" && relay_say ok "防火墙已放行 ${RELAY_ALLOW}" "firewall allows ${RELAY_ALLOW}" \
            || relay_say warn "防火墙规则缺失" "firewall rule missing"
        relay_config_has "in-relay-${RELAY_PORT}" && relay_say ok "config 含 in-relay-${RELAY_PORT}" "config has in-relay-${RELAY_PORT}" \
            || relay_say warn "config 未含入站片段" "inbound fragment missing from config"
        if grep -q '"sockopt":{"tcpFastOpen":true' "$XHY_CONFDIR/relay_in_${RELAY_PORT}.json" 2>/dev/null; then
            relay_say ok "入站 TFO 已开（listen socket 启用 TCP_FASTOPEN）" \
                        "inbound TFO enabled (TCP_FASTOPEN on listen socket)"
        else
            relay_say warn "入站缺 TFO sockopt（这一跳省不到握手 RTT，重跑 xhy relay land）" \
                          "inbound lacks TFO sockopt (no handshake RTT saved; rerun xhy relay land)"
        fi
        printf '%s\n' "  云安全组: 入方向 TCP ${RELAY_PORT} 源 ${RELAY_ALLOW}/32"
        return 0
    fi
    relay_config_has "$(relay_out_tag)" && relay_say ok "config 含 $(relay_out_tag)" "config has $(relay_out_tag)" \
        || relay_say warn "config 未含 relay 出站（xhy relay reapply）" "config lacks relay outbound"
    relay_config_has '"sockopt"' && relay_say ok "出站 sockopt 在位（TFO + tcpNoDelay + keepalive）" \
        "outbound sockopt present (TFO, tcpNoDelay, keepalive)" \
        || relay_say warn "出站缺 sockopt（每条新连接多一个 TCP 握手）" "outbound lacks sockopt"
    if relay_fallback_on; then
        relay_config_has "\"$(relay_lb_tag)\"" && relay_say ok "回落链路在位：$(relay_lb_tag) → direct" \
            "fallback chain present: $(relay_lb_tag) -> direct" \
            || relay_say warn "回落开关是 on 但 config 没有 balancer（xhy relay reapply）" "fallback on but no balancer in config"
        relay_config_has 'burstObservatory' && relay_say ok "探活器 burstObservatory 在位" \
            "prober burstObservatory present" \
            || relay_say warn "缺 burstObservatory：balancer 拿不到延迟数据，回落不会触发" "burstObservatory missing; fallback will not trigger"
    else
        relay_say info "失联回落已关（--no-fallback）：落地挂掉时这些流量直接断" \
                      "fallback disabled (--no-fallback): relayed traffic blacks out if the landing host dies"
    fi
    printf '  传输   : none（明文 vless）\n'
    local hp host p
    hp="$(relay_split_upstream "$RELAY_UPSTREAM")" || { relay_say err "RELAY_UPSTREAM 解析失败" "bad RELAY_UPSTREAM"; return 1; }
    host="${hp% *}"; p="${hp##* }"
    relay_tcp_probe "$host" "$p" || true
    relay_say info "端到端验证：走入口机访问 https://chatgpt.com/cdn-cgi/trace，ip= 应是落地端 IP" \
                  "end-to-end: via the entry host open https://chatgpt.com/cdn-cgi/trace, ip= should be the landing IP"
    return 0
}

relay_del() {
    relay_env_load >/dev/null 2>&1 || {
        # 没状态文件也可能有残留片段，一并清
        local f
        for f in "$XHY_CONFDIR"/relay_in_*.json; do [[ -f "$f" ]] || continue; rm -f "$f"; done
        relay_say info "本机无 relay 状态" "no relay state on this host"
        return 0
    }
    need_root
    local role="$RELAY_ROLE" port="$RELAY_PORT" allow="$RELAY_ALLOW"
    relay_clean_land_state
    rm -f "$XHY_NODES/relay.env"
    relay_reset_vars
    XHY_SKIP_SNAPSHOT=1 rebuild_config || true
    if xray_config_test >/dev/null 2>&1; then
        config_reload >/dev/null 2>&1 || relay_say warn "配置已写回但服务未重启（xhy service restart）" \
                                                     "config written but service not restarted (xhy service restart)"
    fi
    if [[ "$role" == "land" ]]; then
        relay_say ok "落地端 relay 已移除（片段 ${port} + 防火墙规则 ${allow} + 配置已重建）" \
                    "landing relay removed (fragment ${port}, firewall rule ${allow}, config rebuilt)"
    else
        relay_say ok "入口端 relay 已移除（配置已恢复为无 relay 版本）" \
                    "entry relay removed (config rebuilt without relay)"
    fi
    return 0
}

cmd_relay() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        land)    relay_land "$@" ;;
        entry)   relay_entry "$@" ;;
        reapply) relay_reapply "$@" ;;
        status)  relay_status "$@" ;;
        test)    relay_test "$@" ;;
        export)  relay_export "$@" ;;
        del|delete|rm) relay_del "$@" ;;
        help|-h|--help) relay_usage ;;
        *) relay_say err "未知子命令：$sub" "unknown subcommand: $sub"; relay_usage; return 1 ;;
    esac
}
