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

# Download a pinned-or-latest Xray release. The .dgst checksum is MANDATORY:
# unlike most one-key scripts, a missing digest aborts instead of continuing.
xray_install() {
    local ver="$1" asset tmp unpack f oldver
    # Keep the currently working binary before replacing it. A failed download
    # never reaches this point; a failed post-install check can still roll back.
    if [[ -x "$XRAY_BIN" ]]; then
        oldver="$(xray_installed_version)"
        install -d -m 0700 "$XHY_BACKUP"
        cp -a "$XRAY_BIN" "$XHY_BACKUP/xray-${oldver//[^0-9A-Za-z._-]/_}-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    asset="Xray-linux-${XHY_ARCH}.zip"
    tmp="$(mktemp -d)" || die "无法创建临时目录"
    unpack="$tmp/unpack"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    info "下载 Xray $ver ($asset)"
    fetch "${XHY_RELEASE_DL}/${ver}/${asset}" "$tmp/$asset" \
        || die "Xray 压缩包下载失败（版本 $ver 是否存在？架构 $XHY_ARCH 是否受支持？）"
    fetch "${XHY_RELEASE_DL}/${ver}/${asset}.dgst" "$tmp/$asset.dgst" \
        || die "SHA-256 摘要文件下载失败。出于安全考虑拒绝安装未校验的二进制。"
    verify_release_digest "$tmp/$asset.dgst" "$tmp/$asset" || die "校验失败，已中止。"

    mkdir -p "$unpack"
    if have_cmd unzip; then
        unzip -o -q "$tmp/$asset" -d "$unpack" || die "解压失败"
    else
        busybox unzip -o -q "$tmp/$asset" -d "$unpack" || die "解压失败"
    fi
    [[ -f "$unpack/xray" ]] || die "压缩包中缺少 xray 二进制"

    install -d -m 0755 "$(dirname "$XRAY_BIN")" "$XRAY_ASSET"
    install -m 0755 "$unpack/xray" "$XRAY_BIN"
    for f in geoip.dat geosite.dat; do
        [[ -s "$unpack/$f" ]] && install -m 0644 "$unpack/$f" "$XRAY_ASSET/$f"
    done

    # Older/newer release archives occasionally omit geodata. geoip:private
    # routing rules need it, so fetch the community dat files as a fallback.
    for f in geoip.dat geosite.dat; do
        if [[ ! -s "$XRAY_ASSET/$f" ]]; then
            info "补充下载 $f"
            fetch "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" \
                "$XRAY_ASSET/$f" || warn "$f 下载失败，相关路由规则将不生效"
        fi
    done

    local got
    got="$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\r' || true)"
    [[ -n "$got" ]] || die "下载的 Xray 无法运行（架构或依赖不匹配）"
    if [[ "v$got" != "$ver" ]]; then
        warn "版本校验: 请求 $ver，实际 v$got（预发布版或镜像差异时可能不同，请确认）"
    fi
    ok "Xray v$got 安装完成，SHA-256 校验通过"
}

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
    [[ -s "$XRAY_ASSET/geosite.dat" ]] && printf '  geosite.dat %s bytes\n' "$(stat -c%s "$XRAY_ASSET/geosite.dat" 2>/dev/null || echo '?')"
    [[ -x "$CF_BIN" ]] && printf 'cloudflared: %s\n' "$("$CF_BIN" --version 2>&1 | head -1)"
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
