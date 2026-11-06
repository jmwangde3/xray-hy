#!/usr/bin/env bash
# xray-hy / distribution, init system and architecture detection.

XHY_DISTRO="unknown"
XHY_DISTRO_VER=""
XHY_INIT="unknown"
XHY_PKG="unknown"
XHY_ARCH=""
XHY_SSH_PORT="22"

detect_platform() {
    local id="" arch=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-unknown}"
        XHY_DISTRO_VER="${VERSION_ID:-}"
    fi
    case "$id" in
        debian|ubuntu|devuan|linuxmint|raspbian|pop)
            XHY_DISTRO="debian"; XHY_PKG="apt" ;;
        alpine)
            XHY_DISTRO="alpine"; XHY_PKG="apk" ;;
        centos|rhel|rocky|almalinux|fedora)
            XHY_DISTRO="rhel"; XHY_PKG="dnf" ;;
        *)
            if have_cmd apt-get;      then XHY_DISTRO="debian"; XHY_PKG="apt"
            elif have_cmd apk;        then XHY_DISTRO="alpine"; XHY_PKG="apk"
            elif have_cmd dnf;        then XHY_DISTRO="rhel";   XHY_PKG="dnf"
            elif have_cmd yum;        then XHY_DISTRO="rhel";   XHY_PKG="yum"
            else die "未识别的发行版 ($id)，仅支持 Debian/Ubuntu、Alpine、RHEL 系。"; fi ;;
    esac

    if [[ -d /run/systemd/system ]] && have_cmd systemctl; then
        XHY_INIT="systemd"
    elif have_cmd rc-service && have_cmd rc-update; then
        XHY_INIT="openrc"
    else
        die "未识别的 init 系统（需要 systemd 或 OpenRC）。"
    fi

    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  XHY_ARCH="64" ;;
        aarch64|arm64) XHY_ARCH="arm64-v8a" ;;
        armv7l|armv6l) XHY_ARCH="arm32-v7a" ;;
        i386|i686)     XHY_ARCH="32" ;;
        *) die "不支持的 CPU 架构: $arch" ;;
    esac

    detect_ssh_port
    debug "platform: distro=$XHY_DISTRO init=$XHY_INIT pkg=$XHY_PKG arch=$XHY_ARCH ssh=$XHY_SSH_PORT"
}

# Read the current SSH port. This script NEVER edits sshd_config: changing it
# remotely is the single most common way to lock oneself out of a VPS.
detect_ssh_port() {
    local p="" f
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -r "$f" ]] || continue
        p="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f" 2>/dev/null | head -1 | awk '{print $2}')"
        [[ -n "$p" ]] && break
    done
    if [[ -z "$p" ]] && have_cmd ss; then
        p="$(ss -H -ltnp 2>/dev/null | grep -iE 'sshd|dropbear' | head -1 \
            | awk '{print $4}' | sed -E 's/.*[:.]//')"
    fi
    [[ "$p" =~ ^[0-9]+$ ]] || p="22"
    XHY_SSH_PORT="$p"
}

pkg_update() {
    case "$XHY_PKG" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
        apk) apk update -q ;;
        dnf) dnf -q makecache ;;
        yum) yum -q makecache ;;
    esac
}

pkg_install() {
    case "$XHY_PKG" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
        apk) apk add --no-cache "$@" ;;
        dnf) dnf install -y -q "$@" ;;
        yum) yum install -y -q "$@" ;;
    esac
}

# Minimal dependency set. Xray is a static binary; no glibc compatibility layer.
ensure_deps() {
    local missing=() want=(bash ca-certificates curl openssl coreutils)
    case "$XHY_DISTRO" in
        alpine) want+=(iptables ip6tables unzip) ;;
        debian) want+=(iptables unzip procps) ;;
        rhel)   want+=(iptables unzip procps-ng) ;;
    esac
    local c
    for c in "${want[@]}"; do
        case "$c" in
            coreutils) have_cmd sha256sum || missing+=("$c") ;;
            procps|procps-ng) have_cmd ss || missing+=("$c") ;;
            *) have_cmd "$c" || missing+=("$c") ;;
        esac
    done
    if (( ${#missing[@]} > 0 )); then
        info "安装依赖: ${missing[*]}"
        pkg_update || warn "软件源更新失败，继续尝试安装。"
        pkg_install "${missing[@]}" || die "依赖安装失败: ${missing[*]}"
    fi
    have_cmd bash || die "缺少 bash，无法继续。"
    have_cmd unzip || have_cmd busybox || die "缺少 unzip/busybox，无法解压 Xray。"
}

# Optional helpers, installed only when the user asks for them.
ensure_optional() {
    case "$1" in
        qrencode)
            if ! have_cmd qrencode; then
                case "$XHY_DISTRO" in
                    alpine) pkg_install libqrencode libqrencode-tools 2>/dev/null || true ;;
                    debian) pkg_install qrencode 2>/dev/null || true ;;
                    rhel)   pkg_install qrencode 2>/dev/null || true ;;
                esac
            fi ;;
    esac
}

platform_summary() {
    printf '发行版   : %s %s\n' "$XHY_DISTRO" "$XHY_DISTRO_VER"
    printf 'Init     : %s\n' "$XHY_INIT"
    printf '架构     : %s (Xray asset: Xray-linux-%s.zip)\n' "$(uname -m)" "$XHY_ARCH"
    printf 'SSH 端口 : %s (只读，脚本不会修改 sshd_config)\n' "$XHY_SSH_PORT"
}
