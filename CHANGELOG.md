# 变更记录

版本号规则见 README「版本号与发布」；改版本号请用 `tools/bump-version.sh`。

## v1.2.0 — 2026-11-06

- 新增 `xhy scan`：集成 XTLS/RealiTLScanner，扫描 VPS 所在 /24（无合格结果自动扩到同机房 /21），再用真实 SNI 逐个验证证书/跳转/CDN，取最优站点
- 扫描结果缓存到 /etc/xray-hy/scan-cache.tsv（默认 7 天有效）：之后新建 REALITY 节点直接复用，不再重复扫描；缓存候选在采用前仍会过一遍 REALITY 级校验
- 新建 REALITY 节点时可选择「自动扫描 / 内置地区库 / 手动指定」；CLI 新增 --scan、--scan-cidr、--scan-refresh，扫描结果为 dest=源站 IP + SNI=域名
- `xhy target` 菜单新增 7) 自动扫描、8) 查看/复核/清除缓存；`xhy check` 显示扫描器与缓存状态；`xhy version` 带 build 号
- 版本号规则落地：major=不兼容变更，minor=新功能，patch=修复；新增 tools/bump-version.sh 统一改两处版本号，build.sh 校验一致性

