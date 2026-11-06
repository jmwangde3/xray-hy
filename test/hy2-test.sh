#!/usr/bin/env bash
# Hysteria2 node regression: fragment shape, certificate generation, share link
# with pinSHA256, and UDP port exposure from the node registry.
set -u
# shellcheck source=test/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
load_libs
stub_system
make_stub_xray
init_dirs

cat >"$XHY_NODES/hy2_8443.env" <<EOF
MODE=hy2
PORT=8443
PUBLIC=1
PROTO=udp
UUID=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4
AUTH=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4
NODE_HOST=node.example.com
SNI=www.bing.com
CERT_FILE=$XHY_ETC/certs/hy2_8443.crt
KEY_FILE=$XHY_ETC/certs/hy2_8443.key
PIN_B64=YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo=
PIN_HEX=deadbeef
MASQ_URL=https://www.bing.com/
BRUTAL_UP=100mbps
BRUTAL_DOWN=300mbps
SECURITY=tls
CREATED=2026-01-01
EOF

echo "=== fragment ==="
write_fragment "$XHY_NODES/hy2_8443.env" && chk "render hy2" "true" || chk "render hy2" "false"
chk "valid JSON" "$PY -c 'import json,sys; json.load(open(sys.argv[1]))' '$XHY_CONFDIR/hy2_8443.json'"
chk "protocol is hysteria"      "grep -q '\"protocol\": \"hysteria\"' '$XHY_CONFDIR/hy2_8443.json'"
chk "network is hysteria"       "grep -q '\"network\": \"hysteria\"' '$XHY_CONFDIR/hy2_8443.json'"
chk "tls alpn is h3"            "grep -q '\"h3\"' '$XHY_CONFDIR/hy2_8443.json'"
chk "brutal params present"     "grep -q 'brutalUp' '$XHY_CONFDIR/hy2_8443.json'"
# v1.3.0 起默认收敛为静态页面：proxy 模式会被扫描器当免费反代用掉本机带宽。
chk "masquerade defaults to string" "grep -q '\"type\": \"string\"' '$XHY_CONFDIR/hy2_8443.json'"
chk "default has no proxy url"      "! grep -q 'rewriteHost' '$XHY_CONFDIR/hy2_8443.json'"

echo "=== real certificate generation ==="
read -r crt key pin64 pinhex <<<"$(hy2_gen_cert 18444 www.bing.com)"
chk "cert written"   "[[ -s '$crt' ]]"
chk "key written"    "[[ -s '$key' ]]"
chk "pin is base64"  "[[ -n '$pin64' ]]"
chk "pin hex is 64"  "[[ ${#pinhex} -eq 64 ]]"
# 3650 days is exactly 315360000s, so the boundary check must allow for the
# seconds that have already elapsed since issuance.
chk "cert valid ~10y" "openssl x509 -in '$crt' -noout -checkend 283824000"

echo "=== share link ==="
uri="$(link_uri "$XHY_NODES/hy2_8443.env")"
chk "scheme is hysteria2://" "grep -q '^hysteria2://' <<<\"\$uri\""
chk "pinSHA256 non-empty"    "grep -q 'pinSHA256=.' <<<\"\$uri\""
chk "sni present"            "grep -q 'sni=www.bing.com' <<<\"\$uri\""
detail="$(link_from_env "$XHY_NODES/hy2_8443.env")"
chk "insecure fallback offered" "grep -q 'insecure=1' <<<\"\$detail\""

echo "=== firewall port exposure ==="
chk "UDP 8443 exposed"      "[[ \"\$(firewall_udp_ports)\" == 8443 ]]"
chk "not in TCP list"       "[[ -z \"\$(firewall_node_ports)\" ]]"

summary
