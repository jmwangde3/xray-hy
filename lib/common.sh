#!/usr/bin/env bash
# xray-hy / common helpers. Sourced by the entrypoint, never executed directly.

XHY_VERSION="0.1.0"
XHY_HOME="${XHY_HOME:-/opt/xray-hy}"
XHY_ETC="${XHY_ETC:-/etc/xray-hy}"
XHY_CONFDIR="$XHY_ETC/confs"
XHY_NODES="$XHY_ETC/nodes"
XHY_STATE="$XHY_ETC/state.env"
XHY_BACKUP="$XHY_ETC/backups"
XHY_SNAPSHOTS="$XHY_ETC/snapshots"
XHY_LOGDIR="${XHY_LOGDIR:-/var/log/xray-hy}"

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_ASSET="${XRAY_ASSET:-/usr/local/share/xray}"
CF_BIN="${CF_BIN:-/usr/local/bin/cloudflared}"

# v26.10.31 is the first Xray release that disables MPTCP by default.
# XTLS/Xray-core#7291 / CVE-2026-98432 (CVSS 9.8): Go 1.24+ enables MPTCP
# on listeners, which makes an exposed Go proxy trivially root-able remotely.
# Older pinned versions remain possible but always produce a loud warning.
XHY_PINNED_VERSION="v26.10.31"
XHY_MIN_SAFE_VERSION="v26.10.31"
XHY_RELEASE_DL="https://github.com/XTLS/Xray-core/releases/download"
XHY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases"
XHY_CF_DL="https://github.com/cloudflare/cloudflared/releases/latest/download"

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

log()   { printf '%s\n' "$*"; }
info()  { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
debug() { [[ "${XHY_DEBUG:-0}" == "1" ]] && printf '%s[dbg]%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; return 0; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "需要 root 权限运行，请使用 sudo 或切换到 root。"
}

# Read a single line from stdin with an optional default and 60s timeout.
ask() {
    local prompt="$1" default="${2:-}" reply=""
    if [[ -n "$default" ]]; then
        read -r -t 60 -p "$prompt [$default]: " reply || reply=""
    else
        read -r -t 60 -p "$prompt: " reply || reply=""
    fi
    printf '%s' "${reply:-$default}"
}

confirm() {
    local prompt="$1" default="${2:-n}" reply
    reply="$(ask "$prompt (y/n)" "$default")"
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

init_dirs() {
    mkdir -p "$XHY_ETC" "$XHY_CONFDIR" "$XHY_LOGDIR" "$XHY_BACKUP" "$XHY_NODES" "$XHY_SNAPSHOTS"
    chmod 0755 "$XHY_ETC" "$XHY_CONFDIR" "$XHY_LOGDIR" "$XHY_BACKUP" 2>/dev/null || true
    chmod 0700 "$XHY_NODES" "$XHY_SNAPSHOTS" 2>/dev/null || true
    [[ -f "$XHY_STATE" ]] || : >"$XHY_STATE"
    chmod 0600 "$XHY_STATE" 2>/dev/null || true
}

# Serialize every config-mutating command. Without this, two concurrent `xhy`
# invocations can interleave fragment writes and silently lose a node.
# Idea borrowed from 0xdabiaoge/singbox-lite's cross-script shared lock.
XHY_LOCK_MODE=""
acquire_lock() {
    local i
    init_dirs
    if have_cmd flock; then
        exec 9>"$XHY_ETC/.lock"
        for ((i = 0; i < 15; i++)); do
            if flock -n 9 2>/dev/null; then XHY_LOCK_MODE="flock"; return 0; fi
            sleep 1
        done
        die "另一个 xhy 实例正在修改配置（锁: $XHY_ETC/.lock）"
    fi
    for ((i = 0; i < 15; i++)); do
        if mkdir "$XHY_ETC/.lock.d" 2>/dev/null; then XHY_LOCK_MODE="dir"; return 0; fi
        sleep 1
    done
    die "无法取得配置锁，若确认无其它实例请删除 $XHY_ETC/.lock.d"
}

release_lock() {
    if [[ "${XHY_LOCK_MODE:-}" == "dir" ]]; then
        rmdir "$XHY_ETC/.lock.d" 2>/dev/null || true
    fi
    XHY_LOCK_MODE=""
}

# Atomic write from stdin: printf '%s' "$content" | atomic_write <path> <mode>
atomic_write() {
    local dest="$1" mode="${2:-0644}" tmp
    tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
    if ! cat >"$tmp"; then rm -f "$tmp"; return 1; fi
    if ! install -m "$mode" "$tmp" "$dest"; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
}

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$XHY_BACKUP"
    cp -a "$f" "$XHY_BACKUP/$(basename "$f").$(date +%Y%m%d%H%M%S).bak"
}

state_get() {
    local key="$1" default="${2:-}" val=""
    if [[ -f "$XHY_STATE" ]]; then
        val="$(grep -m1 "^${key}=" "$XHY_STATE" 2>/dev/null | cut -d= -f2- || true)"
    fi
    printf '%s' "${val:-$default}"
}

state_set() {
    local key="$1" value="$2" tmp
    init_dirs
    tmp="$(mktemp)"
    if [[ -f "$XHY_STATE" ]]; then
        grep -v "^${key}=" "$XHY_STATE" >"$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    install -m 0600 "$tmp" "$XHY_STATE"
    rm -f "$tmp"
}

state_del() {
    local key="$1" tmp
    [[ -f "$XHY_STATE" ]] || return 0
    tmp="$(mktemp)"
    grep -v "^${key}=" "$XHY_STATE" >"$tmp" || true
    install -m 0600 "$tmp" "$XHY_STATE"
    rm -f "$tmp"
}

rand_hex() {
    local n="${1:-8}"
    if [[ -r /dev/urandom ]]; then
        head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-"$n"
    else
        openssl rand -hex 32 | cut -c1-"$n"
    fi
}

rand_path() { printf '/%s' "$(rand_hex 16)"; }

uuid_gen() {
    if [[ -x "$XRAY_BIN" ]]; then
        "$XRAY_BIN" uuid 2>/dev/null | tr -d '\r' | head -1
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

url_encode() {
    local s="$1" out="" i c o
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) out+="$c" ;;
            *) printf -v o '%%%02X' "'$c"; out+="$o" ;;
        esac
    done
    printf '%s' "$out"
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' -e 's/\n/\\n/g'
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

port_busy() {
    local p="$1"
    if have_cmd ss; then
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    elif have_cmd netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
    else
        return 1
    fi
}

public_ip() {
    local ip=""
    ip="$(curl -fsS -m 8 -4 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(curl -fsS -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1)"
    printf '%s' "${ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
}

public_country() {
    local cc=""
    cc="$(curl -fsS -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^loc=//p' | head -1)"
    [[ -z "$cc" ]] && cc="$(curl -fsS -m 8 "https://ipapi.co/country" 2>/dev/null | tr -d '\r\n' | head -c 2)"
    printf '%s' "${cc^^}"
}

# Fetch with retries. Never pipes remote content into a shell.
fetch() {
    local url="$1" dest="$2"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 -m 120 -sS "$url" -o "$dest"
}

sha256_file() { sha256sum "$1" | awk '{print $1}'; }

# Force-verified download of an Xray release archive.
# Xray publishes <asset>.dgst files containing the SHA-256 of each archive.
verify_release_digest() {
    local dgst="$1" archive="$2" expected actual
    expected="$(grep -Eio 'SHA2?-?256[^A-Za-z0-9]*=?[[:space:]]*[0-9a-fA-F]{64}' "$dgst" 2>/dev/null \
        | grep -Eio '[0-9a-fA-F]{64}' | head -1 | tr 'A-F' 'a-f')"
    [[ -n "$expected" ]] || { err "无法从 .dgst 解析 SHA-256，拒绝继续。"; return 1; }
    actual="$(sha256_file "$archive" | tr 'A-F' 'a-f')"
    if [[ "$expected" != "$actual" ]]; then
        err "SHA-256 校验失败：期望 $expected，实际 $actual"
        return 1
    fi
    ok "SHA-256 校验通过 (${actual:0:16}...)"
}
