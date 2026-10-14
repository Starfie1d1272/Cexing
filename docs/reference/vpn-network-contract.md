# 系统 VPN 与内核网络契约

连接时由宿主读取应用名单与 IPv6 偏好。应用范围必须是 all、white 或 black；white 只下发 trustedApplications，all/black 只下发 blockedApplications。white 去除自身后为空则拒绝启动；black 将自身加入排除。名单去重、包名验证，按最低 API 22 的 64 项限制计算（black 为自身预留一项）。本应用 VPN 进程在内核创建任何出站 socket 前完成 protectProcessNet；不可用或失败时拒绝启动并回收已创建的 TUN。

## SDK 与设备范围

`cexing/build-profile.json5` 声明最低 HarmonyOS 6.0.2 / API 22，目标 API 26。发行设备范围以 #92 的实际验收为准，API 21 不在支持声明内。官方 CLT 26.0.0.851 的 Release SDK 26.0.0.105 中 `ets/api/@ohos.net.vpnExtension.d.ts` 将 protectProcessNet 标注为 since 22，trusted/blocked 标明互斥，API 23 之前最大 64 项。SDK 的 sdkApiVersionMap 将 6.0.2(22) 映射到 API 22；运行时同时检查 API 和方法存在性。

公开[官方声明](https://github.com/openharmony/interface_sdk-js/blob/master/api/@ohos.net.vpnExtension.d.ts)用于对照；发行构建以实际安装的华为 SDK 为准。SDK 声明要求支持 IPv6 时配置 IPv6 地址，MTU 的文档范围为 576–1500。当前系统/Go 两端仍一致为 9000；历史可用性与类型声明不能证明所有受支持系统的实际 MTU 校验和大包行为。任何收敛必须同时改变两端，并先完成 #92 的大小包、UDP、分片、DNS、TCP/HTTPS 对照。

## 双栈与关闭态

| 参数 | IPv6 关闭 | IPv6 开启 |
|---|---|---|
| 系统/Go IPv4 地址 | 172.19.0.1/30 | 172.19.0.1/30 |
| 系统/Go IPv6 地址 | 无 | fdfe:dcba:9876::1/126 |
| 系统默认路由 | 0.0.0.0/0 | 0.0.0.0/0、::/0 |
| 系统 DNS | 既有 IPv4 DNS | 另加隧道内 fdfe:dcba:9876::2 |
| TUN DNS 劫持 | IPv4 53 | IPv4/IPv6 53 |
| Mihomo/DNS IPv6 | false | true |

IPv4 始终保留；IPv6-only 接入网络不是删除系统 IPv4 地址的理由。本次系统 VpnConfig 的 IPv6 进入 Extension 的 UserOverrides；Go 在原有平台约束入口施加顶层与 DNS IPv6，并构造同一 gVisor TUN 的 Inet6Address。成功启动后使用原子只读快照，预览、验证、热加载不能改变已有系统隧道的地址族；停止释放快照，下一次连接读取新设置。没有另建配置发布系统。

配置模块接线契约：CoreValidator.settingsOverrides 与 EffectiveVersions.stage/previewMerge/verify 的现有 overrides 加入 `ipv6: s.ipv6`。这是唯一布尔字段，不携带网络地址或凭据；没有该字段的断开态配置校验按 IPv4-only 处理。连接中仍以 Go 的系统会话快照为准。接线由这些共享文件的所有者完成。

同平台[NekoBox4Harmony 固定提交](https://github.com/xiaoli8571/NekoBox4Harmony/blob/8c4c646aba97e968c0a43c718bdb6bfa151e848a/entry/src/main/ets/vpnext/VpnExtAbility.ets)也将平台 IPv4/IPv6 地址与进程保护配套；仅参考其设计，不复制源码。TUN 选项依据仓库锁定的 Mihomo/sing-tun 声明独立实现。
