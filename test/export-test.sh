#!/usr/bin/env bash
# export.sh 的离线测试：用固定的节点 .env 夹具验证 Clash YAML 与 sing-box JSON
# 生成内容，不需要 root / 网络 / 真实 Xray。
set -Eeuo pipefail
IFS=$'\n\t'

TESTS=0 FAILS=0
ck() { # ck <描述> <命令...> —— 命令成功(0)即 PASS
    local desc="$1"; shift
    TESTS=$((TESTS + 1))
    if "$@" >/dev/null 2>&1; then
        printf '  [ok] %s\n' "$desc"
    else
        printf '  [FAIL] %s\n' "$desc"
        FAILS=$((FAILS + 1))
    fi
}
ck_fail() { # ck_fail <描述> <命令...> —— 命令失败(非0)才 PASS
    local desc="$1"; shift
    TESTS=$((TESTS + 1))
    if "$@" >/dev/null 2>&1; then
        printf '  [FAIL] %s\n' "$desc"
        FAILS=$((FAILS + 1))
    else
        printf '  [ok] %s\n' "$desc"
    fi
}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO/test/_lib.sh"
load_libs
init_dirs

# ---- 夹具：reality + hy2 + xhttp（xhttp 应被跳过）----
mkdir -p "$XHY_ETC/nodes"
cat >"$XHY_NODES/reality_443.env" <<'EOF'
MODE="reality"
PORT="443"
PUBLIC="1"
UUID="11111111-2222-3333-4444-555555555555"
NODE_HOST="203.0.113.10"
SNI="www.nus.edu.sg"
TARGET="www.nus.edu.sg:443"
PUBLIC_KEY="qCBMjJi6Pjc_NHgjgqlczaE8Cqted_YPLO0S0-dVB3w"
SHORT_ID="1c33017f"
SECURITY="reality"
CREATED="2026-11-06T00:00:00+08:00"
EOF
cat >"$XHY_NODES/hy2_8443.env" <<'EOF'
MODE="hy2"
PORT="8443"
PUBLIC="1"
UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
NODE_HOST="203.0.113.10"
AUTH="hy2pass"
SNI="www.bing.com"
CERT_FILE="/etc/xray-hy/certs/hy2.crt"
KEY_FILE="/etc/xray-hy/certs/hy2.key"
PIN_B64="cGluaG9sZQ=="
PIN_HEX="70696e686f6c65"
MASQ_URL="https://www.bing.com/"
BRUTAL_UP="100mbps"
BRUTAL_DOWN="300mbps"
CREATED="2026-11-06T00:00:00+08:00"
EOF
cat >"$XHY_NODES/xhttp_8081.env" <<'EOF'
MODE="xhttp"
PORT="8081"
PUBLIC="1"
UUID="99999999-8888-7777-6666-555555555555"
NODE_HOST="203.0.113.10"
NODE_PATH="/xh"
CREATED="2026-11-06T00:00:00+08:00"
EOF

echo "=== export clash ==="
clash_out="$(cmd_export clash)"
ck "包含 reality 节点名"          grep -q 'name: "xray-hy-reality-443"' <<<"$clash_out"
ck "reality 带 public-key"        grep -q 'public-key: "qCBMjJi6' <<<"$clash_out"
ck "reality 带 flow"              grep -q 'flow: xtls-rprx-vision' <<<"$clash_out"
ck "包含 hy2 节点"                grep -q 'type: hysteria2' <<<"$clash_out"
ck "hy2 带 brutal 带宽"           grep -q 'up: "100mbps"' <<<"$clash_out"
ck "hy2 自签用 skip-cert-verify"  grep -q 'skip-cert-verify: true' <<<"$clash_out"
ck "xhttp 被跳过"                 bash -c "! grep -q 'xhttp' <<<\"\$1\"" _ "$clash_out"
ck "proxies: 键存在"              grep -q '^proxies:' <<<"$clash_out"

echo "=== export singbox ==="
sb_out="$(cmd_export singbox)"
ck "JSON 可解析"     "$PY" -c "import json,sys; d=json.load(sys.stdin); assert len(d)==2" <<<"$sb_out"
ck "包含 vless+reality"     grep -q '"reality"' <<<"$sb_out"
ck "reality 带 public_key"  grep -q 'qCBMjJi6Pjc' <<<"$sb_out"
ck "hy2 类型存在"           grep -q '"type": "hysteria2"' <<<"$sb_out"
ck "hy2 insecure:true"      grep -q '"insecure": true' <<<"$sb_out"
ck "hy2 up_mbps 提取数字"   grep -q '"up_mbps": 100' <<<"$sb_out"
ck "xhttp 被跳过"           bash -c "! grep -q 'xhttp' <<<\"\$1\"" _ "$sb_out"

echo "=== export --out ==="
outfile="$TEST_TMP/export.yaml"
ck "--out 写文件成功"       cmd_export clash --out "$outfile"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        TESTS=$((TESTS + 1)); printf '  [skip] 文件权限 0600（Windows/MSYS 不适用）\n' ;;
    *) ck "文件权限 0600"    test "$(stat -c %a "$outfile")" = 600 ;;
esac
ck "文件含 proxies"         grep -q '^proxies:' "$outfile"

echo "=== 空注册表报错 ==="
rm -f "$XHY_NODES"/*.env
# cmd_export 在无节点时应 die（非零退出；加载在子 shell 里做，不污染本进程）
ck_fail "无节点时 die"      bash -c "set -Eeuo pipefail; source '$REPO/test/_lib.sh' >/dev/null 2>&1; load_libs; init_dirs; cmd_export clash"

echo ""
echo "export-test: PASS=$TESTS FAIL=$FAILS"
(( FAILS == 0 ))
