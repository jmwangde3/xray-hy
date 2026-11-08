#!/usr/bin/env bash
# SSH 防爆破守卫 + relay 防火墙规则位置的离线回归。
#
# 这两条是同一类故障的两面：规则「写进去了」不等于「会命中」。
#   * SSH 守卫：旧版把 --set 放在 --update --hitcount 之前，撞锁后每个重试包都往
#     滑窗顶时间戳，窗口永远满 → 越试越锁。实测硅谷一次会话被 DROP 674 次。
#   * relay 放行：-A 追加到 XHY-IN 链尾，落在 -j RETURN 之后 → 规则永不命中，
#     而 -C 仍返回 0，relay status 报「已放行」、链路实际断。
#
# 全程离线：iptables/ip6tables 换成「有状态的假表」（真的支持 -N/-F/-A/-I/-D/-C/-S），
# 因此能断言规则的行序，而不是只断言「某次调用发生过」。

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system
init_dirs
export XHY_SKIP_SNAPSHOT=1

# ---------------------------------------------------------------------------
# 有状态的假 iptables：链 = 文件，一行一条规则。
# ---------------------------------------------------------------------------
IPT_STATE="$TEST_TMP/ipt"
mkdir -p "$IPT_STATE"
IPT_LOG="$TEST_TMP/ipt.log"
: >"$IPT_LOG"

mkdir -p "$TEST_TMP/bin"
cat >"$TEST_TMP/bin/iptables" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${IPT_LOG:-/dev/null}"
state="${IPT_STATE:?}"
f=()
for a in "$@"; do
    case "$a" in
        -w|--wait) ;;
        *) f+=("$a") ;;
    esac
done
(( ${#f[@]} >= 2 )) || exit 1
op="${f[0]}"; ch="${f[1]}"
file="$state/$ch"

# 从第 N 个参数起到末尾拼成一条规则。$# 是函数自己的参数个数，不能用它当数组
# 上界 —— 那样循环一次都不执行，规则全是空串，测试还会「通过」一部分断言。
join() {
    local start="$1" i parts=()
    for (( i = start; i < ${#f[@]}; i++ )); do parts+=("${f[i]}"); done
    local IFS=' '
    printf '%s' "${parts[*]:-}"
}

case "$op" in
    -N) : >"$file"; exit 0 ;;
    -F) [[ -f "$file" ]] && : >"$file"; exit 0 ;;
    -X) rm -f "$file"; exit 0 ;;
    -S)
        [[ -f "$file" ]] || { echo "iptables: No chain/target/match by that name." >&2; exit 1; }
        printf -- '-N %s\n' "$ch"
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            printf -- '-A %s %s\n' "$ch" "$line"
        done <"$file"
        exit 0 ;;
    -L)
        [[ -f "$file" ]] || { echo "iptables: No chain/target/match by that name." >&2; exit 1; }
        printf 'Chain %s (policy ACCEPT)\n' "$ch"
        exit 0 ;;
    -A)
        rule="$(join 2)"
        printf '%s\n' "$rule" >>"$file"
        exit 0 ;;
    -I)
        if [[ "${f[2]:-}" =~ ^[0-9]+$ ]]; then n="${f[2]}"; rule="$(join 3)"; else n=1; rule="$(join 2)"; fi
        [[ -f "$file" ]] || : >"$file"
        n_lines=$(wc -l <"$file"); n_lines=$(( n_lines + 0 ))
        if (( n > n_lines )); then
            printf '%s\n' "$rule" >>"$file"
        else
            awk -v n="$n" -v r="$rule" 'NR==n{print r} {print}' "$file" >"$file.new"
            mv -f "$file.new" "$file"
        fi
        exit 0 ;;
    -D)
        rule="$(join 2)"
        [[ -f "$file" ]] || exit 1
        grep -Fxq -- "$rule" "$file" || exit 1
        awk -v r="$rule" '!d && $0==r {d=1; next} {print}' "$file" >"$file.new"
        mv -f "$file.new" "$file"
        exit 0 ;;
    -C)
        rule="$(join 2)"
        [[ -f "$file" ]] || exit 1
        grep -Fxq -- "$rule" "$file" || exit 1
        exit 0 ;;
esac
exit 1
FAKE
chmod +x "$TEST_TMP/bin/iptables"
cp "$TEST_TMP/bin/iptables" "$TEST_TMP/bin/ip6tables"
export PATH="$TEST_TMP/bin:$PATH"
export IPT_STATE IPT_LOG

chain_reset() {
    : >"$IPT_STATE/${1:-XHY-IN}"
}
chain_lines() {
    cat "$IPT_STATE/${1:-XHY-IN}" 2>/dev/null
}
# 某条规则的行号（1 起）；不存在输出空。
line_of() {
    local pat="$1" n=0 line
    while IFS= read -r line; do
        n=$(( n + 1 ))
        case "$line" in *"$pat"*) printf '%s' "$n"; return 0 ;; esac
    done < <(chain_lines)
    return 1
}

# 一个公开节点，让 firewall_node_ports 有东西可枚举
cat >"$XHY_NODES/n1.env" <<'EOF'
PUBLIC=1
PROTO=tcp
PORT=8443
MODE=vless
EOF
cat >"$XHY_NODES/n2.env" <<'EOF'
PUBLIC=1
PROTO=udp
PORT=9443
MODE=hysteria2
EOF
# 隧道节点不该暴露
cat >"$XHY_NODES/tunnel.env" <<'EOF'
PUBLIC=0
PROTO=tcp
PORT=18443
MODE=vless
EOF

echo "===== 阈值常量 ====="
chk "爆发窗口 30 次/60s"   '[ "$SSH_BURST_HITS" = 30 ] && [ "$SSH_BURST_WINDOW" = 60 ]'
chk "慢速窗口 120 次/1h"   '[ "$SSH_SLOW_HITS" = 120 ] && [ "$SSH_SLOW_WINDOW" = 3600 ]'
chk "SSH 端口已知"         '[ -n "$XHY_SSH_PORT" ]'

echo ""
echo "===== 守卫链构建（safe 模式） ====="
chain_reset
_apply_family iptables safe on
chk "链已建立"                 '[ -s "$IPT_STATE/XHY-IN" ]'
chk "首条是 lo ACCEPT"         '[ "$(chain_lines | head -1)" = "-i lo -j ACCEPT" ]'
chk "次条放行 ESTABLISHED"     '[ "$(chain_lines | sed -n 2p)" = "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" ]'
chk "有 rcheck 规则"           'line_of "--rcheck" >/dev/null'
chk "无 --update（旧版死锁写法）" '! grep -q -- "--update" "$IPT_STATE/XHY-IN"'
chk "爆发阈值 30 写进规则"     'grep -q -- "--seconds 60 --hitcount 30" "$IPT_STATE/XHY-IN"'
chk "慢速阈值 120 写进规则"    'grep -q -- "--seconds 3600 --hitcount 120" "$IPT_STATE/XHY-IN"'
chk "首条 rcheck 在首个 set 之前" 'r="$(line_of --rcheck)"; s="$(line_of --set)"; [ -n "$r" ] && [ -n "$s" ] && [ "$r" -lt "$s" ]'
chk "两条 rcheck 都排在各自 set 前" '[ "$(grep -c -- "--rcheck" "$IPT_STATE/XHY-IN")" = 2 ]'
chk "SSH 端口仍放行（rcheck 之后）" 'r="$(line_of --rcheck)"; a="$(line_of "--dport $XHY_SSH_PORT -j ACCEPT")"; [ -n "$a" ] && [ "$a" -gt "$r" ]'
chk "节点 TCP 8443 放行"       'grep -qx -- "-p tcp --dport 8443 -j ACCEPT" "$IPT_STATE/XHY-IN"'
chk "节点 UDP 9443 放行"       'grep -qx -- "-p udp --dport 9443 -j ACCEPT" "$IPT_STATE/XHY-IN"'
chk "隧道节点端口未放行"       '! grep -q 18443 "$IPT_STATE/XHY-IN"'
chk "safe 模式链尾是 RETURN"   '[ "$(chain_lines | tail -1)" = "-j RETURN" ]'
chk "safe 模式无 tcp DROP"     '! grep -q -- "-p tcp -j DROP" "$IPT_STATE/XHY-IN"'
chk "INPUT 挂了 XHY-IN"        'grep -qx -- "-j XHY-IN" "$IPT_STATE/INPUT"'

echo ""
echo "===== 守卫链构建（strict 模式） ====="
chain_reset
: >"$IPT_STATE/INPUT"
_apply_family iptables strict on
chk "strict 模式有 tcp DROP"   'grep -qx -- "-p tcp -j DROP" "$IPT_STATE/XHY-IN"'
chk "strict 模式有 udp DROP"   'grep -qx -- "-p udp -j DROP" "$IPT_STATE/XHY-IN"'
chk "strict 模式链尾仍是 RETURN" '[ "$(chain_lines | tail -1)" = "-j RETURN" ]'
chk "strict 下 SSH ACCEPT 在 DROP 之前" 'a="$(line_of "--dport $XHY_SSH_PORT -j ACCEPT")"; d="$(line_of "-p tcp -j DROP")"; [ -n "$a" ] && [ -n "$d" ] && [ "$a" -lt "$d" ]'

echo ""
echo "===== 守卫关闭：不写 recent 规则 ====="
chain_reset
: >"$IPT_STATE/INPUT"
_apply_family iptables safe off
chk "guard=off 无 rcheck"      '! grep -q -- "--rcheck" "$IPT_STATE/XHY-IN"'
chk "guard=off 仍放行 SSH"     'grep -q -- "--dport $XHY_SSH_PORT -j ACCEPT" "$IPT_STATE/XHY-IN"'

echo ""
echo "===== relay 放行插在链尾 RETURN 之前 ====="
chain_reset
: >"$IPT_STATE/INPUT"
_apply_family iptables safe on
RELAY_FW_CHAIN="XHY-IN"
relay_fw_add 14430 47.245.14.31 >/dev/null
chk "relay 规则已写入"         'grep -q -- "xhy-relay-14430" "$IPT_STATE/XHY-IN"'
chk "relay 在 RETURN 之前"     'r="$(line_of xhy-relay-14430)"; t="$(line_of "-j RETURN")"; [ -n "$r" ] && [ -n "$t" ] && [ "$r" -lt "$t" ]'
chk "relay 只一条"             '[ "$(grep -c -- "xhy-relay-14430" "$IPT_STATE/XHY-IN")" = 1 ]'
chk "relay_fw_present 为真"    'relay_fw_present 14430 47.245.14.31'
chk "重复 add 幂等"            'relay_fw_add 14430 47.245.14.31 >/dev/null; [ "$(grep -c -- "xhy-relay-14430" "$IPT_STATE/XHY-IN")" = 1 ]'
chk "relay_fw_del 能删掉"      'relay_fw_del 14430 47.245.14.31 XHY-IN; ! grep -q -- "xhy-relay-14430" "$IPT_STATE/XHY-IN"'

echo ""
echo "===== 旧位置（RETURN 之后）能被识别并纠正 ====="
chain_reset
printf '%s\n' "-i lo -j ACCEPT" "-j RETURN" >"$IPT_STATE/XHY-IN"
# 复现旧版 -A 追加到链尾的行为
printf '%s\n' "-p tcp --dport 14430 -s 47.245.14.31 -m comment --comment xhy-relay-14430 -j ACCEPT" >>"$IPT_STATE/XHY-IN"
chk "死规则被 present 判为未放行" '! relay_fw_present 14430 47.245.14.31'
relay_fw_add 14430 47.245.14.31 >/dev/null
chk "旧死规则被移到 RETURN 前"  'r="$(line_of xhy-relay-14430)"; t="$(line_of "-j RETURN")"; [ -n "$r" ] && [ -n "$t" ] && [ "$r" -lt "$t" ]'
chk "纠正后只剩一条"            '[ "$(grep -c -- "xhy-relay-14430" "$IPT_STATE/XHY-IN")" = 1 ]'
chk "纠正后 present 为真"       'relay_fw_present 14430 47.245.14.31'

echo ""
echo "===== strict 模式下 relay 不会被 DROP 吃掉 ====="
chain_reset
_apply_family iptables strict on
RELAY_FW_CHAIN="XHY-IN"
relay_fw_add 14430 47.245.14.31 >/dev/null
chk "relay 在 tcp DROP 之前"    'r="$(line_of xhy-relay-14430)"; d="$(line_of "-p tcp -j DROP")"; [ -n "$r" ] && [ -n "$d" ] && [ "$r" -lt "$d" ]'
chk "strict 下 present 为真"    'relay_fw_present 14430 47.245.14.31'

echo ""
echo "===== 无 RETURN 的链退回 -A ====="
chain_reset
: >"$IPT_STATE/XHY-IN"
RELAY_FW_CHAIN="XHY-IN"
relay_fw_add 14430 10.0.0.1 >/dev/null
chk "空链也能加进去"            'grep -qx -- "-p tcp --dport 14430 -s 10.0.0.1 -m comment --comment xhy-relay-14430 -j ACCEPT" "$IPT_STATE/XHY-IN"'
chk "present 为真"              'relay_fw_present 14430 10.0.0.1'

echo ""
echo "===== status 文案与实际阈值一致 ====="
export SSH_GUARD_STATUS=on
chk "文案报 60s/30"             'firewall_status --brief | grep -q "60s/30 次"'
chk "文案报 3600s/120"          'firewall_status --brief | grep -q "3600s/120 次"'
chk "文案不再出现旧值 5 次"      '! firewall_status --brief | grep -q "60s/5 次"'

echo ""
summary
