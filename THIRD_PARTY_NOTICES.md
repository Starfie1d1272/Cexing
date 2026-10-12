# 第三方来源与声明

本项目沿用 [GPL-3.0](LICENSE)。脱离 GitHub Fork 关系不改变来源、版权或许可证义务；直接复用文件已有声明应保留。精确历史调查 SHA 见 [来源快照](docs/evidence/2026-10-12-sources.md)，实际构建依赖以 `core/go.mod` / `go.sum` 为准。

| 来源 | 使用范围 | 许可与说明 |
|---|---|---|
| [ClashOH / tom-cat-mao](https://github.com/tom-cat-mao/clash-OpenHarmony) | ArkTS 工程、VPN/NAPI/Go 底座、构建脚本 | GPL-3.0；在原工程上精简宿主、解耦运行时，保留历史与适用声明 |
| [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) | Go 依赖与数据面 | GPL-3.0；模块图及其传递依赖声明须随发行核查 |
| [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) | 构建时准备的 GeoIP 快照 | 根项目 GPL-3.0；分发前核查数据源 notices，二进制不入源码仓库 |
| [vernesong/mihomo](https://github.com/vernesong/mihomo) | 目标 Smart 内核、历史隔离试编译 | 源码 GPL-3.0；尚未作为产品内核接入，模型单独许可待核查 |
| [Zashboard](https://github.com/Zephyruso/zashboard) | 目标面板、源码调查 | MIT；尚未打包，接入时保留 LICENSE/版权及资源声明 |

TunBox、Clash Mi、Bettbox、FlClash-ohos、Paws 是设计调查参考，见来源快照；不因参考就声称复制了它们的代码。尤其 TunBox 的项目许可未明确时，不复制其自有实现。Huawei SDK/NDK 与工具链由开发者按供应商授权取得，不随本仓库分发。

新代码、资源和模型接入时登记来源、固定身份、许可及实际修改。公开项目不包含个人私有代理策略、订阅、真实节点或覆写脚本。
