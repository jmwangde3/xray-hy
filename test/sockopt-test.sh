#!/usr/bin/env bash
# sockopt 渲染的回归测试。
#
# 锁定行为：
#   v1.4.2 —— tcpcongestion 按内核能力决定写不写
#     - available_congestion_control 含 bbr -> 写 "tcpcongestion":"bbr"
#     - 不含/读不到 -> 整个字段省略（继承内核默认，不写 cubic）
#   v1.4.3 —— TFO 默认跟随伪装站，用户可显式覆盖
#     - 节点 env 的 TFO=1 -> tcpFastOpen:true；0/未设置 -> false
#     - tfo_decide on/off/auto 决策表；auto 走 target_tfo_detect（离线 stub 为不支持）
#     - --tfo 重新成为合法 CLI 选项，帮助里有说明
#   两者共通：其余四个字段无条件保留、tcpFastOpenQueueLength 永不写
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

TAIL='"tcpNoDelay":true,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpMptcp":false'
EXPECT_NO_BBR="\"sockopt\":{\"tcpFastOpen\":false,$TAIL}"
EXPECT_BBR="\"sockopt\":{\"tcpFastOpen\":false,$TAIL,\"tcpcongestion\":\"bbr\"}"
EXPECT_TFO="\"sockopt\":{\"tcpFastOpen\":true,$TAIL,\"tcpcongestion\":\"bbr\"}"

# 注入内核能力并清缓存（否则第一次判定会被缓存住）
cc_stub() { XHY_SOCKOPT_CC=""; XHY_SOCKOPT_AVAIL_CC="$1"; }
reset_env() { unset TFO; cc_stub "reno cubic bbr"; }

echo "=== tcpcongestion 按内核能力渲染（v1.4.2）==="
reset_env
cc_stub "reno cubic bbr"
chk "可用 bbr -> 写 bbr"        "$EXPECT_BBR"    "$(sockopt_json)"
cc_stub "reno cubic"
chk "无 bbr -> 省略字段"        "$EXPECT_NO_BBR" "$(sockopt_json)"
cc_stub "bbr"
chk "仅 bbr -> 写 bbr"          "$EXPECT_BBR"    "$(sockopt_json)"
cc_stub ""
chk "读不到 -> 省略字段"        "$EXPECT_NO_BBR" "$(sockopt_json)"
cc_stub "bbr2"
chk "bbr2 不算 bbr -> 省略"     "$EXPECT_NO_BBR" "$(sockopt_json)"

echo "=== TFO 跟随节点 env（v1.4.3）==="
reset_env
TFO=0
chk "TFO=0 -> false"            "$EXPECT_BBR" "$(sockopt_json)"
TFO=1
chk "TFO=1 -> true"             "$EXPECT_TFO" "$(sockopt_json)"
unset TFO
chk "TFO 未设置 -> false"       "$EXPECT_BBR" "$(sockopt_json)"
export TFO=1
chk "TFO 导出到环境 -> true"    "$EXPECT_TFO" "$(sockopt_json)"
unset TFO
cc_stub "reno cubic"
TFO=1
chk "无 bbr + TFO=1 仍写 true"  "\"sockopt\":{\"tcpFastOpen\":true,$TAIL}" "$(sockopt_json)"
unset TFO

echo "=== 四个无关字段在任何内核上、任何 TFO 下都保留 ==="
for cc in "" "reno cubic" "reno cubic bbr"; do
    for tv in 0 1; do
        cc_stub "$cc"; TFO="$tv"
        out="$(sockopt_json)"
        chk "cc=[$cc] tfo=$tv 保留 keepAliveIdle"  "1" "$(printf '%s' "$out" | grep -c '"tcpKeepAliveIdle":45')"
        chk "cc=[$cc] tfo=$tv 保留 userTimeout"    "1" "$(printf '%s' "$out" | grep -c '"tcpUserTimeout":10000')"
        chk "cc=[$cc] tfo=$tv 保留 tcpNoDelay"     "1" "$(printf '%s' "$out" | grep -c '"tcpNoDelay":true')"
        chk "cc=[$cc] tfo=$tv 保留 tcpMptcp"       "1" "$(printf '%s' "$out" | grep -c '"tcpMptcp":false')"
    done
done
unset TFO

echo "=== 不写 queueLength / 输出合法 JSON ==="
reset_env
ck "永不写 tcpFastOpenQueueLength" "! sockopt_json | grep -q tcpFastOpenQueueLength"
ck "有 bbr 时为合法 JSON" \
   "$PY -c 'import json,sys; json.loads(\"{\"+sys.argv[1]+\"}\")' \"\$(sockopt_json)\""
cc_stub "reno cubic"
ck "无 bbr 时为合法 JSON" \
   "$PY -c 'import json,sys; json.loads(\"{\"+sys.argv[1]+\"}\")' \"\$(sockopt_json)\""
TFO=1
ck "TFO=1 时也是合法 JSON" \
   "$PY -c 'import json,sys; json.loads(\"{\"+sys.argv[1]+\"}\")' \"\$(sockopt_json)\""
unset TFO

echo "=== 真实 sysctl 路径不崩 ==="
unset XHY_SOCKOPT_AVAIL_CC XHY_SOCKOPT_CC TFO
ck "读真实 sysctl 后渲染成功" "sockopt_json | grep -q tcpKeepAliveIdle"
ck "sockopt_cc_available 返回 0 或 1" \
   "sockopt_cc_available; rc=\$?; [[ \$rc -eq 0 || \$rc -eq 1 ]]"

echo "=== tfo_decide 决策表（auto 的探测在离线被 stub 为「不支持」）==="
chk "on -> 1"        "1" "$(tfo_decide on 47.88.102.65 443 www.easeus.com)"
chk "off -> 0"       "0" "$(tfo_decide off 47.88.102.65 443 www.easeus.com)"
chk "auto -> 0（目标不支持）" "0" "$(tfo_decide auto 47.88.102.65 443 www.easeus.com)"
chk "auto 空 dest -> 0"      "0" "$(tfo_decide auto '' 443 '')"
chk "未知 mode -> 0"         "0" "$(tfo_decide bogus 47.88.102.65 443 x)"
ck "target_tfo_detect 存在"  "declare -F target_tfo_detect >/dev/null"

echo "=== CLI 与说明 ==="
ck "--tfo 在传参白名单"   "grep -q -- 'scan-cidr|--tfo' entry/main.sh"
ck "--tfo 不在 die 分支"  "! grep -q -- '--tfo) die' entry/main.sh"
ck "帮助列出 --tfo"       "grep -q -- '--tfo auto|on|off' entry/main.sh"
ck "帮助解释跟随逻辑"     "grep -q '默认跟随伪装站' entry/main.sh"
ck "target_help 有 TFO 段" "grep -q 'TFO 与伪装站' lib/target.sh"
ck "scanner 注释说明不纳入打分" "grep -q '不把 TFO 能力纳入打分' lib/scanner.sh"
ck "nodes.sh 用 tfo_decide"    "grep -q 'tfo_decide' lib/nodes.sh"
ck "nodes.sh 不写死 reality TFO=0" \
   "! grep -q '\"SECURITY=reality\" \"TFO=0\"' lib/nodes.sh"
ck "check 不再写『固定，无开关』"   "! grep -q '固定，无开关' lib/update.sh"
ck "check 显示跟随伪装站"           "grep -q '跟随伪装站' lib/update.sh"
ck "check 统计节点 TFO 开/关"       "grep -q '_tfo_on' lib/update.sh"

echo ""
echo "sockopt-test: $pass passed, $fail failed"
(( fail == 0 ))
