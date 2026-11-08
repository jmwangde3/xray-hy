#!/usr/bin/env bash
# geodata 来源回归。
#
# v1.12.x 曾把安装后的 geodata 无条件覆盖成 Loyalsoldier 版；v1.13.0 起改回
# **Xray 官方 release 自带的 dat**（与核心同源）。理由：两份标签集几乎一样
# （官方 1564 / Loyalsoldier 1562 个 tag），3.9 MB 的体积差全在 category-ads-all
# （905 vs 199 451 条），而常用的是 category-ads / geolocation-!cn / 各 AI 分类。
#
# 这里只测接线与分支决策（同源跳过 / --force / 陈旧重下），不联网、不落盘到
# 真实 asset 目录。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system
make_stub_xray
# 空间闸门本身由 disk-test.sh 覆盖；这里只测分支，别让宿主机的余量影响结果。
disk_need() { return 0; }

echo "=== 源码接线：官方源是唯一默认 ==="
chk "定义 geodata_install_official" 'grep -q "^geodata_install_official()" lib/core.sh'
chk "按架构取官方整包"              'grep -q "Xray-linux-\${XHY_ARCH}.zip" lib/core.sh'
chk "整包强制校验 .dgst"            'grep -q "geodata 校验失败，已中止" lib/core.sh'
chk "解包只取两个 dat"              'grep -q "unzip -o -q \"\$tmp/\$asset\" -d \"\$tmp/unpack\" geosite.dat geoip.dat" lib/core.sh'
chk "写盘前过闸门"                  'grep -q "disk_need 45" lib/update.sh'
chk "不再引用 Loyalsoldier 源"      '! grep -rq "v2ray-rules-dat" lib/'
chk "update_geodata 调官方函数"     'grep -q "geodata_install_official \"\$ver\"" lib/update.sh'
chk "update_geodata 不再内联下载"   '! grep -q "更新 \$f" lib/update.sh'
chk "install 不再二次下载 geo"      '! grep -q "完整版）" lib/core.sh'
chk "帮助写 geodata [--force]"      'grep -q "geodata \[--force\]" entry/main.sh'
chk "菜单 14 也转发参数"            'grep -q "geodata) shift; update_geodata" entry/main.sh'

echo "=== 分支决策：同源跳过 / --force 重下 / 陈旧重下 ==="
mkdir -p "$XRAY_ASSET" "$(dirname "$XRAY_BIN")"
printf 'GS' >"$XRAY_ASSET/geosite.dat"
printf 'GI' >"$XRAY_ASSET/geoip.dat"
touch -t 202001010000 "$XRAY_BIN"          # 核心二进制很旧 → dat 比它新 = 同源
CALLED=0
geodata_install_official() { CALLED=$((CALLED + 1)); }

update_geodata >/dev/null 2>&1
chk "dat 比核心新 → 不重下"          '[[ "$CALLED" -eq 0 ]]'
chk "跳过时返回 0"                   '[[ "$(update_geodata >/dev/null 2>&1; echo $?)" == "0" ]]'

update_geodata --force >/dev/null 2>&1
chk "--force 强制重下"               '[[ "$CALLED" -eq 1 ]]'

touch -t 201901010000 "$XRAY_ASSET/geosite.dat" "$XRAY_ASSET/geoip.dat"
update_geodata >/dev/null 2>&1
chk "dat 比核心旧 → 重下"            '[[ "$CALLED" -eq 2 ]]'

chk "未知参数被拒"                   '! ( update_geodata --bogus ) >/dev/null 2>&1'

echo "=== 版本跟随核心（不是 latest 盲跟） ==="
chk "取已装核心版本"                 'grep -q "xray_installed_version 2>/dev/null | sed" lib/update.sh'
chk "核心未装才退回 latest"          'grep -q "ver=\"latest\"" lib/update.sh'
chk "辅助函数内部也留 latest 兜底"   'grep -q "\[\[ -n \"\$ver\" \]\] || ver=\"latest\"" lib/core.sh'

echo "=== core status 只对异常体积告警 ==="
chk "Loyalsoldier 版才提示换回"      'grep -q "疑似 Loyalsoldier 版" lib/core.sh'
chk "<1 MB 提示异常"                 'grep -q "异常小" lib/core.sh'
chk "不再有 9 MB 的旧提示"           '! grep -q "19.9 万条" lib/core.sh'

echo "=== BLOCK_ADS 不再单押 category-ads-all ==="
chk "同时带 category-ads"            'grep -q "geosite:category-ads\",\"geosite:category-ads-all" lib/nodes.sh'

summary
