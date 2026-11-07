#!/usr/bin/env bash
# Node lifecycle regression: add -> snapshot -> delete -> rollback, plus port
# uniqueness and REALITY target fallback ordering.
#
# The snapshot assertions are the important ones: they cover the "node deleted
# before the rebuild" ordering bug, where a snapshot could capture a config.json
# that referenced credentials which no longer existed.
set -u
# shellcheck source=test/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
load_libs
stub_system
make_stub_xray
init_dirs

n_inbounds() { grep -c '"tag": "in-' "$XHY_ETC/config.json" 2>/dev/null || echo 0; }

echo "=== add nodes ==="
node_add direct 18080 --host 1.2.3.4 --path /abc >/dev/null 2>&1
chk "direct env created"    "[[ -f '$XHY_NODES/direct_18080.env' ]]"
chk "direct fragment"       "[[ -s '$XHY_CONFDIR/direct_18080.json' ]]"
chk "config.json created"   "[[ -s '$XHY_ETC/config.json' ]]"
chk "config parses"         "$PY -c 'import json,sys; json.load(open(sys.argv[1]))' '$XHY_ETC/config.json'"

node_add reality 18443 --host 1.2.3.4 --target www.example.com:443 --sni www.example.com >/dev/null 2>&1
chk "reality env created"   "[[ -f '$XHY_NODES/reality_18443.env' ]]"
chk "reality public key"    "grep -q '^PUBLIC_KEY=.\+' '$XHY_NODES/reality_18443.env'"
chk "two inbounds"          "[[ \$(n_inbounds) -eq 2 ]]"

node_add hy2 18444 --host 1.2.3.4 --sni www.bing.com >/dev/null 2>&1
chk "hy2 env created"       "[[ -f '$XHY_NODES/hy2_18444.env' ]]"
chk "hy2 certificate"       "[[ -s '$XHY_CERTS/hy2_18444.crt' ]]"
chk "hy2 key non-empty"     "[[ -s '$XHY_CERTS/hy2_18444.key' ]]"
chk "hy2 link has pin"      "link_uri '$XHY_NODES/hy2_18444.env' | grep -q 'pinSHA256=.'"

echo "=== snapshot shape ==="
snaps=$(ls -1 "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
chk "at least 3 snapshots"       "(( $snaps >= 3 ))"
chk "kept to at most 5"          "(( $snaps <= 5 ))"
newest=$(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz | head -1)
chk "no config.json in snapshot" "! tar tzf '$newest' | grep -qx 'config.json'"
chk "snapshot has certs/"        "tar tzf '$newest' | grep -q '^certs/'"
chk "snapshot has state.env"     "tar tzf '$newest' | grep -qx 'state.env'"
chk "snapshot has nodes/"        "tar tzf '$newest' | grep -q '^nodes/'"

echo "=== delete then roll back ==="
node_del hy2 18444 >/dev/null 2>&1
chk "hy2 env removed"       "[[ ! -f '$XHY_NODES/hy2_18444.env' ]]"
chk "cert removed"          "[[ ! -f '$XHY_CERTS/hy2_18444.crt' ]]"
chk "two inbounds left"     "[[ \$(n_inbounds) -eq 2 ]]"

rollback_config >/dev/null 2>&1
chk "hy2 env restored"      "[[ -f '$XHY_NODES/hy2_18444.env' ]]"
chk "cert restored"         "[[ -s '$XHY_CERTS/hy2_18444.crt' ]]"
chk "three inbounds again"  "[[ \$(n_inbounds) -eq 3 ]]"
chk "pre-rollback copy kept" "ls '$XHY_SNAPSHOTS'/state.pre-rollback.*.tar.gz >/dev/null 2>&1"

echo "=== port uniqueness across modes ==="
out=$(node_add direct 18443 --host 1.2.3.4 2>&1); rc=$?
chk "duplicate port rejected" "[[ $rc -ne 0 ]] && grep -q '已被节点' <<<\"\$out\""

echo "=== REALITY target fallback order ==="
TARGETS_FILE="$TEST_TMP/targets.tsv"
printf '%s\n' '# header' \
    'other|XX|fallback|fallback.test:443|fallback.test' \
    'sg|SG|sg-first|sg.test:443|sg.test' >"$TARGETS_FILE"
export TARGETS_FILE
state_set TARGET_REGION sg
chk "region row beats generic" "pick_target 2>/dev/null | grep -q 'sg.test'"
printf '%s\n' '# header' 'other|XX|fallback|fallback.test:443|fallback.test' >"$TARGETS_FILE"
chk "falls back when region empty" "pick_target 2>/dev/null | grep -q 'fallback.test'"
printf '\357\273\277# bom header\nsg|SG|sg-first|sg.test:443|sg.test\n' >"$TARGETS_FILE"
chk "BOM header is not a region" "! target_list_regions | grep -qi 'bom'"

echo "=== update script：仓库模式迁移为单文件（不改仓库入口） ==="
# v1.3.1 实测踩过：git clone 部署时 `xhy update` 把 42 行 dev 入口覆盖成
# 4307 行 install.sh，版本号回退、工作区变脏。v1.9.2 起改为「装到规范路径」：
# 单文件落到 $XHY_BINDIR/xhy，仓库目录里的 dev 入口一字不动。
export XHY_BINDIR="$TEST_TMP/bin"
export XHY_LEGACY_SELF="$TEST_TMP/legacy-none"
mkdir -p "$XHY_BINDIR"
repo_launcher_sha="$(md5sum "$XHY_SCRIPT_DIR/xhy" 2>/dev/null | cut -d' ' -f1)"
# 离线：把下载换成「拷一份本地 install.sh」
fetch() { cp "$XHY_SCRIPT_DIR/install.sh" "$2"; }
chk "repo mode migrates to single file" "update_script --yes >/dev/null 2>&1"
chk "canonical entry is a regular file" "[[ -f '$XHY_BINDIR/xhy' && ! -L '$XHY_BINDIR/xhy' ]]"
chk "repo dev entry untouched" "[[ \"\$(md5sum '$XHY_SCRIPT_DIR/xhy' | cut -d' ' -f1)\" == '$repo_launcher_sha' ]]"

summary
