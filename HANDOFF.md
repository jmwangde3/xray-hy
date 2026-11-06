# HANDOFF — xray-hy

> 交接时间：2026-11-06 12:30 (UTC+8)
> 仓库：<https://github.com/jmwangde3/xray-hy>（**私有**，main 分支，工作树干净）
> 本次交接的 commit：`2a5e845`
> 生产服务器：`8.222.223.248`（Alpine 3.23 / OpenRC / Xray 26.10.31）

---

## 1. 一句话现状

脚本功能已完整（5 种节点模式 + 加固 + 版本管理 + 回滚），离线测试 67 项断言全过，**但从未在真实 VPS 上端到端部署过**。服务器上跑的是另一套（`0xevn/xray-reality-setup`），只做过安全修复，没有迁移到本项目。

## 2. 立刻要知道的三件事

1. **不要在生产机直接 `xhy install`。** 默认钉死 `v26.3.27`，会把现有 `26.10.31` 降级；新服务也叫 443，与现有 `xray` 服务直接冲突。要迁移必须先在维护窗口停旧服务。
2. **仓库是私有的。** 要公开：
   ```sh
   gh repo edit jmwangde3/xray-hy --visibility public --accept-visibility-change-consequences
   ```
3. **root 密码在之前的对话里明文出现过，且该机一直在被爆破。** 建议轮换密码并改密钥登录（详见 §6.3）。

---

## 3. 仓库与代码结构

### 3.1 取代码 / 更新

```sh
git clone https://github.com/jmwangde3/xray-hy.git /opt/xray-hy   # 需要 gh 已登录或 PAT
cd /opt/xray-hy && ./xhy install
```

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

### 3.4 快照语义（这轮刚改过，务必理解）

快照收录 **`confs/` + `nodes/` + `certs/` + `state.env`**，**不含 `config.json`**。

原因：`node_del` 是先删 `.env` 再重建配置。如果快照同时收录旧的 `config.json`，就会得到「配置里还有某节点、凭证已被删掉」的包，回滚后 `xray run -test` 必失败。排除渲染结果后，回滚流程是：

1. 先把当前状态另存为 `state.pre-rollback.*.tar.gz`（回滚本身可撤销）
2. **清空** `nodes/*.env` 与 `confs/*.json`（否则恢复出来是两份状态的并集）
3. 解包快照
4. `node_rebuild_all` —— 从注册表重新渲染每个片段 → 合并 → 校验 → 重载

所以任何快照都是自洽的；旧格式（带 `config.json`）的快照也能恢复，会被第 4 步覆盖。

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

## 5. 这轮做了什么（commit `2a5e845`）

全树代码审查，修掉 6 个只在异常路径才暴露的缺陷，并补了离线测试：

| 缺陷 | 后果 | 修法 |
|---|---|---|
| 快照含 `config.json` | 回滚后配置引用已删凭证，校验必失败 | 只存状态源，回滚后重新渲染 |
| 快照在变更**之后**拍 | 快照无法撤销本次操作 | 改到 `add`/`del`/`config set` 之前 |
| `atomic_write` / `state_set` 以 `rm` 结尾 | 清理失败会让调用方报「配置生成失败」（其实已写成功） | 显式 `return 0` |
| `tar -C "<path>"` | 路径含 `:` 时 GNU tar 当 `host:path`，**静默生成空快照** | 改用 `cd` 子壳 |
| `svc_disable` 只删 `default` runlevel | `xhy firewall off` 后防火墙在下次开机**自动回来** | default + boot 都删 |
| 开机防火墙 unit 重写自己并调 `rc-update` | 自启动期间重入 | `XHY_FW_NO_INSTALL=1` 守卫；补 `after iptables`；CLI 转发 `--quiet` |
| `pick_target` 单趟遍历 | 通用 `auto` 行（表首）永远压过地区专属候选 | 地区优先两趟 |
| `conf/targets.tsv` 带 UTF-8 BOM | 注释过滤失效，表头被当成「地区」列出 | 去 BOM + 运行时兜底剥离 |
| `hy2` 未进模式错误提示 | 报错信息误导 | 补上 |

新增 `test/`：`bash test/run-all.sh`（无需 root / 网络 / 真实 Xray），67 项断言。

## 6. 服务器 `8.222.223.248` 现状

> 巡检时间 2026-11-06 12:22，**只读**（除 §6.2 已完成的修复外未做改动）

### 6.1 基线（健康）

- Alpine Linux v3.23，内核 `6.18.60-0-virt`（**高于 CVE-2026-98432 的 6.18 修复线 6.18.56**），`apk list -u` 无待升级包
- Xray **26.10.31**（go1.27.3），OpenRC 服务 `xray`，监听 `:::443`，`xray run -test` 通过，access.log 3809 行有真实流量
- BBR + fq 生效；`net.mptcp.enabled=0`、`net.ipv4.tcp_migrate_req=0`、`net.ipv4.ip_forward=0`
- 双栈防火墙：v4/v6 `INPUT` 均为 `DROP` 策略，各自带 SSH 双窗口限速
- `config.json` 0600、凭证 0600、`/root` 已清理旧脚本
- 磁盘 1.9G 用 200M（11%），内存 435M 用 80M
- `boot` runlevel 有 `sysctl`，`default` 有 `iptables-xray ntpd sshd xray crond`

### 6.2 已修复（2026-11-06 上午，备份在 `/root/xhy-fix-backup-20261106_103342/`）

| 项 | 内容 | 验证 |
|---|---|---|
| SSH 爆破 | v4 加 1h/8 次长窗口；封禁 `45.148.10.0/24`、`193.47.62.69`；加 /24 段 1h/12 次窗口（攻击者在 `45.148.10.x` 内轮换 IP，/32 计数被绕过） | 规则顺序已校正到 `ACCEPT 22` 之前；封段后无新增失败 |
| IPv6 后门 | `ip6tables` 镜像 v4 的双窗口限速（原先 v6 的 22 端口直接 ACCEPT，而 sshd 监听 `:::22`） | `ip6tables -S` 见 4 条 recent 规则，已持久化 |
| DNS 报错 | 根因是 `queryStrategy: UseIP` 并发 A/AAAA 两个 DoH 互相取消 → 改 `UseIPv4` + `domainStrategy: IPOnDemand` | **10:43 重启后 `context canceled` 新增 0 条**（截至 12:22） |
| 杂项 | `ip_forward=0`、`mptcp=0`、config 改 600、删 `resolv.conf` 里错误的 `search nameserver`、logrotate 改 `create 0600 root root`+`restart` | 全部核对通过 |

### 6.3 未修 / 遗留风险（**交接重点**）

| 优先级 | 问题 | 说明 |
|---|---|---|
| 🔴 高 | **root 密码登录仍开启** | `PermitRootLogin yes`，累计 253 次 `Failed password`，最近一次 10:41 来自 `45.148.10.152`。限速只能压住常规爆破，对分布式换 IP 无效。**根治 = 密钥登录 + 关密码认证**，有锁死风险，必须先把带外控制台（VNC/救援模式）准备好再动。 |
| 🔴 高 | **现网 Xray 26.10.31 与 sing-box / mihomo 客户端不兼容** | 见 §4。如果使用者用这两类客户端，这个 REALITY 节点现在**连不上**，会报 `reality verification failed`。解法二选一：降到 v26.3.27（等于自降安全版本，需确认内核已修补 + MPTCP 缓解在位），或让客户端换 Xray 官方核心。 |
| 🟠 中 | REALITY target 与 VPS 同 /16 | `dicehoard.com.au` → `8.222.229.202`，本机 `8.222.223.248`，疑似同机房。削弱伪装意义。用户明确表示暂不修。 |
| 🟡 低 | `iptables-xray` 是那套脚本自建的自启动项 | 迁移到 xray-hy 时要一并停用，否则两套规则并存 |
| 🟡 低 | `/root/_archived_scripts_20261106/` 里仍有 4 套旧脚本 | 已归档但未删，确认无用后可清 |

### 6.4 迁移到 xray-hy 的正确顺序（如果要做）

```sh
# 0. 维护窗口 + 带外控制台就绪
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

> 注意：第 2 步会中断现有代理。旧二进制/配置留在 `/usr/local/etc/xray` 与 `/root/xray-legacy-*`，回退就是反向操作。

---

## 7. 常用命令速查

```sh
xhy preflight                 # 安装前只读预检（内核修复线/MPTCP/端口/依赖/GitHub 可达）
xhy install                   # 依赖 + Xray + 服务 + BBR + 防火墙
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

## 8. 已知限制（写进 README §8，这里只列要点）

1. **没有真实 VPS 端到端验证过** —— 这是最大的一条。
2. `direct` 与未加 `--reality` 的 `xhttp` 是**明文**，公网必须自己套 TLS 终结层。
3. `cloudflared` 官方 raw 二进制无校验和，只做了 ELF + `--version` 自检。
4. geodata 补充下载（Loyalsoldier）**无校验和**，只有大小下限检查。
5. `xhy firewall strict` 与任何网络变更，必须有带外控制台。
6. Xray 26.10.31 起对 **WebSocket 传输发出弃用提示**；`direct`/`tunnel` 短期可用，长期优先 `reality` 或 `xhttp --reality`。CF Tunnel 目前仍依赖 WS。
7. `hy2` 依赖 Xray ≥ v26.3.27；UDP 端口除本机防火墙外，**云安全组也必须放行**。
8. 快照不含 `tunnel.token`，删掉最后一个 tunnel 节点会把 token 一并清掉。

## 9. 建议的下一步（按价值排序）

1. **拿一台一次性 VPS 跑通端到端**：`preflight → install → add reality → add hy2 → 客户端连接 → reboot 验证自启 → uninstall`。这一步能暴露绝大部分剩余问题。
2. **决定现网 Xray 版本路线**（§6.3 第二项）—— 这直接影响用户能不能连上。
3. 把 SSH 改成密钥登录（先备好带外控制台），这比任何限速规则都有效。
4. 迁移评估：如果决定用本项目接管 `8.222.223.248`，按 §6.4 执行。
5. 可选增强：nftables 独立表替代自定义链；卸载按依赖顺序清理；`xhy update geodata` 加 shebang/语法校验。

## 10. 交接备注

- 私有仓库推送依赖本机 `gh` 已登录账号 **jmwangde3**（token 含 `repo`/`workflow`）。
- 巡检与修复使用 `paramiko`（用户级 pip 包）通过密码 SSH 完成，**未在服务器上留下任何脚本**；临时探针文件均已清理。
- 服务器 root 密码以环境变量方式传入，未写入任何文件；但它在聊天记录中出现过，建议轮换。
- 合规：此类工具的部署与使用涉及跨境联网合规，请自行确认所在地法律法规与服务商条款。
