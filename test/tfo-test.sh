#!/usr/bin/env bash
# TFO 探测逻辑回归测试（离线，注入 curl / nstat，不打外网）。
#
# 锁定 target_tfo_detect 的判据：
#   curl --tcp-fastopen 连打 3 次，TcpExtTCPFastOpenActive 增长 -> 目标支持
#   IP target 用 --resolve SNI:port:IP 打真源站；域名 target 不带 --resolve
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
curl() {
    CURL_CALLS=$((CURL_CALLS + 1))
    CURL_ARGS="$CURL_ARGS $*"
    FAKE_ACTIVE=$((FAKE_ACTIVE + FAKE_DELTA))
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

echo "=== --resolve 只在 IP target 时出现 ==="
reset; FAKE_DELTA=1
target_tfo_detect 47.88.102.65 443 www.easeus.com >/dev/null 2>&1
chk "IP target 带 --resolve"     "1" "$(printf '%s' "$CURL_ARGS" | grep -c -- '--resolve www.easeus.com:443:47.88.102.65')"
reset; FAKE_DELTA=1
target_tfo_detect real.example.com 443 real.example.com >/dev/null 2>&1
chk "域名 target 不带 --resolve" "0" "$(printf '%s' "$CURL_ARGS" | grep -c -- '--resolve')"

echo "=== 失败时保守关闭 ==="
reset; FAKE_HAVE_CURL=1
target_tfo_detect 47.88.102.65 443 www.easeus.com; rc=$?
chk "无 curl -> 1"               "1" "$rc"
reset; FAKE_HAVE_NSTAT=1
target_tfo_detect 47.88.102.65 443 www.easeus.com; rc=$?
chk "无 nstat -> 1"              "1" "$rc"
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
