# 变更记录

版本号规则见 README「版本号与发布」；改版本号请用 `tools/bump-version.sh`。

## v1.4.2 — 2026-11-07

**口径修正：从「Xray 不支持」改成「运行时不生效」。** 这两者的行动后果完全相反 —— 说不生效只砍一个字段，说不支持会把整个 sockopt 连 `tcpKeepAliveIdle:45` 一起砍掉。

- 依据：Xray **26.3.27**（`XHY_PINNED_VERSION`）与 **26.10.31** 对同一份含七字段的 sockopt（`tcpFastOpen` / `tcpNoDelay` / `tcpKeepAliveIdle` / `tcpUserTimeout` / `tcpcongestion` / `tcpMptcp` / `tcpFastOpenQueueLength`）都返回 `Configuration OK.`、`EXIT=0`，无 unknown field。字段全部被接受，`tcpMptcp` 的存在性顾虑就此作废
- 但**能解析 ≠ 生效**：`tcpcongestion:"bbr"` 是 per-socket 设置，内核没编译 bbr 时 `setsockopt(TCP_CONGESTION)` 返回 EINVAL 被 Xray 静默忽略，那一项零效果。实测两台机器：`47.88.102.45` 是 `reno cubic bbr`（真生效），AX3600 路由器是 `reno cubic`（纯装饰）
- **`tcpcongestion` 改为按内核能力决定写不写**：`net.ipv4.tcp_available_congestion_control` 含 `bbr` 才写，否则整个字段省略（省略 = 继承内核默认，写死 `cubic` 反而可能顶掉更优默认）。判定用 `available` 而非 `current`：per-socket 只需算法可用，不要求内核默认就是 bbr；也与 `hardening.sh` 里 `xhy bbr on` 的判定依据一致，不会出现「bbr on 报 unavailable、sockopt 却写着 bbr」的矛盾
- **显式补 `tcpMptcp:false`**：GODEBUG 已在进程级关掉（`/etc/init.d/xray-hy` 第 14 行），写出来让读代码的人一眼看到结论，与 `tcpFastOpen:false` 同一风格
- **明确不砍的四个字段**：`tcpNoDelay` / `tcpKeepAliveIdle:45` / `tcpUserTimeout:10000` / `tcpMptcp` —— 与 TFO、拥塞控制都无关
- `tcpFastOpenQueueLength` 不写：TFO 关闭时队列长度无意义
- `xhy check` 新增一行 `sockopt`，显示**实际渲染结果**（`cc=bbr（内核可用）` / `cc=继承（内核无 bbr，字段省略）`），排查时少猜一层
- `test/sockopt-test.sh` 扩到 38 项：三种内核能力组合 × 四个无关字段的组合断言、`bbr2` 不算 bbr、两种输出都是合法 JSON、真实 sysctl 路径在 `set -u` 下不崩
- 未改：TFO 仍恒关、`--tfo` 仍被拒（v1.4.0 结论不变）

## v1.4.1 — 2026-11-07

- `xhy check` 不再统计 `TcpExtTCPFastOpenPassive` 命中数（TFO 固定关闭后它永远是 0，摆出来只会让人以为"开了但没命中"），改为明确显示 `TFO : off（固定，无开关）`
- 清掉 `node_add` 顶部注释里残留的 `[--tfo auto|on|off]`

## v1.4.0 — 2026-11-07

- **TFO 定为永久关闭**：`sockopt.tcpFastOpen` 恒写 `false`，脚本不再提供开启路径。`--tfo auto|on|off` 选项整体移除，传入时明确报错并说明理由（不是静默忽略）
- 节点 env 里的 `TFO` 字段不再参与渲染：老节点写的 `TFO=1` 也不会让产物出现 `tcpFastOpen:true`；新建节点的 `TFO` 一律写 `0`
- 删 `tfo_decide`（v1.3.1 起已无探测逻辑，只剩一个恒返回 0 的壳）
- 依据：v1.3.0 的探测恒为 false（普通 connect 的 SYN 不带 option 34）；目标伪装站全部不支持；Xray 26.10.31 上该字段入站/出站都不产生可观测行为；TCP options 不进 TLS 指纹，与 REALITY 伪装无关
- `test/sockopt-test.sh` 重写为 12 项：锁定「TFO=1 也渲染成 false」「tfo_decide 已删除」「CLI 拒绝 --tfo」；`render-test.sh` 同步改断言
- 破坏性：脚本化调用里写了 `--tfo auto` 的会失败。这是有意的 —— 该参数已无任何有效取值

## v1.3.1 — 2026-11-07

- 删掉 `--tfo auto` 的伪装站探测：实测证明它是个恒定返回 false 的死逻辑。被动 TFO 要求 client 的 SYN 带 option 34 **且** server listener 显式 `setsockopt(TCP_FASTOPEN)`；用普通 connect 探测时 SYN 根本不含 34，任何服务端都不会在 SYN-ACK 里回 34
- `--tfo auto`（默认）现在直接写 `tcpFastOpen:false`，不再花 1.4s 探测，也不再需要 tcpdump；`--tfo on/off` 保留为手动阀门
- 实测依据（47.88.102.45 / 26.10.31）：用 `curl --tcp-fastopen` 打出带 `exp-tfo cookiereq` 的 SYN 打 www.easeus.com 源站与两个高分候选，SYN-ACK 全部无 option 34；Xray 入站 `tcpFastOpen=true` 时 `TcpExtTCPFastOpenPassive=0`、出站 `tcpFastOpen=true` 的 SYN 与 false 逐字节相同 —— 该字段在当前核心上不产生可观测行为
- TFO 与 REALITY 伪装无关：TCP options 不进 TLS 指纹，客户端不据此判断真伪，「与伪装站一致」这个理由不成立
- 新增 `test/sockopt-test.sh`：锁定 `tfo_decide auto/off → 0`、`on → 1`，以及 `sockopt_json` 在 TFO=0/1 下的输出
- 修 `xhy update script` 在 git-clone 部署下会覆盖仓库入口的 bug：仓库模式（存在 build.sh + entry/main.sh）下直接拒绝自替换并提示 `git pull`，不再把 42 行的 dev 入口写成 4307 行的 install.sh（实测踩过：版本号回退到旧构建号、git 工作区变脏）
- v1.3.0 的其余改动（policy / access log / sysctl / sniffing 裁剪 / supervise-daemon / systemd 加固 / hy2 伪装）全部保留，并在真实客户端上实连验证通过（出口 IP、Google 204、CF trace、10MB 15MB/s、4 路并发、客户端 RSS 32MB）

## v1.3.0 — 2026-11-06

- 新增 `lib/sockopt.sh`：每个 TCP 入站补 `sockopt`（tcpFastOpen / tcpNoDelay / tcpKeepAliveIdle / tcpUserTimeout / tcpcongestion=bbr）；TFO 默认 `--tfo auto`，探测伪装站 SYN-ACK 是否带 TFO option 再决定，与目标行为一致不产生指纹；探测连的是 dest（源站 IP）、SNI 单独传 —— 域名挂在 CDN 后时，要跟的是源站而不是边缘节点
- config 顶层新增 `policy`：handshake 4 / connIdle 300 / uplinkOnly 2 / downlinkOnly 5 / bufferSize 512KB（`BUFFER_SIZE` 可调），四路流量统计全部关闭
- access log 默认关闭（`log.access=none`），排障用 `xhy config set ACCESS_LOG on`；`xhy check` 显示 access 状态、bufferSize、端口范围、TFO 命中计数
- sysctl 追加 5 条（tcp_mtu_probing / tcp_slow_start_after_idle / ip_local_port_range / netdev_max_backlog / bindv6only）；新增 `add_sysctl` 先探 /proc/sys 再写，不存在的键不再拖垮整段 `sysctl -p`
- OpenRC 改用 `supervise-daemon`（--respawn-max 5 --respawn-delay 3 --respawn-period 60）：原来的 `command_background=true` 崩溃后不会拉起；无 supervise-daemon 时退回后台模式并明确告警
- systemd unit 加固：ProtectSystem=strict + ReadWritePaths、ProtectHome、PrivateTmp、MemoryDenyWriteExecute、RestrictAddressFamilies、SystemCallFilter=@system-service + SystemCallErrorNumber=EPERM 等 14 项
- sniffing 按模式裁剪：direct/tunnel 保留 http+tls，reality/xhttp/hy2 只留 tls（QUIC 再解一次是纯开销）
- hy2 默认 `masquerade type=string` 静态页，`--masq-proxy` 才反代真站；Brutal 参数在 CLI 上明确警告计费与限速风险
- 修 OpenRC 上 `GOMEMLIMIT` 从未生效的既有 bug：`sed s|MEMLIMIT|$memlimit|` 会连 `GOMEMLIMIT` 里的子串一起替换，生成的 init 脚本写成 `export GO108MiB="108MiB"`，变量名根本不叫 `GOMEMLIMIT`，Go 读不到、内存上限一直是空的（小内存机器会 OOM）。改成只匹配带引号的值
- 修 `xhy check` 中途退出的既有 bug：`core_status` 与 `self_check` 里有几条 `[[ 条件 ]] && printf/warn` 作为函数最后一句，条件为假时函数返回 1，在 `set -e` 下自检只印一半就退出（本机没装 cloudflared 时必现）
- 测试 154 项全过（渲染回归新增 sockopt / policy / 日志开关 / sniffing 裁剪 / masquerade 12 项）

## v1.2.0 — 2026-11-06

- 新增 `xhy scan`：集成 XTLS/RealiTLScanner，扫描 VPS 所在 /24（无合格结果自动扩到同机房 /21），再用真实 SNI 逐个验证证书/跳转/CDN，取最优站点
- 扫描结果缓存到 /etc/xray-hy/scan-cache.tsv（默认 7 天有效）：之后新建 REALITY 节点直接复用，不再重复扫描；缓存候选在采用前仍会过一遍 REALITY 级校验
- 新建 REALITY 节点时可选择「自动扫描 / 内置地区库 / 手动指定」；CLI 新增 --scan、--scan-cidr、--scan-refresh，扫描结果为 dest=源站 IP + SNI=域名
- `xhy target` 菜单新增 7) 自动扫描、8) 查看/复核/清除缓存；`xhy check` 显示扫描器与缓存状态；`xhy version` 带 build 号
- 版本号规则落地：major=不兼容变更，minor=新功能，patch=修复；新增 tools/bump-version.sh 统一改两处版本号，build.sh 校验一致性

