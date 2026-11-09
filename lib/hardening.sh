#!/usr/bin/env bash
# xray-hy / kernel tuning (BBR + MPTCP), dual-stack firewall, SSH guard.
# Both iptables and ip6tables get the SAME policy: an IPv6 hole would let an
# attacker bypass every IPv4-only rate limit (sshd usually listens on :::22).

FW_CHAIN="XHY-IN"
XHY_SYSCTL_FILE="/etc/sysctl.d/90-xray-hy.conf"

# SSH 防爆破阈值。按「正常人的使用量」定，不是按攻击者：
# VS Code Remote / scp 批量 / 运维工具一轮就是 5-10 个新连接，家宽 IP 又常被
# 运营商 NAT 与其他用户共享。攻击者的特征是每小时成百上千次，不是一分钟 15 次。
# 爆发窗口 30 次/60s，慢速窗口 120 次/小时 —— 误伤远小于被锁在门外的损失。
SSH_BURST_WINDOW=60
SSH_BURST_HITS=30
SSH_SLOW_WINDOW=3600
SSH_SLOW_HITS=120

in_container() {
    [[ -r /proc/1/environ ]] && tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qE '^container=|^lxc'
}

# 只有运行中的内核真的暴露了该键才写。容器/老内核上不存在的键会让
# `sysctl -p` 整体失败，把同一个文件里本来有效的 BBR 设置一起带走。
# 调用方先设置 XHY_SYSCTL_FILE。
add_sysctl() {
    local key="$1" val="$2" path
    [[ -n "${XHY_SYSCTL_FILE:-}" ]] || return 0
    path="/proc/sys/${key//./\/}"
    [[ -e "$path" ]] || return 0
    printf '%s = %s\n' "$key" "$val" >>"$XHY_SYSCTL_FILE"
    sysctl -w "$key=$val" >/dev/null 2>&1 || true
    return 0
}

# Alpine does not load tcp_bbr / sch_fq at boot and its sysctl service lives in
# the *boot* runlevel. Debian only needs sysctl.d. Containers get a graceful skip.
tune_bbr() {
    local avail="" sysctl_file="/etc/sysctl.d/90-xray-hy.conf"
    if in_container; then
        warn "检测到容器环境，内核参数通常不可写；跳过 BBR（宿主侧才需要设置）。"
        state_set BBR_STATUS "container-skip"
        return 0
    fi

    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true

    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if [[ "$avail" != *bbr* ]]; then
        warn "当前内核未提供 tcp_bbr ($avail)。Alpine 请确认使用带 BBR 的内核；OpenVZ/LXC 无法开启。"
        state_set BBR_STATUS "unavailable"
        return 1
    fi

    if [[ "$XHY_DISTRO" == "alpine" ]]; then
        install -d -m 0755 /etc/modules-load.d
        printf 'tcp_bbr\nsch_fq\n' >/etc/modules-load.d/xray-hy.conf
        rc-update add sysctl boot >/dev/null 2>&1 || true
        sed -i -e '/net.core.default_qdisc/d' -e '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
        printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >>/etc/sysctl.conf
    fi

    install -d -m 0755 /etc/sysctl.d
    backup_file "$sysctl_file"
    # net.ipv4.tcp_fastopen = 3 只是内核「允许」位（bit0 client + bit1 server），
    # 不代表服务端启用被动 TFO。真正的开关是 sockopt.tcpFastOpen=false
    # （lib/sockopt.sh）：伪装站不支持 TFO，开了会被主动探测区分出来。
    cat >"$sysctl_file" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.ip_forward = 0
EOF
    XHY_SYSCTL_FILE="$sysctl_file"
    # PMTU 黑洞：握手成功但传不动数据，跨境链路第一号原因
    add_sysctl net.ipv4.tcp_mtu_probing 1
    # idle 后 cwnd 归 1，长连接周期性掉速
    add_sysctl net.ipv4.tcp_slow_start_after_idle 0
    # 默认 32768-60999 只有 28k 个临时端口，高并发出站会 cannot assign requested address
    add_sysctl "net.ipv4.ip_local_port_range" "10240 65000"
    add_sysctl net.core.netdev_max_backlog 16384
    # listen_addr() 用 "::" 监听依赖 bindv6only=0，被别的工具改过就会 v4 全挂
    add_sysctl net.ipv6.bindv6only 0
    # XTLS#7291 / CVE-2026-98432: Go 1.24+ enables MPTCP on listeners by
    # default. Disable it system-wide when the kernel exposes the knob.
    if [[ -e /proc/sys/net/mptcp/enabled ]]; then
        printf '\n# CVE-2026-98432 / XTLS#7291\nnet.mptcp.enabled = 0\n' >>"$sysctl_file"
        sysctl -w net.mptcp.enabled=0 >/dev/null 2>&1 || true
        state_set MPTCP_STATUS "disabled"
    else
        state_set MPTCP_STATUS "kernel-key-absent"
    fi
    # CVE-2026-98432 also has a request-socket-migration path.
    if [[ -e /proc/sys/net/ipv4/tcp_migrate_req ]]; then
        printf '\n# CVE-2026-98432 secondary path\nnet.ipv4.tcp_migrate_req = 0\n' >>"$sysctl_file"
        sysctl -w net.ipv4.tcp_migrate_req=0 >/dev/null 2>&1 || true
    fi
    if ! sysctl -p "$sysctl_file" >/dev/null 2>&1 && ! sysctl --system >/dev/null 2>&1; then
        warn "内核参数写入成功但即时应用失败，重启后通常会生效。请执行 xhy check 复查。"
        state_set BBR_STATUS "pending-reboot"
        return 1
    fi
    # 「选了开就要真开好」：sysctl -p 返回 0 不代表值真的变了 —— 容器、
    # 只读 /proc、被别的工具覆盖都会造成假成功。这里按实测值判定。
    local applied_cc applied_qd
    applied_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    applied_qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [[ "$applied_cc" != "bbr" || "$applied_qd" != "fq" ]]; then
        warn "sysctl 已下发但实测未生效 (congestion=${applied_cc:-?} qdisc=${applied_qd:-?})；常见于容器 / 只读 /proc / 被覆盖。开机自启已写好，重启后跑 xhy check 复查。"
        state_set BBR_STATUS "apply-failed"
        return 1
    fi
    state_set BBR_STATUS "on"
    ok "BBR 已启用并验证 (congestion=bbr qdisc=fq)"
    return 0
}

# 持久化配置是否完整。判据必须是「文件 + 关键键」，不能拿运行时值代理：
# v1.3.0（commit 56f2e7c）之前只写 /etc/sysctl.conf 的老部署，运行时
# bbr/fq 全对、tcp_mtu_probing=1、mptcp=0 也对，但 90-xray-hy.conf 和
# modules-load.d 从未生成 —— 重启就丢 TFO / PMTU / MPTCP / 端口范围 / BBR 模块。
# 输出人话原因；返回 0=完整，1=缺失或不全。
bbr_persist_check() {
    # 路径可覆盖仅为离线回归用；生产默认就是这两个标准位置。
    local f="${XHY_SYSCTL_CONF:-/etc/sysctl.d/90-xray-hy.conf}"
    local m="${XHY_MODULES_CONF:-/etc/modules-load.d/xray-hy.conf}"
    local k miss=()
    if [[ ! -f "$f" ]]; then
        printf '缺失 %s\n' "$f"
        return 1
    fi
    for k in net.core.default_qdisc net.ipv4.tcp_congestion_control \
             net.core.somaxconn net.ipv4.tcp_fastopen \
             net.ipv4.tcp_max_syn_backlog net.core.rmem_max net.core.wmem_max \
             net.ipv4.ip_forward net.ipv4.tcp_mtu_probing \
             net.ipv4.tcp_slow_start_after_idle net.ipv4.ip_local_port_range \
             net.core.netdev_max_backlog net.ipv6.bindv6only; do
        # add_sysctl 写的是 "key = value"；[.] 让 ERE 里的点只匹配字面点。
        grep -qE "^[[:space:]]*${k//./[.]}[[:space:]]*=" "$f" 2>/dev/null || miss+=("$k")
    done
    # 条件键：内核暴露了就必须落盘，否则重启后 MPTCP 又回到默认开。
    if [[ -e /proc/sys/net/mptcp/enabled ]] &&
       ! grep -qE '^[[:space:]]*net[.]mptcp[.]enabled[[:space:]]*=' "$f" 2>/dev/null; then
        miss+=("net.mptcp.enabled")
    fi
    if [[ -e /proc/sys/net/ipv4/tcp_migrate_req ]] &&
       ! grep -qE '^[[:space:]]*net[.]ipv4[.]tcp_migrate_req[[:space:]]*=' "$f" 2>/dev/null; then
        miss+=("net.ipv4.tcp_migrate_req")
    fi
    # Alpine 不在 boot 加载 tcp_bbr / sch_fq，缺这个文件连 BBR 本身都保不住。
    if [[ "$XHY_DISTRO" == "alpine" && ! -f "$m" ]]; then
        miss+=("modules-load.d/xray-hy.conf")
    fi
    if (( ${#miss[@]} )); then
        printf '不完整（缺 %s）\n' "${miss[*]}"
        return 1
    fi
    printf '完整\n'
    return 0
}

# 幂等兜底：服务端本来就该开 BBR，发现没生效就重新下发。
# BBR_ENABLED=off 是用户在安装时显式选的「不开」，此时完全不干预；
# 未设置（老部署 / 默认）视为 on。除了实测运行时值，还要查持久化文件：
# 老部署靠 /etc/sysctl.conf 开机生效，运行时永远「已就绪」，只判运行时值
# 就会永远跳过 tune_bbr，90-xray-hy.conf 静默漏一辈子。
# 完整时仍直接 return，不会每次 update config 重写 sysctl 文件、堆备份。
bbr_ensure() {
    local cur qd persist
    if [[ "$(state_get BBR_ENABLED on)" == "off" ]]; then
        return 0
    fi
    cur="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [[ "$cur" == "bbr" && "$qd" == "fq" ]]; then
        # 运行时生效 != 重启后还在。容器里 tune_bbr 本来就跳过，别反复空转。
        if ! in_container; then
            if ! persist="$(bbr_persist_check)"; then
                info "BBR 运行时已生效，但内核参数持久化${persist}；重新下发…"
                tune_bbr || return 1
            fi
        fi
        state_set BBR_STATUS "on"
        return 0
    fi
    info "BBR 未生效 (congestion=${cur:-?} qdisc=${qd:-?})，正在启用…"
    if tune_bbr; then
        return 0
    fi
    return 1
}

bbr_status() {
    local cc qd persist
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    printf '拥塞控制 : %s\n' "${cc:-?}"
    printf 'qdisc    : %s\n' "${qd:-?}"
    if [[ "$cc" == "bbr" && "$qd" == "fq" ]]; then
        printf '实际生效 : yes (congestion=bbr + qdisc=fq)\n'
    else
        printf '实际生效 : NO (congestion=%s qdisc=%s) → 执行 xhy bbr on\n' "${cc:-?}" "${qd:-?}"
    fi
    # xhy check 会原样打印这一段。老部署只写 /etc/sysctl.conf 时这里会提示
    # 「缺失」，并给出补全命令，而不是让「实际生效 : yes」掩盖重启即丢。
    if persist="$(bbr_persist_check)"; then
        printf '持久化配置 : %s\n' "$persist"
    else
        printf '持久化配置 : %s\n' "$persist"
        warn "内核参数重启后会丢失，执行 xhy bbr on 重新下发"
    fi
    printf '可用算法 : %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '?')"
    printf 'MPTCP    : %s (应为 0)\n' "$(sysctl -n net.mptcp.enabled 2>/dev/null || echo '内核未暴露')"
    printf 'migrate_req: %s (应为 0)\n' "$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null || echo '内核未暴露')"
    printf '端口范围 : %s\n' "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo '?')"
    printf 'MTU 探测 : %s (应为 1)\n' "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo '?')"
    printf 'access日志: %s\n' "$(state_get ACCESS_LOG 'off (默认关闭)')"
    printf '脚本状态 : %s\n' "$(state_get BBR_STATUS 'unset')"
}

# 由 lib/relay.sh 覆盖：_apply_family 每次都是「清空链 → 重写」，而 relay 的
# 放行规则是 relay_fw_add 单独 -I 插进去的、不在本文件的规则集里。没有这个钩子，
# `xhy update config` / `firewall apply` / 开机重放都会把落地机那条
# ACCEPT tcp dpt:14430 src <entry> 静默清掉（v1.14.2 实机坐实）。
# 默认空实现，relay.sh 加载后覆盖；参数 <iptables|ip6tables> <链名>。
firewall_extra_rules() { return 0; }

# Collect public TCP ports from the node registry. Tunnel nodes bind to
# 127.0.0.1 (PUBLIC=0) and are intentionally not exposed.
firewall_node_ports() {
    local f p public proto
    for f in $(node_env_files); do
        [[ -f "$f" ]] || continue
        public="$(grep -m1 '^PUBLIC=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ "$public" == "0" ]] && continue
        proto="$(grep -m1 '^PROTO=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ "$proto" == "udp" ]] && continue
        p="$(grep -m1 '^PORT=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done | sort -un
}

# Hysteria2 / QUIC nodes are UDP-only; forgetting this is the #1 reason a
# freshly created hy2 node looks "up" but never connects.
firewall_udp_ports() {
    local f p public proto
    for f in $(node_env_files); do
        [[ -f "$f" ]] || continue
        public="$(grep -m1 '^PUBLIC=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ "$public" == "0" ]] && continue
        proto="$(grep -m1 '^PROTO=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ "$proto" == "udp" ]] || continue
        p="$(grep -m1 '^PORT=' "$f" 2>/dev/null | cut -d= -f2- || true)"
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done | sort -un
}

# Build our own chain for one address family. We never flush INPUT, so
# pre-existing admin rules stay intact. Two recent windows are used: a short
# one for bursts and an hourly one that catches slow brute force.
_apply_family() {
    local ipt="$1" mode="$2" guard="$3" tag p ok_recent=1
    have_cmd "$ipt" || return 1
    if [[ "$ipt" == "ip6tables" ]]; then tag="XHYSSH6"; else tag="XHYSSH"; fi

    if ! "$ipt" -w -N "$FW_CHAIN" >/dev/null 2>&1; then
        "$ipt" -w -F "$FW_CHAIN" >/dev/null 2>&1 \
            || { warn "无法创建/清空 $ipt 的 $FW_CHAIN 链"; return 1; }
    fi
    while "$ipt" -w -C INPUT -j "$FW_CHAIN" >/dev/null 2>&1; do
        "$ipt" -w -D INPUT -j "$FW_CHAIN" || break
    done

    "$ipt" -w -A "$FW_CHAIN" -i lo -j ACCEPT
    "$ipt" -w -A "$FW_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    if [[ "$ipt" == "ip6tables" ]]; then
        "$ipt" -w -A "$FW_CHAIN" -p ipv6-icmp -j ACCEPT
    else
        "$ipt" -w -A "$FW_CHAIN" -p icmp --icmp-type echo-request -m limit --limit 5/second -j ACCEPT
    fi

    if [[ "$guard" == "on" ]]; then
        # 顺序与 --rcheck/--set 的选择是这套机制的全部要害：
        #
        #   rcheck(DROP) 在前、set 在后 —— 一旦命中 DROP，包就不再往下走，
        #   时间戳停止新增，滑窗 60 秒后自然滚动清空，人静等一分钟即可解锁。
        #
        # 旧版写的是「先 set 再 --update --hitcount」，两个后果叠加成死锁：
        #   1) --set 无条件执行，每一轮重试都往窗口顶一条新记录；
        #   2) --update 命中时还会再刷新一次时间戳。
        #   于是窗口永远满，越试越锁，只有 VNC 清 /proc/net/xt_recent 才能救。
        # 实测硅谷一次会话被 DROP 674 次、家宽 IP 在表里顶满 32 条就是这个。
        if "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --rcheck --seconds "$SSH_BURST_WINDOW" --hitcount "$SSH_BURST_HITS" --name "$tag" -j DROP >/dev/null 2>&1; then
            "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --set --name "$tag" >/dev/null 2>&1 || ok_recent=0
            "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --rcheck --seconds "$SSH_SLOW_WINDOW" --hitcount "$SSH_SLOW_HITS" --name "${tag}_SLOW" -j DROP >/dev/null 2>&1 || ok_recent=0
            "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --set --name "${tag}_SLOW" >/dev/null 2>&1 || ok_recent=0
        else
            ok_recent=0
        fi
        (( ok_recent == 1 )) || warn "$ipt: xt_recent 不可用，SSH 防爆破未完全生效"
    fi

    "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -j ACCEPT
    while read -r p; do
        [[ -n "$p" ]] && "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$p" -j ACCEPT
    done < <(firewall_node_ports)
    while read -r p; do
        [[ -n "$p" ]] && "$ipt" -w -A "$FW_CHAIN" -p udp --dport "$p" -j ACCEPT
    done < <(firewall_udp_ports)

    if [[ "$mode" == "strict" ]]; then
        "$ipt" -w -A "$FW_CHAIN" -p tcp -j DROP
        "$ipt" -w -A "$FW_CHAIN" -p udp -j DROP
    fi
    "$ipt" -w -A "$FW_CHAIN" -j RETURN
    # 放在 RETURN 之后：relay_fw_add 的 -I 需要能先找到 terminator，
    # 才能把放行规则插到 DROP/RETURN 之前（v1.13.3 的位置修复）。
    firewall_extra_rules "$ipt" "$FW_CHAIN" || warn "附加防火墙规则写入失败（$ipt）"
    "$ipt" -w -I INPUT 1 -j "$FW_CHAIN" || return 1
    return 0
}

# 存一份防火墙规则快照；空表不存，同类只留最新 3 份。
_fw_snapshot() {
    local tool="$1" tmp cnt f n=0
    tmp="$(mktemp "${TMPDIR:-/tmp}/fw.XXXXXX" 2>/dev/null || true)"
    [[ -n "$tmp" ]] || return 0
    if ! "${tool}-save" >"$tmp" 2>/dev/null; then rm -f "$tmp"; return 0; fi
    cnt="$(grep -c '^-A' "$tmp" 2>/dev/null || true)"
    if (( ${cnt:-0} == 0 )); then
        rm -f "$tmp"
        info "${tool} 当前没有规则（空表），跳过快照"
        return 0
    fi
    mv -f "$tmp" "$XHY_BACKUP/${tool}.$(date +%Y%m%d%H%M%S).rules" 2>/dev/null || { rm -f "$tmp"; return 0; }
    while IFS= read -r f; do
        n=$(( n + 1 ))
        (( n > 3 )) && rm -f "$f"
    done < <(ls -1t "$XHY_BACKUP/${tool}."*.rules 2>/dev/null || true)
    return 0
}

firewall_apply() {
    local mode="${1:-$(state_get FIREWALL_MODE safe)}" quiet="${2:-}" guard
    have_cmd iptables || { warn "未安装 iptables，跳过防火墙配置"; return 1; }
    guard="$(state_get SSH_GUARD on)"
    install -d -m 0700 "$XHY_BACKUP"
    # 空规则不值一份快照：`iptables -F` 之后存下来的是两百多字节的空表，还会按
    # 「最新一份」把有价值的历史顶掉（47.88.102.45 上真实发生过）。
    _fw_snapshot iptables
    if have_cmd ip6tables; then _fw_snapshot ip6tables; fi

    _apply_family iptables "$mode" "$guard" || return 1
    if have_cmd ip6tables; then
        if ! _apply_family ip6tables "$mode" "$guard"; then
            warn "IPv6 规则应用失败：请检查 ip6tables，否则 SSH 可经 IPv6 绕过限速。"
        fi
    else
        warn "系统无 ip6tables；若 sshd 监听 IPv6，请自行确认 IPv6 无暴露。"
    fi
    state_set FIREWALL_MODE "$mode"
    state_set SSH_GUARD_STATUS "$([[ "$guard" == on ]] && echo on || echo off)"
    # At boot this runs *from* the unit below; rewriting the unit and calling
    # rc-update from inside its own start() is pointless and can race.
    [[ "${XHY_FW_NO_INSTALL:-0}" == "1" ]] || install_firewall_service
    [[ "$quiet" == "--quiet" ]] || ok "防火墙已应用 (模式: $mode, 双栈, SSH: $XHY_SSH_PORT, 节点端口: $(firewall_node_ports | tr '\n' ' '))"
}

# Boot persistence re-runs the idempotent chain builder instead of restoring a
# full rules dump, so rules added later by the admin are never overwritten.
install_firewall_service() {
    local runner="/usr/local/bin/xhy"
    [[ -x "$runner" ]] || runner="$XHY_SELF"
    if [[ "$XHY_INIT" == "systemd" ]]; then
        cat >/etc/systemd/system/xray-hy-firewall.service <<EOF
[Unit]
Description=xray-hy dual-stack firewall rules
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=XHY_FW_NO_INSTALL=1
ExecStart=${runner} firewall apply --quiet

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray-hy-firewall >/dev/null 2>&1 || true
    else
        cat >/etc/init.d/xray-hy-firewall <<'EOF'
#!/sbin/openrc-run
name="xray-hy-firewall"
description="xray-hy dual-stack firewall rules"
depend() { need net; after iptables; before xray-hy; }
start() { XHY_FW_NO_INSTALL=1 RUNNER firewall apply --quiet; }
stop()  { for t in iptables ip6tables; do
            $t -w -D INPUT -j XHY-IN >/dev/null 2>&1 || true
            $t -w -F XHY-IN >/dev/null 2>&1 || true
            $t -w -X XHY-IN >/dev/null 2>&1 || true
          done; }
EOF
        sed -i "s|RUNNER|${runner}|" /etc/init.d/xray-hy-firewall
        chmod 0755 /etc/init.d/xray-hy-firewall
        rc-update add xray-hy-firewall boot >/dev/null 2>&1 || true
    fi
}

_clear_family() {
    local ipt="$1"
    have_cmd "$ipt" || return 0
    while "$ipt" -w -C INPUT -j "$FW_CHAIN" >/dev/null 2>&1; do
        "$ipt" -w -D INPUT -j "$FW_CHAIN" || break
    done
    "$ipt" -w -F "$FW_CHAIN" >/dev/null 2>&1 || true
    "$ipt" -w -X "$FW_CHAIN" >/dev/null 2>&1 || true
}

firewall_off() {
    _clear_family iptables
    _clear_family ip6tables
    svc_disable "$SVC_FW"
    state_set FIREWALL_MODE "off"
    ok "xray-hy 双栈防火墙链已移除，系统原有规则未改动"
}

# firewall_status [--brief]
# --brief 只打前四行摘要：调用方用 `firewall_status | head -4` 时，head 提前
# 关掉管道会让 printf 收到 SIGPIPE，在 pipefail 下把整个 `xhy check` 变成 141。
firewall_status() {
    local brief=""
    if [[ "${1:-}" == "--brief" ]]; then brief="1"; fi
    printf '工作模式 : %s\n' "$(state_get FIREWALL_MODE safe)"
    printf 'SSH 防爆破: %s (端口 %s，%ss/%s 次 + %ss/%s 次 双窗口)\n' "$(state_get SSH_GUARD_STATUS '?')" "$XHY_SSH_PORT" \
        "$SSH_BURST_WINDOW" "$SSH_BURST_HITS" "$SSH_SLOW_WINDOW" "$SSH_SLOW_HITS"
    printf '节点端口(TCP): %s\n' "$(firewall_node_ports | tr '\n' ' ')"
    printf '节点端口(UDP): %s\n' "$(firewall_udp_ports | tr '\n' ' ')"
    if [[ -n "$brief" ]]; then return 0; fi
    if have_cmd iptables; then
        printf '\n%s\n' "IPv4 自定义链："
        iptables -w -L "$FW_CHAIN" -n --line-numbers 2>/dev/null || printf '  (未创建)\n'
    fi
    if have_cmd ip6tables; then
        printf '\n%s\n' "IPv6 自定义链："
        ip6tables -w -L "$FW_CHAIN" -n --line-numbers 2>/dev/null || printf '  (未创建)\n'
    else
        warn "未找到 ip6tables，IPv6 侧未受本脚本保护"
    fi
}
