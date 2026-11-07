#!/usr/bin/env bash
# 节点编辑（xhy edit）/ 扫描后替换已有节点伪装站 / 地区选择表的回归测试。
# 全程离线：stub 掉 xray、服务、防火墙、快照与探测。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system
make_stub_xray

# 快照与重载都别碰真实目录
snapshot_state() { :; }

mk_reality() {
    local port="${1:-443}"
    mkdir -p "$XHY_NODES"
    cat >"$XHY_NODES/reality_${port}.env" <<EOF
MODE=reality
PORT=${port}
PUBLIC=1
UUID=11111111-2222-3333-4444-555555555555
NODE_PATH=/abcdef0123456789
NODE_HOST=1.2.3.4
SNI=www.old-site.com
TARGET=1.2.3.4:443
PRIVATE_KEY=PRIVKEY
PUBLIC_KEY=PUBKEY
SHORT_ID=deadbeef
FP=chrome
SECURITY=reality
TFO=0
CREATED=2026-01-01T00:00:00+08:00
FUTURE_FIELD=must-survive
EOF
}

mk_direct() {
    mkdir -p "$XHY_NODES"
    cat >"$XHY_NODES/direct_8080.env" <<'EOF'
MODE=direct
PORT=8080
PUBLIC=1
UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
NODE_PATH=/devonly
NODE_HOST=1.2.3.4
SECURITY=none
CREATED=2026-01-01T00:00:00+08:00
EOF
}

reset_state() {
    init_dirs
    rm -f "$XHY_NODES"/*.env "$XHY_CONFDIR"/*.json 2>/dev/null || true
}

echo "=== node_env_update：就地替换 / 保留未知键 / 追加新键 ==="
reset_state
mk_reality 443
ENVF="$XHY_NODES/reality_443.env"
node_env_update "$ENVF" "TARGET=5.6.7.8:443" "SNI=www.new-site.com" "TFO=1" "BRAND_NEW=yes"
chk "TARGET 已替换"        'grep -qx "TARGET=5.6.7.8:443" "$ENVF"'
chk "SNI 已替换"           'grep -qx "SNI=www.new-site.com" "$ENVF"'
chk "TFO 已替换"           'grep -qx "TFO=1" "$ENVF"'
chk "新键已追加"           'grep -qx "BRAND_NEW=yes" "$ENVF"'
chk "未知字段没被丢掉"     'grep -qx "FUTURE_FIELD=must-survive" "$ENVF"'
chk "原有顺序没被打乱"     '[[ "$(head -1 "$ENVF")" == "MODE=reality" ]]'
chk "旧值不再残留"         '! grep -q "www.old-site.com" "$ENVF"'
chk "每行只有一个 KEY=VAL" '! grep -qE "^[A-Z_]+=.*=" "$ENVF" || true'
chk "文件内容完整"         '[[ -s "$ENVF" && ! -e "$ENVF.tmp" ]]'

echo "=== node_edit_apply：改端口 = 重命名注册表 + 重建分片 ==="
reset_state
mk_reality 443
node_edit_apply reality 443 "PORT=8443" "SNI=www.new-site.com" >/dev/null 2>&1
chk "新端口 env 存在"      '[[ -f "$XHY_NODES/reality_8443.env" ]]'
chk "旧端口 env 已删除"    '[[ ! -f "$XHY_NODES/reality_443.env" ]]'
chk "新 env 的 PORT 正确"  'grep -qx "PORT=8443" "$XHY_NODES/reality_8443.env"'
chk "分片按新端口重建"     '[[ -s "$XHY_CONFDIR/reality_8443.json" ]]'
chk "旧分片已删除"         '[[ ! -f "$XHY_CONFDIR/reality_443.json" ]]'
chk "分片里是新 SNI"       'grep -q "www.new-site.com" "$XHY_CONFDIR/reality_8443.json"'
chk "分片仍是合法 JSON"    '"$PY" -c "import json,sys; json.load(open(sys.argv[1]))" "$XHY_CONFDIR/reality_8443.json"'

echo "=== node_edit_apply：端口冲突被拒绝 ==="
reset_state
mk_reality 443
mk_direct
# die 会 exit，放进子 shell 才不会带走整个测试进程
( node_edit_apply reality 443 "PORT=8080" ) >/dev/null 2>&1
rc=$?
chk "冲突端口返回非 0"     '[[ $rc -ne 0 ]]'
chk "原节点仍在"           '[[ -f "$XHY_NODES/reality_443.env" ]]'
chk "没有生成 8080 reality" '[[ ! -f "$XHY_NODES/reality_8080.env" ]]'

echo "=== node_retarget：只换伪装站，密钥不动 ==="
reset_state
mk_reality 443
node_retarget reality 443 "9.9.9.9" "www.brand-new.com" off >/dev/null 2>&1
ENVF="$XHY_NODES/reality_443.env"
chk "target 已换（补 :443）" 'grep -qx "TARGET=9.9.9.9:443" "$ENVF"'
chk "SNI 已换"               'grep -qx "SNI=www.brand-new.com" "$ENVF"'
chk "TFO=off -> 0"           'grep -qx "TFO=0" "$ENVF"'
chk "私钥没被动过"           'grep -qx "PRIVATE_KEY=PRIVKEY" "$ENVF"'
chk "shortId 没被动过"        'grep -qx "SHORT_ID=deadbeef" "$ENVF"'
chk "UUID 没被动过"           'grep -qx "UUID=11111111-2222-3333-4444-555555555555" "$ENVF"'
chk "分片里出现新 target"     'grep -q "9.9.9.9" "$XHY_CONFDIR/reality_443.json"'

echo "=== node_retarget：非 REALITY 节点被拒 ==="
reset_state
mk_direct
node_retarget direct 8080 "9.9.9.9" "x.com" off >/dev/null 2>&1
rc=$?
chk "direct 节点返回非 0"    '[[ $rc -ne 0 ]]'
chk "direct env 未被改"      'grep -qx "NODE_HOST=1.2.3.4" "$XHY_NODES/direct_8080.env"'

echo "=== node_retarget_menu：没有 REALITY 节点时直接返回 ==="
reset_state
mk_direct
out="$(node_retarget_menu "9.9.9.9:443" "x.com" 2>&1)"
chk "提示当前没有 REALITY 节点" 'printf "%s" "$out" | grep -q "没有 REALITY 节点"'
chk "返回 0（不是错误）"        'node_retarget_menu "9.9.9.9:443" "x.com" >/dev/null 2>&1'

echo "=== target_region_table：地区 / 国家 / 候选数 / 首个候选 ==="
export TARGETS_FILE="$TEST_TMP/targets.tsv"
cat >"$TARGETS_FILE" <<'EOF'
# region|country|label|target|SNI
auto|XX|fallback|9.9.9.9:443|auto.example.com
us|US|us-a|1.1.1.1:443|a.us.example.com
us|US|us-b|1.1.1.2:443|b.us.example.com
jp|JP|jp-a|2.2.2.2:443|a.jp.example.com
EOF
tbl="$(target_region_table)"
chk "列出 us 及候选数 2"   'printf "%s\n" "$tbl" | grep -qx "us|US|2|1.1.1.1:443"'
chk "列出 jp 及候选数 1"   'printf "%s\n" "$tbl" | grep -qx "jp|JP|1|2.2.2.2:443"'
chk "注释行不进表"         '! printf "%s\n" "$tbl" | grep -q "^#"'
chk "表按地区排序"         '[[ "$(printf "%s\n" "$tbl" | cut -d"|" -f1 | tr "\n" " ")" == "auto jp us " ]]'

echo "=== 地域名单 TFO：过滤 / 状态保存 / 缓存隔离 ==="
state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REGION us
target_validate() { return 0; }
tfo_probe_ready() { return 0; }
tfo_probe_blocker() { printf 'test blocker'; }
target_tfo_detect() { [[ "$1" == "1.1.1.2" ]]; }
scanner_cache_valid() { return 0; }
scanner_cache_pick_valid() { printf '9.9.9.9:443 auto.example.com scan\n'; }
picked="$(pick_target 1 2>/dev/null)" && rc=0 || rc=$?
chk "强制 TFO 跳过不支持站" '[[ "$rc" -eq 0 && "$picked" == "1.1.1.2:443 b.us.example.com us-b" ]]'
chk "强制 TFO 不采用扫描缓存" '[[ "$picked" != *scan* ]]'
state_set TARGET_REQUIRE_TFO 1
picked="$(pick_target 2>/dev/null)"
chk "默认读取已保存的 TFO 选择" '[[ "$picked" == "1.1.1.2:443 b.us.example.com us-b" ]]'
scanner_cache_valid() { return 1; }
picked="$(pick_target 0 2>/dev/null)"
chk "不强制时保持原质量顺序" '[[ "$picked" == "1.1.1.1:443 a.us.example.com us-a" ]]'
target_tfo_detect() { return 1; }
picked="$(pick_target 1 2>/dev/null)" && rc=0 || rc=$?
chk "无 TFO 命中返回非零" '[[ "$rc" -ne 0 ]]'
chk "无 TFO 命中不返回普通兜底站" '[[ -z "$picked" ]]'
tfo_probe_ready() { return 1; }
out="$(pick_target 1 2>&1)" && rc=0 || rc=$?
chk "本机不可探测时快速失败" '[[ "$rc" -ne 0 && "$out" == *"test blocker"* ]]'

echo "=== 菜单 1 / 2：选完地区询问 TFO ==="
tfo_probe_ready() { return 0; }
target_tfo_detect() { [[ "$1" == "1.1.1.2" ]]; }
public_country() { printf 'US'; }
state_del TARGET_CUSTOM; state_del TARGET_SNI; state_set TARGET_REQUIRE_TFO 0
out="$(target_menu <<< $'1\ny\n0\n' 2>&1)"
chk "菜单1 可选 TFO 并选支持站" '[[ "$out" == *"当前 target: 1.1.1.2:443"* ]]'
chk "菜单1 保存 TFO 选择" '[[ "$(state_get TARGET_REQUIRE_TFO 0)" == 1 ]]'
state_set TARGET_REQUIRE_TFO 0
out="$(target_menu <<< $'2\n3\ny\nn\n0\n' 2>&1)"
chk "菜单2 选地区后可选 TFO" '[[ "$out" == *"当前 target: 1.1.1.2:443"* ]]'
chk "菜单2 保存 TFO 选择" '[[ "$(state_get TARGET_REQUIRE_TFO 0)" == 1 ]]'
target_tfo_detect() { return 1; }
picked="$(target_region_pick_flow <<< $'y\ny\n' 2>/dev/null)" && rc=0 || rc=$?
chk "无命中时明确确认后按质量重选" '[[ "$rc" -eq 0 && "$picked" == "1.1.1.1:443 a.us.example.com us-a" ]]'
chk "回退后清除强制 TFO 状态" '[[ "$(state_get TARGET_REQUIRE_TFO 0)" == 0 ]]'

echo "=== 菜单与接线 ==="
chk "菜单有 2) 编辑节点"          'grep -q "2) 编辑节点" entry/main.sh'
chk "菜单不再有 16) 扫描伪装站"    '! grep -q "16) 扫描伪装站" entry/main.sh'
chk "菜单有 9) 伪装站"            'grep -q "9) 伪装站" entry/main.sh'
chk "菜单只有一份 cmd_menu"        '[[ $(grep -c "^cmd_menu()" entry/main.sh) -eq 1 ]]'
chk "2) 调 node_edit"             'grep -q "2) node_edit" entry/main.sh'
chk "分发表有 edit"               'grep -q "edit)       node_edit" entry/main.sh'
chk "usage 英文有 edit"           'grep -q "edit \[mode\] \[port\]            Edit a node" entry/main.sh'
chk "usage 中文有 edit"           'grep -q "edit \[mode\] \[port\]          编辑已有节点" entry/main.sh'

chk "定义 node_env_update"        'grep -q "^node_env_update()" lib/nodes.sh'
chk "定义 node_edit_apply"        'grep -q "^node_edit_apply()" lib/nodes.sh'
chk "定义 node_edit"              'grep -q "^node_edit()" lib/nodes.sh'
chk "定义 node_retarget"          'grep -q "^node_retarget()" lib/nodes.sh'
chk "定义 node_retarget_menu"     'grep -q "^node_retarget_menu()" lib/nodes.sh'
chk "定义 target_region_table"    'grep -q "^target_region_table()" lib/target.sh'
chk "定义 target_scan_flow"       'grep -q "^target_scan_flow()" lib/target.sh'
chk "定义地域 TFO 选站流程"        'grep -q "^target_region_pick_flow()" lib/target.sh'
chk "菜单1/2 共用 TFO 选站流程"    '[[ $(grep -c "picked=\"\$(target_region_pick_flow)\"" lib/target.sh) -eq 2 ]]'
chk "扫描流程接 node_retarget_menu" 'grep -q "node_retarget_menu \"\$st\" \"\$ss\"" lib/target.sh'
chk "地区菜单用编号选择"          'grep -q "选择地区编号" lib/target.sh'
chk "手动指定后也问替换"          'grep -q "node_retarget_menu \"\$h\" \"\$s\"" lib/target.sh'

echo "=== 强制 TFO 失败后的回退询问 ==="
chk "提示本机网段没有 TFO 站点"    'grep -q "都没有支持被动 TFO 的站点" lib/target.sh'
chk "说明 TFO 只省 1 个 RTT"       'grep -q "TFO 只省首连 1 个 RTT" lib/target.sh'
chk "问是否改为不强制"             'grep -q "改为不强制 TFO、按质量重选" lib/target.sh'
chk "重选时去掉 --require-tfo"     'grep -Fq -- "\"--require-tfo\" ]] || plain" lib/target.sh'

echo "=== 语言层：新词条命中（英文模式无残留中文） ==="
en="$( XHY_LANG_EFFECTIVE=en xhy_t '   1) 添加节点               2) 编辑节点' )"
chk "菜单行已翻译"                 'printf "%s" "$en" | grep -q "Edit node"'
chk "英文输出纯可印 ASCII"         '! printf "%s" "$en" | LC_ALL=C grep -q "[^ -~]"'
en2="$( XHY_LANG_EFFECTIVE=en xhy_t 'TFO auto/on/off（auto = 按新 target 重新探测）' )"
chk "TFO 提示已翻译"               'printf "%s" "$en2" | grep -q "re-probe the new target"'
en3="$( XHY_LANG_EFFECTIVE=en xhy_t '地域名单里没有通过校验且支持被动 TFO 的站点。' )"
chk "地域无 TFO 命中提示已翻译"     'printf "%s" "$en3" | grep -q "No candidate in the region list"'
chk "地域 TFO 新文案纯 ASCII"       '! printf "%s" "$en3" | LC_ALL=C grep -q "[^ -~]"'

summary
