#!/usr/bin/env bash
# 一键脚本入口回归：无参数 = 自动完整安装 + 落地 /usr/local/bin/xhy，
# 已安装机器无参数仍进菜单；另外覆盖 xhy lang 的落盘行为。
# main.sh 末尾有 main "$@"，不能直接 source，这里把需要的函数段抽出来测。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system

funcs="$TEST_TMP/bootstrap.func"
sed -n '/^XHY_BOOTSTRAPPED=0/,/^usage()/p' entry/main.sh | sed '$d' >"$funcs"
# shellcheck disable=SC1090
source "$funcs"

LOG="$TEST_TMP/bootstrap.log"
install_self()   { printf 'self\n' >>"$LOG"; }
create_symlink() { printf 'link\n' >>"$LOG"; }
XHY_BINDIR="$TEST_TMP/bin"
export XHY_BINDIR
mkdir -p "$XHY_BINDIR" "$TEST_TMP/repo/.git" "$TEST_TMP/repo/lib"

echo "=== bootstrap_self 功能 ==="
: >"$LOG"
XHY_DEV=1 XHY_RUNNING="$TEST_TMP/install.sh" XHY_SELF="$TEST_TMP/xhy" XHY_BOOTSTRAPPED=0
bootstrap_self
chk "仓库开发模式跳过自安装" '[[ ! -s "$LOG" ]]'
chk "开发模式不置 BOOTSTRAPPED" '[[ "$XHY_BOOTSTRAPPED" == 0 ]]'

: >"$LOG"
XHY_DEV=0 XHY_RUNNING="$TEST_TMP/xhy" XHY_SELF="$TEST_TMP/xhy" XHY_BOOTSTRAPPED=0
bootstrap_self
chk "从已安装入口运行不重复装" '[[ ! -s "$LOG" ]]'

: >"$LOG"
XHY_DEV=0 XHY_RUNNING="$TEST_TMP/install.sh" XHY_SELF="$TEST_TMP/xhy" XHY_BOOTSTRAPPED=0
bootstrap_self
chk "一键脚本会装脚本本体" 'grep -qx self "$LOG"'
chk "一键脚本会建 xhy 入口" 'grep -qx link "$LOG"'
chk "置 XHY_BOOTSTRAPPED=1" '[[ "$XHY_BOOTSTRAPPED" == 1 ]]'

echo "=== reconcile_bin 自愈旧软链（统一路径后必须能修好指错入口） ==="
mkdir -p "$TEST_TMP/old"
: >"$TEST_TMP/old/xhy"
ln -sf "$TEST_TMP/old/xhy" "$XHY_BINDIR/xhy"
chk "旧软链存在" '[[ -L "$XHY_BINDIR/xhy" ]]'
reconcile_bin
chk "旧软链被摘掉（直装前清场）" '[[ ! -L "$XHY_BINDIR/xhy" ]]'
# 模拟已经直装成文件后，再次遇到旧软链也幂等
: >"$XHY_BINDIR/xhy"
ln -sf "$TEST_TMP/old/xhy" "$XHY_BINDIR/xhy"
reconcile_bin
chk "reconcile 幂等（不报错、软链消失）" '[[ ! -L "$XHY_BINDIR/xhy" ]]'

echo "=== bootstrap_self 迁移旧布局（readlink 相同也必须迁移） ==="
: >"$LOG"
mkdir -p "$TEST_TMP/legacy"
printf '#!/bin/sh\n# xray-hy\n' >"$TEST_TMP/legacy/xhy"
ln -sfn "$TEST_TMP/legacy/xhy" "$XHY_BINDIR/xhy"
XHY_DEV=0 XHY_RUNNING="$XHY_BINDIR/xhy" XHY_SELF="$XHY_BINDIR/xhy" XHY_BOOTSTRAPPED=0
bootstrap_self
chk "旧软链入口触发迁移（不再因解析值相同而跳过）" 'grep -qx self "$LOG"'
chk "迁移后置 XHY_BOOTSTRAPPED=1" '[[ "$XHY_BOOTSTRAPPED" == 1 ]]'

echo "=== install_self 真实迁移（旧布局 -> 直装 + 清孤儿） ==="
# 前面 install_self 被 stub 覆盖；从源码里重新抽出真实实现
sed -n '/^install_self()/,/^}/p' entry/main.sh >"$TEST_TMP/install_self.func"
# shellcheck disable=SC1090
source "$TEST_TMP/install_self.func"
export XHY_BINDIR XHY_APP_DIR="$TEST_TMP/app" XHY_LEGACY_SELF="$TEST_TMP/app/xhy"
export XHY_SELF="$XHY_BINDIR/xhy" XHY_RUNNING="$XHY_BINDIR/xhy"
mkdir -p "$XHY_APP_DIR"
printf '#!/bin/sh\n# xray-hy legacy\n' >"$XHY_APP_DIR/xhy"
ln -sfn "$XHY_APP_DIR/xhy" "$XHY_BINDIR/xhy"
install_self >/dev/null 2>&1
chk "入口变成普通文件（非软链）" '[[ -f "$XHY_BINDIR/xhy" && ! -L "$XHY_BINDIR/xhy" ]]'
chk "内容来自旧本体（复制成功，未下载）" 'grep -q "xray-hy legacy" "$XHY_BINDIR/xhy"'
chk "旧孤儿本体被清掉" '[[ ! -e "$XHY_APP_DIR/xhy" ]]'

echo "=== xhy_is_installed ==="
init_dirs
state_del INSTALLED
rm -f "$XRAY_BIN"
chk "未装过 -> 触发自动安装" '! xhy_is_installed'
state_set INSTALLED "2026-01-01T00:00:00+00:00"
chk "Xray 二进制缺失仍判未完成" '! xhy_is_installed'

echo "=== cmd_lang 落盘 ==="
state_del XHY_LANG
cmd_lang en >/dev/null 2>&1
chk "xhy lang en 写进 state" '[[ "$(state_get XHY_LANG "")" == en ]]'
cmd_lang zh >/dev/null 2>&1
chk "xhy lang zh 写进 state" '[[ "$(state_get XHY_LANG "")" == zh ]]'
cmd_lang auto >/dev/null 2>&1
chk "xhy lang auto 写进 state" '[[ "$(state_get XHY_LANG "")" == auto ]]'
# cmd_lang 用 die 退出，必须放进子 shell，否则会把整个测试脚本带走。
chk "非法值被拒绝" '! ( cmd_lang xx >/dev/null 2>&1 )'

echo "=== 源码接线 ==="
for spec in \
    "bootstrap_self 定义存在|grep -q '^bootstrap_self()' entry/main.sh" \
    "xhy_is_installed 定义存在|grep -q '^xhy_is_installed()' entry/main.sh" \
    "reconcile_bin 定义存在（自愈旧软链）|grep -q '^reconcile_bin()' lib/common.sh" \
    "_cleanup_legacy_self 可重定向（测试用）|grep -q 'XHY_LEGACY_SELF' lib/common.sh" \
    "update_script 仓库模式改为迁移|grep -q 'repo_mode=1' lib/update.sh" \
    "update_script 同版本也纠正布局|grep -q 'layout_bad' lib/update.sh" \
    "self_check 报入口布局|grep -q '入口布局' lib/update.sh" \
    "默认命令改成 auto|grep -q 'local cmd=\"\${1:-auto}\"' entry/main.sh" \
    "auto 分支先判是否已安装|grep -q '|| xhy_is_installed; then' entry/main.sh" \
    "开发入口不触发自动安装|grep -q 'XHY_DEV:-0.*==.*1.*|| xhy_is_installed' entry/main.sh" \
    "auto 未安装时执行 cmd_install|grep -q 'cmd_install || return 1' entry/main.sh" \
    "bootstrap_self 在 main 里被调用|grep -q '^    bootstrap_self$' entry/main.sh" \
    "cmd_install 跳过重复落地|grep -q 'XHY_BOOTSTRAPPED' entry/main.sh" \
    "显式 install 仍走 install_self|grep -q '^        install_self$' entry/main.sh" \
    "create_symlink 仍然接上|grep -q '^        create_symlink$' entry/main.sh" \
    "menu 显式命令仍可用|grep -q 'menu|--menu) cmd_menu' entry/main.sh" \
    "lang 命令已接入|grep -q 'lang)       cmd_lang' entry/main.sh" \
    "prelude 保留一键用法说明|grep -q 'bash <(curl' entry/prelude.sh" \
    "usage 说明语言开关|grep -q 'XHY_LANG=en' entry/main.sh" \
    "run-all 跑 i18n-test|grep -q 'test/i18n-test.sh' test/run-all.sh" \
    "run-all 跑 bootstrap-test|grep -q 'test/bootstrap-test.sh' test/run-all.sh"; do
    d="${spec%%|*}"; c="${spec#*|}"
    if eval "$c" >/dev/null 2>&1; then
        printf '  PASS  %s\n' "$d"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$d"; FAIL=$((FAIL + 1))
    fi
done

summary
