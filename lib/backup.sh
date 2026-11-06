#!/usr/bin/env bash
# xray-hy / backup & restore of script-managed state, with a per-file SHA256
# manifest. 借鉴 idleleo 的「备份带完整性清单、恢复先校验、失败可回滚」。
#
# 备份范围：/etc/xray-hy 下的运行数据 —— config.json、confs/*.json、
# nodes/*.env、certs/、state.env、target 自定义等；**排除** snapshots/ 与
# backups/（历史与备份自身，避免递归与体积膨胀）。Xray 二进制与 geodata
# 不入包：可按版本通道重新下载，备份里只记录版本号便于核对。
#
# 归档结构：
#   payload/          /etc/xray-hy 的内容快照
#   manifest.tsv      meta 行 + 每文件 "sha256<TAB>size<TAB>相对路径"

_backup_meta() {
    printf 'meta\tscript-version\t%s\n' "$XHY_VERSION"
    printf 'meta\tscript-build\t%s\n' "$XHY_BUILD"
    printf 'meta\tcreated\t%s\n' "$1"
    printf 'meta\txray\t%s\n' "$(xray_installed_version 2>/dev/null || true)"
}

backup_create() {
    local out=""
    while (($#)); do
        case "$1" in
            --out) out="${2:?--out 需要路径}"; shift 2 ;;
            *) die "backup 的参数只有 --out，收到: $1" ;;
        esac
    done
    need_root
    init_dirs
    local ts stage f cnt=0
    ts="$(date +%Y%m%d-%H%M%S)"
    [[ -n "$out" ]] || out="$XHY_BACKUP/xhy-backup-$ts.tar.gz"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/xhy-bak.XXXXXX")"
    mkdir -p "$stage/payload"
    if [[ -d "$XHY_ETC" ]]; then
        cp -a "$XHY_ETC/." "$stage/payload/"
    else
        die "$XHY_ETC 不存在：还没有可备份的数据（先 install）"
    fi
    rm -rf "$stage/payload/snapshots" "$stage/payload/backups"
    {
        printf '# xray-hy backup manifest v1\n'
        _backup_meta "$ts"
        # busybox find 没有 -printf，用相对路径逐行处理
        ( cd "$stage/payload" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) \
            | while IFS= read -r f; do
                printf '%s\t%s\t%s\n' \
                    "$(sha256sum "$stage/payload/$f" | awk '{print $1}')" \
                    "$(wc -c <"$stage/payload/$f")" \
                    "$f"
            done
    } >"$stage/manifest.tsv"
    cnt="$(grep -c $'^[0-9a-f]\{64\}\t' "$stage/manifest.tsv" || true)"
    if ! tar -C "$stage" -czf "$out" payload manifest.tsv; then
        rm -rf "$stage"
        die "打包失败: $out"
    fi
    rm -rf "$stage"
    chmod 0600 "$out"
    ok "备份完成: $out"
    printf '  文件数: %s   大小: %s 字节\n' "$cnt" "$(wc -c <"$out")"
    printf '  %s\n' "提示：备份含全部节点凭证与证书私钥，请按敏感文件保管。"
}

backup_restore() {
    local arc="${1:-}"
    [[ -n "$arc" ]] || die "用法: xhy restore <备份文件.tar.gz>"
    [[ -f "$arc" ]] || die "备份文件不存在: $arc"
    need_root
    init_dirs
    local stage bad=0 total=0 sum size f
    stage="$(mktemp -d "${TMPDIR:-/tmp}/xhy-rst.XXXXXX")"
    if ! tar -xzf "$arc" -C "$stage"; then
        rm -rf "$stage"
        die "解包失败：文件损坏或不是 tar.gz"
    fi
    [[ -d "$stage/payload" && -f "$stage/manifest.tsv" ]] \
        || { rm -rf "$stage"; die "不是 xray-hy 备份（缺 payload/manifest.tsv）"; }

    # 1) 完整性校验 —— 任何一项不过就整体放弃，绝不部分还原。
    while IFS=$'\t' read -r sum size f; do
        [[ "$sum" == "meta" || "$f" == "relative-path" ]] && continue
        case "$sum" in '#'*) continue ;; esac
        total=$((total + 1))
        if [[ ! -f "$stage/payload/$f" ]] \
           || [[ "$(sha256sum "$stage/payload/$f" 2>/dev/null | awk '{print $1}')" != "$sum" ]]; then
            warn "校验失败: $f"
            bad=1
        fi
    done <"$stage/manifest.tsv"
    if (( bad )); then
        rm -rf "$stage"
        die "备份完整性校验未通过（$total 项中存在损坏），已放弃还原，目标机未做任何改动"
    fi
    ok "清单校验通过: $total 个文件"
    grep '^meta' "$stage/manifest.tsv" | sed 's/^meta\t/  /'

    # 2) 确认 + 现状留底
    local pre="$XHY_BACKUP/pre-restore-$(date +%Y%m%d-%H%M%S)"
    if [[ -d "$XHY_ETC" ]] && [[ -n "$(ls -A "$XHY_ETC" 2>/dev/null || true)" ]]; then
        mkdir -p "$pre"
        cp -a "$XHY_ETC/." "$pre/"
        info "还原前现状已留底: $pre"
    fi
    if ! confirm "用这份备份覆盖 $XHY_ETC？（备份里没有的 nodes/confs 条目会被删除，保持与备份一致）" "n"; then
        rm -rf "$stage"
        info "已取消"
        return 0
    fi

    # 3) 清掉会与备份产生歧义的内容，再整体拷入。
    rm -rf "$XHY_ETC/confs" "$XHY_ETC/nodes" "$XHY_ETC/certs"
    rm -f "$XHY_ETC/state.env" "$XHY_ETC/config.json"
    cp -a "$stage/payload/." "$XHY_ETC/"
    rm -rf "$stage"                                         # 配置一律从 nodes 重建：
    rm -rf "$XHY_ETC/confs" "$XHY_ETC/config.json"          # confs/ 与 config.json 不沿用备份
    chmod 0700 "$XHY_ETC/nodes" "$XHY_ETC/certs" 2>/dev/null || true
    chmod 0600 "$XHY_ETC/state.env" 2>/dev/null || true

    # 4) 新机器没有 Xray：数据已还原，指引装核心后再起服务。
    if [[ ! -x "$XRAY_BIN" ]]; then
        warn "本机还没有 Xray。数据已还原，接下来: xhy core update 安装核心，再 xhy service start"
        return 0
    fi

    # 5) 从 nodes 重建配置并验证；失败整体回滚到留底。
    local frag
    if ! ( for frag in "$XHY_NODES"/*.env; do
              [[ -f "$frag" ]] || continue
              write_fragment "$frag" || exit 1
          done && rebuild_config && xray_config_test ); then
        err "还原后的配置重建/校验失败，回滚到还原前状态"
        rm -rf "$XHY_ETC/confs" "$XHY_ETC/nodes" "$XHY_ETC/certs"
        rm -f "$XHY_ETC/state.env" "$XHY_ETC/config.json"
        cp -a "$pre/." "$XHY_ETC/"
        die "已回滚。备份清单是完整的，问题多半在目标机环境（版本/端口冲突），看上面的报错"
    fi
    config_reload || warn "配置已写入，但服务重启失败（尚未 install？可 xhy service start 手动起）"
    ok "还原完成（配置已按 nodes 重建并通过 xray -test）"
}
