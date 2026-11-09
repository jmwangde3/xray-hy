#!/usr/bin/env bash
# xray-hy / Xray core download, version channels, key generation, cloudflared.

xray_channel() { state_get XRAY_CHANNEL "pinned"; }

# Compare vX.Y.Z without relying on `sort -V` (absent in busybox).
version_num() {
    local v="${1#v}"; v="${v%%-*}"
    local IFS='.' p=()
    read -r -a p <<<"$v"
    printf '%d%03d%03d\n' "${p[0]:-0}" "${p[1]:-0}" "${p[2]:-0}"
}
version_lt() { (( $(version_num "$1") < $(version_num "$2") )); }

xray_set_channel() {
    case "$1" in
        pinned|latest|v[0-9]*) state_set XRAY_CHANNEL "$1" ;;
        *) die "版本通道只能是 pinned / latest / vX.Y.Z，收到: $1" ;;
    esac
    local target mptcp
    target="$(xray_resolve_version)"
    [[ "$target" == v* ]] || { warn "无法确认目标版本，跳过兼容性检查"; return 0; }
    if ! version_lt "$target" "$XHY_PQ_BREAK_VERSION"; then
        warn "兼容性: $target >= $XHY_PQ_BREAK_VERSION，REALITY 服务端会要求 ClientHello 带 X25519MLKEM768。"
        warn "sing-box / mihomo 客户端将报 reality verification failed (SagerNet/sing-box#4520)。"
        warn "若使用这些客户端，请保持 pinned ($XHY_PINNED_VERSION)。"
    fi
    if version_lt "$target" "$XHY_MPTCP_FIXED_VERSION"; then
        mptcp="$(sysctl -n net.mptcp.enabled 2>/dev/null || echo unknown)"
        warn "安全: $target < $XHY_MPTCP_FIXED_VERSION，Xray 默认启用 MPTCP (CVE-2026-98432)。"
        if [[ "$mptcp" == "0" ]]; then
            ok "  已由内核 net.mptcp.enabled=0 缓解（xhy bbr on 可重新设置）。"
        else
            warn "  内核 MPTCP=$mptcp，请执行 xhy bbr on 关闭它。"
        fi
    fi
}

xray_resolve_version() {
    local ch tag=""
    ch="$(xray_channel)"
    case "$ch" in
        pinned)  printf '%s' "$XHY_PINNED_VERSION"; return 0 ;;
        v[0-9]*) printf '%s' "$ch"; return 0 ;;
        latest)  ;;
    esac
    tag="$(curl -fsSL -m 15 "$XHY_RELEASE_API/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    if [[ ! "$tag" =~ ^v[0-9] ]]; then
        warn "无法从 GitHub API 获取最新版本，回退到 $XHY_PINNED_VERSION"
        tag="$XHY_PINNED_VERSION"
    fi
    printf '%s' "$tag"
}

xray_installed_version() {
    [[ -x "$XRAY_BIN" ]] || { printf '未安装'; return; }
    "$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\r' || true
}

# 从官方 Xray release 里取 geodata（v1.14.0 起为可选源，见 geodata_source）。
# 官方**不单独发** dat 资产，只随各平台 zip 一起发 —— 所以只能下整包再解出这两个
# 文件（linux-64 包 16.7 MB，解开后 geosite 7.55 MB + geoip 3.31 MB）。
# 版本取「本机已装核心的版本」而不是 latest：dat 与核心同源，升核心不会悄悄换数据；
# 核心没装时退回 latest。校验和沿用 xray_install 的严格口径（.dgst 必需）。
# geodata 数据源（v1.14.0 起）。拆 protobuf 逐域名实测：Xray 官方 release
# 自带的 dat 是 Loyalsoldier 版的**真子集**，差异全部是「仅 Loyalsoldier 有」——
#   google 少 114 条（notebooklm / antigravity / geminiweb-pa / cloudcode-pa /
#     scholar.google.* 等）、gfw 整个分类缺失（4433 条）、geolocation-!cn
#     少 3819 条、category-ai-!cn 少 2（grokbot.com / Copilot azure host）、
#     anthropic 少 1、xai 少 1、github-copilot 少 1、disney 少 2；
#   官方「多出来」的只有 geolocation-!cn 里 13 条乱码/正则写法差异，实质 0 条。
# 官方版体积差 3.9 MB 全在 category-ads-all（905 vs 199451 条），但换来的代价
# 是 AI / Google / gfw 覆盖不全。默认回到 Loyalsoldier 完整版。
geodata_source() {
    local v="${XHY_GEODATA_SOURCE:-loyalsoldier}"
    [[ "$v" == "loyalsoldier" || "$v" == "official" ]] || v="loyalsoldier"
    printf '%s' "$v"
}

# Stage both assets, then validate the active config against that pair.
# Keep rollback copies via hard links on the same filesystem to save disk.
geodata_publish() (
    local dir="$1" src="$2" f old
    for f in geoip.dat geosite.dat; do
        [[ -s "$dir/$f" ]] || { err "缺少 $f，保留原 geodata"; return 1; }
        chmod 0644 "$dir/$f" || return 1
    done
    if [[ -s "$XHY_ETC/config.json" && -x "$XRAY_BIN" ]]; then
        XRAY_ASSET="$dir" xray_config_test || { err "现有配置无法使用候选 geodata"; return 1; }
    fi
    printf '%s\n' "$src" >"$dir/.geodata-source" || return 1
    old="$dir/previous"
    mkdir -m 0700 "$old" || return 1
    for f in geoip.dat geosite.dat .geodata-source; do
        [[ -e "$XRAY_ASSET/$f" ]] || continue
        ln "$XRAY_ASSET/$f" "$old/$f" || return 1
    done
    # A forced interruption can never leave a stale marker claiming the new pair.
    rm -f "$XRAY_ASSET/.geodata-source" || return 1
    if mv -f "$dir/geoip.dat" "$XRAY_ASSET/geoip.dat" &&
       mv -f "$dir/geosite.dat" "$XRAY_ASSET/geosite.dat" &&
       mv -f "$dir/.geodata-source" "$XRAY_ASSET/.geodata-source"; then return 0; fi
    local failed=0
    for f in geoip.dat geosite.dat; do
        if [[ -e "$old/$f" ]]; then
            mv -f "$old/$f" "$XRAY_ASSET/$f" || failed=1
        else
            rm -f "$XRAY_ASSET/$f" || failed=1
        fi
    done
    if (( ! failed )) && [[ -e "$old/.geodata-source" ]]; then
        mv -f "$old/.geodata-source" "$XRAY_ASSET/.geodata-source" || failed=1
    fi
    if (( failed )); then
        # Move the recovery copies outside the caller's cleanup directory.
        local recover="$XRAY_ASSET/.geodata-recovery.${BASHPID}"
        if mv "$old" "$recover"; then err "geodata 回滚未完成，备份在 $recover"; fi
    fi
    return 1
)

geodata_stage_loyalsoldier() {
    local dir="$1" base f sz expected actual
    base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
    for f in geoip.dat geosite.dat; do
        info "下载 $f（Loyalsoldier 完整版）"
        fetch "$base/$f" "$dir/$f" &&
            fetch "$base/$f.sha256sum" "$dir/$f.sum" || return 1
        sz="$(wc -c <"$dir/$f")" || return 1
        expected="$(awk 'NR==1 {print $1}' "$dir/$f.sum" | tr 'A-F' 'a-f')" || return 1
        actual="$(sha256_file "$dir/$f")" || return 1
        if (( sz < 102400 )) || [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$expected" != "$actual" ]]; then
            err "$f 的大小或 SHA-256 校验失败"
            return 1
        fi
    done
}

geodata_install_loyalsoldier() (
    local dir
    dir="$(mktemp -d "$XRAY_ASSET/.geodata.XXXXXX")" || return 1
    trap 'rm -rf "$dir"' EXIT
    geodata_stage_loyalsoldier "$dir" && geodata_publish "$dir" loyalsoldier
)

geodata_install_official() (
    local ver="${1:-}" asset url dir
    asset="Xray-linux-${XHY_ARCH}.zip"
    case "$ver" in
        ''|latest|未安装) url="${XHY_RELEASE_DL%/download}/latest/download/$asset" ;;
        v*) url="${XHY_RELEASE_DL}/$ver/$asset" ;;
        *) url="${XHY_RELEASE_DL}/v$ver/$asset" ;;
    esac
    dir="$(mktemp -d "$XRAY_ASSET/.geodata.XXXXXX")" || return 1
    trap 'rm -rf "$dir"' EXIT
    fetch "$url" "$dir/$asset" && fetch "$url.dgst" "$dir/$asset.dgst" || return 1
    verify_release_digest "$dir/$asset.dgst" "$dir/$asset" || return 1
    if have_cmd unzip; then
        unzip -o -q "$dir/$asset" -d "$dir" geosite.dat geoip.dat || return 1
    else
        busybox unzip -o -q "$dir/$asset" -d "$dir" geosite.dat geoip.dat || return 1
    fi
    geodata_publish "$dir" official
)

# Download a pinned-or-latest Xray release. The .dgst checksum is MANDATORY:
# unlike most one-key scripts, a missing digest aborts instead of continuing.
#
# 三段式，顺序不能动：
#   ① 写前空间闸门 —— 不够就中止，目标二进制一个字节都不碰
#   ② 在临时目录里先验证新二进制能不能跑
#   ③ 同盘 rename 原子替换（跨盘时 .new + mv）
# 反过来做（先 install 再 version）就是 47.88.102.45 那次事故：0 MB 余量下
# install 先把目标 truncate 掉再写到一半，留下 11 MB 的半截文件，而 version
# 失败被误报成「架构或依赖不匹配」。
xray_install() (
    local ver="$1" asset tmp="" unpack oldver got geo="" src="" candidate
    # 旧二进制不再归档：36 MB 一份，切几次 channel 就是几百 MB，而它能按版本号
    # 重新下载。要留一份保险就显式 XHY_BACKUP_CORE=1（只留最新 1 份）。
    if [[ -x "$XRAY_BIN" && "${XHY_BACKUP_CORE:-0}" == "1" ]]; then
        oldver="$(xray_installed_version)"
        install -d -m 0700 "$XHY_BACKUP"
        cp -a "$XRAY_BIN" "$XHY_BACKUP/xray-${oldver//[^0-9A-Za-z._-]/_}-$(date +%Y%m%d%H%M%S)" 2>/dev/null \
            || warn "旧二进制备份失败（磁盘？），继续安装"
        ls -1t "$XHY_BACKUP"/xray-[0-9]* 2>/dev/null | tail -n +2 | while IFS= read -r f; do rm -f "$f"; done
    fi

    asset="Xray-linux-${XHY_ARCH}.zip"
    tmp="$(mktemp -d)" || die "无法创建临时目录"
    unpack="$tmp/unpack"
    trap '[[ -z "$geo" ]] || rm -rf "$geo"; rm -rf "$tmp"' EXIT

    # ① 写前闸门：36 MB zip + 36 MB 解压后的二进制 + 官方 dat 4 MB +
    # Loyalsoldier dat 约 30 MB + 余量。不足就中止，原文件未动。
    # v1.14.6 起 xray_install 会额外下一份 Loyalsoldier 完整版，峰值比旧版
    # 多约 30 MB；90 MB 的旧闸门对 427 MB 根分区不再够用。
    disk_need 120 "安装 Xray $ver" || die "已中止安装：原二进制未改动"
    install -d -m 0700 "$XHY_BACKUP"

    info "下载 Xray $ver ($asset)"
    fetch "${XHY_RELEASE_DL}/${ver}/${asset}" "$tmp/$asset" \
        || die "Xray 压缩包下载失败（版本 $ver 是否存在？架构 $XHY_ARCH 是否受支持？）"
    fetch "${XHY_RELEASE_DL}/${ver}/${asset}.dgst" "$tmp/$asset.dgst" \
        || die "SHA-256 摘要文件下载失败。出于安全考虑拒绝安装未校验的二进制。"
    verify_release_digest "$tmp/$asset.dgst" "$tmp/$asset" || die "校验失败，已中止。"

    mkdir -p "$unpack" || return 1
    if have_cmd unzip; then
        unzip -o -q "$tmp/$asset" -d "$unpack" || die "解压失败"
    else
        busybox unzip -o -q "$tmp/$asset" -d "$unpack" || die "解压失败"
    fi
    [[ -f "$unpack/xray" ]] || die "压缩包中缺少 xray 二进制"
    chmod 0755 "$unpack/xray" || return 1
    # 解压产物已齐，压缩包与 .dgst 立刻丢弃：36 MB 的 zip 若留到后面
    # 下载 Loyalsoldier dat 时，正是根分区最容易撑满的时刻。
    rm -f "$tmp/$asset" "$tmp/$asset.dgst" || true

    # ② 先在临时目录验证，通过后才碰目标文件
    got="$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$unpack/xray" version 2>/dev/null \
           | head -1 | awk '{print $2}' | tr -d '\r' || true)"
    if [[ -z "$got" ]]; then
        err "下载的二进制无法执行（下载损坏 / 架构 $XHY_ARCH 不符）"
        err "原二进制未改动，当前版本: $(xray_installed_version)"
        die "安装失败"
    fi

    # ③ 原子替换：同一文件系统用 rename（零拷贝、瞬间），跨盘才退化成 .new + mv
    install -d -m 0755 "$(dirname "$XRAY_BIN")" "$XRAY_ASSET" || return 1
    candidate="$XRAY_ASSET"
    if [[ "${XHY_SKIP_GEODATA:-0}" != 1 ]]; then
        src="$(geodata_source)"
        geo="$(mktemp -d "$XRAY_ASSET/.geodata.XXXXXX")" || return 1
        if [[ "$src" == official ]]; then
            mv "$unpack/geoip.dat" "$unpack/geosite.dat" "$geo/" || return 1
            candidate="$geo"
        elif geodata_stage_loyalsoldier "$geo"; then
            # 压缩包自带的是官方子集 dat，Loyalsoldier 完整版铺好后即无用；
            # 留着会与 $geo 里的两份叠加，多占约 4 MB 峰值。
            rm -f "$unpack/geoip.dat" "$unpack/geosite.dat" || true
            candidate="$geo"
        elif [[ -s "$XRAY_ASSET/geoip.dat" && -s "$XRAY_ASSET/geosite.dat" ]]; then
            warn "Loyalsoldier 下载失败，保留原 geodata 和源标记"
        else
            err "Loyalsoldier 下载失败，重试或显式选择官方源"
            return 1
        fi
    fi
    if [[ -s "$XHY_ETC/config.json" ]]; then
        XRAY_BIN="$unpack/xray" XRAY_ASSET="$candidate" xray_config_test || return 1
    fi
    if [[ "$candidate" == "$geo" ]]; then
        XRAY_BIN="$unpack/xray" geodata_publish "$geo" "$src" || return 1
    fi
    if [[ "$(df -P "$unpack" 2>/dev/null | awk 'NR==2 {print $1}')" \
        == "$(df -P "$(dirname "$XRAY_BIN")" 2>/dev/null | awk 'NR==2 {print $1}')" ]]; then
        mv -f "$unpack/xray" "$XRAY_BIN" || die "替换 $XRAY_BIN 失败（磁盘满？）；原文件未动"
    else
        install -m 0755 "$unpack/xray" "$XRAY_BIN.new" 2>/dev/null \
            || { rm -f "$XRAY_BIN.new"
                 err "写入 $XRAY_BIN.new 失败，余量 $(disk_free_mb /) MB —— 多半是根分区满"
                 die "原二进制未改动"; }
        mv -f "$XRAY_BIN.new" "$XRAY_BIN" || die "替换 $XRAY_BIN 失败；原文件未动"
    fi
    if [[ "v$got" != "$ver" ]]; then
        warn "版本校验: 请求 $ver，实际 v$got（预发布版或镜像差异时可能不同，请确认）"
    fi
    ok "Xray v$got 安装完成，SHA-256 校验通过"
)

x25519_keypair() {
    local out priv pub
    out="$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$XRAY_BIN" x25519 2>/dev/null)" \
        || { err "xray x25519 执行失败"; return 1; }
    # v26 changed "Password" to "Password (PublicKey)"; match both.
    priv="$(printf '%s\n' "$out" | grep -iE '^PrivateKey|^Private[ _]key' | head -1 \
        | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r\n' || true)"
    pub="$(printf '%s\n' "$out" | grep -iE '^Password|^PublicKey|^Public[ _]key' | head -1 \
        | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r\n' || true)"
    [[ -n "$priv" && -n "$pub" ]] || { err "无法解析 x25519 输出: $out"; return 1; }
    printf '%s %s\n' "$priv" "$pub"
}

short_ids() { printf '%s %s\n' "$(rand_hex 8)" "$(rand_hex 16)"; }

cloudflared_install() {
    local cfarch url tmp
    case "$XHY_ARCH" in
        64)        cfarch="amd64" ;;
        arm64-v8a) cfarch="arm64" ;;
        *) die "Cloudflare Tunnel 不支持当前架构 ($XHY_ARCH)" ;;
    esac
    url="${XHY_CF_DL}/cloudflared-linux-${cfarch}"
    tmp="$(mktemp)" || die "无法创建临时文件"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    info "下载 cloudflared ($cfarch)"
    fetch "$url" "$tmp" || die "cloudflared 下载失败"
    # Cloudflare does not publish checksums for these raw binaries. At minimum
    # verify the ELF magic and that the binary actually runs before installing.
    [[ "$(head -c 4 "$tmp")" == $'\x7fELF' ]] || die "cloudflared 下载内容不是 ELF 二进制，已中止"
    chmod 0755 "$tmp"
    "$tmp" --version >/dev/null 2>&1 || die "下载的 cloudflared 无法运行"
    install -m 0755 "$tmp" "$CF_BIN"
    warn "cloudflared 官方 raw 二进制不提供校验和，已做 ELF + 版本自检（无法做到密码学验证）"
    ok "cloudflared 已安装: $("$CF_BIN" --version 2>&1 | head -1)"
}

core_status() {
    local ch ver
    ch="$(xray_channel)"
    ver="$(xray_installed_version)"
    printf '版本通道 : %s\n' "$ch"
    case "$ch" in
        pinned) printf '钉死版本 : %s\n' "$XHY_PINNED_VERSION" ;;
        latest) printf '目标版本 : %s\n' "$(xray_resolve_version)" ;;
        *)      printf '自定义版本: %s\n' "$ch" ;;
    esac
    printf '已装版本 : %s\n' "$ver"
    printf '二进制   : %s\n' "$XRAY_BIN"
    printf 'Geodata  : %s\n' "$XRAY_ASSET"
    [[ -s "$XRAY_ASSET/geoip.dat" ]] && printf '  geoip.dat   %s bytes\n' "$(stat -c%s "$XRAY_ASSET/geoip.dat" 2>/dev/null || echo '?')"
    if [[ -s "$XRAY_ASSET/geosite.dat" ]]; then
        local gssz
        gssz="$(stat -c%s "$XRAY_ASSET/geosite.dat" 2>/dev/null || echo 0)"
        printf '  geosite.dat %s bytes' "$gssz"
        if [[ "$gssz" =~ ^[0-9]+$ ]]; then
            # >9 MB = Loyalsoldier 完整版（默认）；7.5 MB 上下 = 官方 release
            # 自带版（真子集，AI / Google / gfw 覆盖不全）；<1 MB = 文件坏了。
            if (( gssz > 9000000 )); then
                printf '  ← Loyalsoldier 完整版（默认）'
            elif (( gssz >= 6000000 )); then
                printf '  ← 官方版（子集：缺 gfw / google 114 条等，xhy update geodata --force 换回）'
            else
                printf '  ⚠ 体积异常（< 6 MB，疑似损坏/截断），跑 xhy update geodata --force 重下'
            fi
        fi
        printf '\n'
    fi
    if [[ -x "$CF_BIN" ]]; then
        printf 'cloudflared: %s\n' "$("$CF_BIN" --version 2>&1 | head -1)"
    fi
    # 显式 return 0：最后一条若是 `[[ ... ]] && printf`，条件为假时函数返回 1，
    # 在 `set -e` 下调用方（xhy check）会直接中断，自检报告只印一半。
    return 0
}

# Xray-core gained a native Hysteria2 inbound in v26.3.27 (protocol name is
# "hysteria", version must be 2). It requires a TLS certificate. Generate a
# self-signed one and pin its SHA-256 in the share link so clients verify it
# instead of blindly using insecure=1.
# Echo: <crt path> <key path> <pin base64> <pin hex>
hy2_gen_cert() {
    local port="$1" sni="$2" crt key pin_b64 pin_hex
    crt="$XHY_CERTS/hy2_${port}.crt"
    key="$XHY_CERTS/hy2_${port}.key"
    install -d -m 0700 "$XHY_CERTS"
    have_cmd openssl || die "生成 Hysteria2 证书需要 openssl"
    if ! openssl req -x509 -nodes -newkey ec \
            -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$key" -out "$crt" -subj "/CN=${sni}" \
            -addext "subjectAltName=DNS:${sni}" -days 3650 >/dev/null 2>&1; then
        rm -f "$crt" "$key"
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$key" -out "$crt" -subj "/CN=${sni}" \
            -days 3650 >/dev/null 2>&1 || die "自签证书生成失败"
    fi
    chmod 0600 "$key" "$crt"
    pin_b64="$(openssl x509 -in "$crt" -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null | base64 | tr -d '\n')"
    pin_hex="$(openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/.*=//;s/://g' | tr 'A-F' 'a-f')"
    [[ -n "$pin_b64" ]] || die "无法计算证书 SHA-256 指纹"
    printf '%s %s %s %s\n' "$crt" "$key" "$pin_b64" "$pin_hex"
}
