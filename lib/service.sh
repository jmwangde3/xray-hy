#!/usr/bin/env bash
# xray-hy / service management for systemd and OpenRC.

SVC_XRAY="xray-hy"
SVC_CF="xray-hy-tunnel"
SVC_FW="xray-hy-firewall"

svc_enable() {
    local n="$1"
    if [[ "$XHY_INIT" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl enable "$n" >/dev/null 2>&1
    else
        rc-update add "$n" default >/dev/null 2>&1
    fi
}

svc_disable() {
    local n="$1"
    if [[ "$XHY_INIT" == "systemd" ]]; then
        systemctl disable "$n" >/dev/null 2>&1 || true
    else
        rc-update del "$n" default >/dev/null 2>&1 || true
    fi
}

svc_start()   { if [[ "$XHY_INIT" == "systemd" ]]; then systemctl start "$1";   else rc-service "$1" start;   fi; }
svc_stop()    { if [[ "$XHY_INIT" == "systemd" ]]; then systemctl stop "$1" >/dev/null 2>&1 || true; else rc-service "$1" stop >/dev/null 2>&1 || true; fi; }
svc_restart() { if [[ "$XHY_INIT" == "systemd" ]]; then systemctl restart "$1"; else rc-service "$1" restart; fi; }
svc_status()  { if [[ "$XHY_INIT" == "systemd" ]]; then systemctl status "$1" --no-pager -l; else rc-service "$1" status; fi; }
svc_active()  { if [[ "$XHY_INIT" == "systemd" ]]; then systemctl is-active --quiet "$1"; else rc-service "$1" status >/dev/null 2>&1; fi; }

# Bound the Go runtime heap on small VPS / memory-limited containers. singbox-lite
# does this via GOMEMLIMIT; without it a 128-256MB box can OOM-kill Xray.
compute_gomemlimit() {
    local kb cg mb
    kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ -r /sys/fs/cgroup/memory.max ]]; then
        cg="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)"
        if [[ "$cg" =~ ^[0-9]+$ ]]; then
            cg=$((cg / 1024))
            if (( cg > 0 && cg < kb )); then kb="$cg"; fi
        fi
    elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        cg="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)"
        if [[ "$cg" =~ ^[0-9]+$ ]] && (( cg > 0 && cg / 1024 < kb )); then
            kb=$((cg / 1024))
        fi
    fi
    mb=$((kb / 1024 / 4))
    (( mb < 32 )) && mb=32
    (( mb > 512 )) && mb=512
    printf '%sMiB' "$mb"
}

# Unbounded append-logs eventually fill a small VPS disk. Install a rotation
# policy whenever logrotate is available; never fail installation without it.
install_logrotate() {
    local cfg="/etc/logrotate.d/xray-hy" restart_cmd
    if ! have_cmd logrotate; then
        ensure_optional logrotate
        have_cmd logrotate || {
            warn "未安装 logrotate：$XHY_LOGDIR 下日志不会自动轮转，请手动 apt/apk install logrotate";
            return 0;
        }
    fi
    if [[ "$XHY_INIT" == "systemd" ]]; then
        restart_cmd="systemctl restart xray-hy >/dev/null 2>&1 || true"
    else
        restart_cmd="rc-service xray-hy restart >/dev/null 2>&1 || true"
    fi
    install -d -m 0755 /etc/logrotate.d "$XHY_LOGDIR"
    backup_file "$cfg"
    cat >"$cfg" <<EOF
${XHY_LOGDIR}/*.log {
    weekly
    rotate 4
    maxsize 32M
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
    sharedscripts
    postrotate
        $restart_cmd
    endscript
}
EOF
    if [[ "$XHY_DISTRO" == "alpine" ]]; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    fi
    ok "日志轮转已配置 ($cfg)"
}

install_xray_service() {
    local memlimit
    memlimit="$(compute_gomemlimit)"
    backup_file "$XHY_ETC/config.json"
    if [[ "$XHY_INIT" == "systemd" ]]; then
        cat >/etc/systemd/system/xray-hy.service <<EOF
[Unit]
Description=xray-hy Xray multi-node service
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${XHY_ETC}/config.json
Environment=XRAY_LOCATION_ASSET=${XRAY_ASSET}
Environment=GOMEMLIMIT=${memlimit}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
StandardOutput=append:${XHY_LOGDIR}/xray.log
StandardError=append:${XHY_LOGDIR}/xray.err

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        cat >/etc/init.d/xray-hy <<'EOF'
#!/sbin/openrc-run
name="xray-hy"
description="xray-hy Xray multi-node service"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray-hy/config.json"
command_background=true
pidfile="/run/xray-hy.pid"
output_log="/var/log/xray-hy/xray.log"
error_log="/var/log/xray-hy/xray.err"
export XRAY_LOCATION_ASSET="/usr/local/share/xray"
export GOMEMLIMIT="MEMLIMIT"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o root:root /var/log/xray-hy
    XRAY_LOCATION_ASSET="/usr/local/share/xray" \
        "$command" run -test -c /etc/xray-hy/config.json || return 1
}
EOF
        chmod 0755 /etc/init.d/xray-hy
        sed -i "s|MEMLIMIT|${memlimit}|" /etc/init.d/xray-hy
    fi
    svc_enable "$SVC_XRAY"
    install_logrotate
    ok "Xray 服务已安装并设为开机自启 ($XHY_INIT, GOMEMLIMIT=${memlimit})"
}

install_cf_service() {
    # A tiny wrapper reads the root-only token file and execs cloudflared.
    # Keeping this out of the unit avoids shell-quoting differences between
    # systemd and OpenRC. The token is still visible in `ps` by design of
    # cloudflared's token mode; the file itself stays mode 0600.
    install -d -m 0755 /usr/local/lib/xray-hy "$XHY_LOGDIR"
    cat >/usr/local/lib/xray-hy/tunnel-run <<EOF
#!/bin/sh
set -e
[ -s ${XHY_ETC}/tunnel.token ] || { echo "missing tunnel.token" >&2; exit 1; }
TOKEN="\$(cat ${XHY_ETC}/tunnel.token)"
exec ${CF_BIN} tunnel --no-autoupdate run --token "\$TOKEN"
EOF
    chmod 0755 /usr/local/lib/xray-hy/tunnel-run
    if [[ "$XHY_INIT" == "systemd" ]]; then
        cat >/etc/systemd/system/xray-hy-tunnel.service <<EOF
[Unit]
Description=xray-hy Cloudflare Tunnel connector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/lib/xray-hy/tunnel-run
Restart=on-failure
RestartSec=5
StandardOutput=append:${XHY_LOGDIR}/cloudflared.log
StandardError=append:${XHY_LOGDIR}/cloudflared.err

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        cat >/etc/init.d/xray-hy-tunnel <<'EOF'
#!/sbin/openrc-run
name="xray-hy-tunnel"
description="xray-hy Cloudflare Tunnel connector"
command="/usr/local/lib/xray-hy/tunnel-run"
command_background=true
pidfile="/run/xray-hy-tunnel.pid"
output_log="/var/log/xray-hy/cloudflared.log"
error_log="/var/log/xray-hy/cloudflared.err"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o root:root /var/log/xray-hy
}
EOF
        chmod 0755 /etc/init.d/xray-hy-tunnel
    fi
    svc_enable "$SVC_CF"
}

remove_cf_service() {
    svc_stop "$SVC_CF" 2>/dev/null || true
    svc_disable "$SVC_CF"
    rm -f /etc/systemd/system/xray-hy-tunnel.service /etc/init.d/xray-hy-tunnel
    [[ "$XHY_INIT" == "systemd" ]] && systemctl daemon-reload
}

# Validate the fully rendered config before it is ever handed to the service.
xray_config_test() {
    local cfg="${1:-$XHY_ETC/config.json}"
    [[ -s "$cfg" ]] || { err "配置文件为空或不存在: $cfg"; return 1; }
    XRAY_LOCATION_ASSET="$XRAY_ASSET" "$XRAY_BIN" run -test -c "$cfg" 2>&1
}

config_reload() {
    if ! xray_config_test; then
        err "配置校验失败，保持原有运行配置不变。"
        return 1
    fi
    svc_restart "$SVC_XRAY" || { err "Xray 重启失败，查看 $XHY_LOGDIR/xray.err"; return 1; }
    ok "配置已重载"
}
