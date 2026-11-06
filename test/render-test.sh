#!/usr/bin/env bash
# Inbound rendering regression: the four VLESS modes plus xhttp-without-reality.
# Every rendered fragment and the merged config.json must be valid JSON.
set -u
# shellcheck source=test/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
load_libs
stub_system
make_stub_xray
init_dirs

mk() {
    local m="$1" p="$2" f="$XHY_NODES/${1}_${2}.env"
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
    [[ "$m" == tunnel ]] && sed -i 's/^PUBLIC=1/PUBLIC=0/' "$f"
    if [[ "$m" == direct || "$m" == tunnel ]]; then
        sed -i 's/^SECURITY=reality/SECURITY=none/' "$f"
    fi
}

echo "=== fragments ==="
mk direct 8080;  mk tunnel 10086;  mk reality 443;  mk xhttp 8081
for f in "$XHY_NODES"/*.env; do
    if write_fragment "$f"; then chk "render ${f##*/}" "true"; else chk "render ${f##*/}" "false"; fi
done
for f in "$XHY_CONFDIR"/*.json; do
    chk "valid JSON ${f##*/}" "$PY -c 'import json,sys; json.load(open(sys.argv[1]))' '$f'"
done

echo "=== merged config ==="
rebuild_config >/dev/null
chk "merged config parses" "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d[\"inbounds\"])==4' '$XHY_ETC/config.json'"
chk "routing has BT + private rules" \
    "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d[\"routing\"][\"rules\"])>=2' '$XHY_ETC/config.json'"
chk "outbounds are freedom+blackhole" \
    "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); assert [o[\"tag\"] for o in d[\"outbounds\"]]==[\"direct\",\"block\"]' '$XHY_ETC/config.json'"
chk "reality keeps xtls-rprx-vision" \
    "grep -q 'xtls-rprx-vision' '$XHY_CONFDIR/reality_443.json'"
chk "direct has no security layer" \
    "grep -q '\"security\": \"none\"' '$XHY_CONFDIR/direct_8080.json'"

echo "=== share links ==="
for f in "$XHY_NODES"/*.env; do
    uri="$(link_uri "$f")"
    case "$(basename "$f" .env)" in
        direct_8080)  chk "link direct"  "grep -q '^vless://.*type=ws' <<<\"\$uri\"" ;;
        tunnel_10086) chk "link tunnel"  "grep -q 'security=tls' <<<\"\$uri\"" ;;
        reality_443)  chk "link reality" "grep -q 'pbk=' <<<\"\$uri\"" ;;
        xhttp_8081)   chk "link xhttp"   "grep -q 'type=xhttp' <<<\"\$uri\"" ;;
    esac
done

echo "=== xhttp without REALITY ==="
sed -i 's/^SECURITY=reality/SECURITY=none/' "$XHY_NODES/xhttp_8081.env"
write_fragment "$XHY_NODES/xhttp_8081.env"
chk "xhttp plain is valid JSON" "$PY -c 'import json,sys; json.load(open(sys.argv[1]))' '$XHY_CONFDIR/xhttp_8081.json'"
chk "xhttp plain has no realitySettings" "! grep -q realitySettings '$XHY_CONFDIR/xhttp_8081.json'"

echo "=== state round-trip ==="
state_set BLOCK_BT off
chk "state read back off" "[[ \"\$(state_get BLOCK_BT on)\" == off ]]"
state_set BLOCK_BT on
chk "state read back on"  "[[ \"\$(state_get BLOCK_BT off)\" == on ]]"

# ---------------------------------------------------------------------------
# v1.3.0：sockopt / policy / 日志开关 / sniffing 裁剪 / hy2 伪装面
# ---------------------------------------------------------------------------
add_kv() { # add_kv <file> <KEY> <VALUE> —— 覆盖式追加，重复调用不会堆重复键
    local f="$1" k="$2" v="$3"
    grep -v "^${k}=" "$f" >"$f.tmp" || true
    mv "$f.tmp" "$f"
    printf '%s=%s\n' "$k" "$v" >>"$f"
}

echo "=== sockopt ==="
add_kv "$XHY_NODES/reality_443.env" TFO 1
write_fragment "$XHY_NODES/reality_443.env"
chk "reality 片段含 sockopt"        "grep -q '\"sockopt\"' '$XHY_CONFDIR/reality_443.json'"
chk "TFO=1 -> tcpFastOpen true"     "grep -q '\"tcpFastOpen\":true' '$XHY_CONFDIR/reality_443.json'"
add_kv "$XHY_NODES/reality_443.env" TFO 0
write_fragment "$XHY_NODES/reality_443.env"
chk "TFO=0 -> tcpFastOpen false"    "grep -q '\"tcpFastOpen\":false' '$XHY_CONFDIR/reality_443.json'"

# hy2 走 QUIC，没有 TCP 握手，sockopt 对它全是死字段
mk hy2 8443
write_fragment "$XHY_NODES/hy2_8443.env"
chk "hy2 片段无 sockopt"            "! grep -q '\"sockopt\"' '$XHY_CONFDIR/hy2_8443.json'"

echo "=== hy2 masquerade ==="
add_kv "$XHY_NODES/hy2_8443.env" MASQ_MODE string
write_fragment "$XHY_NODES/hy2_8443.env"
chk "默认 masquerade.type=string"        "grep -q '\"type\": \"string\"' '$XHY_CONFDIR/hy2_8443.json'"
add_kv "$XHY_NODES/hy2_8443.env" MASQ_MODE proxy
write_fragment "$XHY_NODES/hy2_8443.env"
chk "--masq-proxy -> masquerade.type=proxy" "grep -q '\"type\": \"proxy\"' '$XHY_CONFDIR/hy2_8443.json'"
rm -f "$XHY_NODES/hy2_8443.env" "$XHY_CONFDIR/hy2_8443.json"

echo "=== policy ==="
state_set BUFFER_SIZE 768
rebuild_config >/dev/null
chk "config 顶层含 policy"          "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); assert \"policy\" in d' '$XHY_ETC/config.json'"
chk "policy.bufferSize 取自 state"  "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"policy\"][\"levels\"][\"0\"][\"bufferSize\"]==768' '$XHY_ETC/config.json'"
chk "policy 关闭四路流量统计"        "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d[\"policy\"][\"system\"]; assert not any([s[\"statsInboundUplink\"],s[\"statsInboundDownlink\"],s[\"statsOutboundUplink\"],s[\"statsOutboundDownlink\"]])' '$XHY_ETC/config.json'"

echo "=== access log switch ==="
state_set LOG_LEVEL warning
state_set ACCESS_LOG off
rebuild_config >/dev/null
chk "ACCESS_LOG=off -> access none" "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"log\"][\"access\"]==\"none\"' '$XHY_ETC/config.json'"
state_set ACCESS_LOG on
rebuild_config >/dev/null
chk "ACCESS_LOG=on -> 写 xray-access.log" "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"log\"][\"access\"].endswith(\"xray-access.log\")' '$XHY_ETC/config.json'"

echo "=== sniffing by mode ==="
chk "direct destOverride 含 http"    "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); assert \"http\" in d[\"sniffing\"][\"destOverride\"]' '$XHY_CONFDIR/direct_8080.json'"
chk "reality destOverride 不含 http" "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); assert \"http\" not in d[\"sniffing\"][\"destOverride\"]' '$XHY_CONFDIR/reality_443.json'"
chk "reality 只嗅探 tls"             "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"sniffing\"][\"destOverride\"]==[\"tls\"]' '$XHY_CONFDIR/reality_443.json'"

# 自检里的两条 set -e 陷阱：函数以 `[[ 条件 ]] && printf/warn` 收尾时返回 1，
# 或在 pipefail 下被 head 打断成 SIGPIPE(141)，自检只印一半就退出。
echo "=== self-check exit codes ==="
chk "core_status 缺 cloudflared 仍返回 0" "CF_BIN=/nonexistent/cloudflared core_status >/dev/null"
chk "firewall_status --brief 返回 0"      "firewall_status --brief >/dev/null"
chk "firewall_status --brief 只有四行"     "[[ \$(firewall_status --brief | wc -l) -eq 4 ]]"
# 裸 sed s|MEMLIMIT|...| 会把 GOMEMLIMIT 的子串一起替换成 GO108MiB，变量名坏掉
chk "OpenRC 只用带引号锚点替换 GOMEMLIMIT"  "grep -qF 'GOMEMLIMIT=\"MEMLIMIT\"' '$REPO/lib/service.sh'"

summary
