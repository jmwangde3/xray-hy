#!/usr/bin/env bash
# 伪装站扫描模块的离线断言：网段换算、域名过滤、打分、CSV 解析、缓存读写。
# 不联网、不下载二进制、不需要 root —— scanner_probe / scanner_ensure 不在这里
# 覆盖（它们要真网络），真机验证在服务器上做。
set -u
source "$(dirname "$0")/_lib.sh"
load_libs

SCANNER_CACHE="$TEST_TMP/etc/scan-cache.tsv"
SCANNER_WORK="$TEST_TMP/scan"
mkdir -p "$TEST_TMP/etc"

# ---- 架构映射（官方只有 amd64 / arm64）----
XHY_ARCH=64;        chk "x86_64 -> linux-amd64" '[[ "$(scanner_asset)" == linux-amd64 ]]'
XHY_ARCH=arm64-v8a; chk "aarch64 -> linux-arm64" '[[ "$(scanner_asset)" == linux-arm64 ]]'
XHY_ARCH=arm32-v7a; chk "armv7 不支持"          '! scanner_asset >/dev/null 2>&1'
XHY_ARCH=32;        chk "i386 不支持"           '! scanner_asset >/dev/null 2>&1'
XHY_ARCH=64

# ---- 网段换算 ----
chk "/24 归位"       '[[ "$(cidr_truncate 47.88.102.45 24)" == 47.88.102.0/24 ]]'
chk "/21 归位"       '[[ "$(cidr_truncate 47.88.102.45 21)" == 47.88.96.0/21 ]]'
chk "/20 归位"       '[[ "$(cidr_truncate 47.88.102.45 20)" == 47.88.96.0/20 ]]'
chk "非法 IP 被拒"   '! cidr_truncate not-an-ip 24 >/dev/null 2>&1'
chk "非法前缀被拒"   '! cidr_truncate 1.2.3.4 99 >/dev/null 2>&1'

# ---- 通配符证书 -> 具体 SNI ----
chk "通配符给两个候选"  '[[ "$(scanner_sni_candidates "*.easeus.com")" == "www.easeus.com easeus.com" ]]'
chk "普通域名只有一个"   '[[ "$(scanner_sni_candidates www.joyy.com)" == "www.joyy.com" ]]'

# ---- 域名过滤：一眼是代理/测试/反代的名字不能当伪装站 ----
chk "正常域名可用"       'scanner_domain_ok www.easeus.com'
chk "通配符可用"         'scanner_domain_ok "*.easeus.com"'
chk "api 子域被排除"     '! scanner_domain_ok api.foo.com'
chk "chatgpt 被排除"     '! scanner_domain_ok chatgpt.foo.com'
chk "proxy 被排除"       '! scanner_domain_ok proxy.foo.com'
chk "test 被排除"        '! scanner_domain_ok test.foo.com'
chk "k8s 假证书被排除"   '! scanner_domain_ok kubernetes.default.svc'
chk "cloudflare 反代被排除" '! scanner_domain_ok www.cloudflare.com'
chk "example.com 被排除" '! scanner_domain_ok www.example.com'
chk "纯数字不是域名"     '! scanner_domain_ok 12345.com'
chk "空值被排除"         '! scanner_domain_ok ""'

# ---- 打分：同机房 + 200 + 有内容 必须高于 远 + 404 ----
fast="$(scanner_score 5 200 5000 0)"
slow="$(scanner_score 300 404 100 0)"
wild="$(scanner_score 5 200 5000 1)"
chk "低延迟高分"         '(( fast > slow ))'
chk "通配符略扣分"       '(( wild < fast ))'
chk "分数是整数"         '[[ "$fast" =~ ^[0-9]+$ ]]'

# ---- CSV 解析：只保留 TLS1.3 + h2 + 可用的 CN ----
csv="$TEST_TMP/scan.csv"
cat >"$csv" <<'CSV'
IP,ORIGIN,TLS,ALPN,CURVE,CERT_LENGTH,CERT_SIGNATURE,CERT_PUBLICKEY,CERT_DOMAIN,CERT_ISSUER,GEO_CODE
47.88.102.65,www.easeus.com,TLS 1.3,h2,X25519,1234(certs count: 1),SHA256-RSA,RSA,*.easeus.com,"DigiCert Inc",US
47.88.100.24,www.joyy.com,TLS 1.3,h2,X25519,1234(certs count: 1),SHA256-RSA,ECDSA,www.joyy.com,"DigiCert Inc",US
47.88.102.66,a.example,TLS 1.3,http/1.1,X25519,1234(certs count: 1),SHA256-RSA,RSA,www.a.example,"Let's Encrypt",US
47.88.102.23,k8s,TLS 1.3,h2,X25519,1234(certs count: 1),SHA256-RSA,RSA,kubernetes.default.svc,"Kubernetes",US
47.88.102.70,cf,TLS 1.3,h2,X25519,1234(certs count: 1),SHA256-RSA,RSA,www.cloudflare.com,"Cloudflare, Inc.",US
47.88.102.71,proxy,TLS 1.3,h2,X25519,1234(certs count: 1),SHA256-RSA,RSA,proxy.foo.com,"Let's Encrypt",US
CSV
cand="$(scanner_candidates "$csv")"
chk "命中条数正确"       '[[ "$(printf "%s\n" "$cand" | grep -c .)" -eq 4 ]]'
chk "解析出 easeus"      'grep -q "47.88.102.65	\*.easeus.com" <<<"$cand"'
chk "issuer 去引号"      'grep -q "DigiCert Inc" <<<"$cand" && ! grep -q "\"DigiCert" <<<"$cand"'
chk "http/1.1 被过滤"    '! grep -q "a.example" <<<"$cand"'

# ---- 缓存：写入 / 有效 / 取最优 / 合并去重 / 过期 ----
rows="$TEST_TMP/ranked.tsv"
printf '90\t47.88.102.65\twww.easeus.com\t47.88.102.65:443\t5\t200\t12000\tDigiCert Inc\tTLS 1.3\t2026-11-06T23:00:00+08:00\n' >"$rows"
scanner_cache_save 47.88.102.0/24 "$rows" 1
chk "缓存写入成功"       '[[ -s "$SCANNER_CACHE" ]]'
chk "缓存刚写就有效"     'scanner_cache_valid'
chk "缓存条数 1"         '[[ "$(scanner_cache_count)" -eq 1 ]]'
chk "best 给出 SNI"      '[[ "$(scanner_cache_best | cut -f3)" == www.easeus.com ]]'

printf '95\t47.88.102.65\twww.easeus.com\t47.88.102.65:443\t5\t200\t12000\tDigiCert Inc\tTLS 1.3\t2026-11-06T23:01:00+08:00\n80\t47.88.100.24\twww.joyy.com\t47.88.100.24:443\t7\t200\t9000\tDigiCert Inc\tTLS 1.3\t2026-11-06T23:01:00+08:00\n' >"$rows"
scanner_cache_save 47.88.100.0/24 "$rows" 0
chk "合并后 2 条"        '[[ "$(scanner_cache_count)" -eq 2 ]]'
chk "同 ip+sni 取高分"   '[[ "$(scanner_cache_best | head -1 | cut -f1)" == 95 ]]'

# 过期：把 epoch 改成 1
sed -i 's/^# epoch=.*/# epoch=1 at=1970-01-01T00:00:00Z cidr=x tool=x/' "$SCANNER_CACHE"
chk "epoch=1 视为过期"   '! scanner_cache_valid'

# 用有效性重新写一份，供 pick_target 用
printf '88\t47.88.102.65\twww.easeus.com\t47.88.102.65:443\t5\t200\t12000\tDigiCert Inc\tTLS 1.3\t2026-11-06T23:02:00+08:00\n' >"$rows"
scanner_cache_save 47.88.102.0/24 "$rows" 1

# ---- 缓存候选要过 REALITY 级校验才被采用 ----
target_validate() { [[ "$2" == "www.easeus.com" ]]; }
best="$(scanner_cache_pick_valid 2>/dev/null)" && rc=0 || rc=$?
chk "命中缓存返回三元组" '[[ "$rc" -eq 0 && "$best" == "47.88.102.65:443 www.easeus.com scan" ]]'

target_validate() { return 1; }
scanner_cache_pick_valid >/dev/null 2>&1 && rc=0 || rc=$?
chk "全部失效则返回非零" '[[ "$rc" -ne 0 ]]'

# ---- pick_target 在无自定义时优先用缓存 ----
target_validate() { return 0; }
state_set TARGET_REGION auto
state_del TARGET_CUSTOM
state_del TARGET_SNI
picked="$(pick_target 2>/dev/null)" && rc=0 || rc=$?
chk "pick_target 采用缓存" '[[ "$rc" -eq 0 && "$picked" == "47.88.102.65:443 www.easeus.com scan" ]]'

# ---- 清除 ----
scanner_cache_clear >/dev/null 2>&1
chk "clear 后文件消失"   '[[ ! -f "$SCANNER_CACHE" ]]'

summary
