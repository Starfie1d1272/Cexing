# 推荐模板编译契约

`core/profiletemplates` 提供策星自有模板，未复制外部模板或客户端源码。模板不请求远端规则源，不含用户节点、订阅来源或凭据。`Plan` 记录模板 ID、版本、所选策略组及既有 `RegionPlan`；`Rules` 返回带稳定 ID 的模板规则，供模板升级比较。

## 编译边界

调用方将 `Apply(ctx, root, plan)` 组合进现有 `configpipeline.Request.Strategy`。输入必须是每次由原文和两层 Merge 产生的新映射，不是上一份生成结果。`Apply` 保留其他字段及未知键；`original` 不修改输入，`region` 复用 `ApplyRegion`，`ai` 将自有 AI 规则置于上游规则前，`automatic` 只有 `replaceRules: true` 时才替换规则。自动方案为本地地址直连、其余流量使用用户选择的组，不依赖地理数据库。

模板服务不负责 Smart 默认转换、宿主平台约束、provider 加载或版本发布。宿主仍须执行完整引用、目标组可用成员与资源检查，再走 stage → verify → apply → commit。静态空目标会被拒绝；动态 provider 的过滤后成员、嵌套组实际可用性与资源快照须由宿主完整校验，不能将本服务变换成功当作生效成功。

模板意图须随现有不可变版本的来源原子保存；关闭、切换、订阅更新和重启均从来源重新编译。不得另建模板发布指针、冻结上游列表为 Merge，或将未发布草稿当作当前模板。Strategy 内模板、个人编辑、Smart 和地区的最终次序由 #146 的统一契约确定；地区变换不得重复执行。

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
