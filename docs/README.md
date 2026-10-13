# 文档索引

| 目的 | 入口 |
|---|---|
| 理解产品与名称 | [策星](brand.md) |
| 理解模块所有权与生命周期 | [架构](architecture.md) |
| 构建与自动检查 | [构建](how-to/build.md)、[CI](how-to/ci.md) |
| 签名、安装与设备验证 | [设备指南](how-to/device.md) |
| 查询平台与配置边界 | [平台](reference/platform.md)、[配置](reference/configuration.md)、[诊断支持包](reference/diagnostics.md) |
| 面板与 Smart 集成 | [集成契约](reference/integrations.md) |
| 理解依赖与架构选择 | [验收门槛](development.md)、[ADR 0001](decisions/0001-architecture.md)、[ADR 0002](decisions/0002-minimal-host.md)、[ADR 0003](decisions/0003-smart-profile-strategies.md) |
| 查询版权与来源 | [第三方声明](../THIRD_PARTY_NOTICES.md) |

## 维护约定

文档保留操作方法、接口契约和设计原因，每项事实只有一个主要来源。版本声明以源码和锁文件为准。

问题、进度、调查快照和一次性验收结果放入对应 Issue/PR；本地原始证据放在忽略目录。历史文档通过 Git 查阅，保留精确提交链接，避免复制归档。

未实现能力须注明目标条件；构建、模拟回归与真机验收分别报告。修改实现时同步对应契约，删除文档时修复引用。密钥、真实订阅及用户配置永不入库。
