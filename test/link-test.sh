#!/usr/bin/env bash
# 分享链接二维码回归：桩掉 qrencode，离线验证 --qr 的终端类型选择、
# --png 的 0600 落盘、多节点后缀，以及 link_from_env / link_all 的挂载点。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system
make_stub_xray
init_dirs

QR_LOG="$TEST_TMP/qr.log"
CHMOD_LOG="$TEST_TMP/chmod.log"
: >"$QR_LOG"; : >"$CHMOD_LOG"
# Git Bash / Windows 的 stat -c %a 恒报 644（无 POSIX 权限位），改成记录
# chmod 调用意图，避免测试在 Windows 上假失败。
chmod() { printf '%s %s\n' "$1" "$2" >>"$CHMOD_LOG"; }

# 记录 qrencode 收到的 -t / -o 与 URI；PNG 模式写一个小占位文件。
qrencode() {
    local t="" out="" last=""
    printf 'CALL' >>"$QR_LOG"
    while (($#)); do
        case "$1" in
            -t) t="$2"; shift 2 ;;
            -o) out="$2"; shift 2 ;;
            *)  last="$1"; printf ' %s' "$1" >>"$QR_LOG"; shift ;;
        esac
    done
    printf ' t=%s out=%s\n' "$t" "$out" >>"$QR_LOG"
    [[ -n "$out" ]] && printf 'PNGDATA' >"$out"
    printf 'QR_STUB\n'
    return 0
}
have_cmd() {
    case "$1" in qrencode) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac
}
ensure_optional() { :; }

mk() {
    local m="$1" p="$2" f
    f="$XHY_NODES/${m}_${p}.env"
    cat >"$f" <<EOF
MODE=$m
PORT=$p
PUBLIC=1
UUID=b831381d-6324-4d53-ad4f-8cda48b30811
NODE_PATH=/abcdef1234567890
NODE_HOST=node.example.com
SNI=www.example.com
TARGET=www.example.com:443
PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
SHORT_ID=01234567
FP=chrome
CF_DOMAIN=node.example.com
SECURITY=reality
CREATED=2026-01-01
EOF
    [[ "$m" == direct ]] && sed -i 's/^SECURITY=reality/SECURITY=none/' "$f"
}
mk reality 443
mk direct 8080

echo "=== link_qr 终端类型 ==="
LINK_QR_OUT=""; LINK_QR_MULTI=0
: >"$QR_LOG"
( TERM=xterm-256color XHY_LANG_EFFECTIVE=zh link_qr "$XHY_NODES/reality_443.env" ) >/dev/null
chk "UTF-8 终端用 ANSIUTF8"        'grep -q "t=ANSIUTF8 out=$" "$QR_LOG"'
( TERM=linux XHY_LANG_EFFECTIVE=zh link_qr "$XHY_NODES/reality_443.env" ) >/dev/null
chk "控制台 TERM 用 ANSI"           'grep -q "t=ANSI out=$" "$QR_LOG"'
( TERM=xterm XHY_LANG_EFFECTIVE=en link_qr "$XHY_NODES/reality_443.env" ) >/dev/null
chk "英文模式用 ANSI"               'grep -q "t=ANSI out=$" "$QR_LOG"'
chk "二维码内容是 vless 链接"        'grep -q "vless://" "$QR_LOG"'

echo "=== link_qr --png ==="
LINK_QR_OUT="$TEST_TMP/one.png"; LINK_QR_MULTI=0
: >"$QR_LOG"
link_qr "$XHY_NODES/reality_443.env" "$LINK_QR_OUT" >/dev/null
chk "PNG 写到 -o 指定路径"          '[[ -f "$TEST_TMP/one.png" ]]'
chk "PNG 内容是桩数据"              'grep -q "PNGDATA" "$TEST_TMP/one.png"'
chk "PNG 显式 chmod 600"            'grep -q "^600 .*one.png$" "$CHMOD_LOG"'
chk "-t PNG 传给 qrencode"          'grep -q "t=PNG" "$QR_LOG"'

LINK_QR_OUT="$TEST_TMP/multi.png"; LINK_QR_MULTI=1
MODE=reality; PORT=443
: >"$QR_LOG"
link_qr "$XHY_NODES/reality_443.env" "$LINK_QR_OUT" >/dev/null
chk "多节点 PNG 带 MODE_PORT 后缀"  '[[ -f "$TEST_TMP/multi-reality_443.png" ]]'
MODE=direct; PORT=8080
link_qr "$XHY_NODES/direct_8080.env" "$LINK_QR_OUT" >/dev/null
chk "第二个节点不覆盖第一个"        '[[ -f "$TEST_TMP/multi-direct_8080.png" ]]'

echo "=== link_from_env / link_all 挂载 ==="
LINK_QR=1; LINK_QR_OUT=""; LINK_QR_MULTI=0
: >"$QR_LOG"
link_from_env "$XHY_NODES/reality_443.env" >/dev/null
chk "link_from_env 带出二维码"      '[[ $(grep -c "^CALL" "$QR_LOG") -eq 1 ]]'
: >"$QR_LOG"
link_all >/dev/null
chk "link_all 每节点各一张二维码"   '[[ $(grep -c "^CALL" "$QR_LOG") -eq 2 ]]'
LINK_QR=0
: >"$QR_LOG"
link_all >/dev/null
chk "不带 --qr 时零二维码"          '[[ ! -s "$QR_LOG" ]]'

echo "=== 非节点 env（relay.env）跳过 ==="
cat >"$XHY_NODES/relay.env" <<'EOF'
RELAY_ROLE=land
RELAY_PORT=14430
RELAY_ALLOW=203.0.113.1
EOF
LINK_QR=1; LINK_QR_OUT=""; LINK_QR_MULTI=0
: >"$QR_LOG"
link_all >/dev/null
chk "relay.env 不当节点导出"      '[[ $(grep -c "^CALL" "$QR_LOG") -eq 2 ]]'
chk "relay.env 不报未知模式"      '! link_all 2>&1 | grep -q "未知模式"'
chk "link_node_files 只列节点"    '[[ $(link_node_files | wc -l) -eq 2 ]]'
rm -f "$XHY_NODES/relay.env"

echo "=== cmd_link 静态形状 ==="
chk "cmd_link 解析 --png"           'grep -q -- "--png" entry/main.sh'
chk "cmd_link 设置 LINK_QR_MULTI"   'grep -q "LINK_QR_MULTI" entry/main.sh'
chk "main.sh 无重复 cmd_link 定义"  '[[ $(grep -c "^cmd_link()" entry/main.sh) -eq 1 ]]'
chk "ensure_optional 带 community"  'grep -q "community" lib/platform.sh'

summary
