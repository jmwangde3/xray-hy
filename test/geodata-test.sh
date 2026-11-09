#!/usr/bin/env bash
# geodata 来源回归。
#
# v1.12.2 曾无条件覆盖成 Loyalsoldier 版 → v1.13.0 改成官方版为默认 →
# v1.14.0 又改回 **Loyalsoldier 为默认**。理由（拆 protobuf 逐域名实测）：
# 官方 release 自带的 dat 是 Loyalsoldier 版的**真子集**，差异全是「仅 Loyalsoldier
# 有」——google 少 114 条、gfw 整个分类缺失(4433 条)、geolocation-!cn 少 3819 条、
# category-ai-!cn 少 2 条、anthropic/xai/github-copilot 各少 1、disney 少 2。
# 官方「多出来」的只有 geolocation-!cn 里 13 条乱码/正则写法差异，实质 0 条。
#
# 这里只测接线与分支决策（默认源 / --source / 1h 跳过 / --force / 源标记与切源），不联网。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system
make_stub_xray
# 空间闸门本身由 disk-test.sh 覆盖；这里只测分支，别让宿主机的余量影响结果。
disk_need() { return 0; }

chk "默认源为 Loyalsoldier" '[[ "$(XHY_GEODATA_SOURCE= geodata_source)" == loyalsoldier ]]'
chk "未知源回落默认" '[[ "$(XHY_GEODATA_SOURCE=bogus geodata_source)" == loyalsoldier ]]'

echo "=== core status 体积提示 ==="
chk ">9 MB 标 Loyalsoldier 默认"           'grep -q "Loyalsoldier 完整版（默认）" lib/core.sh'
chk "官方版标子集"                          'grep -q "官方版（子集" lib/core.sh'
chk "<6 MB 标体积异常"                      'grep -q "体积异常" lib/core.sh'

echo "=== BLOCK_ADS 双标签 ==="
chk "同时带 category-ads"                  'grep -q "geosite:category-ads\",\"geosite:category-ads-all" lib/nodes.sh'

echo "=== 分支决策：默认源 / --source / 1h 跳过 / --force ==="
mkdir -p "$XRAY_ASSET" "$(dirname "$XRAY_BIN")"
printf 'GS' >"$XRAY_ASSET/geosite.dat"
printf 'GI' >"$XRAY_ASSET/geoip.dat"
touch -t 202001010000 "$XRAY_BIN"          # 核心二进制很旧 → dat 比它新

CALLED_L=0
CALLED_O=0
geodata_install_loyalsoldier() { CALLED_L=$((CALLED_L + 1)); printf 'loyalsoldier\n' >"$XRAY_ASSET/.geodata-source"; }
geodata_install_official() { CALLED_O=$((CALLED_O + 1)); printf 'official\n' >"$XRAY_ASSET/.geodata-source"; }
unset XHY_GEODATA_SOURCE

# 刚写过（mtime 是现在）+ 源标记与默认源一致 → 1 小时内跳过
printf 'loyalsoldier\n' >"$XRAY_ASSET/.geodata-source"
update_geodata >/dev/null 2>&1
chk "同源且刚更新 → 不重下"                '[[ "$CALLED_L" -eq 0 && "$CALLED_O" -eq 0 ]]'

update_geodata --force >/dev/null 2>&1
chk "默认源 = Loyalsoldier"                '[[ "$CALLED_L" -eq 1 && "$CALLED_O" -eq 0 ]]'

update_geodata --force --source official >/dev/null 2>&1
chk "--source official 走整包"             '[[ "$CALLED_O" -eq 1 ]]'

XHY_GEODATA_SOURCE=official update_geodata --force >/dev/null 2>&1
chk "env 指定 official 也生效"             '[[ "$CALLED_O" -eq 2 ]]'

XHY_GEODATA_SOURCE=bogus update_geodata --force >/dev/null 2>&1
chk "非法源回落到 Loyalsoldier"            '[[ "$CALLED_L" -eq 2 ]]'

chk "未知参数被拒"                          '! ( update_geodata --bogus ) >/dev/null 2>&1'
chk "--source 非法值被拒"                   '! ( update_geodata --force --source bogus ) >/dev/null 2>&1'

# dat 比核心旧 → 即使没 --force 也应重下
touch -t 201901010000 "$XRAY_ASSET/geosite.dat" "$XRAY_ASSET/geoip.dat"
update_geodata >/dev/null 2>&1
chk "dat 比核心旧 → 重下"                  '[[ "$CALLED_L" -eq 3 ]]'

echo "=== v1.14.1：源切换不被 1h 跳过吞掉 ==="
printf 'GS' >"$XRAY_ASSET/geosite.dat"
printf 'GI' >"$XRAY_ASSET/geoip.dat"
printf 'loyalsoldier\n' >"$XRAY_ASSET/.geodata-source"
CALLED_L=0; CALLED_O=0
update_geodata --source official >/dev/null 2>&1
chk "切 official 不被跳过"                 '[[ "$CALLED_O" -eq 1 ]]'
chk "切源后 stamp 更新"                    '[[ "$(cat "$XRAY_ASSET/.geodata-source")" == "official" ]]'
CALLED_L=0; CALLED_O=0
update_geodata --source loyalsoldier >/dev/null 2>&1
chk "切回 loyalsoldier 也不跳过"           '[[ "$CALLED_L" -eq 1 ]]'
printf 'loyalsoldier\n' >"$XRAY_ASSET/.geodata-source"
CALLED_L=0; CALLED_O=0
XHY_GEODATA_SOURCE=official update_geodata >/dev/null 2>&1
chk "env 切源同样生效"                     '[[ "$CALLED_O" -eq 1 ]]'
# 下载失败时不能写 stamp（否则下次会误判「已同源」而跳过）
geodata_install_loyalsoldier() { CALLED_L=$((CALLED_L + 1)); return 1; }
printf 'official\n' >"$XRAY_ASSET/.geodata-source"
chk "下载失败返回非零" '! update_geodata --force --source loyalsoldier'
chk "下载失败不写 stamp"                   '[[ "$(cat "$XRAY_ASSET/.geodata-source")" == "official" ]]'
unset XHY_GEODATA_SOURCE

summary
