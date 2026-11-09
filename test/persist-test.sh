#!/usr/bin/env bash
# bbr_persist_check 的真实文件夹具回归。
# 背景：v1.3.0 之前只写 /etc/sysctl.conf，运行时 bbr/fq 全对，但
# 90-xray-hy.conf / modules-load.d 从未生成；旧判据只看运行时值，
# 会永远跳过 tune_bbr。这里不 stub 被测函数，直接喂真实文件。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs

PASS=0 FAIL=0
chk() {
    if eval "$2" >/dev/null 2>&1; then
        printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1))
    fi
}

f="$TEST_TMP/90-xray-hy.conf"
m="$TEST_TMP/xray-hy.modules"
export XHY_SYSCTL_CONF="$f" XHY_MODULES_CONF="$m" XHY_DISTRO=alpine
rm -f "$f" "$m"

full_conf() {
    cat >"$f" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.ip_forward = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 10240 65000
net.core.netdev_max_backlog = 16384
net.ipv6.bindv6only = 0
net.mptcp.enabled = 0
net.ipv4.tcp_migrate_req = 0
EOF
    printf 'tcp_bbr\nsch_fq\n' >"$m"
}

echo "=== 缺失 / 不完整 / 完整 三分支 ==="
out="$(bbr_persist_check)"; rc=$?
chk "无 90 文件 -> 非 0"              '[[ $rc -ne 0 ]]'
chk "报出缺失的具体路径"              'grep -q "缺失" <<<"$out"'

printf 'net.ipv4.tcp_congestion_control = bbr\n' >"$f"
printf 'tcp_bbr\nsch_fq\n' >"$m"
out="$(bbr_persist_check)"; rc=$?
chk "文件在但缺关键键 -> 非 0"        '[[ $rc -ne 0 ]]'
chk "点名缺哪些键"                    'grep -q "不完整（缺" <<<"$out"'
chk "缺的键里含 tcp_mtu_probing"      'grep -q "tcp_mtu_probing" <<<"$out"'

full_conf
rm -f "$m"
out="$(bbr_persist_check)"; rc=$?
chk "Alpine 缺 modules-load -> 非 0" '[[ $rc -ne 0 ]]'
chk "点名 modules-load.d"             'grep -q "modules-load.d" <<<"$out"'

full_conf
out="$(bbr_persist_check)"; rc=$?
chk "文件 + modules 齐 -> 0"          '[[ $rc -eq 0 ]]'
chk "输出「完整」"                    '[[ "$out" == "完整" ]]'

echo "=== 判据不拿运行时值代理 ==="
rm -f "$f" "$m"
out="$(XHY_DISTRO=debian bbr_persist_check)"; rc=$?
chk "非 Alpine 但 90 文件缺 -> 非 0" '[[ $rc -ne 0 ]]'

echo "=== 源码接线 ==="
chk "bbr_ensure 调用判据"             '[[ $(grep -c "bbr_persist_check" lib/hardening.sh) -ge 3 ]]'
chk "bbr_status 打印持久化行"         'grep -q "持久化配置 : " lib/hardening.sh'
chk "判据里查 modules-load"           'grep -q "modules-load.d/xray-hy.conf" lib/hardening.sh'
chk "判据里查 tcp_mtu_probing"        'grep -q "net.ipv4.tcp_mtu_probing" lib/hardening.sh'

summary
