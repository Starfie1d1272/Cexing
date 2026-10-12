# 手机配置兼容规范（目标契约）

本目录给统一配置引擎提供输入边界和验收材料，不实现导入、转换或生产执行。现有实现及事务门槛以 [配置契约](../configuration.md) 为准；运行边界见 [平台参考](../platform.md)。应用名、包名和仓库名保持不变。

## 格式与接入

“直接”指可进入完整解析与平台约束流程，不保证内容可运行；“转换”指需要显式语义适配。不要凭扩展名或 YAML 可解析就把 Merge/provider 内容当完整配置。歧义要求用户声明格式，失败保留旧配置。

| 输入 | 手机目标路径 | 基线实际能力及边界 |
|---|---|---|
| 完整 Mihomo YAML（含 proxies 或 proxy-providers、组和规则） | 直接 | 现有 URL/文件/剪贴板导入；完整引用、资源和可运行性校验待统一引擎 |
| Merge YAML | 转换 | 尚未实现；必须有完整 base 和明确 Merge 版本，不能单独激活 |
| Clash Verge JS | 不直接支持执行；原平台导出最终 YAML 走直接路径 | 不运行任意 JS；已知策略只以显式版本化预设转换语义，不用正则抽取脚本 |
| OpenClash sh/Ruby | 不直接支持执行；原平台导出最终 YAML 或显式策略转换 | 不带入 shell、Ruby、LAN ACL、文件写入和 NAS 部署操作 |
| provider-only payload（顶层仅 proxies） | 转换为 provider 资源 + 完整 base | 与完整配置中只有 proxy-providers 的情况不同；不能单独启用 |
| URI 节点列表、未知方言/程序 | 不支持本规范 | 不能静默丢字段、执行代码或装作完整 YAML |

完整 provider 配置仍需受限获取/解析 provider、缓存身份及节点快照。只看到 include-all/use 声明不能证明美国节点存在。私有 Canonical 现有 JS/sh 验证顶层 proxies，provider-only 会失败；不得借此宣称 Mihomo 不支持 provider。

建议手机 Merge v1：mapping 递归合并，scalar 替换，array 整体替换，null 为合法值而非删除。删除用独立、类型明确的 removePaths（JSON Pointer）；删除不存在路径报错。拒绝重复 mapping key、自定义 YAML tag、循环别名和超限展开；字符串不插值。数组不按 name 猜测合并；策略生成器以受管理身份替换自身组/规则，精确去重并保留非管理规则顺序。此为新方言，不能宣称逐字兼容 Verge Merge。平台保留字段的写入/删除在预览中报告，不静默接受。

## Canonical v3 可移植语义

只移植区域池、服务依赖及规则优先级；私有现场覆写不进入公共项目。来源审查及偏差在 [证据](../../evidence/config-compatibility/2026-10-12.md)。区域名字可保留，节点名、订阅及设备身份均为外部私有输入。

| 层 | 语义 |
|---|---|
| 香港 / 新加坡 / 日本 / 美国优选 | 各只有一个普通区域池；名称过滤 + metadata 排除；缺必要池明确诊断 |
| 全网优选 | include-all，没有正向区域 filter；包含普通欧洲等节点，排除 metadata/维护伪节点；不是 AI 默认出口 |
| ChatGPT自动 | fallback 直接选择符合美国条件的叶节点，按内核 include-all 顺序；无区域组嵌套、无 DIRECT 兜底 |
| ChatGPT/Codex | select：ChatGPT自动 → 日本优选 → 新加坡优选 → 美国优选；默认自动，保留人工选择 |
| Google自动 / Google | fallback：日本 → 新加坡 → 美国；外层 select：自动 → 日本 → 新加坡 → 美国 |
| AI普通服务 | select：日本 → 新加坡 → 美国 → 全网；默认日本，全网只能人工选择 |

Gateway 区域组是 smart，Client 是 url-test；两份 OpenClash 源码均显式 uselightgbm=false、collectdata=false。这些字段是策略选择，不是模型参与证据。手机第五目标默认采用 Client url-test；smart 是显式可选能力，必须匹配固定内核与能力证据，不能将 smart 降级为 url-test 后仍标为相同策略，也不能把 false 自动改 true。基线 Mihomo v1.19.32 的组解析器没有 smart 分支，请求该类型必须返回 CAPABILITY_UNAVAILABLE。候选 Smart 内核的预测/模型验收另循 [集成契约](../integrations.md)。

过滤保持版本化：Canonical Client 的 HK 名称可匹配香港池，Gateway 源码缺少 HK 分支，是真实差异；不要悄悄写成一致。手机预设选择 Client 过滤语义。自定义正则必须经目标内核规则语法校验，不能把 JS RegExp 成功等同于 Mihomo 正则成功。名称过滤不是节点所在地真实性证明。

## 手机第五目标

| 维度 | 目标决定与验收 |
|---|---|
| DNS | fake-ip 可作为独立手机预设；resolver 来源、bootstrap、代理节点域名解析及 fake-ip-filter 由手机设置与完整校验确定。必须对齐系统 VpnConfig DNS、内核监听/劫持及真实 DNS 流量。禁止带入订阅域名、桌面域名例外、路由器 nameserver-policy；未配置 resolver 返回 DNS_POLICY_REQUIRED，不能填占位地址后激活 |
| IPv6 | 默认关闭；系统 IPv6 接受/路由、TUN 地址族、内核 ipv6/dns.ipv6 和 fake-ip-v6 必须形成同一方案。关闭不能自动称为无泄漏；系统绕过路径需验收。开启必须先有系统 + 内核双栈证据，不直接继承宿舍的 ipv6=true |
| 分应用 | 系统 VPN 使用 bundle identity 白名单或排除名单；宿主自身排除，由 VpnController 执行。与域名规则分离，不能移植 MAC/SRC-IP 设备匹配，也不能把 Mihomo process 规则当系统分应用保证。空白名单语义必须与 UI/系统一致，避免意外全代理 |
| 健康检查 | 区域 L1 检测节点质量，服务 L2 检测探针路径；主动探针 lazy=false 与耗电权衡须显示，省电配置改变时形成新策略版本。Controller 可达、系统 TUN 在、探针成功、真实业务可用分别记录 |
| 网络切换 | resolver/provider 快照与网络身份关联；切网后重新验证，旧会话迟到结果不能覆盖新事务；页面释放不停止运行时检查 |
| 规则 | 保留客户端订阅 MATCH 终局；局域网规则作为明确手机选项并在服务前；不导入 NAS/DDNS/BT/PT、私有 Supabase、宿舍设备 ACL 或桌面 fake-ip 例外 |

探针目标合同（URL 为公开服务地址，fixtures 用保留域名，绝不联网）：区域 L1 为 gstatic generate_204，204，300s/5000ms，Client max-failed-times=3、lazy=true、tolerance=50；OpenAI 为 chatgpt trace，字符串 "200"，60s/8000ms、max-failed-times=2、lazy=false；Google 为 Gemini 首页，字符串 "200-399"，300s/5000ms、max-failed-times=2、lazy=false。合成 IR 将单值状态码规范化为字符串 "204"；来源 JS 的 204 是数值，不声称来源全部是字符串。OpenAI 探针不证明 Codex API，Google 首页不证明全部 Google API。provider health-check 与组探针覆盖范围须单独验证。

规则顺序目标：显式 QUIC/UDP443 选择 → 可选手机 LAN → OpenAI → google-cn DIRECT 边界 → Google/youtube → 通用 AI → 明确固定区域服务 → 用户选择的国内直连 → 原订阅终局。Canonical 的 QUIC 拒绝作为显式策略选项；本规范不修改真实设备。Google 补洞须有日志证据；禁止凭猜测新增生产域名。逻辑 AND/OR、RULE-SET、no-resolve 由真实解析器提取目标，不用 split(',') 充当校验器。

## 必须满足的转换不变量

同一 base + Merge + policy + providerSnapshot + platformSnapshot 重复生成语义与摘要一致；所有节点字段保留，重复组、重名节点、循环依赖、悬空引用、规则资源缺失均明确失败。管理规则去重不重排非管理规则；不得通过末尾追加规则让它落在 MATCH 后。冲突/删除/预览不泄漏 URL、节点地址或凭据。订阅更新重新执行同一流水线；任何生成、校验、存储或内核应用失败均保留/恢复上一份有效版本，文件原子替换不等于运行时回滚完成。

首次启动、编辑、切换、订阅更新和热重载采用相同平台投影，回环 Controller/随机密钥/UI/系统 TUN 不由外部配置决定。以 [接口](engine-interface.md) 和 [合成验收向量](fixtures/cases.json) 交接配置引擎。fixtures 的结果是目标期待，不表示基线已实现。
