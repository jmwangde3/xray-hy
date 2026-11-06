# 变更记录

版本号规则见 README「版本号与发布」；改版本号请用 `tools/bump-version.sh`。

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

