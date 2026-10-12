# Controller 宿主契约

Controller 安全线的实现与其他配置/面板任务对接入口。基于 main `7f731d5c9c8d4eba7a1680bcb3981d7877232bcc` 和锁定 Mihomo 模块，保留四个 C ABI、ProfileStore 格式及应用身份。

## 地址、认证与存储

唯一 Controller 为 `http://127.0.0.1:9090` / `ws://127.0.0.1:9090`。禁用 TLS、Unix、pipe 等替代控制入口、Controller DoH 和未经认证的 debug。

Go 初始化是唯一写入方：使用系统密码学随机源生成 32 字节 Secret，以 64 位小写 hex 写入 `<filesDir>/controller-security/secret`。目录 0700、文件 0600，原子发布；缺失时首次生成，既有文件损坏或权限异常时拒绝启动，不能匿名回退。UI 与 VPN 扩展使用同一 entry 模块 filesDir。Secret 不经过配置、设置、ProfileStore、Want 或公开产物。这是应用 UID 沙箱隔离，不能抵御已控制本应用进程的攻击者。

原生 `CoreApi.getControllerAccess(): ControllerAccess | null` 返回内存中的 `{ httpBase, wsBase, secret }`；每次请求、首次 WS 和重连均重新读取。可用 `CoreApi.bindContext(context)` 明确绑定模块上下文；冷恢复自动取得 entry 模块上下文。尚未初始化/读取失败时返回 null。

REST 与原生 WS 使用 `Authorization: Bearer <secret>`。浏览器 WS 只能使用上游支持的 `?token=<secret>`，仅用于 WS 握手；不得作为页面导航、公开配置、日志、持久化 URL、历史或分享链接。面板如何注入内存凭据及屏蔽 URL/错误日志由面板线落实。静态 `/ui/` 可以匿名加载，不能作为 API 探活成功证据。

## 配置引擎接口

`PUT /configs` 与 `/configs/` 仅接受一个非空 `path` 或 `payload`，可选 `overrides` 为现有 ArkTS UserOverrides 的 JSON 字符串。路径必须是 filesDir 内非符号链接的 `.yaml/.yml/.json` 文件，排除 credential 和 UI 目录。payload 最大 16 MiB；未知请求字段拒绝。`force` 查询参数为兼容现有调用而保留，宿主始终完整应用。

`CoreApi.reloadConfig(absPath: string, overrides?: string): Promise<boolean>` 保持现有调用有效；新配置事务可传最新设置覆写。省略 overrides 使用本次启动或最近成功重载的设置。不在此处重造 Merge 引擎。原始配置 → 外部 Merge/策略引擎 → 宿主受控入口 → 支持的设置覆写 → 平台最终约束 → Mihomo 校验 → 应用。

平台最终约束每次启动和重载统一施加：Controller 地址/Secret/CORS、UI 目录与禁止自动下载、禁用内核自动建 TUN/iptables/系统时间写入。额外 `listeners[].type=tun` 明确拒绝，防止经通用监听器绕过自动 TUN 禁用。系统 fd 的 TUN 使用宿主 gVisor、`172.19.0.1/30`、MTU 9000、DNS 劫持 `0.0.0.0:53`，不消费订阅的 tun 扩展字段。重载调用 executor 不重建 Controller 或系统 TUN，既有 REST/WS 认证与 UI 参数保留。

返回 204 表示解析通过并执行 Mihomo ApplyConfig；400 为无效请求/配置，409 为宿主未初始化。上游 ApplyConfig 没有事务失败返回值；此接口不能宣称 provider 加载或网络转发已成功，更不能替代配置事务线的保存/应用回退。失败解析在 ApplyConfig 前结束；错误不回显任意 YAML 值。ProfileStore 原始数据格式不变。

`PATCH /configs` 仅接受 `mode`（rule/global/direct）与 `log-level`（上游枚举）；其他字段一并拒绝，不能通过 PATCH 建 TUN 或更改平台边界。`/restart` 与 `/upgrade` 整个路由树在服务器拒绝（405），Geo 更新/规则写入维持上游 embed 限制。需要重启走原生 VPN 生命周期。

## 面板资源边界

`external-ui` 固定为 `<filesDir>/ui`；资源线应将验过摘要的离线文件原子铺盘到这个实际目录，目录及文件不使用符号链接。启动前递归拒绝符号链接；资源缺失返回 404，不联网下载。不要在服务运行时写入来源不明的文件或绕过边界替换目录。

CORS 仅允许 `http://127.0.0.1:9090`，不开放通配来源或 private-network。使用同源 `/ui/`；原生 REST/WS 不受浏览器 CORS 限制。外部导航、JS bridge、PWA 和面板凭据注入由面板线验收。Controller 探活与系统 VPN 健康继续分开。


## 与兼容规范 v1 的衔接

兼容线 PR #2 的 platformSnapshot 可以记录固定回环端口、TUN 地址/MTU 和 UI 私有根句柄；Secret 只传不透明句柄或“已初始化”的状态，不能把 `getControllerAccess()` 的敏感对象放入候选、摘要、diff 或验证回执。配置引擎处理受保护字段时可给出 PROTECTED_FIELD，运行宿主仍重新施加最终强约束。

providerSnapshot、固定 coreIdentity/capabilitiesDigest、validationReceipt、expectedActiveRevision 的生成、过期检测和激活比较交换由配置事务线负责。当前 REST 重载只提供受约束的运行应用边界，没有实现这些事务字段或 provider 完整健康确认。基线不支持 Smart；此安全改动不增加 Smart 或模型能力。


## 冷恢复的意图代次

`VpnController.recover(onDone?)` 的探活提交由独立恢复代次保护。新一次 recover、有效 start、所有显式 stop（含仍为 Disconnected 的取消）和 `cancelRecovery()` 都使旧探活失效；过期结果既不提交 Connected，也不触发旧 onDone。新鲜探活与非断开态的现有完成语义保留。恢复代次与启动 IPC 的 startAttempt 分离，取消探活不会破坏正在进行的启动就绪检查。

运行时线 PR #4 可在 `AppRuntime.cancelRestore()` 调用 `VpnController.cancelRecovery()`，覆盖只取消恢复/当前 Ability 销毁而没有 start/stop 的情况；这只是失效在途探活，不停止 VPN 或后台任务。本分支未修改 AppRuntime/EntryAbility。显式 start→stop→Disconnected 的竞态在本分支已封闭，纯运行时取消需该调用合流。Controller 探活仍不能证明系统 VPN 健康。
