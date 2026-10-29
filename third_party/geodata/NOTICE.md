# GeoData 来源、许可与源码边界

测试包包含 `geoip.metadb` 和 `geosite.dat`，GeoIP 由 [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) 的可变 `latest` 发布取得；GeoSite 使用该项目固定提交 `be456e5c402c4a9c98519e73f09256c96914cefd` 的产物，并重新构造 BILIINTL 和 SHAREPOINT 分类。构建身份记录来源与摘要；固定 GeoSite 产物的摘要不等于固定了其完整上游输入，也不能证明对应源码完整。

GeoIP：上游使用 [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) 的 `geoip.dat`，再用 [MetaCubeX/geo](https://github.com/MetaCubeX/geo) 转换成 metadb。Loyalsoldier 项目声明 CC BY-SA 4.0，许可原文为 `licenses/GEOIP-CC-BY-SA-4.0.txt`；转换项目声明 GPL-3.0，正文为 `licenses/GPL-3.0.txt`。This product includes GeoLite2 data created by MaxMind, available from https://www.maxmind.com .

GeoSite：上游运行 [构建流程](https://github.com/MetaCubeX/meta-rules-dat/blob/4178770badecb1b349fbcd62c737e0d7a2079729/.github/workflows/run.yml)，以 [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) 为基础，使用 [Loyalsoldier/domain-list-custom](https://github.com/Loyalsoldier/domain-list-custom) 生成器并修改数据。还从 [blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script)、[felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list)、[gfwlist/gfwlist](https://github.com/gfwlist/gfwlist)（经 [cokebar/gfwlist2dnsmasq](https://github.com/cokebar/gfwlist2dnsmasq)）、[crazy-max/WindowsSpyBlocker](https://github.com/crazy-max/WindowsSpyBlocker)、[xishang0128/rules](https://github.com/xishang0128/rules) 和 [XIU2/TrackersListCollection](https://github.com/XIU2/TrackersListCollection) 等取数据；上游 README 的致谢列出其他可能贡献来源。元项目及转换工具的 GPL-3.0 不能替代各数据源条件。

保留上游可见的许可原文：v2fly 和 domain-list-custom 的 MIT、blackmatrix7 的 GPL-2.0、dnsmasq-china-list 的 WTFPL-2、gfwlist 的 LGPL-2.1、WindowsSpyBlocker 的 MIT、GeoIP 的 CC BY-SA 4.0，以及元项目、转换器与 TrackersListCollection 的 GPL-3.0，见 `licenses/`。这些是相关项目公开的许可声明，不表示已确认它们对该次所有数据的适用范围或兼容性。`xishang0128/rules` 在核查时没有可见仓库许可证，须取得适用授权或替换；GPL-2.0 与其他条件的适用及兼容性也须核实。

本次手机测试快照的上游 [run 40433225800](https://github.com/MetaCubeX/meta-rules-dat/actions/runs/40433225800) 记录元项目提交 `4178770badecb1b349fbcd62c737e0d7a2079729`、domain-list-custom `efacb51b8950ae673ebb6dcb9e7ecdd1decb1b6d`、domain-list-community `fa3cb96fbc210b8d6466251a1d71b4a6e63a9c85`、converter `7dea27841a3579a633189830c98c08a0434e8b79` 和 gfwlist2dnsmasq `202e52fb5ea2260abc9f162b3a78e58ec9187005`；可通过各仓库对应 commit 获取这些源码。它还直接拉取多个未固定的 URL/分支，日志没有完整输入摘要和全部来源的精确版本，因此不能从这些提交重建或证明全部对应源码，也不能保证可变 latest 的未来构建使用相同来源。

发行应保留实际适用的许可、署名和对应源码材料；全链从头重建并非通用条件。当前构建保留本次 GeoIP 发布的 `geoip.dat` 和固定 GeoSite 基线作为转换输入，但它们并不证明上游所有原始数据来源。blackmatrix7 直接使用规则的具体许可适用和对应源码仍在核查；CI 成功、摘要匹配和此通知不构成许可结论。

## 两个重建分类

`categories.json` 中的值均以 GeoSite `Domain`（域名及其子域）类型写入，与固定基线的两类逐条相同，包含属性与重复次数；其余分类不变。构建时验证固定输入和输出 SHA-256。

SHAREPOINT 三项均见固定的 [v2fly Microsoft 数据](https://github.com/v2fly/domain-list-community/blob/333d8a1810d04600bcb00870155a369954ed37f5/data/microsoft)（MIT）；这里保留原分类类型和无属性行为，而不引入 Microsoft 列表中 `sharepoint.cn` 的 `@cn` 属性。

BILIINTL 的 `bilibili.tv`、`biliintl.com`、`bstarstatic.com` 分别有官方网页及其脚本使用子域的证据：[页面](https://www.bilibili.tv/en)、[官方脚本](https://p.bstarstatic.com/fe-static/bstar-web-new/client/assets/index-ffb946be.js)。旧客户端接口 `api.global.bilibili.com`、`app.global.bilibili.com` 有[播放和字幕请求记录](https://github.com/ipcjs/oh-my-userscripts/issues/722)。`upos-bstar1-mirrorakam.akamaized.net`、`upos-sz-mirrorcosbstar1.bilivideo.com` 分别有 [播放记录](https://github.com/yt-dlp/yt-dlp/issues/7086)、[播放记录](https://github.com/yt-dlp/yt-dlp/issues/6908)；`upos-sz-mirroralibstar1.bilivideo.com` 有[海外 CDN 记录](https://github.com/the1812/Bilibili-Evolved/issues/3234)。`p-bstarstatic.akamaized.net` 与 `upos-bstar-mirrorakam.akamaized.net` 见 [blackmatrix7 BiliBili 列表](https://github.com/blackmatrix7/ios_rule_script/blob/0b6897dc17e0c513d25449c935a9694818e32f0c/rule/Clash/BiliBili/BiliBili.list)（GPL-2.0；该列表是精确域名，原基线对两个域名匹配其子域）。`apm-misaka.biliapi.net` 有[历史规则记录](https://clashios.app/rule/bilibiliintl)，并非官方直接证据。上述第三方历史记录只说明曾观测或收录，不能证明当前服务完整性；共享 CDN 名称仅保留明确主机，不扩到整个 `akamaized.net` 或 `bilivideo.com`。

两类由上述独立线索重新构造；但固定基线仍是现成的 MetaCubeX 二进制，其中原有输入的完整来源没有重建。实际适用的许可、署名和对应源码仍须按具体来源核对；本次身份和材料校验不代替此核查。
