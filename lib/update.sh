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
    newbuild="$(sed -n 's/^XHY_BUILD="\(.*\)"$/\1/p' "$tmp" | head -1)"
    if [[ -z "$newbuild" ]]; then
        rm -f "$tmp"
        die "下载的脚本里找不到构建号，可能不是本项目的 install.sh，已放弃"
    fi
    if [[ "$newbuild" == "$XHY_BUILD" ]]; then
        rm -f "$tmp"
        ok "脚本已是最新 ($XHY_VERSION build $newbuild)"
        return 0
    fi
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
    elif ! confirm "替换 $XHY_SELF 为这个构建？配置与节点数据不受影响。" "y"; then
        rm -f "$tmp"
        info "已取消"
        return 0
    fi
    backup_file "$XHY_SELF"
    if ! install -m 0755 "$tmp" "$XHY_SELF.new" || ! mv -f "$XHY_SELF.new" "$XHY_SELF"; then
        rm -f "$tmp" "$XHY_SELF.new"
        die "替换失败，旧版本仍在 $XHY_SELF"
    fi
    rm -f "$tmp"
    ok "已更新到 build $newbuild；当前进程仍是旧版，下次执行 xhy 生效"
}

update_core() {
    need_root
    init_dirs
    local ver rollback=""
    ver="$(xray_resolve_version)"
    info "版本通道 $(xray_channel) -> 目标 $ver"
    # Keep the working binary so an incompatible new core can be rolled back
    # automatically (idea borrowed from easyxray's version switch).
    if [[ -x "$XRAY_BIN" ]]; then
        rollback="$(mktemp "$XHY_BACKUP/xray-rollback.XXXXXX" 2>/dev/null || true)"
        if [[ -n "$rollback" ]] && cp -a "$XRAY_BIN" "$rollback"; then :; else rollback=""; fi
    fi
    xray_install "$ver"
    if [[ -s "$XHY_ETC/config.json" ]] && ! xray_config_test >/dev/null 2>&1; then
        if [[ -n "$rollback" ]]; then
            cp -a "$rollback" "$XRAY_BIN"
            err "新版本 $ver 无法加载现有配置，已自动回滚到原二进制。"
        fi
        die "请检查 $XHY_ETC/config.json，或改用兼容版本"
    fi
    if [[ -s "$XHY_ETC/config.json" ]]; then config_reload; fi
    [[ -n "$rollback" ]] && rm -f "$rollback"
    ok "Xray 更新完成: $("$XRAY_BIN" version 2>/dev/null | head -1)"
}

update_geodata() {
    need_root
    local f
    install -d -m 0755 "$XRAY_ASSET"
    for f in geoip.dat geosite.dat; do
        info "更新 $f"
        if fetch "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" "$XRAY_ASSET/$f.new"; then
            local sz
            sz="$(stat -c%s "$XRAY_ASSET/$f.new" 2>/dev/null || echo 0)"
            if (( sz < 102400 )); then
                warn "$f 下载内容异常 (${sz} bytes)，保留旧文件"
                rm -f "$XRAY_ASSET/$f.new"
                continue
            fi
            backup_file "$XRAY_ASSET/$f"
            mv "$XRAY_ASSET/$f.new" "$XRAY_ASSET/$f"
            chmod 0644 "$XRAY_ASSET/$f"
        else
            rm -f "$XRAY_ASSET/$f.new"
            warn "$f 更新失败，保留旧文件"
        fi
    done
    ok "Geodata 更新完成"
}

update_config() {
    need_root
    node_rebuild_all
    [[ "$(state_get FIREWALL_MODE off)" != "off" ]] && firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet
    ok "配置已按当前设置重建"
}

update_all() {
    update_script || true
    update_core
    update_geodata
    update_config
    self_check
}

self_check() {
    printf '\n========== xray-hy 环境检查 ==========\n'
    platform_summary
    printf '脚本版本 : %s (build %s)\n' "$XHY_VERSION" "$XHY_BUILD"
    printf '脚本路径 : %s\n' "$XHY_SELF"
    printf '配置目录 : %s\n' "$XHY_ETC"
    printf '出口 IPv4: %s\n' "$(public_ip || true)"
    local _ip6; _ip6="$(public_ip6 || true)"
    if [[ -n "$_ip6" ]]; then
        printf '出口 IPv6: %s（REALITY/hy2 客户端可直接用它做双栈连接）\n' "$_ip6"
    else
        printf '出口 IPv6: 无\n'
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
    [[ "$mptcp" == "1" ]] && warn "MPTCP 已启用，请执行 xhy bbr on 关闭它（钉死旧版时的关键缓解）"
    printf '%s\n' "--------------------------------------"
    bbr_status
    printf '%s\n' "--------------------------------------"
    firewall_status | head -4
    if have_cmd ip6tables; then
        v6rules="$(ip6tables -S 2>/dev/null | grep -c "$FW_CHAIN" || true)"
        printf 'IPv6 链规则: %s 条\n' "${v6rules:-0}"
        [[ "${v6rules:-0}" == "0" ]] && warn "IPv6 未受保护，SSH 可能绕过防爆破"
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
    if (( mem_kb < 131072 )); then
        printf '  [注意] 内存 %s MB 偏小，安装时会设置 GOMEMLIMIT\n' "$((mem_kb / 1024))"
    else
        printf '  [正常] 内存 %s MB\n' "$((mem_kb / 1024))"
    fi
    if (( ${disk_kb:-0} < 307200 )); then
        printf '  [问题] 可用磁盘不足 300 MB\n'
    else
        printf '  [正常] 可用磁盘 %s MB\n' "$((disk_kb / 1024))"
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
