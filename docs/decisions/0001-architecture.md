# ADR 0001：原生 VPN 宿主与 Web 控制面

状态：接受。日期：2026-10-12。

## 背景

需要 HarmonyOS 系统 VPN、订阅与原生生命周期，也需要成熟的策略组和代理诊断界面。ClashOH 提供已可构建的 ArkTS、VPN Extension、NAPI worker 与 Go wrapper；完整 Flutter 客户端引入额外 UI 和平台插件维护边界。

## 决定

沿用原生 VPN 底座，以 Mihomo Smart 为目标内核、Zashboard 为目标管理面板。ArkUI 管系统启停、授权、订阅、必要状态和设置，面板不拥有 VPN 生命周期。优先用 Mihomo external-ui 服务本地静态资源。

## 影响

需统一 Controller 认证、配置事务、离线资源与模型授权。Smart 编译兼容不证明运行稳定；模型与网络行为分别验收。接受产品方向不代表组件已经实现。调查身份见 [来源快照](https://github.com/Starfie1d1272/Cexing/blob/df757138/docs/evidence/2026-10-12-sources.md)。
