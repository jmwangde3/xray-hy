#!/usr/bin/env bash
# BBR「默认开 + 选开就必须真开好」的决策表回归测试。
#
# 锁定 bbr_ensure() 的行为：
#   - BBR_ENABLED=off（安装时显式选了不开）→ 完全不干预
#   - 实测 congestion=bbr 且 qdisc=fq → 认为已生效，不重写 sysctl 文件
#   - 任一不对 → 调 tune_bbr 重新下发
#   - tune_bbr 失败时返回非 0，让调用方能 warn
# 同时锁 bbr_status 的「实际生效」判定行。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
# 注意：这里故意不调 stub_system —— 要测的是真实的 bbr_ensure。

FAKE_CC="cubic"; FAKE_QD="fq_codel"; FAKE_ENABLED="on"
FAKE_TUNE=0; FAKE_TUNE_RC=0; FAKE_STATUS=""

sysctl() {
    case "${2:-}" in
        net.ipv4.tcp_congestion_control) printf '%s\n' "$FAKE_CC" ;;
        net.core.default_qdisc)         printf '%s\n' "$FAKE_QD" ;;
        net.ipv4.tcp_available_congestion_control) printf 'reno cubic bbr\n' ;;
        net.ipv4.tcp_fastopen)          printf '3\n' ;;
        net.mptcp.enabled)              printf '0\n' ;;
        net.ipv4.tcp_migrate_req)       printf '0\n' ;;
        net.ipv4.ip_local_port_range)   printf '10240 65000\n' ;;
        net.ipv4.tcp_mtu_probing)       printf '1\n' ;;
        *)                              printf '\n' ;;
    esac
    return 0
}
state_get() {
    if [[ "${1:-}" == "BBR_ENABLED" ]]; then printf '%s' "$FAKE_ENABLED"; fi
    if [[ "${1:-}" == "ACCESS_LOG" ]]; then printf 'off'; fi
}
state_set() { FAKE_STATUS="${2:-}"; }
tune_bbr() { FAKE_TUNE=$((FAKE_TUNE + 1)); return "$FAKE_TUNE_RC"; }
info() { :; }
warn() { :; }
ok()   { :; }

pass=0 fail=0
chk() {
    local d="$1" e="$2" g="$3"
    if [[ "$g" == "$e" ]]; then
        printf '  PASS  %s\n' "$d"; pass=$((pass + 1))
    else
        printf '  FAIL  %s（期望 [%s] 实际 [%s]）\n' "$d" "$e" "$g"; fail=$((fail + 1))
    fi
}

reset() {
    FAKE_CC="$1"; FAKE_QD="$2"; FAKE_ENABLED="$3"
    FAKE_TUNE=0; FAKE_TUNE_RC=0; FAKE_STATUS=""
}

echo "=== bbr_ensure 决策表 ==="
reset bbr fq on
bbr_ensure; rc=$?
chk "已生效 -> 不调 tune_bbr"      "0/0"          "$rc/$FAKE_TUNE"
chk "已生效 -> BBR_STATUS=on"      "on"           "$FAKE_STATUS"

reset cubic fq_codel on
bbr_ensure; rc=$?
chk "congestion 不对 -> 重新下发"  "0/1"          "$rc/$FAKE_TUNE"

reset bbr fq_codel on
bbr_ensure; rc=$?
chk "qdisc 不对 -> 重新下发"       "0/1"          "$rc/$FAKE_TUNE"

reset cubic fq on
bbr_ensure; rc=$?
chk "仅 congestion 不对 -> 下发"   "0/1"          "$rc/$FAKE_TUNE"

reset "" "" on
bbr_ensure; rc=$?
chk "读不到 sysctl -> 下发"        "0/1"          "$rc/$FAKE_TUNE"

reset cubic fq_codel off
bbr_ensure; rc=$?
chk "BBR_ENABLED=off -> 不干预"    "0/0"          "$rc/$FAKE_TUNE"

reset cubic fq_codel on; FAKE_TUNE_RC=1
bbr_ensure; rc=$?
chk "tune_bbr 失败 -> 返回非 0"     "1/1"          "$rc/$FAKE_TUNE"

echo "=== bbr_status 的实际生效判定 ==="
reset bbr fq on
out="$(bbr_status)"
chk "bbr+fq -> yes"                "1" "$(printf '%s' "$out" | grep -c '实际生效 : yes')"
reset cubic fq_codel on
out="$(bbr_status)"
chk "cubic+fq_codel -> NO"         "1" "$(printf '%s' "$out" | grep -c '实际生效 : NO')"
chk "NO 行提示 xhy bbr on"          "1" "$(printf '%s' "$out" | grep -c 'xhy bbr on')"

echo "=== 源码接线（防漏调用）==="
if grep -q 'bbr_ensure || warn "BBR 未生效' lib/update.sh; then
    printf '  PASS  update_config 接入 bbr_ensure\n'; pass=$((pass + 1))
else
    printf '  FAIL  update_config 未接入 bbr_ensure\n'; fail=$((fail + 1))
fi
if grep -q 'state_set BBR_ENABLED off' entry/main.sh; then
    printf '  PASS  安装时可显式选不开\n'; pass=$((pass + 1))
else
    printf '  FAIL  安装时没有记录「不开」\n'; fail=$((fail + 1))
fi
if grep -q 'confirm "启用 BBR 与内核网络优化？" "y"' entry/main.sh; then
    printf '  PASS  安装默认仍为 y\n'; pass=$((pass + 1))
else
    printf '  FAIL  安装默认值被改掉了\n'; fail=$((fail + 1))
fi
if grep -q 'applied_cc' lib/hardening.sh; then
    printf '  PASS  tune_bbr 有实测校验\n'; pass=$((pass + 1))
else
    printf '  FAIL  tune_bbr 缺实测校验\n'; fail=$((fail + 1))
fi

echo ""
echo "bbr-test: $pass passed, $fail failed"
(( fail == 0 ))
