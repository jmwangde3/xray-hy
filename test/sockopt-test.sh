#!/usr/bin/env bash
# sockopt 渲染与 TFO 策略的回归测试。
#
# 锁定的行为（v1.4.0 定稿）：TFO 在服务端**恒关**，脚本不留开启路径。
#   - sockopt_json 永远写 tcpFastOpen:false，不读 TFO 环境变量（老节点 env 里的
#     TFO=1 不参与渲染）
#   - 没有 tfo_decide / target_tfo_probe（v1.3.0 的探测恒返回 false，已删）
#   - CLI 不再接受 --tfo，传入时明确报错而不是静默忽略
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
ck() { # 布尔断言：$1=描述 $2=命令串
    if eval "$2" >/dev/null 2>&1; then
        printf '  PASS  %s\n' "$1"; pass=$((pass + 1))
    else
        printf '  FAIL  %s\n' "$1"; fail=$((fail + 1))
    fi
}

EXPECT='"sockopt":{"tcpFastOpen":false,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpcongestion":"bbr"}'

echo "=== sockopt_json 恒为 false ==="
TFO=0
chk "TFO=0 -> false"          "$EXPECT" "$(sockopt_json)"
TFO=1
chk "TFO=1 -> 仍 false"       "$EXPECT" "$(sockopt_json)"
unset TFO
chk "TFO 未设置 -> false"     "$EXPECT" "$(sockopt_json)"
export TFO=1
chk "TFO 导出到环境 -> 仍 false" "$EXPECT" "$(sockopt_json)"
unset TFO

echo "=== 开启路径已移除 ==="
if declare -F tfo_decide >/dev/null 2>&1; then
    printf '  FAIL  tfo_decide 仍存在（v1.4.0 应已删除）\n'; fail=$((fail + 1))
else
    printf '  PASS  tfo_decide 已删除\n'; pass=$((pass + 1))
fi
if declare -F target_tfo_probe >/dev/null 2>&1; then
    printf '  FAIL  target_tfo_probe 仍存在\n'; fail=$((fail + 1))
else
    printf '  PASS  target_tfo_probe 已删除\n'; pass=$((pass + 1))
fi
ck "lib/sockopt.sh 不再引用 tcpdump"  "! grep -v '^[[:space:]]*#' lib/sockopt.sh | grep -q tcpdump"
ck "lib/nodes.sh 不再调用 tfo_decide" "! grep -q 'tfo_decide' lib/nodes.sh"
ck "reality 分支写死 TFO=0"           "grep -q 'TFO=0' lib/nodes.sh"

echo "=== CLI 明确拒绝 --tfo ==="
ck "--tfo 有专用报错分支"  "grep -q -- '--tfo) die' entry/main.sh"
ck "--tfo 不在帮助里"      "! grep -q -- '--tfo auto' entry/main.sh"
ck "--tfo 不在传参白名单"  "! grep -q -- 'scan-cidr|--tfo' entry/main.sh"

echo ""
echo "sockopt-test: $pass passed, $fail failed"
(( fail == 0 ))
