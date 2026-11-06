#!/usr/bin/env bash
# xray-hy / per-inbound sockopt + TFO 决策。
#
# ============================================================================
# 口径：**字段被接受 ≠ 运行时生效**（2026-11-07 定）
# ============================================================================
#
# Xray 26.3.27（XHY_PINNED_VERSION）与 26.10.31 都接受七字段完整写法
# （tcpFastOpen / tcpNoDelay / tcpKeepAliveIdle / tcpUserTimeout /
#  tcpcongestion / tcpMptcp / tcpFastOpenQueueLength），`xray run -test`
# 输出 Configuration OK、EXIT=0、无 unknown field。任何「Xray 不支持某字段」
# 的说法都不成立。要判断的是运行时：setsockopt 失败时 Xray 静默忽略。
#
# ---- 一、TFO：默认跟随伪装站，用户可显式覆盖（v1.4.3 起）----
#
# 先纠正早期误判：**Xray 的 tcpFastOpen 是生效的**。2026-11-07 在
# 47.88.102.45 / 26.10.31 / 内核 tcp_fastopen=3 上实测：
#
#   入站 true + 客户端带有效 cookie 的 SYN（1542 B early data）
#     → SYN-ACK 的 ack 跳过 1542 字节、TcpExtTCPFastOpenPassive 每次 +1、
#       curl http=200（REALITY 转发正常，early data 没破坏功能）
#   入站 true + 首次 cookiereq（换新目标 IP 绕开内核 cookie 缓存）
#     → SYN-ACK 回 `tfo cookie 88c5d6bf…`（option 34）、CookieReqd +1
#   入站 false
#     → Passive 不变、SYN-ACK 的 ack 只 +1（early data 被丢）
#   tcpFastOpenQueueLength 写不写都不影响上述结果
#
# 早期判「不生效」用的是「客户端只发 cookiereq 时 SYN-ACK 无 option 34」——
# 那条路径下服务端本来就不该回 34，判据不成立。要看 ack 是否跳过 early data、
# Passive / CookieReqd 计数、以及 cookiereq 路径回不回 cookie。
#
# 既然它真的生效，就不能一刀切关掉或无条件打开，而要**跟伪装站保持一致**：
#
#   真实伪装站支持被动 TFO  → 我们开，探测者看到的 SYN-ACK 一致，且白拿 1 RTT
#   真实伪装站不支持         → 我们关，否则同样是探测者一个 SYN 就能区分开
#
# 现网 www.easeus.com 源站 47.88.102.65:443 不支持（带 cookiereq 的 SYN 打过去，
# SYN-ACK 只有 mss/sackOK/TS/nop/wscale，无 option 34），所以 auto 判定为关，
# 现网行为与 v1.4.2 一致。客户端默认配合：我们开它开、我们关它关。
#
# 探测方法：`curl --tcp-fastopen` 连打 3 次，看内核
# `TcpExtTCPFastOpenActive` 是否增长（远端回 cookie 后本机才能成功用 TFO）。
# 实测：不支持的 easeus delta=0，启用 TFO 的 Xray delta=3。
# **不需要 tcpdump** —— v1.3.0 那个探测之所以恒 false，是因为用普通 connect
# 发 SYN（不带 option 34），任何服务端都不会回 34；这一版判据是成立的。
#
# --tfo auto|on|off：auto 跟随伪装站（默认），on/off 由用户强制覆盖。
# 判定结果写进节点 env 的 TFO 字段并随节点持久保存，重建配置不会重复探测。
#
# ⚠️ **扫描不把 TFO 纳入打分或筛选**（见 lib/scanner.sh 的 scanner_score 注释）：
# 伪装站不承载正常代理流量（REALITY 只把未认证探测转发过去），它的带宽/延迟
# 不影响代理上网速度；为凑 TFO 去缩小候选池，反而会削弱抗探测可信度，
# 换来的只是首连省 1 RTT。先按质量选最优站，再读它的 TFO 能力决定我们开不开。
#
# ---- 二、tcpcongestion 按内核能力决定写不写（v1.4.2 起）----
#
# setsockopt(TCP_CONGESTION) 在内核没编译 bbr 时返回 EINVAL 被静默忽略。
#  47.88.102.45  available = reno cubic bbr  → 写 bbr 真生效
#  AX3600 路由器  available = reno cubic      → 写 bbr 是装饰
# 判定用 tcp_available_congestion_control（算法是否可用），不用 current
# （当前默认算法）：per-socket 只要算法可用就生效，也与 `xhy bbr on` 的
# 判定依据一致。不可用时省略整个字段（继承内核默认，不写死 cubic）。
#
# ---- 三、其余四字段无条件写 ----
#
# tcpNoDelay / tcpKeepAliveIdle=45 / tcpUserTimeout=10000 / tcpMptcp=false
# 与 TFO、拥塞控制都无关，任何内核上都成立，砍 sockopt 时不得连带删掉。
# tcpMptcp 显式写 false：GODEBUG 已在进程级关掉 MPTCP，写出来让读代码的人
# 一眼看到结论（字段存在性已在 26.3.27 + 26.10.31 上实测通过）。
# tcpFastOpenQueueLength 不写：Xray 用默认队列长度即可，实测不影响启用。

# 内核是否编译了 bbr（决定 tcpcongestion 写不写）。
# 缓存一次，避免每个 inbound 都 fork 一个 sysctl。
# 测试用 XHY_SOCKOPT_AVAIL_CC 注入，unset 时读真实 sysctl。
XHY_SOCKOPT_CC=""
sockopt_cc_available() {
    if [ -z "${XHY_SOCKOPT_CC-}" ]; then
        local avail=""
        if [ -n "${XHY_SOCKOPT_AVAIL_CC+x}" ]; then
            avail="$XHY_SOCKOPT_AVAIL_CC"
        else
            avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
        fi
        case " $avail " in
            *" bbr "*) XHY_SOCKOPT_CC="bbr" ;;
            *)         XHY_SOCKOPT_CC="none" ;;
        esac
    fi
    if [ "${XHY_SOCKOPT_CC-}" = "bbr" ]; then
        return 0
    fi
    return 1
}

# 判定伪装站 target 是否启用被动 TFO。
# 返回 0 = 支持（应开 TFO）；1 = 不支持或判不了（应关，失败时保守关闭）。
# 判据：curl --tcp-fastopen 连打 3 次，TcpExtTCPFastOpenActive 是否增长。
target_tfo_detect() {
    local dest="$1" port="${2:-443}" sni="${3:-}" b a i resolve=()
    have_cmd curl || return 1
    have_cmd nstat || return 1
    [[ -n "$sni" ]] || sni="$dest"
    if is_ip_literal "$dest"; then
        resolve=(--resolve "${sni}:${port}:${dest}")
    fi
    b="$(nstat -az 2>/dev/null | awk '$1=="TcpExtTCPFastOpenActive"{print $2}')"
    [[ "$b" =~ ^[0-9]+$ ]] || return 1
    i=0
    while (( i < 3 )); do
        curl -sk -m 4 --tcp-fastopen "${resolve[@]}" \
            "https://${sni}:${port}/" -o /dev/null 2>/dev/null || true
        i=$((i + 1))
    done
    a="$(nstat -az 2>/dev/null | awk '$1=="TcpExtTCPFastOpenActive"{print $2}')"
    [[ "$a" =~ ^[0-9]+$ ]] || return 1
    if (( a > b )); then
        return 0
    fi
    return 1
}

# tfo_decide <auto|on|off> <dest> <port> <sni> -> 打印 1（开）或 0（关）
tfo_decide() {
    local mode="${1:-auto}" dest="${2:-}" port="${3:-443}" sni="${4:-}"
    case "$mode" in
        on)  printf '1'; return 0 ;;
        off) printf '0'; return 0 ;;
        auto)
            if [[ -z "$dest" ]]; then printf '0'; return 0; fi
            if target_tfo_detect "$dest" "$port" "$sni"; then
                printf '1'
            else
                printf '0'
            fi
            return 0 ;;
        *)   printf '0'; return 0 ;;
    esac
}

sockopt_json() {
    local tfo="false" cc=""
    if [[ "${TFO:-0}" == "1" ]]; then
        tfo="true"
    fi
    if sockopt_cc_available; then
        cc=',"tcpcongestion":"bbr"'
    fi
    printf '"sockopt":{"tcpFastOpen":%s,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpMptcp":false%s}' "$tfo" "$cc"
}
