# 平台参考

## ABI 与线程

`core/main.go` 导出 `mihomoInit`、`mihomoStartTun`、`mihomoStop`、`mihomoFree`。以声明和生成头文件为接口事实来源；升级检查四个符号、参数和返回串释放约定。

鸿蒙 musl 的主线程 TLS 与 pthread 不同。Go c-shared 调用必须通过 `cpp/bridge.cpp` 单 worker 串行化，NAPI 用 async work，不在主线程直调，不 `dlclose` Go runtime。停止函数只停止业务监听及 TUN。

系统创建 TUN fd，C++ 复制给 Go 使用；停止/失败分别回收各自所有权。扩展启动在初始化中取消时仍需回收迟到启动。listener 部分开启后失败的完整清理要独立覆盖。

### 私有 Controller router 升级契约

当前模块图将 `github.com/metacubex/mihomo` 替换为 Smart fork
`github.com/vernesong/mihomo` 的 `daf3ad03021cca6031f4a7303ca6d861a14d5a16`。
`controller_listener.go` 通过 `go:linkname` 绑定未导出的
`router(bool, string, string, route.Cors) *chi.Mux`，由宿主拥有唯一的 Controller
listener、HTTP 连接和升级后的 WS。没有复制上游路由实现。

`scripts/ci/check-controller-contract.py` 在 Smart 补丁应用后、编译前核对模块路径、
版本、模块摘要、完整 `hub/route/server.go` 源码（只允许已审查的 Smart 插入）及
wrapper 声明。Quick/Full 的 `test-smart.sh` 和 `build-core.sh` 均调用此门禁；
版本、私有签名、Cors 布局或补丁漂移会阻断。升级需重新审查并更新契约，不能只改版本锁。
`test-controller-contract.py` 用真实固定源码的变异验证拒绝路径；
`TestControllerSecurity` 使用真实路由验证 REST/WS 认证、停止回收、端口重绑和旧会话隔离。
生成头文件与包内 ABI 仍由 Full 检查。这些结果不替代 #92 的真机验收。

依据：[Go 编译器的 linkname 约束](https://pkg.go.dev/cmd/compile#hdr-Compiler_Directives)、
[固定上游路由源码](https://github.com/vernesong/mihomo/blob/daf3ad03021cca6031f4a7303ca6d861a14d5a16/hub/route/server.go)。

## 构建适配

- `netgo` 避免 musl/cgo DNS 类型冲突；`ohos` 选择平台实现；`cmfa` 避免 Android PackageManager/binder 路径；`with_gvisor` 包含所需栈。
- Android 日志头和空 `liblog.a` 由脚本生成，映射到 OHOS hilog。
- gVisor 对 VPN fd 的 Fstat 在沙箱可能返回 EPERM。构建脚本通过 `scripts/ci/patch-gvisor.py` 在专用临时模块缓存中使其回退非 socket 的 readv 路径；补丁匹配失败应停止构建。旧 `patch-gvisor-tun-fd.sh` 仅保留供历史手动环境参考，正常构建和 CI 不再调用它。升级核对上游 endpoint 和补丁，不泛化到其他 fd。
- Android embed 模式限制配置写 API；wrapper 在初始化时关闭该模式，必须在 Controller 构造前完成。

## 配置与网络

平台层提供 Controller、非特权 DNS 监听、进程查找及嗅探默认值，禁用 Mihomo 自动建 TUN，系统 fd 的栈强制 gVisor。默认值只填缺省，**尚不是不可覆盖的安全约束**。

`VpnController` 设置 IPv4 地址、默认路由、HTTPDNS 地址/网段排除和应用名单；应用自身排除。Go 与系统 MTU 必须一致。排除网段意味着并非所有流量都进入代理。

IPv6 开关与默认路由不等于完整双栈实现；系统和 Go 的 IPv6 地址、DNS 和真实出口必须一致验证。Controller 可达不等于系统 VPN 健康。后台 dataTransfer 的可用性由系统、通知及签名权限共同决定，源码存在不证明长时间保活。

## 禁用与诊断边界

Mihomo `/restart` 使用进程 exec 语义，不适合鸿蒙扩展宿主；原生客户端不调用该端点，Web 面板接入时也须限制。需要重启应经原生 VPN 生命周期；配置应用遵循 [配置契约](configuration.md)。

不要通过 HDC 写应用沙箱或以平台权限假设替代验证。`/version` 可能是上游默认值，发行身份需由模块元数据、源码及包内库摘要共同确认，正式发行再实现版本注入。

## 桌面连接入口

`ConnectionFormAbility` 通过公开 `FormExtensionAbility` 的创建、更新、移除回调登记卡片 ID，使用 `formProvider.updateForm` 同步运行时核对的状态。卡片扩展不持有 VPN、后台任务或恢复定时器。卡片保留运行时发布的状态与数值时间戳；一分钟内显示已核实状态，超过一分钟以“上次状态”标明历史结论。卡片使用公开 `TextClock.onDateChange` 核对新鲜度，按平台卡片的分钟回调节奏更新。未确认停止显示“断开未完成”，保留重试断开保护；冷进程不自动清除此保护。

1×2 卡片以状态和单个操作并排显示，根容器铺满主题背景、由桌面处理外轮廓，避免自绘圆角暴露底层背景；文字与按钮复用应用深浅色资源。未连接时连接，已连接或连接中时断开，断开中禁用操作。桌面长按菜单通过 API 20 的 `shortcutManager.setShortcutVisibleForSelf` 同步同一连接意图，先隐藏另一项再显示当前项；异步调用串行处理最新状态，避免迟到回调恢复旧入口。静态配置默认只显示连接。显示控制遵循官方 [shortcutManager](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-ability-kit/js-apis-shortcutManager.md)，背景叠层问题参考[圆角边框说明](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-arkui-1083)。

卡片的 `postCardAction(router)` 和图标的 `ohos.ability.shortcuts` 都进入 singleton `EntryAbility`。前者的 JSON 数据位于 `Want.parameters.params`，后者直接位于 `Want.parameters`；冷启动由 `onCreate` 接收，已有实例由 `onNewWant` 接收。`ConnectionEntry` 仅接受显式 connect/disconnect 请求，运行时恢复后直接执行一次。异步配置准备后重新核对最新请求、上下文、当前订阅、配置事务占用及未知标记；重复请求保持对应连接意图，断开意图能取消在途准备或启动。连接和断开仍由 `VpnController` 执行，连接保留系统正常授权流程。可分别移除 form 扩展注册或 shortcuts metadata 停用对应桌面入口。

注册依据 [华为模块配置](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/module-configuration-file)、[卡片配置](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-ui-widget-configuration)、[router 事件](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-ui-widget-event-router)与官方 SDK 的 `modulecheck/forms.json`、`shortcuts.json`、`FormExtensionAbility`/`UIAbility`/`postCardAction` 声明。上游公开的[模块配置](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/quick-start/module-configuration-file.md)和[router 事件](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/form/arkts-ui-widget-event-router.md)说明同一注册与 Want 数据契约。普通应用不依赖系统专用的 `onChangeFormVisibility` 回调，也不注册控制中心 tile。
