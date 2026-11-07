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
chk "xray_install 备份前看余量"    'grep -q "磁盘余量不足 120 MB，跳过旧二进制备份" lib/core.sh'
chk "update_core 回滚副本也看余量" 'grep -q "磁盘余量不足 120 MB，跳过自动回滚副本" lib/update.sh'
chk "self_check 有磁盘余量行"      'grep -q "磁盘余量 : " lib/update.sh'
chk "self_check 低余量告警"        'grep -q "根分区余量不足 200 MB" lib/update.sh'
chk "定义 cmd_clean"               'grep -q "^cmd_clean()" lib/backup.sh'
chk "定义 disk_free_mb"            'grep -q "^disk_free_mb()" lib/common.sh'
chk "分发表有 clean"               'grep -q "clean)      cmd_clean" entry/main.sh'
chk "菜单 16 支持 clean"           'grep -q "clean)  cmd_clean all" entry/main.sh'
chk "中文帮助有 clean"             'grep -q "clean \[backups|snapshots|all\]    清理旧核心二进制备份" entry/main.sh'
chk "英文帮助有 clean"             'grep -q "clean \[backups|snapshots|all\]  Drop old core backups" entry/main.sh'

summary
