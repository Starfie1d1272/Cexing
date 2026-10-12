# HarmonyOS VPN 与可靠性

日期：2026-10-12。记录源码审查和本项目首轮真机证据；各项验收范围单独标注。

## 平台边界 [源码确认]

`ClashVpnAbility.onConnect()` 同步返回启动状态 IPC 对象，后台建 TUN、`protectProcessNet()`、准备 GeoIP 再进入 NAPI。前端收到内核就绪才显示已连接。C++ worker 的线程约束与 gVisor fd 补丁是现有平台适配；本轮构建保留它们。`onDisconnect()` 发起清理，先 destroy 系统 VPN，再等待启动任务并停内核；`onDestroy()` 调用相同清理。启动中取消与重新启动通过 mock 回归，正常停止/重连通过真机；异常销毁、fd 复用与 listener 部分启动后失败仍需专门验证。

`LiveViewKeeper` 在 UIAbility 上下文使用 dataTransfer + 实况窗子模式，并订阅取消/挂起/恢复事件，有重申请预算。module 只声明 KEEP_BACKGROUND_RUNNING，未声明 taskKeeping 的系统 ACL。原生首页持有保活与自动更新调用入口；未来精简 UI 时需保留生命周期 owner。

[Bettbox 审查记录](https://github.com/htoay/Bettbox/blob/11ed6def314a7412c5d863d48c4453bfcfe6ae8a/docs/harmonyos_audit_fixes.md) 第 5 节报告：特定 API 26 设备上的 dataTransfer 因实况窗义务失败在约十分钟取消，获得 ACL 的 taskKeeping 则维持超过该观察窗口。这是参考项目的限定结论；本项目应先测实况窗是否发布成功，再决定是否申请额外权限。

本地 SDK 声明与其他项目文档不能证明自己的签名 profile 已获 ACL。保活方案选择需以当前权限与系统日志为依据；不叠加多套重申请或模拟任务。

## 网络与状态风险

| 项目 | 当前证据与下一步 |
|---|---|
| IPv4/DNS | [源码确认] 默认路由、gVisor DNS hijack、fake-ip 配置路径存在；[真机验证] IPv4 浏览器请求出现在内核 Tun 连接中，代理链和双向流量存在；[待验证] UDP/DNS 与 HTTPDNS 专项 |
| 路由排除 | [源码确认] VpnController 排除 HTTPDNS IP 和若干完整网段；[待验证] 直连范围是否符合用户预期，不能称所有流量均被代理 |
| IPv6 | [源码确认] 设置有 ::/0 与 isIPv6Accepted；系统 TUN 只给 IPv4 linkAddr，Go 仅 Inet4Address；[待验证] 补全地址与双栈接管/泄漏 |
| 网络切换 | [源码确认] 当前核心文件未发现 connection 网络变化监听与专用恢复流程；[待验证] Wi-Fi/蜂窝切换后重拨、DNS、连接状态收敛 |
| 状态恢复 | [源码确认] recover 使用 `/version`；[待验证] 系统 VPN 状态、扩展身份和真实转发健康一致 |
| 配置更新 | [源码确认] UI 定时器下载并 REST 重载；[待验证] 后台调度可靠性、启动覆写/安全字段/TUN 是否被热重载改变 |
| 日志 | [源码确认] hilog、可选有界内核文件、stderr 文件与最近错误存在；[待验证] 错误链中节点地址/token 脱敏与 stderr 增长上限 |

## 真机测试顺序 [待验证]

签名、应用启动、UI/独立扩展进程、自有订阅、用户授权、IPv4 浏览器转发及停止/重连已完成。下一轮补充 UDP、DNS 和 Controller/WS。观察息屏超过 15 分钟和 30 分钟点、低流量、回前台、Wi-Fi/蜂窝切换、连续启停、错误配置、进程回收与恢复。IPv6 用双栈站点和解析/出口证据单独验收。

每项记录构建 SHA、系统版本、配置摘要（脱敏）、操作、系统/VPN日志、真实流量结果与清理动作。首次授权和 AGC 操作遵循 INSTALL.md 的人机分工。
