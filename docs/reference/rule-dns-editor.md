# 规则与 DNS 原生编辑

`RuleDnsEditorPage` 读取 ConfigEditor 的结构摘要；只有显式打开单项或选取策略组/provider 时才读取该目标的私人值。表单输出结构化 EditOperation，常见规则、no-resolve、规则源和 DNS/hosts 使用有类型字段；未知高级规则与 mapping 使用显式高级编辑，不丢弃未知键。高级 mapping 仅生成字段差异和删除项。

草稿使用 `RuleDnsDraft` 在内存合并同目标修改，并将旧规则 ID 的 move/add 放在替换/rename 前。所有保存与应用经现有 ProfileTransactions 的 editTicket、saveEditDraft、previewEditDraft、applyEditDraft。每次成功保存、且页面请求仍有效后，才捕获保存所产生的新 ticket。订阅更新的冲突由编译器拒绝，不能覆盖原文或上一有效版本。停用/撤销同样重新预览，再明确应用。

DNS 推荐预设只设置 AliDNS/DNSPod 的 DoH nameserver 与 IP bootstrap，不更改 rules、hosts、DNS listener、TUN 或 Controller。默认选择撤去 DNS 编辑操作，回到最新原文与两层 Merge 的 DNS。自定义直接使用同一 DNS 表单和意图，未创建另一套预设持久化。

规则拖动生成真实 move 操作；最终 MATCH 留在末尾。新增普通规则在原规则前插入。新增项与原文项分开显示，单项修改和 provider 改名仍保留原始稳定 ID。高级规则必须经过固定核心 parser/reference/完整验证后才能应用。

运行 provider 状态仅查询既有受认证 loopback Controller，并只在当前运行订阅中允许刷新。读取前后核对 Controller session，页面再核对同一 activeVersion。错误详情按需查看、不写日志。刷新失败重新读取仍在运行的规则源状态，保留核心 last-good；不写配置、不改 DIRECT、不触碰用户 URL。关联数从运行 /rules 的 RuleSet references 获取，不推断其他订阅或未运行状态。

## 入口所有权

订阅整合组在订阅详情入口设置 `RuleDnsEditorBus.file` 为该订阅文件、`RuleDnsEditorBus.section = 'rules'`，然后 push `ruleDnsEdit`。本组不修改 ProfilePage。

设置整合组的高级 DNS 入口使用同一页面，设置 file 为当前激活文件、section 为 `dns`。没有激活文件时先让用户选择订阅。导航整合组注册该 destination，传入 visible，并用 onShown/onHidden 更新它。资源恢复仍使用独立 ResourceRecoveryPage。

```typescript
NavDestination() { RuleDnsEditorPage({ visible: this.ruleDnsVisible }) }
  .title('规则与 DNS')
  .onShown(() => { this.ruleDnsVisible = true; })
  .onHidden(() => { this.ruleDnsVisible = false; })
```

结构化摘要的规则 `item.type` 必须返回固定白名单类型（含 MATCH），不返回条件或名称。没有该元数据时不能把任意末项推断为 MATCH，也不能安全判断新增 MATCH 是否重复；相应契约由编译组补齐后才可合入编辑页。
