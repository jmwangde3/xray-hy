#!/usr/bin/env bash
# sockopt 渲染的回归测试。
#
# 锁定的行为：
#   v1.4.0 —— TFO 在服务端**恒关**，脚本不留开启路径
#     - sockopt_json 永远写 tcpFastOpen:false，不读 TFO 环境变量
#     - 没有 tfo_decide / target_tfo_probe（v1.3.0 的探测恒返回 false，已删）
#     - CLI 不再接受 --tfo，传入时明确报错而不是静默忽略
#   v1.4.2 —— tcpcongestion 按内核能力决定写不写
#     - available_congestion_control 含 bbr -> 写 "tcpcongestion":"bbr"
#     - 不含/读不到         -> 整个字段省略（继承内核默认，不写 cubic）
#     - 其余四字段在任何情况下都在（tcpNoDelay/keepAliveIdle/uto/tcpMptcp）
#     - tcpFastOpenQueueLength 永不出现（TFO 关了，队列长度无意义）
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

BASE='"tcpFastOpen":false,"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpMptcp":false'
EXPECT_NO_BBR="\"sockopt\":{$BASE}"
EXPECT_BBR="\"sockopt\":{$BASE,\"tcpcongestion\":\"bbr\"}"

# 注入内核能力并清缓存（否则第一次判定会被缓存住）
cc_stub() { XHY_SOCKOPT_CC=""; XHY_SOCKOPT_AVAIL_CC="$1"; }

echo "=== tcpcongestion 按内核能力渲染（v1.4.2）==="
cc_stub "reno cubic bbr"
chk "可用 bbr -> 写 bbr"        "$EXPECT_BBR"    "$(sockopt_json)"
cc_stub "reno cubic"
chk "无 bbr -> 省略字段"        "$EXPECT_NO_BBR" "$(sockopt_json)"
cc_stub "bbr"
chk "仅 bbr -> 写 bbr"          "$EXPECT_BBR"    "$(sockopt_json)"
cc_stub ""
chk "读不到 -> 省略字段"        "$EXPECT_NO_BBR" "$(sockopt_json)"
cc_stub "cubic"
chk "只有 cubic -> 省略字段"    "$EXPECT_NO_BBR" "$(sockopt_json)"
cc_stub "cubic reno"
chk "不含 bbr 子串 -> 省略"     "$EXPECT_NO_BBR" "$(sockopt_json)"
cc_stub "bbr2"
chk "bbr2 不算 bbr -> 省略"     "$EXPECT_NO_BBR" "$(sockopt_json)"

echo "=== 四个无关字段在任何内核上都保留 ==="
for cc in "" "reno cubic" "reno cubic bbr"; do
    cc_stub "$cc"
    out="$(sockopt_json)"
    chk "cc=[$cc] 保留 tcpKeepAliveIdle=45"  "1" "$(printf '%s' "$out" | grep -c '"tcpKeepAliveIdle":45')"
    chk "cc=[$cc] 保留 tcpUserTimeout=10000" "1" "$(printf '%s' "$out" | grep -c '"tcpUserTimeout":10000')"
    chk "cc=[$cc] 保留 tcpNoDelay:true"      "1" "$(printf '%s' "$out" | grep -c '"tcpNoDelay":true')"
    chk "cc=[$cc] 保留 tcpMptcp:false"       "1" "$(printf '%s' "$out" | grep -c '"tcpMptcp":false')"
done

echo "=== TFO 恒为 false ==="
cc_stub "reno cubic bbr"
TFO=0
chk "TFO=0 -> false"            "$EXPECT_BBR" "$(sockopt_json)"
TFO=1
chk "TFO=1 -> 仍 false"         "$EXPECT_BBR" "$(sockopt_json)"
unset TFO
chk "TFO 未设置 -> false"       "$EXPECT_BBR" "$(sockopt_json)"
export TFO=1
chk "TFO 导出到环境 -> 仍 false" "$EXPECT_BBR" "$(sockopt_json)"
unset TFO
ck "任何情况下都不写 tcpFastOpenQueueLength" \
   "! sockopt_json | grep -q tcpFastOpenQueueLength"
ck "任何情况下都不出现 \"tcpFastOpen\":true" \
   "! sockopt_json | grep -q '\"tcpFastOpen\":true'"
cc_stub "reno cubic"
ck "无 bbr 时同样不写 queueLength" \
   "! sockopt_json | grep -q tcpFastOpenQueueLength"

echo "=== 输出是合法 JSON ==="
cc_stub "reno cubic bbr"
ck "有 bbr 时为合法 JSON" \
   "$PY -c 'import json,sys; json.loads(\"{\"+sys.argv[1]+\"}\")' \"\$(sockopt_json)\""
cc_stub "reno cubic"
ck "无 bbr 时为合法 JSON" \
   "$PY -c 'import json,sys; json.loads(\"{\"+sys.argv[1]+\"}\")' \"\$(sockopt_json)\""

echo "=== 真实 sysctl 路径不崩 ==="
unset XHY_SOCKOPT_AVAIL_CC XHY_SOCKOPT_CC
ck "读真实 sysctl 后渲染成功" "sockopt_json | grep -q tcpKeepAliveIdle"
ck "sockopt_cc_available 返回 0 或 1" \
   "sockopt_cc_available; rc=\$?; [[ \$rc -eq 0 || \$rc -eq 1 ]]"

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
