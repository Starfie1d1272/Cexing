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

`coreTemplateUpdateAction` 是有界只读 worker 操作，JSON 为 `{op: "template-update-preview", request: UpdateRequest}`。现有 `coreVersionAction` dispatcher 所有者需要为该 op 加一条路由：

```go
if diagnostic.Op == "template-update-preview" {
    return coreTemplateUpdateAction(input)
}
```

放在既有 op 读取之后，不新增 C ABI/NAPI、文件目录或发布指针。`TemplateUpdates.preview` 使用既有 `core.versionAction` 单 worker。

`TemplateUpdateReview` 只显示必要冲突选择和编译影响。Host 组合纯比较与共同编译预览，并附既有 `TemplatePreview` 的 revision/digest/summary；没有全量编译预览时模型拒绝应用。Host.apply 必须比较原先捕获的 profile/source/draft/selection/active ticket，再走现有 stage/verify/apply/commit。应用失败保留 Current、Base/Mine 和原文；成功后才将新 baseline 与个人 delta/墓碑一同保存进成功 EditIntent/source。模板升级和运行配置应用是两个确认，纯比较成功不是应用成功。

`createTemplateUpdateHost(context, profileId, editor, source)` 已实现生产适配的本组部分；`TemplateUpdateReview({profileId, editor, source})` 直接消费它。source 只有 `read(session)`、`plan(candidate,session)`、`label(conflict)` 三个编译器数据转换回调：read 返回私有 Base/Mine/Next，plan 将已解决候选编码到统一 TemplatePlan 的受校验字段。它不持有 publisher/文件路径，不改变个人 operations/Smart/disabled/source 前提。三方未解决时绝不保存；解决后 save 惰性草稿→共同完整 preview→原 opaque receipt apply，缺 digest、错 profile、内容被改或重复 apply 均拒绝。成功/失败消耗回执后重新读取成功基线，不能复用旧升级请求。

这三个 callback 的数据来自共同编译器及成功 provenance；本组不会以回调 mock 代替生产 source。编译组确定 alias/schema/prepare 编码后，接入该适配并跑联合编译/事务链路。

共享模板字段、alias 读取/应用、草稿与成功 provenance、运行时 Host 适配须由 #146/事务所有者统一接线。本文定义本组服务边界，不把未接线函数称为已生效功能。GC 仍只用现有版本引用；模板 baseline/alias 不持有新版本 ID、路径或外部资源句柄。实际回滚使用既有 Previous/恢复事务。

## 取证与许可

采用 Base/两侧结果及显式冲突的模型，对照 [Git merge 官方文档](https://git-scm.com/docs/git-merge)。[Clash Party 固定 store 源码](https://github.com/mihomo-party-org/clash-party/blob/fbaaba2107cea0b39b5c5f1de25a3d59c7749224/src/main/simple/store.ts) 仅用于比较草稿与成功状态分离，未移植源码、模板或建立其存储系统。具体字段合并和顺序约束算法均为本项目自有实现。
