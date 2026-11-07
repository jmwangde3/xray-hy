#!/usr/bin/env bash
# 磁盘余量检查与 xhy clean 的回归测试。
# 背景：根分区满时 sshd 会失去响应，而代理仍在工作 —— 这个故障在 427 MB 的
# 小盘 VPS 上真实发生过（切 core channel 时每次备份 ~30 MB 的旧二进制）。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source test/_lib.sh
load_libs
stub_system

echo "=== disk_free_mb ==="
free="$(disk_free_mb "$TEST_TMP")"
chk "返回纯数字"     '[[ "$free" =~ ^[0-9]+$ ]]'
chk "数值大于 0"     '(( free > 0 ))'
chk "取不到的路径返回 0" '[[ "$(disk_free_mb /nonexistent-path-xyz)" =~ ^[0-9]+$ ]]'

echo "=== cmd_clean：只保留最近若干份 ==="
init_dirs
i=0
while (( i < 3 )); do
    printf 'fake-binary-%d' "$i" >"$XHY_BACKUP/xray-26.3.$i-2026010${i}000000"
    i=$((i + 1))
done
i=0
while (( i < 6 )); do
    printf 'snap' >"$XHY_SNAPSHOTS/state.2026010100000${i}.tar.gz"
    i=$((i + 1))
done
i=0
while (( i < 25 )); do
    printf 'bak' >"$XHY_BACKUP/node.202601010000$(printf '%02d' "$i").bak"
    i=$((i + 1))
done
printf 'keep-me-please' >"$XHY_BACKUP/xhy-manual-keep.tar.gz"

before_snap="$(ls -1 "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
cmd_clean all >/dev/null 2>&1
rc=$?
chk "返回 0"                 '[[ $rc -eq 0 ]]'
chk "二进制备份只剩 1 个"    '[[ $(ls -1 "$XHY_BACKUP"/xray-* 2>/dev/null | wc -l | tr -d " ") -eq 1 ]]'
chk "快照只剩 5 个"          '[[ $(ls -1 "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null | wc -l | tr -d " ") -eq 5 ]]'
chk "快照原本是 6 个"        '[[ $before_snap -eq 6 ]]'
chk ".bak 只剩 20 个"        '[[ $(ls -1 "$XHY_BACKUP"/*.bak 2>/dev/null | wc -l | tr -d " ") -eq 20 ]]'
chk "不认识的备份文件不动"   '[[ -f "$XHY_BACKUP/xhy-manual-keep.tar.gz" ]]'
chk "保留的那份内容完整"     '[[ -s "$(ls -1 "$XHY_BACKUP"/xray-* | head -1)" ]]'

echo "=== cmd_clean：没有多余文件时不报错 ==="
cmd_clean all >/dev/null 2>&1
chk "重复执行仍返回 0"       '[[ $? -eq 0 ]]'

echo "=== cmd_clean backups / snapshots 只清自己那类 ==="
rm -f "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null || true
i=0
while (( i < 7 )); do
    printf 'snap' >"$XHY_SNAPSHOTS/state.2026020100000${i}.tar.gz"
    i=$((i + 1))
done
cmd_clean snapshots >/dev/null 2>&1
chk "snapshots 清到 5 个"     '[[ $(ls -1 "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null | wc -l | tr -d " ") -eq 5 ]]'
chk "backups 不受影响"        '[[ $(ls -1 "$XHY_BACKUP"/xray-* 2>/dev/null | wc -l | tr -d " ") -eq 1 ]]'

echo "=== 源码接线 ==="
chk "xray_install 有写前闸门"      'grep -q "disk_need 90" lib/core.sh'
chk "旧二进制默认不再归档"          'grep -q "XHY_BACKUP_CORE:-0" lib/core.sh'
chk "update_core 有回滚副本闸门"    'grep -q "不足 100 MB，无法建立回滚副本" lib/update.sh'
chk "self_check 有磁盘余量行"      'grep -q "磁盘余量 : " lib/update.sh'
chk "self_check 阈值按机型自适应"   'grep -q "_low=80; else _low=200" lib/update.sh'
chk "preflight 阈值小盘取 90 MB"    'grep -q "need_mb=90; else need_mb=300" lib/update.sh'
chk "geodata 更新前查余量"          'grep -q "disk_need 45" lib/update.sh'
chk "定义 cmd_clean"               'grep -q "^cmd_clean()" lib/backup.sh'
chk "定义 disk_free_mb"            'grep -q "^disk_free_mb()" lib/common.sh'
chk "分发表有 clean"               'grep -q "clean)      cmd_clean" entry/main.sh'
chk "菜单 16 支持 clean"           'grep -q "clean)  cmd_clean all" entry/main.sh'
chk "中文帮助有 clean"             'grep -Fq "clean [backups|snapshots|tarballs|tmp|all]  清理旧核心二进制" entry/main.sh'
chk "英文帮助有 clean"             'grep -Fq "clean [backups|snapshots|tarballs|tmp|all]  Drop old core backups" entry/main.sh'
chk "帮助说明 tarballs 含义"       'grep -Fq "tarballs = xhy backup 产物" entry/main.sh'

echo "=== file_kb / human_kb ==="
printf '0123456789abcdef' >"$TEST_TMP/kb-probe"
chk "file_kb 返回数字"        '[[ "$(file_kb "$TEST_TMP/kb-probe")" =~ ^[0-9]+$ ]]'
chk "file_kb 不存在的路径给 0" '[[ "$(file_kb "$TEST_TMP/nope-xyz")" == "0" ]]'
chk "human_kb 0 -> 0 KB"      '[[ "$(human_kb 0)" == "0 KB" ]]'
chk "human_kb 512 -> 512 KB"  '[[ "$(human_kb 512)" == "512 KB" ]]'
chk "human_kb 1536 -> 1.5 MB" '[[ "$(human_kb 1536)" == "1.5 MB" ]]'
chk "human_kb 2048 -> 2.0 MB" '[[ "$(human_kb 2048)" == "2.0 MB" ]]'

# 回归：v1.6.1 在 47.88.102.45 上报「删除 2 个，释放 0 MB」，因为
# `ls -1t $XHY_BACKUP/xray-*` 把 update_core 的零字节 xray-rollback.?????? 也算成
# 二进制备份，排序后「最新一份」可能是这个残留，真正的 30 MB 备份反而被当旧文件。
echo "=== 回归：xray-rollback 残留不能当二进制备份计数 ==="
rm -rf "$XHY_BACKUP"; mkdir -p "$XHY_BACKUP"
head -c 8192 /dev/zero >"$XHY_BACKUP/xray-26.10.1-20260101000000"
head -c 4096 /dev/zero >"$XHY_BACKUP/xray-26.9.9-20251201000000"
: >"$XHY_BACKUP/xray-rollback.Ab12Cd"
touch -t 202601030000 "$XHY_BACKUP/xray-26.9.9-20251201000000"
touch -t 202601040000 "$XHY_BACKUP/xray-26.10.1-20260101000000"
touch -t 202601050000 "$XHY_BACKUP/xray-rollback.Ab12Cd"   # 残留是最新的
out="$(cmd_clean backups 2>&1)"
chk "零字节残留被清掉"        '[[ ! -e "$XHY_BACKUP/xray-rollback.Ab12Cd" ]]'
chk "最新真实备份保留"        '[[ -s "$XHY_BACKUP/xray-26.10.1-20260101000000" ]]'
chk "较旧的真实备份被删"      '[[ ! -e "$XHY_BACKUP/xray-26.9.9-20251201000000" ]]'
chk "确实只剩 1 个二进制备份" '[[ $(ls -1 "$XHY_BACKUP"/xray-* 2>/dev/null | wc -l | tr -d " ") -eq 1 ]]'
chk "逐条报出被删文件与体积"  'grep -q "xray-rollback.Ab12Cd" <<<"$out"'
chk "报告 KB 级释放量而非 0 MB" 'grep -qE "[0-9]+ KB" <<<"$out"'
chk "结尾写合计删除量"        'grep -q "本次删除" <<<"$out"'

echo "=== cmd_clean tarballs：打包备份与还原前快照 ==="
rm -rf "$XHY_BACKUP"; mkdir -p "$XHY_BACKUP"
i=0
while (( i < 5 )); do
    head -c 2048 /dev/zero >"$XHY_BACKUP/xhy-backup-2026010${i}.tar.gz"
    touch -t 2026010$(( i + 1 ))0000 "$XHY_BACKUP/xhy-backup-2026010${i}.tar.gz"
    i=$(( i + 1 ))
done
head -c 1024 /dev/zero >"$XHY_BACKUP/pre-restore-20260106000000"
cmd_clean tarballs >/dev/null 2>&1
chk "打包备份+还原前共 3 份"   '[[ $(ls -1 "$XHY_BACKUP"/xhy-backup-*.tar.gz "$XHY_BACKUP"/pre-restore-* 2>/dev/null | wc -l | tr -d " ") -eq 3 ]]'
chk "最新打包备份保留"         '[[ -f "$XHY_BACKUP/xhy-backup-20260104.tar.gz" ]]'
chk "还原前快照保留（最新）"   '[[ -f "$XHY_BACKUP/pre-restore-20260106000000" ]]'
chk "最旧的已被删"             '[[ ! -f "$XHY_BACKUP/xhy-backup-20260100.tar.gz" ]]'
chk "tarballs 不动二进制备份"  '[[ -z "$(ls -1 "$XHY_BACKUP"/xray-* 2>/dev/null)" ]]'

echo "=== 大体积 .bak：geoip/geosite 历史副本一律清掉 ==="
# 真实病例：47.88.102.45 的 backups 目录 63.8 MB 里 29.5 MB 是 geoip.dat（19 MB）
# 与 geosite.dat（10 MB）的旧副本。v1.7 起 geodata 不再进备份，这些就是纯垃圾。
rm -rf "$XHY_BACKUP"; mkdir -p "$XHY_BACKUP"
i=1
while (( i <= 3 )); do
    head -c $(( 2048 * 1024 )) /dev/zero >"$XHY_BACKUP/geoip.dat.2026010${i}000000.bak"
    head -c $(( 2048 * 1024 )) /dev/zero >"$XHY_BACKUP/geosite.dat.2026010${i}000000.bak"
    touch -t 2026010$(( i + 1 ))0000 "$XHY_BACKUP/geoip.dat.2026010${i}000000.bak"
    touch -t 2026010$(( i + 1 ))0000 "$XHY_BACKUP/geosite.dat.2026010${i}000000.bak"
    i=$(( i + 1 ))
done
printf 'tiny' >"$XHY_BACKUP/config.json.20260101000000.bak"
out="$(cmd_clean all 2>&1)"
chk "geoip 旧副本全清"        '[[ -z "$(ls -1 "$XHY_BACKUP"/geoip.dat.*.bak 2>/dev/null)" ]]'
chk "geosite 旧副本全清"      '[[ -z "$(ls -1 "$XHY_BACKUP"/geosite.dat.*.bak 2>/dev/null)" ]]'
chk "小 .bak 不受影响"        '[[ -f "$XHY_BACKUP/config.json.20260101000000.bak" ]]'
chk "报告里报出 MB 级释放量"  'grep -qE "[0-9]+\.[0-9] MB" <<<"$out"'

echo "=== cmd_clean：未知参数拒绝执行 ==="
( cmd_clean bogus ) >/dev/null 2>&1
rc=$?
chk "未知参数非零退出"       '[[ $rc -ne 0 ]]'

echo "=== disk_need：写前闸门（不足即失败，不是警告） ==="
chk "余量足够时通过"          'disk_need 1 "测试"'
chk "需求超过余量时失败"      '! disk_need 999999 "测试"'
chk "失败时给出清理命令"      'grep -q "xhy clean all" <<<"$(disk_need 999999 测试 2>&1)"'
chk "失败时报出需要的 MB"     'grep -q "至少需要 999999 MB" <<<"$(disk_need 999999 测试 2>&1)"'

echo "=== 备份只留配置：可重下的大件不进 backups ==="
for big in xray geoip.dat geosite.dat; do
    chk "认定 $big 可重新下载" "backup_is_redownloadable /usr/local/bin/$big"
done
chk "配置类不算可重下载"      '! backup_is_redownloadable /etc/xray-hy/config.json'

rm -rf "$XHY_BACKUP"; mkdir -p "$XHY_BACKUP"
head -c 4096 /dev/zero >"$TEST_TMP/geoip.dat"
printf '{"a":1}' >"$TEST_TMP/config.json"
backup_file "$TEST_TMP/geoip.dat" >/dev/null 2>&1
chk "geoip.dat 不留 .bak"      '[[ -z "$(ls -1 "$XHY_BACKUP"/geoip.dat.* 2>/dev/null)" ]]'
backup_file "$TEST_TMP/config.json" >/dev/null 2>&1
chk "config.json 留了 .bak"    '[[ -n "$(ls -1 "$XHY_BACKUP"/config.json.*.bak 2>/dev/null)" ]]'
i=1
while (( i <= 4 )); do
    printf 'x' >"$XHY_BACKUP/config.json.2026010100000${i}.bak"
    touch -t 2026010${i}0000 "$XHY_BACKUP/config.json.2026010100000${i}.bak"
    i=$(( i + 1 ))
done
backup_file "$TEST_TMP/config.json" >/dev/null 2>&1
chk "写完就裁到最新 2 份"      '[[ $(ls -1 "$XHY_BACKUP"/config.json.*.bak 2>/dev/null | wc -l | tr -d " ") -eq 2 ]]'

echo "=== 回归：余量为 0 时不得破坏现有二进制 ==="
# 47.88.102.45 上 install 先 truncate 再写，0 MB 余量下留下 11 MB 半截文件，
# 而失败被误报成「架构或依赖不匹配」。闸门前移后应在下载前就中止。
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/asset"
printf 'OLD-BINARY-CONTENT' >"$TEST_TMP/bin/xray"; chmod 0755 "$TEST_TMP/bin/xray"
old_sum="$(sha256sum "$TEST_TMP/bin/xray" | awk '{print $1}')"
out="$(
    disk_free_mb() { printf '0'; }
    XRAY_BIN="$TEST_TMP/bin/xray"
    XRAY_ASSET="$TEST_TMP/asset"
    xray_install v1.0.0 2>&1
)"
rc=$?
chk "余量 0 时安装失败"        '[[ $rc -ne 0 ]]'
chk "原二进制逐字节未变"       '[[ "$(sha256sum "$TEST_TMP/bin/xray" | awk "{print \$1}")" == "$old_sum" ]]'
chk "报错点名磁盘余量不足"     'grep -q "至少需要 90 MB" <<<"$out"'
chk "没有下载就被拦下"         '! grep -q "下载 Xray" <<<"$out"'

echo "=== 防火墙快照：空表不存，同类留 3 份 ==="
chk "定义 _fw_snapshot"        'grep -q "^_fw_snapshot()" lib/hardening.sh'
chk "firewall_apply 走该函数"   'grep -q "_fw_snapshot iptables" lib/hardening.sh'
chk "空表跳过并提示"           'grep -q "跳过快照" lib/hardening.sh'
chk "同类只留 3 份"            'grep -q "n > 3" lib/hardening.sh'

summary
