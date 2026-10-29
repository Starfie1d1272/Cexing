# GeoData 来源、许可与源码边界

测试包包含 `geoip.metadb` 和 `geosite.dat`，均由 [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) 的可变 `latest` 发布取得。构建身份的 `geodata` 项记录各资产的 release/asset ID、时间、大小与 SHA-256；摘要标识本包字节，不固定其上游输入。策星不修改这两份数据。

GeoIP：上游使用 [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) 的 `geoip.dat`，再用 [MetaCubeX/geo](https://github.com/MetaCubeX/geo) 转换成 metadb。Loyalsoldier 项目声明 CC BY-SA 4.0，许可原文为 `licenses/GEOIP-CC-BY-SA-4.0.txt`；转换项目声明 GPL-3.0，正文为 `licenses/GPL-3.0.txt`。This product includes GeoLite2 data created by MaxMind, available from https://www.maxmind.com .

GeoSite：上游运行 [构建流程](https://github.com/MetaCubeX/meta-rules-dat/blob/4178770badecb1b349fbcd62c737e0d7a2079729/.github/workflows/run.yml)，以 [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) 为基础，使用 [Loyalsoldier/domain-list-custom](https://github.com/Loyalsoldier/domain-list-custom) 生成器并修改数据。还从 [blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script)、[felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list)、[gfwlist/gfwlist](https://github.com/gfwlist/gfwlist)（经 [cokebar/gfwlist2dnsmasq](https://github.com/cokebar/gfwlist2dnsmasq)）、[crazy-max/WindowsSpyBlocker](https://github.com/crazy-max/WindowsSpyBlocker)、[xishang0128/rules](https://github.com/xishang0128/rules) 和 [XIU2/TrackersListCollection](https://github.com/XIU2/TrackersListCollection) 等取数据；上游 README 的致谢列出其他可能贡献来源。元项目及转换工具的 GPL-3.0 不能替代各数据源条件。

保留上游可见的许可原文：v2fly 和 domain-list-custom 的 MIT、blackmatrix7 的 GPL-2.0、dnsmasq-china-list 的 WTFPL-2、gfwlist 的 LGPL-2.1、WindowsSpyBlocker 的 MIT、GeoIP 的 CC BY-SA 4.0，以及元项目、转换器与 TrackersListCollection 的 GPL-3.0，见 `licenses/`。这些是相关项目公开的许可声明，不表示已确认它们对该次所有数据的适用范围或兼容性。`xishang0128/rules` 在核查时没有可见仓库许可证，须取得适用授权或替换；GPL-2.0 与其他条件的适用及兼容性也须核实。

本次手机测试快照的上游 [run 40433225800](https://github.com/MetaCubeX/meta-rules-dat/actions/runs/40433225800) 记录元项目提交 `4178770badecb1b349fbcd62c737e0d7a2079729`、domain-list-custom `efacb51b8950ae673ebb6dcb9e7ecdd1decb1b6d`、domain-list-community `fa3cb96fbc210b8d6466251a1d71b4a6e63a9c85`、converter `7dea27841a3579a633189830c98c08a0434e8b79` 和 gfwlist2dnsmasq `202e52fb5ea2260abc9f162b3a78e58ec9187005`；可通过各仓库对应 commit 获取这些源码。它还直接拉取多个未固定的 URL/分支，日志没有完整输入摘要和全部来源的精确版本，因此不能从这些提交重建或证明全部对应源码，也不能保证可变 latest 的未来构建使用相同来源。

正式分发前必须获取并保存每个输入的精确版本、许可和适用归属，确认兼容性与对应源码提供方式，或替换/移除无法确认授权的输入；目前这项核查未完成，不能将现有源码包或上游可变链接描述为完整对应源码。CI 成功、摘要匹配和此通知均不构成发行许可结论。
