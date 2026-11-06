# xray-hy

模块化 Xray 部署管理脚本。一个仓库同时覆盖 **Debian/Ubuntu (systemd)** 与 **Alpine (OpenRC)**，支持五种节点模式并存（含 Xray 原生 Hysteria2）、多节点管理、系统加固、版本钉死与后续更新。

> 仓库：`https://github.com/jmwangde3/xray-hy`（公开仓库，克隆不需要账号或 token）
>
> **合规声明**：本项目是通用网络软件的配置自动化工具，仅供学习、研究及在**符合所在地法律法规与服务商条款**的前提下使用。在中国境内，未经主管部门批准自行建立或使用非法定信道进行国际联网属于违规行为；请勿将本脚本用于任何违法用途。使用者需自行承担合规责任。

---

## 1. 设计取向

对比了几个同类项目后确定的取舍：

| 关注点 | 本项目的做法 |
|---|---|
| 供应链 | **单文件发布**：`install.sh` 由 `build.sh` 从 `lib/` 拼接生成，带构建号（commit + 源码哈希）。安装时先落盘再执行、自更新先过 `bash -n` 并比对构建号才整文件替换，**不会**把下载内容直接管道进 shell。仓库内开发仍走 git 工作树，`xhy update script` 拉新构建后先比对再替换。 |
| 下载校验 | Xray 发布包的 `.dgst` SHA-256 **强制校验**，拿不到摘要直接中止（多数一键脚本在这里会警告后继续）。cloudflared 官方 raw 二进制无校验和，做 ELF + `--version` 自检并明确提示。 |
| 配置安全 | 每次变更先在临时文件渲染、用 `xray run -test -c` 整体校验，**失败自动回滚该节点**，不影响已有节点。 |
| SSH | **从不修改 `sshd_config`**，只读取当前端口用于防火墙放行，避免远程锁死自己。 |
| 防火墙 | 只维护自己的 iptables 链，不 flush `INPUT`、不覆盖用户已有规则；开机时幂等重建而非 `iptables-restore` 全量覆盖。 |
| 凭证 | 节点 `.env` 权限 0600，目录 0700，Tunnel Token 单独 0600；分享链接输出时提示等同凭证。 |
| REALITY | 上游官方警告：认证失败的流量会被转发到 target，CDN 后面的站点会让服务器变成开放转发器。因此内置 TLS 1.3 / H2 / 无跳转 / 非 CDN 校验，并默认加上 `limitFallback*` 限速。 |
| 并发与磁盘 | 全局 `flock` 串行化所有配置变更，且服务命令显式关闭锁 fd（防 OpenRC 守护进程继承导致死锁）；**快照是整套状态 tar**（config + confs + nodes + state），回滚不会出现配置与节点注册表不一致；自动生成 logrotate 策略（weekly / 保留 4 份 / 32M 触发） |
| 内存 | 依据物理内存与 cgroup `memory.max` 给 Xray 设 `GOMEMLIMIT`（取 1/4，下限 32MiB），128–256MB 小鸡不易被 OOM Kill |
| 自更新 | `xhy update script` 下载新构建 → `bash -n` 语法检查 → 比对构建号 → 确认后原子替换；任一步失败本地脚本保持原样，旧版本自动备份在 `/etc/xray-hy/backups/`。克隆方式则走 `git pull --ff-only` |

---

## 2. 快速开始

两种方式任选其一，**都不要同时用**（会在两个位置各装一份 `xhy`）。

### 方式 A：一条命令（推荐，不需要 git）

```sh
# 以 root 执行
bash <(curl -fsSL https://github.com/jmwangde3/xray-hy/releases/latest/download/install.sh)
```

就这一条：它先做完整安装（依赖 → 脚本本体 → Xray → 服务 → BBR → 防火墙 → 空配置自检），装完 `xhy` 已在 PATH 里，接着输 `xhy` 打开菜单即可。

**全新 Alpine 服务器**（默认没有 bash，也可能没有 curl）改用这条 —— busybox 自带的 wget 就够：

```sh
wget -qO- https://github.com/jmwangde3/xray-hy/releases/latest/download/install.sh | sh
```

脚本开头是 POSIX sh：检测到没有 bash 会自己 `apk add bash`，再带着完整安装流程重新执行，所以这两条命令行为完全一致。缺 curl 也不用装，`| sh` 这条用的是 wget。

### 方式 B：git clone（想改代码、想随时看 diff）

```sh
# 以 root 执行

# 1) 补齐前提：仓库公开，git 不需要任何账号或 token
#    Alpine（官方镜像默认没有 git 和 bash）：
apk add --no-cache git bash
#    Debian / Ubuntu（一般自带，缺了再补）：
#    apt-get update && apt-get install -y git

# 2) 克隆到固定目录（卸载 / 更新时路径别换）
git clone https://github.com/jmwangde3/xray-hy.git /opt/xray-hy
cd /opt/xray-hy

# 3) 安装（仓库是模块化的，xhy 入口会加载 lib/，所以必须在克隆目录里跑）
bash xhy install
xhy                     # 打开交互菜单（install 已创建 /usr/local/bin/xhy 软链）
```

`bash xhy install` 与 `./xhy install` 等价；直接敲 `./xhy` 若报 `Permission denied`，先 `chmod +x xhy`。

### 两种方式差别

| | 方式 A（一条命令） | 方式 B（git clone） |
|---|---|---|
| 需要 git | 否 | 是 |
| 需要先装 bash | 否（脚本自动装） | Alpine 需要 `apk add bash` |
| 脚本位置 | `/usr/local/lib/xray-hy/xhy`（单文件，自包含） | `/opt/xray-hy/`（模块化工作树，`lib/` 必须保留） |
| `xhy` 软链指向 | `/usr/local/lib/xray-hy/xhy` | `/opt/xray-hy/xhy` |
| `xhy update script` | 下载新构建 → 语法检查 → 整文件替换 | `git pull --ff-only`（先看 diff） |
| 适合 | 一次性部署、全新小鸡 | 二次开发、想审计每一行改动 |

节点数据两种方式都存在 `/etc/xray-hy/`，与脚本位置无关。

### 2.1 只想先体检、不安装

```sh
xhy preflight        # 安装前只读预检（root、内核、磁盘、端口、依赖、GitHub 可达）
xhy check            # 已安装后的全量自检
```

### 2.2 「跑了没反应」怎么定位

脚本每一步都有 `==> [n/7]` banner 和超时上限，卡住先看停在哪一步。按顺序试：

| 现象 | 含义 | 处理 |
|---|---|---|
| `curl: command not found`（Alpine 用了方式 A 第一条） | 没有 curl | 改用 `wget -qO- ... \| sh`，或 `apk add curl` 后重试 |
| 卡在 `[1/7] 依赖` | 软件源/DNS 不通，或 apk 锁被占 | 另开会话跑 `apk update`、`ps w \| grep apk`；换源 `sed -i 's#dl-cdn.alpinelinux.org#mirrors.aliyun.com#g' /etc/apk/repositories` |
| 卡在 `[2/7] 脚本本体` | GitHub release 地址 404 或线路不通 | `curl -I <install.sh 的 URL>` 看返回码；404 说明 release 还没发 |
| 卡在 `[4/7] 下载并校验 Xray` | 到 GitHub 的线路不通 | `curl -I https://github.com` 验证；失败时按 `fetch` 打印的 curl 退出码处置 |
| 十几秒后报「另一个 xhy 实例…」 | 上一轮没退干净，配置锁还在 | `ps w \| grep '[x]hy'`，杀掉残留进程后重试 |
| 什么都不打印就退出 | 检查 `echo $?` | 用 `XHY_TRACE=1 bash <(curl -fsSL <url>)` 逐行看到哪一步 |

一键体检（不需要先装任何东西，纯 busybox）：

```sh
{ uname -a; head -3 /etc/os-release 2>/dev/null
  command -v bash || echo "缺少 bash"; command -v curl || echo "缺少 curl（Alpine 可用 wget 方式）"
  (nslookup github.com >/dev/null 2>&1 && echo "DNS ok") || echo "DNS 失败"
  curl -sS -o /dev/null -m 10 -w 'github HTTP %{http_code}\n' https://github.com 2>/dev/null || echo "curl 不可用"
  ps w | grep -E '[x]hy|[a]pk' || echo "没有卡住的 xhy/apk 进程"; } 2>&1
```

添加节点：

```sh
xhy add reality --port 443                 # 自动按 VPS 地区挑伪装站并校验
xhy add reality --port 8443 --target www.example.com:443 --sni www.example.com
xhy add reality --port 443 --target 1.2.3.4:443 --sni www.example.com   # 站点在 CDN 后：dest 用源站 IP、SNI 用域名
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
| BBR | Debian 写 `/etc/sysctl.d/`；**Alpine 额外**写 `/etc/modules-load.d/xray-hy.conf` 加载 `tcp_bbr`/`sch_fq`、追加 `/etc/sysctl.conf`、`rc-update add sysctl boot`（Alpine 的 sysctl 服务在 boot runlevel 且默认不加载 BBR 模块）。容器环境自动跳过并说明原因。**TFO 跟随 REALITY 伪装站自身的 SYN-ACK 自动对齐，不单独作为性能项宣传** |
| Xray 版本 | `xhy core channel pinned`（钉死 **`v26.3.27`**，保 sing-box / mihomo 客户端兼容）/ `latest` / `vX.Y.Z` 自定义；切换时提示 #4520 与 MPTCP 两条边界，`xhy core update` 重装并校验配置兼容性 |
| 自动启动 | systemd unit 或 OpenRC init 脚本，`start_pre` 里先做配置校验；`Restart=on-failure` / OpenRC 自动重启策略 |
| BT 阻断 | `sniffing` + `routing` 的 `protocol: ["bittorrent"]` → blackhole，开关 `BLOCK_BT` |
| 防 SSH 爆破 | iptables `recent` **双窗口**：60 秒 10 次 + **1 小时 25 次**（阈值按正常运维用量校准——诊断工具/VS Code/scp 一轮就是 5-10 个连接；暴力破解是每小时成百上千次）；IPv4 / IPv6 双栈同时生效；缺 `xt_recent` 时降级并告警 |
| CF Tunnel | 可选；WS 只监听 `127.0.0.1`，cloudflared 由独立服务托管，Token 存 0600 文件；分享链接按 CF 边缘 TLS 生成 |
| 防火墙 | `safe`（默认）/ `strict` / `off`；**同时构建 iptables 与 ip6tables 链** —— 只防 IPv4 等于给 `:::22` 留了后门；每次变更前备份两个 family 的规则转储 |
| 伪装站 | 三档：**`xhy scan` 自动扫描本机机房网段**（RealiTLScanner + 真实 SNI 验证 + 结果缓存，见上节）、`conf/targets.tsv` 地区库按 VPS 出口国家匹配、`xhy target` 手动固定 target/SNI 或单独校验；三者都做 TLS 1.3 / HTTP/2 / 无重定向 / 非 CDN 校验，并支持「dest=源站 IP、SNI=域名」（`--target 1.2.3.4:443 --sni www.example.com`，交互菜单写作 `1.2.3.4:443,sni=www.example.com`）|
| 后续更新 | `xhy update script`（单文件：新构建整文件替换；克隆：git ff-only）/ `core` / `geodata` / `config`（重建全部节点）/ `all` |
| 五种模式 | `direct`、`tunnel`、`reality`、`xhttp`、`hy2`（Xray 原生 Hysteria2 入站，UDP/QUIC + 自签证书 + `pinSHA256` 分享链接） |
| 导出链接 | `xhy link --all` / `--uri` / `--qr`（服务器是 IPv4 字面量且开了双栈时自动附 **IPv6 变体链接**） |
| 导出客户端配置 | `xhy export clash|singbox [--out FILE]` —— 生成 mihomo/Clash.Meta 的 `proxies` YAML 或 sing-box 的 outbounds JSON；xHTTP 两边都暂不支持，自动跳过并提示 |
| 备份 / 还原 | `xhy backup [--out FILE]` —— 打包 `/etc/xray-hy`（排除 snapshots/backups），**内含逐文件 SHA256 清单**；`xhy restore <文件>` 先全量校验、现状自动留底、从 nodes 重建配置并过 `xray -test`，失败整体回滚 |
| 非交互更新 | `xhy update script --yes`（同一主版本序列自动确认；跨主版本再加 `--allow-major`） |
| 额外补充 | 多节点并存与独立增删、**端口跨模式全局唯一检查**、**`DUAL_STACK=on` 双栈监听**、**`xhy preflight` 安装前只读预检**（内核修复线 / 端口 / 磁盘 / 内存 / MPTCP / GitHub 可达 / 依赖）、**Hysteria2 的 UDP 双栈放行与自签证书 pin**、节点注册表、**`flock` 并发锁（服务命令关闭锁 fd）**、配置变更原子校验+回滚、**最近 5 份整套状态快照 + `xhy rollback`**、更新 Xray 时二进制自动回滚、更新脚本后全量 `bash -n`、按内存/cgroup 设 `GOMEMLIMIT`、日志自动轮转、系统级关闭 MPTCP（钉死旧版的关键缓解）、私网/回国 IP/广告域名阻断开关、DoH 选择、日志级别与关闭、geodata 更新（带大小校验）、REALITY fallback 限速、系统自检报告、CLI 与菜单双入口、卸载可选保留配置 |

### 伪装站：target / dest / SNI / serverNames 是什么

| 名词 | 含义 |
|---|---|
| `target`（= `dest`） | 服务端主动去连的**目的地址**（`IP:端口` 或 `域名:端口`）。REALITY 把认证失败的探测流量原样转发到这里，所以它必须是一个真实存在、长期稳定的 HTTPS 站点。 |
| `SNI` | 客户端 TLS 握手时明文声明的域名（ClientHello 的 `server_name`）。服务端按它选证书，REALITY 也拿它判断这次访问像不像正常流量。 |
| `serverNames` | Xray 配置字段，等于允许的 SNI 白名单，一般写一个域名；它必须被 target 的证书覆盖，否则回落握手会证书不匹配——看起来就是一台假站。 |

**为什么有时要「IP 和域名分开填」**：目标站挂在 CDN 后面时，域名解析到的是 CDN 边缘 IP。此时 `target` 若也写域名，REALITY 就在替 CDN 做转发（特征不像源站，Xray 官方把这叫「变成开放转发器」）。正确做法是 `target` 写源站 IP、`SNI` 仍写域名：

```sh
xhy add reality --port 443 --target 1.2.3.4:443 --sni www.example.com
# 或交互菜单：xhy target → 3) 手动指定 target / SNI → 1.2.3.4:443,sni=www.example.com
```

校验会带 `curl --resolve www.example.com:443:1.2.3.4` 去打这台 IP，验的是**真实回落到源站**时证书是否覆盖该域名、是否没有 CDN 头，而不是公共 DNS 解析出的边缘节点。target 是 IP 却没给 SNI 时脚本会直接拒绝（否则会渲染出 `SNI=IP` 的废节点）。

### 伪装站自动扫描（`xhy scan`）

内置地区库是一份全球静态候选表；但**最合适的伪装站通常就在 VPS 自己的机房里** —— 同一个 /24、同一家运营商、TLS 握手 5ms 上下，而且机架不拆它就一直存在。`xhy scan` 用 [XTLS/RealiTLScanner](https://github.com/XTLS/RealiTLScanner) 把这个网段里所有 **TLS 1.3 + HTTP/2** 的站点列出来，再逐个用**真实 SNI** 验证后排序，取最优的那个。

```sh
xhy scan                     # 扫本机公网 IP 所在 /24（无合格结果自动扩到同机房 /21）
xhy scan 47.88.96.0/21       # 指定网段
xhy scan --refresh           # 忽略缓存重扫
xhy scan --list              # 看候选与打分（分数 = 延迟 + 状态码 + 内容量）
xhy scan --verify            # 复核缓存，剔除已失效的站点
xhy scan --clear             # 清缓存
```

扫描结果以 **`dest=源站 IP` + `SNI=域名`** 的形式给出，正好是 REALITY 需要的组合：

```
最优伪装站: target=47.88.102.65:443  SNI=www.easeus.com（来源 scan）
```

建节点时三选一（交互菜单默认第 1 项）：

```sh
xhy add reality --port 443 --scan     # 自动扫描（有缓存直接复用，不重复扫）
xhy add reality --port 443            # 内置地区库（按 VPS 出口国家匹配）
xhy add reality --port 443 --target 1.2.3.4:443 --sni www.example.com   # 手动
```

**缓存**：结果写在 `/etc/xray-hy/scan-cache.tsv`（0600，默认 7 天有效），下次建 REALITY 节点直接复用，不再扫描；即使是缓存里的候选，采用前也会再过一遍 REALITY 级校验（证书 / 跳转 / CDN），失效的就跳过。`SCANNER_TTL` 环境变量可改有效期。

**实现上比较要紧的几点**：

- RealiTLScanner 看到的是「该 IP 在无 SNI 时给出的默认证书」，CN 可能是 `*.example.com`；脚本会换成 `www.example.com` / 裸域两个具体 SNI 逐个用 `curl --resolve` 验证，证书不覆盖就用下一个，避免回落到源站时证书对不上。
- **排除本机 IP**：自己 443 上跑的就是 REALITY，扫回来的是「自己回落到 target 的那张证书」，不排掉会把自己选成 target。
- 证书里带 `cloudflare` / `fastly` / `akamai` 的、CN 落在 `api` / `proxy` / `test` / `chatgpt` 这类标签上的站点会被直接剔除（一眼就是反代或代理工具）。
- 只发 `linux-amd64` / `linux-arm64` 二进制；其它架构自动回退到内置地区库。Alpine 是 musl，首次使用会自动装 `libc6-compat`（官方二进制是 glibc 链接的）。

## 版本策略：两个相互冲突的上游边界

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

> 如果哪天 sing-box / mihomo 修好了 uTLS 指纹，或者你的客户端全是 Xray 系，可以切 `latest`。但**切 `latest` 是为了修 CVE-2026-98432，不是为了启用 MPTCP**：单网卡上 MPTCP 只有开销没有收益，`net.mptcp.enabled=0` 与 `GODEBUG=multipathtcp=0` 永久保留；在那之前保持 `pinned` + 内核 MPTCP=0 是更稳的组合。

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

本脚本选 Xray 内置方案，保持「一套核心、一套配置、一次 `run -test`」。`hy2` 节点会：用 openssl 生成 10 年自签证书（0600，证书 CN/SAN = SNI）、把证书 SHA-256 以 `pinSHA256` 写进 `hysteria2://` 链接（比 `insecure=1` 安全，同时输出简易链接备选）、默认 `masquerade type=string`（一张静态页）；`--masq-proxy` 改为反代真站，伪装性更好但未认证流量会消耗本机带宽；可选 `--up/--down` Brutal 带宽、并让防火墙对 **IPv4 和 IPv6 都放行对应 UDP 端口**。

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
本仓库（开发布局，方式 B 克隆下来的就是它）
├── xhy                       开发入口：加载 lib/ 与 entry/main.sh
├── install.sh                构建产物：单文件、自包含（build.sh 生成，不手改）
├── build.sh                  拼接器：entry/ + lib/ + conf/ -> install.sh
├── entry/
│   ├── prelude.sh            POSIX sh 开头段（没有 bash 先装、再 exec）+ bash 环境变量
│   └── main.sh               用法、各命令实现、main 分发
├── lib/
│   ├── common.sh             日志/状态/原子写/校验/工具函数
│   ├── platform.sh           发行版、init、架构、SSH 端口检测，依赖安装
│   ├── core.sh               Xray 版本通道、下载+强制校验、x25519、cloudflared
│   ├── service.sh            systemd / OpenRC 服务与配置校验
│   ├── hardening.sh          BBR、iptables 链、SSH 防爆破
│   ├── target.sh             伪装站地区库与在线校验
│   ├── nodes.sh              五种模式 inbound 渲染、节点注册表、整体重建、快照
│   ├── links.sh              vless:// 链接与二维码
│   └── update.sh             脚本/核心/geodata/配置更新、自检
├── conf/targets.tsv          可自行编辑的地区伪装站候选（构建时内嵌进 install.sh）
└── test/                     离线测试（无需 root / 网络 / 真实 Xray）

方式 A 安装后（单文件布局，逻辑与仓库完全一致）
/usr/local/lib/xray-hy/
├── xhy                       install.sh 的副本
└── conf/targets.tsv          首次用到伪装站时从内嵌数据生成（之后可直接编辑）

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
xhy update script     # 单文件：下载新构建 -> bash -n -> 比对构建号 -> 确认后原子替换
                      # 克隆方式：git fetch -> 展示 log/diff -> 确认 -> pull --ff-only
xhy update core       # 按版本通道重装 Xray（强制校验），自动验证现有配置兼容性
xhy update geodata    # 只更新 geoip.dat / geosite.dat，失败保留旧文件
xhy update config     # 从节点注册表重建全部 inbound + 重载 + 刷新防火墙
xhy update all        # 以上全部 + 自检
```

脚本更新**不会**触碰 `/etc/xray-hy`。`update script` 拿到新脚本后先 `bash -n` 语法检查、再比对构建号，任一步不对就放弃且本地文件分毫未动；确认替换前旧版本会备份到 `/etc/xray-hy/backups/`。所有会改配置的命令都持有全局 `flock`，并发执行不会互相踩。

若配置渲染或校验失败，新增节点会被回滚，已有配置保持原样。

快照保存的是**状态源**而不是渲染结果：`confs/` + `nodes/` + `certs/` + `state.env`，**不含 `config.json`**。原因很实际 —— `node_del` 会先删 `.env` 再重建配置，如果快照同时收录旧的 `config.json`，就会得到一个「配置里还有该节点、凭证却已不存在」的包。排除渲染结果后，回滚时先清空再解包，然后**从节点注册表重新渲染全部片段**并校验，任何快照都是自洽的（旧格式带 `config.json` 的快照同样能恢复，会被重新渲染覆盖）。

快照在**每次变更之前**拍（`add` / `del` / `config set` 都是先拍再改），所以「刚删错一个节点」可以直接回滚回来。保留最近 5 份：

```sh
xhy snapshots          # 列出快照
xhy rollback           # 回滚到最近一份
xhy rollback /etc/xray-hy/snapshots/state.20261106120000.tar.gz   # 指定快照
```

回滚前会自动把当前状态另存为 `state.pre-rollback.*.tar.gz`，所以回滚本身也可撤销。注意 `state.env` 之外的东西（如 `tunnel.token`）不在快照内，删除 tunnel 节点会一并清掉 token，需要重新填。

`xhy update core` 在安装新 Xray 前会备份当前二进制；若新核心无法加载现有配置，自动换回原版本。更早的二进制副本也留在 `/etc/xray-hy/backups/`。

### 版本号与发布

版本号只在两处定义（`entry/prelude.sh` 的赋值、`lib/common.sh` 的兜底默认值），**改版本号必须走工具**，`build.sh` 会校验两处一致，不一致直接拒绝构建：

```sh
tools/bump-version.sh minor --note "新增 xxx"    # 1.2.0 -> 1.3.0
tools/bump-version.sh patch                      # 1.3.0 -> 1.3.1
tools/bump-version.sh major --note "破坏性变更"   # 1.3.1 -> 2.0.0
```

规则：

| 位 | 什么时候动 | 例子 |
|---|---|---|
| **major** `X.0.0` | 不兼容变更：配置格式 / 目录结构 / CLI 语义变了，旧节点需要重建 | 节点注册表换格式 |
| **minor** `x.Y.0` | 新增功能、新命令、新交互，向后兼容 | 本版新增 `xhy scan` |
| **patch** `x.y.Z` | 修 bug、改文案、小重构，不改变既有行为 | 修一个下载重试 |

工具会自动更新两处版本号、在 `CHANGELOG.md` 顶部插入一节、重建 `install.sh` 并跑全量测试。`xhy version` 显示 `xray-hy 1.2.0 (build <12 位源码哈希>)`；`xhy update script` 用主版本号判断是否需要 `--allow-major`。

---

## 8. 已知限制与测试状态

已在真实 VPS（Alpine 3.23 / OpenRC，`47.88.102.45`）上完成端到端部署：`install` 七步全过、REALITY 节点实测可连、`xhy scan` 实机扫出并应用了同机房伪装站。下面的离线测试仍保留，任何机器上都能复跑（不需要 root、不需要网络、不需要真实 Xray）：

```sh
bash test/run-all.sh     # bash -n + 渲染 + hy2 + 生命周期 + 伪装站/扫描，共 158 项断言
```

覆盖：全部脚本语法；四种 VLESS 模式与 `hy2` 的 inbound 片段和合并 `config.json` 是否合法 JSON；`hy2` 自签证书生成与 `pinSHA256` 链接；UDP 端口是否进入防火墙；`add → snapshot → del → rollback` 的整套状态恢复；跨模式端口冲突；伪装站地区优先与 BOM 防御；IP+SNI 校验与删除节点选择器；扫描模块的网段换算 / 域名过滤 / 打分 / CSV 解析 / 缓存合并与过期 / 缓存优先选站；`sockopt` 是否按节点类型出现（`TFO=1/0` 对应 `tcpFastOpen` true/false、`hy2` 无 `sockopt`）、`policy.bufferSize` 取自 state、`ACCESS_LOG` 开关对 `log.access` 的影响、`sniffing.destOverride` 按模式裁剪、`hy2` 的 `masquerade.type` 默认 `string` 与 `--masq-proxy` 切 `proxy`。

此外 `hy2` 的配置字段在真实 Xray **26.10.31** 上用 `xray run -test` 验证通过（`protocol: hysteria` / `version: 2` / `alpn: ["h3"]` / `masquerade` / `finalmask.quicParams`），`hysteria2://` 链接格式经人工核对。

不同发行版、内核、容器环境差异较大，请务必：

1. 先在一台**可随时重置的一次性 VPS** 上跑 `xhy install`，再看 `xhy check` 输出；
2. REALITY 部署前执行 `xhy target` → `5) 校验指定域名或 IP+SNI`（IP 写法 `1.2.3.4:443,sni=www.example.com`），确认目标站点当前仍满足 TLS 1.3 / H2 / 非 CDN；`conf/targets.tsv` 只是初始候选，站点会变；
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
