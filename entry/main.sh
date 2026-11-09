# 把「正在运行的这个文件」直装成 /usr/local/bin/xhy（不再嵌套 /usr/local/lib/xray-hy + 软链）。
#   本地文件运行（sh install.sh / ./xhy）：直接复制
#   bash <(curl ...)：BASH_SOURCE 是管道，读不回来，按 XHY_INSTALL_URL 取一份
# 已经在目标位置运行时（开发目录）什么都不做。
install_self() {
    need_root
    local src="${XHY_RUNNING:-}" real="" tmp
    # 软链调用时 BASH_SOURCE 是链接本身。先解析出真身：reconcile_bin 会删掉
    # /usr/local/bin/xhy 这个链接，之后再复制 $src 就复制不到了。旧布局
    # /usr/local/bin/xhy -> /usr/local/lib/xray-hy/xhy 正是这种情况。
    if [[ -n "$src" ]]; then
        real="$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")"
    fi
    reconcile_bin
    install -d -m 0755 "$XHY_APP_DIR" || die "无法创建 $XHY_APP_DIR"
    # 已是规范直装（入口是普通文件、运行的就是它本身）→ 只补权限 + 清孤儿
    if [[ -n "$real" ]] && [[ ! -L "$XHY_SELF" ]] \
       && [[ "$real" == "$(readlink -f "$XHY_SELF" 2>/dev/null || printf '%s' "$XHY_SELF")" ]]; then
        chmod 0755 "$XHY_SELF" 2>/dev/null || true
        _cleanup_legacy_self
        return 0
    fi
    tmp="$XHY_SELF.new.$$"
    if [[ -n "$real" && -f "$real" ]]; then
        install -m 0755 "$real" "$tmp" || die "复制脚本到 $tmp 失败"
    else
        info "当前是从管道运行的，重新下载一份脚本到 $XHY_SELF ..."
        fetch "$XHY_INSTALL_URL" "$tmp" || die "下载脚本本体失败（见上面的 curl 错误码）"
        # 拿到的必须是本项目（有构建号）。构建号不同只说明 release 已更新，
        # 装「最新这份」正是期望行为；真正的风险（下到非本项目内容）由下面的
        # 构建号存在性检查兜底。
        if ! grep -q '^XHY_BUILD="[0-9a-f]\{12\}"$' "$tmp"; then
            rm -f "$tmp"
            die "下载到的脚本缺少构建号，可能不是本项目的 install.sh，已放弃"
        fi
        if ! grep -q "^XHY_BUILD=\"$XHY_BUILD\"$" "$tmp"; then
            warn "下载到的构建 $(sed -n 's/^XHY_BUILD=\"\(.*\)\"$/\1/p' "$tmp" | head -1) 与当前运行的不同（release 已更新），将安装最新这份"
        fi
        chmod 0755 "$tmp"
    fi
    mv -f "$tmp" "$XHY_SELF" || { rm -f "$tmp"; die "无法写入 $XHY_SELF"; }
    ok "脚本已安装到 $XHY_SELF"
    _cleanup_legacy_self
}

# 命令入口目录：默认 /usr/local/bin，离线测试用 XHY_BINDIR 指到临时目录，
# 免得测试真的往系统目录里塞软链。
XHY_BINDIR="${XHY_BINDIR:-/usr/local/bin}"

create_symlink() {
    local bindir="${XHY_BINDIR:-/usr/local/bin}"
    # 单文件已直接装在 $bindir/xhy 时不再做软链（否则会变成自指向的环）。
    [[ "$XHY_SELF" == "$bindir/xhy" ]] && { chmod 0755 "$XHY_SELF" 2>/dev/null || true; return 0; }
    install -d -m 0755 "$bindir"
    chmod 0755 "$XHY_SELF"
    ln -sf "$XHY_SELF" "$bindir/xhy"
    ok "命令入口: $bindir/xhy -> $XHY_SELF"
}

# 一键脚本（bash <(curl ...)、wget|sh、sh install.sh）跑完后退出菜单，
# `xhy` 必须能用。以前只有 cmd_install 的 stage 2 会落地脚本本体，而无参数
# 运行走的是菜单，于是「装完了」其实什么都没装 —— 连 /usr/local/bin/xhy
# 都不存在。任何从非安装位置发起的运行，先在这里把本体与入口装上（幂等）。
XHY_BOOTSTRAPPED=0

# 一键脚本（bash <(curl ...)、wget|sh、sh install.sh）跑完后退出菜单，
# `xhy` 必须能用。以前只有 cmd_install 的 stage 2 会落地脚本本体，而无参数
# 运行走的是菜单，于是「装完了」其实什么都没装 —— 连 /usr/local/bin/xhy
# 都不存在。任何从非安装位置发起的运行，先在这里把本体与入口装上（幂等）。
# 统一安装路径：单文件永远直装到 /usr/local/bin/xhy（不再有 git 仓库 / 单文件
# 两套模式抢这个入口；旧软链由 reconcile_bin 在 install_self 里自动摘掉）。
bootstrap_self() {
    local src="${XHY_RUNNING:-}"
    # 已规范直装：入口就是正在运行的本体，且它不是软链 → 什么都不用做（顺手清孤儿）。
    # 注意判据是「字面同一路径」，不能只比 readlink -f：旧布局
    # /usr/local/bin/xhy -> /usr/local/lib/xray-hy/xhy 解析后同样相等，
    # 用解析值比较会永远跳过迁移，机器就永远停在旧路径上。
    if [[ -n "$src" ]] && [[ "$src" == "$XHY_SELF" ]] && [[ ! -L "$XHY_SELF" ]]; then
        _cleanup_legacy_self
        return 0
    fi
    # 仓库开发目录（XHY_DEV=1）：不往系统目录写，避免调试时被悄悄改写。
    # 仓库模式迁移到单文件由 `xhy update script` 显式完成。
    if [[ "${XHY_DEV:-0}" == "1" ]]; then
        return 0
    fi
    install_self
    create_symlink
    XHY_BOOTSTRAPPED=1
    return 0
}

# 是否已完成过完整安装。三样都在才算：Xray 二进制、INSTALLED 状态、命令入口。
# 半安装状态（比如 Xray 装了但 state 没写）会自动补一次完整安装。
xhy_is_installed() {
    [[ -x "$XRAY_BIN" ]] || return 1
    [[ -n "$(state_get INSTALLED '')" ]] || return 1
    [[ -x "${XHY_BINDIR:-/usr/local/bin}/xhy" ]] || return 1
    return 0
}

cmd_lang() {
    local v="${1:-}"
    case "${v,,}" in
        en|zh|auto|"") ;;
        *) die "用法: xhy lang [en|zh|auto]" ;;
    esac
    if [[ -z "$v" ]]; then
        # 这里要走 printf 过滤器：英文模式下这些中文提示同样不能变成方块。
        printf '当前语言 : %s（state: %s）\n' "$XHY_LANG_EFFECTIVE" "$(state_get XHY_LANG auto)"
        printf '  xhy lang en    强制英文（纯 ASCII；云 VNC 控制台中文是小方块时用）\n'
        printf '  xhy lang zh    强制中文\n'
        printf '  xhy lang auto  自动判定（默认；VNC 控制台英文 / SSH 中文）\n'
        printf '  单次强制：XHY_LANG=en xhy  或  XHY_ASCII=1 xhy\n'
        return 0
    fi
    state_set XHY_LANG "${v,,}"
    ok "已设置语言为 ${v,,}（下次运行生效；本次可用 XHY_LANG=${v,,} 立即切换）"
}

usage() {
    # 帮助是用户最需要读通的长文本，短语替换会把它切碎，所以单独写一份英文版。
    # 纯 ASCII，不走 xhy_t；中文版继续走原来的 xhy_t <<EOF。
    if [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]]; then
        cat <<EOF
xray-hy $XHY_VERSION - modular Xray deployment manager (Debian/Ubuntu, Alpine, RHEL)

Usage: xhy <command> [options]

  Install & check
    install                     Full init (script, deps, Xray, service, BBR, firewall)
    preflight                   Pre-install checks (ports/disk/kernel/network/deps)
    check                       Environment report
    version                     Show script version

  Node management
    add <mode> [--port N] [opts]  Add a node
    edit [mode] [port]            Edit a node; no args = pick by number
    list                          List nodes
    link [--all|--uri] [--qr] [--png FILE]  Export vless:// links; --qr prints a
                                            scannable QR for phone apps; --png
                                            writes a 0600 QR PNG (keeps secrets)
    link <mode> [port] [--qr] [--png FILE]  Same, for one node
    del [mode] [port]             Delete node; no args = pick by number
    menu                          Interactive menu

    mode: direct | tunnel | reality | xhttp | hy2
    add opts: --host --path --uuid --sni --target --domain --token --reality
              --masq --masq-proxy --up --down   (hy2 only)
              --scan [--scan-cidr CIDR] [--scan-refresh]   (reality only)
              --tfo auto|on|off            (reality/xhttp; auto = follow target)
    Default ports: direct 8080 / tunnel 10086 / reality 443 / xhttp 8081 / hy2 8443(UDP)
    hy2 uses Xray's built-in Hysteria2 inbound (v26.3.27+), self-signed cert + pinSHA256
    hy2 default masquerade is a static page; --masq-proxy proxies a real site
      (looks better, but unauthenticated traffic uses this host's bandwidth)

  Camouflage site auto-scan
    scan [CIDR]                 Scan this rack's subnet, show 3-5 candidates (cached)
    scan --require-tfo          Only TFO-capable sites; otherwise asks once
    scan --list                 Show cached candidates and scores
    scan --verify               Re-verify cached candidates, drop stale ones
    scan --refresh              Ignore cache and rescan
    scan --clear                Clear cache
    How it works: RealiTLScanner enumerates TLS 1.3 + h2 sites in a /24, each is
    validated with its real SNI (cert/redirect/CDN) and scored; the top 3-5 are
    shown for you to pick (scripted calls take the best score).
    TFO is display/filter only, never part of the score: by default we pick by
    quality (TFO-capable sites may still appear); with --require-tfo only
    TFO-capable ones remain. If the /24 (or cache) has no TFO-capable site it
    auto-widens to the /21 of the same rack and rescans once.
    Every candidate is labelled "TFO: yes / no" (live probe, not cached),
    including [ok] lines, the shortlist, scan --list and scan --verify.
    Results go to /etc/xray-hy/scan-cache.tsv (7 days); later REALITY nodes
    reuse it without rescanning. amd64 / arm64 only; other arches use the
    built-in region library.

  Camouflage site / REALITY terms (xhy target -> 6)
    target(dest)   Address the server connects to (IP:port or domain:port).
                   REALITY forwards unauthenticated probes there verbatim, so it
                   must be a real, stable, long-lived HTTPS site.
    SNI            Domain in the client TLS ClientHello; serverNames is Xray's
                   SNI allowlist and must be covered by the target certificate.
    Behind a CDN?  dest = origin IP, SNI stays the domain:
        xhy add reality --port 443 --target 1.2.3.4:443 --sni www.example.com
    Menu 9) -> 3) manual accepts the same form (1.2.3.4:443,sni=www.example.com);
    validation uses --resolve to hit that IP and verify the cert covers the name.
    Or just xhy scan: auto-scan this rack's subnet and pick the best site (cached).

  TFO (TCP Fast Open) - follows the target by default, can be overridden
    Xray's tcpFastOpen really works (accepts early data in SYN, answers
    cookiereq with a cookie). Whether to enable it depends on the target:
      target supports passive TFO -> auto enables it; probe sees the same
                                    SYN-ACK, and we save 1 RTT
      target does not support it  -> auto disables it; otherwise a probe sending
                                    a cookiereq SYN sees our tfo cookie while the
                                    real site sends none - trivially distinguishable
    auto probes with curl --tcp-fastopen x3 and checks TcpExtTCPFastOpenActive;
    the result is stored in the node env, so config rebuilds do not re-probe.
    --tfo on / off overrides. Clients follow the server: on->on, off->off.
    Note: the target carries no normal proxy traffic (REALITY only forwards
    unauthenticated probes), so its bandwidth/latency do not affect proxy speed;
    scanning does not shrink the candidate pool just to find TFO.

  Config
    config                      Routing / DNS / log menu (or set directly)
    config set KEY VALUE        Change a setting, see KEYs below
    snapshots                   List the 5 most recent full-state snapshots
    rollback [path]             Roll back the whole state
    target                      Camouflage site selection / validation
    firewall [apply|strict|off|status]   Dual-stack IPv4 + IPv6
    bbr [on|status]             Includes MPTCP off (CVE-2026-98432)

  Language / VNC console
    lang [en|zh|auto]           Switch to English when Chinese shows as boxes on
                                a cloud VNC console (pure ASCII output)
    XHY_LANG=en xhy <command>   Force English for one run; XHY_ASCII=1 is the same
    XHY_LANG=zh xhy <command>   Force Chinese for one run
    English mode guarantees printable ASCII; Chinese mode is byte-for-byte
    unchanged. auto checks LANG/TERM/charmap/tty: C locale, non-UTF-8 and
    console ttys (/dev/tty1..6, /dev/ttyS0) switch to English; ordinary
    UTF-8 SSH sessions (/dev/pts/N) stay Chinese. Use auto, NOT 'lang en',
    for a VNC-only English setting -- 'en' is persisted globally and also
    turns SSH output English.

  Version & update
    core [status|channel pinned|channel latest|channel vX.Y.Z|update [--force]]
    update [script|core|geodata|config|all]
    update geodata [--force] [--source loyalsoldier|official]
    update script --yes [--allow-major]   Non-interactive (major bump needs flag)

  Backup, export & disk
    backup [--out FILE]         Back up /etc/xray-hy (per-file SHA256 list)
    restore <file>              Verify then restore (auto rollback on failure)
    clean [backups|snapshots|tarballs|tmp|all|purge]  Drop old core backups / snapshots; purge = wipe ALL (before imaging)
                                A full root fs makes sshd unreachable while the
                                proxy keeps working; check `xhy check` disk line
                                tarballs = xhy backup output, tmp = xray-rollback.*
    export clash|singbox [--out F]  Export mihomo/Clash or sing-box configs

  Relay (entry -> landing) -- plaintext vless/tcp, security=none
    relay land --allow IP [--port N] [--uuid U]   Landing: inbound, only that source IP
    relay entry --to IP:PORT [--uuid U] [--categories a,b,c|ai|media|none] [--no-geoip-us]
                 [--no-fallback] [--no-tfo]        Entry: AI/US traffic -> landing
    relay status|test|export|reapply|del         Inspect / self-check / peer cmd / remove
    Hop is unencrypted: both ends are yours on a cloud backbone; client-to-site TLS
    is already end-to-end. --tls/--sni/--pin are retired no-ops (v1.11.0).
    Fallback is on: the balancer probes the landing host and switches to direct
    when unreachable. Open the cloud security group (inbound TCP <port>, entry IP).
    The relay survives xhy add/edit/del; reapply is only a fallback after a rollback.

  Service & uninstall
    service [start|stop|restart|status]
    uninstall                   Uninstall (optionally keep config)

config KEYs: BLOCK_BT BLOCK_PRIVATE BLOCK_CN BLOCK_ADS
             DNS_PROVIDER(cloudflare|quad9|dns-sb|system)
             LOG_LEVEL(warning|info|none) SSH_GUARD TARGET_REGION
             DUAL_STACK(on = new nodes listen on ::, off = 0.0.0.0)
EOF
        return 0
    fi
    xhy_t <<EOF
xray-hy $XHY_VERSION - 模块化 Xray 部署管理 (Debian/Ubuntu, Alpine, RHEL 系)

用法: xhy <命令> [选项]

  安装与检查
    install                     完整初始化（脚本本体、依赖、Xray、服务、BBR、防火墙）
    preflight                   安装前预检（端口/磁盘/内核/网络/依赖）
    check                       环境自检报告
    version                     显示脚本版本

  节点管理
    add <mode> [--port N] [选项] 添加节点
    edit [mode] [port]          编辑已有节点；省略参数时列出编号选择（回车=不改）
    list                        列出所有节点
    link [--all|--uri] [--qr] [--png FILE] 导出 vless:// 链接；--qr 打印可扫二维码
                                           （手机 App 直接导入）；--png 存成 0600
                                           二维码图片（含凭证，勿公开）
    link <mode> [port] [--qr] [--png FILE]  单个节点同上
    del [mode] [port]           删除节点；省略参数时列出编号选择
    menu                        交互式菜单

    mode: direct | tunnel | reality | xhttp | hy2
    add 选项: --host --path --uuid --sni --target --domain --token --reality
              --masq --masq-proxy --up --down   (hy2 专用)
              --scan [--scan-cidr CIDR] [--scan-refresh]   (reality 专用)
              --tfo auto|on|off            (reality/xhttp；auto=跟随伪装站，默认)
    默认端口: direct 8080 / tunnel 10086 / reality 443 / xhttp 8081 / hy2 8443(UDP)
    hy2 用 Xray 内置 Hysteria2 入站(v26.3.27+)，自签证书 + pinSHA256 链接
    hy2 默认 masquerade type=string（静态页）；--masq-proxy 改为反代真站，
      伪装性更好，但未认证流量会走本机带宽

  伪装站自动扫描
    scan [网段]                 扫本机机房网段，列出 3-5 个候选让你挑（结果缓存复用）
    scan --require-tfo          只列出支持被动 TFO 的候选；不给则交互询问一次
    scan --list                 查看缓存里的候选与打分
    scan --verify               复核缓存候选，剔除已失效的
    scan --refresh              忽略缓存重新扫描
    scan --clear                清除缓存
    原理: 用 RealiTLScanner 在 /24 里枚举 TLS 1.3 + h2 站点，再逐个用真实 SNI
    做证书/跳转/CDN 校验并打分，最后列出前 3-5 个候选由你选（脚本化调用
    自动取最高分）。TFO 只是展示/过滤项，不参与打分：不强制时按质量选，
    结果里也可能带支持 TFO 的站点；强制时只留支持 TFO 的。
    --require-tfo 在 /24（或缓存）里没找到时，会自动扩到同机房 /21 再扫一次。
    每个候选后面都标注「TFO 支持 / 不支持」（现场探测，不写进缓存），
    包括 [ok] 校验行、3-5 短名单、scan --list 与 scan --verify。
    结果记在 /etc/xray-hy/scan-cache.tsv（默认 7 天），此后再建 REALITY 节点
    直接复用，不会重复扫描。仅 amd64 / arm64 支持，其它架构回退内置地区库。

  伪装站 / REALITY 名词（xhy target 里输入 6 可随时查看）
    target(dest)  服务端主动去连的目的地址（IP:端口 或 域名:端口），未认证流量
                  原样转发到这里，所以必须是真实、稳定、长期存在的 HTTPS 站点。
    SNI           客户端握手时声明的域名；serverNames 是 Xray 里的 SNI 白名单，
                  必须被 target 的证书覆盖。
    目标站挂在 CDN 后面时，dest 要写「源站 IP」、SNI 仍写域名，例如：
        xhy add reality --port 443 --target 1.2.3.4:443 --sni www.example.com
    交互菜单 9) 伪装站 → 3) 手动指定 支持同一写法（1.2.3.4:443,sni=www.example.com），
    校验会用 --resolve 打该 IP，测证书是否真的覆盖这个域名。
    不想手挑就用 xhy scan：自动扫本机机房网段并选最优站点（结果缓存复用）。

  TFO（TCP Fast Open）— 默认跟随伪装站，可强制覆盖
    Xray 的 tcpFastOpen 实测确实生效（服务端能收 SYN 里的 early data、能给
    cookiereq 回 cookie）。但开不开要看伪装站：
      伪装站支持被动 TFO → auto 默认开，探测者看到的 SYN-ACK 一致，白拿 1 RTT
      伪装站不支持        → auto 默认关；否则探测者发一个带 cookiereq 的 SYN，
                            我们会回 tfo cookie、真实站点不回，一眼就能区分开
    auto 用 curl --tcp-fastopen 连打 3 次看内核 TcpExtTCPFastOpenActive 是否
    增长，判定结果写进节点配置，重建配置不会重复探测。--tfo on / off 强制覆盖。
    客户端默认跟随服务端：我们开它开、我们关它关。
    注：伪装站不承载正常代理流量（REALITY 只把未认证探测转发过去），它的带宽
    和延迟不影响代理上网速度；扫描不为凑 TFO 缩小候选池，先按质量选最优站。

  配置
    config                      路由/DNS/日志开关菜单（也可直接 set）
    config set KEY VALUE        直接改设置，见下方 KEY
    snapshots                   列出最近 5 份整套状态快照
    rollback [快照路径]         回滚整套状态（config + 节点 + 分片 + state）
    target                      伪装站选择 / 校验菜单
    firewall [apply|strict|off|status]   双栈 IPv4 + IPv6
    bbr [on|status]             含 MPTCP 关闭 (CVE-2026-98432)

  语言 / VNC 控制台
    lang [en|zh|auto]           中文在云 VNC 上显示成小方块时切英文（纯 ASCII）
    XHY_LANG=en xhy <命令>      单次强制英文；XHY_ASCII=1 同义
    XHY_LANG=zh xhy <命令>      单次强制中文
    英文模式下所有输出保证是可打印 ASCII；中文模式下输出逐字节不变。
    auto 会按 LANG/TERM/charmap/tty 判定：C locale、非 UTF-8、控制台 tty
    （/dev/tty1..6、/dev/ttyS0）自动切英文，普通 UTF-8 SSH（/dev/pts/N）保持中文。
    VNC 只想英文请用 auto，别用 lang en —— en 会全局持久化，把 SSH 也变英文。

  版本与更新
    core [status|channel pinned|channel latest|channel vX.Y.Z|update [--force]]
    update [script|core|geodata|config|all]
    update geodata [--force] [--source loyalsoldier|official]
    update script --yes [--allow-major]   非交互更新（跨主版本需 --allow-major）

  备份、导出与磁盘
    backup [--out FILE]              备份 /etc/xray-hy（内含逐文件 SHA256 清单）
    restore <备份文件>               校验清单后还原（先备份现状，失败自动回滚）
    clean [backups|snapshots|tarballs|tmp|all|purge]  清理旧核心二进制 / 旧快照 / 旧打包备份；purge 全清含凭证快照（做镜像前必用）
                                     根分区满时 sshd 会连不上、而代理仍在工作；
                                     xhy check 里有「磁盘余量」一行
                                     tarballs = xhy backup 产物，tmp = xray-rollback.* 残留
    export clash|singbox [--out F]   导出 mihomo/Clash 或 sing-box 节点配置

  中继 / relay（入口机 → 落地机，明文 vless/tcp，security=none）
    relay land --allow IP [--port N] [--uuid U]   落地端：开入站，只放行这一个源 IP
    relay entry --to IP:端口 [--uuid U] [--categories a,b,c|ai|media|none] [--no-geoip-us]
                [--no-fallback] [--no-tfo]        入口端：AI/美区流量 → 落地端
    relay status|test|export|reapply|del        查状态 / 自检 / 对端命令 / 移除
    这一跳不加密：两端自有、走云内网，客户端到目标站 TLS 已端到端。
    --tls / --sni / --pin 已停用（v1.11.0 起只留参数位兼容老脚本）。
    失联回落默认开：balancer 探活落地机，不可达时切 direct 出站。
    云安全组要单独放行（入方向 TCP <端口>，源只填入口机 IP）。
    改造后 relay 不会被 xhy add/edit/del 覆盖；reapply 只在从快照回滚后兜底用。

  服务与卸载
    service [start|stop|restart|status]
    uninstall                   卸载（可选保留配置）

config 的 KEY: BLOCK_BT BLOCK_PRIVATE BLOCK_CN BLOCK_ADS
               DNS_PROVIDER(cloudflare|quad9|dns-sb|system)
               LOG_LEVEL(warning|info|none) SSH_GUARD TARGET_REGION
               DUAL_STACK(on=新节点监听 :: 双栈，off=0.0.0.0)
EOF
}

default_port() {
    case "$1" in
        direct) echo 8080 ;; tunnel) echo 10086 ;; reality) echo 443 ;; xhttp) echo 8081 ;; hy2) echo 8443 ;;
        *) echo 0 ;;
    esac
}

cmd_install() {
    need_root
    detect_platform
    xhy_lang_banner
    printf '\n'
    platform_summary
    printf '\n'
    stage 1 7 "依赖检查与安装（这一步最慢；卡住多半是软件源，见文末提示）"
    ensure_deps
    stage 2 7 "安装脚本本体与命令入口"
    # bootstrap_self 在 main() 里已经把本体 + /usr/local/bin/xhy 落地了，
    # 别再下载/复制一遍；显式 `xhy install` 时仍完整执行。
    if [[ "${XHY_BOOTSTRAPPED:-0}" == "1" ]]; then
        ok "脚本本体已就位（本次启动已落地）"
    else
        install_self
        create_symlink
    fi
    stage 3 7 "创建数据目录"
    init_dirs
    if [[ -z "$(state_get DUAL_STACK '')" && -n "$(public_ip6 || true)" ]]; then
        state_set DUAL_STACK on
        ok "检测到 IPv6 出口，新节点默认双栈监听 (::)（xhy config set DUAL_STACK off 可改回）"
    fi
    local ver
    stage 4 7 "下载并校验 Xray"
    # 版本二选一：最新版功能全，但 >=26.9.8 的 REALITY 要求 MLKEM ClientHello，
    # sing-box / mihomo 客户端连不上（SagerNet/sing-box#4520）；钉死版没这问题。
    if confirm "安装最新版 Xray？(回车/n = 钉死 ${XHY_PINNED_VERSION}，sing-box/mihomo 客户端兼容性最好)" "n"; then
        xray_set_channel latest
    else
        xray_set_channel pinned
    fi
    ver="$(xray_resolve_version)"
    xray_install "$ver"
    stage 5 7 "安装服务与开机自启"
    install_xray_service

    stage 6 7 "内核网络优化与防火墙"
    if confirm "启用 BBR 与内核网络优化？" "y"; then
        state_set BBR_ENABLED on
        bbr_ensure || warn "BBR 未启用，可执行 xhy bbr on / xhy check 复查。"
    else
        state_set BBR_ENABLED off
        warn "已跳过 BBR（要启用请执行 xhy bbr on）"
    fi
    if confirm "配置防火墙（safe 模式：SSH 防爆破 + 放行节点端口，不改动现有规则）？" "y"; then
        state_set FIREWALL_MODE safe
        state_set SSH_GUARD on
        firewall_apply safe
    fi

    stage 7 7 "渲染配置并启动服务"
    rebuild_config
    xray_config_test || die "初始配置校验失败"
    svc_start "$SVC_XRAY" || die "Xray 启动失败，查看 $XHY_LOGDIR/xray.err"
    state_set INSTALLED "$(date -Is)"
    ok "安装完成。现在可用 xhy add reality 添加第一个节点，或直接输入 xhy 打开菜单。"
}

cmd_add_interactive() {
    local mode port host path sni target domain token
    local -a extra=()
    xhy_t <<'EOF'
  节点类型：
    1) direct   VLESS + WS 直连（明文，建议套 CDN / 反代）
    2) tunnel   VLESS + WS + Cloudflare Tunnel（不需要公网入站端口）
    3) reality  VLESS + REALITY + XTLS Vision
    4) xhttp    VLESS + XHTTP（可选叠加 REALITY）
    5) hy2      Hysteria2（UDP/QUIC，Xray 内置入站 + 自签证书）
EOF
    case "$(ask '选择类型' '3')" in
        1) mode=direct ;; 2) mode=tunnel ;; 3) mode=reality ;; 4) mode=xhttp ;; 5) mode=hy2 ;; *) return 0 ;;
    esac
    port="$(ask '监听端口' "$(default_port "$mode")")"
    valid_port "$port" || { err "端口不合法"; return 1; }
    local ip4 ip6
    ip4="$(public_ip || true)"
    ip6="$(public_ip6 || true)"
    host="$(ask '客户端连接地址(域名或 IP)' "${ip4:-$ip6}")"
    if [[ -n "$ip6" && -n "$ip4" ]]; then
        info "检测到双栈出口 (v6: $ip6)。想让客户端也能走 v6：xhy config set DUAL_STACK on，链接会自动附 IPv6 变体。"
    elif [[ -z "$ip4" && -n "$ip6" ]]; then
        info "仅检测到 IPv6 出口 ($ip6)，已用它作为默认连接地址。"
    fi
    path="$(ask '路径 (回车随机生成)' '')"

    local -a opts=(--host "$host")
    [[ -n "$path" ]] && opts+=(--path "$path")
    case "$mode" in
        reality)
            xhy_t <<'EOF'
  伪装站（target / dest）来源：
    1) 自动扫描本机机房网段，选最优站点（推荐；有缓存直接复用，不重复扫）
    2) 内置地区库（按 VPS 出口国家匹配）
    3) 手动指定 target / SNI
EOF
            case "$(ask '选择' '1')" in
                1)
                    opts+=(--scan)
                    if [[ -s "$SCANNER_CACHE" ]] && scanner_cache_valid; then
                        info "已有 $(scanner_cache_age_h) 小时前的扫描缓存（$(scanner_cache_count) 个候选）"
                        if confirm "忽略缓存重新扫描？" "n"; then opts+=(--scan-refresh); fi
                    else
                        info "扫描范围默认是本机公网 IP 所在 /24；无合格站点、或强制 TFO 时没找到支持 TFO 的站，会自动扩到 /21 再扫一次"
                    fi ;;
                3)
                    # 一条输入：host[:port][,sni=xxx]；不写 sni= 时 SNI 与 target 同名。
                    # 目标站在 CDN 后面时用「源站 IP + 域名 SNI」：1.2.3.4:443,sni=www.example.com
                    local t_in ts
                    xhy_t <<'EOF'
  输入示例：
    www.example.com                    域名，dest 与 SNI 相同
    1.2.3.4:443,sni=www.example.com   源站 IP + 域名 SNI（站点在 CDN 后时用这个）
    www.example.com:8443              非 443 端口
EOF
                    t_in="$(ask 'target')"
                    [[ -n "$t_in" ]] || return 0
                    ts="${t_in#*,sni=}"; [[ "$ts" == "$t_in" ]] && ts=""
                    t_in="${t_in%%,*}"
                    [[ "$t_in" == *:* ]] || t_in="${t_in}:443"
                    if is_ip_literal "${t_in%%:*}" && [[ -z "$ts" ]]; then
                        err "target 是 IP 时必须加 ,sni=域名（dest 用 IP、SNI 用域名）"
                        return 1
                    fi
                    opts+=(--target "$t_in" --sni "${ts:-${t_in%%:*}}") ;;
                *)
                    info "使用内置地区库（conf/targets.tsv）..." ;;
            esac ;;
        xhttp)
            if confirm "叠加 REALITY（无需证书）？" "n"; then
                extra+=(--reality)
                if confirm "自动扫描本机机房网段挑伪装站？（n = 用内置地区库）" "y"; then
                    extra+=(--scan)
                fi
            fi ;;
        tunnel)
            domain="$(ask 'Cloudflare 公开主机名' '')"
            token="$(ask 'Tunnel Token (回车复用已保存的)' '')"
            opts+=(--domain "$domain")
            [[ -n "$token" ]] && opts+=(--token "$token") ;;
        hy2)
            opts+=(--sni "$(ask 'SNI / 证书 CN' 'www.bing.com')")
            if confirm "自定义伪装站 URL？" "n"; then
                opts+=(--masq "$(ask '伪装站 URL' 'https://www.bing.com/')")
            fi
            # 默认静态页：proxy 模式被扫到未认证流量时会拿本机带宽替真站转发。
            if confirm "改为反代真站（更像，但走本机带宽）？" "n"; then
                opts+=(--masq-proxy)
            fi
            if confirm "设置 Brutal 带宽上限？" "n"; then
                opts+=(--up "$(ask '上行 (如 100mbps)' '100mbps')" --down "$(ask '下行' '300mbps')")
            fi ;;
    esac
    node_add "$mode" "$port" "${opts[@]}" "${extra[@]}"
}

cmd_add() {
    if (( $# == 0 )); then cmd_add_interactive; return; fi
    local mode="$1" port="" opts=()
    shift
    port="$(default_port "$mode")"
    while (( $# > 0 )); do
        case "$1" in
            --port)   port="$2"; shift 2 ;;
            --host|--path|--uuid|--sni|--target|--domain|--token|--masq|--up|--down|--scan-cidr|--tfo)
                opts+=("$1" "$2"); shift 2 ;;
            --reality|--scan|--scan-refresh|--masq-proxy) opts+=("$1"); shift ;;
            *) die "未知参数: $1（见 xhy --help）" ;;
        esac
    done
    valid_port "$port" || die "端口不合法: $port"
    node_add "$mode" "$port" "${opts[@]}"
}

# xhy scan [网段] [--refresh|--list|--verify|--clear]
cmd_scan() {
    local cidr="" refresh=0 mode="run" best st ss sl require=0
    while (( $# > 0 )); do
        case "$1" in
            --refresh) refresh=1; shift ;;
            --list)    mode="list"; shift ;;
            --clear)   mode="clear"; shift ;;
            --verify)  mode="verify"; shift ;;
            --require-tfo) require=1; shift ;;
            --cidr)    cidr="${2:?--cidr 需要网段}"; shift 2 ;;
            -*)        die "未知参数: $1（用法: xhy scan [网段] [--refresh|--list|--verify|--clear|--require-tfo]）" ;;
            *)         cidr="$1"; shift ;;
        esac
    done
    case "$mode" in
        list)   scanner_cache_show ;;
        clear)  scanner_cache_clear ;;
        verify) scanner_cache_verify ;;
        run)
            local -a args=()
            if (( refresh == 1 )); then args+=(--refresh); fi
            if [[ -n "$cidr" ]]; then args+=(--cidr "$cidr"); fi
            # 交互式问一次「是否必须 TFO」；显式给了 flag 或非 tty 时跳过。
            if (( require == 0 )) && [[ -t 0 ]]; then
                printf '是否只选支持 TFO 的伪装站？(y/N，回车=不强制): ' >&2
                local ans=""
                if { read -r ans < /dev/tty; } 2>/dev/null; then :; else ans=""; fi
                printf '\n' >&2
                if [[ "$ans" == "y" || "$ans" == "Y" ]]; then require=1; fi
            fi
            if (( require == 1 )); then args+=(--require-tfo); fi
            if best="$(scanner_pick ${args[@]+"${args[@]}"})"; then
                read -r st ss sl <<<"$best"
                printf '\n最优伪装站: target=%s  SNI=%s（来源 %s）\n\n' "$st" "$ss" "$sl"
                printf '  直接建节点（用缓存，不再扫描）:\n'
                printf '    xhy add reality --port 443 --target %s --sni %s\n\n' "$st" "$ss"
                printf '  或让它自己挑（缓存有效期内同样不重扫）:\n'
                printf '    xhy add reality --port 443 --scan\n'
            else
                if (( require == 1 )); then
                    err "自动扫描失败：/24 与 /21 里都没有支持被动 TFO 的候选"
                    err "可去掉 --require-tfo 按质量选，或 xhy scan --cidr <其它网段> --require-tfo"
                    err "也可改用 xhy target → 2) 指定地区，或 3) 手动指定"
                else
                    err "自动扫描失败；可改用 xhy target → 1) 内置地区库，或 3) 手动指定"
                fi
                return 1
            fi ;;
    esac
}

cmd_config_set() { config_transaction _cmd_config_set "$@"; }

_cmd_config_set() {
    local key="$1" val="$2"
    case "$key" in
        BLOCK_BT|BLOCK_PRIVATE|BLOCK_CN|BLOCK_ADS|SSH_GUARD|DUAL_STACK|ACCESS_LOG)
            [[ "$val" == "on" || "$val" == "off" ]] || die "$key 只能是 on/off" ;;
        DNS_PROVIDER)
            [[ "$val" =~ ^(cloudflare|quad9|dns-sb|system)$ ]] || die "DNS_PROVIDER 值不合法" ;;
        LOG_LEVEL)
            [[ "$val" =~ ^(warning|info|debug|none)$ ]] || die "LOG_LEVEL 值不合法" ;;
        TARGET_REGION) ;;
        *) die "未知设置项: $key" ;;
    esac
    # Snapshot before the setting changes: a snapshot should always represent
    # the state you had *before* this command, otherwise it cannot undo it.
    snapshot_state
    state_set "$key" "$val" || return 1
    XHY_SKIP_SNAPSHOT=1 node_rebuild_all || return 1
    if [[ "$key" == "SSH_GUARD" && "$(state_get FIREWALL_MODE off)" != off ]]; then
        firewall_apply "$(state_get FIREWALL_MODE safe)" || return 1
    fi
    ok "$key=$val"
}

cmd_config_menu() {
    while true; do
        printf '\n当前配置（改动会立即重建并校验配置）：\n'
        printf '  1) BT 阻断          %s\n' "$(state_get BLOCK_BT on)"
        printf '  2) 私网地址阻断     %s\n' "$(state_get BLOCK_PRIVATE on)"
        printf '  3) 回国 IP 阻断     %s\n' "$(state_get BLOCK_CN off)"
        printf '  4) 广告域名阻断     %s\n' "$(state_get BLOCK_ADS off)"
        printf '  5) SSH 防爆破       %s\n' "$(state_get SSH_GUARD on)"
        printf '  6) DoH              %s\n' "$(state_get DNS_PROVIDER cloudflare)"
        printf '  7) 日志级别         %s\n' "$(state_get LOG_LEVEL warning)"
        printf '  8) 伪装站地区       %s\n' "$(target_region)"
        printf '  9) 双栈监听         %s\n' "$(state_get DUAL_STACK off)"
        printf '  0) 返回\n'
        case "$(ask '选择' '0')" in
            1) cmd_config_set BLOCK_BT "$([[ "$(state_get BLOCK_BT on)" == on ]] && echo off || echo on)" ;;
            2) cmd_config_set BLOCK_PRIVATE "$([[ "$(state_get BLOCK_PRIVATE on)" == on ]] && echo off || echo on)" ;;
            3) cmd_config_set BLOCK_CN "$([[ "$(state_get BLOCK_CN off)" == on ]] && echo off || echo on)" ;;
            4) cmd_config_set BLOCK_ADS "$([[ "$(state_get BLOCK_ADS off)" == on ]] && echo off || echo on)" ;;
            5) cmd_config_set SSH_GUARD "$([[ "$(state_get SSH_GUARD on)" == on ]] && echo off || echo on)" ;;
            6) cmd_config_set DNS_PROVIDER "$(ask 'cloudflare/quad9/dns-sb/system' 'cloudflare')" ;;
            7) cmd_config_set LOG_LEVEL "$(ask 'warning/info/debug/none' 'warning')" ;;
            8) target_menu ;;
            9) cmd_config_set DUAL_STACK "$([[ "$(state_get DUAL_STACK off)" == on ]] && echo off || echo on)" ;;
            0) return 0 ;;
        esac
    done
}

cmd_link() {
    local qr=0 png="" want="" f a n=0 cnt=0
    local -a pos=()
    while (($#)); do
        a="$1"
        case "$a" in
            --qr)     qr=1; shift ;;
            --png)    png="${2:?--png 需要文件路径}"; qr=1; shift 2 ;;
            --uri)    want="--uri"; shift ;;
            --all)    want="--all"; shift ;;
            --*)      die "未知参数: $a" ;;
            *)        pos+=("$a"); shift ;;
        esac
    done
    LINK_QR="$qr"; LINK_QR_OUT="$png"; LINK_QR_MULTI=0
    # --uri 只出链接文本，给脚本 / 剪贴板用，不掺二维码。
    if [[ "$want" == "--uri" ]]; then
        while IFS= read -r f; do
            link_uri "$f"; n=1
        done < <(link_node_files)
        (( n == 1 )) || warn "暂无节点，先用 xhy add 添加一个。"
        return 0
    fi
    if (( ${#pos[@]} == 0 )); then
        # 全节点；--png 时多节点各写一份带 MODE_PORT 后缀的 PNG。
        cnt="$(link_node_files | wc -l | tr -d ' ')"
        (( cnt > 1 )) && [[ -n "$png" ]] && LINK_QR_MULTI=1
        link_all
        return 0
    fi
    # link <mode> [port] [--qr] [--png FILE]（标志可放任意位置）
    local mode="${pos[0]}" port=""
    (( ${#pos[@]} > 1 )) && port="${pos[1]}"
    f="$(node_file "$mode" "$port")"
    [[ -f "$f" ]] || die "节点不存在: ${mode}_${port}"
    link_from_env "$f"
}

cmd_uninstall() {
    need_root
    warn "这将停止 Xray / cloudflared 服务并移除 xray-hy 的开机项与防火墙链。"
    confirm "确定卸载？" "n" || { info "已取消"; return 0; }
    svc_stop "$SVC_CF"; svc_stop "$SVC_XRAY"
    svc_disable "$SVC_CF"; svc_disable "$SVC_XRAY"
    remove_cf_service 2>/dev/null || true
    firewall_off
    rm -f /etc/systemd/system/xray-hy.service /etc/systemd/system/xray-hy-firewall.service \
          /etc/init.d/xray-hy /etc/init.d/xray-hy-firewall \
          /usr/local/lib/xray-hy/tunnel-run /usr/local/bin/xhy \
          "$XHY_SELF" /etc/sysctl.d/90-xray-hy.conf /etc/modules-load.d/xray-hy.conf
    # 扫描器是下载来的独立工具，不在 git 工作树里，卸载时单独清。
    rm -rf "$XHY_TOOLS_DIR"
    # 仓库内运行时 XHY_APP_DIR 就是工作树：只删入口，不碰 conf/ 和目录本身。
    if [[ "${XHY_DEV:-0}" != "1" ]]; then
        rm -rf "$XHY_APP_DIR/conf"
        rmdir "$XHY_APP_DIR" 2>/dev/null || true
    fi
    [[ "$XHY_INIT" == "systemd" ]] && systemctl daemon-reload
    if confirm "同时删除 Xray 二进制与所有节点配置/凭证？" "n"; then
        rm -f "$XRAY_BIN" "$CF_BIN"
        rm -rf "$XRAY_ASSET" "$XHY_ETC"
        ok "配置与凭证已删除"
    else
        ok "已保留 $XHY_ETC（内含节点凭证，权限 0600/0700）"
    fi
    ok "卸载完成"
}

cmd_menu() {
    xhy_lang_banner
    while true; do
        printf '\n============ xray-hy %s ============\n' "$XHY_VERSION"
        printf '  %s / %s / Xray %s / 节点 %s 个\n' "$XHY_DISTRO" "$XHY_INIT" "$(xray_installed_version)" "$(node_count)"
        xhy_t <<'EOF'
  ---- 节点 ----
   1) 添加节点               2) 编辑节点
   3) 节点列表               4) 导出分享链接
   5) 删除节点
  ---- 系统 ----
   6) 完整安装 / 重装        7) 环境自检
   8) 配置（路由/DNS/日志）  9) 伪装站
  10) 防火墙                11) BBR / 内核
  ---- 维护 ----
  12) 服务管理              13) Xray 版本通道
  14) 更新                  15) 卸载
  16) 备份 / 恢复
   0) 退出
EOF
        case "$(ask '选择' '0')" in
            1) cmd_add_interactive ;;
            2) node_edit ;;
            3) node_list; ask '按回车继续' '' ;;
            4) link_all; ask '按回车继续' '' ;;
            5) if node_pick; then
                   if confirm "确认删除节点 ${MODE}_${PORT}？恢复需 xhy rollback" "n"; then
                       node_del "$MODE" "$PORT"
                   fi
               fi ;;
            6) cmd_install ;;
            7) self_check ;;
            8) cmd_config_menu ;;
            9) target_menu ;;
           10) local fa
               fa="$(ask 'apply / strict / off / status' 'status')"
               case "$fa" in
                   apply)  firewall_apply safe ;;
                   strict) warn "strict 会丢弃除 SSH 与节点端口外的所有入站连接。"
                           if confirm "确认？" "n"; then firewall_apply strict; fi ;;
                   off)    firewall_off ;;
                   *)      firewall_status ;;
               esac ;;
           11) if [[ "$(ask 'on / status' 'status')" == "on" ]]; then tune_bbr; else bbr_status; fi ;;
           12) local sa
               sa="$(ask 'start / stop / restart / status' 'status')"
               case "$sa" in
                   start|stop|restart) "svc_$sa" "$SVC_XRAY" ;;
                   *) svc_status "$SVC_XRAY" ;;
               esac ;;
           13) core_status
               local ch; ch="$(ask 'pinned / latest / vX.Y.Z（回车不改）' '')"
               if [[ -n "$ch" ]]; then xray_set_channel "$ch"; core_status; fi ;;
           14) local ua; ua="$(ask 'all / script / core / geodata / config' 'all')"
               case "$ua" in
                   all) update_all ;; script) update_script ;; core) update_core ;;
                   geodata) shift; update_geodata "$@" ;; config) update_config ;;
               esac ;;
           15) cmd_uninstall; return 0 ;;
           16) local ba
               ba="$(ask 'backup / restore / clean（清理旧备份释放磁盘）' 'backup')"
               case "$ba" in
                   backup) backup_create ;;
                   restore) backup_restore "$(ask '备份文件路径' '')" ;;
                   clean)  cmd_clean all ;;
                   *) warn "只支持 backup / restore / clean" ;;
               esac ;;
            0) return 0 ;;
        esac
    done
}

main() {
    # 无参数 = 一键入口：没装过就自动完整安装（含脚本本体与 xhy 命令），
    # 装过就进菜单。显式 `xhy menu` / `xhy install` 保持原语义。
    local cmd="${1:-auto}"
    [[ $# -gt 0 ]] && shift
    xhy_lang_init
    xhy_install_output_filters
    case "$cmd" in
        --help|-h|help) usage; return 0 ;;
        --version|version) printf 'xray-hy %s (build %s)\n' "$XHY_VERSION" "$XHY_BUILD"; return 0 ;;
    esac

    need_root
    detect_platform
    acquire_lock
    trap release_lock EXIT

    # 任何从非安装位置发起的运行都先把本体 + /usr/local/bin/xhy 落地。
    bootstrap_self

    case "$cmd" in
        auto)
            # 仓库开发入口永远进菜单，别让本地 ./xhy 触发完整安装。
            if [[ "${XHY_DEV:-0}" == "1" ]] || xhy_is_installed; then
                cmd_menu
            else
                cmd_install || return 1
                if [[ -t 0 ]]; then
                    cmd_menu
                else
                    info "非交互环境：安装完成，下次直接运行 xhy 即可打开菜单。"
                fi
            fi ;;
        lang)       cmd_lang "$@" ;;
        install)    cmd_install ;;
        preflight)  preflight_check ;;
        check)      self_check ;;
        menu|--menu) cmd_menu ;;
        add)        cmd_add "$@" ;;
        list)       node_list ;;
        link)       cmd_link "$@" ;;
        export)     cmd_export "$@" ;;
        backup)     backup_create "$@" ;;
        restore)    backup_restore "${1:?用法: xhy restore <备份文件>}" ;;
        del)        if [[ -z "${1:-}" ]]; then
                        # 不带参数：列出节点编号让人选，避免盲猜 mode/port
                        if node_pick; then
                            if confirm "确认删除节点 ${MODE}_${PORT}？恢复需 xhy rollback" "n"; then
                                node_del "$MODE" "$PORT"
                            fi
                        fi
                    else
                        node_del "${1:?需要模式}" "${2:?需要端口}"
                    fi ;;
        config)     if [[ "${1:-}" == "set" ]]; then cmd_config_set "${2:?需要 KEY}" "${3:?需要 VALUE}";
                    else cmd_config_menu; fi ;;
        snapshots)  list_snapshots ;;
        rollback)   rollback_config "${1:-}" ;;
        target)     target_menu ;;
        edit)       node_edit "$@" ;;
        clean)      cmd_clean "$@" ;;
        relay)      cmd_relay "$@" ;;
        scan)       cmd_scan "$@" ;;
        firewall)   case "${1:-status}" in
                        # --quiet is passed by the boot unit; forward it so boot
                        # logs stay clean.
                        apply)  firewall_apply safe "${2:-}" ;;
                        strict) firewall_apply strict ;;
                        off)    firewall_off ;;
                        *)      firewall_status ;;
                    esac ;;
        bbr)        case "${1:-status}" in
                        on) state_set BBR_ENABLED on; bbr_ensure || warn "BBR 未启用，可执行 xhy check 复查。" ;;
                        *)  bbr_status ;;
                    esac ;;
        core)       case "${1:-status}" in
                        status)  core_status ;;
                        channel) xray_set_channel "${2:?需要 pinned/latest/vX.Y.Z}"; core_status ;;
                        update)  shift; update_core "$@" ;;
                        *) die "用法: xhy core [status|channel <值>|update [--force]]" ;;
                    esac ;;
        update)     case "${1:-all}" in
                        # `xhy update`（不带子命令）命中默认的 all 时 $# 已经是 0，
                        # 无条件 shift 会在 set -Eeuo pipefail 下返回 1 直接终止脚本。
                        # 只有确实存在子命令参数时才消费它。
                        all) if (( $# )); then shift; fi; update_all "$@" ;;
                        _continue) update_continue "${2:-}" ;;
                        script) shift; update_script "$@" ;;
                        core) shift; update_core "$@" ;;
                        geodata) shift; update_geodata "$@" ;; config) update_config ;;
                        *) die "用法: xhy update [all|script [--yes] [--allow-major]|core [--force]|geodata [--force] [--source ...]|config]" ;;
                    esac ;;
        service)    case "${1:-status}" in
                        start|stop|restart) "svc_$1" "$SVC_XRAY" ;;
                        status) svc_status "$SVC_XRAY" ;;
                        *) die "用法: xhy service [start|stop|restart|status]" ;;
                    esac ;;
        uninstall)  cmd_uninstall ;;
        *)          err "未知命令: $cmd"; usage; return 1 ;;
    esac
}

main "$@"
