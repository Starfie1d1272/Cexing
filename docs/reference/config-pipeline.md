# 独立配置编译与事务接口

`core/configpipeline` 是独立 Go 包。生产离线校验入口使用其 `InspectOffline` 做 YAML 与引用检查；Merge 草案预览调用 `Compiler` 的固定 Verge v2.5.8 语义，只返回固定 section 数量和摘要。`FileStore`、`Transaction` 与生成配置的运行应用仍未接入生产；草案 sidecar 不会改变当前配置。先满足本文接入条件，再替换现有激活路径。模块使用仓库锁定的 yaml.v3 与 Mihomo 规则拆分函数，没有新增依赖。

## 与安全线、策略线的最小契约

安全线提供唯一的平台约束实现及其非敏感投影；本包不定义端口、Secret、external-ui、TUN 的安全值或第二套限制逻辑。

```go
// 参数是已完成覆写/策略转换的独立 YAML mapping，不是 DocumentNode。
// 修改成功后返回 nil；策略产出只能是可持久化配置，不含平台运行态。
type Transform func(context.Context, *yaml.Node) error
// 仅投影非敏感可序列化字段；不能注入运行态 Secret。
type PlatformProjection func(context.Context, *yaml.Node) error
// 必须完成锁定 Mihomo 的完整解析及必要资源检查，不启动监听器。
type Validator func(context.Context, []byte) error
Compiler{Platform: projectNonSensitivePlatform, Validate: validateRuntimeCopyWithSecurity}
```

Platform 与 Validate 都必填；没有静默默认值或自动降级。策略线通过 `Request.Strategy` 接收同一 mapping，可按名称生成/更新组、规则和 provider；支持未来 `smart` 字段的原样传递，具体组类型是否可用由被锁定内核的 Validate 判断。本包不做 Smart 选点，不执行 JS、Shell 或 Ruby。

如安全线接口采用 `map[string]any`，由安全线/宿主提供 Node adapter：只将其拥有的非敏感可持久化字段写回 Node，绝不注入 Secret 等敏感运行态，保持无关的有序映射（例如 nameserver-policy）和规则顺序。不在本包复制安全字段清单。启动、更新、编辑、热重载必须使用同一个约束实现。实际联调仍是后续接入门槛。

### 持久候选与运行态的边界

安全 PR #9 的 `enforcePlatformSecurity`/`preparePlatformConfig` 使用应用 Secret 构造**仅内存**的最终运行配置，不能直接适配为 Compiler.Platform；若误接而输出顶层 secret，本包在 YAML 编码/返回候选前拒绝，不能靠写盘后删字段补救。PlatformProjection 由安全线提供，只投影非敏感字段，不在本包复制其安全值、字段过滤清单或 credential 存储实现。当前安全线若尚未提供投影 adapter，不允许用运行态约束函数替代；这是后续接入前置条件。

完整 Validator 收到不含平台敏感运行态的 YAML，宿主安全模块在自己的私有副本中重新施加唯一最终约束并注入 Secret，再调用锁定内核解析器；副本只能用于本次验证，不返回 Result/Store/日志。Activate 与 Restore 从 credential-free Version.Path 读取，并使用**同一个**安全模块准备内存运行配置，不改写版本文件。Controller 凭据仍只由安全线的专用私有存储拥有，不经过 Request、平台快照的公开材料、Original/Overlays、候选 YAML、成功版本、差异摘要、摘要哈希或 source.json。平台/网络身份及验证回执只使用不透明身份；Secret 轮换不改变持久候选 Digest。

原文/overlay 中顶层 secret（含大小写形式、null/空串）明确拒绝，不能先丢弃生成配置中的字段却把原文凭据保存进 source.json。Strategy/Platform 注入该字段同样拒绝。FileStore.Stage 对生成 YAML、原文、每层覆写再执行这一持久化边界检查，防止绕过 Compiler 直接提交 Result；失败发生在任何写盘之前。此拒绝检查只定义序列化边界，不生成 Secret、不能证明 runtime 约束已经生效，也不代替安全线唯一最终约束。节点密码等订阅私有数据仍仅存于应用私有原文/配置，不能公开或记录日志。

Mihomo v1.19.32 `config.ParseRawConfig` 会临时更新全局 General/IPv6 状态，构造代理/provider，并可能访问 geodata。不能声称它是纯校验函数，也不能在 UI/并发预览线程调用。宿主必须通过已有单 worker 串行执行，提供应用私有 home/资源上下文和清理责任，屏蔽上游包含输入的错误/日志。本模块对 callback 错误只返回固定阶段文本，原始错误不得直接进入 UI/日志。独立集成测试在一次性子进程调用锁定解析器，不启动监听器；这不证明应用运行时隔离已接入。

## 编译行为

`Compile` 顺序为原始 YAML → 按顺序 Merge overlays → 可选 Strategy → 必填 Platform → 结构/引用检查 → 完整 Validate → 返回最终 YAML。全部输入复制，Result 保留准确的 Original 与各层 Overlays；生成配置独立于原文。多文档、重复键、非字符串键、循环别名、自定义 YAML tag 和不支持的标准 collection tag 明确拒绝；只支持标准 map/seq、str/bool/int/float/null/timestamp/binary scalar 及实际 merge-key。检查覆盖原文、overlay、别名目标与策略/平台回调产出；不会将未知 tag 静默当普通字符串或对象。正常 YAML alias/merge key 会展开，保留显式有序映射的顺序。支持 UTF-8 YAML/JSON，旧导入编码修复仍由现有宿主负责。

- Merge 固定采用 Clash Verge v2.5.8 的 [merge.rs](https://github.com/clash-verge-rev/clash-verge-rev/blob/4337bd85758d54d7b9044b2da3c9ac1176eae1f3/src-tauri/src/enhance/merge.rs)（提交 `4337bd85758d54d7b9044b2da3c9ac1176eae1f3`），以及其 [顶层键名处理](https://github.com/clash-verge-rev/clash-verge-rev/blob/4337bd85758d54d7b9044b2da3c9ac1176eae1f3/src-tauri/src/enhance/field.rs)：overlay 顶层键仅 ASCII 小写化，mapping 递归合并；scalar、null、所有数组整体替换。null 是值，保留键，不表达删除。
- proxies、proxy-groups、listeners 与 rules 等所有数组都整体替换，不按名称推测局部更新，不隐式去重/重排规则。空数组明确清空。需要 Canonical 管理组/规则按名称生成、更新、去重或顺序插入时，只能由显式版本化 Strategy 负责，并验证自身幂等及保留非管理项；通用 Merge 没有 `$delete`、removePaths 或第二套公开方言。
- 顶层 dns 的新旧值都为 mapping 时，只在直接子字段层做替换：nameserver-policy、fallback-filter 等子 mapping 不递归混入旧字段；未指定的 DNS 直接子字段保留。顶层 hosts 整体替换，包括空 mapping。其他 mapping（例如 tun）继续递归合并。该行为对应上游 2026-09-22 [DNS/hosts 修正](https://github.com/clash-verge-rev/clash-verge-rev/commit/6a85d0344e5df34c750ca3158e53b8b37a5ddf82)之后的来源版本，旧版 DNS/hosts 深度合并不是等价迁移；宿主导入时必须明确来源版本并预览新结果，不能静默声称旧语义兼容。本包匹配所引用的 use_merge，而不是承诺实现上游其余增强阶段或任意脚本执行。
- 组目标、`use` provider、规则目标、SUB-RULE、顶层 RULE-SET、dialer-proxy 和组依赖环先检查；嵌套逻辑规则/provider、协议字段、DNS、资源、规则语法及具体组类型由必填完整 Validate 检查。
- 支持 proxies 及 provider-only；至少有一项。provider 定义要求类型与对应来源，HTTP URL 的明显占位形式拒绝；这不能替代资源存在、下载结果或可用节点检查，后者属于完整 Validate。file 路径边界由宿主/平台约束处理。
- 差异摘要仅返回固定 section 名与数量，不返回节点名、规则、URL 或字段值；`Previous` 仅供比较，不参与合并。摘要没有列出的其他字段仍完整保留在 YAML 中。

订阅更新必须使用最新原文与已保存的覆写/策略重新 Compile，不能把上一份 generated YAML 当作订阅原文，否则旧订阅字段和策略生成可能累积。编译结果是私有数据，不得把 Result/YAML/Original/source.json 作为日志或公开配置导出。

## 保存与激活

`Transaction.Apply` 在一个 coordinator 的互斥锁内执行 Load → 比对 Request.ExpectedActiveRevision → Compile → Stage → Activate → Commit。revision 使用 Current.ID；空字符串仅匹配尚无激活版本，过期返回 ErrStaleRevision，不保存/激活候选。下载发起时捕获 revision，不能在下载完成后用最新 revision 冒充原意图。Store 的任何错误必须保留原 successful snapshot；Activate 即使返回错误也按可能部分生效处理，调用 Restore。Commit 失败也恢复运行内核。Restore 接收上一成功 Version；nil 表示停止候选/恢复未激活状态。激活成功必须表示应用完成，而不是请求已经入队；不能把 Controller 探活等同系统 VPN 健康。

FileStore 在应用私有 Root 创建不可变版本目录（0600 文件、0700 目录），分别存放 config.yaml 和保留原文/覆写的 source.json；成功后原子 rename state.json 指针，保留 Current/Previous。候选并未覆盖旧成功文件。文件落盘/激活/commit 失败都不会切换 successful pointer；成功回滚后丢弃失败候选。回滚失败保留候选并以 `Failure.RollbackFailed` 报告，宿主应显示需恢复状态并停止继续事务，不能宣称已恢复。取消请求后仍需以不受该请求取消影响的 context 回滚，宿主必须为恢复操作提供自己的有界执行策略。

此事务保证进程内失败回退与原子文件指针，不声称文件系统与运行内核组成跨进程/掉电原子事务。文件都 fsync，发布后 directory fsync 尽力执行（发布已成功后不能再返回“未提交”并删除它）。若进程在 Activate 与 Commit 之间崩溃，下次启动应从 state.json 的 Current 重建内核；宿主需实现启动恢复与全局单写者/跨进程协调。不能让多个 coordinator 指向同一 Root。版本保留/垃圾回收由宿主在确认 Current/Previous 后显式进行；禁止清理现有用户数据。

## 在途下载、取消与 ProfileStore 写入边界

接入时下载请求必须捕获以下宿主内部 ticket，绑定到同一事务，不能在异步下载完成后重新读取当前选择来补签：

```typescript
interface SubscriptionUpdateTicket {
  profileId: string;              // 发起下载的稳定 profile 身份
  sourceRevision: string;         // URL/来源及原文编辑版本，不能用 URL 本身当身份
  selectionEpoch: string;         // 选择、编辑、删除、取消或会话失效时递增
  expectedActiveRevision: string; // 对应本包 Snapshot.Current.ID
}
```

下载结果先保存在内存或新临时文件，只能进入该 ticket 的候选目录。禁止先调用旧 ProfileStore 的原文覆盖写入再检查取消，也禁止根据下载结束时的 active profile 把结果写进另一个 profile。仅阻止迟到 CoreApi reload 或成功时间戳不足以保护原文、来源元数据与激活指针。

宿主必须把选择/编辑/取消与配置提交纳入同一串行 coordinator，ticket 的 profile 身份、sourceRevision、selectionEpoch、expectedActiveRevision 在接收下载结果、Stage 前、Activate 前及最终 Commit 的临界区内校验。任何变化均返回陈旧/取消，不覆盖现有原文、覆写、来源元数据、成功更新时间或激活选择；即使重新选回同一个 profile，epoch 不同也应拒绝旧请求。取消下载本身只是尽力操作，不能代替上述提交检查。

本包的 ExpectedActiveRevision 只保护成功配置版本；它不表示 ArkTS 的待选 profile、来源编辑或 VPN 会话代次。应用选择改变而尚未提交新配置时，Current.ID 可能不变，因此宿主仍必须检查 selectionEpoch/profileId。宿主可把检查封装到 Store/Activator adapter，但最终检查和持久化发布必须处于同一选择锁/事务门控，不能留出“检查通过后切换 profile、随后旧写入发布”的窗口。本轮没有修改 ProfileStore，也没有宣称旧写入路径已修复。

原文、覆写、生成配置和来源元数据先落到新的不可变版本目录；最终用一个原子 manifest/成功指针发布其身份，随后界面和启动从同一权威指针读取。不能分别 overwrite 原文与 active 元数据并把其中一个 rename 当成整体事务。若暂时保留旧 ProfileStore 文件布局，需要另行设计可恢复日志/统一元数据提交 adapter，不得同时维护两个独立激活权威。失败/取消只清理本事务创建的候选，不删旧 profile 或上次成功配置。

激活已开始后才取消/过期时，Restore 必须恢复发起事务前的成功版本（首次无成功版本则停止部分候选）；恢复失败保留材料并阻断后续激活。后续接入回归必须用可控下载/写入屏障覆盖：A 下载中切换到 B、A 来源被编辑/删除、取消后重新选择 A、Stage 中取消、Activate 与 Commit 之间切换，以及两次更新乱序完成。逐项确认 A/B 原文、来源元数据、成功指针和运行内核都未被迟到结果污染，不能只断言 reload 未调用。

## 具体接入顺序

1. 宿主显式分类完整配置、Merge 与 provider payload，并绑定平台/provider 快照、固定内核能力和验证回执；本包只接收已分类的完整 base，不实现格式猜测或 provider 获取。校验回调/策略闭包捕获这些不可变上下文，生产提交需再核对其网络与能力身份。独立包不宣称已实现 ArkTS PlanRequestV1 协议。
2. 安全线提供非敏感 PlatformProjection adapter 与统一认证来源；宿主 Validator/Activate/Restore 通过同一安全模块仅在私有运行副本注入敏感字段，并提供串行完整 Mihomo 校验、私有资源上下文与日志屏蔽。先联测恶意订阅/覆写/策略均不能改变受保护字段。
3. 在 Go worker 边界包装 Compile/Apply，保持现有四个 C ABI；新增桥接方式另开接入 PR，不在本包直接改 ABI。ArkTS 通过受控桥接传输入和固定差异摘要，不能在主线程直接调用 Go。
4. 按上述 ticket/选择锁保护下载与写入，ProfileStore 读取现有来源元数据，向新私有目录保存 Original/Overlays/策略标识；更新、切换、编辑和启动均走唯一事务。策略函数自身不能 JSON 序列化，需由宿主将稳定策略 ID/版本映射到已注册函数，禁止任意代码执行。
5. Activator 只应用已生成的不可变 Version.Path；安全线保证所有重载路由仍使用同一约束。应用失败 Restore 旧路径，首次失败停止部分激活候选；系统 TUN 生命周期仍由 VPN Extension 管理。
6. crash/restart 从 successful pointer 恢复，与运行时线共同验收系统会话状态。完整契约回归通过前，保留当前导入及激活能力，不提前替换生产入口。

验收与原有门槛见 [配置契约](configuration.md)、[开发顺序](../development.md)；构建与实际网络/设备验证是不同证据。
