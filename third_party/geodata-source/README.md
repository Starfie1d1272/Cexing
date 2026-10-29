# GeoSite 源数据与覆盖变化

- `community/baseline.dat`：上游 MetaCubeX 固定基线清空 21 个将重建的分类后所得固定输入，SHA-256 `ea5bc44cf6d2baba4167a906243c28907de8277d8f141db1548cd79732aadf13`；生成方式见 `scripts/ci/sanitize-geosite.go`。未替换分类保持不变。
- `community/source.tar.gz`：v2fly/domain-list-community 固定提交 `333d8a1810d04600bcb00870155a369954ed37f5` 的完整源码与 MIT 许可。由该项目原生生成器展开 include 和属性；本项目对 OneDrive、tracker 与 `geolocation-!cn` 的局部组合记录在 `scripts/ci/build-geosite-input.py`。
- `gfwlist/`：gfwlist/gfwlist 提交 `986098e6890e34b5e14f04209714f741bbe6313d`，含 `list.txt`、`gfwlist.txt`、LGPL-2.1 正文与转换后域名。`gfwlist2dnsmasq/` 是 cokebar/gfwlist2dnsmasq 提交 `202e52fb5ea2260abc9f162b3a78e58ec9187005` 的转换脚本及 GPL-3.0 正文。构建使用本地固定输入重做转换并验证生成域名一致。
- `dnsmasq-china/`：felixonmars/dnsmasq-china-list 提交 `d6f9c70b70e8f4bc539f8c3f84975ce14a7b209b` 的 Google / Apple 输入及 WTFPL 许可。

`GEOSITE-DIFF.json` 是新旧分类条目增减与共享值类型/属性变化的统计。添加和删除条目可能表示同一域名的类型或属性变化，不能直接解释成独立的匹配数量。实际变化和代表例子见 `third_party/geodata/NOTICE.md`；原订阅仍可引用各分类，但未命中时会按后续规则处理。
