# Mihomo Smart 换核调查

日期：2026-10-12。完整版本见 [来源登记](sources.md)。

## 候选与差异 [源码确认]

当前产品基线是 MetaCubeX Mihomo `v1.19.29`。两个 Smart 候选均声明模块 `github.com/metacubex/mihomo`、`go 1.20`，属于 Alpha 分支；当前可取得的最新 vernesong 提交是 `daf3ad03021cca6031f4a7303ca6d861a14d5a16`（2026-10-12），lux5am 是 `8d4c8c70faedc27fda176ee18742ab86b5835a83`。

vernesong gVisor 为 `v0.0.0-20260922041103-e2cbcd6e7400`，lux5am 与本项目原始内核均为 `v0.0.0-20251227095601-261ec1326fe8`。Smart 的缓存与连接评分实现也有变化；同模块名不能证明运行行为完全兼容。优先用最新 vernesong 做隔离试验，再建立固定 SHA 的稳定性门禁。

## 最小试编译 [构建确认]

复制原始 `core/*.go`、go.mod/go.sum 和构建脚本到系统临时目录。仅在副本新增：

```go
replace github.com/metacubex/mihomo => github.com/vernesong/mihomo v1.19.10-0.20261012020909-daf3ad03021c
```

执行 `go mod tidy` 后沿用原有 `build-core.sh`：Go 1.27.2、OHOS clang、`GOOS=android GOARCH=arm64 CGO_ENABLED=1`、`netgo ohos cmfa with_gvisor`、c-shared。原有 gVisor 补丁成功匹配新版本，模块缓存隔离于临时目录。

结果：动态库约 80 MiB；生成头文件与原始 `libmihomo.h` 字节一致，四个 `mihomoInit/mihomoStartTun/mihomoStop/mihomoFree` 导出存在。本轮无需修改 wrapper、NAPI 或 Go runtime 就能编译这个固定候选。OHOS ABI 的运行兼容、耗电与内存仍待设备验证。

试验只在临时副本进行，主工程继续使用原始内核。产品接入阶段修改 `core/go.mod/go.sum`，固定依赖来源，记录 gVisor 补丁身份；随后按模型准备与配置 contract 修改启动 owner，保持原 ABI。

## 模型与真实选路 [源码确认][待验证]

`adapter/outboundgroup/smart.go` 的选项为 `type: smart`、`uselightgbm`、`collectdata`、`prefer-asn`。`component/smart/lightgbm/lightgbm.go` 通过 Go `leaves` 读取模型；本候选无需额外 C++ LightGBM 库。模型加载包含 transforms 参数，文件存在检查不足以证明其有效。

`GetModel()` 在 sync.Once 内同步加载；缺失/无效会尝试下载，`downloadModel` 上限 90 秒。失败后预测路径会使用其他权重计算。需启动前解析与校验；坏模型不得通过“Smart 组存在”的检查。

模型 release 当前提供 `Model.bin`（9,345,218 B），API 给出的 SHA-256 为 `23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788`。本轮只读取元数据，未下载模型。release tag 可变，未来须固定资产摘要并检查实际下载；源代码 GPL-3.0 不足以确定训练模型的单独再分发条件，授权未明确前不入产品资源。

建议模型就绪后使用 `uselightgbm: true`、`collectdata: false`、`prefer-asn: false`，默认关闭自动更新，保持模型/内核组合可追踪。节点/provider/rules 沿用用户配置；若需要生成 Smart 组，采用显式转换并保留原订阅，不强制固定到具体节点。

[TunBox 换核记录](https://github.com/xiaoli8571/TunBox/blob/930accb2ba6a5d5356f47b456cdd376a649a0f8c/MIHOMO_SMART_KERNEL_SWAP.md) 已全文读取。它的 `Ssrvpn*` ABI 与本项目不同；其报告提供模型预置和按连接观察的参考方法，不能直接替换本项目动态库。

验收需同时满足：离线模型加载成功；至少两个有效节点；规则路径进入 Smart 组；`/group/weights` 返回有效数据；`/connections.chains` 显示真实出口；故障/目标变化时观察选择结果。`Now()` 或延迟排序不构成 LightGBM 参与预测的证据，还要记录候选版本、模型摘要和预测路径诊断。

更新与回退：每次固定新 SHA，重做编译、模型兼容、端点和真机回归；保存上个正常源码依赖与签名构建记录。回退通过旧依赖重建并保留订阅数据，避免仅替换未知 `.so`。
