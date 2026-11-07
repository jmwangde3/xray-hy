# 变更记录

版本号规则见 README「版本号与发布」；改版本号请用 `tools/bump-version.sh`。

## v1.9.3 — 2026-11-07

- fix(update): `xhy update script` 在 pipefail+errexit 下被 `sed | head -1` 的 SIGPIPE 打死（退出码 141），升级在下载前静默中止；改为 `|| true` 兜住。scanner 缓存时间读取同样处理
- test(lifecycle): 仓库模式用例改为断言「迁移到单文件、仓库入口不动」，覆盖 v1.9.2 新行为
- fix(common): `XHY_INSTALL_URL` 在库层给默认值，仓库入口/离线测试直接 source lib/ 时不再因 set -u 炸掉

## v1.9.2 — 2026-11-07

- fix(install): 旧软链入口在下次运行 xhy 时自动迁移到 /usr/local/bin/xhy 并清掉孤儿本体（此前 readlink 解析相同会跳过迁移，机器会永远停在旧路径）
- fix(update): `xhy update script` 不再拒绝仓库模式，改为迁移为单文件直装（仓库目录本身不动）；同版本但布局非规范时也会重装纠正
- feat(check): `xhy check` 新增「入口布局」行（单文件 / 旧软链 / 非规范路径）与遗留本体提示；`_cleanup_legacy_self` 支持 XHY_LEGACY_SELF 重定向便于测试

## v1.9.1 — 2026-11-07

- refactor(install): 单文件直装 /usr/local/bin/xhy（不再嵌套 /usr/local/lib/xray-hy + 软链），删除 git 仓库安装模式；install_self/update_script 增加 reconcile_bin 自愈旧软链，升级时自动校正 PATH 入口

## v1.9.0 — 2026-11-07

- feat(target): 地域推荐名单（伪装站子菜单 1/2）新增「只要 TFO」筛选——选定地域/自动匹配后问一次是否强制 TFO；强制时逐站实测、跳过不支持被动 TFO 的站、绝不做兜底；选择随状态保存，之后新建节点继续沿用
- fix(target): 强制 TFO 时绕过扫描缓存（缓存候选不带该过滤语义），避免选中普通站
- i18n: 新增 6 条双语纯 ASCII 词条（地域 TFO 提示 / 无命中提示 / 筛选状态行）
- test: edit-test.sh 新增地域 TFO 选站、无命中回退重选、选择状态保存等用例（76 项相关全过）

## v1.8.1 — 2026-11-07

- fix(tfo): **8.222.223.248 上之前两轮「扫不到 TFO 站点」的真凶找到了**——那台 `nstat` 命令缺失（精简系统常见），而旧版 `target_tfo_detect` / `tfo_probe_ready` **强制依赖 nstat 读 `TcpExtTCPFastOpenActive`**，读不到就一律判「不支持」→ 全假阴性，与「网段没站」长得一模一样。实测该机 `tcp_fastopen=3`、且 `/proc/net/netstat` 里 `TCPFastOpenActive` 字段**在**，`curl --tcp-fastopen` 打三家后计数 `1 → 7（+6）`，探测链路本来是通的。新增 `tfo_active_read()`：**优先 nstat，缺失就回退读 `/proc/net/netstat`**；`tfo_probe_ready` / `tfo_probe_blocker` 同步放宽（仅当 nstat 缺失**且** `/proc` 也不可读才判不可用）。`XHY_NETSTAT_PROC` 可重定向便于测试。`tfo-test.sh` 17→34 项，含「无 nstat 但 /proc 可读仍探到 TFO」的核心回归

## v1.8.0 — 2026-11-07

- feat(tfo): `--require-tfo` 开扫之前先自检「本机能不能探」——`curl --tcp-fastopen`、`nstat`、`net.ipv4.tcp_fastopen` 的**客户端位**三者缺一，任何目标都会被判成「不支持」，用户看到的是「扫了 /24 又扫 /21 一个都没有」，极易误判成「全网没人开 TFO」。缺条件时直接说明原因，并问一次是否改为按质量选站
- fix(tfo): 域名目标先解析再 `--resolve` 钉死**单个 IP**再探三次。TFO cookie 按目的 IP 缓存，多 A 记录的站三次试探可能落到不同 IP，支持 TFO 的站也会测成 0（假阴性）
- feat(check): `xhy check` 新增「TFO 探测 : 可用 / 不可用（原因）」一行，与「节点开没开 TFO」分开显示
- test: `tfo-test.sh` 17 → 28 项（钉 IP、解析失败退回、客户端位 0/1/2/3、缺 curl/nstat）

## v1.7.4 — 2026-11-07

- fix(check): 遗留钩子告警文案与实际行为对齐 —— 是**原地改名**（`xhy-backup-prune.retired-<ts>`，含 `.` 故 run-parts 不再执行），不是搬到 `/root`；告警里给出的回滚命令随之正确
- 现网实测：`xhy check` 打出告警 → `xhy clean all` 打印「摘掉事故期遗留的定时任务」+ 一条 `mv` 回滚 → `/etc/periodic/daily/` 只剩 `logrotate` 与改名后的留档

## v1.7.3 — 2026-11-07

- fix(clean): 事故期手工装的 `/etc/periodic/daily/xhy-backup-prune` 会被自动摘掉并原地改名留档（含 `.` 的名字 run-parts 不执行，回滚一条 `mv`）。它的策略是「二进制留 1 份」，与新默认值 0 直接冲突，留着半夜就把 35 MB 搬回来
- feat(check): `xhy check` 检测到该遗留钩子时告警，并说明 `xhy clean all` 会处理
- feat(clean): 新增 `XHY_PERIODIC_DIR` 以便测试重定向；`disk-test.sh` 扩到 80 项

## v1.7.2 — 2026-11-07

- `xhy clean` 默认不再保留二进制备份：`xray` 也是「能上网重新下载」的东西，留一份就是 35 MB。想留保险设 `XHY_BACKUP_CORE=1`（只留最新 1 份）
- 删完会打印恢复方法：`xhy core channel <版本> && xhy core update`
- 至此 `backups/` 里只剩真正丢不起的东西：`config.json` / 节点 env / 证书 / `state.env`

## v1.7.1 — 2026-11-07

- `xhy clean all` 现在会把 `geoip.dat.*.bak` / `geosite.dat.*.bak` 这类「可重新下载」的历史副本**全部清掉**（v1.7.0 是每类留 2 份，但那 29.5 MB 在 47.88.102.45 上正是主要占用）。现用的 dat 在 `/usr/local/share/xray`，`xhy geodata` 随时重下，留副本没有意义
- 生产机实测：备份目录 63.8 MB → 34.2 MB，根分区余量 143 MB → 172 MB

## v1.7.0 — 2026-11-07

**备份只留配置，写盘前先过闸门。** 依据 `xray-hy_磁盘写满事故报告_20261107.md`（生产机 220 MB 备份撑满 427 MB 根分区，`install` 把 xray 写成 11 MB 半截文件）。

- **备份范围收窄到「丢了要重新想一遍」的东西**：`config.json` / `nodes/` / `confs/` / `certs/` / `state.env`。`xray` 二进制、`geoip.dat`、`geosite.dat` 约 65 MB，全部可重新下载，`backup_file` 直接跳过并打印省下多少
- 旧二进制不再归档进 `backups/`：要留一份保险得显式 `XHY_BACKUP_CORE=1`，且只留最新 1 份（写入后立刻裁）
- **写作前空间闸门 `disk_need <MB> <操作>`**：不足直接返回非零，不再「余量不够就跳过备份、然后继续写」。接线在 `xray_install`（90 MB，在下载之前）、`update_geodata`（45 MB）、`backup_create`（15 MB）
- **`xray_install` 改三段式**：闸门 → 临时目录里先 `version` 验证 → 同盘 `rename` 原子替换（跨盘才退回 `.new` + `mv`）。目标二进制永远不会处于半写状态；写入失败时明确报「原二进制未改动」，不再误报成「架构或依赖不匹配」
- geodata 替换同样改成 `.new` + `mv`
- `update_core`：回滚副本是「换核这次事务」的临时保险（成功/失败都删），余量 < 100 MB 直接拒绝换核并提示 `xhy clean all`；确要硬来的用 `xhy core update --force`
- `xhy check` 的磁盘行改成「余量 / 总容量 / 备份目录占用」，阈值按机型自适应（总盘 < 1 GB 取 80 MB，否则 200 MB）—— 427 MB 的机器永远到不了 200 MB，固定阈值的后果是用户学会无视告警
- `preflight` 的 300 MB 阈值同样自适应：小盘取 90 MB，并显示「本机需 N MB」
- `backup_file` 写完就裁：同名 `.bak` 只留最新 2 份
- `xhy firewall` 快照：空表（没有 `-A` 行）不再存，同类只留最新 3 份
- `test/disk-test.sh` 扩到 70 项：闸门语义、可重下判定、`backup_file` 裁剪、**余量为 0 时原二进制逐字节不变**的回归

## v1.6.2 — 2026-11-07

- **修 `xhy clean` 的账算错了**：`ls -1t $XHY_BACKUP/xray-*` 把 `update_core` 的临时回滚副本 `xray-rollback.??????` 也当成二进制备份，而且按 mtime 排序后「最新一份」可能正是这个零字节残留 —— 真正 30 MB 的备份反而被当旧文件删掉。现在两类分开统计：临时副本一律清掉，二进制备份只按真实备份排最新
- 释放量不再拿 `df` 前后相减（粒度 1 MB，删零星小文件会显示「释放 0 MB」，看着像没删）。改为逐文件 `du -k` 求和，按 KB/MB 报，并逐个列出被删文件名与体积；结尾区分「df 增加 N MB」与「df 未变（删的是零字节残留或文件仍被占用）」
- `xhy clean` 新增两类清理：`tarballs`（`xhy backup` 产物与还原前自动备份，留最新 3 份）与 `tmp`（`xray-rollback.*` 残留）；参数非法直接拒绝，不再静默什么都不做
- 余量仍不足 200 MB 时，额外列出备份目录里最大的 3 个文件，并提示 apk/apt 缓存、`/var/log`、`/root` 下的手工 tar 包 —— 不用再自己 `ls` 猜空间去哪了
- `update_core` 自动回滚成功后立刻删掉回滚副本（原先只删成功路径，回滚分支 `die` 前把 30 MB 留在盘上）
- `test/disk-test.sh` 扩到 43 项：新增 `file_kb` / `human_kb`、零字节残留顶掉真实备份的回归用例、`tarballs` 清理、非法参数

## v1.6.1 — 2026-11-07

- **修致命缺陷：根分区被备份撑满 → sshd 失去响应**。427 MB 根分区的小盘 VPS 上真实发生：`xhy core channel` 每次切换都往 `/etc/xray-hy/backups` 丢一个 ~30 MB 的旧二进制副本，叠加手工备份后盘满，`git pull` 写不进对象，SSH 直接连不上（而 443 上的代理仍在正常工作，很容易误判成网络问题）
- `xray_install` 与 `update_core` 备份二进制前先看余量：不足 120 MB 就跳过备份并告警，绝不为了留一份副本把盘塞满
- 新增 `xhy clean [backups|snapshots|all]`（菜单 16 → clean）：二进制备份留最新 1 份、状态快照留最新 5 份、`.bak` 留最新 20 份，跑完汇报释放了多少 MB
- `xhy check` 新增「磁盘余量」一行，低于 200 MB 直接告警并提示 `xhy clean`
- 新增 `test/disk-test.sh`（23 项：余量函数 / 保留策略 / 分类型清理 / 源码接线）

## v1.6.0 — 2026-11-07

- 菜单重排：新增「2) 编辑节点」，去掉与伪装站子菜单完全重复的「16) 扫描伪装站」（`xhy scan` CLI 保留，脚本化仍可用），其余编号随之调整
- 新增 `xhy edit [mode] [port]`：交互式修改已有节点的端口 / UUID / 路径 / 连接地址 / target / SNI / shortId / 指纹 / TFO，hy2 还能改伪装 URL、伪装模式与 Brutal 速率。回车 = 保持原值；改端口等于重命名注册表并重建分片；hy2 改端口或 SNI 会自动重签自签证书并更新 pinSHA256
- 「指定地区」不再让人背地区代码：列出序号 / 地区 / 国家 / 候选数 / 首个候选，输入编号或直接输入地区代码都行，选完立即逐个校验并显示结果
- 扫描或手动指定伪装站后，可以选是否把新站套用到已有 REALITY 节点（all / 1,3 / 单个编号，回车不换）；只换 target 与 SNI，私钥、shortId、UUID 一律不动
- `--require-tfo` 在 /24 与同机房 /21 都扫不到时不再把用户丢回菜单：直接说明 TFO 只省首连 1 个 RTT、伪装站不承载代理流量，并问一次「改为不强制 TFO 按质量重选」
- 修 hy2 节点改端口或 SNI 时不重签证书：证书文件名带端口、SAN 带 SNI，不重签会让客户端的 pinSHA256 直接失配
- `node_env_update` 就地改写注册表：命中的键替换、未知字段与注释原样保留、新键追加，避免编辑时顺手丢掉后来加的字段
- 新增 `test/edit-test.sh`（59 项：就地改写 / 改端口重命名 / 端口冲突拒绝 / retarget 不动密钥 / 地区表 / 菜单接线 / TFO 回退），全量 416 项断言

## v1.5.0 — 2026-11-07

- 一键安装语义修正：`install.sh` 无参数 = `auto`，未安装则跑完整安装（脚本本体 + `/usr/local/bin/xhy`）并进菜单，已安装直接进菜单。任何从管道 / 临时文件启动的调用都会 `bootstrap_self` 先落地入口，装完 `xhy` 立刻可用
- 新增语言层 `lib/i18n.sh`：`XHY_LANG=zh|en|auto`、`XHY_ASCII=1`、`xhy lang`。`en` 模式经短语表 + `tr -c` 兜底，硬保证纯可印 ASCII —— 云厂商 VNC 控制台没有中文字形，原来满屏小方块
- `xhy scan --require-tfo` 自动扩网段：`/24`（含缓存）找不到支持被动 TFO 的站点时，自动扩到同机房 `/21` 再扫一次；缓存路径直接扩 `/21`，绝不重复扫同一 `/24`。扩视野用 `SCANNER_TFO_POOL_WIDE=32` 防新站被前排挤掉
- 扫描输出每个候选后面标注 `TFO 支持 / 不支持`，覆盖 `[ok]` 校验行、3-5 候选短名单、`xhy scan --list` / `--verify`；现场探测，不写进缓存
- 修 `--require-tfo` 过滤为空被当成「缓存候选都已失效」→ 白重扫同一 `/24`、同样 8 行 `[ok]` 打两遍；现在直接失败并给三条可选路径
- 修仓库部署被自举改写成单文件安装：在 `/opt/xray-hy` 这类 git 克隆里跑 `install.sh` 会把入口改指 `/usr/local/lib/xray-hy`，之后 `git pull` 不再生效；现在识别仓库并只把入口指向该仓库
- 修 `TERM=dumb` 与空 `LANG` 误判：非交互 ssh / CI 的 `TERM=dumb` 曾触发英文、Alpine 出厂无 locale 的空 `LANG` 曾被当 C locale，普通 ssh 中文输出被切成英文。现在只有真 console TERM（`linux`/`vt100`/`vt102`/`ansi`/`cons25`/`sun`）或明确设了且非 UTF-8 的 locale 才切英文
- 修英文模式 `tr -cd` 删字节导致未登录中文两侧英文词粘连；改用 `tr -c` 替换为空格
- 新增 `XHY_BINDIR`（默认 `/usr/local/bin`），离线测试不再往系统目录写软链；新增 `test/i18n-test.sh` 与 `test/bootstrap-test.sh`，全量断言 357 项

## v1.4.4 — 2026-11-07

- 修 `xhy check` 的过时文案：v1.4.3 把 TFO 改回可配置后，输出里仍写着 v1.4.1 遗留的 `TFO : off（固定，无开关）`。现在改为统计现网节点的实际判定：`TFO : 跟随伪装站（开 N / 关 M；--tfo auto|on|off 可覆盖）`
- `sockopt-test.sh` 加 3 条断言锁住该文案不再回退

## v1.4.3 — 2026-11-07

按三条口径重定 BBR / TFO / MPTCP：**只考虑服务端最优，默认客户端会配合**（我们开 TFO 客户端也开、我们关它也关）。

### BBR：默认开、可显式不开、选开必须真开好

- 安装时 `confirm "启用 BBR 与内核网络优化？"` **保留**，默认值仍是 `y`；选 `n` 时写 `BBR_ENABLED=off`，后续不会被强行打开
- `tune_bbr` 加**实证校验**：`sysctl -p` 返回 0 不等于生效（容器 / 只读 /proc / 被覆盖都会假成功）。按实测 `tcp_congestion_control=bbr` 且 `default_qdisc=fq` 才写 `BBR_STATUS=on`，否则 `apply-failed` 并返回非 0
- 新增 `bbr_ensure()`：幂等兜底，实测没生效才重新下发，接入 `cmd_install` / `xhy bbr on` / `xhy update config`；已生效时不重写 sysctl 文件、不堆备份
- `xhy bbr status` 加「实际生效 yes/NO」行；`xhy check` 里 `BBR_ENABLED=off` 时不干预

### TFO：默认跟随伪装站，用户可显式覆盖

**补测翻案**：Xray 的 `tcpFastOpen` 在 26.10.31 上是**生效的**（早期判「不生效」的判据不成立）：

| 场景 | 实测 |
|---|---|
| 入站 true + 带有效 cookie 的 SYN（1542 B early data） | SYN-ACK 的 ack 跳过 1542 字节、`TCPFastOpenPassive` 每次 +1、`curl http=200` |
| 入站 true + 首次 `cookiereq`（换目标 IP 绕开 cookie 缓存） | SYN-ACK 回 `tfo cookie 88c5d6bf…`（option 34）、`CookieReqd` +1 |
| 入站 false | `Passive` 不变、SYN-ACK ack 只 +1（early data 被丢） |
| `tcpFastOpenQueueLength` 写不写 | 不影响上述结果 |

早期用「客户端只发 cookiereq 时 SYN-ACK 无 option 34」判「不生效」是错的 —— 那条路径下服务端本来就不该回 34。

因此改成**跟随伪装站**（这正是伪装一致性的正确实现）：目标支持 → 默认开，白拿首连 1 RTT；目标不支持 → 默认关，否则探测者发一个带 `cookiereq` 的 SYN，我们回 option 34、真实站点不回，一眼可区分。现网 easeus 源站不支持，`auto` 判定为关，**现网行为零变化**。

- 恢复 `--tfo auto|on|off`（`auto` 默认，`on/off` 强制覆盖）；判定结果写进节点 env 的 `TFO`，重建配置不重复探测
- 新增 `target_tfo_detect()`：`curl --tcp-fastopen` 连打 3 次，看内核 `TcpExtTCPFastOpenActive` 是否增长。实测不支持的 easeus delta=0、启用 TFO 的 Xray delta=3。**不需要 tcpdump** —— v1.3.0 那个恒 false 的探测用普通 connect 发 SYN（不带 option 34），判据本身不成立
- `sockopt_json` 重新读 `TFO`：`1 → tcpFastOpen:true`，`0/未设置 → false`

### 扫描：可选「必须 TFO」+ 3-5 个候选让用户选

- `xhy scan --require-tfo` / `xhy target → 7)` / 交互提问：只列出支持被动 TFO 的候选；默认不强制，按质量选（结果也可能含支持 TFO 的站）
- 扫描完列出**前 3-5 个候选**（分数、IP、SNI、握手、HTTP、TFO 标记）由用户选编号；脚本化调用（无 tty）自动取最高分
- TFO **不参与打分**，只做可选硬过滤。理由：伪装站不承载正常代理流量（REALITY 只把未认证探测转发过去），它的带宽/延迟**不影响代理上网速度**；支持被动 TFO 的站点在公网上是少数，加权或强制会把候选池往冷门站带、削弱抗探测可信度，换来的只是 1 RTT。先按质量选最优站，再读它的 TFO 能力决定我们开不开
- TFO 能力不写进 7 天缓存：它是站点当前配置，缓存反而可能过期；展示短名单时现场探测，同一次调用内去重

### MPTCP

保持 v1.4.2 的三层全关（sockopt `false` + `GODEBUG=multipathtcp=0` + `net.mptcp.enabled=0` / `tcp_migrate_req=0`），未改动。

### 测试

新增 `test/bbr-test.sh`（15 项：决策表 + 状态判定 + 接线）、`test/tfo-test.sh`（17 项：探测判据 + --resolve + 失败保守关闭）、`test/shortlist-test.sh`（17 项：短名单 + 强制过滤 + 交互降级）；`sockopt-test.sh` 重写为 54 项、`render-test.sh` 改断言。全套 **263 项**通过。

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

