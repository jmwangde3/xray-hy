#!/usr/bin/env bash
# xray-hy / kernel tuning (BBR), iptables firewall and SSH brute-force guard.

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
        warn "当前内核未提供 tcp_bbr ($avail)。Alpine 请确认使用 linux-lts 而非 virt 精简内核；OpenVZ/LXC 无法开启。"
        state_set BBR_STATUS "unavailable"
        return 1
    fi

    if [[ "$XHY_DISTRO" == "alpine" ]]; then
        install -d -m 0755 /etc/modules-load.d
        printf 'tcp_bbr\nsch_fq\n' >/etc/modules-load.d/xray-hy.conf
        rc-update add sysctl boot >/dev/null 2>&1 || true
        # Alpine's busybox sysctl service reads /etc/sysctl.conf as well.
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
EOF
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
    printf '脚本状态 : %s\n' "$(state_get BBR_STATUS 'unset')"
}

# Collect public TCP ports from the node registry. Tunnel nodes bind to
# 127.0.0.1 (PUBLIC=0) and are intentionally not exposed.
firewall_node_ports() {
    local f p public
    for f in "$XHY_NODES"/*.env; do
        [[ -f "$f" ]] || continue
        public="$(grep -m1 '^PUBLIC=' "$f" 2>/dev/null | cut -d= -f2-)"
        [[ "$public" == "0" ]] && continue
        p="$(grep -m1 '^PORT=' "$f" 2>/dev/null | cut -d= -f2-)"
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done | sort -un
}

# Rebuild our own chain. We never flush INPUT, so pre-existing user rules are
# left completely intact. `strict` additionally drops everything else.
firewall_apply() {
    local mode="${1:-$(state_get FIREWALL_MODE safe)}" p quiet="${2:-}" guard
    have_cmd iptables || { warn "未安装 iptables，跳过防火墙配置"; return 1; }
    guard="$(state_get SSH_GUARD on)"
    install -d -m 0700 "$XHY_BACKUP"
    iptables-save >"$XHY_BACKUP/iptables.$(date +%Y%m%d%H%M%S).rules" 2>/dev/null || true

    if ! iptables -w -N "$FW_CHAIN" >/dev/null 2>&1; then
        iptables -w -F "$FW_CHAIN" >/dev/null 2>&1 \
            || { warn "无法创建/清空 $FW_CHAIN 链（权限不足或内核缺模块？），跳过防火墙"; return 1; }
    fi
    while iptables -w -C INPUT -j "$FW_CHAIN" >/dev/null 2>&1; do
        iptables -w -D INPUT -j "$FW_CHAIN" || break
    done

    iptables -w -A "$FW_CHAIN" -i lo -j ACCEPT
    iptables -w -A "$FW_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -w -A "$FW_CHAIN" -p icmp --icmp-type echo-request -m limit --limit 5/second -j ACCEPT

    if [[ "$guard" == "on" ]] \
       && iptables -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
            -m recent --set --name XHYSSH >/dev/null 2>&1; then
        iptables -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
            -m recent --update --seconds 60 --hitcount 5 --rttl --name XHYSSH -j DROP 2>/dev/null \
        || iptables -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -m conntrack --ctstate NEW \
            -m recent --update --seconds 60 --hitcount 5 --name XHYSSH -j DROP 2>/dev/null \
        || warn "内核缺少 xt_recent，跳过 SSH 防爆破规则"
        state_set SSH_GUARD_STATUS "on"
    else
        warn "SSH 防爆破未启用（xt_recent 不可用或已在设置中关闭）"
        state_set SSH_GUARD_STATUS "off"
    fi

    iptables -w -A "$FW_CHAIN" -p tcp --dport "$XHY_SSH_PORT" -j ACCEPT
    while read -r p; do
        [[ -n "$p" ]] && iptables -w -A "$FW_CHAIN" -p tcp --dport "$p" -j ACCEPT
    done < <(firewall_node_ports)

    if [[ "$mode" == "strict" ]]; then
        iptables -w -A "$FW_CHAIN" -p tcp -j DROP
        iptables -w -A "$FW_CHAIN" -p udp -j DROP
    fi
    iptables -w -A "$FW_CHAIN" -j RETURN
    iptables -w -I INPUT 1 -j "$FW_CHAIN"

    state_set FIREWALL_MODE "$mode"
    install_firewall_service
    [[ "$quiet" == "--quiet" ]] || ok "防火墙已应用 (模式: $mode, SSH: $XHY_SSH_PORT, 节点端口: $(firewall_node_ports | tr '\n' ' '))"
}

# Boot persistence re-runs the idempotent chain builder instead of restoring a
# full rules dump, so rules added later by the admin are never overwritten.
install_firewall_service() {
    local runner="/usr/local/bin/xhy"
    [[ -x "$runner" ]] || runner="${XHY_HOME}/xhy"
    if [[ "$XHY_INIT" == "systemd" ]]; then
        cat >/etc/systemd/system/xray-hy-firewall.service <<EOF
[Unit]
Description=xray-hy firewall rules
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${runner} firewall apply --quiet

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray-hy-firewall >/dev/null 2>&1 || true
    else
        cat >/etc/init.d/xray-hy-firewall <<EOF
#!/sbin/openrc-run
name="xray-hy-firewall"
description="xray-hy firewall rules"
depend() { need net; before xray-hy; }
start() { ${runner} firewall apply --quiet; }
stop()  { /sbin/iptables -w -D INPUT -j XHY-IN >/dev/null 2>&1 || true
          /sbin/iptables -w -F XHY-IN >/dev/null 2>&1 || true
          /sbin/iptables -w -X XHY-IN >/dev/null 2>&1 || true; }
EOF
        chmod 0755 /etc/init.d/xray-hy-firewall
        rc-update add xray-hy-firewall boot >/dev/null 2>&1 || true
    fi
}

firewall_off() {
    have_cmd iptables || return 0
    while iptables -w -C INPUT -j "$FW_CHAIN" >/dev/null 2>&1; do
        iptables -w -D INPUT -j "$FW_CHAIN" || break
    done
    iptables -w -F "$FW_CHAIN" >/dev/null 2>&1 || true
    iptables -w -X "$FW_CHAIN" >/dev/null 2>&1 || true
    svc_disable "$SVC_FW"
    state_set FIREWALL_MODE "off"
    ok "xray-hy 防火墙链已移除，系统原有规则未改动"
}

firewall_status() {
    printf '工作模式 : %s\n' "$(state_get FIREWALL_MODE safe)"
    printf 'SSH 防爆破: %s (端口 %s, 60 秒内 >5 次新连接丢弃)\n' "$(state_get SSH_GUARD_STATUS '?')" "$XHY_SSH_PORT"
    printf '节点端口 : %s\n' "$(firewall_node_ports | tr '\n' ' ')"
    if have_cmd iptables; then
        printf '\n%s\n' "当前自定义链："
        iptables -w -L "$FW_CHAIN" -n --line-numbers 2>/dev/null || printf '  (未创建)\n'
    fi
}
