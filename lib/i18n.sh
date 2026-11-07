#!/usr/bin/env bash
# xray-hy / 输出语言层。
#
# 为什么需要它：阿里云 / 腾讯云的网页 VNC 控制台只有一套 ASCII 字体，UTF-8
# 中文能正确解码但没有字形，全部显示成「小方块」。脚本本身改不了终端字体，
# 只能保证在这种环境下输出的每一个字节都是可打印 ASCII。
#
#   XHY_LANG=en / XHY_ASCII=1   强制英文（纯 ASCII，VNC 可用）
#   XHY_LANG=zh                 强制中文
#   xhy lang en|zh|auto         写进 state.env，之后每次运行沿用
#   auto（默认）                按 LANG/TERM/charmap 判定：控制台终端、C locale、
#                              非 UTF-8 一律切英文；普通 UTF-8 SSH 终端保持中文
#
# 实现方式：默认（中文）模式下 xhy_t 是恒等变换，离线测试与原有输出逐字节一致；
# 只有英文模式才启用 printf 过滤器。这样不用改散落在十几个 lib 里的几百条
# 中文文案，也不会把配置 / JSON / 分享链接这类纯 ASCII 数据碰坏。

# 中文 -> 英文短语表。必须按「长词在前」排，否则「不支持」会被「支持」先拆开。
# 不带 declare：本文件是在 load_libs() 函数内被 source 的，显式 declare 会创建
# 局部变量，函数返回后数组就丢了（同一个坑 scanner.sh 的 XHY_TFO_CACHE 踩过）。
XHY_T_ZH=(
    "扫描范围默认是本机公网 IP 所在 /24；无合格站点、或强制 TFO 时没找到支持 TFO 的站，会自动扩到 /21 再扫一次" "当前网段内没有支持被动 TFO 的候选（每个站点后已标注 TFO 结果）；将自动扩大到 /21 再扫一次" "安装完成。现在可用 xhy add reality 添加第一个节点，或直接输入 xhy 打开菜单。"
    "  xhy lang en    强制英文（纯 ASCII；云 VNC 控制台中文是小方块时用）" "已按新的端口 / SNI 重签 Hysteria2 证书，客户端的 pinSHA256 需要更新" "节点参数已写入但未生效，可用 xhy snapshots + xhy rollback 回退"
    "TFO 只省首连 1 个 RTT，伪装站又不承载正常代理流量，不值得为它牺牲站点质量。" "  单次强制：XHY_LANG=en xhy  或  XHY_ASCII=1 xhy" "当前没有 REALITY 节点，新伪装站已记为默认 target，下次新建节点会用"
    "现在用 xhy add reality 添加第一个节点，或输入 xhy 打开菜单" "缓存里没有支持被动 TFO 的站点；自动扩大网段再扫一次（不重复扫同一 /24）" "  xhy lang auto  按终端 / locale 自动判定（默认）"
    "TFO auto/on/off（auto = 按新 target 重新探测）" "  10) 防火墙                11) BBR / 内核" "  12) 服务管理              13) Xray 版本通道"
    "1) 自动扫描本机机房网段，选最优站点（推荐；有缓存直接复用，不重复扫）" "（safe 模式：SSH 防爆破 + 放行节点端口，不改动现有规则）" "   3) 节点列表               4) 导出分享链接"
    "本机网段（/24 与同机房 /21）都没有支持被动 TFO 的站点。" "自动扫描没有找到可用站点，可改用 1) 按地区，或 3) 手动指定" "TLS 1.3 / H2 / 无跳转 / 非 CDN（源站直连）"
    "   1) 添加节点               2) 编辑节点" "  14) 更新                  15) 卸载" "  7) 扫描本机机房网段挑站（可强制 TFO，可替换已有节点）"
    "是否只选支持 TFO 的伪装站？(y/N，回车=不强制): " "；scanner_pick 会自动扩大到 /21 再扫一次。" "   6) 完整安装 / 重装        7) 环境自检"
    "非交互环境：安装完成，下次直接运行 xhy 即可打开菜单。" "候选伪装站（按质量排序；TFO=目标是否支持被动 TFO）" "选哪个 \[1-%d\]（回车=1，0=自动取最高分）: "
    "尚未安装 Xray，请先运行: xhy install" "（未强制 TFO；列表里也可能含支持 TFO 的站点）" "   8) 配置（路由/DNS/日志）  9) 伪装站"
    "shortId（输入 new 重新生成，客户端需同步）" "编辑已有节点；省略参数时列出编号选择（回车=不改）" "伪装站 target（IP:端口 或 域名:端口）"
    "每个候选后面都标注「TFO 支持 / 不支持」" "选择地区编号（也可直接输入地区代码，回车取消）" "替换哪些（all / 1,3 / 回车=不换）"
    "（这一步最慢；卡住多半是软件源，见文末提示）" "（下次运行生效；本次可用 XHY_LANG=" "2) 内置地区库（按 VPS 出口国家匹配）"
    "SNI（target 是 IP 时必填域名）" "去掉 --require-tfo 按质量选" "伪装站（target / dest）来源："
    "  xhy lang zh    强制中文" "里没有支持被动 TFO 的站点，自动扩大到" "  2) 指定地区（列出现有地区与候选数）"
    "Brutal 上行 Mbps（空=不启用）" "Brutal 下行 Mbps（空=不启用）" "只有 REALITY 节点有伪装站（当前 "
    "伪装站（target / dest）来源" "3) 手动指定 target / SNI" "内置地区库（按 VPS 出口国家匹配）"
    "  已存在的 REALITY 节点：" "UUID（输入 new 重新生成）" "伪装模式 string/proxy"
    "自动扫描本机机房网段，选最优站点" "脚本本体已就位（本次启动已落地）" "（已按「必须支持 TFO」过滤）"
    "改为不强制 TFO、按质量重选？" "已完成 %s 个节点的伪装站替换" "客户端连接地址(域名或 IP)"
    "（回车=1，0=自动取最高分）" "前 个候选都不支持被动 TFO" "SNI（改这个会重签自签证书）"
    "或换 --cidr 网段再试" "可改用 xhy target" "最优伪装站: target="
    "固定下来（新建节点直接用）？" "没有匹配的编号，未做任何替换" "配置（路由/DNS/日志）"
    "  16) 备份 / 恢复" "保持原 target 不变" "建议套 CDN / 反代"
    "---- 节点 ----" "---- 系统 ----" "---- 维护 ----"
    "上面每个站点后已标注结果" "选择类型 \[3\]: " "直接回车 = 保持原值。"
    "连接地址（域名或 IP）" "扫描范围默认是本机公网" "扫描完成但没有可用站点"
    "非 CDN（源站直连）" "安装脚本本体与命令入口" "路径 (回车随机生成)"
    "缓存里的候选都已失效" "内核网络优化与防火墙" "选择 \[0\]: "
    "选择 \[1\]: " "   5) 删除节点" "当前 target:"
    "没有新的伪装站可应用" "不需要公网入站端口" "完整安装 / 重装"
    "Xray 版本通道" "尚未安装 Xray" "安装服务与开机自启"
    "渲染配置并启动服务" "每个候选后面都标注" "BBR / 内核"
    "支持被动 TFO" "无结果会自动扩到" "   0) 退出"
    "指纹 / TFO" "备份 / 恢复" "客户端连接地址"
    "依赖检查与安装" "当前语言 : " "TFO 不支持"
    "结果已缓存: " "个可用候选（共" "导出分享链接"
    "内核网络优化" "自动扫描失败" "创建数据目录"
    "已设置语言为" "TFO 支持" "使用扫描缓存"
    "扫描伪装站" "结果已缓存" "最优伪装站"
    "直接建节点" "候选伪装站" "按质量排序"
    "个去重候选" "下载并校验" "安装最新版"
    "配置防火墙" "不写入缓存" "不参与打分"
    "节点类型：" "立即切换）" "验证完成："
    "地区已设为" "将要修改：" "确认应用？"
    "服务管理" "添加节点" "节点列表"
    "删除节点" "环境自检" "版本通道"
    "重新扫描" "完整安装" "手动指定"
    "自动扫描" "随机生成" "监听端口"
    "节点类型" "选择类型" "必须支持"
    "现场探测" "再扫一次" "本网段前"
    "没有改动" "防火墙" "伪装站"
    "不支持" "已清除" "已过期"
    "已失效" "已跳过" "未启用"
    "未安装" "已安装" "签发者"
    "小时前" "个候选" "不合法"
    "未强制" "列表里" "个站点"
    "硬过滤" "同机房" "小方块"
    "控制台" "选择 " "选哪个"
    "支持" "握手" "分数"
    "缓存" "候选" "扫描"
    "校验" "复核" "查看"
    "清除" "列出" "刷新"
    "扩容" "扩大" "节点"
    "端口" "地址" "域名"
    "证书" "流量" "探测"
    "最优" "质量" "结果"
    "来源" "添加" "删除"
    "导出" "列表" "配置"
    "路由" "日志" "系统"
    "维护" "更新" "卸载"
    "备份" "恢复" "重装"
    "自检" "服务" "管理"
    "环境" "内核" "权限"
    "脚本" "入口" "启用"
    "开启" "关闭" "使用"
    "当前" "选择" "返回"
    "继续" "确认" "确定"
    "取消" "输入" "示例"
    "格式" "说明" "提示"
    "警告" "错误" "失败"
    "成功" "完成" "安装"
    "下载" "检查" "启动"
    "停止" "重启" "状态"
    "默认" "有效" "保留"
    "剔除" "需要" "运行"
    "命令" "参数" "文件"
    "目录" "版本" "缺少"
    "无法" "必须" "可选"
    "回车" "路径" "退出"
    "只选" "中文" "英文"
    "终端"
)

XHY_T_EN=(
    "Default scan range is this host's /24; with no usable site (or no TFO-capable site when required) it auto-widens to /21 and rescans" "No TFO-capable candidate in this subnet (each site above is labelled); auto-widening to /21 and rescanning" "Install complete. Run xhy add reality to add the first node, or just xhy for the menu."
    "  xhy lang en    force English (pure ASCII; use when a cloud VNC shows boxes)" "Hysteria2 cert re-issued for the new port/SNI; update pinSHA256 on clients" "Node updated but not active; use xhy snapshots + xhy rollback to revert"
    "TFO only saves 1 RTT on the first connect and the target carries no proxy traffic; not worth trading site quality for." "  one-shot: XHY_LANG=en xhy   or  XHY_ASCII=1 xhy" "No REALITY node yet; the new site is saved as the default target for the next node"
    "Now run xhy add reality to add the first node, or just xhy for the menu" "No TFO-capable site in cache; auto-widening the subnet to rescan (not the same /24)" "  xhy lang auto  detect from terminal / locale (default)"
    "TFO auto/on/off (auto = re-probe the new target)" "  10) Firewall              11) BBR / kernel" "  12) Service               13) Xray channel"
    "1) Auto-scan this datacenter subnet and pick the best site (recommended; cache reused, no rescan)" " (safe mode: SSH brute-force guard + allow node ports, no changes to existing rules)" "   3) List nodes             4) Export links"
    "No passive-TFO site in this subnet (/24) or the same rack (/21)." "Scan found no usable site; use 1) by region or 3) specify manually" "TLS 1.3 / H2 / no redirect / not CDN (origin direct)"
    "   1) Add node               2) Edit node" "  14) Update                15) Uninstall" "  7) Scan this rack's subnet (optional TFO, optional node retarget)"
    "Only TFO-capable sites? (y/N, Enter = no): " "; scanner_pick auto-widens to /21 and rescans." "   6) Full install           7) Self check"
    "Non-interactive shell: install complete, run xhy later to open the menu." "Candidate sites (by quality; TFO = target supports passive TFO)" "Pick [1-%d] (Enter=1, 0=best score): "
    "Xray is not installed, run: xhy install" " (TFO not required; the list may still contain TFO sites)" "   8) Config (routing/DNS)   9) Camouflage site"
    "shortId (type new to regenerate; clients must update)" "Edit a node; no args = pick by number (Enter = keep)" "Target site (IP:port or domain:port)"
    "each candidate is labelled TFO: yes / no" "Region number (or code, Enter = cancel)" "Replace which (all / 1,3 / Enter = none)"
    " (this is the slowest step; stalls are usually the package mirror)" " (effective next run; use XHY_LANG=" "2) Built-in region library (match VPS egress country)"
    "SNI (required when target is an IP)" "drop --require-tfo to pick by quality" "Camouflage site (target / dest) source:"
    "  xhy lang zh    force Chinese" " has no TFO-capable site, auto-widening to " "  2) Pick a region (shows regions and candidate counts)"
    "Brutal up Mbps (empty = off)" "Brutal down Mbps (empty = off)" "Only REALITY nodes have a target site (current "
    "Camouflage site (target / dest) source" "3) Specify target / SNI manually" "Built-in region library (match VPS egress country)"
    "  Existing REALITY nodes:" "UUID (type new to regenerate)" "Masquerade mode string/proxy"
    "Auto-scan this datacenter subnet and pick the best site" "Script and command entry already installed (this run)" " (filtered: TFO required)"
    "Retry without requiring TFO (pick by quality)? " "%s node(s) retargeted" "Client address (domain or IP)"
    "(Enter=1, 0=best score)" "no TFO-capable candidates" "SNI (changing it re-issues the self-signed cert)"
    "or try another --cidr subnet" "fall back to xhy target" "Best camouflage site: target="
    "Pin it (new nodes use it)? " "No matching number; nothing replaced" "Config (routing/DNS/log)"
    "  16) Backup / restore" "Keeping the current target" "put it behind a CDN / reverse proxy"
    "---- Nodes ----" "---- System ----" "---- Maintenance ----"
    "each site above is labelled" "Select type [3]: " "Press Enter to keep the current value."
    "Client address (domain or IP)" "Default scan range is the public" "Scan finished but no usable site"
    "not CDN (origin direct)" "Install script and command entry" "Path (Enter = random)"
    "all cached candidates are stale" "Kernel network tuning and firewall" "Select [0]: "
    "Select [1]: " "   5) Delete node" "Current target: "
    "No new camouflage site to apply" "no public inbound port needed" "Full install / reinstall"
    "Xray version channel" "Xray is not installed" "Install service and enable at boot"
    "Render config and start service" "each candidate is labelled with" "BBR / kernel"
    "supports passive TFO" "auto-widens to" "   0) Exit"
    "Fingerprint / TFO" "Backup / restore" "Client address"
    "Dependency check and install" "Language : " "TFO: no"
    "Results cached: " " usable candidates (of " "Export share links"
    "kernel network tuning" "Auto-scan failed" "Create data directories"
    "Language set to" "TFO: yes" "Using scan cache"
    "Scan camouflage sites" "Results cached" "Best camouflage site"
    "Create a node now" "Candidate sites" "sorted by quality"
    "unique candidates" "Download and verify" "Install latest"
    "Configure firewall" "not written to cache" "not part of the score"
    "Node type:" " for this run)" "Verified: "
    "Region set to" "Changes to apply:" "Apply these changes? "
    "Service control" "Add node" "List nodes"
    "Delete node" "Environment check" "version channel"
    "Rescanning" "full install" "specify manually"
    "auto scan" "random" "Listen port"
    "Node type" "Select type" "must support"
    "live probe" " and rescanning" "Among the first "
    "No changes" "Firewall" "camouflage site"
    "does not support" "cleared" "expired"
    "stale" "skipped" "not enabled"
    "not installed" "installed" "Issuer"
    "hours ago" "candidates" "invalid"
    "not required" "the list" "sites"
    "hard filter" "same rack" "boxes"
    "console" "Select " "Pick"
    "supports" "Handshake" "Score"
    "cache" "candidate" "scan"
    "validate" "reverify" "show"
    "clear" "list" "refresh"
    "widen" "widen" "node"
    "port" "address" "domain"
    "certificate" "traffic" "probe"
    "best" "quality" "result"
    "source" "add" "delete"
    "export" "list" "config"
    "routing" "log" "system"
    "maintenance" "update" "uninstall"
    "backup" "restore" "reinstall"
    "check" "service" "manage"
    "environment" "kernel" "privileges"
    "script" "entry" "enable"
    "on" "off" "use"
    "current" "select" "back"
    "continue" "confirm" "confirm"
    "cancel" "input" "example"
    "format" "notes" "hint"
    "warning" "error" "failed"
    "success" "done" "install"
    "download" "check" "start"
    "stop" "restart" "status"
    "default" "valid" "keep"
    "drop" "needs" "run"
    "command" "option" "file"
    "directory" "version" "missing"
    "unable" "must" "optional"
    "Enter" "Path" "Exit"
    "only" "Chinese" "English"
    "terminal"
)


# 纯 ASCII 快速路径：配置 / JSON / 分享链接 / 表头里的英文都不会被翻译或改写。
# 在 C locale 下 ${#s} 按字节计数，逐字节看有没有 >0x7f 的，比正则可靠。
xhy_is_ascii() {
    local LC_ALL=C s="$1" i c
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        if [[ "$c" > $'\x7f' ]]; then return 1; fi
    done
    return 0
}

# 一行的翻译：先按短语表替换，再把残留的非 ASCII 字节换成空格。
# 最后这一步是硬保证：即便将来新增了没进词表的中文，VNC 上也只会看到 ASCII。
# 用 tr -c（替换成空格）而不是 tr -cd（直接删除）：中文是多字节，直接删会让
# 前后两个英文词粘成一个（"scan完成support" -> "scandonesupport"），换空格
# 后至少还能读。保留 tab/LF/CR/ESC（ANSI 颜色）与 0x20-0x7e 可打印字符。
xhy_t_line() {
    local s="$1" i
    for (( i = 0; i < ${#XHY_T_ZH[@]}; i++ )); do
        s="${s//${XHY_T_ZH[$i]}/${XHY_T_EN[$i]}}"
    done
    builtin printf '%s' "$(builtin printf '%s' "$s" | LC_ALL=C tr -c '\11\12\15\33\40-\176' ' ')"
}

# xhy_t <字符串>  或  xhy_t <<'EOF' ... EOF（整段展示文本）
# 中文模式恒等；英文模式只处理含中文的那部分输出。stdin 模式逐行处理，
# 保留 heredoc 的行结构与末尾不换行的内容。
xhy_t() {
    local s line
    if (( $# > 0 )); then
        s="$1"
        if [[ "${XHY_LANG_EFFECTIVE:-zh}" != "en" ]] || xhy_is_ascii "$s"; then
            builtin printf '%s' "$s"
        else
            xhy_t_line "$s"
        fi
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "${XHY_LANG_EFFECTIVE:-zh}" != "en" ]] || xhy_is_ascii "$line"; then
            builtin printf '%s\n' "$line"
        else
            xhy_t_line "$line"; builtin printf '\n'
        fi
    done
    return 0
}

# 英文模式下的 printf 过滤器：不改任何调用点，把所有 printf 出来的用户可见
# 文本统一过一遍 xhy_t。printf -v 与纯 ASCII 数据原样透传。
# 注意：这里必须用 builtin printf，否则会递归回自己。
xhy_install_output_filters() {
    [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]] || return 0
    printf() {
        if (( $# == 0 )); then return 0; fi
        if [[ "${1:-}" == "-v" ]]; then builtin printf "$@"; return $?; fi
        local -a a=()
        local x
        for x in "$@"; do a+=("$(xhy_t "$x")"); done
        builtin printf "${a[@]}"
    }
    return 0
}

# 判定语言。优先级：XHY_ASCII=1 / XHY_LANG 环境变量 > state.env > 环境探测。
xhy_lang_init() {
    local want="${XHY_LANG:-}" st="" cm="" lang_all="" is_zh=0 no_utf8=0 console=0
    [[ "${XHY_ASCII:-0}" == "1" ]] && want="en"
    if [[ -z "$want" || "${want,,}" == "auto" ]]; then
        st="$(state_get XHY_LANG '' 2>/dev/null || true)"
        if [[ -n "$st" && "${st,,}" != "auto" ]]; then want="$st"; fi
    fi
    case "${want,,}" in
        en|english|ascii) XHY_LANG_EFFECTIVE="en" ;;
        zh|cn|chinese|zh_cn|zh_tw) XHY_LANG_EFFECTIVE="zh" ;;
        *)
            # 空 locale ≠ 非 UTF-8。Alpine / 精简容器默认根本没有 LANG，终端照样
            # 是 UTF-8、中文照样能显示；早期把空值当 no_utf8，导致普通 ssh 会话
            # 一律被判成英文。只有「明确设了、且不是 UTF-8」才算。
            lang_all="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
            case "${lang_all,,}" in zh*|*zh_cn*|*zh_tw*) is_zh=1 ;; esac
            if [[ -n "$lang_all" || -n "${LC_ALL:-}" || -n "${LC_CTYPE:-}" ]]; then
                case "$lang_all" in C|POSIX|c|posix) no_utf8=1 ;; esac
                case "${lang_all,,}" in *utf-8*|*utf8*) ;; *) no_utf8=1 ;; esac
                cm="$(locale charmap 2>/dev/null || true)"
                if [[ -n "$cm" ]]; then
                    case "${cm,,}" in *utf-8*|*utf8*) ;; *) no_utf8=1 ;; esac
                fi
            fi
            # 云 VNC / 串口控制台的 TERM：没有中文字形。
            # 不含 dumb：非交互 ssh / CI / agent 管道常见 TERM=dumb，那不是
            # 控制台，输出中文给日志和管道读完全没问题，不该切成英文。
            # 中文 locale 明确出现时尊重用户（他自己配了字形）。
            case "${TERM:-}" in linux|vt100|vt102|ansi|cons25|sun) console=1 ;; esac
            if (( no_utf8 == 1 )); then
                # 脚本输出是 UTF-8、终端却不是：中文只会更乱，直接英文。
                XHY_LANG_EFFECTIVE="en"
            elif (( is_zh == 1 )); then
                # 管理员显式配了中文 locale，尊重他（他自己装了字形）。
                XHY_LANG_EFFECTIVE="zh"
            elif (( console == 1 )); then
                XHY_LANG_EFFECTIVE="en"
            else
                XHY_LANG_EFFECTIVE="zh"
            fi
            ;;
    esac
    export XHY_LANG_EFFECTIVE
    # 颜色转义里的 ESC 会被兜底 tr 保留，但控制台上没必要冒这个险，直接关掉。
    if [[ "$XHY_LANG_EFFECTIVE" == "en" ]]; then
        C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
    fi
    return 0
}

# 一行永远可读的 ASCII 提示：不管判定成哪种语言，VNC 用户都能看到怎么切英文。
xhy_lang_banner() {
    if [[ "${XHY_LANG_EFFECTIVE:-zh}" == "en" ]]; then
        builtin printf '[*] xray-hy %s | English (ASCII) output. Switch back: xhy lang zh\n' "$XHY_VERSION"
    else
        builtin printf '[*] xray-hy %s | Chinese UI | boxes on VNC? re-run with XHY_LANG=en or: xhy lang en\n' "$XHY_VERSION"
    fi
    return 0
}
