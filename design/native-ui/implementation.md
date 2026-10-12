# ArkTS 实施建议与协作接口

此文件是待实施建议，未改变生产 ArkTS。不要从浏览器模拟推导系统能力。优先按数据契约拆分实现，再替换样式。

## 现有代码映射

| 设计区域 | 基线实际入口 | 实施建议 |
|---|---|---|
| 三页签 | Index.ets | 保留连接/配置/设置，文案「配置」改「订阅」需产品评审 |
| 连接、取消、断开 | HomePage.ets / VpnController | 沿用 start/stop/onChanged/offChanged；按钮受状态约束 |
| 源导入与配置 | ProfilePage.ets / ProfileStore | 保留 importFromUrl/importContent、来源元数据和格式 |
| 覆写 | OverridePage.ets / Settings | 现有只支持少量运行参数；完整策略/Merge 依赖新配置流水线 |
| 恢复偏好 | Settings / AppRuntime | 使用 autoRestore/autoUpdate；显式用户动作先 cancelRestore |
| 页面流量 | CoreApi.StreamWatcher | 可见且就绪时开启，页面消失释放 WS；不释放 AppRuntime 服务 |
| 面板入口 | 临时 ProxyPage | Zashboard 验收后替换入口，不提前删除可用页面 |

实施可拆为 `ConnectionStatusCard`、`ActiveProfileCard`、`ImportSourceSelector`、`ConfigChangePreview`、`RecoveryPreferences`、`HostDiagnostics`，数据从现有服务或未来适配层传入。视图不得拥有 TUN、Go runtime 或后台调度器。使用 Column/Row/Scroll/Button/Text/Toggle 等原生组件；按状态让主操作满宽，窗口安全区域由系统提供。资源按系统浅深色提供同语义 token，页面状态用可观察视图模型，避免把每个演示 scene 转成生产页面。

## 合流时需要的契约（提案，非现有 API）

| 依赖线 | 需要的数据/事件 | 界面行为 |
|---|---|---|
| ① 安全与平台约束 | 同一端口/认证来源，脱敏错误，面板访问上下文 | UI 只得到内部导航句柄，不读取/展示 secret |
| ② 配置事务 | transactionId、候选/有效 revision、覆写摘要、差异、校验结果、应用/回滚状态 | 成功应用才标当前；旧事务完成不可覆盖新事务 |
| ③ 面板 | 资源状态/版本、加载/认证失败类别、关闭事件 | 返回原生，保留 VPN，禁止危险 /restart |
| ⑤ 运行时 | sessionId、粗粒度 VpnStatus、可选真实启动阶段、系统会话确认、Controller 可达、转发健康与时间 | 旧会话事件过滤；未知健康显示待验证 |

错误类型建议含 `category`（配置/授权/资源/启动/网络）、`safeMessage`、`retryable`、`recoveryAction`，并附会话或事务身份；不能直接显示原始内核错误串，可能含 URL/token。转发健康用 unknown/checking/healthy/degraded 与 measuredAt，不能从流量非零或 HTTP 探活推断 healthy。本次没有给这些类型建立生产定义；由接口负责人在各自实现中统一。

配置预览不能只比原 YAML：应展示平台约束后的有效结果类别，隐藏敏感具体值。策略 ID、规则优先级、Smart 与 LightGBM 启用情况按事务结果展示；不由 UI 合成组名，不静默改变选点算法。订阅更新、切换、首次启用必须共享事务。新接口未验收前保留旧 ProfileStore 路径与元数据，不删除沙箱配置。

## 实施顺序与验收

1. 独立接入主题、触区与状态卡，保留现有服务调用。核对系统字号、无障碍焦点与安全区域。
2. 运行时提供真实阶段/会话证据后，添加诊断分层；只有粗粒度证据时使用「连接中」，不得虚构分步进度。
3. 配置事务完成完整校验、失败回退、启动/热重载一致性后，接入覆写选择与差异预览。不得宣称 JS/Shell 兼容。
4. 认证、离线资源、REST/WS、PWA 生命周期验收后接入面板，移除 ProxyPage；原生不再提供运行模式、节点组管理等重复功能。
5. 真机检查授权拒绝、取消与迟到回调、会话重建、网络切换、息屏、面板失败、更新回滚，再决定文案是否可由「内核就绪」升级为带时间的健康状态。

本轮没有 HAP 或真机设计验收结论，没有操作设备 VPN/安全设置，没有发布。总体文档修改由父任务统一；建议仅增加设计评审入口，不改变现有验收门槛。
