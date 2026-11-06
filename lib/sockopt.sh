#!/usr/bin/env bash
# xray-hy / per-inbound sockopt.
#
# ---- TFO 一律关闭（2026-11-07 定稿：服务端不开，脚本也不再留开关）----
#
# 四条实测结论（47.88.102.45，Xray 26.10.31，详见 HANDOFF §12.6.4 / §12.7.2）：
#
# 1) 被动 TFO 要两端同时成立：client 的 SYN 带 option 34（cookie request）
#    **且** server 的 listener 显式 setsockopt(TCP_FASTOPEN, qlen)。
#    net.ipv4.tcp_fastopen=3 只是"允许"，不会让普通 listener 启用被动 TFO。
# 2) 目标不支持。用 curl --tcp-fastopen 打出带 `exp-tfo cookiereq` 的 SYN，
#    打 www.easeus.com 源站 47.88.102.65:443 与两个高分候选，SYN-ACK 全部
#    只有 mss/sackOK/TS/nop/wscale，没有 option 34。
# 3) Xray 侧不生效。入站 tcpFastOpen=true 时 SYN-ACK 无 34、
#    TcpExtTCPFastOpenPassive=0；出站 freedom tcpFastOpen=true 的 SYN 与
#    false 逐字节相同。这个字段在当前核心上是装饰。
# 4) 与伪装无关。TCP options 不进 TLS 指纹，客户端不拿 SYN-ACK 的 options
#    判断真伪；REALITY 首包要精确模仿浏览器，0-RTT 带数据反而是额外风险面。
#
# 所以 v1.4.0 起不再有 `--tfo` 选项，字段恒为 false。要重新评估 TFO 就改这里
# 一处，不要再把它做成 CLI 开关 —— 这个开关存在过两个版本，两次都回到 0。

sockopt_json() {
    # 显式写 false 而不是省略字段：v1.3.0 已实测 26.10.31 接受该字段，
    # 写出来读代码的人一眼能看到结论，省得再去翻 handoff。
    # tcpMptcp 不写：GODEBUG 已经在进程级关掉，字段存在性未在 v26.3.27 上验证，
    # 少一个 unknown field 风险点。
    printf '"sockopt":{"tcpFastOpen":false,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpcongestion":"bbr"}'
}
