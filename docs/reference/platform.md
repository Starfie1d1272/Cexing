# 平台参考

## ABI 与线程

`core/main.go` 导出 `mihomoInit`、`mihomoStartTun`、`mihomoStop`、`mihomoFree`。以声明和生成头文件为接口事实来源；升级检查四个符号、参数和返回串释放约定。

鸿蒙 musl 的主线程 TLS 与 pthread 不同。Go c-shared 调用必须通过 `cpp/bridge.cpp` 单 worker 串行化，NAPI 用 async work，不在主线程直调，不 `dlclose` Go runtime。停止函数只停止业务监听及 TUN。

系统创建 TUN fd，C++ 复制给 Go 使用；停止/失败分别回收各自所有权。扩展启动在初始化中取消时仍需回收迟到启动。listener 部分开启后失败的完整清理要独立覆盖。

## 构建适配

- `netgo` 避免 musl/cgo DNS 类型冲突；`ohos` 选择平台实现；`cmfa` 避免 Android PackageManager/binder 路径；`with_gvisor` 包含所需栈。
- Android 日志头和空 `liblog.a` 由脚本生成，映射到 OHOS hilog。
- gVisor 对 VPN fd 的 Fstat 在沙箱可能返回 EPERM。`patch-gvisor-tun-fd.sh` 使其回退非 socket 的 readv 路径；补丁匹配失败应停止构建。升级核对上游 endpoint 和补丁，不泛化到其他 fd。
- Android embed 模式限制配置写 API；wrapper 在初始化时关闭该模式，必须在 Controller 构造前完成。

## 配置与网络

平台层提供 Controller、非特权 DNS 监听、进程查找及嗅探默认值，禁用 Mihomo 自动建 TUN，系统 fd 的栈强制 gVisor。默认值只填缺省，**尚不是不可覆盖的安全约束**。

`VpnController` 设置 IPv4 地址、默认路由、HTTPDNS 地址/网段排除和应用名单；应用自身排除。Go 与系统 MTU 必须一致。排除网段意味着并非所有流量都进入代理。

IPv6 开关与默认路由不等于完整双栈实现；系统和 Go 的 IPv6 地址、DNS 和真实出口必须一致验证。Controller 可达不等于系统 VPN 健康。后台 dataTransfer 的可用性由系统、通知及签名权限共同决定，源码存在不证明长时间保活。

## 禁用与诊断边界

Mihomo `/restart` 使用进程 exec 语义，不适合鸿蒙扩展宿主；原生客户端不调用该端点，Web 面板接入时也须限制。需要重启应经原生 VPN 生命周期；配置应用遵循 [配置契约](configuration.md)。

不要通过 HDC 写应用沙箱或以平台权限假设替代验证。`/version` 可能是上游默认值，发行身份需由模块元数据、源码及包内库摘要共同确认，正式发行再实现版本注入。
