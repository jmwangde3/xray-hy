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
    # 备份只打包配置（config.json / nodes / confs / certs / state.env），
    # 二进制与 geoip/geosite 不入档 —— 它们能重新下载，且 65 MB 在小盘上是灾难。
    disk_need 15 "打包配置备份" || die "已中止：先腾出空间再备份"
    local ts stage f archive_tmp cnt=0
    ts="$(date +%Y%m%d-%H%M%S)"
    [[ -n "$out" ]] || out="$XHY_BACKUP/xhy-backup-$ts-${BASHPID}.tar.gz"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/xhy-bak.XXXXXX")"
    mkdir -p "$stage/payload"
    for f in confs nodes certs config.json state.env tunnel.token target.env scan-cache.tsv; do
        [[ -e "$XHY_ETC/$f" ]] || continue
        cp -a "$XHY_ETC/$f" "$stage/payload/" || { rm -rf "$stage"; return 1; }
    done
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
    archive_tmp="$(mktemp "$out.tmp.XXXXXX")" || { rm -rf "$stage"; return 1; }
    if ! tar -C "$stage" -czf "$archive_tmp" payload manifest.tsv ||
       ! chmod 0600 "$archive_tmp" || ! mv -f "$archive_tmp" "$out"; then
        rm -rf "$stage"
        rm -f "$archive_tmp"
        die "打包失败: $out"
    fi
    rm -rf "$stage"
    ok "备份完成: $out"
    printf '  文件数: %s   大小: %s 字节\n' "$cnt" "$(wc -c <"$out")"
    printf '  %s\n' "提示：备份含全部节点凭证与证书私钥，请按敏感文件保管。"
}

# Validate before extracting: only regular files and directories within the
# backup layout, no symlinks/hardlinks, absolute paths or traversal.
backup_archive_safe() {
    local arc="$1" stage="$2" member
    tar -tzf "$arc" >"$stage/members" &&
        tar -tvzf "$arc" >"$stage/types" || return 1
    if grep -qvE '^[-d]' "$stage/types"; then return 1; fi
    while IFS= read -r member; do
        [[ "$member" =~ ^[A-Za-z0-9_./+-]+$ && "/$member/" != */../* && "/$member/" != */./* ]] || return 1
        case "$member" in
            manifest.tsv|payload/|payload/confs/|payload/nodes/|payload/certs/|payload/confs/*|payload/nodes/*|payload/certs/*|payload/config.json|payload/state.env|payload/tunnel.token|payload/target.env|payload/scan-cache.tsv|payload/.lock|payload/.lock.d/) ;;
            *) return 1 ;;
        esac
    done <"$stage/members"
    [[ -z "$(LC_ALL=C sort "$stage/members" | uniq -d)" ]]
}

backup_restore() (
    local arc="${1:-}" stage sum size f total=0
    [[ -f "$arc" ]] || die "用法: xhy restore <备份文件.tar.gz>"
    need_root
    stage="$(mktemp -d "${TMPDIR:-/tmp}/xhy-rst.XXXXXX")" || return 1
    trap 'rm -rf "$stage"' EXIT
    backup_archive_safe "$arc" "$stage" || die "备份含有不支持或不安全的条目"
    tar -xzf "$arc" -C "$stage" || die "解包失败"
    [[ -d "$stage/payload" && -f "$stage/manifest.tsv" ]] || die "缺少备份清单或 payload"
    local -A seen=()
    while IFS=$'\t' read -r sum size f; do
        case "$sum" in \#*|meta) continue ;; esac
        [[ "$sum" =~ ^[0-9a-f]{64}$ && "$size" =~ ^[0-9]+$ && "$f" =~ ^[A-Za-z0-9_./+-]+$ &&
           "$f" != /* && "/$f/" != */../* && "/$f/" != */./* ]] || die "备份清单格式错误"
        [[ ! "${seen[$f]+yes}" && -f "$stage/payload/$f" ]] || die "备份清单缺失或重复: $f"
        [[ "$(sha256_file "$stage/payload/$f")" == "$sum" &&
           "$(wc -c <"$stage/payload/$f" | tr -d '[:space:]')" == "$size" ]] || die "备份校验失败: $f"
        seen["$f"]=1
        total=$(( total + 1 ))
    done <"$stage/manifest.tsv"
    (( total > 0 )) || die "备份清单为空"
    while IFS= read -r f; do
        [[ "${seen[$f]+yes}" ]] || die "备份有未列入清单的文件: $f"
    done < <(cd "$stage/payload" && find . -type f | sed 's|^\./||')
    ok "清单校验通过: $total 个文件"
    confirm "用这份备份覆盖 $XHY_ETC？" "n" || { info "已取消"; return 0; }
    config_transaction _backup_restore_apply "$stage/payload"
)

_backup_restore_apply() {
    local payload="$1" f
    # Retain an independent copy for manual recovery after a successful restore.
    backup_create || return 1
    for f in confs nodes certs state.env tunnel.token target.env scan-cache.tsv; do
        rm -rf "$XHY_ETC/$f" || return 1
        [[ -e "$payload/$f" ]] || continue
        # Generated fragments are rebuilt from the registry, including relay.
        [[ "$f" == confs ]] && continue
        cp -a "$payload/$f" "$XHY_ETC/" || return 1
    done
    init_dirs || return 1
    if [[ ! -x "$XRAY_BIN" ]]; then
        rm -f "$XHY_ETC/config.json" || return 1
        warn "数据已恢复；先安装 Xray，再执行 xhy update config"
        return 0
    fi
    XHY_SKIP_SNAPSHOT=1 node_rebuild_all || return 1
    if [[ "$(state_get FIREWALL_MODE off)" != off ]]; then
        firewall_apply "$(state_get FIREWALL_MODE safe)" --quiet || return 1
    fi
    ok "还原完成（配置已按节点与中继状态重建）"
}

# ---------------------------------------------------------------------------
# xhy clean — 小盘 VPS 的救命命令
# ---------------------------------------------------------------------------
# 根分区 400-500 MB 的机型（阿里云/腾讯云的入门配置很常见）最容易被这里塞满：
# 切一次 `xhy core channel` 就多一个 ~30 MB 的旧二进制副本，再叠加手工备份，
# 盘一满 sshd 就写不了会话文件 —— 症状是「SSH 突然连不上、但代理还能用」。
# 只保留最近若干份，其余删除。

# 删除一组文件，逐个报体积，并把「删了几个 / 释放多少」累加到 _CLEAN_N / _CLEAN_KB。
# 为什么不拿 df 前后相减：df 粒度 1 MB，删掉零星零字节残留会显示「释放 0 MB」，
# 看上去像什么都没删（v1.6.1 在 47.88.102.45 上就报过这个数）。
# 一组文件合计多少 KB（不删除，只统计）。
_clean_sum() {
    local f total=0
    for f in "$@"; do
        [[ -e "$f" ]] || continue
        total=$(( total + $(file_kb "$f") ))
    done
    printf '%s' "$total"
}

_clean_drop() {
    local label="$1"; shift
    local f kb total=0 cnt=0
    for f in "$@"; do
        [[ -e "$f" ]] || continue
        kb="$(file_kb "$f")"
        if rm -rf "$f" 2>/dev/null; then
            total=$(( total + kb )); cnt=$(( cnt + 1 ))
            printf '  - %-40s %s\n' "$(basename "$f")" "$(human_kb "$kb")"
        else
            warn "删除失败（仍在占用？）：$f"
        fi
    done
    _CLEAN_N=$(( _CLEAN_N + cnt ))
    _CLEAN_KB=$(( _CLEAN_KB + total ))
    (( cnt > 0 )) && ok "删除${label} $cnt 个，释放 $(human_kb "$total")"
    return 0
}

# 11-07 事故当晚手工装的 /etc/periodic/daily/xhy-backup-prune 已被 xhy clean 取代。
# 它的保留策略是「二进制留 1 份」，与新策略（默认 0 份）直接冲突 —— 留着会让
# 35 MB 的旧二进制永远爬回来。移进 /root 而不是删除，留一条回头路。
_clean_legacy_hook() {
    local h dst
    h="$(legacy_prune_hook)"
    [[ -f "$h" ]] || return 0
    # 就放在原地改名：run-parts 会跳过含 '.' 的条目，它从此不会再被执行，
    # 想回滚只需 mv 回去（放到 /root 反而要跨目录搬 2 KB）。
    dst="$(dirname "$h")/xhy-backup-prune.retired-$(date +%Y%m%d%H%M%S)"
    if mv "$h" "$dst" 2>/dev/null; then
        ok "摘掉事故期遗留的定时任务 /etc/periodic/daily/xhy-backup-prune（已由 xhy clean 取代）"
        info "如需回滚：mv $dst /etc/periodic/daily/xhy-backup-prune"
    else
        warn "遗留定时任务仍在：$h —— 它会把旧二进制留成 35 MB 常驻，建议手工删"
    fi
    return 0
}

cmd_clean() {
    local what="${1:-all}" keep_bin="${XHY_BACKUP_CORE:-0}" keep_snap=5 keep_bak=20 keep_tar=3 keep_big=2
    local before after f i k p
    local _keep=0
    local -a bins=() rt=() snaps=() baks=() bigs=() tars=() drop=()
    local -A fbseen=()
    need_root
    init_dirs
    _CLEAN_N=0
    _CLEAN_KB=0

    case "$what" in
        all|backups|snapshots|tarballs|tmp) ;;
        *) die "用法：xhy clean [all|backups|snapshots|tarballs|tmp]" ;;
    esac

    before="$(disk_free_mb /)"
    # 清 anything 之前先摘掉过时的定时钩子，免得它半夜把二进制又搬回来。
    [[ "$what" == "all" || "$what" == "backups" ]] && _clean_legacy_hook

    # 二进制备份 = xray-<版本>-<14 位时间戳>。
    # xray-rollback.* 是 update_core 的临时副本，中断时会留零字节文件；它同样匹配
    # xray-*，混在一起排序会让「最新一份」变成 0 字节残留，真正的 30 MB 备份反被删。
    while IFS= read -r f; do
        [[ -e "$f" ]] || continue
        case "$(basename "$f")" in
            xray-rollback.*) rt+=("$f") ;;
            *)               bins+=("$f") ;;
        esac
    done < <(ls -1t "$XHY_BACKUP"/xray-* 2>/dev/null || true)
    while IFS= read -r f; do [[ -e "$f" ]] && snaps+=("$f"); done \
        < <(ls -1t "$XHY_SNAPSHOTS"/state.*.tar.gz 2>/dev/null || true)
    while IFS= read -r f; do
        [[ -e "$f" ]] || continue
        # 大体积 .bak（geoip.dat / geosite.dat 这类十几 MB 的数据文件）单独算：
        # 「.bak 留 20 份」对它们等于永不清理，一次 geodata 更新就留 30 MB。
        # 而它们本来就能重新下载，留最新 2 份足够回退。
        if (( $(file_kb "$f") >= 2048 )); then
            bigs+=("$f")
        else
            baks+=("$f")
        fi
    done < <(ls -1t "$XHY_BACKUP"/*.bak 2>/dev/null || true)
    while IFS= read -r f; do [[ -e "$f" ]] && tars+=("$f"); done \
        < <(ls -1t "$XHY_BACKUP"/xhy-backup-*.tar.gz "$XHY_BACKUP"/pre-restore-* 2>/dev/null || true)

    printf '\n清理前：根分区剩余 %s MB\n' "$before"
    printf '  备份目录 %s / 快照目录 %s\n' \
        "$(human_kb "$(file_kb "$XHY_BACKUP")")" "$(human_kb "$(file_kb "$XHY_SNAPSHOTS")")"
    printf '  二进制备份 %d 个 / 临时副本 %d 个 / 状态快照 %d 个 / 打包备份 %d 个\n' \
        "${#bins[@]}" "${#rt[@]}" "${#snaps[@]}" "${#tars[@]}"
    printf '  .bak 小文件 %d 个 / 大体积 .bak %d 个（%s）\n' \
        "${#baks[@]}" "${#bigs[@]}" "$(human_kb "$(_clean_sum "${bigs[@]}")")"

    # ---- 临时副本：按定义就是可丢的，不看数量 ----
    if [[ "$what" == "tmp" || "$what" == "backups" || "$what" == "all" ]]; then
        if (( ${#rt[@]} > 0 )); then
            _clean_drop "临时副本残留" "${rt[@]}"
        else
            info "没有临时副本残留"
        fi
    fi

    # ---- 二进制备份：留最新 keep_bin 份 ----
    if [[ "$what" == "backups" || "$what" == "all" ]]; then
        drop=()
        for (( i = keep_bin; i < ${#bins[@]}; i++ )); do drop+=("${bins[$i]}"); done
        if (( ${#drop[@]} > 0 )); then
            _clean_drop "旧二进制备份" "${drop[@]}"
        fi
        if (( ${#bins[@]} > 0 )); then
            if (( keep_bin > 0 )); then
                _keep=$(( ${#bins[@]} > keep_bin ? keep_bin : ${#bins[@]} ))
                info "保留 ${_keep} 份二进制备份：$(basename "${bins[0]}")（$(human_kb "$(file_kb "${bins[0]}")")）"
            else
                info "二进制不进备份（可重下）。需要恢复：xhy core channel <版本> && xhy core update"
                info "想留一份保险：XHY_BACKUP_CORE=1 xhy clean"
            fi
        fi
    fi

    # ---- 状态快照：留最新 keep_snap 份（xhy rollback 还要用） ----
    if [[ "$what" == "snapshots" || "$what" == "all" ]]; then
        drop=()
        for (( i = keep_snap; i < ${#snaps[@]}; i++ )); do drop+=("${snaps[$i]}"); done
        if (( ${#drop[@]} > 0 )); then
            _clean_drop "旧状态快照" "${drop[@]}"
            info "保留最新 $keep_snap 份快照，xhy rollback 仍可用"
        else
            info "状态快照 ${#snaps[@]} 个，未超过保留数 $keep_snap"
        fi
    fi

    # ---- 打包备份（xhy backup / 还原前自动备份）：留最新 keep_tar 份 ----
    if [[ "$what" == "tarballs" || "$what" == "all" ]]; then
        drop=()
        for (( i = keep_tar; i < ${#tars[@]}; i++ )); do drop+=("${tars[$i]}"); done
        if (( ${#drop[@]} > 0 )); then
            _clean_drop "旧打包备份" "${drop[@]}"
        fi
        if (( ${#tars[@]} > 0 )); then
            info "保留 $(( ${#tars[@]} > keep_tar ? keep_tar : ${#tars[@]} )) 份打包备份（最新一份 $(human_kb "$(file_kb "${tars[0]}")")）"
        fi
    fi

    # ---- 大体积 .bak：可重下的直接删，其余同名留最新 keep_big 份 ----
    # 47.88.102.45 上 63.8 MB 的备份目录里，29.5 MB 是 geoip.dat / geosite.dat 的旧
    # 副本；它们掉进「.bak 留 20 份」就永远清不掉。既然 v1.7 起 geodata 不再进备份，
    # 这些历史残留就是纯垃圾 —— 现用的 dat 在 /usr/local/share/xray，随时可重下。
    if [[ "$what" == "backups" || "$what" == "all" ]]; then
        drop=()
        for f in "${bigs[@]}"; do
            k="$(basename "$f")"
            k="${k%.bak}"; k="${k%.*}"      # geoip.dat.20261107092534 -> geoip.dat
            if backup_is_redownloadable "$k"; then
                drop+=("$f")                # 可重下的历史副本：一律清掉
                continue
            fi
            fbseen[$k]=$(( ${fbseen[$k]:-0} + 1 ))
            (( ${fbseen[$k]} > keep_big )) && drop+=("$f")
        done
        if (( ${#drop[@]} > 0 )); then
            _clean_drop "大体积数据备份（可重新下载）" "${drop[@]}"
        fi
    fi

    # ---- .bak：留最新 keep_bak 份 ----
    if [[ "$what" == "backups" || "$what" == "all" ]]; then
        drop=()
        for (( i = keep_bak; i < ${#baks[@]}; i++ )); do drop+=("${baks[$i]}"); done
        if (( ${#drop[@]} > 0 )); then
            _clean_drop "旧 .bak" "${drop[@]}"
        else
            info ".bak ${#baks[@]} 个，未超过保留数 $keep_bak"
        fi
    fi

    after="$(disk_free_mb /)"
    printf '\n清理后：根分区剩余 %s MB\n' "$after"
    if (( _CLEAN_N == 0 )); then
        printf '本次没有删除任何文件（都在保留数内）\n'
    else
        printf '本次删除 %d 个文件，合计 %s' "$_CLEAN_N" "$(human_kb "$_CLEAN_KB")"
        if (( after > before )); then
            printf '；df 增加 %d MB\n' "$(( after - before ))"
        else
            printf '；df 未变（删的多是零字节残留，或文件仍被进程占用）\n'
        fi
    fi

    if (( after < 200 )); then
        warn "余量仍不足 200 MB。备份目录里最大的几份："
        du -k "$XHY_BACKUP"/* 2>/dev/null | sort -rn | head -3 | while read -r k p; do
            printf '  %8s  %s\n' "$(human_kb "$k")" "$(basename "$p")"
        done
        warn "还可清：apk/apt 缓存、/var/log 里的旧日志、手工传上来的 tar 包（/root）"
    fi
    return 0
}
