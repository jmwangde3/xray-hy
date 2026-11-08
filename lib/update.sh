#!/usr/bin/env bash
# xray-hy / script, core, geodata and configuration updates.

# 单文件发布后，更新脚本 = 下载新的 install.sh -> 语法检查 -> 原子替换自己。
# 不依赖 git，也不会把下载到的内容直接喂给 shell：先落到临时文件、跑
# `bash -n`、比对构建号，确认后整文件替换。配置与节点数据完全不动。
#
# 非交互门控（借鉴 idleleo 的发布序列策略）：
#   --yes          自动确认；仅限同一主版本序列内（v1.x -> v1.y）
#   --allow-major  跨主版本（v1 -> v2）时解除 --yes 的限制，需与 --yes 同用
update_script() {
    local autoyes=0 allowmajor=0 a
    for a in "$@"; do
        case "$a" in
            --yes) autoyes=1 ;;
            --allow-major) allowmajor=1 ;;
            *) die "update script 的选项只有 --yes 和 --allow-major，收到: $a" ;;
        esac
    done
    need_root

    # 单文件永远装在 /usr/local/bin/xhy。仓库模式下运行的是 $REPO/xhy（XHY_DEV=1），
    # 原地覆盖会把 42 行 dev 入口换成 4307 行 install.sh（版本回退、git 变脏）。
    # 正确做法是往规范路径装：跑一次 update script 就从「git 克隆」变成「单文件直装」，
    # 仓库目录本身不动。
    local canonical="${XHY_BINDIR:-/usr/local/bin}/xhy"
    local repo_mode=0 layout_bad=0 selfreal
    if [[ -f "$XHY_SCRIPT_DIR/build.sh" && -f "$XHY_SCRIPT_DIR/entry/main.sh" ]]; then
        repo_mode=1
        info "检测到仓库模式（$XHY_SCRIPT_DIR）：本次迁移为单文件直装 $canonical（仓库目录本身不动）"
    fi
    if [[ -L "$canonical" ]]; then
        layout_bad=1
    fi
    selfreal="$(readlink -f "$XHY_SELF" 2>/dev/null || printf '%s' "$XHY_SELF")"
    if [[ "$selfreal" != "$(readlink -f "$canonical" 2>/dev/null || printf '%s' "$canonical")" ]]; then
        layout_bad=1
    fi
    info "当前版本: $XHY_VERSION (build $XHY_BUILD)"
    info "检查更新: $XHY_INSTALL_URL"
    local tmp newbuild newver
    tmp="$(mktemp "${TMPDIR:-/tmp}/xhy-update.XXXXXX")" || die "无法创建临时文件"
    if ! fetch "$XHY_INSTALL_URL" "$tmp"; then
        rm -f "$tmp"
        warn "拉取失败，保持当前版本 $XHY_VERSION"
        return 1
    fi
    if ! bash -n "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        die "下载的脚本未通过 bash -n 语法检查，已放弃（本地脚本未改动）"
    fi
    # `| head -1` 会在 sed 还没写完时关管道，pipefail+errexit 下变成 141(SIGPIPE)
    # 直接把整个升级打死（实测 2026-11-07 22:5x 三台全中）。必须兜住。
    newbuild="$(sed -n 's/^XHY_BUILD="\(.*\)"$/\1/p' "$tmp" | head -1 || true)"
    if [[ -z "$newbuild" ]]; then
        rm -f "$tmp"
        die "下载的脚本里找不到构建号，可能不是本项目的 install.sh，已放弃"
    fi
    if [[ "$newbuild" == "$XHY_BUILD" ]] && (( ! layout_bad )); then
        rm -f "$tmp"
        ok "脚本已是最新 ($XHY_VERSION build $newbuild)"
        return 0
    fi
    if [[ "$newbuild" == "$XHY_BUILD" ]]; then
        info "已是最新版本，但入口布局需要纠正（旧软链或非规范路径），重装到 $canonical"
    else
        newver="$(sed -n 's/^XHY_VERSION="\(.*\)"$/\1/p' "$tmp" | head -1 || true)"
        [[ -n "$newver" ]] || newver="未知"
        info "发现新版本: $newver (build $newbuild，当前 $XHY_VERSION build $XHY_BUILD)"
        if have_cmd diff; then
            diff -u "$XHY_SELF" "$tmp" | head -40 || true
        fi
        if [[ "${newver%%.*}" != "${XHY_VERSION%%.*}" ]]; then
            warn "这是跨主版本更新 ($XHY_VERSION -> $newver)，可能包含不兼容变更，建议先看 release notes。"
            if (( autoyes && ! allowmajor )); then
                rm -f "$tmp"
                die "非交互模式拒绝跨主版本更新；确认后请加 --allow-major 重试"
            fi
        fi
        if (( autoyes )); then
            info "--yes: 自动确认替换"
        elif ! confirm "替换 $canonical 为这个构建？配置与节点数据不受影响。" "y"; then
            rm -f "$tmp"
            info "已取消"
            return 0
        fi
    fi
    reconcile_bin
    # 只备份真正的单文件本体；仓库模式下的 $REPO/xhy 是开发入口，不进备份目录
    if (( ! repo_mode )) && [[ -f "$XHY_SELF" && ! -L "$XHY_SELF" ]]; then
        backup_file "$XHY_SELF"
    fi
    if ! install -m 0755 "$tmp" "$canonical.new" || ! mv -f "$canonical.new" "$canonical"; then
        rm -f "$tmp" "$canonical.new"
        die "替换失败，旧版本仍在 $canonical"
    fi
    rm -f "$tmp"
    _cleanup_legacy_self
    ok "已更新到 build $newbuild（$canonical）"
    if (( layout_bad )); then
        ok "入口布局已纠正：$canonical 现在是单文件实体（非软链）"
    fi
    info "当前进程仍是旧版，下次执行 xhy 生效"
    return 0
}

update_core() {
    need_root
    init_dirs
    local ver rollback="" force="${1:-}"
    [[ "$force" == "--force" ]] || force=""
    ver="$(xray_resolve_version)"
    info "版本通道 $(xray_channel) -> 目标 $ver"

    # 回滚副本是「换核这次事务」的临时保险，不是归档备份（归档备份已取消，
    # 见 xray_install：36 MB 一份且可重下）。它只在换核期间存在，成功/失败都删。
    # 没有副本就不开工 —— 换核是唯一会原地改生产二进制的操作。
    if [[ -x "$XRAY_BIN" ]]; then
        if (( $(disk_free_mb "$XHY_BACKUP") < 100 )); then
            err "根分区余量 $(disk_free_mb "$XHY_BACKUP") MB，不足 100 MB，无法建立回滚副本"
            err "先清理：xhy clean all"
            [[ "$force" == "--force" ]] || die "拒绝在无退路的情况下换核（确要如此：xhy core update --force）"
            warn "--force：跳过回滚副本，换核失败需手动重装旧版本"
        else
            rollback="$(mktemp "$XHY_BACKUP/xray-rollback.XXXXXX" 2>/dev/null || true)"
            if [[ -n "$rollback" ]] && cp -a "$XRAY_BIN" "$rollback"; then :; else rollback=""; fi
            [[ -n "$rollback" ]] || warn "回滚副本创建失败，继续安装（失败需手动重装旧版本）"
        fi
    fi
    xray_install "$ver"
    if [[ -s "$XHY_ETC/config.json" ]] && ! xray_config_test >/dev/null 2>&1; then
        if [[ -n "$rollback" ]]; then
            cp -a "$rollback" "$XRAY_BIN"
            rm -f "$rollback"          # 回滚副本用完就删，别在小盘上留 30 MB
            err "新版本 $ver 无法加载现有配置，已自动回滚到原二进制。"
        fi
        die "请检查 $XHY_ETC/config.json，或改用兼容版本"
    fi
    if [[ -s "$XHY_ETC/config.json" ]]; then config_reload; fi
    [[ -n "$rollback" ]] && rm -f "$rollback"
    ok "Xray 更新完成: $("$XRAY_BIN" version 2>/dev/null | head -1)"
}

# geodata 与核心同源：官方 Xray release 的 dat（v1.13.0 起的默认源）。
# 官方不单独发 dat 资产，只能下整包解出来，所以：
#   · 版本跟随已装核心，不跟 latest —— 升核心会顺带刷新 dat，数据不会漂；
#   · 默认先判「dat 比核心二进制新」就跳过，避免 `xhy update all` 刚装完核心又
#     多下一次 16.7 MB；要重下用 --force。
update_geodata() {
    need_root
    local force=0 ver
    case "${1:-}" in
        --force|-f) force=1 ;;
        "") ;;
        *) die "用法: xhy update geodata [--force]" ;;
    esac
    install -d -m 0755 "$XRAY_ASSET"
    ver="$(xray_installed_version 2>/dev/null | sed 's/^v//' || true)"
    [[ -n "$ver" && "$ver" != "未安装" ]] || ver="latest"

    if (( ! force )) && [[ -s "$XRAY_ASSET/geosite.dat" && -s "$XRAY_ASSET/geoip.dat" ]] \
        && [[ "$XRAY_ASSET/geosite.dat" -nt "$XRAY_BIN" ]]; then
        ok "geodata 已与核心 v$ver 同源（geosite $(( $(stat -c%s "$XRAY_ASSET/geosite.dat") / 1024 )) KB），跳过；--force 可强制重下"
        return 0
    fi

    # 整包 16.7 MB + 解出 11 MB，还要余量写 .new。不足就别下，旧文件继续用。
    disk_need 45 "更新 geodata（约 28 MB）" || die "已中止：现有 geo 数据继续生效"
    geodata_install_official "$ver"
    ok "Geodata 更新完成（官方版，Xray $ver）"
}

update_config() {
    need_root
    # 服务端本来就该开 BBR：每次重建配置顺手兜底，实测没生效就重新下发。
    # 安装时显式选了「不开」(BBR_ENABLED=off) 的不会被强行打开。
    bbr_ensure || warn "BBR 未生效，可执行 xhy bbr on 复查。"
    node_rebuild_all
    [[ "$(state_get FIREWALL_MODE off)" != "off" ]] && firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet
    ok "配置已按当前设置重建"
}

update_all() {
    update_script || true
    update_core
    # 核心安装已把官方 dat 一起铺好（zip 自带），这里只兜底「核心没变动 / 数据缺失」。
    update_geodata
    update_config
    self_check
}

self_check() {
    printf '\n========== xray-hy 环境检查 ==========\n'
    platform_summary
    printf '脚本版本 : %s (build %s)\n' "$XHY_VERSION" "$XHY_BUILD"
    printf '脚本路径 : %s\n' "$XHY_SELF"
    local _canonical="${XHY_BINDIR:-/usr/local/bin}/xhy" _layout="单文件直装"
    if [[ -L "$_canonical" ]]; then
        _layout="旧软链（下次运行 xhy 会自动迁移）"
    elif [[ "$(readlink -f "$XHY_SELF" 2>/dev/null || printf '%s' "$XHY_SELF")" != "$(readlink -f "$_canonical" 2>/dev/null || printf '%s' "$_canonical")" ]]; then
        _layout="非规范路径（跑一次 xhy update script 会迁移）"
    fi
    printf '入口布局 : %s\n' "$_layout"
    if [[ -e "${XHY_LEGACY_SELF:-/usr/local/lib/xray-hy/xhy}" ]]; then
        printf '遗留本体 : %s（下次运行 xhy 会自动清理）\n' "${XHY_LEGACY_SELF:-/usr/local/lib/xray-hy/xhy}"
    fi
    printf '配置目录 : %s\n' "$XHY_ETC"
    printf '出口 IPv4: %s\n' "$(public_ip || true)"
    local _ip6; _ip6="$(public_ip6 || true)"
    if [[ -n "$_ip6" ]]; then
        printf '出口 IPv6: %s（REALITY/hy2 客户端可直接用它做双栈连接）\n' "$_ip6"
    else
        printf '出口 IPv6: 无\n'
    fi
    local _free _total _low _bk
    _free="$(disk_free_mb /)"
    _total="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $2+0}')"
    _bk="$(human_kb "$(file_kb "$XHY_BACKUP")")"
    # 阈值按机型自适应：427 MB 的机器满载工作也到不了 200 MB，固定阈值的唯一
    # 后果是用户学会无视这行告警（狼来了）。
    if (( _total > 0 && _total < 1024 )); then _low=80; else _low=200; fi
    printf '磁盘余量 : %s MB / 总 %s MB（根分区；备份目录 %s）\n' "$_free" "$_total" "$_bk"
    if (( _free < _low )); then
        warn "根分区余量不足 ${_low} MB：盘满会让 sshd 写不了会话文件、SSH 直接连不上。先跑 xhy clean"
    fi
    # 事故期的手工定时钩子会按旧策略把 35 MB 二进制搬回来，和当前策略打架。
    if [[ -f "$(legacy_prune_hook)" ]]; then
        warn "发现遗留定时任务 $(legacy_prune_hook)（旧策略会保留 1 份二进制）"
        warn "它已被 xhy clean 取代；跑一次 xhy clean all 会自动停用它（原地改名，留一条 mv 回滚）"
    fi
    printf '%s\n' "--------------------------------------"
    core_status
    local inst mptcp v6rules
    inst="$(xray_installed_version)"
    if [[ "$inst" == [0-9]* ]]; then
        if version_lt "v$inst" "$XHY_MPTCP_FIXED_VERSION"; then
            printf 'MPTCP 修复: 未包含 (v%s < %s)，依赖内核缓解\n' "$inst" "$XHY_MPTCP_FIXED_VERSION"
        else
            printf 'MPTCP 修复: 已包含\n'
        fi
        if ! version_lt "v$inst" "$XHY_PQ_BREAK_VERSION"; then
            warn "当前 v$inst >= $XHY_PQ_BREAK_VERSION：sing-box / mihomo 客户端可能无法连接 REALITY (#4520)"
        else
            printf '客户端兼容: OK (v%s < %s)\n' "$inst" "$XHY_PQ_BREAK_VERSION"
        fi
    fi
    mptcp="$(sysctl -n net.mptcp.enabled 2>/dev/null || echo '内核未暴露')"
    printf '内核 MPTCP: %s (应为 0)\n' "$mptcp"
    if [[ "$mptcp" == "1" ]]; then
        warn "MPTCP 已启用，请执行 xhy bbr on 关闭它（钉死旧版时的关键缓解）"
    fi
    printf '%s\n' "--------------------------------------"
    bbr_status
    printf '%s\n' "--------------------------------------"
    printf 'access日志: %s\n' "$(state_get ACCESS_LOG 'off')"
    printf 'bufferSize: %s KB\n' "$(state_get BUFFER_SIZE 512)"
    printf '端口范围  : %s\n' "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo '?')"
    # v1.4.3 起 TFO 跟随伪装站（--tfo auto|on|off）；显示现网节点的实际判定，
    # 不再摆一个永远为 0 的「命中数」，也不再写「固定、无开关」那种过时文案。
    local _f _tfo_on=0 _tfo_off=0
    for _f in "$XHY_NODES"/*.env; do
        [[ -f "$_f" ]] || continue
        if grep -q '^TFO=1$' "$_f" 2>/dev/null; then
            _tfo_on=$(( _tfo_on + 1 ))
        else
            _tfo_off=$(( _tfo_off + 1 ))
        fi
    done
    printf 'TFO       : 跟随伪装站（开 %d / 关 %d；--tfo auto|on|off 可覆盖）\n' "$_tfo_on" "$_tfo_off"
    # 探测能力与「节点开没开」是两件事：本机客户端位没开 / 缺 nstat 时，
    # --require-tfo 会把全部候选判成「不支持」，看起来像"全网没人开 TFO"。
    if tfo_probe_ready; then
        printf 'TFO 探测  : 可用（curl --tcp-fastopen + nstat + 客户端位已开）\n'
    else
        printf 'TFO 探测  : 不可用（%s）—— --require-tfo 会恒为空\n' "$(tfo_probe_blocker)"
    fi
    # v1.4.2：tcpcongestion 按内核能力决定写不写，无 bbr 时该字段根本不出现。
    # 这里显示的是**实际渲染结果**而不是"应该是什么"，排查时少一层猜测。
    if sockopt_cc_available; then
        printf 'sockopt   : keepAliveIdle=45 uto=10000 cc=bbr（内核可用）\n'
    else
        printf 'sockopt   : keepAliveIdle=45 uto=10000 cc=继承（内核无 bbr，字段省略）\n'
    fi
    # 中继（relay）只在配置过时才占一行，避免每台机器都多一行噪音
    if [[ -f "$XHY_NODES/relay.env" ]] && declare -F relay_status >/dev/null 2>&1; then
        relay_status --brief
    fi
    printf '%s\n' "--------------------------------------"
    firewall_status --brief
    if have_cmd ip6tables; then
        v6rules="$(ip6tables -S 2>/dev/null | grep -c "$FW_CHAIN" || true)"
        printf 'IPv6 链规则: %s 条\n' "${v6rules:-0}"
        if [[ "${v6rules:-0}" == "0" ]]; then
            warn "IPv6 未受保护，SSH 可能绕过防爆破"
        fi
    else
        warn "未安装 ip6tables，IPv6 未受保护"
    fi
    printf '%s\n' "--------------------------------------"
    if [[ -x "$SCANNER_BIN" ]]; then
        printf '扫描器   : %s\n' "$SCANNER_BIN"
    else
        printf '扫描器   : 未安装（首次 xhy scan / add --scan 自动下载）\n'
    fi
    target_show
    printf '节点数量 : %s\n' "$(node_count)"
    printf '配置快照 : %s 份 (xhy snapshots / xhy rollback)\n' \
        "$(ls -1 "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
    printf '%s\n' "--------------------------------------"
    if [[ -s "$XHY_ETC/config.json" ]] && [[ -x "$XRAY_BIN" ]]; then
        if xray_config_test >/dev/null 2>&1; then ok "配置语法: 通过"; else err "配置语法: 失败"; fi
    else
        warn "尚未安装或未生成配置"
    fi
    if svc_active "$SVC_XRAY" 2>/dev/null; then ok "Xray 服务: 运行中"; else warn "Xray 服务: 未运行"; fi
    if [[ -x "$CF_BIN" ]] && svc_active "$SVC_CF" 2>/dev/null; then ok "CF Tunnel: 运行中"; fi
    printf '======================================\n\n'
}

# Pre-install checklist, modelled on the environment gates used by ArgoX /
# xray-agent. Read-only; safe to run on a live server.
preflight_check() {
    printf '\n========== xray-hy 安装前预检（只读） ==========\n'
    local kver major minor patch min_patch="" mem_kb disk_kb m r c p
    if (( $(id -u) == 0 )); then printf '  [正常] root 权限\n'; else printf '  [问题] 需要 root 权限\n'; fi
    printf '  [信息] 发行版 %s %s / init %s / 架构 %s\n' \
        "$XHY_DISTRO" "$XHY_DISTRO_VER" "$XHY_INIT" "$XHY_ARCH"

    mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    disk_kb="$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}' || true)"
    local total_kb need_mb
    total_kb="$(df -Pk / 2>/dev/null | awk 'NR==2{print $2}' || true)"
    # 安装本身（xray 36 MB + geodata 30 MB + 包缓存）约需 90 MB 余量。
    # 阈值不再写死 300 MB：427 MB 的机器永远到不了那个数，结果是常年「问题」，
    # 用户学会无视预检 —— 比没有预检更糟。
    if (( ${total_kb:-0} > 0 && ${total_kb:-0} < 1048576 )); then need_mb=90; else need_mb=300; fi
    if (( mem_kb < 131072 )); then
        printf '  [注意] 内存 %s MB 偏小，安装时会设置 GOMEMLIMIT\n' "$((mem_kb / 1024))"
    else
        printf '  [正常] 内存 %s MB\n' "$((mem_kb / 1024))"
    fi
    if (( ${disk_kb:-0} < need_mb * 1024 )); then
        printf '  [问题] 可用磁盘 %s MB，安装至少需要 %s MB\n' "$(( ${disk_kb:-0} / 1024 ))" "$need_mb"
    else
        printf '  [正常] 可用磁盘 %s MB（本机需 %s MB）\n' "$((disk_kb / 1024))" "$need_mb"
    fi

    kver="$(uname -r)"; kver="${kver%%-*}"
    IFS=. read -r major minor patch <<<"$kver"
    patch="${patch%%[^0-9]*}"
    case "${major}.${minor}" in
        5.10) min_patch=272 ;; 5.15) min_patch=223 ;; 6.1)  min_patch=190 ;;
        6.6)  min_patch=159 ;; 6.12) min_patch=113 ;; 6.18) min_patch=56 ;;
        7.2)  min_patch=10  ;;
    esac
    if [[ -n "$min_patch" ]]; then
        if (( ${patch:-0} >= min_patch )); then
            printf '  [正常] 内核 %s 已包含 CVE-2026-98432 修复 (>= %s.%s.%s)\n' \
                "$kver" "$major" "$minor" "$min_patch"
        else
            printf '  [问题] 内核 %s 低于修复线 %s.%s.%s，请更新内核并重启\n' \
                "$kver" "$major" "$minor" "$min_patch"
        fi
    else
        printf '  [注意] 内核 %s 不在已知分支映射内，请自行核对 CVE-2026-98432\n' "$kver"
    fi
    m="$(sysctl -n net.mptcp.enabled 2>/dev/null || echo NA)"
    r="$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null || echo NA)"
    if [[ "$m" == "0" && "$r" == "0" ]]; then
        printf '  [正常] MPTCP / tcp_migrate_req 均已关闭\n'
    else
        printf '  [注意] MPTCP=%s migrate_req=%s，建议执行 xhy bbr on\n' "$m" "$r"
    fi

    for c in bash curl openssl iptables unzip; do
        if have_cmd "$c"; then printf '  [正常] 依赖 %s\n' "$c"; else printf '  [注意] 缺少 %s（install 会尝试安装）\n' "$c"; fi
    done
    if curl -fsS -m 8 -o /dev/null https://github.com 2>/dev/null; then
        printf '  [正常] GitHub 可达\n'
    else
        printf '  [问题] GitHub 不可达，Xray / cloudflared 下载会失败\n'
    fi
    for p in 443 8443 8080 10086; do
        if port_busy "$p"; then printf '  [注意] 端口 %s 已被占用\n' "$p"; fi
    done
    if [[ -r /proc/net/if_inet6 ]]; then
        printf '  [信息] IPv6 协议栈可用（可选 DUAL_STACK=on）\n'
    else
        printf '  [信息] IPv6 未启用，DUAL_STACK 请保持 off\n'
    fi
    if [[ -x "$XRAY_BIN" ]]; then
        printf '  [信息] 已装 Xray %s\n' "$(xray_installed_version)"
    else
        printf '  [信息] Xray 未安装，install 将下载 %s\n' "$(xray_resolve_version)"
    fi
    printf '==============================================\n\n'
}
