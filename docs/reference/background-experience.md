# 后台保障与反馈契约

`LiveViewKeeper` 在已有串行任务生命周期中维护 `BackgroundState`，不修改 `VpnController.status`。`task` 是本进程拥有任务的观测：unknown、disabled、requesting、active、failed、revoked、user-stopped；`notification` 独立为 unknown、ready、failed。`suspended` 表示收到匹配当前任务的暂停事件。active 不保证 VPN 数据路径、息屏存活或未来不被系统撤销；notification ready 只表示本次发布成功。

`AppRuntime.backgroundState()` 返回快照；`onBackgroundChanged(listener)` 返回解绑函数；页面销毁只解绑观察者。`retryBackground()` 仅在当前进程上下文、VPN Connected 且持久设置 keepAlive 已开启时调用现有任务重试，不开启偏好、不重启 VPN。实况窗失败时复用已取得的任务重新发布；用户主动划掉任务后，foreground ensure 不自动恢复，只有显式重试或重新连接恢复。

`BackgroundNotice` 仅在 Connected 且任务申请失败/系统撤销/暂停或实况窗发布失败时显示一句短反馈和重试、设置。未知初始状态、申请中、健康、关闭偏好及用户取消不显示故障。用于首页时传入 `status` 和 `visible: rootVisible && currentVisibleTab === 0`；放在可滚动操作区中，不能挤占底部连接按钮。首页和诊断页已接线，不复制反馈状态或重试接口。

任务申请、取消、暂停/恢复和异步通知以当前任务身份及代次过滤。关闭偏好或断开期间迟到的授权结果只清理任务，不发出新成功；重复点击不会同时申请两份任务。日志保留错误细节，默认界面不展示平台错误原文。

依据：[OpenHarmony backgroundTaskManager 官方接口](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-backgroundtasks-kit/js-apis-resourceschedule-backgroundTaskManager.md)。仅借鉴 API 契约，无复制外部实现。长时间息屏、低流量转发与系统撤销后的真实设备行为按 [#92](https://github.com/Starfie1d1272/Cexing/issues/92) 验收。

## 实况窗显示策略

实况窗仅标 `显示策略 <组名>`，不会沿 Selector.now 推断全局出口，也不把 REJECT 当直连。显示组可在诊断的按需详情中选择；编辑与取消没有写入，明确应用后只保存现有 `Settings.mainGroup`。此编辑依赖 #126 的持久保存/异常报告契约，不另建偏好或发布系统。显示组失效或 Controller 无法读取时省略名称；默认仅临时选首个可展示组，不在后台自动写回偏好。

5 分钟探测对该显示组调用现有 GET /proxies/{name}/delay；实况窗短标为 `探测 N ms`，不归因到叶节点或网站。探测失败、显示组改变、Controller 失联均清除旧结果；缓存最多保留一个探测周期。后台刷新从不 PUT 选择组或切换模式。

API 依据：[Mihomo 官方控制面接口](https://wiki.metacubex.one/api/#proxiesproxies_namedelay)。Zashboard 固定版本仅用于核对 Smart 与组展示边界：[smart.ts](https://github.com/Zephyruso/zashboard/blob/50717b02dac68425cdc5b80cb754bea768ee4fc9/src/assembly/proxies/smart.ts)；本实现不复制外部代码或模板。
