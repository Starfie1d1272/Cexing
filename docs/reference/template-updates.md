# 模板三方比较

`profiletemplates.PreviewUpdate` 比较旧模板 Base、个人结果 Mine、新模板 Next 的模板拥有项。实体使用自编稳定 ID；名称、文本、位置变化不改变逻辑身份。它返回候选和待解决冲突，不写盘、不请求 provider、不发布版本。

## 语义

- mapping 逐字段递归合并，未知高级键也保留。无关修改自动合并；数组成员与单条规则作为完整语义值处理，同处双方不兼容修改需选择。
- rules/proxies/proxy-groups 合并顺序变化。独立重排自动组合；相互矛盾的顺序约束形成环时需选择。新增项放在其后继存活锚点前，不重复插入。用户删除用墓碑保留，跨上游删除、重加和重启仍有效。
- 冲突 ID 是三份具体语义输入及版本的摘要；旧选择不能套用到变化后的内容。未解决冲突不返回 Candidate。取消不会修改任何输入。
- `kind=template` 必须升级模板版本；`kind=subscription` 模板版本保持相同。provider 内容刷新不进入该流程，不更新模板版本或个人意图。
- 输入和候选都有实体数、体积和 ID 边界；JSON 值经既有 configpipeline YAML parser 规范化，重复键拒绝。冲突摘要不含值，但实体/路径仍是私有编辑身份，不进入日志或支持包。

## 模板与编辑器绑定

`Prepare(ctx, root, plan)` 在编译器私有的双层 Merge root 上运行既有模板变换，返回仅模板生成项的 baseline 与临时节点 bindings。AI/自动规则使用自有规则 ID；地区复用 RegionPlan，CLDR 标签映射成 ISO ID，不重复分类节点。上游节点、组、规则不被整体保存为模板快照。`TemplateTarget` 生成稳定不透明 alias，独立于规则文本、组名和顺序。

共同编辑器须以这些 alias 读取/定位模板节点，并在 scalar replacement 后更新 binding、delete 后保留显式 nil。`CaptureEdited` 读取编辑后的同一 root；旧节点指针不再可达时拒绝捕获，避免回写旧内容。bindings 仅在一次 worker 存活，不进入来源、GC 或备份。

Base 是最后成功版本的自有模板基线；Mine 是个人模板结果/墓碑；Next 从当前最新订阅和 Merge 重新生成。比较结果转成共同 EditIntent 的字段级 delta，不能替换完整上游列表为 Merge。普通上游编辑仍保留在既有 operations 中。

## 生产接线

`coreTemplateUpdateAction(input, home)` 在既有 `template-update-preview` op 内提供有界只读子请求：`request` 进行纯三方比较，`source` 从既有成功来源读取 Base、在原成功原文与模板上捕获当前个人 Mine、从当前原文与双层 Merge 生成 Next。两种输入互斥；source 不允许 URL、调用方路径或 provider 抓取。所有数据留在私有编辑通道。

`createTemplateUpdateSource` 通过既有单 worker 调用 source/read；返回输入绑定的 stamp。解决冲突后 source/encode 重新比较 stamp，调用 `EncodeDelta` 生成模板 alias 的字段 patch/delete/rename/move/add，并保留普通个人操作、Smart 和 disabled。编码结果再次通过共同完整编译，实际 Mine 必须与所选 Candidate 语义一致；不一致拒绝保存。规则替换使用单条 value，mapping 仅发变化字段及其原始前提，重排绑定共同编译器提供的锚点，不将上游整列表塞进 Merge。

`createTemplateUpdateHost(context, profileId, editor, source)` 复用 `EditorDraftHosts.create`，依次比较、惰性 save、共同完整 preview、原 opaque receipt apply。未解决冲突不保存；缺 digest、错 profile、候选被改、重复 apply 均拒绝。显式重新预览重新读取来源；退出或迟到请求不能覆盖新会话。事务内仍核对来源/草稿/设置/provider，并走 stage/verify/apply/commit；成功之后才发布新的 baseline/Mine/墓碑。纯三方 ready 不表示应用成功。

`TemplateWizard` 内的更新操作打开 `TemplateUpdateReview`，两页都可仅传 profileId 组合真实工厂与 source；自定义 editor/source 仅用于同一会话注入。默认仅显示冲突操作、短影响与应用状态，不展示快照原文。不存在的模板生成器版本不提供应用路径：当前目录只支持 v1，纯算法的合成 v2/v3 夹具不表示真实模板已经升级。

冲突卡片按实体序号、可理解名称与字段区分，并在冲突发生时展示两侧的必要差异；列表从变化处展示，排序比较保留实际优先级。凭据、请求头、完整地址与未知复杂值不作原文展示。应用错误只映射固定结果类别：未确认指向重连恢复，已提交但地区选择待恢复保留“已保存”状态，两者不再提供重复预览入口；普通失败才提示重新预览，未知异常正文不进入界面。

模板 snapshot 只保存自有实体；绑定只活于一次 worker，不进入 GC/备份。所有历史与回滚引用沿现有 Current/Previous/Profiles 及可靠性组引用门禁。取消/失败保留旧 Current，恢复沿既有 Previous 事务。结构化 JSON 数字若不能精确往返，比较前拒绝并引导高级文本编辑，不取整后写回未知字段。

## 取证与许可

采用 Base/两侧结果及显式冲突的模型，对照 [Git merge 官方文档](https://git-scm.com/docs/git-merge)。[Clash Party 固定 store 源码](https://github.com/mihomo-party-org/clash-party/blob/fbaaba2107cea0b39b5c5f1de25a3d59c7749224/src/main/simple/store.ts) 仅用于比较草稿与成功状态分离，未移植源码、模板或建立其存储系统。具体字段合并和顺序约束算法均为本项目自有实现。

下载更新使用不可变 `EditorSourceCandidate { original, metadata }`：同一候选传给 `EditorDraftHosts.create(context, profileId, candidate)` 和 `createTemplateUpdateSource(context, profileId, candidate)`，再交既有 `createTemplateUpdateHost`。source 的 Base/Mine 仍来自成功 provenance，Next 来自候选；未解决冲突时共同 host 保留成功编辑视图，避免旧个人 precondition 提前阻断冲突入口。解决后经同一收据完整预览、发布候选 Original/metadata/intent。不得预写下载原文或另建 publisher；页面退出和迟到响应沿用同一 host 的代次检查。

冷恢复的模板 Source 使用 `ProfileTransactions.readEditSource(context, ticket, current?)` 读取配对来源，不直接绕过共同校验读取私有正文。会话意图修订与完整 ticket 必须匹配，读取、资源准备及 worker 返回前后继续核对同一 ticket。Host reset 取消 Source 的分块读取并丢弃迟到结果，不撤销或删除草稿；重新进入由同一配对来源重新预览，再消费原收据提交。
