#!/usr/bin/env bash
# xray-hy / per-inbound sockopt.
#
# ---- TFO 的四条实测结论（2026-11-07，47.88.102.45 真机，详见 HANDOFF §12.6.4）----
#
# 1) 「探测伪装站是否支持 TFO」这个思路本身不成立。
#    被动 TFO 要成立，必须 client 的 SYN 带 option 34（cookie request）**且**
#    server 的 listener 显式 setsockopt(TCP_FASTOPEN, qlen)。用普通 connect 去
#    探测时 SYN 根本不含 34，任何服务端都不会在 SYN-ACK 里回 34 —— 探测恒为
#    「不支持」。旧实现（v1.3.0）因此是个恒定返回 false 的死逻辑，白等 1.4s，
#    还拖了一个 tcpdump 依赖。
#
# 2) 目标确实不支持。用 curl --tcp-fastopen 打出带 `exp-tfo cookiereq` 的 SYN，
#    打 www.easeus.com 源站 47.88.102.65:443 与两个高分候选，SYN-ACK 全部只有
#    mss/sackOK/TS/nop/wscale，没有 option 34。
#
# 3) Xray 侧也不生效。26.10.31 上：
#    - 入站 sockopt.tcpFastOpen=true：SYN-ACK 无 34，TcpExtTCPFastOpenPassive=0
#    - 出站 freedom sockopt.tcpFastOpen=true：SYN 与 false 逐字节相同，无 34
#    也就是说这个字段在当前核心上是装饰，写了也不产生可观测行为。
#
# 4) 与伪装无关。TCP options 不进 TLS 指纹，客户端不会拿 SYN-ACK 的 options
#    判断真伪。「与伪装站保持一致」这个理由在 REALITY 上不成立。
#
# 结论：默认写 false。`--tfo on` 只保留成手动阀门 —— 将来换到真正支持 TFO 的
# 链路、且核心版本真的 setsockopt 时，用户自己决定打开。

sockopt_json() {
    local tfo="false"
    if [[ "${TFO:-0}" == "1" ]]; then tfo="true"; fi
    # tcpMptcp 不写：GODEBUG 已经在进程级关掉，字段存在性未在 v26.3.27 上验证，
    # 少一个 unknown field 风险点。
    printf '"sockopt":{"tcpFastOpen":%s,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpcongestion":"bbr"}' "$tfo"
}

# tfo_decide auto|on|off -> 打印 0 或 1。
#   auto（默认）= 0，不探测。理由见文件头四条；探测不可达真值且恒为 0。
#   on          = 1，手动强制（仅在确认链路支持 TFO 时使用）。
#   off         = 0。
tfo_decide() {
    local opt="${1:-auto}"
    case "$opt" in
        on)  printf '1'; return 0 ;;
        off) printf '0'; return 0 ;;
        auto|"") printf '0'; return 0 ;;
        *)
            warn "未知 --tfo 取值: $opt（应为 auto / on / off），按 auto 处理" >&2
            printf '0'; return 0
            ;;
    esac
}
