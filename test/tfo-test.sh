#!/usr/bin/env bash
# TFO 探测逻辑回归测试（离线，注入 curl / nstat，不打外网）。
#
# 锁定 target_tfo_detect 的判据：
#   curl --tcp-fastopen 连打 3 次，TcpExtTCPFastOpenActive 增长 -> 目标支持
#   IP target 用 --resolve SNI:port:IP 打真源站；域名 target 先解析再钉死一个 IP
#   （TFO cookie 按目的 IP 缓存，多 A 记录不钉会假阴性）；解析失败才退回不钉
#   客户端位 net.ipv4.tcp_fastopen bit0 没开 / 缺 nstat -> 必然全假阴性，先判后扫
#   工具缺失 / 计数读不到 -> 保守判定「不支持」
# 以及 tfo_decide 的 on/off/auto 三种模式。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
# 不调 stub_system：这里要测真实的 target_tfo_detect / tfo_decide。

FAKE_ACTIVE=0; FAKE_DELTA=0; CURL_CALLS=0; CURL_ARGS=""
FAKE_HAVE_CURL=0; FAKE_HAVE_NSTAT=0; FAKE_NSTAT_BAD=0

nstat() {
    if [[ "$FAKE_NSTAT_BAD" == "1" ]]; then
        printf 'garbage\n'
    else
        printf 'TcpExtTCPFastOpenActive %s 0.0\n' "$FAKE_ACTIVE"
    fi
    return 0
}
# /proc/net/netstat 的 TcpExt 段最小桩：TCPFastOpenActive 在第 4 列。
# curl stub 每次调用都把该列写成当前 FAKE_ACTIVE，模拟真实 MIB 增长。
write_netstat() { printf 'TcpExt: Foo Bar TCPFastOpenActive Baz\nTcpExt: 0 0 %s 0\n' "$1" > "${XHY_NETSTAT_PROC:-/proc/net/netstat}"; }
curl() {
    CURL_CALLS=$((CURL_CALLS + 1))
    CURL_ARGS="$CURL_ARGS $*"
    FAKE_ACTIVE=$((FAKE_ACTIVE + FAKE_DELTA))
    write_netstat "$FAKE_ACTIVE"
    return 0
}
have_cmd() {
    case "${1:-}" in
        curl)  return "$FAKE_HAVE_CURL" ;;
        nstat) return "$FAKE_HAVE_NSTAT" ;;
        *)     return 0 ;;
    esac
}
is_ip_literal() { [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
# 客户端位（bit 0）与探测能力判定要用到 sysctl；默认按"能探"（3）给。
FAKE_FASTOPEN=3
sysctl() {
    case "${2:-}" in
        net.ipv4.tcp_fastopen) printf '%s\n' "$FAKE_FASTOPEN"; return 0 ;;
        *) return 1 ;;
    esac
}
# 域名解析结果可控：空串 = 解析失败（回到不钉 IP 的旧行为）
FAKE_RESOLVE_IP=""
resolve_v4_one() { printf '%s' "$FAKE_RESOLVE_IP"; }

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
    FAKE_ACTIVE=0; FAKE_DELTA=0; CURL_CALLS=0; CURL_ARGS=""
    FAKE_HAVE_CURL=0; FAKE_HAVE_NSTAT=0; FAKE_NSTAT_BAD=0
    FAKE_FASTOPEN=3; FAKE_RESOLVE_IP=""
    XHY_NETSTAT_PROC="${TEST_TMP:-/tmp}/netstat"; write_netstat 0
}

echo "=== 目标不支持（Active 不增长）==="
reset; FAKE_DELTA=0
target_tfo_detect 47.88.102.65 443 www.easeus.com; rc=$?
chk "detect 返回 1"              "1" "$rc"
chk "curl 调用 3 次"             "3" "$CURL_CALLS"
chk "auto 判定为 0"              "0" "$(tfo_decide auto 47.88.102.65 443 www.easeus.com)"

echo "=== 目标支持（Active 每次 +1）==="
reset; FAKE_DELTA=1
target_tfo_detect 47.88.102.65 443 www.easeus.com; rc=$?
chk "detect 返回 0"              "0" "$rc"
chk "curl 调用 3 次"             "3" "$CURL_CALLS"
chk "auto 判定为 1"              "1" "$(tfo_decide auto 47.88.102.65 443 www.easeus.com)"

echo "=== on / off 不触发探测 ==="
reset; FAKE_DELTA=1
chk "on -> 1"                    "1" "$(tfo_decide on 47.88.102.65 443 www.easeus.com)"
chk "off -> 0"                   "0" "$(tfo_decide off 47.88.102.65 443 www.easeus.com)"
chk "on/off 不调 curl"           "0" "$CURL_CALLS"

echo "=== --resolve：IP 天然钉死，域名解析后也钉死 ==="
reset; FAKE_DELTA=1
target_tfo_detect 47.88.102.65 443 www.easeus.com >/dev/null 2>&1
chk "IP target 带 --resolve"     "1" "$(printf '%s' "$CURL_ARGS" | grep -c -- '--resolve www.easeus.com:443:47.88.102.65')"
reset; FAKE_DELTA=1; FAKE_RESOLVE_IP="93.184.216.34"
target_tfo_detect real.example.com 443 real.example.com >/dev/null 2>&1
chk "域名解析成功则钉死 IP"       "1" "$(printf '%s' "$CURL_ARGS" | grep -c -- '--resolve real.example.com:443:93.184.216.34')"
chk "钉死后 3 次打同一 IP"         "3" "$(printf '%s' "$CURL_ARGS" | grep -o -- '93.184.216.34' | wc -l | tr -d ' ')"
reset; FAKE_DELTA=1; FAKE_RESOLVE_IP=""
target_tfo_detect real.example.com 443 real.example.com >/dev/null 2>&1
chk "解析失败则退回不钉 IP"       "0" "$(printf '%s' "$CURL_ARGS" | grep -c -- '--resolve')"

echo "=== 探测能力：客户端位没开 = 必然全部假阴性 ==="
# 约定：FAKE_HAVE_* = 0 表示"有这个命令"（与 have_cmd 的返回语义一致）
reset
chk "fastopen=3 可探"            "0" "$(tfo_probe_ready; echo $?)"
FAKE_FASTOPEN=1
chk "fastopen=1 可探（客户端位）" "0" "$(tfo_probe_ready; echo $?)"
FAKE_FASTOPEN=2
chk "fastopen=2 不可探（只有服务端位）" "1" "$(tfo_probe_ready; echo $?)"
chk "说明指出客户端位"            "1" "$(tfo_probe_blocker | grep -c '客户端位')"
FAKE_FASTOPEN=0
chk "fastopen=0 不可探"          "1" "$(tfo_probe_ready; echo $?)"
# nstat 缺失但 /proc 可读：仍可探（8.222 真实场景，修复前此处被误判不可用）
reset; FAKE_HAVE_NSTAT=1; FAKE_FASTOPEN=3
chk "缺 nstat 但 /proc 可读 -> 可探" "0" "$(tfo_probe_ready; echo $?)"
chk "说明此时为空"               "" "$(tfo_probe_blocker)"
# nstat 缺失 且 /proc 不可读：才真正不可探
reset; FAKE_HAVE_NSTAT=1; FAKE_FASTOPEN=3; XHY_NETSTAT_PROC="$TEST_TMP/nope_netstat"
chk "nstat无+proc不可读 -> 不可探" "1" "$(tfo_probe_ready; echo $?)"
chk "说明指出 nstat缺失"          "1" "$(tfo_probe_blocker | grep -c 'nstat 缺失')"
XHY_NETSTAT_PROC="$TEST_TMP/netstat"
reset; FAKE_HAVE_CURL=1; FAKE_FASTOPEN=3
chk "缺 curl 不可探"              "1" "$(tfo_probe_ready; echo $?)"
reset; FAKE_FASTOPEN=3
chk "能力齐备时说明为空"          "" "$(tfo_probe_blocker)"

echo "=== 无 nstat 但 /proc 可读：仍能探测出 TFO（核心回归）==="
reset; FAKE_HAVE_NSTAT=1; FAKE_DELTA=1
target_tfo_detect 47.88.102.65 443 www.easeus.com; rc=$?
chk "无 nstat+proc可读 -> detect 返回 0（支持）" "0" "$rc"
chk "无 nstat 也调了 curl 3 次"   "3" "$CURL_CALLS"
chk "auto 判定为 1"               "1" "$(tfo_decide auto 47.88.102.65 443 www.easeus.com)"
reset; FAKE_HAVE_NSTAT=1; FAKE_DELTA=0
target_tfo_detect 47.88.102.65 443 www.easeus.com; rc=$?
chk "无 nstat+proc可读 但 Active 不增 -> 1" "1" "$rc"

echo "=== 失败时保守关闭 ==="
reset; FAKE_HAVE_CURL=1
target_tfo_detect 47.88.102.65 443 www.easeus.com; rc=$?
chk "无 curl -> 1"               "1" "$rc"
reset; FAKE_HAVE_NSTAT=1
target_tfo_detect 47.88.102.65 443 www.easeus.com; rc=$?
chk "无 nstat（走 /proc）且 Active 不增 -> 1" "1" "$rc"
reset; FAKE_NSTAT_BAD=1
target_tfo_detect 47.88.102.65 443 www.easeus.com; rc=$?
chk "计数读不到 -> 1"            "1" "$rc"
reset; FAKE_DELTA=1
chk "空 dest 的 auto -> 0"       "0" "$(tfo_decide auto '' 443 '')"

echo "=== 说明文案 ==="
if grep -q 'TcpExtTCPFastOpenActive' lib/sockopt.sh; then
    printf '  PASS  注释记录判据\n'; pass=$((pass + 1))
else
    printf '  FAIL  注释缺判据\n'; fail=$((fail + 1))
fi
if grep -q '不承载正常代理流量' lib/scanner.sh; then
    printf '  PASS  说明伪装站不影响代理速度\n'; pass=$((pass + 1))
else
    printf '  FAIL  缺速度说明\n'; fail=$((fail + 1))
fi

echo ""
echo "tfo-test: $pass passed, $fail failed"
(( fail == 0 ))
