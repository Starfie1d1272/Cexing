# 推荐模板编译契约

`core/profiletemplates` 提供策星自有模板，未复制外部模板或客户端源码。模板不请求远端规则源，不含用户节点、订阅来源或凭据。`Plan` 记录模板 ID、版本、所选策略组及既有 `RegionPlan`；`Rules` 返回带稳定 ID 的模板规则，供模板升级比较。

## 编译边界

调用方将 `Apply(ctx, root, plan)` 组合进现有 `configpipeline.Request.Strategy`。输入必须是每次由原文和两层 Merge 产生的新映射，不是上一份生成结果。`Apply` 保留其他字段及未知键；`original` 不修改输入，`region` 复用 `ApplyRegion`，`ai` 将自有 AI 规则置于上游规则前，`automatic` 只有 `replaceRules: true` 时才替换规则。自动方案为本地地址直连、其余流量使用用户选择的组，不依赖地理数据库。

模板服务不负责 Smart 默认转换、宿主平台约束、provider 加载或版本发布。宿主仍须执行完整引用、目标组可用成员与资源检查，再走 stage → verify → apply → commit。静态空目标会被拒绝；动态 provider 的过滤后成员、嵌套组实际可用性与资源快照须由宿主完整校验，不能将本服务变换成功当作生效成功。

模板意图须随现有不可变版本的来源原子保存；关闭、切换、订阅更新和重启均从来源重新编译。不得另建模板发布指针、冻结上游列表为 Merge，或将未发布草稿当作当前模板。统一次序为模板/单次地区生成 → 个人编辑 → Smart；生产编译和 editor-list/read/target 使用相同视图。

## 向导接入

`TemplateWizard` 为新增组件，入口由 ProfilePage 的统一所有者接入。`TemplateWizardHost` 只提供三个操作：

- `load()`：读取当前版本的模板选择、可用出口和地区 Selector；敏感 YAML 不进入摘要。
- `preview(plan)`：通过统一编译入口返回 revision、digest 和简短影响摘要，不发布版本。
- `apply(plan, preview)`：在既有事务锁内重新确认来源、全局/本订阅 Merge、设置与 provider 快照和预览一致，再发布；过期请求拒绝并要求重新预览。

组件没有直接的写盘、启停 VPN 或替用户选点操作。返回/离开会使旧异步展示结果失效，不中断已经开始的宿主发布事务；发布是否完成以事务状态为准。仅“自动分流”替换原规则需要确认。AI 模板的分流结果不能表示服务可达，定向服务检查必须另由 #151 在实际应用成功后启动。

## 依据

- [Mihomo 规则语法](https://wiki.metacubex.one/config/rules/)。本组规则表为自编基础域名与本地地址规则，不使用外部模板文件。
- [现有 RegionPlan](../../core/configpipeline/region.go) 与 [配置事务](configuration.md) 为唯一地区生成和版本发布基础。
- [Clash Verge Rev v2.5.8 enhance](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.8/src-tauri/src/enhance/mod.rs) 与 [GUI.for.Clash v1.27.0 generator](https://github.com/GUI-for-Cores/GUI.for.Clash/blob/v1.27.0/frontend/src/utils/generator.ts) 仅用于比较原文与增强分离的架构，未移植代码。

## 原生向导 Host

`TemplateWizard({ profileId, editor })` 接受同一订阅绑定的生产 `EditorDraftHost`，由 `createTemplateWizardHost` 转接 load/save/preview/apply。模板类型直接 alias ConfigEditor.TemplatePlan，赋值通过 ConfigEditor.templatePlan；不在组件中重写事务或源文件。

预览先保存惰性草稿，再取得共同全量编译 receipt。应用必须匹配该原始 receipt 和原先计划，不读取新 revision 来伪装旧请求；消耗 receipt 后不能重复应用。保留 existing operations、Smart 例外、Merge 与未知高级数据。“original”只停用模板，不清除其他个人编辑。

读取成功版本意图需要 EffectiveVersions.editIntent；该 getter 属于统一 provenance 适配。对已停用个人编辑，预览可保留惰性草稿，但正式应用前需一次确认；即便离开后重开，也按成功版本状态判断风险，不能把上次未应用草稿当作已启用。确认与页面 generation 绑定，旧确认框结果不会应用到新页面。

生产 EditorDraftHost 工厂须在既有串行 gate 内比较来源/草稿/选择、两层 Merge、设置/provider 身份及编译 digest。地区模板还须复用既有 pending/previous-selection 行为，成功后只消费一次明确选择；关闭模板按既有规则恢复原选择。仅创建组不能报告地区流量已使用新入口。

ProfilePage 的唯一入口所有者只需要提供稳定 profileId 和该共同 Host；TemplateWizard 不自行创建另一个保存器，也不接管 VPN 生命周期。
## 模板应用后的恢复

模板向导及更新比较页消费共同 `ProfileApplyFeedback`，未知和已提交待恢复状态阻止再次预览/应用，并提供实际 `ProfileApplyRecovery.reconnect` 操作；选择失效则沿既有代理面板处理。重连须确认中断，页面离开、订阅或会话变化使旧确认失效。停止/重建复用原 `ProfileRecovery`，启动接受只导航到连接页，不由模板页面清除持久未知标记；确认解除仍由现有内核/成功版本恢复链负责。

### 停用与恢复

模板停用和切换仍修改同一 EditIntent，并经既有 preview/receipt/apply 发布。`templateArchives` 仅保存未使用模板的有界基线；操作的 `templateId` 表示其所属模板。未选中该模板时操作保留原顺序但不参与编译；其他个人修改继续生效，恢复同模板时重新校验并执行，不复制生成 YAML。

切换前的纯意图计算使用现有引用解析区分模板自有操作与跨引用修改。自有操作自动休眠；存在依赖时先返回数量，用户选择一并停用后才将这些操作归属旧模板。返回编辑不会写草稿。输入、归档、操作总数仍受现有容量与结构校验约束；订阅变化导致恢复冲突时不静默覆盖。
