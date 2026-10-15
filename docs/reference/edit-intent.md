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

`EditableSnapshot.missingFieldRevision` 与 `EditTarget.missingFieldRevision` 均由 Go 返回，target.item.fields 含真实字段前置指纹；有序 DNS policy 的 source/field revision 包含顺序。新增字段使用该 missingFieldRevision，不能填空串或自行对 null/字段值计算哈希。load 的 snapshot 应使用 list，使 #147 能直接显示名字和 provider 引用；模板新生成的条目也通过 list/target 读取，个人操作在模板之后执行，重编译不会被模板覆盖。保存前按既有草稿 ID 合并同字段修改，避免把当前投影的指纹叠加到旧操作后面。

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

一个意图每次从最新原文重新执行，重复编译幂等；不把生成 YAML 用作下一次原文。单份意图是一次原子修改集合：同实体的后续 update/rename/delete 可使用本次编译输入的原基线指纹，也可使用前序已通过守卫的当前投影指纹，自己的前序修改不会制造假冲突。真实上游变更仍必须匹配基线/当前守卫，否则拒绝；预览不重写持久意图。草稿应合并同目标同字段的 update 操作；移动与旧规则 ID 操作先于影响该 ID 的改名/规则替换。撤销移除该操作，停用设置 disabled；两者都重新编译最新输入。只读操作不验证外部 provider 资源，不联网、不 stage，不宣称已可运行。

`smartGroups` 使用 SmartGroupChange.choiceId → boolean；choiceId 是个人改名前的稳定来源实体 ID，不是改名后当前 target ID。smartPreview 同时返回当前 id（关联列表）与稳定 choiceId（写例外），撤销改名不丢选择。旧未改名实体两者相等。true 是用户明确 opt-in，false 是保留原类型。Smart 参数与转换逻辑由同一 configpipeline 提供；由 `ApplySmartPolicy` / `PreviewSmartPolicy` 接通。url-test 默认转换，load-balance 默认保留；明确 opt-in 才去除其 strategy；已存在 Smart 参数和手动 Selector 不覆盖。全局关闭时，逐订阅显式 true 仍优先；intent.disabled 只停用个人编辑/例外，不改变全局默认。

## 模板与固定顺序

统一字段 `EditIntent.template` / `configpipeline.TemplatePlan` 与 PR #159 的 `profiletemplates.Plan` 完全同形。生产 worker 已通过 `editorTemplate(home)` 将共享字段转换为既有 `profiletemplates.Plan` 并调用 Apply，不需要模板组再等待 alias。Go struct conversion 在编译时校验同形，模板代码/现有 Validate 保持不变；不得在另一种 provenance 中另存同一个模板。ArkTS 两个 TemplatePlan 接口字段同形但不能依赖结构赋值；使用 `ConfigEditor.templatePlan(plan.templateId, plan.version, plan.targetGroup, plan.region, plan.replaceRules)` 显式生成统一类型，再设 `intent.template`。SDK clean 挂载回归单独检查该接线。

固定顺序：最新原文 → 全局 Merge → 本订阅 Merge → 模板（地区模板复用一次 RegionPlan）→ 个人操作 → Smart 默认/例外 → 平台 → 引用/完整 Validate。原有 RegionPlan 通过 `Request.Region` 在个人操作前运行；有显式 template 时由 template 接管地区选择，不再重复旧地区变换。original 模板不生成规则/地区，个人修改仍可保留；停用整个 intent 重新采用全局默认与旧地区计划。

`Compiler.Template` 类型为 `func(context.Context,*yaml.Node,TemplatePlan) error`；生产 `compileLayeredMergeWithIntent`、editor-list/read/target 和 smart-preview 已绑定 #159 的 `profiletemplates.Apply`，全部使用相同先后顺序。region 的临时 provider 成员来自现有本地已校验缓存解析，不联网，不进入序列化 Plan。非 original 模板若无适配明确返回 `template_unavailable`，不会假装编译成功。模板层是个人编辑的 authoring 基线，不能把模板生成规则写回原订阅。

## 事务与可靠性组接线契约

ArkTS 统一生产适配名为 `EditorDraftHost`（实际接口已在 `ConfigEditor.ets`）：`load()` 返回 profileId、revision、intent、snapshot；`target(section,id,revision)` 明确取单项私有值；`save(intent,expectedRevision)` 保存私有草稿并返回新 session；`preview(expectedRevision)` 返回 `{revision,digest,changes}`；`apply(preview)` 重新编译/核对 revision+digest 后走既有事务；`undo(expectedRevision)` 丢弃未发布草稿，恢复该订阅成功版本的意图并增加 revision。每个 host 绑定一个稳定 profile；UI 不传当前选择来替换它。revision 是宿主绑定来源、草稿、两层 Merge、设置与 provider 快照的私有不透明身份，不能仅用 active version ID。过期均拒绝，不写盘/不应用。生产适配由 `EditorDraftHosts.create(context, file)` 返回，实现位于 `lib/EditorDraftHosts.ets`。UI 只在用户进入编辑时创建并保存这个实例；load 使用私有 list，target/保存/预览/应用/撤销均绑定同一来源。修订同时比较来源/草稿 ticket、两层 Merge、设置与 native 有界本地 provider 字节指纹；缺失缓存也有独立状态，不联网。应用必须来自本实例的预览 digest；stage 返回实际 digest 并在 apply 前核对，之后继续走既有 verify/apply/commit。

宿主保存每订阅独立草稿 `{intent, expectedDraftRevision}`。成功应用通过现有 stage/verify/apply/commit，将完整 `EditIntent` 加入 `source.json`（字段名 `EditIntent`），与原文、本订阅 Merge、地区计划一起发布。Compiler 返回独立 `Result.EditIntent` 副本，可靠性组只需在既有 FileStore source 结构添加该字段，不新增版本引用或第二个成功指针。更新、切换、重启与全局 Merge 应用必须从该订阅成功版本读取意图重新编译。草稿修改不能改变成功意图。校验/应用/持久化失败均保持旧意图、旧指针和旧原版，不能先保存新意图再调用 reload。



GC 引用清单不新增版本引用：`sourceRevision`/`revision`/target/field fingerprints 都是私有数据标识，不是 version ID 或路径。版本仍仅由现有 Current/Previous/Profiles、可靠性组的备份/回滚引用保留。意图不持有外部文件句柄，不重写 FileStore GC。

夹具位于 `core/configpipeline/testdata/edit-source.yaml`，覆盖直接节点、Selector/url-test/load-balance、规则、DNS/hosts 与未知高级字段。测试涵盖双层 Merge、上游无关更新、同字段冲突、撤销、原文不变、规则重复/排序、改名引用、非法删除引用、平台字段拒绝和完整校验失败。它们是合成 Go 证据，不能替代设备上的真实启动/热重载/网络验收。

## 参考边界

设计对照 [GUI.for.Clash v1.27.0 generator](https://github.com/GUI-for-Cores/GUI.for.Clash/blob/v1.27.0/frontend/src/utils/generator.ts) 的输入来源与生成分离，以及 [Clash Party 固定开发提交](https://github.com/mihomo-party-org/clash-party/blob/fbaaba2107cea0b39b5c5f1de25a3d59c7749224/src/main/simple/compiler.ts) 的草稿/编译边界。两者只作 GPL 方案参考，本实现独立编写，不复制源码或模板。规则解析直接复用本仓已经锁定的 Mihomo dependency。

## 模板自有项与升级桥接（#150）

`TemplatePlan.baseline` / `mine` 必须成对出现且与 plan 的 templateId/version 相同。每份私有快照仅含稳定实体 `{id,section,value}`；Mine.deleted 保存删除墓碑。实体、墓碑、值大小、总意图、重复 ID/未知字段均由共同 decoder 限制。快照不进入默认摘要、日志或支持包，也不持有新版本目录。字段是 provenance，不是整列表 Merge；不自动把 Mine 作为第二套配置覆盖原文。

共同 `Compiler.PrepareTemplate` 复用 `profiletemplates.Prepare` / `CaptureEdited`。`TemplateTarget(templateId,entityId)` 是稳定 alias；Editable/EditorList/EditTarget 与 operations 的 target/before 使用相同身份。scalar replacement 更新当前 binding，delete 留显式 nil，后续捕获拒绝不可达指针。binding 只存活于单次 worker；重启从原文→Merge→模板→operations 重建。成功完整 Validate 后 Result.EditIntent 深拷贝存入实际 baseline/Mine；失败不返回成功 provenance、不修改草稿输入。事务所有者继续将该结果随现有 source.json 进行 stage/verify/apply/commit，不能提前提交模板升级。

`template-update-preview` 已由既有 `coreVersionAction` 路由 #184 的有界只读 decoder，无新增 C ABI。三方比较、冲突决策、候选→字段 delta 与 UI Host 仍由模板组维护。模板组须将候选转换为这些共同 operations 并进行完整编译预览；共同层不直接发布 Candidate。当前模板目录只支持已实现的 v1，新模板版本仍须先有真实生成器，不能将纯比较的 version=2 当成已可应用模板。

生产事务将编译器返回的完整 EditIntent（含生成的 baseline/Mine/墓碑）写入同一 source.json；成功后同 revision 的已应用侧车读取为最新成功 provenance，订阅重算不会被旧侧车遮蔽。未应用的新 UUID 草稿仍独立保留。Host 的输入身份忽略这两个编译器生成快照本身，来源/profile/draft ticket、模板选项、个人 operations、Smart、Merge、设置和实际 provider 字节仍比较；自身成功规范化不会误报外部改动。

Go-only `Compiler.EditorResourceSource` 仅复用既有 editSource/boundEditSource，给宿主读取本地 provider 身份，保证模板 alias 与个人操作的投影一致；不走完整资源验证、不联网，不把私有 YAML root 返回 ArkTS、默认摘要或诊断。模板比较的 Candidate→个人 delta 与冲突选择仍由模板页消费 `EditorDraftHosts.create` 的同一会话，提交前必须取得完整编译预览，不能把纯三方比较当成已应用。

### 共同绑定补充

共同快照的模板版本校验正整数；实际 `profiletemplates.Plan.Validate`/生成器仍决定支持目录，生产未知版本完整编译继续拒绝。`template-update-preview` 将 home 转交既有 source/encode worker，不新增 envelope。三方共同新增/重加实体同样参与顺序图，矛盾顺序需显式选择。

保留被新版模板移除的个人实体：Candidate 写在 `template.mine.entries`，共同 add 的 `target` 为其 `TemplateTarget`；仅接受已声明、未绑定、section 一致的 alias。add 实际插入才创建 binding；捕获包含它并保留实际位置，快照本身仍不执行配置。alias 未实际插入则留墓碑。普通 add 仍省略 target。已在 fresh baseline 的实体继续用 update/rename/move，不接受重复 add。

显式 `editor-list` / `edit-target` 的组 `sourceName` 是双层 Merge 后、模板与个人操作前的源组名；个人改名只改变 name。模板选择使用 sourceName，界面标签使用 name。个人新增或模板生成组不提供 sourceName；默认摘要不增加私有名称。

单节点停用使用 `kind: disable, section: proxies, target, expected`。共同编译器严格验证原节点 revision，生成保留同名的 reject adapter；组成员、规则、dialer-proxy 等引用全部保持。它既不删除其他对象/引用，也不自动换成 DIRECT 或其他出口。显式编辑视图标记 disabled；撤销移除该操作后从最新原文重建，未知字段和凭据只保留在原文/私有来源中。UI 应显示“停用后拒绝连接”这一必要决策，并将启用实现为移除此操作；delete 仍是删除，非法引用继续拒绝完整编译。

## 下载原文候选

`EditorDraftHosts.create(context, file, sourceOverride?)` 接受导出的 `EditorSourceCandidate { original: string; metadata: ProfileMetaExt }`。工厂复制候选，后续调用方修改无效。下载或冲突页面不得先写成功 Original；同一候选交给 `createTemplateUpdateSource(context, file, sourceOverride?)`，由共同 host 完成 save、完整 preview 和 receipt apply。

候选可能与旧个人操作的 precondition 冲突。未解决时 load/target 读取成功原文的编辑视图，身份同时绑定该 authoring 投影和纯候选资源；save 解决后切换候选投影。preview/apply 始终校验真实候选，metadata 也进入身份比较。原成功 Original、profile/current/draft、设置、Merge 和 provider 的 CAS 持续有效；提交后只允许 Original 精确等于本候选。Original、metadata 与成功 intent 在同次 stage/verify/apply/commit 发布；未应用草稿不改变启动来源。

## 地区选择与同次发布

共同 publisher 调用 `TemplateRegionEffects.prepareRegionChoice`，把初始 `RegionChoice` 与编译结果写入同一 source.json；`FileStore.StageWithRegionChoice` 只扩展持久化，不改变 compiler 转换。GC 和备份严格来源读取均识别、校验这个可选字段，不增加版本引用。

成功提交后调用 committed，重连调用 resume。消费状态沿用 `.region-select.json` 并绑定 versionId，旧 pending/previous 仅在来源缺少新字段时迁移。同 selector 的更新保留已消费请求；移除/换组先恢复原手动选项，离线不推断未观察的 reload fallback，后来的手动选择优先。控制面读写受原事务门禁、active version、epoch 和 session 约束；失败不撤销已提交事实。无可恢复选项时在发布前拒绝，并提供手动选择的修复操作。

### 候选草稿的关闭与恢复

候选 Original、metadata、已解决 intent 与同一个草稿 revision 必须成对保存；页面关闭不调用 undo，也不通过重新下载恢复。普通 `EditorDraftHosts.create(context,file).load()` 自动恢复已有候选，`TemplateUpdateSource` 无显式 override 时使用同一持久来源。相同 override 可继续，其他候选不能覆盖尚未处理的草稿。显式 undo 才清候选，成功 apply 的已消费 revision 只投影成功 provenance。

私有 `.intent.json` 保持旧 JSON 草稿可读。带候选的记录使用 `CED2`、8 位十六进制 UTF-8 头长及换行作为 13 字节前缀，随后是 JSON 头与原文 UTF-8 正文；头含 revision/intent、metadata、稳定来源身份、成功 profile version 和原文摘要。版本号只用于 CAS，不读取旧目录、不增加 GC 根。头部有界读取供同步 ticket 使用，正文按现有 15 MiB 字节限异步读取、分批严格解码；metadata/intent 仍受原边界约束。

事务通过 `ProfileStore.saveEditDraftAtomic` 异步短写循环、fsync、关闭、再次核对 guard/revision 后原子替换同一个文件。失败或迟到保存保留旧记录；冷进程直接读取该完整文件，未完成临时文件不参与恢复。成功来源或字节已变时拒绝沿用旧绑定，保留草稿供冲突处理。`readEditDraftSource(context,file,revision,current?)` 提供有界异步候选读取，页面不得把只含绑定的同步头当作候选正文。

已消费草稿会压缩为小标记；读取该标记始终投影当前成功意图。提交后压缩失败不否认已提交事实，但下一次发布前必须先完成压缩，避免恢复旧版本后旧候选重新出现。模板比较对恢复的已解决候选在其配对原文上重建 authoring Base/Mine，不把新的前置条件重投到旧成功 Original；仍使用共同编译器和收据流程。地区 authoring 资源解析与身份缓存读取不递归获取同一运行锁，身份同时绑定实际投影和资源字节。

### 直接读取者与联测入口

节点、规则等直接调用 ConfigEditor 的模型先捕获 `EditTicket`，再调用 `ProfileTransactions.readEditSource(context,ticket,current?)`。有候选时使用其 Original/metadata，无候选返回 undefined；该只读封装复用同一私有来源读取，前后比较完整 ticket 和成功原文字节，并把取消传给有界异步正文读取，不进入发布门禁或写草稿。保存仍经现有事务，不另建来源库。

未应用候选保留期间，手动/后台订阅更新在下载前拒绝；同一订阅的其他版本发布也不能绕过，只有该草稿的正常 apply 可发布。应用或显式撤销后更新重新放行。因此正常更新不会先改变成功版本、再把配对草稿留成无法打开/撤销的旧来源。

页面联测复用 `runCandidateDraftFixture(t,script,phases)`：真实 Go worker 在独立进程运行，各 Node 阶段共享私有文件。Node fixture 可 require `scripts/ci/candidate-draft-lifecycle.cjs`，使用 runtime/load、action、ctx/file、I/O/worker调度 hooks；实际 Store/Tx/Host/Compiler 不替换。runtime 支持 lib/pages 相对模块解析与页面源码 transform、平台/UI globals。规则组提供 `candidate-rule-page-lifecycle.cjs` 后，标准 runner 自动加 rules-save/reopen/modify/apply 四阶段并打印实际通过列表，缺少其分支时原七阶段仍全部保留；联合验收须核对四阶段实际执行，不能把仅接口分支的成功记为页面通过。

地区生成需要 provider 成员时，编译器先在双层 Merge 的私有 root 上执行同一 intent 中的 provider 声明操作，再解析本地有效缓存并生成地区实体，最后执行其余个人操作。provider 操作不会在第二阶段重放；所有原始目标 guard 在第一阶段前保存，跨 provider rename 引用改写仍按原始基线严格核对。宿主缓存投影使用 `ApplyProviderResourceEdits`，不提前执行尚未生成的组/规则编辑；最终输出继续走原有完整验证和发布事务。

分阶段执行保留原始操作序号及节点身份。延后执行的新增/更新只承接原顺序中晚于该写入的 provider 改名；mapping 只转换此次 patch 写入的引用字段，不重新改写整棵 root。改名之后才写入的旧名不会被“修复”，仍由完整引用校验拒绝。规则因资源改名改变文本时，原始目标/锚点 alias 跟随原节点，替换/删除同步迁移或清空；所有投影均作用于私有 root，不改持久 intent。
