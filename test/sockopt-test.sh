#!/usr/bin/env bash
# sockopt 渲染与 TFO 决策的回归测试。
#
# 锁定的行为（v1.3.1）：
#   - `--tfo auto` 不再探测，直接给 0。伪装站探测在 v1.3.0 是恒 false 的死逻辑
#     （被动 TFO 要求 client SYN 带 option 34，普通 connect 探测的 SYN 不含 34，
#     服务端永远不会回 34），见 lib/sockopt.sh 文件头与 HANDOFF §12.6.4。
#   - `--tfo on` 仍然能强制写 true，`off` 写 false。
#   - 未知取值按 auto 处理并给出告警，不中断脚本（`set -e` 下不能返回 1）。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system

pass=0 fail=0
chk() {
    local desc="$1" expect="$2" got="$3"
    if [[ "$got" == "$expect" ]]; then
        printf '  PASS  %s\n' "$desc"; pass=$((pass + 1))
    else
        printf '  FAIL  %s（期望 [%s] 实际 [%s]）\n' "$desc" "$expect" "$got"; fail=$((fail + 1))
    fi
}

echo "=== tfo_decide ==="
chk "auto -> 0（不探测）"          "0" "$(tfo_decide auto 1.2.3.4 443 example.com)"
chk "空参数 -> 0"                  "0" "$(tfo_decide "" 1.2.3.4 443 example.com)"
chk "off -> 0"                     "0" "$(tfo_decide off)"
chk "on -> 1"                      "1" "$(tfo_decide on)"
chk "未知值 -> 0 且不报错退出"      "0" "$(tfo_decide bogus 2>/dev/null)"

echo "=== tfo_decide 多余参数不影响结果 ==="
chk "auto 带 dest/port/sni -> 0"   "0" "$(tfo_decide auto 47.88.102.65 443 www.easeus.com)"

echo "=== sockopt_json ==="
TFO=0
chk "TFO=0 -> tcpFastOpen false" \
    '"sockopt":{"tcpFastOpen":false,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpcongestion":"bbr"}' \
    "$(sockopt_json)"
TFO=1
chk "TFO=1 -> tcpFastOpen true" \
    '"sockopt":{"tcpFastOpen":true,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpcongestion":"bbr"}' \
    "$(sockopt_json)"
unset TFO
if sockopt_json | grep -q '"tcpFastOpen":false'; then
    printf '  PASS  TFO 未设置 -> false\n'; pass=$((pass + 1))
else
    printf '  FAIL  TFO 未设置时不是 false\n'; fail=$((fail + 1))
fi

echo "=== 探测依赖已移除 ==="
if declare -F target_tfo_probe >/dev/null 2>&1; then
    printf '  FAIL  target_tfo_probe 仍存在（v1.3.1 应已删除）\n'; fail=$((fail + 1))
else
    printf '  PASS  target_tfo_probe 已删除\n'; pass=$((pass + 1))
fi
if grep -v '^[[:space:]]*#' lib/sockopt.sh | grep -q "tcpdump"; then
    printf '  FAIL  lib/sockopt.sh 仍引用 tcpdump\n'; fail=$((fail + 1))
else
    printf '  PASS  lib/sockopt.sh 不再依赖 tcpdump\n'; pass=$((pass + 1))
fi

echo ""
echo "sockopt-test: $pass passed, $fail failed"
(( fail == 0 ))
