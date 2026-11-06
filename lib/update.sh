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
    local ver
    ver="$(xray_resolve_version)"
    info "版本通道 $(xray_channel) -> 目标 $ver"
    xray_install "$ver"
    if [[ -s "$XHY_ETC/config.json" ]]; then
        xray_config_test || die "新版本与现有配置不兼容，请检查 $XHY_ETC/config.json 后重试"
        config_reload
    fi
}

update_geodata() {
    need_root
    local f
    install -d -m 0755 "$XRAY_ASSET"
    for f in geoip.dat geosite.dat; do
        info "更新 $f"
        if fetch "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" "$XRAY_ASSET/$f.new"; then
            [[ -s "$XRAY_ASSET/$f.new" ]] || { warn "$f 下载为空，保留旧文件"; rm -f "$XRAY_ASSET/$f.new"; continue; }
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
    printf '%s\n' "--------------------------------------"
    bbr_status
    printf '%s\n' "--------------------------------------"
    firewall_status | head -4
    printf '%s\n' "--------------------------------------"
    target_show
    printf '节点数量 : %s\n' "$(node_count)"
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
