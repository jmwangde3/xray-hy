# HANDOFF — xray-hy

> 交接时间：2026-11-06 13:56 (UTC+8)
> 更新：2026-11-06 15:35 —— 见 §11（无 bash / 无 git 的引导路径 + 卡死可见化）
> 仓库：<https://github.com/jmwangde3/xray-hy>（**私有**，main 分支，工作树干净）
> 基线 commit：`53cb4c6`（本文档为在此基础上的一次 docs 提交）
> 生产服务器：`8.222.223.248`（Alpine 3.23 / OpenRC / Xray 26.10.31）

---

## 1. 一句话现状

脚本功能完整（5 种节点模式 + 加固 + 版本管理 + 回滚），离线测试 67 项断言全过，**从未在真实 VPS 上端到端部署过**。生产服务器跑的仍是另一套（`0xevn/xray-reality-setup`），今天只做了安全加固与线路评估，**没有迁移**。

## 2. 立刻要知道的四件事

1. **不要在生产机直接 `xhy install`。** 默认钉死 `v26.3.27`，会把现有 `26.10.31` 降级；新服务名与现有 `xray` 服务直接冲突。迁移必须先在维护窗口停旧服务（见 §6.4）。
2. **SSH 已改为仅密钥登录。** 密码认证关闭，端口保持 22。私钥在运维机 `C:\Users\jmwan\OneDrive\.ssh\id_ed25519`（无口令），指纹 `SHA256:yh9qpakC4Kp/fJdO65XMchdxod959t7hC4YfbJpRNaM`。root 密码现在只对云控制台 VNC 有效。⚠️ 该私钥位于 OneDrive 同步目录内，见 §6.3。
3. **传输选型已定：REALITY。** 结论与理由见 §5。
4. **仓库是私有的。** 要公开：
   ```sh
   gh repo edit jmwangde3/xray-hy --visibility public --accept-visibility-change-consequences
   ```

---

## 3. 仓库与代码结构

### 3.1 取代码 / 更新

```sh
git clone https://github.com/jmwangde3/xray-hy.git /opt/xray-hy   # 需要 gh 已登录或 PAT
cd /opt/xray-hy && ./xhy install
```

**没有 git / 没有 bash 的机器**（Alpine 官方镜像默认两者都没有，且仓库是私有的）：
从 Windows 打包 `scp` 上去，用 `bootstrap.sh` 装依赖并摊到 `/opt/xray-hy`，全程不碰 git ——
具体命令见 `README` §2.1。`install` 本身**不依赖 git**，git 只被 `xhy update script` 使用。

脚本**以本地 git 工作树安装**，运行时绝不下载任何脚本；`xhy update script` 走 `git pull --ff-only`，拉完对所有 `.sh` 跑 `bash -n`，任一失败整组回滚到旧 commit。

### 3.2 模块地图

| 文件 | 行数 | 职责 | 改动时注意 |
|---|---|---|---|
| `xhy` | ~390 | 入口、CLI 解析、交互菜单、`cmd_install` | 首段是 POSIX sh，负责在 Alpine 上 `exec bash`，**不要改成纯 bash** |
| `lib/common.sh` | ~250 | 日志、状态、原子写、全局 flock、`fetch`、SHA-256 | `atomic_write` 末尾必须 `return 0`，否则清理失败会误判写入失败 |
| `lib/platform.sh` | ~142 | 发行版/init/架构/SSH 端口探测、依赖安装 | `detect_ssh_port` 只读，绝不改 `sshd_config` |
| `lib/core.sh` | ~202 | 版本通道、下载+强制校验、x25519、cloudflared、hy2 证书 | `.dgst` 拿不到必须中止，不能降级为警告 |
| `lib/service.sh` | ~250 | systemd / OpenRC 服务、`GOMEMLIMIT`、logrotate | 所有 `svc_*` 必须 `9>&-`，否则 OpenRC 子进程继承锁 fd 会死锁 |
| `lib/hardening.sh` | ~270 | BBR、双栈 iptables 链、SSH 防爆破 | 只维护自有链 `XHY-IN`，绝不 flush INPUT |
| `lib/target.sh` | ~166 | 伪装站地区库 + 在线校验 | `pick_target` 的诊断输出必须走 stderr |
| `lib/nodes.sh` | ~540 | 5 种 inbound 渲染、节点注册表、快照/回滚 | 最容易出问题的一块，见 §3.4 |
| `lib/links.sh` | ~85 | `vless://` / `hysteria2://` 链接、二维码 | — |
| `lib/update.sh` | ~237 | 更新、`self_check`、`preflight_check` | — |

### 3.3 运行时数据

```
/etc/xray-hy/                 0700
├── config.json               0600  渲染结果（由片段合并，不要手改）
├── state.env                 0600  全局开关
├── tunnel.token              0600  CF Tunnel Token（不在快照内）
├── confs/<mode>_<port>.json        每个 inbound 一个片段
├── nodes/<mode>_<port>.env   0600  节点凭证（权限 0700 目录）
├── certs/hy2_<port>.crt/key  0600  hy2 自签证书
├── snapshots/state.*.tar.gz        最近 5 份状态源
└── backups/                        配置、iptables、旧 Xray 二进制
/var/log/xray-hy/                   日志（logrotate weekly/4/32M，0600）
```

### 3.4 快照语义（务必理解）

快照收录 **`confs/` + `nodes/` + `certs/` + `state.env`**，**不含 `config.json`**。

原因：`node_del` 先删 `.env` 再重建配置。若快照同时收录旧 `config.json`，就会得到「配置里还有某节点、凭证已被删掉」的包，回滚后 `xray run -test` 必失败。排除渲染结果后，回滚流程是：

1. 先把当前状态另存为 `state.pre-rollback.*.tar.gz`（回滚本身可撤销）
2. **清空** `nodes/*.env` 与 `confs/*.json`（否则恢复出来是两份状态的并集）
3. 解包快照
4. `node_rebuild_all` —— 从注册表重新渲染每个片段 → 合并 → 校验 → 重载

快照在**变更之前**拍（`add` / `del` / `config set` 都是先拍再改），所以「刚删错一个节点」可以直接回滚。

---

## 4. 版本策略（钉死 v26.3.27 的原因）

Xray 上游有两个互相冲突的边界：

| 边界 | 影响 |
|---|---|
| **≥ v26.9.8** | REALITY 服务端要求 ClientHello 带 `X25519MLKEM768` key share，**sing-box / mihomo 的 uTLS 发不出来**，一律 `reality verification failed`（[SagerNet/sing-box#4520](https://github.com/SagerNet/sing-box/issues/4520)）。Xray 官方客户端不受影响。 |
| **≥ v26.10.31** | 才默认关闭 MPTCP，修掉 [XTLS#7291 / CVE-2026-98432](https://github.com/XTLS/Xray-core/pull/7291)（内核 TCP 竞态，CVSS 9.8，Go 1.24+ 默认在监听器启用 MPTCP，公网 Go 代理可被远程提权）。 |

中间那段（v26.9.8 ~ v26.10.30）**两头不讨好**。所以默认 `pinned = v26.3.27` 保客户端兼容，MPTCP 用三层缓解压住：

1. 进程级 `GODEBUG=multipathtcp=0`（写进 systemd unit / OpenRC init）
2. 内核级 `net.mptcp.enabled=0` + `net.ipv4.tcp_migrate_req=0`
3. `xhy check` / `xhy preflight` 会报告这两项

⚠️ **这三条都是缓解，不是修复。** 漏洞根因在普通 IPv4 TCP 路径，根治靠装修补内核并重启。`xhy preflight` 会按内核分支映射给出修复线（6.18 是 `>= 6.18.56`）。

---

## 5. 传输选型：用 REALITY（结论）

生产用 **REALITY**，hy2 不作为主线路。

| 结论 | 说明 |
|---|---|
| REALITY 抗丢包 | 线路有丢包时吞吐下降有限，仍可用 |
| hy2 不适合本场景 | 同样丢包条件下吞吐会崩到接近不可用 |
| 根本原因 | 服务器已启用 BBR，hy2 靠拥塞控制算法换来的优势在这套环境里不存在 |
| 客户端兼容 | 服务器现为 26.10.31，sing-box / mihomo 连 REALITY 会失败（§4 第一条边界），只有 Xray 官方客户端可用 |

**脚本里的 `hy2` 模式保留**（`xhy add hy2`），但它需要换成官方 hysteria2 服务端才有意义，当前架构下不建议投产。生产服务器上**未部署 hy2**，云安全组 UDP 443 已关闭。

---

## 6. 服务器 `8.222.223.248` 现状

### 6.1 基线（健康）

- Alpine Linux v3.23，内核 `6.18.60-0-virt`（**高于 CVE-2026-98432 的 6.18 修复线 6.18.56**），`apk list -u` 无待升级包
- Xray **26.10.31**（go1.27.3），OpenRC 服务 `xray`，监听 `:::443`，`xray run -test` 通过
- 只有 1 个 REALITY inbound（443/TCP），无 hy2、无 UDP 监听
- BBR + fq 生效；`net.mptcp.enabled=0`、`net.ipv4.tcp_migrate_req=0`、`net.ipv4.ip_forward=0`
- 双栈防火墙：v4/v6 `INPUT` 均为 `DROP` 策略，规则持久化在 `/etc/iptables/rules.v4|v6` + 开机服务 `iptables-xray`
- `config.json` 0600、凭证 0600、`/root` 已清理旧脚本
- 磁盘 1.9G 用 200.5M（11%），内存 435M 用 58M

### 6.2 已完成（结论）

| 项 | 结论 |
|---|---|
| SSH 加固 | **已切换为仅密钥登录**：`PasswordAuthentication no`、`KbdInteractiveAuthentication no`、`PermitRootLogin prohibit-password`、`PubkeyAuthentication yes`，端口仍 22。已验证「密钥可登 + 密码被拒」。备份 `/root/sshd_config.bak-20261106_1347` |
| 防火墙 | v4 加 1h/8 次长窗口 + /24 段 1h/12 次窗口（对抗换 IP 爆破）；v6 镜像同等规则（原先 v6 的 22 端口直接 ACCEPT） |
| 攻击段封禁 | `45.148.10.0/24`、`193.47.62.69` 已 DROP |
| DNS 报错 | 根因 `queryStrategy: UseIP` 并发 A/AAAA 互相取消 → 改 `UseIPv4` + `domainStrategy: IPOnDemand`，重启后不再新增 |
| 杂项 | `ip_forward=0`、MPTCP 缓解、config 0600、logrotate `create 0600 root root` + `restart`、清理 `resolv.conf` 错误行 |
| 云安全组 | UDP 443 已关闭（hy2 未部署，无需保留） |

### 6.3 遗留风险

| 优先级 | 问题 | 说明 |
|---|---|---|
| 🔴 高 | **现网 Xray 26.10.31 与 sing-box / mihomo 客户端不兼容** | 见 §4。使用者若用这两类客户端，这个 REALITY 节点**连不上**，会报 `reality verification failed`。解法二选一：降到 v26.3.27（需确认内核已修补 + MPTCP 缓解在位），或让客户端换 Xray 官方核心。 |
| 🟠 中 | REALITY target 与 VPS 同 /16 | `dicehoard.com.au` → `8.222.229.202`，本机 `8.222.223.248`，疑似同机房。削弱伪装意义。用户明确表示暂不修。 |
| 🟡 低 | `iptables-xray` 是旧脚本自建的自启动项 | 迁移到 xray-hy 时要一并停用，否则两套规则并存 |
| 🟡 低 | `/root/_archived_scripts_20261106/` 里仍有 4 套旧脚本 | 已归档但未删，确认无用后可清 |
| 🟠 中 | **私钥无口令，且落在 OneDrive 同步目录** | `C:\Users\jmwan\OneDrive\.ssh\id_ed25519` 会被同步到云端，等于把 root 私钥上传到第三方存储。建议移出同步目录，或加口令（`ssh-keygen -p -f <key>`），或两者都做 |

### 6.4 迁移到 xray-hy 的正确顺序（如果要做）

```sh
# 0. 维护窗口 + 带外控制台（VNC）就绪
# 1. 装到非 443 端口先验证（避免冲突）
git clone https://github.com/jmwangde3/xray-hy.git /opt/xray-hy
cd /opt/xray-hy && ./xhy preflight
# 2. 停旧服务并禁用其自启
rc-service xray stop && rc-update del xray
rc-service iptables-xray stop && rc-update del iptables-xray
# 3. 保留旧配置备份后再 install
cp -a /usr/local/etc/xray /root/xray-legacy-$(date +%F)
./xhy install
./xhy add reality --port 443 --host <域名或IP>
./xhy check
```

> 第 2 步会中断现有代理。旧二进制/配置留在 `/usr/local/etc/xray` 与 `/root/xray-legacy-*`，回退就是反向操作。

---

## 7. 常用命令速查

```sh
sh bootstrap.sh --check       # 纯 busybox 体检：DNS / 软件源 / GitHub / 卡住的进程
sh bootstrap.sh <dir|tar.gz>  # 装依赖 -> 摊到 /opt/xray-hy -> preflight
xhy preflight                 # 安装前只读预检（内核修复线/MPTCP/端口/依赖/GitHub 可达）
xhy install                   # 依赖 + Xray + 服务 + BBR + 防火墙（分 6 步打印 banner）
xhy check                     # 环境自检（版本两条边界、MPTCP、IPv6 链、配置语法、服务状态）

xhy add reality --port 443 --host 1.2.3.4
xhy add hy2 --port 8443 --sni www.bing.com --up 100mbps --down 300mbps
xhy add tunnel --port 10086 --domain node.example.com --token <CF_TOKEN>
xhy list / xhy link --all / xhy link --qr / xhy del reality 443

xhy config                    # 菜单：BT/私网/回国 IP/广告/SSH 防爆破/DoH/日志级别/地区/双栈
xhy config set BLOCK_CN on
xhy target                    # 伪装站：自动匹配 / 指定地区 / 手填 / 在线校验
xhy firewall [apply|strict|off|status]
xhy bbr [on|status]

xhy core [status|channel pinned|channel latest|channel v26.3.27|update]
xhy update [all|script|core|geodata|config]
xhy snapshots / xhy rollback [快照路径]
xhy service [start|stop|restart|status]
xhy uninstall
```

测试：

```sh
bash test/run-all.sh          # 67 项断言（21 + 18 + 28），无需 root / 网络 / 真实 Xray
```

---

## 8. 已知限制

1. **没有真实 VPS 端到端验证过** —— 这是最大的一条。
2. `direct` 与未加 `--reality` 的 `xhttp` 是**明文**，公网必须自己套 TLS 终结层。
3. `cloudflared` 官方 raw 二进制无校验和，只做了 ELF + `--version` 自检。
4. geodata 补充下载（Loyalsoldier）**无校验和**，只有大小下限检查。
5. `xhy firewall strict` 与任何网络变更，必须有带外控制台。
6. Xray 26.10.31 起对 **WebSocket 传输发出弃用提示**；`direct`/`tunnel` 短期可用，长期优先 `reality` 或 `xhttp --reality`。CF Tunnel 目前仍依赖 WS。
7. `hy2` 依赖 Xray ≥ v26.3.27；UDP 端口除本机防火墙外，**云安全组也必须放行**。该模式当前不建议投产（§5）。
8. 快照不含 `tunnel.token`，删掉最后一个 tunnel 节点会把 token 一并清掉。

## 9. 建议的下一步（按价值排序）

1. **拿一台一次性 VPS 跑通端到端**：`preflight → install → add reality → 客户端连接 → reboot 验证自启 → uninstall`。这一步能暴露绝大部分剩余问题。
2. **决定现网 Xray 版本路线**（§6.3 第一项）—— 这直接影响使用者能不能连上。
3. 私钥离线备份（无口令，丢了只能走 VNC）。
4. 迁移评估：如果决定用本项目接管 `8.222.223.248`，按 §6.4 执行。
5. 可选增强：nftables 独立表替代自定义链；卸载按依赖顺序清理；`xhy update geodata` 加 shebang/语法校验。

## 10. 交接备注

- 私有仓库推送依赖本机 `gh` 已登录账号 **jmwangde3**（token 含 `repo`/`workflow`）。
- 服务器运维走 SSH 密钥认证，**未在服务器上留下任何脚本**；临时探针文件均已清理。
- 本轮所有临时改动（hy2 入站、证书、iptables 规则、sysctl）均已回滚，`config.json` 恢复为原版 3005 字节。
- root 密码仅用于云控制台 VNC，且曾在聊天记录中明文出现，建议轮换。
- 合规：此类工具的部署与使用涉及跨境联网合规，请自行确认所在地法律法规与服务商条款。

## 11. 2026-11-06 15:35 · 「新服务器没反应」的修复

**现象**：全新 Alpine 机器（默认无 bash、无 git），`bash xhy install` 没有任何输出。

**先纠正一个判断**：`install` **不需要 git**。脚本是从本地目录读 `lib/*.sh`，git 只被 `xhy update script` 使用，且缺 git 时它已经会打印跳过。所以「没有 git」不是阻塞点，真正要解决的是**怎么把私有仓库的代码弄到机器上** —— 用 `tar.gz` + `scp`，见 README §2.1。

**真正的缺陷是静默**：三处会把输出吞掉或无限期等待，任何一处网络不通，表现都是「几分钟没反应」：

| 位置 | 原因 | 改法 |
|---|---|---|
| `xhy` 首段 | `apk add --no-cache bash >/dev/null 2>&1 \|\| true`，失败也不吭声 | 打印提示 + `timeout 180` + 4 条排查命令；补 apt/dnf/yum 分支 |
| `lib/platform.sh` | `pkg_update` / `pkg_install` 无超时 | 统一走 `run_lim`（`XHY_PKG_TIMEOUT`，默认 180s），失败打印 `pkg_hint`（换源/锁/手动装） |
| `lib/common.sh::fetch` | `-m 120` 只管总时长，连上后低速卡住照样干等 | 加 `--speed-time 30 --speed-limit 1024`，并按 curl 退出码（6/7/22/28/35/60）解释原因 |

另外三处可观测性：
- `cmd_install` 拆 6 步，每步 `==> [n/6]` banner —— 卡住时一眼知道停在哪。
- `XHY_TRACE=1 xhy install` 开 `set -x`，`PS4` 带 `文件:行号`。
- `acquire_lock` 等锁前先吭声，超时消息带 `ps w | grep '[x]hy'`。

**新增 `bootstrap.sh`**（POSIX sh，只依赖 busybox，因为它在 bash 装好之前就要能跑）：
`--check` 只体检 / 带目录或 tar.gz 参数时装依赖 + 摊平到 `/opt/xray-hy` + 跑 preflight。

**验证**：`bash -n` 全过（xhy + 8 个 lib + bootstrap），`test/run-all.sh` 67 项断言仍全过（21 + 18 + 28）。

**未解决**：新服务器 IP 没给，无法远程确认它到底卡在哪一步。需要一次现场输出（README §2.2 的一键体检）才能断定是 DNS、软件源还是 GitHub 线路。
