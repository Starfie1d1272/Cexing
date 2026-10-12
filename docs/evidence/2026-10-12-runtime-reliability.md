# 运行时可靠性审查与验证（2026-10-12）

基线：`main` 的 `7f731d5c9c8d4eba7a1680bcb3981d7877232bcc`（PR #1 merge）；分支：`fix/runtime-reliability`。已阅读 AGENTS、architecture、development、platform、build/device 指南和 [PR #1 的复审及修复](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/1)。仓库无 `.agents/skills`，环境 `.agents` 为空。

## 改动与接口契约

- `AppRuntime.abilityDestroyed(ctx)` 只取消当前绑定 Ability 的待恢复动作。EntryAbility 销毁走这个入口，旧 Ability 的迟到销毁不会撤销新 Ability 的恢复。`cancelRestore()` 保留供显式用户启停调用；页面销毁仍不停止 VPN/后台服务。
- LiveViewKeeper 的 native start/stop/cancel 保留串行队列；停止立即使任务工作代次失效。启动途中取得的旧任务身份仍交给排队 stop 清理，不发布或创建旧定时器。定时回调捕获所属代次，流量/测速/元数据各 await 后校验，防止迟到结果写入新任务。
- 通知 publish/cancel 使用独立串行队列；已提交 publish 完成后才 cancel，迟到读取不再提交 publish。无法撤销已提交的 native Promise；系统 Promise 若长期不落定，该通知清理队列仍会等待，未用猜测超时绕过它。
- 监听按本模块的 callback 解绑，部分注册失败走失败清理；各 off 独立尝试。未取得 native 任务身份的 WantAgent/start 失败不调用无 ID 的全局 stop。foreground ensure 可重试任务申请失败；用户划掉通知后 ensure 不自动重建，显式断开/重新连接是重试路径。
- 系统取消的重申请计时器可清除，探活前捕获生命周期代次；停止/新 start 使迟到探活和已排队重申请失效。用户取消标记在异步清理前设定。
- AutoUpdater 的 stop/Context 更换使在途检查失效；同一时刻只保留一个检查，失败后释放门闩。下载完成和重载前重新检查代次、开关和激活文件，避免旧更新重载新连接；后续 tick 使用重绑定的 Context。

**跨任务边界**：`ProfileStore.updateFromOrigin()` 已在内部写文件，当前接口不能取消下载或阻止其迟到写入。此 PR 只阻止旧检查后续时间戳和 Core 重载，不声称提供配置事务；下载取消、原子文件提交及手动更新互斥须由配置流水线负责。已提交 `CoreApi.reloadConfig()` 也无法在本模块撤销。

**VPN 状态机阻塞**：`VpnController.recover()`（基线 130–146 行）在探活完成后只检查 Disconnected，随后内部设置 Connected；用户在探活期间启动/取消并回到 Disconnected 时，旧探活可改变状态，早于 AppRuntime 的完成回调代次检查。需要 VPN 状态机负责人以会话/意图代次保护 recover 的内部提交。本任务未改 VpnController/CoreApi/ClashVpnAbility/engine；Controller 可达仍不证明系统 TUN 健康。

## API26 官方声明核查

使用已安装的华为 Command Line Tools `26.0.0.851 Release`，SDK 标识 `HarmonyOS 26.0.0 Release / Ohos_sdk_public 26.0.0.105 / API26`。这是 SDK 声明证据，未获得 HarmonyOS 7 真机运行证据。官方网站 BackgroundTaskManager、continuous-task、restricted-permissions 页面本轮抓取超时，没有把网页全文写成已核验；可从[官方文档入口](https://developer.huawei.com/consumer/cn/doc/)和[官方下载](https://developer.huawei.com/consumer/cn/download/)复查。

| 核查对象 | 官方 SDK 事实来源（相对 SDK 根） | 核查结论与边界 |
|---|---|---|
| dataTransfer / Live View | `openharmony/ets/api/@ohos.resourceschedule.backgroundTaskManager.d.ts` 的 BackgroundTaskMode、BackgroundTaskSubmode、ContinuousTaskRequest | MODE_DATA_TRANSFER=1、SUBMODE_LIVE_VIEW_NOTIFICATION=3；request/main/submode 从 API21 起。声明要求进度更新采用 Live View，超过十分钟未更新进度可取消；不能推导每分钟 publish 或五分钟测速保证永久保活。 |
| cancel 事件 | 同文件 ContinuousTaskCancelInfo / ContinuousTaskDetailedCancelReason / on/off | 事件任务身份是 `id`；`detailedReason` 可选且详细枚举从 API26 起。详细用户移除=3、低速=4、进度未更新=12；实现保留详细枚举不存在时的兼容分支。off 支持指定 callback。 |
| taskKeeping / ACL | 同文件 BackgroundMode.TASK_KEEPING / BackgroundTaskMode.MODE_TASK_KEEPING；`openharmony/toolchains/configcheck/configSchema_rich.json` backgroundModes | schema 接受 taskKeeping 只证明配置可声明。SDK 从 API21 起允许非 PC/2-in-1 设备在取得 `ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM` ACL 后使用；普通 KEEP_BACKGROUND_RUNNING 不等价于此 ACL。未申请 ACL、未检查私有签名材料、未将应用改成 taskKeeping。 |
| 当前 manifest | `entry/src/main/module.json5` | EntryAbility 仅声明 dataTransfer，并请求普通 KEEP_BACKGROUND_RUNNING；声明、安装/签名获权和真机长时运行是不同证据。 |

本轮 build 仍有继承的弃用与 API26 / compatible API21 警告；枚举判空不意味着所有低版本接口已可用。未提高兼容版本或擅改权限。

## 实际验证

Linux 云端，Node `26.11.1`、Go `1.27.2`、JDK `27`，官方 SDK 编译器；没有签名、安装、设备 VPN 或系统安全设置操作。

1. 四个现有脚本均通过：11 项 profile name、VPN readiness/error/cancel/extension、AppRuntime ownership/recovery/Ability、background lifecycle。新增检查执行真实 ArkTS 服务经 SDK TypeScript 转译的代码，平台边界用 mock 和 deferred Promise；不等同于设备结果。
2. background lifecycle 共 12 个风险场景；在 `/tmp` 导出固定基线服务源码并运行相同测试，以下 8 项在基线失败、修复后通过：旧流量/已排队旧 tick、旧测速、分配任务前失败却全局 stop、在途 publish 后 cancel 顺序、部分监听注册失败、取消探活迟到重申请、停止后旧订阅重载、重复下载。另验证快速 native start→stop→start、旧 cancel ID、新 Context 的 tick/heartbeat、用户取消清理期间 foreground 不重申请、失败后可重试和激活配置/偏好变化。
3. 原有环境内核摘要与历史证据不一致，未将其当作固定基线产物；按本分支未修改的 `core/go.mod/go.sum` 重编译内核。123 个 Go build metadata 依赖与 `go list -m all` 一致；完整性检查只临时还原仓库确切 gVisor Fstat 补丁后执行 `go mod verify`，通过并恢复补丁。
4. native 产物变化后执行 `hvigorw clean --no-daemon`，未签名 HAP 构建通过（33 tasks，32 executed，1 up-to-date）。HAP ZIP CRC 通过，三个 ELF 均为 ARM64，默认配置/GeoIP 资源存在且 GeoIP 与锁定值一致。产物全部忽略，不入库。
5. `git diff --check` 通过；应用名、包名、仓库名及共享 README/AGENTS/development 保持原样。

| 产物 | SHA-256 |
|---|---|
| 重编译未 strip 的 libmihomo.so | `d2ada34bc20afc9a013e0182d8ed0bdce338b4dd83b5e43c42cd6a8ddd07411c` |
| HAP 包内 libmihomo.so | `b021bb60317ba469c29b3bb66505807e1ef0e5ca39826f659cc2d62efe2a8b35` |
| 未签名 HAP | `05f19eb3a5d965a9a411f3d297ee8a4cb3d78361b6c8917fb9c116b976e14bda` |

## 待执行真机矩阵

所有行均 **未执行**。由获授权设备人员完成，不自动修改设备设置。每次记录源码 SHA、HAP 摘要、设备/系统/API、通知权限/ACL 条件、脱敏配置及时间戳；成功要求系统隧道和真实双向 TUN 流量，不能只用 Connected 或 `/version`。

| 场景 | 操作条件 | 观察与通过条件 |
|---|---|---|
| 低流量息屏 15 分钟 | 普通 dataTransfer，通知可用；前台连接后低流量息屏 | 记录每次 publish、系统取消原因/id、重申请次数；唤醒后查系统 VPN 与真实请求。允许系统取消被准确记录，不把自动重申请当作保活保证。 |
| 低流量息屏 30 分钟 | 同条件延长至 30 分钟；另测有真实业务流量 | 检查是否被回收、时间戳/任务 ID、取消后限流和前台重试；对比有无业务流量，避免测速产生流量掩盖低流量行为。 |
| 用户划掉实况窗 | 连接时用户明确取消；清理期间及之后回前台 | 不自动重申请、不自动 VPN 重连；随后显式断开/重新连接可恢复任务。 |
| Wi-Fi↔蜂窝 / 暂时无网 | 活跃流量与低流量各一轮 | 真实新请求、DNS/UDP、任务/扩展身份与错误路径；不出现旧测速覆盖新会话或旧配置重载。 |
| 启动/取消/快速重连 | 授权/启动中取消、连接失败，随后立即重新连接 | 用户取消无自动恢复；旧 native start/stop/cancel 不释放新任务；失败可显式重试，检查通知/监听/定时器数量。 |
| 页面关闭与 Ability 重建 | 关闭页面后继续真实转发，再重建 UIAbility | 页面销毁不停止 VPN；新 tick/heartbeat 使用当前 Context；旧 Ability 迟到销毁不取消新恢复。 |
| UI 进程回收 / 扩展回收 | 用户在可授权实验条件下触发或等待回收 | 区分 UI 与扩展回收；核对系统 TUN 和 Controller，不因 Controller 独活误报健康；旧 recover 竞态修复合流后才验收取消后不恢复。 |
| 后台申请失败 / 通知受限 | 用户操作受支持的通知授权；记录系统拒绝码 | 不重复监听、无无 ID 全局 stop；前台 ensure/显式重连可再尝试；未获 ACL 时不使用 taskKeeping。 |

合流建议：在 architecture 的生命周期参考中补充“恢复提交由 VPN 状态机校验意图代次”和“订阅下载与运行时取消的事务边界”；由父任务统筹共享文档。此 PR 可审阅代码修复，但不能据此认定系统会话恢复、长期后台或日用稳定性已通过。
