#!/usr/bin/env bash
# v1.14.2 回归：① relay.env 不再被当成节点 ② update script 自动判定 relay reapply。
# 全程离线：不联网、不需要 root、不需要真实 Xray。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source test/_lib.sh
load_libs
stub_system
init_dirs

PASS=0 FAIL=0

# =========================================================================
echo "=== 1) node_env_files：relay.env / 备份 / 无 MODE 文件都不是节点 ==="
cat >"$XHY_NODES/reality_443.env" <<'EOF'
MODE=reality
PORT=443
PUBLIC=1
UUID=test-uuid-0000
NODE_HOST=203.0.113.10
SNI=example.com
TARGET=203.0.113.20:443
PRIVATE_KEY=x
PUBLIC_KEY=y
SHORT_ID=abcd
SECURITY=reality
CREATED=2026-11-06T22:42:45+08:00
EOF
# 第 2 个合法节点（同模式不同端口），保证 node_count / rebuild 真的处理 2 个
sed 's/^PORT=443$/PORT=8443/' "$XHY_NODES/reality_443.env" >"$XHY_NODES/reality_8443.env"
cat >"$XHY_NODES/relay.env" <<'EOF'
RELAY_ROLE=land
RELAY_PORT=14430
RELAY_ALLOW=203.0.113.30
RELAY_UUID=relay-uuid-0000
RELAY_FW_CHAIN=XHY-IN
RELAY_SECURITY=none
EOF
cp "$XHY_NODES/reality_443.env" "$XHY_NODES/reality_443.env.bak-224412"
printf 'GARBAGE=1\n' >"$XHY_NODES/junk.env"          # 名字不像节点
printf 'GARBAGE=1\n' >"$XHY_NODES/empty_7777.env"    # 名字像节点但没有 MODE=

chk "node_env_files 只返回 2 个真节点"      '[[ "$(node_env_files | wc -l)" -eq 2 ]]'
chk "node_env_files 不含 relay.env"          '! ( node_env_files | grep -q "relay.env" )'
chk "node_env_files 不含 .bak 备份"          '! ( node_env_files | grep -q "\.bak" )'
chk "node_env_files 不含 junk.env"           '! ( node_env_files | grep -q "junk.env" )'
chk "node_env_files 排除无 MODE 的伪节点"   '! ( node_env_files | grep -q "empty_7777.env" )'
chk "node_count 不再把 relay.env 算进去"     '[[ "$(node_count)" -eq 2 ]]'
chk "link_node_files 复用同一过滤器"         '[[ "$(link_node_files | wc -l)" -eq 2 ]]'
chk "源码里 link_node_files 是包装"          'grep -Fq "link_node_files() { node_env_files; }" lib/links.sh'
chk "nodes.sh 里 5 处遍历都走过滤器"         '[[ "$(grep -Fc "for f in \$(node_env_files); do" lib/nodes.sh)" -eq 5 ]]'
chk "export.sh 走过滤器"                     'grep -Fq "for f in \$(node_env_files); do" lib/export.sh'
chk "hardening.sh 两处走过滤器"              '[[ "$(grep -Fc "for f in \$(node_env_files); do" lib/hardening.sh)" -eq 2 ]]'
chk "update.sh 统计走过滤器"                 'grep -Fq "for _f in \$(node_env_files); do" lib/update.sh'

echo ""
echo "=== 2) 列表 / 选择器 / 重建不再被 relay.env 带崩 ==="
LIST_OUT="$(node_list 2>&1)"
chk "node_list 无幽灵空行"                   '[[ "$(printf "%s\n" "$LIST_OUT" | tail -n +3 | grep -c "no  *none  *?" )" -eq 0 ]]'
chk "node_list 只有 2 条数据行"              '[[ "$(printf "%s\n" "$LIST_OUT" | tail -n +3 | grep -c .)" -eq 2 ]]'
chk "node_list 不含 (暂无节点)"              '! ( printf "%s\n" "$LIST_OUT" | grep -q "暂无节点" )'
PICK_OUT="$(node_pick 2>&1)"
chk "node_pick 候选只有 2 个"                '[[ "$(printf "%s\n" "$PICK_OUT" | grep -cE "^  [0-9]+ ")" -eq 2 ]]'
# 旧版：node_rebuild_all 拿 relay.env 去 write_fragment → 「未知节点类型: 」→ rc=1
node_rebuild_all >"$TEST_TMP/rebuild.log" 2>&1
REBUILD_RC=$?
chk "node_rebuild_all 有 relay.env 仍成功"   '[[ '"$REBUILD_RC"' -eq 0 ]]'
chk "rebuild 日志无未知节点类型"             '! grep -q "未知节点类型" "$TEST_TMP/rebuild.log"'
chk "只生成 2 个 inbound fragment"           '[[ "$(ls -1 "$XHY_CONFDIR"/*.json 2>/dev/null | grep -c .)" -eq 2 ]]'
chk "没有空 MODE/PORT 的畸形 fragment"       '! ls "$XHY_CONFDIR"/_*.json >/dev/null 2>&1'

echo ""
echo "=== 3) relay 代码指纹 ==="
# 造最小脚本，不依赖 install.sh 是否已构建
mk_script() { # mk_script <file> <schema> <relay-body>
    cat >"$1" <<EOF
XHY_RELAY_SCHEMA="$2"
# 注释：改这行不应影响指纹
relay_alpha() {
    $3
    printf 'tail\n'
}
extra_outbounds_json() {
    printf '[]\n'
}
not_relay() {
    printf 'unrelated\n'
}
EOF
}
mk_script "$TEST_TMP/a.sh" 1 "printf 'one\n'"
mk_script "$TEST_TMP/b.sh" 1 "printf 'one\n'"
mk_script "$TEST_TMP/c.sh" 1 "printf 'TWO\n'"     # 改 relay 函数体
mk_script "$TEST_TMP/d.sh" 2 "printf 'one\n'"     # 只改 schema
sed -i 's|# 注释：改这行不应影响指纹|# 注释：文案改了|' "$TEST_TMP/b.sh"
sed -i 's|printf .unrelated.|printf .UNRELATED.|' "$TEST_TMP/b.sh"   # 改非 relay 函数
FP_A="$(_update_relay_fingerprint "$TEST_TMP/a.sh")"
FP_B="$(_update_relay_fingerprint "$TEST_TMP/b.sh")"
FP_C="$(_update_relay_fingerprint "$TEST_TMP/c.sh")"
FP_D="$(_update_relay_fingerprint "$TEST_TMP/d.sh")"
chk "指纹非空"                                '[[ -n "$FP_A" ]]'
chk "注释 + 非 relay 函数改动不影响指纹"     '[[ "$FP_A" == "$FP_B" ]]'
chk "relay 函数体改动 → 指纹变化"            '[[ "$FP_A" != "$FP_C" ]]'
chk "XHY_RELAY_SCHEMA 改动 → 指纹变化"       '[[ "$FP_A" != "$FP_D" ]]'
chk "缺失文件 → 空指纹"                      '[[ -z "$(_update_relay_fingerprint "$TEST_TMP/nope.sh")" ]]'
printf 'XHY_RELAY_SCHEMA="1"\nrelay_extra() { printf "new\n"; }\n' >"$TEST_TMP/e.sh"
chk "新增 relay 函数 → 指纹变化"             '[[ "$FP_A" != "$(_update_relay_fingerprint "$TEST_TMP/e.sh")" ]]'
mk_script "$TEST_TMP/f.sh" 1 "printf 'one\n'"
cat >>"$TEST_TMP/f.sh" <<'EOF'
firewall_extra_rules() {
    echo hook
}
EOF
cp "$TEST_TMP/f.sh" "$TEST_TMP/g.sh"
sed -i 's|echo hook|echo HOOK2|' "$TEST_TMP/g.sh"
chk "防火墙钩子函数体改动 → 指纹变化"       '[[ "$(_update_relay_fingerprint "$TEST_TMP/f.sh")" != "$(_update_relay_fingerprint "$TEST_TMP/g.sh")" ]]'
chk "指纹函数自身不以 relay_ 开头（防自指）" 'grep -q "^_update_relay_fingerprint()" lib/update.sh'

echo ""
echo "=== 4) 自动 reapply 判定：三个条件全满足才触发 ==="
RELAY_ENV="$TEST_TMP/relay.env"
printf 'RELAY_ROLE=land\nRELAY_PORT=14430\n' >"$RELAY_ENV"
chk "指纹变 + role=land → 需要"              'update_script_relay_reapply_needed "$TEST_TMP/a.sh" "$TEST_TMP/c.sh" "$RELAY_ENV"'
printf 'RELAY_ROLE=entry\n' >"$RELAY_ENV"
chk "指纹变 + role=entry → 需要"             'update_script_relay_reapply_needed "$TEST_TMP/a.sh" "$TEST_TMP/c.sh" "$RELAY_ENV"'
printf 'RELAY_ROLE=bogus\n' >"$RELAY_ENV"
chk "无效角色 → 不触发"                      '! update_script_relay_reapply_needed "$TEST_TMP/a.sh" "$TEST_TMP/c.sh" "$RELAY_ENV"'
printf 'RELAY_ROLE=land\n' >"$RELAY_ENV"
chk "指纹没变 → 不触发"                      '! update_script_relay_reapply_needed "$TEST_TMP/a.sh" "$TEST_TMP/b.sh" "$RELAY_ENV"'
chk "无 relay.env → 不触发"                  '! update_script_relay_reapply_needed "$TEST_TMP/a.sh" "$TEST_TMP/c.sh" "$TEST_TMP/missing.env"'
chk "旧脚本缺失 → 不触发（宁可不碰）"       '! update_script_relay_reapply_needed "$TEST_TMP/nope.sh" "$TEST_TMP/c.sh" "$RELAY_ENV"'
chk "schema 变 → 需要"                       'update_script_relay_reapply_needed "$TEST_TMP/a.sh" "$TEST_TMP/d.sh" "$RELAY_ENV"'

echo ""
echo "=== 5) update_script 接线 ==="
chk "prelude 定义 XHY_RELAY_SCHEMA"          'grep -q "^XHY_RELAY_SCHEMA=" entry/prelude.sh'
chk "替换前调用判定函数"                     'grep -Fq "update_script_relay_reapply_needed \"\$old_src\" \"\$tmp\"" lib/update.sh'
chk "替换后执行 canonical relay reapply"     'grep -Fq "\"\$canonical\" relay reapply" lib/update.sh'
chk "失败只 warn 不让升级失败"               'grep -q "自动 relay reapply 失败" lib/update.sh'
chk "起子进程前先释放父进程配置锁"          'grep -q "^        release_lock$" lib/update.sh'
chk "起子进程前关闭继承的 flock fd 9"       'grep -q "^        exec 9>&- 2>/dev/null || true$" lib/update.sh'
chk "hardening 有防火墙空钩子"               'grep -q "^firewall_extra_rules() { return 0; }" lib/hardening.sh'
chk "_apply_family 调用钩子"                 '[[ "$(grep -Fc "firewall_extra_rules" lib/hardening.sh)" -eq 2 ]]'
chk "relay.sh 覆盖钩子"                      'grep -q "^firewall_extra_rules()" lib/relay.sh'

summary
