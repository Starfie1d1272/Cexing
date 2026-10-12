# 架构与职责

日期：2026-10-12；基线 SHA 见 [调研入口](research/overview.md)。

## 当前实现 [源码确认]

```text
EntryAbility / ArkUI
  ├─ VpnController ─ 系统授权 / 连接扩展 / 下发 VpnConfig
  ├─ ProfileStore / Settings ─ 应用私有文件与 preferences
  ├─ CoreApi ─ HTTP / WebSocket → 127.0.0.1:9090
  └─ LiveViewKeeper ─ UIAbility 上下文申请长时任务和实况窗

ClashVpnAbility（vpn 扩展；实际 PID 待真机读回）
  └─ create TUN → protectProcessNet → initCore → startTun
       └─ NAPI async work → C++ 单 pthread worker → Go c-shared
            ├─ Mihomo 配置 / Controller / DNS / 出站
            └─ sing-tun + gVisor，使用系统 fd
```

`entry/src/main/module.json5` 声明 `type: vpn`，未指定可控制进程名的字段。源码注释中的 `:vpn` 是架构称呼，实际进程名与 PID 必须在签名安装后核实。内核由扩展直接加载，UI 不持有 TUN fd。

核心 owner：

| 边界 | 文件与行为 |
|---|---|
| 系统 VPN | `clash-openharmony/entry/src/main/ets/lib/VpnController.ets` 构造默认路由、应用白黑名单和 DNS，连接/断开扩展 |
| 扩展生命周期 | `vpnability/ClashVpnAbility.ets` 获取 TUN、保护扩展进程网络、初始化内核、写最近启动错误；disconnect 停内核再销毁连接 |
| ABI/线程 | `core/main.go` 导出四个函数；`cpp/bridge.cpp` 单 worker 串行调用，复制 TUN fd 交 Go，失败回收复制 fd |
| 核心配置 | `core/engine.go` 合并订阅/用户覆写/平台默认，禁用内核自动创建 TUN；`platform_ohos.go` 强制 gVisor |
| 数据与控制面 | `lib/ProfileStore.ets` 存 profiles/active/meta；`lib/CoreApi.ets` 访问固定 HTTP/WS 地址 |
| 后台 | `lib/LiveViewKeeper.ets` dataTransfer + 实况窗、任务取消事件与有界重申请；`AutoUpdater.ets` UI 定时订阅更新 |

Go 层由 `constant.SetHomeDir` 指向扩展 `filesDir`。C++ 与系统各持有一份 fd，成功时 Go 关闭复制 fd，系统 destroy 关闭原 fd。错误发生在 listener 已开启之后时是否完整回滚仍需专门测试。

## 目标增量 [待验证]

1. 保留系统 VPN、NAPI worker、Go wrapper 和配置存储边界，在 Go 模块图中固定 Smart 候选。
2. 启动前校验模型并原子铺到内核 home；Web 资源铺到私有版本目录。
3. Mihomo `external-ui` 托管资源，ArkWeb 打开 `/ui/`；关闭 WebView 只释放页面。
4. 统一 Controller 认证和配置应用流程，再精简原生页面。

Web 资源缺失显示可恢复错误；模型未就绪明确阻止启用 LightGBM或告知降级状态。日志需要区分构建身份、模型身份、VPN 状态与控制面可达性，并脱敏用户配置。

## 当前需要收敛的 contract

- 平台 Controller 只是缺省回环绑定：订阅可以覆盖监听地址；CoreApi 又固定为 9090，且未发送认证。目标必须强制回环、统一端口与随机 secret。
- `AutoUpdater`/`CoreApi.reloadConfig` 使用 `PUT /configs?force=true` 原始路径；与启动时 wrapper 合并路径不同。Smart、external-ui、安全字段和系统 TUN 必须经过一致的应用 contract。
- `recover()` 通过 `/version` 推断 Connected。需结合系统连接、扩展心跳或会话身份验证，避免把服务可达当作实际转发健康。
- IPv6 默认路由开关存在，Go TUN options 当前仅设置 `Inet4Address`。需要完整地址、DNS、双栈与泄漏验证。
