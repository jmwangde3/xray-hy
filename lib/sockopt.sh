#!/usr/bin/env bash
# xray-hy / per-inbound sockopt.
#
# ============================================================================
# 一条必须先分清的口径：**字段被接受 ≠ 运行时生效**（2026-11-07 定）
# ============================================================================
#
# Xray 26.3.27（本项目的 XHY_PINNED_VERSION）与 26.10.31 都接受下面这套完整
# 的七字段写法，`xray run -test` 输出 Configuration OK、EXIT=0，无 unknown
# field：
#
#   tcpFastOpen / tcpNoDelay / tcpKeepAliveIdle / tcpUserTimeout /
#   tcpcongestion / tcpMptcp / tcpFastOpenQueueLength
#
# 所以任何"Xray 不支持某个字段"的说法都是错的。真正要判断的是**运行时**：
# 配置能过 `-test`，但 setsockopt 在内核侧返回 EINVAL / EOPNOTSUPP 时，Xray
# 只打一条 warning 或干脆静默忽略，服务照常启动，那一项零效果。下面三段
# 结论都是按"运行时有没有可观测行为"得出的，不是按"字段能不能解析"。
#
# ---- 一、TFO 一律关闭（服务端不开，脚本也不留开关）----
#
# 1) 被动 TFO 要两端同时成立：client 的 SYN 带 option 34（cookie request）
#    **且** server 的 listener 显式 setsockopt(TCP_FASTOPEN, qlen)。
#    net.ipv4.tcp_fastopen 只是"允许"：bit0=client，bit1=server。
#    本机路由器（arm64）实测该值为 1 —— 只有客户端位，做监听会 EOPNOTSUPP；
#    服务器（47.88.102.45）是 3，允许，但 Xray 侧仍未真正启用（见下条）。
# 2) 目标不支持。用 curl --tcp-fastopen 打出带 `exp-tfo cookiereq` 的 SYN，
#    打 www.easeus.com 源站 47.88.102.65:443 与两个高分候选，SYN-ACK 全部
#    只有 mss/sackOK/TS/nop/wscale，没有 option 34。
# 3) Xray 侧运行时未生效。入站 tcpFastOpen=true 时 SYN-ACK 无 34、
#    TcpExtTCPFastOpenPassive=0（一次都没成立）；出站 freedom tcpFastOpen=true
#    的 SYN 与 false 逐字节相同。cookie 由内核生成、Xray 只负责打开监听队列，
#    这是设计如此 —— 但"设计上支持"不等于"实测有行为"，计数为 0 就是没发生。
# 4) 与伪装无关。TCP options 不进 TLS 指纹，客户端不拿 SYN-ACK 的 options
#    判断真伪；REALITY 首包要精确模仿浏览器，0-RTT 带数据反而是额外风险面。
#
# 所以 v1.4.0 起不再有 `--tfo` 选项，tcpFastOpen 恒为 false，
# tcpFastOpenQueueLength 也随之不写（队列长度在 TFO 关闭时无意义）。
# 要重新评估 TFO 就改这里一处，不要再把它做成 CLI 开关 —— 这个开关存在过
# 两个版本，两次都回到 0。
#
# ---- 二、tcpcongestion 必须按内核能力决定写不写（v1.4.2 起）----
#
# `tcpcongestion:"bbr"` 是 per-socket 设置，算法没编译进内核时
# setsockopt(TCP_CONGESTION) 返回 EINVAL，Xray 静默忽略，那一项纯装饰。
# 实测两台机器的差别：
#
#   47.88.102.45 (x86_64)  available = reno cubic bbr  → 写 bbr 真生效
#   AX3600 路由器 (arm64)  available = reno cubic      → 写 bbr 是装饰
#
# 判定用 **tcp_available_congestion_control**（算法是否编译进内核），不用
# tcp_congestion_control（当前默认算法）：per-socket 只需要算法可用，不要求
# 内核默认就是 bbr。这也和 hardening.sh 里 `xhy bbr on` 的判定依据一致，
# 不会出现"bbr on 报 unavailable、sockopt 却写着 bbr"的自相矛盾。
#
# 不可用时**省略整个字段**而不是写 cubic：省略 = 继承内核默认，写死 cubic
# 反而可能把内核默认的更优算法顶掉。
#
# ---- 三、其余四字段无条件写 ----
#
# tcpNoDelay / tcpKeepAliveIdle=45 / tcpUserTimeout=10000 / tcpMptcp=false
# 与 TFO、拥塞控制都无关，任何内核上都成立，砍 sockopt 时不得连带删掉。
# tcpMptcp 显式写 false 而非省略：GODEBUG 已在进程级关掉 MPTCP，写出来让
# 读代码的人一眼看到结论（字段存在性已在 26.3.27 + 26.10.31 上实测通过）。

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

sockopt_json() {
    local cc=""
    if sockopt_cc_available; then
        cc=',"tcpcongestion":"bbr"'
    fi
    printf '"sockopt":{"tcpFastOpen":false,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpMptcp":false%s}' "$cc"
}
