#!/usr/bin/env bash
# xray-hy / warp —— 给落地机加一个「换 ASN」的旁路出站。
#
# 起因（2026-11-15）：x.ai 与 grok.com 对 AS45102（阿里云）整段返回
#   403 Blocked due to abusive traffic patterns
# 同一台机器换到 Cloudflare 自己的 AS13335 出口立刻 200。WARP 是 Cloudflare
# 的免费 WireGuard 接入，出口天然是这个 ASN，于是：落地机上跑一个 wireproxy
# （WARP over WireGuard + 本地 socks5），xray 按域名把对应流量交给它。
#
# 与 relay 的关系（重要）：两者都往 nodes.sh 的 two 个扩展钩子里塞东西，而钩子
# 只有一个函数名 —— 谁后定义谁生效。relay.sh 的两个钩子末尾会追加 warp_* 的
# 输出（relay 规则在前、warp 规则在后），因此 **warp.sh 必须排在 LIBS 的
# relay 之后**（见 build.sh）。顺序反了的表现是：x.ai 仍从本机直出、403。
#
# 状态存 $XHY_NODES/warp.env（0600，纳入快照）。wireproxy 二进制在
# /usr/local/bin，WARP 账号与 wp.conf 在 $WARP_DIR（含私钥，不进快照）。

WARP_DEFAULT_PORT=25344
WARP_DEFAULT_TAG="warp"
# 裸名 = domain:（含所有子域）。domain:x.ai 一并覆盖 auth/accounts/console/
# images/api 等全部子域 —— x.ai 是按 ASN 整段封的，逐个列子域没有意义，
# 而且新子域上线时不会漏。
WARP_DEFAULT_DOMAINS="domain:x.ai,domain:grok.com"
WARP_DEFAULT_ENDPOINT="engage.cloudflareclient.com:2408"
WARP_DEFAULT_DNS="1.1.1.1"
WARP_DEFAULT_MTU=1280
# WARP 的公共 peer 公钥（Cloudflare 官方注册流程里固定不变的那一个）
WARP_PEER_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_DIR="${XHY_WARP_DIR:-/usr/local/lib/xray-hy/warp}"
WARP_BIN="${XHY_WARP_BIN:-/usr/local/bin/wireproxy}"
WARP_SVC="warp-proxy"

WARP_ENABLE=""; WARP_PORT=""; WARP_DOMAINS=""; WARP_TAG=""; WARP_ENDPOINT=""

warp_reset_vars() {
    WARP_ENABLE=""; WARP_PORT=""; WARP_DOMAINS=""; WARP_TAG=""; WARP_ENDPOINT=""
}

# 双语句对，理由同 relay_say：i18n 的长句词条会互相吞，这里就地给两份。
warp_say() {
    local lvl="$1" zh="$2" en="${3:-$2}" s
    if [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]]; then s="$en"; else s="$zh"; fi
    case "$lvl" in
        ok)   ok "$s" ;;
        warn) warn "$s" ;;
        err)  err "$s" ;;
        *)    info "$s" ;;
    esac
}

warp_usage() {
    if [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]]; then
        cat <<'EOF'
Usage: xhy warp <command> [options]

  on       Install WARP egress and route the listed domains through it.
           xhy warp on [--port 25344] [--domains domain:x.ai,domain:grok.com]
                       [--tag warp] [--endpoint HOST:PORT] [--reuse-account]
  off      Remove the xray outbound and routing rule; keep the proxy running.
  status   Show state, proxy health and what xray currently routes.
  test     Self-check: binary, service, socks port, egress IP, domain reachability.
  reapply  Re-inject after the config was rebuilt / restored from a snapshot.
  del      Remove everything: xray hooks, service, proxy binary, account files.

Why: some sites block whole cloud ASNs. x.ai / grok.com answer
     "403 Blocked due to abusive traffic patterns" to AS45102 (Alibaba).
     WARP exits from AS13335 (Cloudflare) and is allowed.
EOF
        return 0
    fi
    cat <<'EOF'
用法: xhy warp <命令> [选项]

  on       安装 WARP 出站，并把指定域名交给它。
           xhy warp on [--port 25344] [--domains domain:x.ai,domain:grok.com]
                       [--tag warp] [--endpoint HOST:PORT] [--reuse-account]
  off      撤掉 xray 的出站与路由规则（代理进程保留，随时可再 on）。
  status   查状态：开关、代理健康度、xray 当前把哪些域名指过去。
  test     自检：二进制 / 服务 / socks 端口 / 出口 IP / 目标域名可达性。
  reapply  配置被重建或从快照回滚后，重新注入一次。
  del      全部删除：xray 钩子、服务、代理二进制、账号文件。

为什么需要它：有些站按整段云厂商 ASN 封。x.ai / grok.com 对 AS45102（阿里云）
          一律返回 403 Blocked due to abusive traffic patterns，而 WARP 的
          出口是 AS13335（Cloudflare），放行。
EOF
}

# ---------------------------------------------------------------------------
# 状态文件
# ---------------------------------------------------------------------------

warp_env_load() {
    local f="$XHY_NODES/warp.env" line key
    warp_reset_vars
    [[ -f "$f" && ! -L "$f" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in ''|\#*) continue ;; esac
        [[ "$line" == *=* ]] || return 1
        key="${line%%=*}"
        case "$key" in
            WARP_ENABLE|WARP_PORT|WARP_DOMAINS|WARP_TAG|WARP_ENDPOINT)
                printf -v "$key" '%s' "${line#*=}" ;;
        esac
    done <"$f"
    [[ "$WARP_ENABLE" == on ]] || return 1
    valid_port "$WARP_PORT" || return 1
    [[ -n "$WARP_DOMAINS" && -n "$WARP_TAG" ]] || return 1
    return 0
}

warp_env_save() {
    [[ -d "$XHY_NODES" ]] || mkdir -p "$XHY_NODES" 2>/dev/null || return 1
    {
        printf '# xray-hy warp state (generated, do not edit by hand)\n'
        printf '# %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
        printf 'WARP_ENABLE=%s\n' "$WARP_ENABLE"
        printf 'WARP_PORT=%s\n' "$WARP_PORT"
        printf 'WARP_DOMAINS=%s\n' "$WARP_DOMAINS"
        printf 'WARP_TAG=%s\n' "$WARP_TAG"
        printf 'WARP_ENDPOINT=%s\n' "$WARP_ENDPOINT"
    } | atomic_write "$XHY_NODES/warp.env" 0600
}

# 是否处于启用态（钩子用它决定要不要注入）
warp_active() { warp_env_load; }

# ---------------------------------------------------------------------------
# 钩子：出站 + 路由（由 relay.sh 的同名函数调用，别在此重复定义那两个名字）
# ---------------------------------------------------------------------------

# 域名列表 → JSON 数组元素串。裸名补 domain: 前缀。
# 反斜杠要转义成 \\（regexp 规则里常带 \. \d），双引号同理 —— 否则拼出来的
# routing 段是坏 JSON，xray 直接起不来。
warp_domains_json() {
    local raw="$1" item esc out="" sep="" arr=()
    local IFS=','
    read -ra arr <<< "$raw"
    for item in ${arr[@]+"${arr[@]}"}; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] || continue
        case "$item" in
            domain:*|full:*|keyword:*|regexp:*|geosite:*|ext:*) ;;
            *) item="domain:${item}" ;;
        esac
        # 控制字符无法在 JSON 字符串里裸写，直接拒（域名里也不该出现）
        case "$item" in
            *[[:cntrl:]]*) return 1 ;;
        esac
        esc="${item//\\/\\\\}"
        esc="${esc//\"/\\\"}"
        out+="${sep}\"${esc}\""; sep=","
    done
    printf '%s' "$out"
}

warp_outbound_json() {
    warp_env_load || return 0
    printf '{"protocol":"socks","tag":"%s","settings":{"servers":[{"address":"127.0.0.1","port":%s}]}}' \
        "$WARP_TAG" "$WARP_PORT"
    return 0
}

warp_routing_rules_json() {
    warp_env_load || return 0
    local domains
    domains="$(warp_domains_json "$WARP_DOMAINS")" || return 0
    [[ -n "$domains" ]] || return 0
    printf '{"type":"field","domain":[%s],"outboundTag":"%s"}' "$domains" "$WARP_TAG"
    return 0
}

# ---------------------------------------------------------------------------
# 平台与文件
# ---------------------------------------------------------------------------

warp_arch() {
    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64)  printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

warp_conf_path() { printf '%s/wp.conf' "$WARP_DIR"; }
warp_account_path() { printf '%s/wgcf-account.toml' "$WARP_DIR"; }
warp_profile_path() { printf '%s/wgcf-profile.conf' "$WARP_DIR"; }

warp_svc_installed() { [[ -f "/etc/init.d/$WARP_SVC" ]]; }

# 所有对 init 系统的调用都必须带 9>&-：xhy 用 `exec 9>lock` + flock 持锁，而
# openrc 的 supervise-daemon 是**常驻**的，会把 fd 9 一起继承下去 —— 于是那把锁
# 被一个不该管配置的进程永久持有，之后任何 `xhy ...` 都卡在「另一个实例正在
# 修改配置」。service.sh 的 svc_* 早就这么做了，这里是同一坑的第二现场。
warp_svc() { rc-service "$@" 9>&-; }
warp_upd() { rc-update "$@" 9>&-; }

warp_proxy_up() {
    # 服务在跑 && socks 端口在听。两者缺一都不能算健康。
    if have_cmd rc-service; then
        warp_svc "$WARP_SVC" status >/dev/null 2>&1 || return 1
    else
        pgrep -f "wireproxy -c" >/dev/null 2>&1 || return 1
    fi
    port_busy "$WARP_PORT"
}

# 经 socks 走一次，打印出口 IP（失败给空）
warp_egress_ip() {
    local port="$1"
    have_cmd curl || return 0
    curl -s --max-time 12 --socks5-hostname "127.0.0.1:${port}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
        sed -n 's/^ip=//p' | head -1 || true
}

# ---------------------------------------------------------------------------
# 安装：二进制、账号、配置
# ---------------------------------------------------------------------------

warp_dl() {
    local url="$1" dest="$2"
    if have_cmd curl; then
        curl -fsSL --max-time 120 -o "$dest" "$url" && return 0
    fi
    if have_cmd wget; then
        wget -q -O "$dest" --timeout=120 "$url" && return 0
    fi
    return 1
}

warp_install_bin() {
    local arch tmp url
    if [[ -x "$WARP_BIN" && "${1:-}" != "--force" ]]; then
        return 0
    fi
    arch="$(warp_arch)" || { warp_say err "不支持的架构: $(uname -m)" "unsupported arch: $(uname -m)"; return 1; }
    tmp="$(mktemp -d)" || return 1
    url="https://github.com/pufferffish/wireproxy/releases/latest/download/wireproxy_linux_${arch}.tar.gz"
    warp_say info "下载 wireproxy ($arch)" "downloading wireproxy ($arch)"
    if ! warp_dl "$url" "$tmp/wp.tar.gz"; then
        rm -rf "$tmp" || true
        warp_say err "下载失败: $url" "download failed: $url"
        return 1
    fi
    if ! tar xzf "$tmp/wp.tar.gz" -C "$tmp" 2>/dev/null || [[ ! -f "$tmp/wireproxy" ]]; then
        rm -rf "$tmp" || true
        warp_say err "解包失败（archive 结构不符）" "unpack failed (unexpected archive layout)"
        return 1
    fi
    if ! chmod 0755 "$tmp/wireproxy" || ! mv -f "$tmp/wireproxy" "$WARP_BIN"; then
        rm -rf "$tmp" || true
        warp_say err "安装到 $WARP_BIN 失败" "install to $WARP_BIN failed"
        return 1
    fi
    rm -rf "$tmp" || true
    return 0
}

# 用 wgcf 注册一个 WARP 账号并生成 wp.conf（只在没有账号时做一次）
warp_create_account() {
    local arch ver tmp
    arch="$(warp_arch)" || return 1
    tmp="$(mktemp -d)" || return 1
    ver="$(curl -fsSL --max-time 20 https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null |
        sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
    [[ -n "$ver" ]] || ver="v2.3.1"
    warp_say info "注册 WARP 账号（wgcf $ver）" "registering WARP account (wgcf $ver)"
    if ! warp_dl "https://github.com/ViRb3/wgcf/releases/download/${ver}/wgcf_${ver#v}_linux_${arch}" "$tmp/wgcf"; then
        rm -rf "$tmp" || true
        warp_say err "下载 wgcf 失败" "wgcf download failed"
        return 1
    fi
    chmod 0755 "$tmp/wgcf" || { rm -rf "$tmp"; return 1; }
    if ! ( cd "$tmp" && ./wgcf register --accept-tos >/dev/null 2>&1 ); then
        rm -rf "$tmp" || true
        warp_say err "wgcf register 失败（Cloudflare 注册接口不可达？）" \
                    "wgcf register failed (Cloudflare enrolment unreachable?)"
        return 1
    fi
    if ! ( cd "$tmp" && ./wgcf generate >/dev/null 2>&1 ); then
        rm -rf "$tmp" || true
        warp_say err "wgcf generate 失败" "wgcf generate failed"
        return 1
    fi
    mkdir -p "$WARP_DIR" && chmod 0700 "$WARP_DIR" || { rm -rf "$tmp"; return 1; }
    mv -f "$tmp/wgcf-account.toml" "$(warp_account_path)" 2>/dev/null || true
    chmod 600 "$(warp_account_path)" 2>/dev/null || true
    # profile 留着便于事后核对；wp.conf 才是实际喂给 wireproxy 的。
    cp -f "$tmp/wgcf-profile.conf" "$(warp_profile_path)" 2>/dev/null || true
    chmod 600 "$(warp_profile_path)" 2>/dev/null || true
    WARP_PRIVATE_KEY="$(sed -n 's/^PrivateKey = //p' "$tmp/wgcf-profile.conf" | head -1)"
    rm -rf "$tmp" || true
    [[ -n "$WARP_PRIVATE_KEY" ]] || { warp_say err "profile 里没解析到私钥" "no private key in profile"; return 1; }
    return 0
}

warp_write_conf() {
    local key="$1" conf address profile_key
    [[ -n "$key" ]] || return 1
    mkdir -p "$WARP_DIR" && chmod 0700 "$WARP_DIR" || return 1
    conf="$(warp_conf_path)"
    # Only reuse addresses belonging to this key; preserve a working config.
    if [[ -f "$(warp_profile_path)" ]]; then
        profile_key="$(sed -n 's/^PrivateKey = //p' "$(warp_profile_path)" | head -1)"
        if [[ "$profile_key" == "$key" ]]; then
            address="$(sed -n 's/^Address = //p' "$(warp_profile_path)" | head -1)"
        fi
    fi
    if [[ -z "${address:-}" && -f "$conf" ]]; then
        profile_key="$(sed -n 's/^PrivateKey = //p' "$conf" | head -1)"
        if [[ "$profile_key" == "$key" ]]; then
            address="$(sed -n 's/^Address = //p' "$conf" | head -1)"
        fi
    fi
    if [[ ! "${address:-}" =~ ^[0-9a-fA-F:.,/[:space:]]+$ || "$address" != *:* || "$address" != *.* ]]; then
        warp_say err "缺少此账号的双栈地址，保留现有配置；请恢复 wgcf-profile.conf" \
                     "missing dual-stack address for this account; existing configuration preserved; restore wgcf-profile.conf"
        return 1
    fi
    {
        printf '# generated by xhy warp -- contains a private key, keep 0600\n'
        printf '[Interface]\n'
        printf 'Address = %s\n' "$address"
        printf 'PrivateKey = %s\n' "$key"
        printf 'DNS = %s\n' "$WARP_DEFAULT_DNS"
        printf 'MTU = %s\n' "$WARP_DEFAULT_MTU"
        printf '\n[Peer]\n'
        printf 'PublicKey = %s\n' "$WARP_PEER_PUBKEY"
        printf 'Endpoint = %s\n' "$WARP_ENDPOINT"
        printf 'AllowedIPs = 0.0.0.0/0, ::/0\n'
        printf '\n[Socks5]\n'
        printf 'BindAddress = 127.0.0.1:%s\n' "$WARP_PORT"
    } | atomic_write "$conf" 0600
}

warp_service_install() {
    local unit="/etc/init.d/$WARP_SVC"
    {
        printf '#!/sbin/openrc-run\n'
        printf '# generated by xhy warp\n'
        printf 'name="%s"\n' "$WARP_SVC"
        printf 'description="Cloudflare WARP socks5 egress for xray-hy"\n\n'
        printf 'supervisor="supervise-daemon"\n'
        printf 'command="%s"\n' "$WARP_BIN"
        printf 'command_args="-c %s"\n' "$(warp_conf_path)"
        printf 'pidfile="/run/%s.pid"\n' "$WARP_SVC"
        printf 'respawn_delay=5\n'
        printf 'respawn_max=0\n\n'
        printf 'depend() {\n'
        printf '    need net\n'
        printf '    after firewall\n'
        printf '}\n'
    } | atomic_write "$unit" 0755 || return 1
    warp_upd add "$WARP_SVC" default >/dev/null 2>&1 || true
    return 0
}

warp_service_remove() {
    if have_cmd rc-service; then
        warp_svc "$WARP_SVC" stop >/dev/null 2>&1 || true
    fi
    if have_cmd rc-update; then
        warp_upd del "$WARP_SVC" default >/dev/null 2>&1 || true
    fi
    rm -f "/etc/init.d/$WARP_SVC" 2>/dev/null || true
    rm -f "/run/$WARP_SVC.pid" 2>/dev/null || true
    pkill -f "$WARP_BIN -c" >/dev/null 2>&1 || true
    return 0
}

warp_service_restart() {
    if ! have_cmd rc-service; then
        warp_say err "本机没有 openrc（rc-service），无法托管代理进程" \
                     "no openrc on this host (rc-service missing)"
        return 1
    fi
    warp_svc "$WARP_SVC" restart >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if port_busy "$WARP_PORT"; then return 0; fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# 应用
# ---------------------------------------------------------------------------

warp_apply() {
    XHY_SKIP_SNAPSHOT=1 rebuild_config || return 1
    config_reload --validated || return 1
    return 0
}

warp_reapply_render() {
    # 没装 wireproxy 时不该注入出站 —— 否则 xray 起来后所有 x.ai 流量指向
    # 一个不存在的端口，表现为「连不上」而不是「403」，更难查。
    [[ -f "$(warp_conf_path)" ]] || { warp_say err "缺少 $(warp_conf_path)，先跑 xhy warp on" "missing $(warp_conf_path), run xhy warp on first"; return 1; }
    warp_apply
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

warp_parse_args() {
    WARP_PORT="$WARP_DEFAULT_PORT"
    WARP_DOMAINS="$WARP_DEFAULT_DOMAINS"
    WARP_TAG="$WARP_DEFAULT_TAG"
    WARP_ENDPOINT="$WARP_DEFAULT_ENDPOINT"
    WARP_REUSE="0"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)     shift; WARP_PORT="${1:-}" ;;
            --domains)  shift; WARP_DOMAINS="${1:-}" ;;
            --tag)      shift; WARP_TAG="${1:-}" ;;
            --endpoint) shift; WARP_ENDPOINT="${1:-}" ;;
            --reuse-account) WARP_REUSE="1" ;;
            -h|--help)  warp_usage; return 2 ;;
            *) warp_say err "未知参数: $1" "unknown option: $1"; return 1 ;;
        esac
        shift
    done
    valid_port "$WARP_PORT" || { warp_say err "端口不合法: $WARP_PORT" "bad port: $WARP_PORT"; return 1; }
    [[ "$WARP_TAG" =~ ^[A-Za-z0-9_-]+$ ]] || { warp_say err "tag 不合法: $WARP_TAG" "bad tag: $WARP_TAG"; return 1; }
    warp_domains_json "$WARP_DOMAINS" >/dev/null || { warp_say err "域名列表含非法字符" "domain list has illegal characters"; return 1; }
    [[ -n "$(warp_domains_json "$WARP_DOMAINS")" ]] || { warp_say err "域名列表为空" "empty domain list"; return 1; }
    return 0
}

warp_cmd_on() {
    need_root
    warp_parse_args "$@" || return $(( $? == 2 ? 0 : 1 ))
    init_dirs || return 1

    # 磁盘闸门：wireproxy 约 6 MB，wgcf 约 8 MB，账号与配置可忽略。
    local free_mb
    free_mb="$(disk_free_mb / 2>/dev/null || echo 999)"
    if [[ "$free_mb" =~ ^[0-9]+$ ]] && (( free_mb < 40 )); then
        warp_say err "根分区仅剩 ${free_mb} MB，低于 40 MB 闸门" \
                     "only ${free_mb} MB free on /, below the 40 MB gate"
        return 1
    fi

    if port_busy "$WARP_PORT" && ! pgrep -f "wireproxy -c" >/dev/null 2>&1; then
        warp_say err "端口 $WARP_PORT 已被其他进程占用" "port $WARP_PORT is taken by another process"
        return 1
    fi

    warp_install_bin || return 1

    local key=""
    if [[ -f "$(warp_conf_path)" ]]; then
        key="$(sed -n 's/^PrivateKey = //p' "$(warp_conf_path)" | head -1)"
    fi
    if [[ -z "$key" ]]; then
        if [[ -f "$(warp_account_path)" ]]; then
            # 有账号但没 conf：用已有账号重新 generate，不必重新注册
            local arch ver tmp
            arch="$(warp_arch)" || return 1
            tmp="$(mktemp -d)" || return 1
            ver="$(curl -fsSL --max-time 20 https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null |
                sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
            [[ -n "$ver" ]] || ver="v2.3.1"
            if warp_dl "https://github.com/ViRb3/wgcf/releases/download/${ver}/wgcf_${ver#v}_linux_${arch}" "$tmp/wgcf"; then
                chmod 0755 "$tmp/wgcf" 2>/dev/null || true
                cp -f "$(warp_account_path)" "$tmp/wgcf-account.toml" 2>/dev/null || true
                ( cd "$tmp" && ./wgcf generate >/dev/null 2>&1 ) || true
                key="$(sed -n 's/^PrivateKey = //p' "$tmp/wgcf-profile.conf" 2>/dev/null | head -1)"
                if [[ -n "$key" ]]; then
                    mkdir -p "$WARP_DIR" && chmod 0700 "$WARP_DIR" || { rm -rf "$tmp"; return 1; }
                    cp -f "$tmp/wgcf-profile.conf" "$(warp_profile_path)" || { rm -rf "$tmp"; return 1; }
                    chmod 600 "$(warp_profile_path)" || { rm -rf "$tmp"; return 1; }
                fi
            fi
            rm -rf "$tmp" || true
        fi
    fi
    if [[ -z "$key" ]]; then
        warp_create_account || return 1
        key="$WARP_PRIVATE_KEY"
    fi
    [[ -n "$key" ]] || { warp_say err "拿不到 WARP 私钥" "could not obtain WARP private key"; return 1; }

    warp_write_conf "$key" || { warp_say err "写 $(warp_conf_path) 失败" "failed writing $(warp_conf_path)"; return 1; }

    WARP_ENABLE=on
    warp_env_save || { warp_say err "写 warp.env 失败" "failed writing warp.env"; return 1; }

    warp_service_install || { warp_say err "写 service 文件失败" "failed writing service unit"; return 1; }
    if ! warp_service_restart; then
        warp_say err "代理没起来，看：rc-service $WARP_SVC status" \
                     "proxy did not start, check: rc-service $WARP_SVC status"
        return 1
    fi

    local ip
    ip="$(warp_egress_ip "$WARP_PORT")"
    if [[ -z "$ip" ]]; then
        warp_say err "socks5 端口在听，但出不了网（WARP 握手失败？）" \
                     "socks5 port is listening but egress fails (WARP handshake?)"
        return 1
    fi

    warp_say info "应用 xray 配置（relay 会短暂中断）" "applying xray config (relay blips briefly)"
    warp_reapply_render || { warp_say err "配置应用失败，已保留 warp.env 便于重试" "config apply failed; warp.env kept for retry"; return 1; }

    warp_say ok "WARP 出站已启用：$WARP_DOMAINS → $WARP_TAG（出口 $ip）" \
                "WARP egress enabled: $WARP_DOMAINS -> $WARP_TAG (exit $ip)"
    return 0
}

warp_cmd_off() {
    need_root
    warp_env_load || { warp_say info "本来就是关闭状态" "already off"; return 0; }
    WARP_ENABLE=off
    warp_env_save || return 1
    warp_say info "重建 xray 配置（relay 会短暂中断）" "rebuilding xray config (relay blips briefly)"
    warp_apply || return 1
    warp_say ok "已摘掉 WARP 路由；代理进程仍在跑（xhy warp del 可彻底删）" \
                "WARP routing removed; proxy still running (xhy warp del to remove)"
    return 0
}

warp_cmd_status() {
    local conf; conf="$(warp_conf_path)"
    if warp_env_load; then
        printf 'warp:      on\n'
        printf 'tag:       %s\n' "$WARP_TAG"
        printf 'domains:   %s\n' "$WARP_DOMAINS"
        printf 'socks:     127.0.0.1:%s\n' "$WARP_PORT"
        printf 'endpoint:  %s\n' "$WARP_ENDPOINT"
    else
        printf 'warp:      off\n'
        printf 'conf:      %s\n' "$([[ -f "$conf" ]] && echo present || echo absent)"
        printf 'binary:    %s\n' "$([[ -x "$WARP_BIN" ]] && echo present || echo absent)"
        printf 'service:   %s\n' "$(warp_svc_installed && echo installed || echo absent)"
        return 0
    fi
    printf 'binary:    %s\n' "$([[ -x "$WARP_BIN" ]] && echo present || echo absent)"
    printf 'conf:      %s\n' "$([[ -f "$conf" ]] && echo present || echo absent)"
    printf 'service:   %s\n' "$(warp_svc_installed && echo installed || echo absent)"
    printf 'proxy:     %s\n' "$(warp_proxy_up && echo up || echo down)"
    local ip; ip="$(warp_egress_ip "$WARP_PORT")"
    printf 'exit-ip:   %s\n' "${ip:-none}"
    if [[ -f "$XHY_ETC/config.json" ]]; then
        printf 'in-config: %s\n' \
            "$(grep -q "\"$WARP_TAG\"" "$XHY_ETC/config.json" 2>/dev/null && echo yes || echo no)"
    fi
    return 0
}

warp_cmd_test() {
    local rc=0
    if warp_env_load; then
        warp_say ok "状态文件可读（$WARP_DOMAINS → $WARP_TAG :$WARP_PORT）" \
                    "state file OK ($WARP_DOMAINS -> $WARP_TAG :$WARP_PORT)"
    else
        warp_say warn "未启用（没有有效的 warp.env）" "not enabled (no valid warp.env)"
        rc=1
    fi
    [[ -x "$WARP_BIN" ]] && warp_say ok "wireproxy 在位: $WARP_BIN" "wireproxy present: $WARP_BIN" \
                         || { warp_say err "wireproxy 缺失: $WARP_BIN" "wireproxy missing: $WARP_BIN"; rc=1; }
    [[ -f "$(warp_conf_path)" ]] && warp_say ok "配置在位: $(warp_conf_path)" "conf present: $(warp_conf_path)" \
                                 || { warp_say err "配置缺失: $(warp_conf_path)" "conf missing: $(warp_conf_path)"; rc=1; }
    warp_svc_installed && warp_say ok "service 已安装: $WARP_SVC" "service installed: $WARP_SVC" \
                       || { warp_say err "service 未安装: $WARP_SVC" "service missing: $WARP_SVC"; rc=1; }
    if warp_proxy_up; then
        warp_say ok "socks 端口在听: $WARP_PORT" "socks port listening: $WARP_PORT"
    else
        warp_say err "socks 端口没在听: $WARP_PORT" "socks port not listening: $WARP_PORT"; rc=1
    fi
    if [[ $rc -eq 0 ]]; then
        local ip; ip="$(warp_egress_ip "$WARP_PORT")"
        if [[ -n "$ip" ]]; then
            warp_say ok "出口 IP: $ip" "egress IP: $ip"
        else
            warp_say err "经 socks 出不了网" "no egress through socks"; rc=1
        fi
    fi
    if [[ -f "$XHY_ETC/config.json" && -n "$WARP_TAG" ]]; then
        if grep -q "\"$WARP_TAG\"" "$XHY_ETC/config.json" 2>/dev/null; then
            warp_say ok "xray 配置里已有 $WARP_TAG 出站" "xray config contains the $WARP_TAG outbound"
        else
            warp_say warn "xray 配置里没有 $WARP_TAG（跑 xhy warp reapply）" \
                          "xray config lacks $WARP_TAG (run xhy warp reapply)"
            rc=1
        fi
    fi
    return $rc
}

warp_cmd_del() {
    need_root
    if [[ -f "$XHY_NODES/warp.env" ]]; then
        WARP_ENABLE=off
        WARP_PORT="${WARP_PORT:-$WARP_DEFAULT_PORT}"
        WARP_DOMAINS="${WARP_DOMAINS:-$WARP_DEFAULT_DOMAINS}"
        WARP_TAG="${WARP_TAG:-$WARP_DEFAULT_TAG}"
        WARP_ENDPOINT="${WARP_ENDPOINT:-$WARP_DEFAULT_ENDPOINT}"
        warp_env_save >/dev/null 2>&1 || true
        warp_apply >/dev/null 2>&1 || true
    fi
    warp_service_remove
    rm -f "$XHY_NODES/warp.env" 2>/dev/null || true
    rm -rf "$WARP_DIR" 2>/dev/null || true
    rm -f "$WARP_BIN" 2>/dev/null || true
    warp_say ok "WARP 出站、服务、二进制与账号均已删除" \
                "WARP egress, service, binary and account files removed"
    return 0
}

cmd_warp() {
    local sub="${1:-status}"
    [[ $# -gt 0 ]] && shift
    case "$sub" in
        on)      warp_cmd_on "$@" ;;
        off)     warp_cmd_off "$@" ;;
        status)  warp_cmd_status "$@" ;;
        test)    warp_cmd_test "$@" ;;
        reapply) need_root; warp_reapply_render ;;
        del)     warp_cmd_del "$@" ;;
        -h|--help|help) warp_usage ;;
        *) warp_say err "未知子命令: $sub（看 xhy warp --help）" "unknown subcommand: $sub (see xhy warp --help)"; return 2 ;;
    esac
}
