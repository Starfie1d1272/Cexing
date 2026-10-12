# 文档索引

| 目的 | 入口 |
|---|---|
| 理解实现、进程和职责 | [架构](architecture.md) |
| 编译、准备资源与运行回归 | [构建](how-to/build.md) |
| 本地签名、安装与真机测试 | [设备指南](how-to/device.md) |
| 查询 ABI、线程、TUN 和平台限制 | [平台参考](reference/platform.md) |
| 设计订阅、导入与覆写 | [配置契约](reference/configuration.md) |
| 接入面板与 Smart | [组件集成契约](reference/integrations.md) |
| 确定后续开发依赖和验收 | [开发顺序](development.md) |
| 理解架构选择 | [ADR 0001](decisions/0001-architecture.md)、[ADR 0002](decisions/0002-minimal-host.md) |
| 复查历史测试及调查版本 | [P0 证据](evidence/2026-10-12-p0.md)、[清理验证](evidence/2026-10-12-cleanup.md)、[来源快照](evidence/2026-10-12-sources.md) |
| 查询版权和组件来源 | [第三方声明](../THIRD_PARTY_NOTICES.md) |

## 维护约定

按读者任务区分 how-to（操作）、reference（契约）、decisions（原因）与 evidence（一次性结果），每项事实只有一个主要来源。README 和 AGENTS 只提供入口与必要约束。

- 实现细节以源码和依赖声明为准，文档解释边界及不能从源码直接看出的原因，避免复制完整 API 列表或版本表。
- 区分“现有实现”与“目标契约”。未实现能力不得写成支持承诺；完成实现时同步更新对应参考。
- ADR 的决定一旦接受就不当作进度表改写；改变方向新增 ADR，标明取代关系。
- 证据记录日期、源码身份、工具与设备条件、操作、结果及局限。历史结果不因新版本出现而覆盖，也不证明新改动已通过真机测试。
- 工作进度、临时故障与讨论放在 PR/Issue；持久验收门槛留在开发指南。不要维护多人手工更新的“最新”“当前剩余”表格。
- 删除文件时更新所有链接；旧设计与过程日志通过 Git 历史查阅，不复制进多个 archive 目录。
- 新增依赖或分发资源时核对许可证和摘要，在第三方声明登记。私有配置不属于文档示例。
