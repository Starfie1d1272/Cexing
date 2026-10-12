# 独立配置编译与事务接口

`core/configpipeline` 是独立 Go 包，尚未被生产入口引用，不改变应用名称、包名、ProfileStore 格式、自动更新或 VPN 启动路径。先满足本文接入条件，再替换现有激活路径。模块使用仓库锁定的 yaml.v3 与 Mihomo 规则拆分函数，没有新增依赖。

## 与安全线、策略线的最小契约

安全线提供唯一的平台约束函数；本包不定义端口、Secret、external-ui、TUN 的安全值或第二套限制逻辑。

```go
// 参数是已完成覆写/策略转换的独立 YAML mapping，不是 DocumentNode。
// 修改成功后返回 nil；不得输出输入或密钥到日志。
type Transform func(context.Context, *yaml.Node) error
// 必须完成锁定 Mihomo 的完整解析及必要资源检查，不启动监听器。
type Validator func(context.Context, []byte) error
Compiler{Platform: enforcePlatform, Validate: validateFullConfig}
```

Platform 与 Validate 都必填；没有静默默认值或自动降级。策略线通过 `Request.Strategy` 接收同一 mapping，可按名称生成/更新组、规则和 provider；支持未来 `smart` 字段的原样传递，具体组类型是否可用由被锁定内核的 Validate 判断。本包不做 Smart 选点，不执行 JS、Shell 或 Ruby。

如安全线接口采用 `map[string]any`，由安全线/宿主提供 Node adapter：只将其拥有的受保护字段写回 Node，保持无关的有序映射（例如 nameserver-policy）和规则顺序。不在本包复制安全字段清单。启动、更新、编辑、热重载必须使用同一个约束实现。实际联调仍是后续接入门槛。

Mihomo v1.19.32 `config.ParseRawConfig` 会临时更新全局 General/IPv6 状态，构造代理/provider，并可能访问 geodata。不能声称它是纯校验函数，也不能在 UI/并发预览线程调用。宿主必须通过已有单 worker 串行执行，提供应用私有 home/资源上下文和清理责任，屏蔽上游包含输入的错误/日志。本模块对 callback 错误只返回固定阶段文本，原始错误不得直接进入 UI/日志。独立集成测试在一次性子进程调用锁定解析器，不启动监听器；这不证明应用运行时隔离已接入。

## 编译行为

`Compile` 顺序为原始 YAML → 按顺序 Merge overlays → 可选 Strategy → 必填 Platform → 结构/引用检查 → 完整 Validate → 返回最终 YAML。全部输入复制，Result 保留准确的 Original 与各层 Overlays；生成配置独立于原文。多文档、重复键、非字符串键、循环别名明确拒绝；正常 YAML alias/merge key 会展开，保留显式有序映射的顺序。支持 UTF-8 YAML/JSON，旧导入编码修复仍由现有宿主负责。

- 本包方言命名为 `pipeline-merge-v1`：Mapping 递归合并；overlay 中 null 删除该键。
- 顶层 proxies、proxy-groups、listeners 数组按 name 深度合并。已有项保持位置、新项按 overlay 顺序追加；`{name: synthetic, $delete: true}` 删除项。原文或单层覆写重复名称拒绝，重复执行同层覆写幂等。
- 其他数组整体替换，空数组明确清空。规则数组整体替换后只去除完全一致的重复规则，保留第一次出现的位置。不同目标的同条件规则不会重排或自动裁决，仍按第一匹配优先；需要插入/追加的策略必须明确构造完整规则数组。这是本包定义的 Merge 语义，不声称兼容任意第三方 Merge 方言。
- 组目标、`use` provider、规则目标、SUB-RULE、顶层 RULE-SET、dialer-proxy 和组依赖环先检查；嵌套逻辑规则/provider、协议字段、DNS、资源、规则语法及具体组类型由必填完整 Validate 检查。
- 支持 proxies 及 provider-only；至少有一项。provider 定义要求类型与对应来源，HTTP URL 的明显占位形式拒绝；这不能替代资源存在、下载结果或可用节点检查，后者属于完整 Validate。file 路径边界由宿主/平台约束处理。
- 差异摘要仅返回固定 section 名与数量，不返回节点名、规则、URL 或字段值；`Previous` 仅供比较，不参与合并。摘要没有列出的其他字段仍完整保留在 YAML 中。

订阅更新必须使用最新原文与已保存的覆写/策略重新 Compile，不能把上一份 generated YAML 当作订阅原文，否则删除和策略生成可能累积。编译结果是私有数据，不得把 Result/YAML/Original/source.json 作为日志或公开配置导出。

## 保存与激活

`Transaction.Apply` 在一个 coordinator 的互斥锁内执行 Load → 比对 Request.ExpectedActiveRevision → Compile → Stage → Activate → Commit。revision 使用 Current.ID；空字符串仅匹配尚无激活版本，过期返回 ErrStaleRevision，不保存/激活候选。下载发起时捕获 revision，不能在下载完成后用最新 revision 冒充原意图。Store 的任何错误必须保留原 successful snapshot；Activate 即使返回错误也按可能部分生效处理，调用 Restore。Commit 失败也恢复运行内核。Restore 接收上一成功 Version；nil 表示停止候选/恢复未激活状态。激活成功必须表示应用完成，而不是请求已经入队；不能把 Controller 探活等同系统 VPN 健康。

FileStore 在应用私有 Root 创建不可变版本目录（0600 文件、0700 目录），分别存放 config.yaml 和保留原文/覆写的 source.json；成功后原子 rename state.json 指针，保留 Current/Previous。候选并未覆盖旧成功文件。文件落盘/激活/commit 失败都不会切换 successful pointer；成功回滚后丢弃失败候选。回滚失败保留候选并以 `Failure.RollbackFailed` 报告，宿主应显示需恢复状态并停止继续事务，不能宣称已恢复。取消请求后仍需以不受该请求取消影响的 context 回滚，宿主必须为恢复操作提供自己的有界执行策略。

此事务保证进程内失败回退与原子文件指针，不声称文件系统与运行内核组成跨进程/掉电原子事务。文件都 fsync，发布后 directory fsync 尽力执行（发布已成功后不能再返回“未提交”并删除它）。若进程在 Activate 与 Commit 之间崩溃，下次启动应从 state.json 的 Current 重建内核；宿主需实现启动恢复与全局单写者/跨进程协调。不能让多个 coordinator 指向同一 Root。版本保留/垃圾回收由宿主在确认 Current/Previous 后显式进行；禁止清理现有用户数据。

## 具体接入顺序

1. 宿主显式分类完整配置、Merge 与 provider payload，并绑定平台/provider 快照、固定内核能力和验证回执；本包只接收已分类的完整 base，不实现格式猜测或 provider 获取。校验回调/策略闭包捕获这些不可变上下文，生产提交需再核对其网络与能力身份。独立包不宣称已实现 ArkTS PlanRequestV1 协议。
2. 安全线提供 Platform adapter 与统一认证来源；宿主提供串行完整 Mihomo Validator、私有资源上下文与日志屏蔽。先联测恶意订阅/覆写/策略均不能改变受保护字段。
3. 在 Go worker 边界包装 Compile/Apply，保持现有四个 C ABI；新增桥接方式另开接入 PR，不在本包直接改 ABI。ArkTS 通过受控桥接传输入和固定差异摘要，不能在主线程直接调用 Go。
4. ProfileStore 读取现有来源元数据，向新私有目录保存 Original/Overlays/策略标识；更新、切换、编辑和启动均走唯一事务。策略函数自身不能 JSON 序列化，需由宿主将稳定策略 ID/版本映射到已注册函数，禁止任意代码执行。
5. Activator 只应用已生成的不可变 Version.Path；安全线保证所有重载路由仍使用同一约束。应用失败 Restore 旧路径，首次失败停止部分激活候选；系统 TUN 生命周期仍由 VPN Extension 管理。
6. crash/restart 从 successful pointer 恢复，与运行时线共同验收系统会话状态。完整契约回归通过前，保留当前导入及激活能力，不提前替换生产入口。

验收与原有门槛见 [配置契约](configuration.md)、[开发顺序](../development.md)；构建与实际网络/设备验证是不同证据。
