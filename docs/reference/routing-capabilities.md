# 路由与选点能力矩阵


依据：`core/go.mod` 锁定的 vernesong/mihomo `daf3ad03021c`，不以最新文档推断手机已适配全部能力。源码字段见 [SmartOption](https://github.com/vernesong/mihomo/blob/daf3ad03021c/adapter/outboundgroup/smart.go)、[GroupCommonOption 与解析](https://github.com/vernesong/mihomo/blob/daf3ad03021c/adapter/outboundgroup/parser.go)、[url-test](https://github.com/vernesong/mihomo/blob/daf3ad03021c/adapter/outboundgroup/urltest.go)、[fallback](https://github.com/vernesong/mihomo/blob/daf3ad03021c/adapter/outboundgroup/fallback.go)。通用语义对照 [MetaCubeX 官方组文档](https://wiki.metacubex.one/config/proxy-groups/)、[自动测速](https://wiki.metacubex.one/config/proxy-groups/url-test/)、[顺序回退](https://wiki.metacubex.one/config/proxy-groups/fallback/)。Smart 是锁定分支扩展，不把 MetaCubeX 通用说明当作其参数依据。

“已支持可视化”指可保存有类型意图并经真实编译器验证；不代表设备预测、服务可达或移动平台内核功能已经验收。

| 能力 | 原生入口与状态 | 约束与准确默认值 |
|---|---|---|
| Smart / url-test / fallback / select | 已支持可视化：出口直接选择；高级组编辑保留所有原类型 | 每出口独立。托管 url-test 与 fallback 不被全局 Smart 改写；select 是运行时单选，不能充当多国并集 |
| 多国家、节点/来源范围、排除项 | 已支持可视化：出口范围 | 空国家/节点/来源列表表示全部；排除优先；未知由 include/exclude 明确表达。推荐默认出口包含未知，AI 排香港和未知；分类仅按名字，可纠正 |
| fallback 顺序 | 已支持可视化：候选列表上下移动；高级组成员排序 | 全体候选必须有明确无重复顺序；更新后的成员不匹配须重新确认，保留旧运行版本。provider 叶节点由单成员 REJECT 组包装，保持真实跨来源顺序；大量候选受共同 intent/实体上限约束，超限拒绝 |
| policy-priority | 已支持可视化：Smart 高级文本字段，格式校验 | 上游为分号分隔 pattern:factor，系数须有限正数；不是国家选择器。默认省略，不改变权重 |
| uselightgbm | 已支持可视化：Smart 高级开关 | 推荐及安全转换为 true，复用现有离线模型；上游组默认 false。模型资源/真实预测验收独立 |
| collectdata | 已支持可视化：Smart 高级开关 | 推荐/安全转换为 false，不额外开启训练样本采集；导入的明确设置保留 |
| sample-rate | 已支持可视化：Smart 高级数值 | 明确输入须大于 0 且不超过 1；上游省略或 0 实际按 1 处理，故控件拒绝把 0 冒充关闭。collectdata 默认仍关闭 |
| prefer-asn | 已支持可视化：Smart 高级开关 | 推荐/安全转换为 false；不为默认方案额外开启 ASN 偏好或采集 |
| tolerance | 已支持可视化：Smart / url-test 高级数值 | uint16 范围 0–65535 毫秒；省略为 0，不能把容差解释成成功/解锁检测 |
| URL / interval / timeout / lazy / expected-status / max-failed-times | 已支持可视化：出口及组编辑高级控件 | 推荐组为 HTTPS gstatic generate_204、300 秒、5000 毫秒、true、字符串 204、5。自定义有效值保留；expected-status 支持官方 `/` 与 `-` 范围。普通导入不被套推荐健康检查默认 |
| use / proxies / include-all / include-all-proxies / include-all-providers | 已支持可视化：高级组编辑和出口来源/节点范围 | 继承内核语义。全纳入不包括其他策略组；本地 provider 快照必须已校验，宿主不下载私人来源。重复叶节点名称无法唯一引用时拒绝托管，内置 direct/reject/dns 不纳入代理候选；原订阅仍可沿用 |
| filter / exclude-filter / exclude-type | 已支持可视化：高级组编辑文本控件；出口提供结构化排除 | filter 仅筛 provider 及 include-all-proxies 引入的节点；exclude 语义依锁定解析器，最终候选与完整校验为准。托管出口编译为精确成员过滤，原始参数不能绕过声明的范围 |
| 域名、CIDR、规则集、合法复合/其他规则 | 已支持可视化：现有规则编辑器及高级原始字段 | 推荐使用内置完整维护分类，个人规则默认插入局域网之后、服务/国内规则之前；显式高级重排仍是用户修改。服务子集先于 AI 聚合 |
| 未识别合法字段 | 已支持：高级组 JSON、原始订阅与 Merge | 表单从原对象复制，只改所选字段，不重建丢弃未知键。托管出口的 name/type/members/filter/empty-fallback 属于结构化意图，拒绝通过原始 options 绕过范围；完整原始配置编辑仍可用 |
| 运行选点、延迟测试、Smart 技术详情 | 由 Zashboard 和原有 Smart 高级设置承接 | 原生不复制节点管理器 |
| routing-mark / 组内 interface-name / 组内 dialer-proxy | 平台/内核不适用，不提供误导控件 | 锁定组解析器已删除/拒绝这些组字段；手机 VPN 出站保护经宿主。不承诺 Linux 网关 mark、桌面 TUN 或服务监听能力 |
| 上游完整协议、规则和设备识别矩阵 | 需要补齐逐项设备证据 | 未列出的字段可经原始配置和完整解析验证；编译接受不等于手机真实转发支持 |

## 更新与资源

规则固定来源、MIT 声明与各分类计数见 [source.json](../../third_party/routing-rules/source.json)。完整展开数据随 Go 内核离线内置，MIT 与来源随 HAP。维护者使用 `python3 scripts/update-routing-rules.py --revision <40位提交>` 更新，失败恢复此前文件；`--verify` 仅离线核对锁定数据、计数和声明。Quick、内核构建和 HAP 验证都拒绝摘要不符。自动下载不发生于手机连接或应用策略时；来源更新以独立审查提交和构建发布为边界。
