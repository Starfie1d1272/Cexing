# 语义预览契约

`configpipeline.Result.Changes` 保留 `section/before/after`，新增固定 kind、contentChanged、added/removed/modified/reordered、typesChanged/membersChanged 和按需 fields。相同数量的替换可报告 modified，纯排序报告 reordered，清空报告 cleared；策略组类型/成员单独计数。数组顺序保留，普通 mapping 键顺序/注释/格式变化等价，不误报。DNS 的 nameserver-policy 与 proxy-server-nameserver-policy 由锁定 Mihomo 的 OrderedMap 消费，顺序变动会报告；hosts 按条目摘要，Merge 的替换行为不改变。

摘要仅输出固定 section 和允许列出的 DNS schema 字段，以及计数/布尔标记。任意其他 YAML 键聚合为 advanced；节点名、provider 名、规则、域名、IP、URL、凭据、值和内部比较签名均不返回。不输出全文 diff 或可反推值的哈希。

`Result.PlatformChanges` / `MergePreview.platformChanges` 单独记录 Strategy 后的用户输入被实际平台投影处理的字段，kind 为 protected。只比较投影前后，不复制安全策略；仅注入宿主缺省值不算忽略用户决策。Controller runtime secret 仍由现有持久化边界拒绝，不进入摘要。

全局/本订阅/结构化编辑的 worker 预览共享此服务，仍执行完整 Validate，无 stage/apply/commit。旧 ArkTS 调用保留兼容；`CoreValidator.describeMergeChange` 和 `describeMergePreview` 提供简短中文呈现，详细 fields/platformChanges 留给按需详情。页面所有者应把现有 `section: n → n` 拼接改为此共享 formatter，不实现页面自己的 diff；本批不修改其他工作组拥有的页面。

合成回归覆盖同数量替换、规则顺序/类型、策略组成员/类型、DNS 有序 policy、hosts、清空、等价格式及未识别字段脱敏。SDK/HAP、云端测试与设备热重载/转发仍为不同证据，设备验收使用 #92。

依据：[Mihomo DNS 官方文档](https://wiki.metacubex.one/config/dns/)、仓库锁定替代模块的 `config.RawDNS.NameServerPolicy` / `parseNameServerPolicy`；只调用已有 parser/类型，不移植外部客户端源码。Merge 方言仍见 [配置编译契约](config-pipeline.md)。
