# 生态比较与复用范围

调查日期：2026-10-12。固定源码版本见 [来源登记](sources.md)。

| 项目 | 本轮证据 | 用途与边界 |
|---|---|---|
| [ClashOH](https://github.com/tom-cat-mao/clash-OpenHarmony) | [源码确认][构建确认] ArkTS + VPN + NAPI + Go；原始 HAP 可构建 | 工程基底，GPL-3.0，保留作者与许可证 |
| [vernesong/mihomo](https://github.com/vernesong/mihomo) | [源码确认] Alpha、Smart/LightGBM/API；[构建确认] 当前 wrapper 可交叉编译 | 首选研发候选，开发分支稳定性待真机回归 |
| [lux5am/mihomo-smart](https://github.com/lux5am/mihomo-smart) | [源码确认] Alpha 同模块名，旧 gVisor，与 TunBox 记录一致 | 固定对照版本，当前提交较早，本轮未试编译 |
| [TunBox](https://github.com/xiaoli8571/TunBox) | [源码确认] 换核文档包含模型铺盘与 Smart 选路反馈 | 技术参考；根项目许可未明确，复制代码或模型前单独核实 |
| [Zashboard](https://github.com/Zephyruso/zashboard) | [源码确认] Vue/Vite 静态资源、Smart API，MIT | 主控制界面，优先最新正式版 |
| [Clash Mi](https://github.com/KaringX/clashmi) | [源码确认] `assets/zashboard/`、Dart 本地 HttpServer，GPL-3.0 | 参考资源完整性；本项目优先复用 Mihomo HTTP 服务 |
| [Bettbox](https://github.com/htoay/Bettbox) | [源码确认] ohos-port 的 VPN 迁移和后台实测文档，GPL-3.0 | 借鉴风险与验证方法，许可/权限按本项目核实 |
| [FlClash-ohos](https://github.com/tljk/FlClash-ohos) | [源码确认] 本轮读取仓库 tree/版本/许可证；实现未深入审查 | Flutter OHOS 对照，GPL-3.0 |
| [Paws](https://github.com/richerfu/Paws) | [源码确认] tree 中有原生 VPN 扩展与平台插件，MIT | 补充平台参考，当前未做运行验证 |

采用 ClashOH 的理由是现有 ArkTS、VPN 扩展、C ABI 和命令行流水线能够直接作为验证入口。Zashboard 已承担所需代理管理界面，维护完整 Flutter 客户端会增加另一套 UI 与平台插件边界，因此当前选择原生轻量宿主。

会话中的 FlClash/Bettbox 文件数与 Stars 不在本轮重算；它们影响有限，也随版本漂移。选择依据是实际职责、构建结果与维护范围。
