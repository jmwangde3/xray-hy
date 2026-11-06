#!/usr/bin/env bash
# 伪装站选择 / 删除节点选择器的离线断言。不联网、不需要 root。
set -u
source "$(dirname "$0")/_lib.sh"
load_libs

XHY_NODES="$TEST_TMP/nodes"
mkdir -p "$XHY_NODES"

# ---- IP 字面量判定 ----
chk "IPv4 被识别"            'is_ip_literal 1.2.3.4'
chk "域名不算 IP"            '! is_ip_literal www.example.com'
chk "带端口不算 IP"          '! is_ip_literal 1.2.3.4:443'
chk "含数字的域名不算 IP"    '! is_ip_literal www.1.2.3.4.com'

# ---- target 是 IP 却没给 SNI：必须快速失败，且提示要 sni= ----
out="$(target_validate 1.2.3.4:443 2>&1)" && rc=0 || rc=$?
chk "IP 无 SNI 被拒绝"       '[[ "$rc" -ne 0 ]]'
chk "拒绝信息提到 SNI"       '[[ "$out" == *SNI* ]]'
unset rc out

# ---- node_pick：编号选择 ----
cat >"$XHY_NODES/reality_443.env" <<'ENV'
MODE=reality
PORT=443
PUBLIC=1
SNI=www.a.example
TARGET=1.1.1.1:443
CREATED=2026-11-01T10:00:00+08:00
ENV
cat >"$XHY_NODES/direct_8080.env" <<'ENV'
MODE=direct
PORT=8080
PUBLIC=1
NODE_HOST=1.2.3.4
CREATED=2026-11-02T10:00:00+08:00
ENV
cat >"$XHY_NODES/hy2_8443.env" <<'ENV'
MODE=hy2
PORT=8443
PUBLIC=1
SNI=www.b.example
CREATED=2026-11-03T10:00:00+08:00
ENV

# 用 here-string 而不是管道：管道会把 node_pick 放进子 shell，MODE/PORT 传不回来
node_pick <<<"2" >/dev/null 2>&1 && rc=0 || rc=$?
# 列表按文件名排序：direct_8080 -> hy2_8443 -> reality_443
chk "选 2 得到第二个节点"     '[[ "$rc" -eq 0 && "${MODE:-}" == hy2 && "${PORT:-}" == 8443 ]]'

node_pick <<<"3" >/dev/null 2>&1 && rc=0 || rc=$?
chk "选 3 得到第三个节点"     '[[ "$rc" -eq 0 && "${MODE:-}" == reality && "${PORT:-}" == 443 ]]'

node_pick <<<"" >/dev/null 2>&1 && rc=0 || rc=$?
chk "空输入取消且非零退出"    '[[ "$rc" -ne 0 ]]'

node_pick <<<"9" >/dev/null 2>&1 && rc=0 || rc=$?
chk "越界编号被拒绝"          '[[ "$rc" -ne 0 ]]'

node_pick <<<"abc" >/dev/null 2>&1 && rc=0 || rc=$?
chk "非数字被拒绝"            '[[ "$rc" -ne 0 ]]'

# 空目录：应报「暂无节点」而不是崩
XHY_NODES="$TEST_TMP/empty-nodes"; mkdir -p "$XHY_NODES"
node_pick <<<"1" >/dev/null 2>&1 && rc=0 || rc=$?
chk "无节点时返回非零"        '[[ "$rc" -ne 0 ]]'

summary
