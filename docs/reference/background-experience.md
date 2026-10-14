# 后台保障与反馈契约

`LiveViewKeeper` 在已有串行任务生命周期中维护 `BackgroundState`，不修改 `VpnController.status`。`task` 是本进程拥有任务的观测：unknown、disabled、requesting、active、failed、revoked、user-stopped；`notification` 独立为 unknown、ready、failed。`suspended` 表示收到匹配当前任务的暂停事件。active 不保证 VPN 数据路径、息屏存活或未来不被系统撤销；notification ready 只表示本次发布成功。

`AppRuntime.backgroundState()` 返回快照；`onBackgroundChanged(listener)` 返回解绑函数；页面销毁只解绑观察者。`retryBackground()` 仅在当前进程上下文、VPN Connected 且持久设置 keepAlive 已开启时调用现有任务重试，不开启偏好、不重启 VPN。实况窗失败时复用已取得的任务重新发布；用户主动划掉任务后，foreground ensure 不自动恢复，只有显式重试或重新连接恢复。

`BackgroundNotice` 仅在 Connected 且任务申请失败/系统撤销/暂停或实况窗发布失败时显示一句短反馈和重试、设置。未知初始状态、申请中、健康、关闭偏好及用户取消不显示故障。用于首页时传入 `status` 和 `visible: rootVisible && currentVisibleTab === 0`；放在可滚动操作区中，不能挤占底部连接按钮。诊断页已接线。首页由对应页面所有者加 `import { BackgroundNotice } from './BackgroundNotice'` 与 `BackgroundNotice({ status: this.status, visible: this.rootVisible && this.currentVisibleTab === 0 })`，不复制反馈状态或重试接口。

任务申请、取消、暂停/恢复和异步通知以当前任务身份及代次过滤。关闭偏好或断开期间迟到的授权结果只清理任务，不发出新成功；重复点击不会同时申请两份任务。日志保留错误细节，默认界面不展示平台错误原文。

依据：[OpenHarmony backgroundTaskManager 官方接口](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-backgroundtasks-kit/js-apis-resourceschedule-backgroundTaskManager.md)。仅借鉴 API 契约，无复制外部实现。长时间息屏、低流量转发与系统撤销后的真实设备行为按 [#92](https://github.com/Starfie1d1272/Cexing/issues/92) 验收。
