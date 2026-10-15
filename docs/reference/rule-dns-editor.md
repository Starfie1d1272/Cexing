# 规则与 DNS 原生编辑

`RuleDnsEditorPage` 消费现有生产 `EditorDraftHosts`。入口按订阅创建 host；load 返回 session、投影后的摘要及缺失字段 revision，target 仅在打开单项时读取私人值。save 后重新绑定 session，preview 返回语义摘要与 digest，apply 只提交当前已展示的 revision/digest；undo 撤销草稿。宿主核对原文、两层 Merge、草稿、设置和 provider 资源身份，统一经原配置事务发布。页面不创建持久化或发布系统。

`RuleDnsForms` 输出结构化 EditOperation，常见规则、no-resolve、规则源和 DNS/hosts 使用类型字段。未知规则与 mapping 有显式高级编辑入口，mapping 只生成字段差异和删除项，不丢弃未知键。`RuleDnsDraft` 仅在内存合并连续字段修改，保留第一次 precondition；规则 move/update/delete 与 provider rename 保留当前投影 ID 的操作顺序。

已有及新增规则都通过保存后的真实摘要展示和重排，拖动产生 move 操作；新增规则可选择插入位置，普通新增默认在现有规则前。MATCH 始终保留最终位置。摘要缺失规则类型时拒绝排序和新增 MATCH，不能将任意末项猜成最终规则。该安全白名单类型须由编译器在已有 `EditableItem.type` 返回，不包含私人条件。

DNS 推荐只设置 AliDNS/DNSPod DoH nameserver 与 IP bootstrap，不更改 rules、hosts、DNS listener、TUN 或 Controller。默认选择撤去 DNS 编辑操作，恢复原文与两层 Merge 的 DNS；自定义使用同一意图，无第二套预设存储。所有修改先显示现有 `CoreValidator.describeMergePreview` 的语义摘要，再由用户明确应用；停用与启用亦重新预览。

provider 状态只查询既有受认证 loopback Controller：GET `/providers/rules` 集合并按名称选择，PUT `/providers/rules/{name}` 显式刷新。仅当前运行订阅且草稿与已发布意图一致时允许查询，前后核对 Controller session 与 activeVersion。失败显示短反馈，实际错误详情按需打开；重新读取仍在运行的状态，不写配置、不改 DIRECT、不记录私人 URL。关联数从运行 `/rules` 的 RuleSet references 获取，加载数不等同真实流量验收。

## 入口所有权

订阅组设置 `RuleDnsEditorBus.file`、`RuleDnsEditorBus.section = 'rules'`，push `ruleDnsEditor`；Index 的 destination 按 onShown/onHidden 传递 visible。此接线由订阅组 #182 提供，本组集成原提交验证。

设置组的高级 DNS 入口复用同页，设置 file 为选定订阅、section 为 `dns`。没有激活文件时先选订阅。本组不修改 ProfilePage、Index 或 Settings 的入口文件。资源恢复使用独立 `ResourceRecoveryPage`，设置组 #171 提供导航。

隐藏页面使在途结果失效；重复点击不能重复保存或应用。失败预览、应用未确认和资源身份变化均禁止继续提交，用户通过重试或重新打开恢复。页面生命周期不停止 VPN。
