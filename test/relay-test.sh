#!/usr/bin/env bash
# relay 子命令离线回归：entry 注入 us-relay 出站 + 路由规则，land 生成入站片段，
# del 干净移除；全程不碰真实系统（iptables/xray 桩、XHY_SKIP_SNAPSHOT）。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system
make_stub_xray
export XHY_SKIP_SNAPSHOT=1
# relay_fw_add/del 直接调 iptables，离线桩成 no-op
iptables()  { :; }
ip6tables() { :; }
init_dirs

# 放一个最小合法入站片段，让 confs/ 非空（贴近真实环境）
cat >"$XHY_CONFDIR/reality_443.json" <<'EOF'
{
  "listen": "0.0.0.0", "port": 443, "protocol": "vless",
  "tag": "in-reality-443",
  "settings": { "clients": [ { "id": "b831381d-6324-4d53-ad4f-8cda48b30811", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
  "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "show": false, "serverNames": ["www.example.com"], "privateKey": "A", "shortIds": ["01234567"] } }
}
EOF

echo "===== relay entry ====="
relay_entry --to 203.0.113.10:14430 --uuid test-uuid-0000 --categories openai,anthropic
chk "entry 写入 relay.env"        '[ -f "$XHY_NODES/relay.env" ]'
chk "config 含 us-relay 出站"     'grep -q "us-relay" "$XHY_ETC/config.json"'
chk "config 含 geoip:us 路由"     'grep -q "geoip:us" "$XHY_ETC/config.json"'
chk "config 含 geosite:openai"    'grep -q "geosite:openai" "$XHY_ETC/config.json"'
chk "config 不含 geosite:tiktok"  '! grep -q "geosite:tiktok" "$XHY_ETC/config.json"'

echo "===== relay status (entry) ====="
relay_status

echo "===== relay del (entry) ====="
relay_del
chk "entry 删除后无 relay.env"    '! [ -f "$XHY_NODES/relay.env" ]'
chk "config 回收 us-relay"        '! grep -q "us-relay" "$XHY_ETC/config.json"'

echo "===== relay land ====="
relay_land --allow 198.51.100.20 --uuid land-uuid-0000
chk "land 生成入站片段"           '[ -f "$XHY_CONFDIR/relay_in_14430.json" ]'
chk "config 含 in-relay-14430"    'grep -q "in-relay-14430" "$XHY_ETC/config.json"'
chk "land 写入 relay.env"         '[ -f "$XHY_NODES/relay.env" ]'
chk "relay.env 角色=land"         'grep -q "^RELAY_ROLE=land$" "$XHY_NODES/relay.env"'

echo "===== relay del (land) ====="
relay_del
chk "land 删除入站片段"           '! [ -f "$XHY_CONFDIR/relay_in_14430.json" ]'
chk "land 删除后无 relay.env"     '! [ -f "$XHY_NODES/relay.env" ]'

summary
