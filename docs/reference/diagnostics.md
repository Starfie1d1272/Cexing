# 本地诊断支持包

`DiagnosticsService` 通过既有 `versionAction` NAPI 单 worker 调用 Go 存储，不增加内核 C ABI，不上传。页面用 `check(context, kind, proxy?)` 执行检查，用 `exportBundle(context)` 获取 `{json, path, fileName}`；结果文件在 cacheDir，保存位置选择和分享由页面拥有。导出不执行网络检查，重复导出覆盖同一个缓存文件。

运行时在恢复前调用 `initialize(context)`，并拥有 `observe(context)` 返回的释放函数。观察器只订阅 `VpnController.onChanged/offChanged`，读取脱敏故障、TUN 创建、内核就绪和停止结果 getters，不消费错误、不改变启停。缺少细分阶段时标明覆盖缺口。更精确的业务动作由拥有该动作的模块调用 `record(context, {operation, stage, outcome, object?, reason?, code?, durationMs?})`；只传固定阶段和数字/固定码，禁止传原始异常、Want、URL、配置或凭据。字段词表在 `core/diagnostics_fields.go`；未列入词表的阶段、原因、枚举或错误码记为 unknown，并保存包内关联 identity，不允许通过“符合标识符格式”传任意明文。新增调用者的固定阶段必须补入词表。数值错误码按 32 位范围保存，errno 和定义内 DNS rcode 保留其结构。`record` 返回落盘是否成功，不应改变 VPN 控制结果。

生命周期接入由 `AppRuntime` 初始化并持有状态观察与阶段订阅；Ability 重建先释放旧订阅，迟到的旧 Ability 销毁不能释放新订阅。窗口关闭时 VPN 或未知会话仍存在则继续观察，确认停止后释放。授权、绑定、恢复与停止只提交固定阶段、原始数字码或明确固定码及不透明会话身份；采集异常不能改变控制结果。

`record` 的 host 流只由 UI 进程写入。VPN 扩展的 TUN、进程网络保护、GeoIP、模型、面板资源、配置和内核阶段通过现有私有 IPC 回传有界事件队列，再由 UI 进程提交 `record`，不让两个进程同时写 host journal。队列最多 32 条，截断与 IPC 不可用明确记录 unknown；阶段代码严格白名单，不传异常文本、Want 或配置。记录时间是 UI 接收/落盘时间，耗时来自实际阶段；回传事件是已发生的观察，不证明当前转发。扩展阶段队列不独立持久化，强杀前尚未回传的事件可能缺失；不以重启后的成功补齐缺口。停止后若已有诊断读在途，或本次新发起的快照读在停止返回时仍未完成，不等待日志，明确记录返回时停止快照未取得；代次变化后的响应记录原会话的 superseded 缺口，不能计入新会话。空会话也使用请求时捕获的关联身份。

## 内容与证据解释

JSON schema 为 `cexing-support-bundle/1`。journal 新记录为内部 schema 2。旧 schema 1 可能包含修复前的自由文本，导出时保留时间、阶段、数值/固定码与原因结构，并显式省略自由消息及未批准详情，标记 legacySanitized；不删除或重写原始旧证据。host 和 kernel 两条证据流分开写，避免两个进程互相覆盖。每条记录有会话、递增序号、UTC 时间、动作、阶段、结果和可用的耗时。内核启动明确区分配置解析、Controller 监听、配置应用与 TUN 启动；内核退出仅说明内核清理完成，系统 VPN 停止仍以控制器结果为准。

host 快照保存应用/系统/SDK/ABI 及允许的偏好值，标明“偏好，不是运行时确认”。内核快照是启动/重载的最终平台投影输入，保留有限 DNS 端点协议/端口、同对象关联、节点/组引用、节点类型、安全选项、provider/规则数量和来源层级；不导出 YAML、订阅来源、provider URL、请求正文、访问名单、节点凭据、控制令牌。生成版本的 profile/版本身份、覆写存在、Smart/地区策略元数据单独标记，未读取到元数据则为 unknown。投影输入不证明配置应用或真实转发成功。

额外日志只采集 wrapper 的 warning/error 以及明确的失败拨号、DNS 失败事件；成功流量和一般 Mihomo 浏览日志不采集。原有 `mihomo.log`、系统 hilog、订阅侧车文件不作为附件读取。错误结构保留 Go 类型、可提取的原始 errno、有限原因链和脱敏技术错误；纯文本错误没有可证明的数字码时不猜码。日志正文、URL、地址、路径、已知节点名及凭据在持久化前脱敏；名称/端点用私有安装密钥 HMAC 关联，导出再随机加盐，同包保持关联，不导出任何密钥。原因链和消息裁剪有标记。内存脱敏表在进程内单调合并运行配置、全部候选及历史配置的值，失败候选不会移除当前值，成功更换后的旧事件仍受保护；日志读取与表更新同步。最多保留 16384 个值或 8 MiB 映射，不为腾空间淘汰旧值，满额后明确省略自由消息正文；阶段、错误类型、实际 errno、原因链及固定错误条件仍保留。表和候选正文均不落盘。环境、偏好、观察值、配置类型和 DNS 协议采用字段专用白名单/数值范围，未知值只保存关联 identity。

`checkCoverage` 标明已保留的检查证据；没有保留结果意味着 unknown，不能断言从未执行。host/kernel 会话互相独立，时间与对象关联不能单独证明是同一系统 TUN。当前 getters 尚不能提供授权、服务绑定、保护及资源铺盘的全部子阶段，观察器明确标出缺口。

## 检查与流量范围

检查只在用户明确执行时联网。Controller 检查保留凭据缺失、授权拒绝、HTTP 码和平台传输码。认证 `POST /ohos/diagnostics/check` 接口限制固定 kind 和代理名、单个并发探针、8 秒截止；不接受 URL、正文或任意目标。

- DNS：通过配置的核心 resolver 对 `example.com` 执行一个 A 查询，保存 rcode、答案数量、截断标志与耗时，不导出解析地址。缓存命中可能不触发外部查询；结果不证明系统 TUN 的 DNS 劫持正常。
- connection/delay：选定代理适配器向固定 gstatic HTTPS 204 目标拨号，区分代理拨号、TLS 握手和 HTTP 状态，发送一次 HEAD，不读响应正文。提供总耗时和子阶段耗时，不称为带宽测试，也不证明设备浏览器经 TUN 转发成功。未选代理或内核未就绪有明确跳过原因；不自动替用户选 DIRECT。
- bandwidth：本服务不执行，记录需要独立显式带宽操作的原因。支持包不得擅自启动大流量测速。

## 持久化、轮转与限制

每进程首次写入时轮转所属流：current、previous、older 三个会话；同进程多次连接不轮转。每个 journal 最多 256 条和 192 KiB，超限丢弃最早事件并增加 dropped。写入使用 0600 临时文件、文件 sync、原子 rename 和目录 sync；证据目录 0700。应用重启后的空 current 不替代 previous/older。每流总量不超过约 576 KiB，另有 32 字节私有关联密钥；普通 logToFile 开关不控制这份有限、已脱敏的故障证据。

导出最多 1 MiB，必要时从较早来源逐条省略并增加 `exportOmitted`，不修改落盘证据；每个来源区分 available、missing、unreadable、invalid，保留 dropped、writeFailures、实时未落盘计数和会话时间。失败日志限每秒 8 条，logSuppressed 在下一次写入保存；强杀前最后一秒的抑制计数可能无法落盘，包内策略明确该缺口。文件过大、损坏或不存在不等于健康。进程被杀于首次尚未落盘的动作、磁盘不可写或安装本能力之前的日志不能恢复；这类缺失不能拿重启后的成功状态填补。

未接入调用者的 ArkTS 服务不会进入 HAP；Full 成功不能证明该文件已通过官方编译。接入方必须验证服务实际进入模块，独立服务验证可在隔离副本临时引用 initialize 并编译；这类产物属于验证 fixture，不作为交付包或真机证据。

云端 fixture 验证重启、关联脱敏、失败阶段、DNS rcode、错误原因、权限码、容量和写入失败；不能代替真机 VPN、真实 DNS/TLS/转发、系统文件选择器和后台死亡验收。可定位常见问题的覆盖率是后续数据验证目标，没有 99% 已达成声明。

## 参考设计

只读核对 [Mizar 支持包](https://github.com/Starfie1d1272/Mizar/blob/c5a2633d15e0d7efd0c5d4ca1bf71ff8932c7dd8/apps/companion/src/support/routes.ts) 的分源状态、原始错误码、原因链与显式省略，[Mizar 日志契约](https://github.com/Starfie1d1272/Mizar/blob/c5a2633d15e0d7efd0c5d4ca1bf71ff8932c7dd8/apps/companion/src/support/logs.ts) 的有界字段与包内身份关联；保留跨重启会话，避免只依赖当前快照和短尾摘要。内核接口按仓库锁定 Mihomo 的 resolver/adapter 生命周期使用，没有复制参考项目源码、添加依赖或执行其程序。
