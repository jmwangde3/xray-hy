#!/usr/bin/env bash
# xray-hy / per-inbound sockopt + TCP Fast Open probing.
#
# TFO 不是吞吐参数：它最多省掉 TCP 握手最后半程，且只有 CLIENT 也发 TFO
# option 时才生效。Xray / sing-box / mihomo 客户端默认 tcpFastOpen=false，
# 所以服务端单方面打开等于零收益。这里不做"一律开"，而是让 REALITY 节点
# 跟着被伪装站自己的 SYN-ACK 走 —— 与伪装目标不一致才是特征，一致不是。

# target_tfo_probe <连接地址> [端口] [TLS SNI]
#   0 = target 的 SYN-ACK 带 TFO option
#   1 = SYN-ACK 抓到了，但不带 TFO option
#   2 = 无法判定（缺 tcpdump/openssl/timeout，或两次都没抓到 SYN-ACK）
# 连接地址用 dest（可能是源站 IP），SNI 单独给 —— 域名解析到 CDN 时两者不同，
# 要跟的是源站的 SYN-ACK，不是 Cloudflare 边缘的。
target_tfo_probe() {
    local host="$1" port="${2:-443}" sni="${3:-$1}" out pid rc=2 attempt rhost filt
    have_cmd tcpdump  || return 2
    have_cmd openssl  || return 2
    have_cmd timeout  || return 2
    out="$(mktemp "${TMPDIR:-/tmp}/xhy-tfo.XXXXXX" 2>/dev/null)" || return 2

    # 必须按源 IP 收窄：只写 `src port 443` 会把本机 443 入站发出的 SYN-ACK
    # 一起抓进来（REALITY 自己就监听 443），那样测到的是自己不是目标。
    filt="tcp and src port $port and tcp[tcpflags] & (tcp-syn|tcp-ack) == (tcp-syn|tcp-ack)"
    rhost="$host"
    if [[ ! "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if have_cmd getent; then
            rhost="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')"
        elif have_cmd nslookup; then
            rhost="$(nslookup "$host" 2>/dev/null \
                | awk '/^Address: /{print $2}' | grep -E '^[0-9]+\.' | head -1)"
        else
            rhost=""
        fi
    fi
    if [[ -n "$rhost" ]]; then
        filt="tcp and src host $rhost and src port $port and tcp[tcpflags] & (tcp-syn|tcp-ack) == (tcp-syn|tcp-ack)"
    fi

    # 直接吃 tcpdump 的文本输出，不写 pcap：`-w` 有输出缓冲，杀进程那一刻
    # 可能还是空文件（实测过），文本管道 + `grep -m1` 命中第一条 SYN-ACK 就
    # 退出，既快也不依赖缓冲行为。
    for attempt in 1 2; do
        : >"$out"
        { timeout 3 tcpdump -i any -nn -vv "$filt" 2>/dev/null || true; } \
            | grep -m1 -E 'Flags \[S\.\]' >"$out" &
        pid=$!
        # tcpdump 挂上过滤器要几百毫秒，太短会让握手抢在监听之前过去。
        if (( attempt == 1 )); then sleep 0.7; else sleep 1.0; fi
        timeout 4 openssl s_client -connect "${host}:${port}" -servername "$sni" \
            -tls1_3 -brief </dev/null >/dev/null 2>&1 || true
        wait "$pid" 2>/dev/null || true
        if [[ -s "$out" ]]; then
            # tcpdump 对 option 34 打印 "unknown-34"（老版本）/"fast open"（新版本），
            # 部分发行版补丁写成 "tfo"，三个都认。
            if grep -qiE 'unknown-34|fast.?open|\btfo\b' "$out"; then
                rc=0
            else
                rc=1
            fi
            break
        fi
    done
    rm -f "$out"
    return $rc
}

sockopt_json() {
    local tfo="false"
    if [[ "${TFO:-0}" == "1" ]]; then tfo="true"; fi
    # tcpMptcp 不写：GODEBUG 已经在进程级关掉，字段存在性未在 v26.3.27 上验证，
    # 少一个 unknown field 风险点。
    printf '"sockopt":{"tcpFastOpen":%s,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpcongestion":"bbr"}' "$tfo"
}

# tfo_decide auto|on|off <dest> [port] [sni] -> 打印 0 或 1。
# auto 走真实探测：只有伪装站的 SYN-ACK 自己带 TFO option 时才跟着开。
# 客户端不请求 TFO 时服务端开与不开的握手完全一样，所以「跟随目标」既没有
# 收益损失，也避开了「节点与伪装站 TCP 行为不一致」这个指纹。
tfo_decide() {
    local opt="${1:-auto}" dest="$2" port="${3:-443}" sni="${4:-$2}" trc=0
    case "$opt" in
        on)       printf '1'; return 0 ;;
        off)      printf '0'; return 0 ;;
        auto|"")  ;;
        *)        warn "未知 --tfo 取值: $opt（应为 auto / on / off），按 auto 处理" >&2 ;;
    esac
    target_tfo_probe "$dest" "$port" "$sni" || trc=$?
    if (( trc == 2 )); then
        info "无法探测 $dest 的 TFO（缺 tcpdump/openssl 或抓不到 SYN-ACK），按关闭处理" >&2
    fi
    if (( trc == 0 )); then printf '1'; else printf '0'; fi
}
