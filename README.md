# xray-hy

模块化 Xray 部署管理脚本。一个仓库同时覆盖 **Debian/Ubuntu (systemd)** 与 **Alpine (OpenRC)**，支持四种节点模式并存、多节点管理、系统加固、版本钉死与后续更新。

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

参考与致谢：`XTLS/Xray-core`、`XTLS/Xray-install`、`zxcvos/Xray-script`（交互式菜单、target 校验、规则开关）、`audsiui/xray-jb`（多节点注册表与四模式划分）、`0xevn/xray-reality-setup`（加固项与文档结构）、`ICMP-UNREACHABLE/Minimal-Xray-Script`、`miku111/XrayOnAlpine`。

另外从 `driftray/easyxray` 借鉴了**校验后替换 + 配置快照回滚**、**切换 Xray 版本前备份二进制并在不兼容时自动换回**、**最低安全版本基线**和**诊断清单**这几项工程思路（它是 GPL-3.0、仅支持 Debian/Ubuntu + systemd、强依赖域名与 Nginx，架构与本项目不同，未复用其代码）。IPv6 双栈防火墙与慢速爆破双窗口则来自本项目在一台真实 Alpine VPS 上的巡检发现。

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
| Xray 版本 | `xhy core channel pinned`（钉死 `v26.10.31`）/ `latest` / `vX.Y.Z` 自定义；切换后 `xhy core update` 重装并校验配置兼容性 |
| 自动启动 | systemd unit 或 OpenRC init 脚本，`start_pre` 里先做配置校验；`Restart=on-failure` / OpenRC 自动重启策略 |
| BT 阻断 | `sniffing` + `routing` 的 `protocol: ["bittorrent"]` → blackhole，开关 `BLOCK_BT` |
| 防 SSH 爆破 | iptables `recent` **双窗口**：60 秒 5 次 + **1 小时 8 次**（后者专治「每几分钟来几发」的慢速爆破）；IPv4 / IPv6 双栈同时生效；缺 `xt_recent` 时降级并告警 |
| CF Tunnel | 可选；WS 只监听 `127.0.0.1`，cloudflared 由独立服务托管，Token 存 0600 文件；分享链接按 CF 边缘 TLS 生成 |
| 防火墙 | `safe`（默认）/ `strict` / `off`；**同时构建 iptables 与 ip6tables 链** —— 只防 IPv4 等于给 `:::22` 留了后门；每次变更前备份两个 family 的规则转储 |
| 伪装站 | `conf/targets.tsv` 地区库（US/GB/JP/HK/TW/SG/FR/DE/IN/CA/AU/NL/…），按 VPS 出口国家自动匹配，逐个做 TLS 1.3、HTTP/2、无重定向、非 CDN 校验；支持 `xhy target` 指定地区或手动固定 target/SNI |
| 后续更新 | `xhy update script`（git ff-only） / `core` / `geodata` / `config`（重建全部节点）/ `all` |
| 四种模式 | `direct`、`tunnel`、`reality`、`xhttp` |
| 导出链接 | `xhy link --all` / `--uri` / `--qr` |
| 额外补充 | 多节点并存与独立增删、节点注册表、配置变更原子校验+回滚、**最近 5 份配置快照 + `xhy rollback`**、更新 Xray 时二进制自动回滚、系统级关闭 MPTCP、私网/回国 IP/广告域名阻断开关、DoH 选择、日志级别与关闭、geodata 更新（带大小校验）、REALITY fallback 限速、系统自检报告（含版本安全线 / MPTCP / IPv6 检查）、CLI 与菜单双入口、卸载可选保留配置 |

### 版本策略与安全基线

`pinned` 默认钉死 **v26.10.31** 而不是更早的版本，原因是一条真实的安全问题：

> `XTLS/Xray-core#7291` / `CVE-2026-98432`（Linux 内核 TCP 竞态，CVSS 9.8）：Go 1.24+ 默认在监听器上启用 MPTCP，暴露在公网的 Go 代理服务端可被远程利用提权到 root。Xray 从 **v26.10.31** 起默认关闭 MPTCP。

因此本脚本还会：在内核暴露 `net.mptcp.enabled` 时把它设为 `0`；`xhy check` 报告当前版本与安全线、MPTCP 状态；`xhy core channel vX.Y.Z` 允许强制钉死旧版本，但会打印明确警告。切换版本前备份当前二进制，若新核心无法加载现有配置则自动换回。

`xhy core channel latest` 拉取最新正式版；`pinned` 用于「上游格式变更不破坏生产」的场景（历史上 `xray x25519` 输出格式变化曾让多个脚本的 REALITY 安装必定失败）。生产环境建议定期评估把 pinned 版本往前推，而不是永远不升。

---

## 4. 四种节点模式

| 模式 | 协议栈 | 默认端口 | 监听 | 说明 |
|---|---|---|---|---|
| `direct` | VLESS + WS | 8080 | 0.0.0.0 | 明文 WS，**建议前置 CDN / Nginx 反代并启用 TLS**，不要裸奔公网 |
| `tunnel` | VLESS + WS + Cloudflare Tunnel | 10086 | 127.0.0.1 | 无需公网入站端口；在 CF 控制台把 Public Hostname 的 Service 指向 `http://127.0.0.1:<port>`，路径与 WS path 一致 |
| `reality` | VLESS + REALITY + XTLS Vision | 443 | 0.0.0.0 | 无需域名与证书；`target` 必须是 TLS 1.3 + H2 的非 CDN 站点 |
| `xhttp` | VLESS + XHTTP | 8081 | 0.0.0.0 | 默认明文（便于套 CDN）；加 `--reality` 则叠加 REALITY，无需证书 |

同一模式可添加多个不同端口的节点，四种模式也可以共存。每个节点一份 `.env` 凭证 + 一份 inbound JSON 片段，`xhy update config` 会把所有片段重新渲染成单一 `config.json` 并整体校验。

CF Tunnel 模式下多个 tunnel 节点共用同一个 cloudflared 服务与 Token；请在 CF 控制台为每个主机名配置对应的本地端口。Token 在 `ps` 中可见是 cloudflared token 模式的固有行为，非本脚本引入。

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
│   ├── nodes.sh              四种模式 inbound 渲染、节点注册表、整体重建
│   ├── links.sh              vless:// 链接与二维码
│   └── update.sh             脚本/核心/geodata/配置更新、自检
└── conf/targets.tsv          可自行编辑的地区伪装站候选

/etc/xray-hy/                 运行时数据（0700）
├── config.json               渲染后的完整配置（0600）
├── state.env                 全局开关（0600）
├── tunnel.token              CF Tunnel Token（0600）
├── confs/<mode>_<port>.json  inbound 片段
├── nodes/<mode>_<port>.env   节点凭证（0600）
├── snapshots/                最近 5 份已知可用配置（xhy rollback 用）
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

脚本更新**不会**触碰 `/etc/xray-hy`。若配置渲染或校验失败，新增节点会被回滚，已有配置保持原样。每次重建配置都会先把上一份可用配置存进 `snapshots/`（保留最近 5 份）：

```sh
xhy snapshots          # 列出快照
xhy rollback           # 回滚到最近一份
xhy rollback /etc/xray-hy/snapshots/config.20261106120000.json   # 指定快照
```

`xhy update core` 在安装新 Xray 前会备份当前二进制；若新核心无法加载现有配置，自动换回原版本。更早的二进制副本也留在 `/etc/xray-hy/backups/`。

---

## 8. 已知限制与测试状态

**本项目尚未在真实 VPS 上做过端到端部署验证。** 代码经过 `bash -n` 语法检查与 JSON 片段审查，但不同发行版、内核、容器环境差异较大，请务必：

1. 先在一台**可随时重置的一次性 VPS** 上跑 `xhy install`，再看 `xhy check` 输出；
2. REALITY 部署前执行 `xhy target` → `5) 校验指定域名`，确认目标站点当前仍满足 TLS 1.3 / H2 / 非 CDN；`conf/targets.tsv` 只是初始候选，站点会变；
3. `direct` 与未加 `--reality` 的 `xhttp` 是明文传输，公网使用请自行套 TLS 终结层；
4. OpenVZ / LXC 等容器通常无法加载 `tcp_bbr`、无法写 sysctl，脚本会跳过并给出说明；
5. `xhy core channel latest` 存在上游格式变更风险（历史上 `xray x25519` 输出从 `Password` 改为 `Password (PublicKey)` 曾导致多个脚本 REALITY 安装失败）。本项目解析器已兼容两种格式，且 `update core` 会在新版本不兼容时自动换回旧二进制；但钉死版本也不要长期不升，见上面的「版本策略与安全基线」；
6. cloudflared raw 二进制没有官方校验和，无法做密码学验证；介意的话请改用 Cloudflare 官方软件源或 `.deb` 包自行替换 `$CF_BIN`；
7. `xhy firewall strict` 与任何会改动网络的操作，请确保有带外控制台（VNC / 救援模式）。

---

## 9. License

MIT，见 [LICENSE](LICENSE)。
