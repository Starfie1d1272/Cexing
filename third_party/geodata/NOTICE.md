# GeoData 来源、许可与规则变化

本包 `geoip.metadb` 从固定输入生成：DB-IP 2026-10 Country Lite 和 ASN Lite，gaoyifan/china-operator-ip 中国运营商列表，Tor Metrics 出口快照，以及 Cloudflare、Telegram、Google、Fastly 和 AWS 公开 IP 列表。输入、摘要、转换脚本、来源及差异见源码包 `third_party/geodata-candidate/`。DB-IP 数据依据 CC BY 4.0 使用：IP Geolocation by DB-IP，https://db-ip.com ；许可正文为 `licenses/DBIP-CC-BY-4.0.txt`。Tor Metrics 对其站点数据提供 CC0 声明，gaoyifan 快照附 MIT 许可。服务商快照的具体适用条件和来源说明见源码包；请勿把某一个项目根许可当作所有数据的许可。

GeoIP 使用 DB-IP Lite 的国家与 ASN 数据，精度和覆盖与旧 GeoLite 不同；CN 沿用运营商输入语义，服务商 IP 和 Tor 数据按固定快照更新。各分类地址集合增减统计见源码包 `third_party/geodata-candidate/IP-DIFF.jsonl`。转换器 `MetaCubeX/geo` 按 GPL-3.0 提供，固定来源、补丁与 Go 依赖声明随源码包；工具许可本身不自动决定输出数据许可。

GeoSite 以固定 MetaCubeX 基线保留闭包之外的分类；CN、STEAM、ONEDRIVE 及其 11 项派生分类（反向 include 闭包共 14 项），TRACKER、GFW、GOOGLE-CN、APPLE-CN 使用固定 v2fly、gfwlist、dnsmasq-china-list 数据和本项目记录的转换规则重建。v2fly 固定提交 `333d8a1810d04600bcb00870155a369954ed37f5` 为 MIT；gfwlist 固定提交 `986098e6890e34b5e14f04209714f741bbe6313d` 的规则与 LGPL-2.1 许可、转换脚本及其 GPL-3.0 正文随源码包；dnsmasq-china-list 固定提交 `d6f9c70b70e8f4bc539f8c3f84975ce14a7b209b` 的输入和 WTFPL 许可随源码包。具体规则、完整分类差异统计见 `third_party/geodata-source/GEOSITE-DIFF.json`。基线文件的来源身份记录在构建报告；源码附件提供清空替换分类后的固定基线与生成脚本，不分发已替换分类的旧混合输入；可用 `scripts/ci/sanitize-geosite.go` 从记录的上游基线重新生成该文件。

HTTPDNS 取 [GetSomeFries 固定版本](https://github.com/VirgilClyne/GetSomeFries/blob/b4aa767bcbc4d39bea5b549a3277a00517891d1e/ruleset/HTTPDNS.Block.list) 的原有 22 项，原文件和 GPL-3.0 许可随包。`httpdns.baidu.com`、`httpdns.baidubce.com`、`httpsdns.baidu.com` 从该上游精确匹配改为后缀匹配，保留先前行为；不引入上游额外域名或 IP。

本次规则覆盖有变化：CN 改用 v2fly `tld-cn` 与 `geolocation-cn`；STEAM 的 `@cn` 不再覆盖全部全球 CDN；ONEDRIVE 不再专门匹配旧的 `spoprod-a.akamaihd.net` 等五个辅助主机；TRACKER 的规则来源改为 v2fly 两表，`cgpeers.com` 不再命中该专门分类。ONEDRIVE 保留 `1drv`、`onedrive`、`skydrive` 关键词，TRACKER 保留 `announce`、`chdbits`、`m-team`、`torrent` 关键词，均可能宽泛匹配其他名称。未命中分类的流量继续按配置中后续规则处理。

BILIINTL 删除未能独立确认用途的 `upos-bstar-mirrorakam.akamaized.net`，旧客户端如仍使用该主机将落到后续规则；不扩大到整个 `akamaized.net`。`p-bstarstatic.akamaized.net` 与官方 `p.bstarstatic.com` 的同一静态资源于 2026-10-29 分别返回 80,723 字节，SHA-256 均为 `07fbec694248c62faf34c881414b92b70168517e3f57f40507f285abaf7489b7`；这里只保存事实和摘要，不分发该脚本。完整主机沿用旧后缀匹配。SHAREPOINT 三项来自固定 v2fly Microsoft 数据。

构建和发行检查核对资产身份、实际包含的声明与来源材料；它们不替代具体许可条件、订阅出口或设备验证。
