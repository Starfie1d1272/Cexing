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

`external-ui` 固定为 `<filesDir>/ui`；资源线应将验过摘要的离线文件原子铺盘到这个实际目录，目录及文件不使用符号链接。启动前检查 root 必须是目录，递归检查符号链接/特殊文件，并按面板版本布局校验当前选择器、manifest 身份、文件全集与文件摘要；资源缺失、损坏或任何检查失败时静态根降级为 404，不联网下载，也不中止认证 API/VPN 初始化。不要在服务运行时写入来源不明的文件或绕过边界替换目录。

CORS 仅允许 `http://127.0.0.1:9090`，不开放通配来源或 private-network。使用同源 `/ui/`；原生 REST/WS 不受浏览器 CORS 限制。外部导航、JS bridge、PWA 和面板凭据注入由面板线验收。Controller 探活与系统 VPN 健康继续分开。


## 与兼容规范 v1 的衔接

兼容线 PR #2 的 platformSnapshot 可以记录固定回环端口、TUN 地址/MTU 和 UI 私有根句柄；Secret 只传不透明句柄或“已初始化”的状态，不能把 `getControllerAccess()` 的敏感对象放入候选、摘要、diff 或验证回执。配置引擎处理受保护字段时可给出 PROTECTED_FIELD，运行宿主仍重新施加最终强约束。

providerSnapshot、固定 coreIdentity/capabilitiesDigest、validationReceipt、expectedActiveRevision 的生成、过期检测和激活比较交换由配置事务线负责。当前 REST 重载只提供受约束的运行应用边界，没有实现这些事务字段或 provider 完整健康确认。基线不支持 Smart；此安全改动不增加 Smart 或模型能力。


## 冷恢复的意图代次

`VpnController.recover(onDone?)` 的探活提交由独立恢复代次保护。新一次 recover、有效 start、所有显式 stop（含仍为 Disconnected 的取消）和 `cancelRecovery()` 都使旧探活失效；过期结果既不提交 Connected，也不触发旧 onDone。新鲜探活与非断开态的现有完成语义保留。恢复代次与启动 IPC 的 startAttempt 分离，取消探活不会破坏正在进行的启动就绪检查。

运行时线 PR #4 可在 `AppRuntime.cancelRestore()` 调用 `VpnController.cancelRecovery()`，覆盖只取消恢复/当前 Ability 销毁而没有 start/stop 的情况；这只是失效在途探活，不停止 VPN 或后台任务。本分支未修改 AppRuntime/EntryAbility。显式 start→stop→Disconnected 的竞态在本分支已封闭，纯运行时取消需该调用合流。Controller 探活仍不能证明系统 VPN 健康。


## UI 故障降级与私有资源边界

UI 故障与凭据故障分离：凭据异常仍拒绝启动；UI 缺失、普通文件根、symlink、当前入口损坏、选中版本缺失、manifest/文件摘要不符或额外文件，只将静态访问降级为 404。降级的根是已校验为普通文件的私有 credential 文件下面的不可遍历子路径；该根不可能成为目录。锁定 HTTP Dir 将 ENOTDIR 映射为 404，任何请求都不会读取 credential 文件本身。绝不调用 SetUIPath(空字符串)，因为锁定 Mihomo 会把它解析为私有 homeDir。

受认证 `GET /ohos/ui-status` / `CoreApi.getControllerUiStatus()` 返回初始化时的 `{ available, error }` 快照；error 仅是可恢复提示，不包含路径、原始解析错误或 Secret。404 不意味着 API/VPN 不可用；热重载仍不重建 Controller，不能用配置恢复危险 static root。修复资源后，下一次 Controller 初始化重新校验；本线没有增加无验证的实时 UI 开关或面板文件写入口。

磁盘一致性校验使用 #10 的 ZASHBOARD_SELECTION 入口、versions/<files摘要>/manifest.json 以及 path/size/sha256 文件清单。它不替代面板线安装时的固定来源与入包 manifest 摘要批准，也不证明完整 WebView/凭据/CSP 联调。服务运行时，面板资源只能通过既有受校验原子部署路径更新；不允许绕过它写入任意文件。

## 配置线的持久化投影和敏感运行态

唯一平台函数拆分为两个用途，共享同一字段约束实现：`projectPlatformConfig(map[string]any)` 施加平台默认与最终字段约束，并**删除顶层 Controller secret**；这是配置线 Platform Transform 可持久化投影的接口。Transform(ctx,*yaml.Node) 的适配只 Decode 为 map、调用这一个函数、Encode 回 node；不得调用运行态注入函数来生成候选 YAML。不要复制第二套字段常量或约束表。

`enforcePlatformSecurity(map[string]any)` 仅调用上述投影，再把应用 Secret 注入内存 map；只允许 preparePlatformConfig 的瞬时解析/内核运行用途，严禁交给 candidate/成功版本、digest/差异预览、错误/日志或验证回执存储。原始订阅的顶层 Controller secret 也不继承到生成配置。候选的完整 Mihomo 校验可以使用不含 Secret 的投影；运行时应用前再由唯一宿主入口瞬时注入，而不是把 Secret 写进“临时”配置文件后再删除。

本分支没有接入或修改 #5 的 configpipeline 文件；配置作者须对 candidate、成功版本与预览添加“应用 Secret 从未落盘”的验收，并在生产适配时选择可持久化投影。Go preparePlatformConfig 内部的 yaml.Marshal 缓冲仅驻留内存，不作为文件/回执输出。

## Controller 关闭完成边界

Controller 使用宿主同步 `net.Listen(tcp4,127.0.0.1:9090)` 和自有 Server 生命周期，停止时使会话代次失效、关闭 HTTP/全部已接受的连接（包含上游 Hijack 的 WS）、等待 Serve 退出，再返回。已升级 WS 使用强制 TCP 终止，避免半关闭后仍能缓冲写入；下一次 start 在同一生命周期锁内先完成前次关闭。排队的 PUT/PATCH 在取得运行锁后再次检查会话代次，旧会话不能在停止后重新应用配置。没有依赖延迟重试或异步 ReCreateServer 来宣称停止完成。

为了保留锁定内核原有 REST/WS 路由、认证和扩展路由，宿主只用 go:linkname 绑定 Mihomo v1.19.32 的私有 router(bool,string,string,route.Cors) 工厂；监听器仍只有宿主这一份。没有复制上游 API 实现、修改模块缓存或增加第二台 HTTP 服务，go.mod/go.sum 与四个 C ABI 不变。这是明确的私有 Go 耦合，不能外推为稳定公开接口；内核升级/候选 Smart 必须核对工厂源码签名、完整链接构建及真实启停回归。本分支未关闭 Go 链接检查。

另外，上游 executor 在 ExternalUI 非空时会尝试 AutoDownloadUI，即便 URL 为空。因此运行态 config.Controller.ExternalUI 明确置空以禁用该 updater，静态根由宿主显式 SetUIPath 管理；这不是 SetUIPath(空字符串)。持久化投影仍标记受控 external-ui=ui，重载从不把它交给 hub.ApplyConfig 重建路由。

## Generic inbound 与日志资源清理

Controller HTTP/WS 的停止不代表代理侧 generic inbound 已停止。coreStop 分别通过 PatchInboundListeners(nil, tunnel, true)、PatchTunnel(nil, tunnel) 和空 TuicServer 移除声明式 inbound/静态转发/顶层 TUIC，再关闭原有固定端口与 DNS；没有把 listener.Cleanup 当成全局清理（锁定实现只关闭自动 TUN）。generic HTTP 的验收是新 TCP 接受/拒绝与端口重新绑定，不是完整代理转发或所有已建立 generic 转发连接都退出的证明。

`/logs` 由宿主可取消 handler 接管，其余 API 继续使用锁定 router。保持 level、普通/structured JSON、REST 流与 WS 认证语义，复用上游导出的日志记录类型和已锁定 coder/websocket。WS 读循环处理 ping/pong 并检测 peer 关闭；会话停止和 peer 关闭均唤醒 silent 级别的等待。handler 的退出先退订并等待持续排空的 relay 结束，再取消/关闭并等待 WS 读循环，最后交付日志资源完成回执；不会等待下一条足够级别的日志才能退订。

停止先对日志 handler 注册加关闭栅栏，再关闭 socket/取消会话，等待这些受控日志 handler 清理完成。**仅等待 Serve 退出不是 handler 清理证明；也不无限等待所有 API handler**，后者可能正在等待 coreStop 持有的运行锁。已排队配置写入仍靠会话代次拒绝。

新增完整 race 检查暴露锁定 Mihomo generic HTTP 的上游同步风险：入站 IP/跳过认证全局切片和默认 authenticator 的读写没有统一同步。停止后的重新监听功能已验证，但这不等于并发安全重启已通过。此风险未在本线通过依赖更换、缓存补丁或测试抑制修复；具体证据见资源清理报告，需要父任务协调依赖层整改。


## 代理默认认证对象的同步

默认代理 AuthStore 通过公开接口在 package init 一次性安装同步委托，之后不换 Default 身份。Get/SetAuthenticator 同步，已有 immutable snapshot、nil 和用户认证语义保留；它与 Controller Bearer Secret 分开。这个 wrapper 改动解决了第四项 authenticator race，不解决 upstream inbound 的三个私有前缀切片读写。产品链、实际双栈与未应用上游提案见 [race 边界报告](../evidence/controller-security/2026-10-12-race-boundary.md)；不得把部分解决当成完整 race 已通过。
