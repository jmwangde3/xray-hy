#!/usr/bin/env bash
# xray-hy / kernel tuning (BBR + MPTCP), dual-stack firewall, SSH guard.
# Both iptables and ip6tables get the SAME policy: an IPv6 hole would let an
# attacker bypass every IPv4-only rate limit (sshd usually listens on :::22).

FW_CHAIN="XHY-IN"

in_container() {
    [[ -r /proc/1/environ ]] && tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qE '^container=|^lxc'
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
    if sysctl -p "$sysctl_file" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1; then
        state_set BBR_STATUS "on"
        ok "BBR 已启用 ($(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null))"
    else
        warn "内核参数写入成功但即时应用失败，重启后通常会生效。请执行 xhy check 复查。"
        state_set BBR_STATUS "pending-reboot"
    fi
}

bbr_status() {
    printf '拥塞控制 : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    printf 'qdisc    : %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    printf '可用算法 : %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '?')"
    printf 'MPTCP    : %s (应为 0)\n' "$(sysctl -n net.mptcp.enabled 2>/dev/null || echo '内核未暴露')"
    printf 'migrate_req: %s (应为 0)\n' "$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null || echo '内核未暴露')"
    printf '脚本状态 : %s\n' "$(state_get BBR_STATUS 'unset')"
}

# Collect public TCP ports from the node registry. Tunnel nodes bind to
# 127.0.0.1 (PUBLIC=0) and are intentionally not exposed.
firewall_node_ports() {
    local f p public proto
    for f in "$XHY_NODES"/*.env; do
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
    for f in "$XHY_NODES"/*.env; do
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
        if "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --set --name "$tag" >/dev/null 2>&1; then
            "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --update --seconds 60 --hitcount 5 --name "$tag" -j DROP 2>/dev/null || ok_recent=0
            "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --set --name "${tag}_SLOW" >/dev/null 2>&1 || ok_recent=0
            "$ipt" -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
                -m recent --update --seconds 3600 --hitcount 8 --name "${tag}_SLOW" -j DROP 2>/dev/null || ok_recent=0
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
    "$ipt" -w -I INPUT 1 -j "$FW_CHAIN" || return 1
    return 0
}

firewall_apply() {
    local mode="${1:-$(state_get FIREWALL_MODE safe)}" quiet="${2:-}" guard
    have_cmd iptables || { warn "未安装 iptables，跳过防火墙配置"; return 1; }
    guard="$(state_get SSH_GUARD on)"
    install -d -m 0700 "$XHY_BACKUP"
    iptables-save >"$XHY_BACKUP/iptables.$(date +%Y%m%d%H%M%S).rules" 2>/dev/null || true
    if have_cmd ip6tables; then
        ip6tables-save >"$XHY_BACKUP/ip6tables.$(date +%Y%m%d%H%M%S).rules" 2>/dev/null || true
    fi

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

firewall_status() {
    printf '工作模式 : %s\n' "$(state_get FIREWALL_MODE safe)"
    printf 'SSH 防爆破: %s (端口 %s，60s/5 次 + 1h/8 次 双窗口)\n' "$(state_get SSH_GUARD_STATUS '?')" "$XHY_SSH_PORT"
    printf '节点端口(TCP): %s\n' "$(firewall_node_ports | tr '\n' ' ')"
    printf '节点端口(UDP): %s\n' "$(firewall_udp_ports | tr '\n' ' ')"
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
