#!/usr/bin/env bash
# 伪装站短名单：3-5 个候选让用户选 + --require-tfo 硬过滤的回归测试。
# 注入 target_tfo_detect / target_validate，构造一份内存缓存，完全离线。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system

export SCANNER_CACHE="$TEST_TMP/scan-cache.tsv"
TFO_SUPPORT=""

# stub_system 把探测 stub 成「不支持」；这里按 IP 注入可控结果。
target_tfo_detect() {
    case " $TFO_SUPPORT " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

make_cache() {
    local ep; ep="$(date +%s)"
    {
        printf '# xray-hy scan-cache 1\n'
        printf '# epoch=%s at=%s cidr=1.1.1.0/24 tool=v0.2.3\n' "$ep" "$(date -Is)"
        printf '95\t1.1.1.1\twww.a.com\t1.1.1.1:443\t5\t200\t8000\tIssuerA\tTLS1.3\t%s\n' "$(date -Is)"
        printf '90\t2.2.2.2\twww.b.com\t2.2.2.2:443\t6\t200\t7000\tIssuerB\tTLS1.3\t%s\n' "$(date -Is)"
        printf '85\t3.3.3.3\twww.c.com\t3.3.3.3:443\t7\t200\t6000\tIssuerC\tTLS1.3\t%s\n' "$(date -Is)"
        printf '80\t4.4.4.4\twww.d.com\t4.4.4.4:443\t8\t200\t5000\tIssuerD\tTLS1.3\t%s\n' "$(date -Is)"
        printf '75\t5.5.5.5\twww.e.com\t5.5.5.5:443\t9\t200\t4000\tIssuerE\tTLS1.3\t%s\n' "$(date -Is)"
    } >"$SCANNER_CACHE"
}

pass=0 fail=0
chk() {
    local d="$1" e="$2" g="$3"
    if [[ "$g" == "$e" ]]; then
        printf '  PASS  %s\n' "$d"; pass=$((pass + 1))
    else
        printf '  FAIL  %s（期望 [%s] 实际 [%s]）\n' "$d" "$e" "$g"; fail=$((fail + 1))
    fi
}

echo "=== 缓存有效性 ==="
make_cache
if scanner_cache_valid; then
    printf '  PASS  构造的缓存有效\n'; pass=$((pass + 1))
else
    printf '  FAIL  缓存无效\n'; fail=$((fail + 1))
fi
chk "候选数 5" "5" "$(scanner_cache_count)"

echo "=== 不强制 TFO：按质量取最高分 ==="
TFO_SUPPORT="2.2.2.2 4.4.4.4"
out="$(scanner_shortlist 0 5 2>/dev/null)"
chk "返回最高分候选"  "1.1.1.1:443 www.a.com scan" "$out"

echo "=== 强制 TFO：只留支持的候选 ==="
TFO_SUPPORT="2.2.2.2 4.4.4.4"
out="$(scanner_shortlist 1 5 2>/dev/null)"
chk "返回首个支持 TFO 的" "2.2.2.2:443 www.b.com scan" "$out"

echo "=== 只展示 2 个候选 ==="
TFO_SUPPORT="2.2.2.2 4.4.4.4"
err="$(scanner_shortlist 0 2 2>&1 >/dev/null)"
chk "列表恰好 2 行数据" "2" "$(printf '%s\n' "$err" | grep -c '^  [1-9] ' )"

echo "=== 没有任何支持 TFO 的站点 ==="
TFO_SUPPORT=""
scanner_shortlist 1 5 >/dev/null 2>&1; rc=$?
chk "require-tfo 无匹配 -> 返回 1" "1" "$rc"
TFO_SUPPORT=""
out="$(scanner_shortlist 0 5 2>/dev/null)"
chk "不强制时仍可用"  "1.1.1.1:443 www.a.com scan" "$out"

echo "=== 展示信息含 TFO 标记 ==="
TFO_SUPPORT="1.1.1.1"
err="$(scanner_shortlist 0 5 2>&1 >/dev/null)"
if printf '%s\n' "$err" | grep -q '支持'; then
    printf '  PASS  显示「支持」\n'; pass=$((pass + 1))
else
    printf '  FAIL  没显示「支持」\n'; fail=$((fail + 1))
fi
if printf '%s\n' "$err" | grep -q 'TFO'; then
    printf '  PASS  表头含 TFO 列\n'; pass=$((pass + 1))
else
    printf '  FAIL  表头缺 TFO 列\n'; fail=$((fail + 1))
fi

echo "=== scanner_pick 接受 --require-tfo ==="
TFO_SUPPORT="2.2.2.2"
out="$(scanner_pick --require-tfo 2>/dev/null)"
chk "pick --require-tfo 返回支持项" "2.2.2.2:443 www.b.com scan" "$out"

echo "=== 源码接线 ==="
for spec in \
    "scanner_shortlist 函数存在|declare -F scanner_shortlist >/dev/null" \
    "scanner_tfo_of 去重缓存|grep -q 'XHY_TFO_CACHE' lib/scanner.sh" \
    "cmd_scan 支持 --require-tfo|grep -q -- '--require-tfo) require=1' entry/main.sh" \
    "cmd_scan 会交互询问|grep -q '是否只选支持 TFO' entry/main.sh" \
    "target 菜单有 TFO 提问|grep -q '是否只选支持 TFO' lib/target.sh" \
    "帮助说明 3-5 个候选|grep -q '列出 3-5 个候选' entry/main.sh" \
    "打分不因 TFO 加权|grep -q '不把 TFO 能力纳入打分' lib/scanner.sh"; do
    d="${spec%%|*}"; c="${spec#*|}"
    if eval "$c" >/dev/null 2>&1; then
        printf '  PASS  %s\n' "$d"; pass=$((pass + 1))
    else
        printf '  FAIL  %s\n' "$d"; fail=$((fail + 1))
    fi
done

echo ""
echo "shortlist-test: $pass passed, $fail failed"
(( fail == 0 ))
