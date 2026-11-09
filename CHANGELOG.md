# 变更记录

版本号规则见 README「版本号与发布」；改版本号请用 `tools/bump-version.sh`。

## v1.14.4 — 2026-11-09

- fix(update): 自动 relay reapply 不再被配置锁自己挡住 —— main() 从 acquire_lock 起全程持有 flock fd 9（或 .lock.d），update_script 起的新脚本子进程会继承 fd 9 / 看到目录还在，于是自己 acquire_lock 等 15 秒后 die（v1.14.3 硅谷实机：日志出现「自动重建 config.json…」随后「另一个 xhy 实例正在修改配置」+ warn）。现在起子进程前先 release_lock + exec 9>&- 释放父进程锁，子进程自己拿锁；父进程之后只剩打印与 return，不改配置。XHY_RELAY_SCHEMA 2→3 强制触发一次以端到端验证
- test: update-relay-test 42→44（断言起子进程前 release_lock 与关闭 fd 9）；全套 19 文件 846 项断言全绿

## v1.14.3 — 2026-11-09

- fix(firewall): 链重建不再静默清掉落地机 relay 放行规则 —— v1.14.2 修好 node_rebuild_all 后，xhy update config 第一次真正跑通，反而暴露 _apply_family 每次「清空链 → 重写」会把 relay_fw_add 单独插入的 ACCEPT tcp dpt:14430 src <entry> 清掉（硅谷实机：update config 后 relay status 报「防火墙规则缺失」、iptables 链里无该规则）。新增 firewall_extra_rules 空钩子（hardening.sh），在 _apply_family 写完 RETURN 后调用；relay.sh 覆盖它，仅对 land 角色按 family 补回规则。开机重放 / firewall apply / update config 全部覆盖
- feat(update): XHY_RELAY_SCHEMA 1 → 2（relay 契约变更），指纹白名单补 firewall_extra_rules（该函数不以 relay_ 开头，否则新增它不会被指纹发现）。v1.14.2 → v1.14.3 因此成为首次真正触发「自动 relay reapply」的升级：旧脚本已内置判定逻辑，新脚本 relay 函数集有变 + schema 不同 → 东京/硅谷自动 reapply，新加坡无 relay.env 不触发
- test: hardening-test 42→48（链重建后 relay 放行被补回 / 源 IP 正确 / safe 与 strict 下均在 DROP/RETURN 之前 / 无 relay.env 时不加规则）；update-relay-test 38→42（钩子源码接线 + 钩子函数体改动能被指纹发现）。全套 19 文件 844 项断言全绿

## v1.14.2 — 2026-11-09

- fix(nodes): relay.env 不再被当成节点 —— 新增公共 node_env_files()（文件名 <mode>_<port>.env + 必须有 MODE= 行），替换 nodes/export/hardening/update/links 共 11 处裸扫 *.env 的遍历点。旧版 node_list 出现一行 MODE/PORT/UUID 全空的幽灵记录、node_count 把 relay.env 算成第 2 个节点（菜单显示「节点 2 个」）、node_pick 把它列成可选节点，而 xhy update config（node_rebuild_all）拿 relay.env 去 write_fragment 直接报「未知节点类型: 」rc=1。东京/硅谷实机复现，新加坡无 relay.env 故正常
- feat(update): 涉及 relay 的脚本升级自动 relay reapply，不涉及就不动 Xray —— 新增 _update_relay_fingerprint()（新旧脚本里所有 relay_*/extra_* 函数体 + XHY_RELAY_SCHEMA 的 SHA-256）与 update_script_relay_reapply_needed()。只有「本机 relay.env 存在且角色 entry/land」+「指纹有变化」同时满足，才用替换后的新脚本起子进程跑 relay reapply；纯注释 / 文案 / 其它模块改动不触发。失败只 warn，不影响升级本身。XHY_RELAY_SCHEMA 是逃生口：改了 config 生成逻辑但函数体没变时手工 +1
- docs: README 把「涉及 relay 的升级另跑 xhy relay reapply」改为自动机制说明；xhy relay reapply 降级为手动兜底。测试状态 18 文件约 800 项 → 19 文件约 840 项
- test: 新增 test/update-relay-test.sh 38 项（node_env_files 过滤 / node_count / node_list 无幽灵行 / node_pick / node_rebuild_all 有 relay.env 仍 rc=0 / 指纹对注释与 relay 改动的区分 / 自动 reapply 三分支 / 源码接线）；修 hardening-test 的夹具文件名（n1.env → vless_8443.env 等，旧夹具不符合生产命名会被过滤）。全套 19 文件 834 项断言全绿

## v1.14.1 — 2026-11-09

- fix(core/update): geodata 切源不再被「1h 内跳过」静默吞掉 —— 新增 /usr/local/share/xray/.geodata-source 源标记，只在两个 dat 全部下载成功后写入；update_geodata 的跳过条件同时比对 age 与源标记，切 --source / 改 XHY_GEODATA_SOURCE 一小时内立即可生效，ok 文案也不再拿本次请求值冒充实际来源。xray_install 铺完 dat 后同步写标记，update all 不会重复下 30 MB
- fix(core): Loyalsoldier geodata 补强制完整性校验 —— 下 release 附带的 .sha256sum 并逐个验 SHA-256（格式非法/不匹配即保留旧文件并计失败）；geodata_install_loyalsoldier / geodata_install_official 现在两个 dat 全成功才返回 0，部分失败不再被当成完成。core_status 把 <6 MB 标为「体积异常（疑似损坏/截断）」，不再把截断的 Loyalsoldier dat 误标成官方版
- fix(relay): status/test 增加 config.json 与 relay.env 的一致性校验 —— 新增 relay_fallback_cfg_tag()，发现 config 的 fallbackTag 与期望值不符就告警并提示 xhy relay reapply。修掉 relay_test 里那条会破坏配置的错误提示命令（旧文案 'xhy relay entry --fallback-tag block' 缺必填 --to、且会重置 UUID 与分类），改为 xhy relay reapply
- test: 修掉两处假通过 —— '显式 direct 有告警' 原来抓 relay_status 里的 direct 字样恒真（且 warn 走 stderr 被 2>/dev/null 吞掉），改为抓 relay_entry 的真实告警输出；'reapply 后不再报不一致' 同样修正输出流。新增切源不被跳过 / 切源后 stamp 更新 / 下载失败不写 stamp / config 与 env 不一致告警 等回归。geodata-test 31→41 项、relay-test 145→148 项，全套 18 文件 796 项断言全绿
- docs(README): 全面更新与 v1.14.x 不符的陈旧内容 —— 删掉早已废弃的 git clone 安装方式与差别表、纠正 xhy 为普通文件非软链、SSH 双窗口阈值 60s/10+1h/25 → 60s/30+1h/120 且补 --rcheck 前置说明、补 --source/--force/--png/relay reapply、lib 清单补齐 6 个模块、目录树补 relay.env 与 .geodata-source、测试状态 158 项 → 18 文件约 800 项

## v1.14.0 — 2026-11-09

- feat(core): geodata 默认源改回 **Loyalsoldier 完整版**（v1.13.x 曾改成官方版）。拆 protobuf 逐域名实测：Xray 官方 release 自带的 dat 是 Loyalsoldier 版的**真子集**，差异全部是「仅 Loyalsoldier 有」—— google 少 114 条（notebooklm / antigravity / geminiweb-pa / cloudcode-pa / scholar.google.* 等）、gfw 整个分类缺失 4433 条、geolocation-!cn 少 3819 条、category-ai-!cn 少 2（grokbot.com / Copilot azure host）、anthropic 少 1、xai 少 1、github-copilot 少 1、disney 少 2；官方「多出来」的只有 geolocation-!cn 里 13 条乱码/正则写法差异，实质 0 条。3.9 MB 的体积差全在 category-ads-all（905 vs 199451），但换来 AI/Google/gfw 覆盖不全，不值。XHY_GEODATA_SOURCE=official 或 --source official 仍可取官方版
- feat(relay): **落地失联直接断联，绝不东京直出** —— balancer 的 fallbackTag 从 direct 改成 block（blackhole）。v1.11~1.13 的 direct 会让出口 IP 从硅谷 47.88.102.45 变成东京 47.245.14.31，AI/流媒体站看到地区跳变会触发风控。新增 --fallback-tag block|direct（默认 block，显式 direct 才恢复旧行为并告警）；--no-fallback 仍是硬死指，同样断联。RELAY_FALLBACK_TAG 持久化进 relay.env
- feat(update): xhy update geodata 新增 --source loyalsoldier|official；默认 1 小时内刚更新过就跳过（update all 不重复下 30 MB），--force 强制。xhy core status 现在把 >9 MB 标「Loyalsoldier 完整版（默认）」、官方版标「子集：缺 gfw / google 114 条等」
- test: geodata-test 31 项（默认源 / --source / env / 1h 跳过 / --force / 非法值回落）；relay-test 137 -> 145 项（fallbackTag=block / 绝不 direct / block 出站存在 / relay.env 持久化 / --fallback-tag direct 恢复旧行为 / 非法值被拒）

## v1.13.3 — 2026-11-09

- fix(hardening): SSH 守卫改用 --rcheck 在前、--set 在后 —— 旧版先无条件 --set 再 --update --hitcount，撞锁后每个重试包都往滑窗顶时间戳，窗口永远满，越试越锁（实测硅谷单次会话被 DROP 674 次、家宽 IP 在 xt_recent 表里顶满 32 条）；顺序反转后命中 DROP 即停止记录，60 秒滑窗自然滚动，静默等一分钟自动解锁，不再需要 VNC 清表
- fix(hardening): 阈值放宽 60s/10→60s/30、1h/25→1h/120。VS Code Remote / scp 批量 / 家宽运营商 NAT 共享一轮就是 5-10 个新连接，10 次一分钟是误伤不是防护；阈值提为 SSH_BURST_WINDOW/HITS + SSH_SLOW_WINDOW/HITS 常量，status 文案从硬编码改成读常量（旧文案还挂着早已失效的 5/8）
- fix(relay): 落地机放行规则用 -I 插到链尾 RETURN/DROP 之前 —— 旧版 -A 追加到 XHY-IN 末尾，落在 -j RETURN 之后永不命中，而 -C 仍返回 0，relay status 报「已放行」实际靠 INPUT 默认策略兜底；新增 _relay_fw_term_pos/_relay_fw_own_pos，relay_fw_add 就地纠正错位旧规则，relay_fw_present 改为「存在且位置有效」
- test(hardening): 新增 test/hardening-test.sh 42 项 —— 有状态假 iptables（真支持 -N/-F/-A/-I/-D/-C/-S）断言规则行序：rcheck 在 set 前、无 --update、两窗口阈值、strict 下 SSH/relay 均在 DROP 前、RETURN 之后死规则被识别并迁移、无 RETURN 链退回 -A；run-all 从 17 个测试文件增至 18

## v1.13.2 — 2026-11-09

- fix(relay): `relay status --brief` 的域名计数差一 —— `printf '%s' | tr ',' '\\n' | wc -l` 的最后一个字段没有换行，7 个域会报成「+6域」；改 `printf '%s\\n'` + `grep -c .`。实测东京 13 分类 7 域现在显示正确
- test(relay): 135 -> 137 项，新增 brief 报 +3域 / 不出现 +2域 两条

## v1.13.1 — 2026-11-09

- fix(core): geodata 下载 URL 补 release tag 的 v 前缀 —— `xray version` 输出 26.10.31，而 Xray 的 release tag 是 v26.10.31，`xhy update geodata --force` 因此 404（真实踩到：sanjose / singapore 升级后第一条 geodata 命令就报 22）；latest 分支改走 releases/latest/download/<asset>，不再拼 tag 段
- test(geodata): 25 项，新增「release tag 补 v 前缀」「latest 走 /releases/latest/download」两条断言

## v1.13.0 — 2026-11-09

- feat(core): geodata 默认源改回 **Xray 官方 release 内置的 dat**（v1.12.x 曾无条件覆盖成 Loyalsoldier 版）。实测两份标签集几乎相同（官方 1564 个 tag / Loyalsoldier 1562 个，openai、category-ai-!cn 214/218、google-gemini、github-copilot 两边都有），3.9 MB 的体积差几乎全在 category-ads-all（905 vs 199 451 条）；日常用的是 category-ads / geolocation-!cn / 各 AI 分类，为一张用不到的广告表多占 4 MB 没意义。安装/升级核心时 zip 里的官方 dat 直接铺好，不额外下载
- feat(update): xhy update geodata 重写 —— 官方不单独发 dat 资产，改为下载对应版本的 Xray-linux-<arch>.zip（16.7 MB）解出两个 dat，同样强制校验 .dgst；版本跟随已装核心（未装才退回 latest），dat 比核心二进制新就跳过，避免 xhy update all 重复下载，--force 强制重下
- test(geodata): 新增 test/geodata-test.sh 23 项 —— 官方源接线、整包校验、同源跳过 / --force / 陈旧重下三分支、版本跟随核心、core status 只对异常体积告警
- fix(nodes): `BLOCK_ADS=on` 的拦截规则从 `geosite:category-ads-all` 一条改成 `category-ads` + `category-ads-all` 两条 —— 官方 dat 的 `category-ads-all` 只有 905 条，单押它会漏一大批；`category-ads` 官方 845 / Loyalsoldier 849，两边几乎一致，官方版也能挡住主体
- docs: relay --domains 的用法文案去掉「精简版 geosite 缺分类」的错误说法（真相：那些站在官方版和 Loyalsoldier 版里都不属于任何 AI 分类）；xhy core status 对 >9 MB 的 geosite.dat 标「疑似 Loyalsoldier 版」

## v1.12.3 — 2026-11-09

- fix(link): XHY_NODES 目录下的 relay.env 是中继状态文件（无 MODE），旧版 link_all 把它也当节点导出，link_uri 报「未知模式」并让 xhy link --qr / --png 退出码变 1 —— 落地机（硅谷）必现。新增 link_node_files() 只列带 ^MODE= 的 env，link_all / --uri / 多节点计数统一改用它
- test(link): +3 项 relay.env 跳过断言，link-test 17 -> 20 项，全套回归全绿

## v1.12.2 — 2026-11-08

- fix(docs): 纠正 geosite 说明 —— 实测官方 release 自带版与 Loyalsoldier 版**标签集几乎一致**（1564 vs 1562 个 tag，openai/category-ai-!cn 两边都有），7.5 MB vs 11.4 MB 的差全在 category-ads-all（905 vs 199451 条）。统一来源的真实收益是「同机两份 geo 不再打架」+ 广告表 220 倍，不是补分类
- fix(core): xhy status 的体积提示改为「release 自带版（category-ads-all 仅 905 条）」，不再暗示缺分类

## v1.12.1 — 2026-11-08

- feat(relay): --categories 放开 ! 字符 —— v2fly / Loyalsoldier 的 AI 分类真名就叫 category-ai-!cn（218 条域名，含 perplexity / x.ai / cursor / elevenlabs / huggingface / poe / midjourney），此前字符集把它挡在门外，只能用 --domains 一条条补；--domains 的 geosite: 前缀同样放开
- test(relay): 131 -> 135 项，新增 category-ai-!cn 被接受 / geosite: 前缀可带 ! / 含空格分类仍被拒

## v1.12.0 — 2026-11-08

- feat(relay): 新增 --domains 明文域名规则 —— geosite 分类覆盖不到的站（实测 character.ai / replicate.com / suno.com / runwayml.com / luma.ai / ideogram.ai / stability.ai 这些 AI 站**不在任何 AI 分类里**，只出现在 geolocation-!cn / gfw 里）现在可以直接写 domain/full/keyword/regexp/geosite 规则，与 geosite 分类同处一条 domain 数组；relay.env 持久化 RELAY_DOMAINS，不传 --domains 时沿用旧值，--no-domains 清空
- fix(relay): regexp 规则里的反斜杠在写进 JSON 前转义为 \\，否则 regexp:^a\.b$ 会产出非法 JSON 让 xray 起不来
- test(relay): 115 -> 131 项，新增裸域名补前缀 / 前缀原样保留 / 与 geosite 合并同规则 / 沿用旧值 / --no-domains 清空 / 引号与空格与空值被拒
- feat(core): 统一 geodata 来源 —— xray 安装 / 升级后**一律**用 Loyalsoldier 版覆盖 release zip 自带的那份。实测两份**标签集几乎相同**（官方 1564 个 tag / Loyalsoldier 1562 个，`openai`、`category-ai-!cn` 等两边都有），7.5 MB vs 11.4 MB 的差几乎全在 `category-ads-all`（905 vs 199451 条）。统一的理由：`update geodata` 本就用 Loyalsoldier 而 install 用 zip 自带的，同机两份 geo 会对不上；且 19.9 万条广告表让 `geosite:category-ads-all → block` 真正有效。磁盘余量 <60 MB 或 `XHY_SKIP_GEODATA=1` 时跳过
- feat(core): `xhy core status` 对 <9 MB 的 geosite.dat 标注「release 自带版（category-ads-all 仅 905 条）」，不再需要人工比对体积

## v1.11.5 — 2026-11-08

- fix(i18n): xhy lang en 是全局持久化的，VNC 乱码时设一次会把普通 SSH 会话也变成英文。auto 新增 tty 设备判定（/dev/tty1..6、/dev/ttyS0 -> en；/dev/pts/N -> zh），并修正 POSIX prelude 把空 LANG 当 C locale 的旧误判。VNC 只想要英文请用 xhy lang auto，不要 lang en
- feat(link): 分享链接导出加二维码。xhy link [--all|--uri] [--qr] [--png FILE] 与 xhy link <mode> [port] [--qr] [--png FILE]：--qr 在终端打印可扫二维码（UTF-8 用 ANSIUTF8，控制台/英文模式用 ANSI），--png 存 0600 PNG（多节点自动加 MODE_PORT 后缀）。ensure_optional 在 Alpine 用 -X 临时 community 源装 libqrencode-tools，绕开精简镜像注释掉 community 导致 no such package
- chore: 删掉 entry/main.sh 里重复的 cmd_link/cmd_uninstall 定义块（50 行）；test: 新增 link-test.sh 17 项，i18n-test 增 4 项 tty 判定，全套回归全绿

## v1.11.4 — 2026-11-08

- fix(relay): RELAY_GEOIP_US 默认从 on 改为 off —— 此前 relay entry 不带 --no-geoip-us 就把 Cloudflare/AWS/GitHub 等美国 CDN IP 全量绕东京→硅谷一圈（55ms→162ms 且跨 region 双倍计费）；现只按 geosite 分类转发，要恢复旧行为必须显式 --geoip-us on
- fix(relay): relay entry 默认 geoip=off 并写进 relay.env；status/brief 显示与 usage 默认值同步；--no-geoip-us 保留为 --geoip-us off 的兼容别名
- test(relay): 109 → 115 项，新增「默认不含 geoip:us」「relay.env 默认 off」「--geoip-us on 显式恢复」「非法值被拒」

## v1.11.3 — 2026-11-08

- fix(relay): sockopt 必须嵌在 streamSettings 内。v1.11.0 出站 / v1.11.2 入站都把 sockopt 写在 inbound/outbound 顶层，Xray 当 unknown field 静默忽略，run -test 仍报 Configuration OK 但 setsockopt 一次都不调 —— 这两版的 TFO/keepalive/BBR 全部零效果。tcpdump 对照坐实：顶层写法 SYN 无 option 34、两端 TFO 计数全 0；同一抓包里把 sockopt 放进 streamSettings 的临时实例 SYN 带 tfo cookiereq、硅谷 TCPFastOpenCookieReqd 0->6
- test(relay): 96 -> 109 项，新增 sockopt 层级 JSON 断言（必须在 streamSettings 内且顶层不得出现）；relay test 落地端自检改为校验嵌套位置与顶层无重复

## v1.11.2 — 2026-11-08

- fix(relay): land 入站补 sockopt（tcpFastOpen=true / tcpNoDelay / tcpKeepAliveIdle / tcpUserTimeout / tcpMptcp:false / BBR 跟随系统）。内核 net.ipv4.tcp_fastopen=3 只是允许位，服务端真开关是 listen socket 的 setsockopt(TCP_FASTOPEN)；此前只有 entry 出站开 TFO，实测两端 TcpExtTCPFastOpenPassive=0 / TCPFastOpenActive=0，这一跳省不到那个 107ms 握手 RTT
- feat(relay): relay test 落地端新增入站 TFO 自检；relay-test 96 -> 106 项，全套回归全绿

## v1.11.1 — 2026-11-08

- fix(relay): routing 规则指向 balancer 必须用 balancerTag（Xray 26.x 把 outboundTag 当出站 tag 查，写 us-relay-lb 报 non existing outTag 并丢包，AI 分类流量全 000）
- test(relay): 路由规则断言改认 balancerTag，rules_order_ok 兼容两种字段

## v1.11.0 — 2026-11-08

- feat(relay): 中继这一跳恒为 security=none —— 两端自有机器 + 云厂商内网，客户端到目标站 TLS 已端到端，再套一层只多一次握手与落地机每字节一遍 AES。--tls/--sni/--pin 停用为兼容占位（不再产出任何 tlsSettings）；v1.10.x 的旧 relay.env 读入时自动降级为 none
- feat(relay): 出站补 sockopt（tcpFastOpen=true / tcpNoDelay / tcpKeepAliveIdle / tcpUserTimeout / BBR 跟随系统），省掉每条新连接一次 TCP 握手；--no-tfo 可关，开关持久化进 relay.env
- feat(relay): 落地失联自动回落 —— nodes.sh 新增 extra_routing_head_json / extra_top_json 两个钩子，relay 注入 balancer(leastPing, fallbackTag=direct) 与顶层 burstObservatory(60s 探活 gstatic 204)；--no-fallback 回到 v1.10.x 死指行为
- test(relay): 77 → 96 项（恒明文、旧 tls 状态自动降级、sockopt、balancer/observatory 位置与形状、--no-fallback/--no-tfo、非法值拒绝）；全套 654 项通过

## v1.10.1 — 2026-11-08

- fix(relay): Xray 26.x 移除了 `allowInsecure`、`pinnedPeerCertificateChainSha256` 也只吃 hex —— TLS 出站改用 `pinnedPeerCertSha256`（64 位小写 hex）+ 无 pin 时 `verifyPeerCertByName`；旧 relay.env 里的 base64 pin 自动转 hex，非法 pin 直接报错不静默降级
- fix(relay): 自签证书补 `subjectAltName`（Go 1.27 拒绝只带 CN 的证书）；历史证书缺 SAN 时就地重签，不用手工删文件
- fix(relay): entry 无 pin 时 SNI 默认 `relay-<port>` 而不是落地 IP —— 否则 verifyPeerCertByName 拿 IP 比证书 SAN 必然失败（入口 `--tls` 不带参数即可通）
- feat(relay): `relay export` 反向命令补 `--tls --sni`、vless:// 链接补 `sni`；`--pin` 帮助文本改 HEX 并说明兼容旧 base64
- test(relay): 55 → **77** 项（pin 归一 hex/大写/冒号/base64、pinnedPeerCertSha256、verifyPeerCertByName、SNI 自动对齐、缺 SAN 证书重签）

## v1.10.0 — 2026-11-07

- feat(relay): 收编进基础管线 —— nodes.sh 新增 extra_outbounds_json / extra_routing_rules_json 两个空钩子，relay 覆盖它们；xhy add/edit/del/config set 触发的基础 rebuild 不再冲掉 relay 出站与前置路由（v1.9.3 的「已知限制 1」消除）
- fix(relay): 激活后从不 config_reload —— 配置写进 config.json 但运行中的 xray 没生效；改用共享 xray_config_test（带 XRAY_LOCATION_ASSET，geosite 引用不再误判）+ config_reload
- feat(relay): 新增 --tls（自签证书自动生成 + 证书链 pin）/ --no-geoip-us / --categories 预设 ai|media|none / IPv6 上游 [v6]:port / relay export / 同机 land↔entry 角色互清 / land 重复执行幂等 / 防火墙按注释精确增删
- fix(relay): 自带中英双语句对，XHY_LANG=en 机器上不再整句被词表吞成空白；xhy check 增一行 relay 状态；usage 中英同步
- test(relay): 55 项离线断言（配置 JSON 合法性、relay 规则前置顺序、假 iptables 记账、角色切换、参数注入拒绝、TLS 片段）

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

