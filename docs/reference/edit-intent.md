# 结构化编辑意图 v1

本契约属于 `configpipeline`，复用 [配置编译与事务](config-pipeline.md)，不另建保存或发布系统。Go 编译接口与合成夹具已经实现；宿主的草稿保存、版本 provenance 与 UI 接线须共同接入后才可作为完整可视化编辑功能使用。草稿 JSON 采用 [schema](config-compatibility/edit-intent.schema.json)，上限 1 MiB、512 个操作。旧版本没有意图时等同 `nil`，不迁移或修改原文。

## 读取与编译

- `ReadEditable(original, global, local)`：读取原文与两层 Merge 的当前基线，返回 `sourceRevision` 和固定七个 section 的有序 `items`；每项只有不透明 `id`、`revision`、允许列出的类型；snapshot 返回 `missingFieldRevision`，供新增字段前置条件使用，无需 UI 猜测指纹。无原始名称、域名、URL 或任意 mapping 键。
- `ReadEditTarget(original, global, local, section, id)`：用户明确进入单项编辑后调用，返回该目标的私有 JSON `value`、原始 `name` 及 `item.fields` 各字段指纹。它不适用于默认预览、日志或支持包。未知高级键仍保留，可以在高级编辑中按字段修改。
- `Request.Intent`：在双层 Merge 及模板后、`Request.Strategy` 前执行。先调用 `Compiler.Template` 注册的模板转换（或 `Request.Region` 的旧地区计划），再执行个人编辑，最后由 Strategy 执行 Smart；平台最后执行，随后既有引用检查及完整 Validate。模板组使用同一 Transform，不新造数组 Merge 方言。
- `DecodeEditIntent`：严格拒绝未知 schema 字段、尾随内容、不支持版本与超量；`IntentError{code, operation}` 只返回固定类别和操作下标。取消、parser/引用/Validate 失败不返回候选。

`sourceRevision` 标记编辑时的语义基线，不是把整个订阅锁死的条件；`revision` 是宿主生成的草稿修订标识。宿主必须在保存/提交的串行临界区比较之前读取的草稿 revision 与当前 revision，同时保留现有 profile/source/selection ticket 和 active-version 比较。不能在异步工作结束后读取新 revision 伪装请求身份。

ArkTS 接口定义位于 `lib/ConfigEditor.ets`：`ConfigEditor.read(context, original, overlay, expected, globalMerge?)` 与 `ConfigEditor.target(context, original, overlay, expected, section, id, globalMerge?)`。两者复用现有 `core.versionAction` 单 worker，分别调用 `edit-read` / `edit-target`，只读返回 `editable` / `editTarget`。expected 必须在异步工作前捕获；页面还需用请求身份拒绝迟到结果。追加 `smartPreview(..., defaultEnabled, intent?, globalMerge?)` 提供组类型/例外的只读数据，`preview(..., overrides, defaultEnabled, intent, regionPlan, globalMerge?)` 使用相同完整编译链。worker stage 的可选 `editIntent` 与现有调用兼容；保存草稿、持久化 provenance 及生产更新传递由可靠性组接入。`EditIntentFailure` 保留固定错误类别与操作下标，无输入值。

当前/草稿投影使用 `Compiler.Editable` / `Compiler.EditTarget`，输入 `Request{Original,Overlays,Region,Intent}`，与 Compile 相同模板/个人顺序，读取返回实际个人修改后的值，不调用完整 parser、不写盘。`ConfigEditor.read/target` 的尾部可选 intent/regionPlan 参数保持旧调用兼容。

**#147/#148 列表接口**：`ConfigEditor.list(context, original, overlay, expected, globalMerge?, intent?, regionPlan?)` 调用 worker `editor-list`，返回相同 EditableSnapshot shape，但 item 额外带 `name` 与 `providers: [{id,name,type,state,count?}]`。这是用户明确进入编辑列表的私有数据，默认预览仍调用 read，不带名称；列表不含地址/密码/URL/原始规则。规则名称为“规则 n”；单项条件/值用 target 明确读取。provider state 仅 declared（已声明、未证明加载）、inline（内联声明，count 是声明数量）、missing（定义缺失），**不等于资源校验或转发健康**。缺失或被过滤后的可用性仍由完整编译/资源验证判定。

`EditableSnapshot.missingFieldRevision` 与 `EditTarget.missingFieldRevision` 均由 Go 返回，target.item.fields 含真实字段前置指纹。新增字段使用该 missingFieldRevision，不能填空串或自行对 null/字段值计算哈希。load 的 snapshot 应使用 list，使 #147 能直接显示名字和 provider 引用；保存前按既有草稿 ID 合并同字段修改，避免把当前投影的指纹叠加到旧操作后面。

## 操作

| kind | 数据 | 行为 |
|---|---|---|
| add | value；mapping 项另带 name；列表可带 before | 加单项，重复命名拒绝；不替换整个上游列表 |
| update | target；mapping 使用 patch/remove/preconditions | 仅修改指定字段，每个字段必须与编辑时指纹一致；不存在字段使用 `MissingFieldRevision()`；不覆盖其他键 |
| update | target/expected/value | 修改规则或 hosts 的非 mapping 单值；必须符合目标 revision |
| delete | target/expected | 删除单项；引用未同步修正会由完整编译拒绝；上游已移除则保留删除墓碑 |
| move | target/before | 仅 rules/proxies/proxy-groups 列表移动；空 before 放末尾；其他上游项保持相对顺序 |
| rename | target/expected/name | 命名节点/组/provider 改名，同步普通规则目标、RULE-SET provider、组成员/use、dialer-proxy、listener proxy；完整 Validate 再校验 |

DNS 是一个 mapping 目标，缺失时提供虚拟空 mapping；通过 update 创建字段，不允许整段替换/删除或修改 `dns.listen`。顶层平台字段不能作为可编辑 section；运行态 secret 不进入此契约。语义指纹区分缺失和 null，忽略注释及 mapping 键顺序。

命名目标 ID 由 section 与原名生成，上游修改无关字段不会换 ID。规则 ID 使用语义内容、同内容出现序号及重复总数：重复条目数量变化时不会错删另一条。上游改名/修改规则后的 update/move/rename 返回缺失目标；delete 不猜测替代目标。重复规则仍存在但 ID 因重复数量变化失效时，delete 返回冲突。用户需重新选取发生冲突的目标。任意私有 ID/指纹也不得进入诊断或支持导出。

一个意图每次从最新原文重新执行，重复编译幂等；不把生成 YAML 用作下一次原文。草稿应合并同目标同字段的 update 操作，而不是叠加相互矛盾的前置条件；移动与旧规则 ID 操作先于影响该 ID 的改名/规则替换。撤销移除该操作，停用设置 disabled；两者都重新编译最新输入。只读操作不验证外部 provider 资源，不联网、不 stage，不宣称已可运行。

`smartGroups` 使用组的 target ID → boolean，true 是用户明确 opt-in，false 是保留原类型。Smart 参数与转换逻辑由同一 configpipeline 提供；由 `ApplySmartPolicy` / `PreviewSmartPolicy` 接通。url-test 默认转换，load-balance 默认保留；明确 opt-in 才去除其 strategy；已存在 Smart 参数和手动 Selector 不覆盖。全局关闭时，逐订阅显式 true 仍优先；intent.disabled 只停用个人编辑/例外，不改变全局默认。

## 模板与固定顺序

统一字段 `EditIntent.template` / `configpipeline.TemplatePlan` 与 PR #159 的 `profiletemplates.Plan` 完全同形。模板组最小接线是 `type Plan = configpipeline.TemplatePlan`，其 Validate 由共享类型提供；不得在另一种 provenance 中另存同一个模板。ArkTS `TemplateWizardModel.TemplatePlan` 同理可从 `ConfigEditor` re-export。

固定顺序：最新原文 → 全局 Merge → 本订阅 Merge → 模板（地区模板复用一次 RegionPlan）→ 个人操作 → Smart 默认/例外 → 平台 → 引用/完整 Validate。原有 RegionPlan 通过 `Request.Region` 在个人操作前运行；有显式 template 时由 template 接管地区选择，不再重复旧地区变换。original 模板不生成规则/地区，个人修改仍可保留；停用整个 intent 重新采用全局默认与旧地区计划。

`Compiler.Template` 类型为 `func(context.Context,*yaml.Node,TemplatePlan) error`；宿主绑定 #159 的 `profiletemplates.Apply`。非 original 模板若无适配明确返回 `template_unavailable`，不会假装编译成功。模板层是个人编辑的 authoring 基线，不能把模板生成规则写回原订阅。

## 事务与可靠性组接线契约

ArkTS 统一生产适配名为 `EditorDraftHost`（实际接口已在 `ConfigEditor.ets`）：`load()` 返回 profileId、revision、intent、snapshot；`target(section,id,revision)` 明确取单项私有值；`save(intent,expectedRevision)` 保存私有草稿并返回新 session；`preview(expectedRevision)` 返回 `{revision,digest,changes}`；`apply(preview)` 重新编译/核对 revision+digest 后走既有事务；`undo(expectedRevision)` 丢弃未发布草稿，恢复该订阅成功版本的意图并增加 revision。每个 host 绑定一个稳定 profile；UI 不传当前选择来替换它。revision 是宿主绑定来源、草稿、两层 Merge、设置与 provider 快照的私有不透明身份，不能仅用 active version ID。过期均拒绝，不写盘/不应用。此处接口供可靠性组实现，当前不宣称已经有生产适配对象。

宿主保存每订阅独立草稿 `{intent, expectedDraftRevision}`。成功应用通过现有 stage/verify/apply/commit，将完整 `EditIntent` 加入 `source.json`（字段名 `EditIntent`），与原文、本订阅 Merge、地区计划一起发布。Compiler 返回独立 `Result.EditIntent` 副本，可靠性组只需在既有 FileStore source 结构添加该字段，不新增版本引用或第二个成功指针。更新、切换、重启与全局 Merge 应用必须从该订阅成功版本读取意图重新编译。草稿修改不能改变成功意图。校验/应用/持久化失败均保持旧意图、旧指针和旧原版，不能先保存新意图再调用 reload。

GC 引用清单不新增版本引用：`sourceRevision`/`revision`/target/field fingerprints 都是私有数据标识，不是 version ID 或路径。版本仍仅由现有 Current/Previous/Profiles、可靠性组的备份/回滚引用保留。意图不持有外部文件句柄，不重写 FileStore GC。

夹具位于 `core/configpipeline/testdata/edit-source.yaml`，覆盖直接节点、Selector/url-test/load-balance、规则、DNS/hosts 与未知高级字段。测试涵盖双层 Merge、上游无关更新、同字段冲突、撤销、原文不变、规则重复/排序、改名引用、非法删除引用、平台字段拒绝和完整校验失败。它们是合成 Go 证据，不能替代设备上的真实启动/热重载/网络验收。

## 参考边界

设计对照 [GUI.for.Clash v1.27.0 generator](https://github.com/GUI-for-Cores/GUI.for.Clash/blob/v1.27.0/frontend/src/utils/generator.ts) 的输入来源与生成分离，以及 [Clash Party 固定开发提交](https://github.com/mihomo-party-org/clash-party/blob/fbaaba2107cea0b39b5c5f1de25a3d59c7749224/src/main/simple/compiler.ts) 的草稿/编译边界。两者只作 GPL 方案参考，本实现独立编写，不复制源码或模板。规则解析直接复用本仓已经锁定的 Mihomo dependency。
