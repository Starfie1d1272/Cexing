# 实验来源与许可

本仓库 [GPL-3.0](../../LICENSE) 和 [第三方声明](../../THIRD_PARTY_NOTICES.md) 继续适用。

- 构建下载 `vernesong/mihomo@daf3ad03021cca6031f4a7303ca6d861a14d5a16`，上游 LICENSE 为 GPL-3.0。本目录 `offline-model.patch` 是针对该版本的新增修改；对应源码和 LICENSE 保存在忽略的实验构建目录，发布时须另行履行源码与通知义务。本次没有发布二进制。
- `github.com/vernesong/leaves@2a1c022f37d0` 为模型解析的传递依赖，核对该版本 LICENSE.md 为 MIT、Copyright (c) 2018 Dmitry Khominich；精确版本/摘要在独立 Go 锁文件，后续分发须保留完整许可。其他依赖沿用各自许可，不能仅以 Mihomo 根许可概括整个模块图。
- lux5am 的 Smart 来源用于源码对照，未复制其实现；TunBox 未明确项目许可，仅阅读记录，不复制其自有源码。
- Model.bin 单独分发许可尚未确认，未下载、未打包、未再分发。记录其发布摘要不构成许可确认。
- Huawei SDK/NDK、原生库与 HAP 不提交。新实验未包含订阅、令牌、证书、真实节点或私有配置。
