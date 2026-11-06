#!/usr/bin/env bash
# xray-hy / script, core, geodata and configuration updates.

# The project is installed as a real git worktree. Updating means a fast-forward
# pull of *local* files that you can diff first -- never `curl | bash` at runtime.
update_script() {
    local wd="$XHY_SCRIPT_DIR"
    if [[ ! -d "$wd/.git" ]]; then
        warn "$wd 不是 git 工作树，跳过脚本自更新（请手动替换文件或重新 clone）。"
        return 1
    fi
    need_root
    info "当前版本: $XHY_VERSION  commit: $(git -C "$wd" rev-parse --short HEAD 2>/dev/null || echo '?')"
    if ! git -C "$wd" remote | grep -q .; then
        warn "未配置 git remote，无法拉取更新。"
        return 1
    fi
    git -C "$wd" fetch --quiet || { warn "fetch 失败，检查网络或 remote 配置"; return 1; }
    local behind
    behind="$(git -C "$wd" rev-list --count HEAD..@{u} 2>/dev/null || echo 0)"
    if [[ "$behind" == "0" ]]; then
        ok "脚本已是最新"
        return 0
    fi
    info "远端有 $behind 个新提交："
    git -C "$wd" --no-pager log --oneline HEAD..@{u} | head -20
    git -C "$wd" --no-pager diff --stat HEAD..@{u}
    confirm "应用这些更新（仅快进，不改动 /etc/xray-hy 配置）？" "y" || { info "已取消"; return 0; }
    git -C "$wd" pull --ff-only --quiet || die "pull 失败（本地有改动？请先 git -C $wd status 查看）"
    create_symlink
    ok "脚本已更新，配置与节点数据保持不变"
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
    printf '脚本版本 : %s\n' "$XHY_VERSION"
    printf '脚本目录 : %s\n' "$XHY_SCRIPT_DIR"
    printf '配置目录 : %s\n' "$XHY_ETC"
    printf '%s\n' "--------------------------------------"
    core_status
    local inst mptcp v6rules
    inst="$(xray_installed_version)"
    if [[ "$inst" == [0-9]* ]] && version_lt "v$inst" "$XHY_MIN_SAFE_VERSION"; then
        warn "Xray $inst 低于安全版本 $XHY_MIN_SAFE_VERSION (MPTCP / CVE-2026-98432)，请执行 xhy core update"
    fi
    mptcp="$(sysctl -n net.mptcp.enabled 2>/dev/null || echo '内核未暴露')"
    printf 'MPTCP    : %s (应为 0)\n' "$mptcp"
    [[ "$mptcp" == "1" ]] && warn "MPTCP 已启用，建议 xhy bbr on 关闭它"
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
    target_show
    printf '节点数量 : %s\n' "$(node_count)"
    printf '配置快照 : %s 份 (xhy snapshots / xhy rollback)\n' \
        "$(ls -1 "$XHY_SNAPSHOTS"/config.*.json 2>/dev/null | wc -l)"
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
