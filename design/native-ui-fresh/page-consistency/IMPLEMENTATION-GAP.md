# 视觉基准与实现差距

视觉基准已选 `0974f9dd021130fe2b17554af773db554d05ddb5`。当前 main 远端核对为 `7f731d5c9c8d4eba7a1680bcb3981d7877232bcc`，尚未纳入独立技术 PR。以下状态来自本轮只读源码检查及 GitHub PR 描述／checks 查询，技术线的自报测试不当作本设计任务重新执行的验证。Ready 只表示可审查；GitHub mergeState=CLEAN 不表示无功能阻塞。

## 原型与 main

| 界面／任务 | main 已有源码能力 | 原型与正式接入的距离 |
| --- | --- | --- |
| URL／文件／剪贴板导入与更新 | ProfileStore、原生 ProfilePage 已有导入、私有存储、来源更新、激活元数据 | 原型只用内存合成数据；文件选择读取文本是真浏览器交互，未连接 ProfileStore。main validateConfig 仅做长度／关键字段字符串检查，不是完整内核校验 |
| 覆写／确认／差异 | 原生 OverridePage 是端口、日志等级、LAN 等参数设置 | Merge、策略编译、更新重应用与事务回退未接入生产；原型 Merge 编辑／差异仅草稿演示 |
| VPN 授权／连接／断开 | VpnController 调用系统 VPN Extension；ClashVpnAbility 创建 TUN、启动内核；AppRuntime 管恢复与后台服务 | 原型弹窗不是真 OS 授权；连接／断开为1500／700ms合成状态，不能证明设备转发或后台稳定 |
| 实时状态／流量 | CoreApi 有 REST 流量、StreamWatcher 与状态监听 | 原型数字是合成样例，未对接认证后的 REST／WS；系统会话、内核就绪、真实网络健康须分别验收 |
| Zashboard 交接 | main 仍保留临时 ProxyPage，无完成的 ArkWeb 面板接入 | 原型为明确的接入占位／失败路径；节点、组、Smart、规则和日志目标归面板，尚不能点开真实面板 |
| 网络／内核设置、自动更新 | 当前原生页与 AppRuntime／AutoUpdater 有相应设置、调度、恢复路径 | 原型仅演示内存状态；更改生效时机、持久化、切网和生命周期需原生接入后验证 |
| 诊断与恢复 | main 有内核探活、状态、启动错误等基础信息 | 原型分层诊断、分享摘要、错误恢复为目标交互；尚无真实转发验证、脱敏摘要及设备验收 |
| 原生视觉实现 | 现有 ArkTS 页面和系统 VPN 通路存在 | 当前交付为 HTML/CSS/JS；新主卡、统一页签、视觉材质未迁移至 ArkTS。浏览器可用性不是 HAP／真机验收 |

源码依据：[ProfileStore](../../../clash-openharmony/entry/src/main/ets/lib/ProfileStore.ets)、[VpnController](../../../clash-openharmony/entry/src/main/ets/lib/VpnController.ets)、[ClashVpnAbility](../../../clash-openharmony/entry/src/main/ets/vpnability/ClashVpnAbility.ets)、[CoreApi](../../../clash-openharmony/entry/src/main/ets/lib/CoreApi.ets)、[AppRuntime](../../../clash-openharmony/entry/src/main/ets/lib/AppRuntime.ets)、[OverridePage](../../../clash-openharmony/entry/src/main/ets/pages/OverridePage.ets)。

## 其他技术线当前快照

| 线／PR | 核对 head | 已报告进展 | 尚待完成／阻塞 |
| --- | --- | --- | --- |
| [运行时 #4](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/4) | c1db85075992a6df0b00cd57c928e879bd6bfe50 | 迟到调度／回调、后台资源清理、独立回归与 HAP；恢复合流补丁已准备 | 最终组合 HAP、真机息屏／切网／回收；已提交文件 IO 的撤销由配置事务接管 |
| [配置流水线 #5](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/5) | e7798387a9ab1a9baf89209f715c9977047f0b0f | 独立 configpipeline、明确 Merge 语义、校验／激活回调与回退；race／vet 等自报通过 | 生产入口未接入；安全投影、ProfileStore 写入门控、完整兼容矩阵和设备联调未完成 |
| [Smart #7](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/7) | 182f7af5e750bff1954f6cc56fa2d986940a3656 | 独立固定核心实验、禁模型下载、HAP 身份门禁；构建／篡改回归自报通过 | 生产未换核；模型许可、合法模型加载、实际预测与真机流量链未验证 |
| [CI #8](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/8) | d3255402b756c4d6a2cecf84eeb8c2f306255293 | GitHub Quick checks 实际 SUCCESS；本地官方 SDK Full 自报通过 | 自托管 Full 未调度；签名、设备验证、分发批准不包含在内 |
| [安全 #9](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/9) | 1b23e76297d51212b250da85b7375dd7fdab1c1b | Controller／认证／停止资源清理、部分 race 修复与独立 HAP | **完整 race 未通过**：上游 resolver／hosts／IPv6、前缀与解析 live 状态等问题待独立依赖维护；不能视为并发安全完成 |
| [Zashboard #10](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/10) | 86df6179a7be894a719917f267a20f085c5e915e | 锁定离线资源、ArkWeb 隔离页、资源恢复／摘要与 HAP 自报通过 | 入口仍关闭；内存凭据、WS 适配、精确 CSP、认证成功／拒绝与重载跨线验收未完成 |

查询时以上均为 OPEN、Ready，未合并。除 #8 Quick 外，查询的 statusCheckRollup 为空；空列表不代表本地测试失败或通过。未阅读或继续旧设计 PR #6 的内容。

## 建议接入次序

先处理安全线完整 race 阻塞与恢复取消接点；然后统一配置持久投影／更新事务，完成认证后的 Zashboard REST/WS 接入。用这套真实状态接入已选首页和工具页，再做系统授权、流量、切网、后台／折叠设备验收。Smart 维持独立能力门禁；没有模型与预测证据前不在首页增加“Smart 已启用”承诺。

本轮只读这些技术线，不修改其分支、不做合流、不构建或安装技术线 HAP。
