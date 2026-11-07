#!/usr/bin/env bash
# relay 子命令离线回归。
#
# 全程不碰真实系统：iptables/ip6tables 换成「会记账的假表」，xray 是桩，
# public_ip / TCP 探测都不出网。redis 之类的外部依赖一律没有。
#
# 覆盖点（对应 v1.9.4 的改动）：
#   * entry 注入的 outbound / 路由规则形状正确，且**基础 rebuild 不再覆盖它**
#   * 基础规则仍在、顺序是「relay 前置、基础在后」
#   * --no-geoip-us / --categories 预设 / 非法分类被拒 / IPv6 上游解析
#   * land 入站片段、防火墙注释规则、重复执行幂等、--tls 走证书文件
#   * 同机换角色（land↔entry）互清、del 后配置干净且仍是合法 JSON
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system
make_stub_xray
export XHY_SKIP_SNAPSHOT=1
export XHY_RELAY_NO_TCP=1      # 不要真去 /dev/tcp 打 203.0.113.10
export XHY_SOCKOPT_AVAIL_CC="bbr cubic"   # 测试机没有 sysctl，钉住 BBR 可用
init_dirs

# --- 假 iptables：记录「链 + 端口 + 源 + 注释」，-C 查表、-A 追加、-D 删除 -----
FAKE_FW="$TEST_TMP/fw.rules"
: >"$FAKE_FW"
fake_ipt() {
    local a="" port="" src="" comment=""
    while (( $# > 0 )); do
        case "$1" in
            -w) shift ;;
            -L) [[ "${2:-}" == "${FW_CHAIN:-XHY-IN}" ]] && return 0; return 1 ;;
            -C|-A|-D) a="$1"; shift ;;
            -p|-j|-m) shift 2 ;;
            --dport)  port="$2"; shift 2 ;;
            -s)       src="$2"; shift 2 ;;
            --comment) comment="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    local key="port=$port src=$src comment=$comment"
    case "$a" in
        -C) grep -qxF "$key" "$FAKE_FW" ;;
        -A) printf '%s\n' "$key" >>"$FAKE_FW" ;;
        -D) grep -vxF "$key" "$FAKE_FW" >"$FAKE_FW.tmp" 2>/dev/null || true
            mv -f "$FAKE_FW.tmp" "$FAKE_FW" 2>/dev/null || true ;;
        *)  return 0 ;;
    esac
}
iptables()  { fake_ipt "$@"; }
ip6tables() { fake_ipt "$@"; }
public_ip() { printf '198.51.100.9'; }

# 放一个最小合法入站片段，让 confs/ 非空（贴近真实环境）
cat >"$XHY_CONFDIR/reality_443.json" <<'EOF'
{
  "listen": "0.0.0.0", "port": 443, "protocol": "vless",
  "tag": "in-reality-443",
  "settings": { "clients": [ { "id": "b831381d-6324-4d53-ad4f-8cda48b30811", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
  "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "show": false, "serverNames": ["www.example.com"], "privateKey": "A", "shortIds": ["01234567"] } }
}
EOF

json_ok() { "$PY" -c "import json,sys;json.load(open(sys.argv[1]))" "$1" >/dev/null 2>&1; }
# 断言 config 里 relay 规则排在基础 block 规则之前（前置优先级）
rules_order_ok() {
    "$PY" - "$XHY_ETC/config.json" <<'PY' >/dev/null 2>&1
import json,sys
cfg=json.load(open(sys.argv[1]))
rules=cfg["routing"]["rules"]
relay=[i for i,r in enumerate(rules) if r.get("outboundTag","").startswith("us-relay")]
block=[i for i,r in enumerate(rules) if r.get("outboundTag")=="block"]
assert relay, "no relay rule"
assert block, "no base block rule"
assert min(relay) < min(block), "relay rules are not in front"
PY
}

echo "===== relay entry（基础注入） ====="
relay_entry --to 203.0.113.10:14430 --uuid test-uuid-0000 --categories openai,anthropic
chk "entry 写入 relay.env"            '[ -f "$XHY_NODES/relay.env" ]'
chk "relay.env 角色=entry"            'grep -q "^RELAY_ROLE=entry$" "$XHY_NODES/relay.env"'
chk "config 是合法 JSON"              'json_ok "$XHY_ETC/config.json"'
chk "config 含 us-relay 出站"         'grep -q "\"tag\":\"us-relay\"" "$XHY_ETC/config.json"'
chk "config 含 geoip:us 路由"         'grep -q "geoip:us" "$XHY_ETC/config.json"'
chk "config 含 geosite:openai"        'grep -q "geosite:openai" "$XHY_ETC/config.json"'
chk "未指定的分类不出现"              '! grep -q "geosite:tiktok" "$XHY_ETC/config.json"'
chk "基础 block 规则仍在"             'grep -q "geoip:private" "$XHY_ETC/config.json"'
chk "relay 规则排在基础规则之前"      'rules_order_ok'
chk "上游地址/端口正确"               'grep -q "\"address\":\"203.0.113.10\",\"port\":14430" "$XHY_ETC/config.json"'
chk "status 报角色"                   'relay_status | grep -q "入口"'
chk "export 给出落地端命令"           'relay_export | grep -q "xhy relay land --allow"'

# --- v1.11.0：出站 sockopt / 失联回落 -------------------------------------
balancer_in_routing() {
    "$PY" - "$XHY_ETC/config.json" <<'PY' >/dev/null 2>&1
import json,sys
cfg=json.load(open(sys.argv[1]))
assert "balancers" not in cfg, "balancer must live inside routing, not top level"
b=cfg["routing"]["balancers"][0]
assert b["tag"]=="us-relay-lb", b
assert b["selector"]==["us-relay"], b
assert b["fallbackTag"]=="direct", b
assert b["strategy"]["type"]=="leastPing", b
obs=cfg["burstObservatory"]
assert obs["subjectSelector"]==["us-relay"], obs
assert obs["pingConfig"]["sampling"]==3, obs
PY
}

echo "===== v1.11.0：出站 sockopt ====="
chk "出站带 sockopt"                  'grep -q "\"sockopt\":{\"tcpFastOpen\":true" "$XHY_ETC/config.json"'
chk "sockopt 含 tcpNoDelay"           'grep -q "\"tcpNoDelay\":true" "$XHY_ETC/config.json"'
chk "sockopt 含 tcpUserTimeout"       'grep -q "\"tcpUserTimeout\":10000" "$XHY_ETC/config.json"'
chk "sockopt 带 BBR"                  'grep -q "\"tcpcongestion\":\"bbr\"" "$XHY_ETC/config.json"'

echo "===== v1.11.0：失联回落（balancer + burstObservatory） ====="
chk "config 含 balancers"             'grep -q "\"balancers\"" "$XHY_ETC/config.json"'
chk "balancer 落在 routing 内"        'balancer_in_routing'
chk "路由规则指向 balancer"           'grep -q "\"outboundTag\":\"us-relay-lb\"" "$XHY_ETC/config.json"'
chk "探活目标 gstatic 204"            'grep -q "generate_204" "$XHY_ETC/config.json"'
chk "回落配置仍合法"                  'json_ok "$XHY_ETC/config.json"'
chk "status 报回落 on"                'relay_status | grep -q "回落   : on"'
chk "test 报回落链路"                 'relay_test 2>/dev/null | grep -q "回落链路在位"'

echo "===== --no-fallback / --no-tfo：回到 v1.10.x 行为 ====="
relay_entry --to 203.0.113.10:14430 --uuid test-uuid-0000 --categories openai \
    --no-fallback --no-tfo >/dev/null
chk "relay.env 记 fallback=off"       'grep -q "^RELAY_FALLBACK=off$" "$XHY_NODES/relay.env"'
chk "relay.env 记 tfo=off"            'grep -q "^RELAY_TFO=off$" "$XHY_NODES/relay.env"'
chk "无 balancers"                    '! grep -q "\"balancers\"" "$XHY_ETC/config.json"'
chk "无 burstObservatory"             '! grep -q "burstObservatory" "$XHY_ETC/config.json"'
chk "规则指回裸 us-relay"             'grep -q "\"outboundTag\":\"us-relay\"" "$XHY_ETC/config.json"'
chk "tcpFastOpen 已关"                'grep -q "\"tcpFastOpen\":false" "$XHY_ETC/config.json"'
chk "关掉回落仍合法"                  'json_ok "$XHY_ETC/config.json"'
chk "非法 --fallback 值被拒"          '! ( relay_entry --to 203.0.113.10:14430 --fallback maybe ) >/dev/null 2>&1'

echo "===== 恢复默认：回落与 TFO 重新打开 ====="
relay_entry --to 203.0.113.10:14430 --uuid test-uuid-0000 --categories openai >/dev/null
chk "默认回来是 on"                   'grep -q "^RELAY_FALLBACK=on$" "$XHY_NODES/relay.env"'
chk "balancer 回来了"                 'grep -q "\"balancers\"" "$XHY_ETC/config.json"'
chk "tcpFastOpen 回 true"             'grep -q "\"tcpFastOpen\":true" "$XHY_ETC/config.json"'

echo "===== 基础 rebuild 不再覆盖 relay（本轮核心修复） ====="
XHY_SKIP_SNAPSHOT=1 rebuild_config >/dev/null 2>&1
chk "rebuild 后 us-relay 仍在"        'grep -q "us-relay" "$XHY_ETC/config.json"'
chk "rebuild 后仍是合法 JSON"         'json_ok "$XHY_ETC/config.json"'
chk "rebuild 后顺序仍正确"            'rules_order_ok'

echo "===== --no-geoip-us ====="
relay_entry --to 203.0.113.10:14430 --uuid test-uuid-0000 --categories ai --no-geoip-us >/dev/null
chk "关掉 geoip:us 后不再出现"        '! grep -q "geoip:us" "$XHY_ETC/config.json"'
chk "域名分类仍在"                    'grep -q "geosite:openai" "$XHY_ETC/config.json"'
chk "出站仍在"                        'grep -q "us-relay" "$XHY_ETC/config.json"'
chk "仍是合法 JSON"                   'json_ok "$XHY_ETC/config.json"'

echo "===== 参数校验 ====="
chk "非法端口被拒"                    '! ( relay_entry --to 203.0.113.10:99999 --uuid u ) >/dev/null 2>&1'
chk "分类注入被拒"                    '! ( relay_entry --categories "a\"b" --uuid u ) >/dev/null 2>&1'
chk "非法上游被拒"                    '! ( relay_entry --to 203.0.113.10 --uuid u ) >/dev/null 2>&1'

echo "===== IPv6 上游 ====="
relay_entry --to '[2001:db8::1]:14430' --uuid test-uuid-0000 --categories openai >/dev/null
chk "IPv6 地址写进 vnext"             'grep -q "\"address\":\"2001:db8::1\",\"port\":14430" "$XHY_ETC/config.json"'
chk "IPv6 上游仍是合法 JSON"          'json_ok "$XHY_ETC/config.json"'

echo "===== relay del（entry） ====="
relay_del >/dev/null
chk "del 后无 relay.env"              '! [ -f "$XHY_NODES/relay.env" ]'
chk "del 后 config 无 us-relay"       '! grep -q "us-relay" "$XHY_ETC/config.json"'
chk "del 后 config 仍合法"            'json_ok "$XHY_ETC/config.json"'
chk "del 后基础节点还在"              'grep -q "in-reality-443" "$XHY_ETC/config.json"'

echo "===== relay land ====="
relay_land --allow 198.51.100.20 --uuid land-uuid-0000 >/dev/null
chk "land 生成入站片段"               '[ -f "$XHY_CONFDIR/relay_in_14430.json" ]'
chk "片段是合法 JSON"                 'json_ok "$XHY_CONFDIR/relay_in_14430.json"'
chk "config 含 in-relay-14430"        'grep -q "in-relay-14430" "$XHY_ETC/config.json"'
chk "config 仍是合法 JSON"            'json_ok "$XHY_ETC/config.json"'
chk "relay.env 角色=land"             'grep -q "^RELAY_ROLE=land$" "$XHY_NODES/relay.env"'
chk "防火墙规则带注释写入"            'grep -q "comment=xhy-relay-14430" "$FAKE_FW"'
chk "只放行入口 IP"                   'grep -q "src=198.51.100.20" "$FAKE_FW"'
chk "land 不含 relay 出站"            '! grep -q "us-relay" "$XHY_ETC/config.json"'
chk "land status 报角色"              'relay_status | grep -q "落地"'

echo "===== land 重复执行（幂等，不因端口自占用而失败） ====="
relay_land --allow 198.51.100.20 --uuid land-uuid-0000 >/dev/null
chk "重复执行后片段只有一个"          '[ "$(ls "$XHY_CONFDIR"/relay_in_*.json | wc -l)" = "1" ]'
chk "重复执行后配置仍合法"            'json_ok "$XHY_ETC/config.json"'

echo "===== 恒明文：--tls 系列参数已停用 ====="
printf 'dummy-cert\n' >"$TEST_TMP/relay.crt"
printf 'dummy-key\n'  >"$TEST_TMP/relay.key"
relay_land --allow 198.51.100.20 --uuid land-uuid-0000 \
    --tls-cert "$TEST_TMP/relay.crt" --tls-key "$TEST_TMP/relay.key" --sni relay.example.com >/dev/null
chk "land 片段恒 security=none"     'grep -q "\"security\":\"none\"" "$XHY_CONFDIR/relay_in_14430.json"'
chk "land 片段无 tlsSettings"       '! grep -q "tlsSettings" "$XHY_CONFDIR/relay_in_14430.json"'
chk "land 片段不引用证书文件"       "! grep -q 'relay.crt' \"\$XHY_CONFDIR/relay_in_14430.json\""
chk "relay.env 记 none"             'grep -q "^RELAY_SECURITY=none$" "$XHY_NODES/relay.env"'
chk "relay.env 不记 sni"            '! grep -q "^RELAY_SNI=" "$XHY_NODES/relay.env"'
chk "片段仍是合法 JSON"             'json_ok "$XHY_CONFDIR/relay_in_14430.json"'

echo "===== 证书 pin 归一（函数保留，供将来跨公网复用） ====="
PIN_HEX="$("$PY" -c 'print(bytes(range(32)).hex())')"
PIN_UP="$("$PY" -c 'print(bytes(range(32)).hex().upper())')"
PIN_COLON="$("$PY" -c 'print(":".join("%02x" % b for b in range(32)))')"
PIN_B64="$("$PY" -c 'import base64;print(base64.b64encode(bytes(range(32))).decode())')"
chk "小写 hex 原样通过"               '[ "$(relay_pin_hex "$PIN_HEX")" = "$PIN_HEX" ]'
chk "大写 hex 转小写"                 '[ "$(relay_pin_hex "$PIN_UP")" = "$PIN_HEX" ]'
chk "冒号分隔 hex 去冒号"             '[ "$(relay_pin_hex "$PIN_COLON")" = "$PIN_HEX" ]'
chk "旧 base64 pin 转 hex"            '[ "$(relay_pin_hex "$PIN_B64")" = "$PIN_HEX" ]'
chk "空 pin 返回空（不报错）"         '[ -z "$(relay_pin_hex "")" ]'
chk "非法 pin 必须报错"               '! relay_pin_hex "not-a-pin" 2>/dev/null'

echo "===== entry 恒明文：传 --tls / --sni / --pin 也不产出加密 ====="
relay_entry --to 203.0.113.10:14430 --uuid tls-uuid-0000 \
    --tls --sni relay.example.com --pin "$PIN_B64" >/dev/null
chk "出站 security=none"            'grep -q "\"security\":\"none\"" "$XHY_ETC/config.json"'
chk "无 pinnedPeerCertSha256"       '! grep -q "pinnedPeerCertSha256" "$XHY_ETC/config.json"'
chk "无 verifyPeerCertByName"       '! grep -q "verifyPeerCertByName" "$XHY_ETC/config.json"'
chk "无 allowInsecure"              '! grep -q "allowInsecure" "$XHY_ETC/config.json"'
chk "无 serverName"                 '! grep -q "\\"serverName\\":" "$XHY_ETC/config.json"'
chk "无 base64 pin 原值"            "! grep -q '$PIN_B64' \"\$XHY_ETC/config.json\""
chk "relay.env 不记 SNI/PIN"        '! grep -qE "^RELAY_(SNI|PIN)=" "$XHY_NODES/relay.env"'
chk "配置仍是合法 JSON"             'json_ok "$XHY_ETC/config.json"'

echo "===== 旧 tls 状态自动降级（v1.10.x 升级路径） ====="
cat >"$XHY_NODES/relay.env" <<'EOF'
RELAY_ROLE=entry
RELAY_UPSTREAM=203.0.113.10:14430
RELAY_UUID=legacy-uuid-0000
RELAY_CATEGORIES=openai
RELAY_SECURITY=tls
RELAY_SNI=relay-14430
RELAY_PIN=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
RELAY_CERT=/etc/xray-hy/certs/relay_14430.crt
RELAY_KEY=/etc/xray-hy/certs/relay_14430.key
EOF
XHY_SKIP_SNAPSHOT=1 rebuild_config >/dev/null 2>&1
chk "旧 tls 状态不产出 tlsSettings" '! grep -q "tlsSettings" "$XHY_ETC/config.json"'
chk "降级后出站 security=none"      'grep -q "\"security\":\"none\"" "$XHY_ETC/config.json"'
chk "降级后配置仍合法"              'json_ok "$XHY_ETC/config.json"'
chk "status 报 none"                'relay_status | grep -q "传输   : none"'


echo "===== 同机换角色：land → entry ====="
relay_entry --to 203.0.113.10:14430 --uuid switch-uuid-0000 --categories openai >/dev/null
chk "换角色后入站片段被摘掉"          '! ls "$XHY_CONFDIR"/relay_in_*.json >/dev/null 2>&1'
chk "换角色后防火墙规则被摘掉"        '! grep -q "xhy-relay-14430" "$FAKE_FW"'
chk "换角色后 config 无 in-relay"     '! grep -q "in-relay" "$XHY_ETC/config.json"'
chk "换角色后 config 有 us-relay"     'grep -q "us-relay" "$XHY_ETC/config.json"'
chk "换角色后仍是合法 JSON"           'json_ok "$XHY_ETC/config.json"'

echo "===== reapply（快照回滚后兜底） ====="
relay_entry --to 203.0.113.10:14430 --uuid switch-uuid-0000 --categories openai >/dev/null
XHY_SKIP_SNAPSHOT=1 rebuild_config >/dev/null 2>&1
relay_reapply >/dev/null
chk "reapply 后 relay 在"             'grep -q "us-relay" "$XHY_ETC/config.json"'
chk "reapply 后 JSON 合法"            'json_ok "$XHY_ETC/config.json"'

echo "===== relay del（收尾） ====="
relay_del >/dev/null
chk "最终无 relay.env"                '! [ -f "$XHY_NODES/relay.env" ]'
chk "最终无入站片段"                  '! ls "$XHY_CONFDIR"/relay_in_*.json >/dev/null 2>&1'
chk "最终无 relay 出站"               '! grep -q "us-relay" "$XHY_ETC/config.json"'
chk "最终 config 合法"                'json_ok "$XHY_ETC/config.json"'

summary
