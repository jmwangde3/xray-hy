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

summary
