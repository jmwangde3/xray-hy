#!/usr/bin/env bash
# warp 子命令离线回归。
#
# 全程不碰真实系统：wireproxy / wgcf 的下载与注册、openrc 服务、socks 探测、
# 端口占用检查全部替换成桩；网络一次都不出。
#
# 覆盖点：
#   * 未启用时钩子输出为空 —— 基础 rebuild 的产物与 v1.14.x 逐字节等价
#   * on 之后出站/规则形状正确，规则顺序是「relay → warp → 基础」
#   * 裸域名补 domain: 前缀，五种前缀保留，带引号/反斜杠被拒
#   * relay entry 与 warp 共存时两个出站都在、两个规则都在
#   * off 摘掉出站与规则但保留环境；del 连环境文件一起清
#   * warp.env 权限 0600、非法端口/标签被拒、on 可重复执行（幂等）
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
export XHY_WARP_DIR="$TEST_TMP/warp"
export XHY_WARP_BIN="$TEST_TMP/bin/wireproxy"
load_libs
stub_system
make_stub_xray
export XHY_SKIP_SNAPSHOT=1
export XHY_SOCKOPT_AVAIL_CC="bbr cubic"
init_dirs

# --- 桩：不下载、不注册、不起服务、不出网 --------------------------------
warp_install_bin()     { return 0; }
warp_create_account()  { WARP_PRIVATE_KEY="dGVzdC1wcml2YXRlLWtleS1vZmZsaW5l"; return 0; }
warp_service_install() { return 0; }
warp_service_remove()  { return 0; }
warp_service_restart() { return 0; }
warp_egress_ip()       { printf '104.28.227.185'; }
warp_proxy_up()        { return 0; }
warp_svc_installed()   { return 0; }
port_busy()            { return 1; }
disk_free_mb()         { printf '200'; }

json_ok() { "$PY" -c "import json,sys;json.load(open(sys.argv[1]))" "$1" >/dev/null 2>&1; }

# 出站/规则形状与顺序
warp_shape_ok() {
    "$PY" - "$XHY_ETC/config.json" <<'PY' >/dev/null 2>&1
import json,sys
cfg=json.load(open(sys.argv[1]))
outs={o.get("tag"):o for o in cfg["outbounds"]}
assert "warp" in outs, "no warp outbound"
w=outs["warp"]
assert w["protocol"]=="socks", "warp outbound must be socks"
srv=w["settings"]["servers"][0]
assert srv["address"]=="127.0.0.1" and srv["port"]==25344, "wrong socks target"
rules=cfg["routing"]["rules"]
wi=[i for i,r in enumerate(rules) if r.get("outboundTag")=="warp"]
assert len(wi)==1, "expect exactly one warp rule"
assert "domain:x.ai" in rules[wi[0]]["domain"], "x.ai missing"
assert "domain:grok.com" in rules[wi[0]]["domain"], "grok.com missing"
blk=[i for i,r in enumerate(rules) if r.get("outboundTag")=="block"]
assert blk and min(wi) < min(blk), "warp rule must precede base rules"
PY
}

rules_order_ok() {
    "$PY" - "$XHY_ETC/config.json" <<'PY' >/dev/null 2>&1
import json,sys
cfg=json.load(open(sys.argv[1]))
rules=cfg["routing"]["rules"]
# relay 规则在回落开着时指向 balancerTag，关掉时指向 outboundTag，两种都算。
def refs(tag):
    return [i for i,r in enumerate(rules)
            if str(r.get("outboundTag","")).startswith(tag)
            or str(r.get("balancerTag","")).startswith(tag)]
relay=refs("us-relay"); warp=refs("warp")
assert relay and warp, "both rule kinds expected"
assert min(relay) < min(warp), "relay must come before warp (entry forwards, land exits)"
PY
}

echo "===== 未启用：钩子不注入 ====="
XHY_SKIP_SNAPSHOT=1 rebuild_config >/dev/null 2>&1
chk "默认 config 合法"                'json_ok "$XHY_ETC/config.json"'
chk "默认无 warp 出站"                '! grep -q "\"tag\":\"warp\"" "$XHY_ETC/config.json"'
chk "warp_active 为假"                '! warp_active'

echo "===== 域名解析 ====="
chk "裸名补 domain:"                  '[ "$(warp_domains_json "x.ai")" = "\"domain:x.ai\"" ]'
chk "domain: 前缀保留"                '[ "$(warp_domains_json "domain:a.com")" = "\"domain:a.com\"" ]'
chk "full: 前缀保留"                  '[ "$(warp_domains_json "full:a.com")" = "\"full:a.com\"" ]'
chk "regexp: 反斜杠转成 \\\\"          '[ "$(warp_domains_json "regexp:^a\\.")" = "\"regexp:^a\\\\.\"" ]'
chk "多域名逗号分隔"                  '[ "$(warp_domains_json "a.com,b.com")" = "\"domain:a.com\",\"domain:b.com\"" ]'
chk "空格被裁掉"                      '[ "$(warp_domains_json " a.com , b.com ")" = "\"domain:a.com\",\"domain:b.com\"" ]'
chk "双引号被转义而非放行裸写"        '[ "$(warp_domains_json "a\".com")" = "\"domain:a\\\".com\"" ]'
chk "反斜杠被转义"                    '[ "$(warp_domains_json "a\\\\.com")" = "\"domain:a\\\\\\\\.com\"" ]'
chk "空列表输出为空"                  '[ -z "$(warp_domains_json ",")" ]'

echo "===== warp on（基础注入） ====="
warp_cmd_on >/dev/null 2>&1
chk "写入 warp.env"                   '[ -f "$XHY_NODES/warp.env" ]'
warp_perm() { stat -c %a "$1" 2>/dev/null || printf ''; }
case "$(uname -s 2>/dev/null || printf '')" in
    MINGW*|MSYS*|CYGWIN*) printf '  [skip] 文件权限 0600（Windows/MSYS 不适用）\n' ;;
    *) chk "warp.env 权限 0600"       '[ "$(warp_perm "$XHY_NODES/warp.env")" = 600 ]'
       chk "wp.conf 权限 0600"        '[ "$(warp_perm "$XHY_WARP_DIR/wp.conf")" = 600 ]' ;;
esac
chk "warp.env 标记 on"                'grep -q "^WARP_ENABLE=on$" "$XHY_NODES/warp.env"'
chk "wp.conf 已生成"                  '[ -f "$XHY_WARP_DIR/wp.conf" ]'
chk "wp.conf 含 socks 端口"           'grep -q "BindAddress = 127.0.0.1:25344" "$XHY_WARP_DIR/wp.conf"'
chk "wp.conf 含私钥"                  'grep -q "^PrivateKey = dGVzdC1wcml2YXRlLWtleS1vZmZsaW5l$" "$XHY_WARP_DIR/wp.conf"'
chk "config 合法"                     'json_ok "$XHY_ETC/config.json"'
chk "出站与规则形状正确"              'warp_shape_ok'
chk "仍保留直连与黑洞出站"            'grep -q "\"tag\":\"direct\"" "$XHY_ETC/config.json" && grep -q "\"tag\":\"block\"" "$XHY_ETC/config.json"'

echo "===== 自定义参数 ====="
warp_cmd_on --port 25399 --domains "x.ai,full:grok.com" --tag warp2 >/dev/null 2>&1
chk "端口生效"                        'grep -q "\"port\":25399" "$XHY_ETC/config.json"'
chk "tag 生效"                        'grep -q "\"tag\":\"warp2\"" "$XHY_ETC/config.json"'
chk "full: 前缀写进规则"              'grep -q "\"full:grok.com\"" "$XHY_ETC/config.json"'
chk "旧 tag 已消失"                   '! grep -q "\"tag\":\"warp\"" "$XHY_ETC/config.json"'
warp_cmd_on >/dev/null 2>&1          # 复位成默认

echo "===== 幂等 ====="
before="$(cat "$XHY_ETC/config.json")"
warp_cmd_on >/dev/null 2>&1
after="$(cat "$XHY_ETC/config.json")"
chk "重复 on 不改配置"                '[ "$before" = "$after" ]'

echo "===== 与 relay entry 共存 ====="
relay_entry --to 203.0.113.10:14430 --uuid test-uuid-0000 --categories openai,anthropic >/dev/null 2>&1
chk "config 合法"                     'json_ok "$XHY_ETC/config.json"'
chk "relay 出站在"                    'grep -q "\"tag\":\"us-relay\"" "$XHY_ETC/config.json"'
chk "warp 出站在"                     'grep -q "\"tag\":\"warp\"" "$XHY_ETC/config.json"'
chk "relay 规则排在 warp 之前"        'rules_order_ok'
chk "基础 rebuild 不冲掉 warp"        'relay_reapply >/dev/null 2>&1 && warp_shape_ok'
chk "基础 block 规则仍在最后"         'warp_shape_ok'

echo "===== land 片段嗅探（warp 才需要） ====="
chk "warp 启用时 land 片段带 sniffing"  'relay_fragment 14430 u | grep -q "\"sniffing\""'
chk "routeOnly 保持 true（不改写目标）" 'relay_fragment 14430 u | grep -q "\"routeOnly\":true"'
chk "destOverride 只嗅 TLS"             'relay_fragment 14430 u | grep -q "\"destOverride\":\[\"tls\"\]"'
chk "开启嗅探后片段仍是合法 JSON"       'relay_fragment 14430 u | "$PY" -c "import json,sys;json.load(sys.stdin)"'

echo "===== warp off ====="
warp_cmd_off >/dev/null 2>&1
chk "config 合法"                     'json_ok "$XHY_ETC/config.json"'
chk "warp 出站已摘"                   '! grep -q "\"tag\":\"warp\"" "$XHY_ETC/config.json"'
chk "warp 规则已摘"                   '! grep -q "\"outboundTag\":\"warp\"" "$XHY_ETC/config.json"'
chk "relay 未受影响"                  'grep -q "\"tag\":\"us-relay\"" "$XHY_ETC/config.json"'
chk "warp.env 保留并标记 off"         'grep -q "^WARP_ENABLE=off$" "$XHY_NODES/warp.env"'
chk "warp_active 为假"                '! warp_active'
chk "wp.conf 未被删"                  '[ -f "$XHY_WARP_DIR/wp.conf" ]'

echo "===== 非法参数 ====="
chk "坏端口被拒"                      '! warp_cmd_on --port 99999 >/dev/null 2>&1'
chk "坏 tag 被拒"                     '! warp_cmd_on --tag "a.b" >/dev/null 2>&1'
chk "空域名被拒"                      '! warp_cmd_on --domains "," >/dev/null 2>&1'
chk "未知参数被拒"                    '! warp_cmd_on --nope >/dev/null 2>&1'

echo "===== warp del（收尾） ====="
warp_cmd_on >/dev/null 2>&1
warp_cmd_del >/dev/null 2>&1
chk "无 warp.env"                     '! [ -f "$XHY_NODES/warp.env" ]'
chk "无 WARP 目录"                    '! [ -d "$XHY_WARP_DIR" ]'
chk "config 合法"                     'json_ok "$XHY_ETC/config.json"'
chk "config 无 warp 残留"             '! grep -q "warp" "$XHY_ETC/config.json"'
chk "relay 仍在"                      'grep -q "\"tag\":\"us-relay\"" "$XHY_ETC/config.json"'

relay_del >/dev/null 2>&1
chk "relay 收尾后 config 合法"        'json_ok "$XHY_ETC/config.json"'

echo "===== install.sh 里 warp 排最后 ====="
chk "build.sh LIBS 顺序"              'grep -q "update relay warp)" build.sh'
chk "_lib.sh 同步加载 warp"           'grep -q "update relay warp" test/_lib.sh'

summary
