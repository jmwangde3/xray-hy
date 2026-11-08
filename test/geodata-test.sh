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
# 这里只测接线与分支决策（默认源 / --source / 1h 跳过 / --force），不联网。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system
make_stub_xray
# 空间闸门本身由 disk-test.sh 覆盖；这里只测分支，别让宿主机的余量影响结果。
disk_need() { return 0; }

echo "=== 源码接线：Loyalsoldier 是唯一默认 ==="
chk "定义 geodata_source"                  'grep -q "^geodata_source()" lib/core.sh'
chk "默认常量是 loyalsoldier"              'grep -q "\${XHY_GEODATA_SOURCE:-loyalsoldier}" lib/core.sh'
chk "非法源回落到 loyalsoldier"            'grep -q "|| v=\"loyalsoldier\"" lib/core.sh'
chk "定义 geodata_install_loyalsoldier"    'grep -q "^geodata_install_loyalsoldier()" lib/core.sh'
chk "走 Loyalsoldier 单独 dat"             'grep -q "Loyalsoldier/v2ray-rules-dat/releases/latest/download/\$f" lib/core.sh'
chk "保留官方整包函数（可选源）"            'grep -q "^geodata_install_official()" lib/core.sh'
chk "官方整包仍校验 .dgst"                 'grep -q "geodata 校验失败，已中止" lib/core.sh'
chk "release tag 补 v 前缀"                'grep -q "XHY_RELEASE_DL}/v\$ver/\$asset" lib/core.sh'
chk "latest 走 /releases/latest/download"  'grep -q "latest/download/\$asset" lib/core.sh'
chk "xray_install 先铺 zip 自带 dat 保底"  'grep -q "\[\[ -s \"\$unpack/\$f\" \]\]" lib/core.sh'
chk "默认源触发 Loyalsoldier 覆盖"          'grep -q "geodata_install_loyalsoldier" lib/core.sh'
chk "覆盖前有 45 MB 闸门"                  'grep -q "disk_free_mb /) >= 45" lib/core.sh'
chk "XHY_SKIP_GEODATA 仍保留现状"           'grep -q "XHY_SKIP_GEODATA:-0" lib/core.sh'
chk "写盘前总闸门"                          'grep -q "disk_need 45" lib/update.sh'
chk "update_geodata 支持 --source"          'grep -q -- "--source)" lib/update.sh'
chk "官方源走整包函数"                      'grep -q "geodata_install_official \"\$ver\"" lib/update.sh'
chk "Loyalsoldier 源走单独函数"             'grep -q "geodata_install_loyalsoldier" lib/update.sh'
chk "帮助写 geodata 参数"                  'grep -q "geodata \[--force\]" entry/main.sh'
chk "菜单 14 也转发参数"                    'grep -q "geodata) shift; update_geodata" entry/main.sh'

echo "=== core status 体积提示 ==="
chk ">9 MB 标 Loyalsoldier 默认"           'grep -q "Loyalsoldier 完整版（默认）" lib/core.sh'
chk "官方版标子集"                          'grep -q "官方版（子集" lib/core.sh'
chk "<1 MB 标异常"                          'grep -q "异常小" lib/core.sh'

echo "=== BLOCK_ADS 双标签 ==="
chk "同时带 category-ads"                  'grep -q "geosite:category-ads\",\"geosite:category-ads-all" lib/nodes.sh'

echo "=== 分支决策：默认源 / --source / 1h 跳过 / --force ==="
mkdir -p "$XRAY_ASSET" "$(dirname "$XRAY_BIN")"
printf 'GS' >"$XRAY_ASSET/geosite.dat"
printf 'GI' >"$XRAY_ASSET/geoip.dat"
touch -t 202001010000 "$XRAY_BIN"          # 核心二进制很旧 → dat 比它新

CALLED_L=0
CALLED_O=0
geodata_install_loyalsoldier() { CALLED_L=$((CALLED_L + 1)); }
geodata_install_official()     { CALLED_O=$((CALLED_O + 1)); }
unset XHY_GEODATA_SOURCE

# 刚写过（mtime 是现在）→ 1 小时内跳过
update_geodata >/dev/null 2>&1
chk "刚更新过 → 不重下"                    '[[ "$CALLED_L" -eq 0 && "$CALLED_O" -eq 0 ]]'

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

summary
