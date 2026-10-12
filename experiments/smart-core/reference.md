# Smart 内核隔离实验

本目录是研究构建，不是生产换核。标准 `core/go.mod` 仍为 Mihomo v1.19.32；应用名、包名、仓库名、安全配置、ArkTS UI 和 C++ worker 均未修改。宿主固定于 `7f731d5c9c8d4eba7a1680bcb3981d7877232bcc`，构建只写忽略的 `.work/`。实验 HAP 仍有原应用身份，不安装、不签名、不发布。

## 来源与选择

| 来源 | 固定身份 | 用途 |
|---|---|---|
| [vernesong/mihomo](https://github.com/vernesong/mihomo/tree/daf3ad03021cca6031f4a7303ca6d861a14d5a16) | `daf3ad03021cca6031f4a7303ca6d861a14d5a16` | 候选源码，2026-10-12 提交；沿用 P0 已试编译候选，独立锁定模块图 |
| [lux5am/mihomo-smart](https://github.com/lux5am/mihomo-smart/tree/8d4c8c70faedc27fda176ee18742ab86b5835a83) | `8d4c8c70faedc27fda176ee18742ab86b5835a83` | 对照 2026-07-11 提交，Smart YAML 与 API 路由；未在本实验编译 |
| [TunBox](https://github.com/xiaoli8571/TunBox/blob/930accb2ba6a5d5356f47b456cdd376a649a0f8c/MIHOMO_SMART_KERNEL_SWAP.md) | `930accb2ba6a5d5356f47b456cdd376a649a0f8c` | 阅读完整换核记录，仅参考，不复制自有桥接或补丁 |

选择 vernesong 是减少相对项目 [P0](../../docs/evidence/2026-10-12-p0.md) 的未知差异，并使用仍有当日源码活动的固定候选，不代表已验证长期维护、稳定或真机适用。两个 Smart 来源保持 `github.com/metacubex/mihomo` 模块路径；不能只改 import，也不能复制 TunBox 的九个 `Ssrvpn*` ABI 库到本项目。

本目录 `go.mod` / `go.sum` 是从宿主模块图替换 Mihomo 后 tidy 的独立锁；保留宿主已锁定的较新传递依赖。因此不等于 TunBox 的 2026-07 原始模块图：实际 gVisor 是 `v0.0.0-20260922041103-e2cbcd6e7400`，不是它记录的 `261ec1326fe8`。构建先验证所有模块完整性，再只在实验缓存施加仓库 Fstat 补丁；重复构建仅允许从模块 ZIP 恢复原文或准确的已知补丁，其他修改立即失败。

## 构建与验证

准备官方工具链并激活 Go、Node、JDK 后，从仓库根目录执行：

```bash
source scripts/env.sh
bash experiments/smart-core/build.sh hap
bash experiments/smart-core/test.sh
git diff --check
```

工具链在其他位置时设置 `HARMONYOS_CLT_ROOT`，详见 [构建指南](../../docs/how-to/build.md)。脚本使用 Git archive 固定宿主，下载校验后的候选复制到私有源码目录应用 `offline-model.patch`，然后复用基线的 OHOS clang、日志 stub、gVisor 补丁与 c-shared 构建。源码补丁是本实验新增，未改生产 `core/` 或共享脚本。

编译参数保持 `GOOS=android GOARCH=arm64 CGO_ENABLED=1`、`netgo ohos cmfa with_gvisor`。Go 的 android 目标不表示产物是 Android APK；C 链接实际使用 OHOS musl SDK。产物验证读取 ELF64/LE/AArch64/DYN、动态导出符号、四个生成头文件声明，HAP CRC、必需库和资源、模型不入包。`build-info.txt` 记录编译模块图，`upstream-module.json` 记录补丁前来源与校验和；本地 replace 在二进制元数据中须和这两份身份一起解释。

`test.sh` 将本目录的两个测试 fixture 复制到实验上游目录，使用真实 parser/router 和模型降级路径。没有真实节点、凭据或 TUN。模型测试覆盖缺失、损坏/摘要不符、禁止下载、不删除坏文件及统计 fallback。API 测试覆盖 synthetic YAML 生成 Smart 类型、`GET /group/weights`、`POST /cache/smart/flush` 的认证和返回契约，以及 `POST /upgrade/lgbm` 离线拒绝。

## ABI、线程与平台边界

保留 `mihomoInit(char*) -> char*`、`mihomoStartTun(int,char*,char*) -> char*`、`mihomoStop(void)`、`mihomoFree(char*)`；返回错误串仍用对应 free 释放。基线 C++ NAPI async work → 单 pthread worker 不变，系统原 TUN fd 与 `dup` 给 Go 的 fd 所有权不变。不新增主线程 Go 调用，不主动卸载运行时。详见 [平台契约](../../docs/reference/platform.md)。

gVisor Fstat 补丁准确应用到锁定版本；TLS/uTLS/REALITY 与 TUN 代码编译进入库，但跨编译不证明 OHOS pthread TLS 布局、TUN fd 沙箱行为、TLS 握手、DNS、UDP、IPv6 或真实流量可用。本实验不操作设备。

基线 worker 的缺少 ABI 符号失败分支仍包含 `dlclose(h)`。本实验验证四个符号存在，因此没有覆盖该失败路径；父任务应另行审查 Go runtime 被加载后卸载的边界，本线未混改生产桥接。

## Model.bin 与降级

[上游模型 release](https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model) 是可变标签。2026-10-12 查询到 release ID `221196816`、Model.bin asset ID `530723858`，资产更新时间 `2026-08-26T11:40:42Z`，尺寸 `9,345,218` B，GitHub 报告 SHA-256 `23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788`。这是远端元数据，不是本次下载后验证的文件摘要。release 正文未给模型单独分发许可；源码 GPL-3.0 不自动证明该模型许可。

本实验不下载、不再分发、不铺盘 Model.bin；许可明确前，不把它加入资源流水线。可供后续私有测试的本地文件须与该固定尺寸和摘要一致，再由 leaves 解析。首次 `GetModel` 缺失、尺寸/摘要不符或解析失败，返回 nil，明确日志并保留统计策略，坏文件不删除。首次加载仍由上游 `sync.Once` 管理：失败后补入模型不能靠 VPN stop/start 重试，需新的宿主进程；不通过 `dlclose` 重置 Go runtime。

补丁同时拒绝 `lightgbm.downloadModel` 与独立 `updater.UpdateLgbmModel` 下载路径，后者也覆盖 REST 升级与定时更新；仅设置 `lgbm-auto-update: false` 不足以防首次联网。本实验不提供可分发模型的原子安装/热更新机制；未来资源流水线须在许可明确后实现临时文件、摘要与解析校验、原子切换和上一版本回退，加载期间文件不可被并发改写。

## Smart YAML / API 契约

`type: smart` 才是 Smart 策略，`uselightgbm` 是独立的模型能力，`collectdata` 控制训练 CSV 收集，`prefer-asn` 可触发 ASN 数据加载。合成 [fixture](smart.yaml) 显式关闭这三项与自动更新，不强制节点、不增加 UI 状态。`policy-priority`、`sample-rate`、`tolerance` 保持上游语义；模型实验不能把 Smart 改成固定 select。

两个固定候选都有 `/group/weights`、`/group/{name}/weights`、`/cache/smart/flush`、`/cache/smart/flush/{config}`。单组不存在或类型错误、缓存不可用与无排名数据有不同响应；调用方须处理 error/message 与空 weights，不能以 HTTP 200 宣称预测成功。缓存清空是破坏历史学习状态的显式操作，不在页面打开时调用。

证据必须分三层：YAML 解析得到 Smart 策略；固定文件摘要和解析成功得到模型加载；真实请求命中 Smart 规则，满足最小采样量且进入 `PredictSingle` 得到有效输出，才证明模型实际预测。上游 `ModelPredicted` 布尔包含统计权重路径的结果，不能单独作为 LightGBM 参与证明。权重 API、组名、延迟排序、成功连接均不充分。后续验收须有两个有效节点、离线模型、目标/故障变化、真实连接链，以及针对模型分支的明确观测；本次后两层未完成。

## 回退

本实验无生产激活入口：生产模块/库/配置不变，停止使用实验脚本即回到标准路径。实验 HAP 使用原包名，覆盖安装可能触及既有沙箱，因此不能把隔离构建误称为隔离安装。如果以后授权设备验收，应独立保存脱敏配置、标准依赖锁和上一份产物，并由宿主完整生命周期回退；Smart 学习缓存与普通配置分别处理，不删除用户数据。正式接入须在 Controller 安全、配置事务门槛之后另开实现 PR。
