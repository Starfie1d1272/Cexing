# GeoSite 上游来源参考快照

这些文件随对应源码包提供，来源、提交和 SHA-256 由构建身份及发行材料校验记录。它们是可复核的上游参考快照，不声称为固定 GeoSite 基线构建时所下载的精确版本：该次上游任务的动态下载没有可核验的逐文件身份。

- `gfwlist/`：gfwlist/gfwlist `986098e6890e34b5e14f04209714f741bbe6313d`，含规则和 LGPL-2.1 正文。
- `gfwlist2dnsmasq/`：cokebar/gfwlist2dnsmasq `202e52fb5ea2260abc9f162b3a78e58ec9187005`，含转换脚本与 GPL-3.0 正文；它是已记录的较早上游运行所用版本，不能证明固定基线使用了同一版本。
- `trackers/`：XIU2/TrackersListCollection `61fbb62c9c326d7234da2fb240055680cb150ba6`，含 `all.txt` 和 GPL-3.0 正文。

按 MetaCubeX 流程用上述 gfwlist 和转换脚本生成的候选 GFW 域名包含基线的全部 4,424 个不同值，另有 19 个候选值；这不是精确输入证明。按上游过滤规则从 `trackers/all.txt` 提取 35 个不同主机，其中 25 个在基线 TRACKER 分类中完全匹配，10 个未匹配，不能将该快照说成精确对应源码。实际分发时还需按照各文件许可核对必要条件。
