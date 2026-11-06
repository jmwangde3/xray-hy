# xray-hy

模块化 Xray 部署管理脚本。一个仓库同时覆盖 **Debian/Ubuntu (systemd)** 与 **Alpine (OpenRC)**，支持五种节点模式并存（含 Xray 原生 Hysteria2）、多节点管理、系统加固、版本钉死与后续更新。

> 仓库：`https://github.com/jmwangde3/xray-hy`（当前为私有仓库，推送与自更新依赖已配置的 git 凭据）
>
> **合规声明**：本项目是通用网络软件的配置自动化工具，仅供学习、研究及在**符合所在地法律法规与服务商条款**的前提下使用。在中国境内，未经主管部门批准自行建立或使用非法定信道进行国际联网属于违规行为；请勿将本脚本用于任何违法用途。使用者需自行承担合规责任。

---

## 1. 设计取向

对比了几个同类项目后确定的取舍：

| 关注点 | 本项目的做法 |
|---|---|
| 供应链 | 以**本地 git 工作树**安装，运行时不下载任何脚本；更新走 `git pull --ff-only` 且先看 diff。不提供也不推荐 `curl \| bash`。 |
| 下载校验 | Xray 发布包的 `.dgst` SHA-256 **强制校验**，拿不到摘要直接中止（多数一键脚本在这里会警告后继续）。cloudflared 官方 raw 二进制无校验和，做 ELF + `--version` 自检并明确提示。 |
| 配置安全 | 每次变更先在临时文件渲染、用 `xray run -test -c` 整体校验，**失败自动回滚该节点**，不影响已有节点。 |
| SSH | **从不修改 `sshd_config`**，只读取当前端口用于防火墙放行，避免远程锁死自己。 |
| 防火墙 | 只维护自己的 iptables 链，不 flush `INPUT`、不覆盖用户已有规则；开机时幂等重建而非 `iptables-restore` 全量覆盖。 |
| 凭证 | 节点 `.env` 权限 0600，目录 0700，Tunnel Token 单独 0600；分享链接输出时提示等同凭证。 |
| REALITY | 上游官方警告：认证失败的流量会被转发到 target，CDN 后面的站点会让服务器变成开放转发器。因此内置 TLS 1.3 / H2 / 无跳转 / 非 CDN 校验，并默认加上 `limitFallback*` 限速。 |
| 并发与磁盘 | 全局 `flock` 串行化所有配置变更，且服务命令显式关闭锁 fd（防 OpenRC 守护进程继承导致死锁）；**快照是整套状态 tar**（config + confs + nodes + state），回滚不会出现配置与节点注册表不一致；自动生成 logrotate 策略（weekly / 保留 4 份 / 32M 触发） |
| 内存 | 依据物理内存与 cgroup `memory.max` 给 Xray 设 `GOMEMLIMIT`（取 1/4，下限 32MiB），128–256MB 小鸡不易被 OOM Kill |
| 自更新 | `git pull --ff-only` 后对入口与所有 `lib/*.sh` 跑 `bash -n`，任一失败整组回滚到更新前 commit，不会留下跑不起来的入口 |

参考与致谢：`XTLS/Xray-core`、`XTLS/Xray-install`、`zxcvos/Xray-script`（交互式菜单、target 校验、规则开关）、`audsiui/xray-jb`（多节点注册表与四模式划分）、`0xevn/xray-reality-setup`（加固项与文档结构）、`ICMP-UNREACHABLE/Minimal-Xray-Script`、`miku111/XrayOnAlpine`。

另外从 `driftray/easyxray` 借鉴了**校验后替换 + 配置快照回滚**、**切换 Xray 版本前备份二进制并在不兼容时自动换回**、**最低安全版本基线**和**诊断清单**这几项工程思路（它是 GPL-3.0、仅支持 Debian/Ubuntu + systemd、强依赖域名与 Nginx，架构与本项目不同，未复用其代码）。

从 `0xdabiaoge/singbox-lite`（**已获作者授权阅读源码**）借鉴了跨脚本共享状态锁 + 原子写入、下载/更新后语法与版本校验再提交、按内存设 `GOMEMLIMIT`、日志自动清理。读源码后又发现几处我们自己的实现缺陷并修正：**服务操作必须显式关闭锁 fd（`9>&-`），否则 OpenRC 守护进程继承锁会让后续所有 `xhy` 命令死锁**；**事务快照要覆盖 config + 节点注册表 + 分片 + state 整套状态**，只存 config.json 回滚后会产生静默不一致；**用 `flock -n` 而非 `-w`**（BusyBox 不支持后者）；`memory.high` 与 `memory.max` 取较小值；`sha256sum` 缺失时用 `openssl dgst` 兜底。只借鉴实现思路、未复制其代码（该仓库无 LICENSE，且是 4 个 Shell 共 744 KB 的巨型单文件方案，功能覆盖双核心 / 中转 / 端口转发 / 订阅，与本项目轻量定位相反）。

同类脚本调研时还参考了 `fscarmen/ArgoX`（2046★，Xray 只听 localhost、由 Argo 隧道对外，不暴露代理端口 —— 我们的 `tunnel` 模式同思路）、`Suysker/xray-agent`（安装前把证书库存 / DNS 解析 / 端口占用 / 网络栈状态列清楚再动手 → `xhy preflight`）、`whherui/xray-reality-hy2-ss`（Hysteria2 必须放行 **UDP**，我们因此在 iptables 与 ip6tables 都加了 UDP 端口放行）、`sincalaway/ArgoSB` 与 `miihhaa/v2ray-1agent`（多核心组合、命令生成器、订阅）。这些都只取了思路，未复用代码。

IPv6 双栈防火墙与慢速爆破双窗口、DNS 并发查询取消的根因则来自本项目在一台真实 Alpine VPS 上的巡检发现。

---

## 2. 快速开始

```sh
# 以 root 执行
gh repo clone jmwangde3/xray-hy /opt/xray-hy      # 私有仓库，需先 gh auth login
# 或：git clone https://github.com/jmwangde3/xray-hy.git /opt/xray-hy
cd /opt/xray-hy
bash xhy install        # 依赖 -> Xray -> 服务 -> BBR -> 防火墙 -> 空配置自检
xhy                     # 打开交互菜单（install 已创建 /usr/local/bin/xhy 软链）
```

添加节点：

```sh
xhy add reality --port 443                 # 自动按 VPS 地区挑伪装站并校验
xhy add reality --port 8443 --target www.example.com:443 --sni www.example.com
xhy add direct  --port 8080 --host node.example.com
xhy add xhttp   --port 8081 --reality     # XHTTP + REALITY
xhy add tunnel  --port 10086 --domain node.example.com --token <CF_TUNNEL_TOKEN>
xhy add hy2     --port 8443 --sni www.bing.com --up 100mbps --down 300mbps

xhy preflight                # 安装/加节点前先跑一遍只读预检
xhy list
xhy link --all                            # 导出 vless:// 链接
xhy link --qr                            # 二维码（需 qrencode）
xhy del reality 8443
xhy check                                 # 全量环境自检
```

非交互环境（CI / 批量）所有命令都有对应形式，菜单中的 `confirm` 会采用默认值。

---

## 3. 需求覆盖

| 需求 | 实现 |
|---|---|
| 多系统 | Debian / Ubuntu / Devuan (systemd)、Alpine (OpenRC)、RHEL 系 (systemd)；x86_64 与 aarch64 |
| BBR | Debian 写 `/etc/sysctl.d/`；**Alpine 额外**写 `/etc/modules-load.d/xray-hy.conf` 加载 `tcp_bbr`/`sch_fq`、追加 `/etc/sysctl.conf`、`rc-update add sysctl boot`（Alpine 的 sysctl 服务在 boot runlevel 且默认不加载 BBR 模块）。容器环境自动跳过并说明原因 |
| Xray 版本 | `xhy core channel pinned`（钉死 **`v26.3.27`**，保 sing-box / mihomo 客户端兼容）/ `latest` / `vX.Y.Z` 自定义；切换时提示 #4520 与 MPTCP 两条边界，`xhy core update` 重装并校验配置兼容性 |
| 自动启动 | systemd unit 或 OpenRC init 脚本，`start_pre` 里先做配置校验；`Restart=on-failure` / OpenRC 自动重启策略 |
| BT 阻断 | `sniffing` + `routing` 的 `protocol: ["bittorrent"]` → blackhole，开关 `BLOCK_BT` |
| 防 SSH 爆破 | iptables `recent` **双窗口**：60 秒 5 次 + **1 小时 8 次**（后者专治「每几分钟来几发」的慢速爆破）；IPv4 / IPv6 双栈同时生效；缺 `xt_recent` 时降级并告警 |
| CF Tunnel | 可选；WS 只监听 `127.0.0.1`，cloudflared 由独立服务托管，Token 存 0600 文件；分享链接按 CF 边缘 TLS 生成 |
| 防火墙 | `safe`（默认）/ `strict` / `off`；**同时构建 iptables 与 ip6tables 链** —— 只防 IPv4 等于给 `:::22` 留了后门；每次变更前备份两个 family 的规则转储 |
| 伪装站 | `conf/targets.tsv` 地区库（US/GB/JP/HK/TW/SG/FR/DE/IN/CA/AU/NL/…），按 VPS 出口国家自动匹配，逐个做 TLS 1.3、HTTP/2、无重定向、非 CDN 校验；支持 `xhy target` 指定地区或手动固定 target/SNI |
| 后续更新 | `xhy update script`（git ff-only） / `core` / `geodata` / `config`（重建全部节点）/ `all` |
| 五种模式 | `direct`、`tunnel`、`reality`、`xhttp`、`hy2`（Xray 原生 Hysteria2 入站，UDP/QUIC + 自签证书 + `pinSHA256` 分享链接） |
| 导出链接 | `xhy link --all` / `--uri` / `--qr` |
| 额外补充 | 多节点并存与独立增删、**端口跨模式全局唯一检查**、**`DUAL_STACK=on` 双栈监听**、**`xhy preflight` 安装前只读预检**（内核修复线 / 端口 / 磁盘 / 内存 / MPTCP / GitHub 可达 / 依赖）、**Hysteria2 的 UDP 双栈放行与自签证书 pin**、节点注册表、**`flock` 并发锁（服务命令关闭锁 fd）**、配置变更原子校验+回滚、**最近 5 份整套状态快照 + `xhy rollback`**、更新 Xray 时二进制自动回滚、更新脚本后全量 `bash -n`、按内存/cgroup 设 `GOMEMLIMIT`、日志自动轮转、系统级关闭 MPTCP（钉死旧版的关键缓解）、私网/回国 IP/广告域名阻断开关、DoH 选择、日志级别与关闭、geodata 更新（带大小校验）、REALITY fallback 限速、系统自检报告、CLI 与菜单双入口、卸载可选保留配置 |

### 版本策略：两个相互冲突的上游边界

`pinned` 默认钉死 **v26.3.27**。这不是随便选的，而是因为 Xray 上游有两处互不相容的变化：

| 边界 | 影响 |
|---|---|
| **≥ v26.9.8** | `XTLS/REALITY` 升级后，服务端要求 ClientHello 携带 `X25519MLKEM768` key share（且排在普通 X25519 之前）。**sing-box / mihomo 的 uTLS chrome 指纹不带它**，这些客户端连 REALITY 会一律报 `reality verification failed`。见 [SagerNet/sing-box#4520](https://github.com/SagerNet/sing-box/issues/4520)，1.12.25 / 1.14.0 / 1.15.0-alpha 均受影响；Xray 官方客户端不受影响。 |
| **≥ v26.10.31** | Xray 才默认关闭 MPTCP，修掉 [XTLS#7291 / CVE-2026-98432](https://github.com/XTLS/Xray-core/pull/7291)（Linux 内核 TCP 竞态，CVSS 9.8；Go 1.24+ 默认在监听器启用 MPTCP，公网 Go 代理可被远程提权到 root）。 |

也就是说 **v26.9.8 ~ v26.10.30 两头不讨好**：客户端不兼容，MPTCP 又还没修。所以本项目默认选 v26.3.27 保住客户端兼容性，并用三层措施压住 MPTCP 暴露面：

- **进程级**：systemd unit / OpenRC init 给 Xray 注入 `GODEBUG=multipathtcp=0`。即使 sysctl 被重置，Go 1.24+ 监听器也主动使用普通 TCP；
- **内核级**：`xhy bbr on` 在内核暴露 `net.mptcp.enabled` 时设为 `0`（实测 Go 会自动回退普通 TCP、端口照常监听），并把 `net.ipv4.tcp_migrate_req` 设为 `0` 关掉该 CVE 的第二条路径；已存在的 listener 不会变，改完要重启服务；
- **可见性**：`xhy check` / `xhy bbr status` 报告版本相对两条边界的位置、MPTCP 与 migrate_req 状态；`xhy core channel latest|vX.Y.Z` 切换时提示对应风险但**不阻止**选择；切换前备份二进制，新核心加载不了现有配置会自动换回。

> ⚠️ **这些是缓解，不是修复。** CVE-2026-98432 的根因在普通 IPv4 TCP 路径的 use-after-free，Go 团队与各发行商都明确表示「关掉 MPTCP 不等于安全」。真正根治是**安装已修补的内核并重启**（Debian 12/13 已发布修复版本）。容器的 `net.mptcp.enabled` 按 network namespace 生效，需在容器内也设置；还可用 `nft ... tcp flags syn ip hdrlength != 5 counter drop` 丢弃带 IPv4 options 的 SYN 进一步收窄。

> 如果哪天 sing-box / mihomo 修好了 uTLS 指纹，或者你的客户端全是 Xray 系，就可以把通道切到 `latest` 吃到 MPTCP 官方修复；在那之前保持 `pinned` + 内核 MPTCP=0 是更稳的组合。

---

## 4. 五种节点模式

| 模式 | 协议栈 | 默认端口 | 监听 | 说明 |
|---|---|---|---|---|
| `direct` | VLESS + WS | 8080 | 0.0.0.0 | 明文 WS，**建议前置 CDN / Nginx 反代并启用 TLS**，不要裸奔公网 |
| `tunnel` | VLESS + WS + Cloudflare Tunnel | 10086 | 127.0.0.1 | 无需公网入站端口；在 CF 控制台把 Public Hostname 的 Service 指向 `http://127.0.0.1:<port>`，路径与 WS path 一致 |
| `reality` | VLESS + REALITY + XTLS Vision | 443 | 0.0.0.0 | 无需域名与证书；`target` 必须是 TLS 1.3 + H2 的非 CDN 站点 |
| `xhttp` | VLESS + XHTTP | 8081 | 0.0.0.0 | 默认明文（便于套 CDN）；加 `--reality` 则叠加 REALITY，无需证书 |
| `hy2` | Hysteria2（Xray 内置入站） | 8443 **UDP** | 0.0.0.0 | 自签证书 + `pinSHA256` 链接、站点伪装、可选 Brutal 带宽上限；防火墙自动放行 UDP |

同一模式可添加多个不同端口的节点，五种模式也可以共存。每个节点一份 `.env` 凭证 + 一份 inbound JSON 片段，`xhy update config` 会把所有片段重新渲染成单一 `config.json` 并整体校验。

CF Tunnel 模式下多个 tunnel 节点共用同一个 cloudflared 服务与 Token；请在 CF 控制台为每个主机名配置对应的本地端口。Token 在 `ps` 中可见是 cloudflared token 模式的固有行为，非本脚本引入。

### Hysteria 支持情况（为什么不引入第二个核心）

| 核心 | Hysteria2 | 说明 |
|---|---|---|
| **Xray-core** | ✅ 服务端入站从 **v26.3.27** 起支持 | 配置里协议名是 `hysteria`，`version` 必须为 `2`（只实现 Hysteria2，不支持 v1）。正好是我们默认钉死的版本，因此**不需要额外二进制**；配置字段已在真实 Xray 上用 `xray run -test` 验证。 |
| **sing-box** | ✅ 一直原生支持 | `type: hysteria2`，单块配置、带宽用纯整数 Mbps，端口跳跃用 `server_ports`。功能更成熟（Salamander / Gecko 混淆、端口跳跃），但要引入第二个核心与另一套配置格式。 |
| Hysteria 官方服务端 | ✅ | `apernet/hysteria` 独立二进制 + YAML 配置，是很多一键脚本的做法（如 `whherui/xray-reality-hy2-ss`）。 |

本脚本选 Xray 内置方案，保持「一套核心、一套配置、一次 `run -test`」。`hy2` 节点会：用 openssl 生成 10 年自签证书（0600，证书 CN/SAN = SNI）、把证书 SHA-256 以 `pinSHA256` 写进 `hysteria2://` 链接（比 `insecure=1` 安全，同时输出简易链接备选）、配置 `masquerade` 反代伪装站、可选 `--up/--down` Brutal 带宽、并让防火墙对 **IPv4 和 IPv6 都放行对应 UDP 端口**。

> 注意：`pinSHA256` 依赖客户端支持该标准参数；若导入失败，改用输出里给的 `insecure=1` 简易链接，或把 `PIN_HEX` 填到客户端的证书指纹字段。Hysteria2 是 UDP/QUIC，别忘了云安全组也要放行 UDP 端口。

---

## 5. 配置开关

```sh
xhy config set BLOCK_BT on          # BT 阻断（默认 on）
xhy config set BLOCK_PRIVATE on     # 私网地址阻断，防探测内网/云元数据（默认 on）
xhy config set BLOCK_CN off         # 回国 IP 阻断
xhy config set BLOCK_ADS off        # 广告域名阻断
xhy config set SSH_GUARD on         # SSH 防爆破
xhy config set DNS_PROVIDER quad9   # cloudflare / quad9 / dns-sb / system
xhy config set LOG_LEVEL none       # warning / info / debug / none，默认 warning
xhy config set TARGET_REGION jp     # 或 auto
```

注意：`BLOCK_PRIVATE` / `BLOCK_CN` / `BLOCK_ADS` 依赖 `geoip.dat` / `geosite.dat`。若 Xray 发布包未附带，安装时会自动从 `Loyalsoldier/v2ray-rules-dat` 补齐，也可随时 `xhy update geodata`。

`xhy firewall strict` 会把除 SSH 与节点端口外的所有入站 TCP/UDP 丢弃，请**先确认 SSH 端口识别正确**（`xhy check` 会显示），并保留一条可用的带外控制台。任何模式下都不会改动系统已有的 iptables 规则。

---

## 6. 目录结构

```
/opt/xray-hy/                 脚本 git 工作树（= 本仓库）
├── xhy                       主入口，POSIX sh shim 自动 re-exec 到 bash
├── lib/
│   ├── common.sh             日志/状态/原子写/校验/工具函数
│   ├── platform.sh           发行版、init、架构、SSH 端口检测，依赖安装
│   ├── core.sh               Xray 版本通道、下载+强制校验、x25519、cloudflared
│   ├── service.sh            systemd / OpenRC 服务与配置校验
│   ├── hardening.sh          BBR、iptables 链、SSH 防爆破
│   ├── target.sh             伪装站地区库与在线校验
│   ├── nodes.sh              五种模式 inbound 渲染、节点注册表、整体重建
│   ├── links.sh              vless:// 链接与二维码
│   └── update.sh             脚本/核心/geodata/配置更新、自检
└── conf/targets.tsv          可自行编辑的地区伪装站候选

/etc/xray-hy/                 运行时数据（0700）
├── config.json               渲染后的完整配置（0600）
├── state.env                 全局开关（0600）
├── tunnel.token              CF Tunnel Token（0600）
├── confs/<mode>_<port>.json  inbound 片段
├── nodes/<mode>_<port>.env   节点凭证（0600）
├── certs/hy2_<port>.crt/key  Hysteria2 自签证书与私钥（0600，目录 0700）
├── snapshots/                最近 5 份整套状态（xhy rollback 用）
└── backups/                  配置、iptables/ip6tables 与旧 Xray 二进制备份
/usr/local/bin/xray           Xray 二进制
/usr/local/share/xray/        geoip.dat / geosite.dat
/var/log/xray-hy/             日志
/usr/local/bin/xhy            入口软链
```

---

## 7. 更新与回滚

```sh
xhy update script     # git fetch -> 展示 log/diff -> 确认 -> pull --ff-only
xhy update core       # 按版本通道重装 Xray（强制校验），自动验证现有配置兼容性
xhy update geodata    # 只更新 geoip.dat / geosite.dat，失败保留旧文件
xhy update config     # 从节点注册表重建全部 inbound + 重载 + 刷新防火墙
xhy update all        # 以上全部 + 自检
```

脚本更新**不会**触碰 `/etc/xray-hy`。`update script` 拉取后会对 `xhy` 和所有 `lib/*.sh` 跑 `bash -n`，任一文件语法错误就整组回滚到更新前的 commit；所有会改配置的命令都持有全局 `flock`，并发执行不会互相踩。

若配置渲染或校验失败，新增节点会被回滚，已有配置保持原样。每次重建配置都会把**整套可变状态**（`config.json` + `confs/` + `nodes/` + `state.env`）打包进 `snapshots/`（保留最近 5 份），回滚时整套恢复，不会出现「配置回去了但节点凭证还留着」的不一致：

```sh
xhy snapshots          # 列出快照
xhy rollback           # 回滚到最近一份
xhy rollback /etc/xray-hy/snapshots/state.20261106120000.tar.gz   # 指定快照
```

回滚前会自动把当前状态另存为 `state.pre-rollback.*.tar.gz`，所以回滚本身也可撤销。

`xhy update core` 在安装新 Xray 前会备份当前二进制；若新核心无法加载现有配置，自动换回原版本。更早的二进制副本也留在 `/etc/xray-hy/backups/`。

---

## 8. 已知限制与测试状态

**本项目尚未在真实 VPS 上做过端到端部署验证。** 代码经过 `bash -n` 语法检查与 JSON 片段审查，但不同发行版、内核、容器环境差异较大，请务必：

1. 先在一台**可随时重置的一次性 VPS** 上跑 `xhy install`，再看 `xhy check` 输出；
2. REALITY 部署前执行 `xhy target` → `5) 校验指定域名`，确认目标站点当前仍满足 TLS 1.3 / H2 / 非 CDN；`conf/targets.tsv` 只是初始候选，站点会变；
3. `direct` 与未加 `--reality` 的 `xhttp` 是明文传输，公网使用请自行套 TLS 终结层；
4. OpenVZ / LXC 等容器通常无法加载 `tcp_bbr`、无法写 sysctl，脚本会跳过并给出说明；
5. `xhy core channel latest` 除上游格式变更风险外（历史上 `xray x25519` 输出从 `Password` 改为 `Password (PublicKey)` 曾让多个脚本的 REALITY 安装必定失败），**≥ v26.9.8 还会让 sing-box / mihomo 客户端连不上 REALITY**（#4520）。本项目解析器已兼容两种密钥输出格式，`update core` 也会在配置不兼容时自动换回旧二进制；升级前请先读上面的「版本策略：两个相互冲突的上游边界」；
6. cloudflared raw 二进制没有官方校验和，无法做密码学验证；介意的话请改用 Cloudflare 官方软件源或 `.deb` 包自行替换 `$CF_BIN`；
7. `xhy firewall strict` 与任何会改动网络的操作，请确保有带外控制台（VNC / 救援模式）；
8. Xray 26.10.31 起已对 **WebSocket 传输发出弃用提示**。`direct` 与 `tunnel` 两个 WS 模式短期可用，但长期使用请关注上游动向；CF Tunnel 目前仍依赖 WS，暂无等价替代。需要长期稳定的直连优先选 `reality` 或 `xhttp --reality`；
9. `hy2` 依赖 Xray **≥ v26.3.27** 的内置 Hysteria2 入站，把通道切到更旧版本会让该节点配置校验失败。自签证书需客户端支持 `pinSHA256`（不支持就用输出里的 `insecure=1` 简易链接）；UDP 端口除本机防火墙外，**云安全组也必须放行 UDP**。

---

## 9. License

MIT，见 [LICENSE](LICENSE)。
