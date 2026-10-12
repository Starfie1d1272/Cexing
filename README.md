# ClashOH

面向 HarmonyOS NEXT 的轻量原生 Mihomo VPN 宿主。ArkTS 管理系统授权、连接、订阅和后台运行，Go 内核承担代理转发。

产品方向是 **原生宿主 + Mihomo Smart + 内置 Zashboard**。Smart 与 Zashboard 的接入须通过独立验收；此仓库保留标准 Mihomo 底座、原生配置导入，以及面板接入前的最小代理组选择入口。

- [开发与构建](docs/how-to/build.md)
- [签名与设备验收](docs/how-to/device.md)
- [架构与模块边界](docs/architecture.md)
- [配置兼容契约](docs/reference/configuration.md)
- [后续开发顺序与验收门槛](docs/development.md)
- [完整文档索引](docs/README.md)

基于 [tom-cat-mao/clash-OpenHarmony](https://github.com/tom-cat-mao/clash-OpenHarmony) 演进，沿用 [GPL-3.0](LICENSE)。来源、第三方组件及资源授权见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。仓库历史保留原始实现和验证基线。
