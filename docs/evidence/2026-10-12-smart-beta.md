# Smart 首个测试版证据

真实模型加载、预测及 Linux 转发链已验证：官方资产 30 个特征被 leaves 解析，`PredictSingle` 对明确输入返回 `0.920044907231`；12 个真实 HTTP 请求经 `MATCH → smart-real → local-a`，产生 10 次有效 LightGBM 预测。关闭 local-a 后 6 个请求经 local-b 成功，两个真实本地节点均有转发命中。不是排序、组名或统计 fallback 的推断。

独立 reviewer 指出的两项 P2 和早期失败记录残留均已修复，最终 HAP 构建代码 `6159740`；最终产物身份与新增失败检查见末节。

本线为最新 main `da622b7` 创建的 `feat/smart-beta`。首次 HAP 构建代码身份为 `37355684eabe87761afa351cc83c4c350e0a53ea`；后续增强测试 fixture 和本文未更改 HAP 的原生/ArkTS/资源输入。Smart 上游固定 `daf3ad03021cca6031f4a7303ca6d861a14d5a16`，补丁 SHA-256 `b8350b21b3825cec5f8804632c20c674a2381d686e50409e828d1a5c5d00c5eb`。

## 实现与实际检查

- 生产模块已切换为锁定 Smart 来源；只在专用缓存施加精确离线补丁，原始模块完整性在构建前/后验证。两个因最小版本选择必需的传递依赖版本变化、leaves 身份均在 go.mod/go.sum，而不是隐藏换库。
- 模型只从真实上游 [release](https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model) 下载到临时验证目录，9,345,218 B，SHA-256 `23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788`。无模型进入源码或 HAP；未推定单独分发许可。
- 缺失、损坏模型的统计回退通过；保留原坏文件。真实模型经安装接口底层校验/解析/原子安装，旧无效资源保留为 `.previous`；同尺寸真实模型篡改被拒绝且不替换资源。不足采样不计作模型预测；有效 `PredictSingle` 结果才计数。
- 真实 router/parser 通过 Smart YAML、状态 GET、模型导入拒绝、权重 GET、显式缓存清理与模型联网升级拒绝。无凭据/错误凭据均 401；未配置 Controller secret 的新增 Smart 路由为 404，不能通过任意 Bearer 伪造认证。
- 实际 bridge.cpp 的缺四个符号分别验证：重复 Init 只 dlopen 一次、dlclose 零次、worker 调用零次；完整 ABI 两次 Init 均在独立 worker，dlopen 一次、dlclose 零次。宿主链接拦截/日志桩不证明 OHOS Go runtime 行为。
- 专用 `scripts/test-smart.sh` 的真实模型/转发检查及全部配置 pipeline 回归通过；普通 `go test ./...` 也通过，实际模型集成测试用 `smartbeta` tag 与专用入口运行。既有 profile、VPN startup/recovery、AppRuntime、background、Zashboard 的所有 `scripts/test-*.cjs` 宿主回归通过。
- 官方工具链 OHOS c-shared、C++、ArkTS 与未签名 HAP 构建通过，原生库/资源变化后执行 clean。Linux x86_64；Go 1.27.2、Node 26.11.1、JDK 27、CLT 26.0.0.851、SDK/API 26。保留既有编译警告，未签名、未安装、未操作设备。
- 普通与 `PYTHONOPTIMIZE=1` 均通过新 HAP 门禁：真实 Smart replacement、来源补丁/输入/核心/头文件构建记录、AArch64 ELF 与四个动态 ABI、独立 strip 后字节、本次 CMake 的两项宿主库、CRC、资源摘要和 Model.bin 禁止。
- `tests/smart/hap_gate.py` 的 6 项篡改拒绝通过：精确 112 B 假核心且四项必需库/资源为空、单独空 override、违规 Model.bin，在两种 Python 模式下均失败。

## 产物

忽略目录中的 `build-identity.json` 保存逐项核心/资源及工具摘要，`smart-build.json` 保存已验证补丁源码摘要和实际核心身份；构建完整性复验完成后才提升为成功记录。记录保护受信构建目录，不是签名证明。

| 产物 | 字节数 | SHA-256 |
|---|---:|---|
| 首次未签名 HAP | 91,152,603 | `6dea67d61bd4d7e3f67a4a6913a087acb6c4dd7164649ac000fb7b8f75159ed5` |
| 未 strip 核心 | 83,543,728 | `7a028daaf3ce3763565865d0f76748d4cbf4ccf9fc308ba14629d56947e121e7` |
| 包内 strip 核心 | 74,961,360 | `41679e6955ae098c7a9b6087739767e5fda4337d6fd56a35a272c3cf3cc6d91c` |
| 包内 worker | 107,520 | `34d2ccf39b9de4c8857a318cf040fb6d8374ab7917afabd752070b1953fa1d8c` |

## 保留的失败与未验收边界

首次私人模块缓存补丁因只读目录失败，随后仅给该私人缓存中的被修改文件/父目录写权限。新增配置 fixture 曾把块 YAML 字段插入 flow mapping，真实 parser 拒绝；修正为合法 flow mapping 后回归通过。首次 HAP 身份检查曾假定 trimpath 会保留 ldflags，而 Go 没有保存该字段；门禁拒绝，改用经源码检查和模块完整性复验的构建记录绑定后重建通过。一次宿主回归调用未设置 mock SDK 环境，preloader 拒绝；按既有 CI 环境重跑通过。这些首次失败没有算为成功。

共享开发缓存中的 notice inventory 报 `RyuaNerin/testingutil v0.1.0` 缺少 notice，保留原失败门禁。该模块只在依赖图，不在 `go list -deps .` 或实际 HAP Go 元数据中，未链接进核心；不能以此声称它具有已确认许可。独立新缓存按 CI 下载入口重查，136 个实际下载模块的 notice inventory 通过，testingutil 记为依赖图中未下载模块；没有放宽 gate。未运行整个 Full CI 单入口，不声称发行审查全部通过。

模型合法来源的私有导入入口已实现，但原生 UI/文件选择与统一 Controller 客户端仍由 UI/集成会话接入。参数与响应见 [Smart 契约](../reference/smart-beta.md)。本环境没有 cloud_threads 发消息工具，通过结果交接公共脚本/CI/notices 边界；没有改页面、CoreApi 或独立安全实现。

Linux 真实连接不证明手机 TUN、OHOS pthread TLS、TLS/REALITY、UDP/DNS、IPv6、后台或网络切换。Hokit 签名、手机安装与这些验收留给用户本地会话；本线不签名、不发布、不自动合并。模型替换后不热重载，首次加载失败的进程必须结束再启动，不能用停止 VPN 或 dlclose 代替。

## 独立审查修复与最终产物

新的独立 reviewer 对 `b9878e5` 审查，指出两项 P2 和一项 P3，未修改代码、未批准/合并 PR。修复提交 `6159740`：

- 构建记录绑定全部 11 个本地生产 Go 源码的摘要及文件集合（排除测试/生成 third_party）。旧核心遇到源码修改或新增时必须失败；普通/优化 Python 下共 4 项源码变化拒绝通过，原文件均恢复。
- 旧模型读取错误除 ENOENT 外均拒绝安装。真实模型上传时旧文件 chmod 000 导致实际读取失败，原内容保留；恢复权限后合法导入/备份、真实模型预测、12 请求/10 次预测和故障后第二节点 6 次转发均再次通过。
- 成功/pending 记录在环境和工具链预检查前清除；故意指定不存在的 CLT 路径，构建确实失败且两份旧标记均消失。HAP 门禁开始即删除旧报告；6 项篡改和 4 项源码变化失败均核验没有遗留成功报告。
- 重建核心、clean、未签名 HAP 和普通/优化 HAP 身份门禁再次通过。最终输入补丁 SHA-256 `57e096030c32c2a043eb0cd4c8a6965d2d2373ad6e723e9ece509012b7410f97`。初次产物记录保留，不把它改写成审查修复后的产物。

| 最终产物 | 字节数 | SHA-256 |
|---|---:|---|
| 未签名 HAP | 91,152,923 | `69020352eda257f0a8714e8290ea38d6ec1b74700952a3449b831e3f24695491` |
| 未 strip 核心 | 83,544,048 | `b4aa72ffc1dc119fcaa7a30bae225a564c62479b19f407e122287a78895914b8` |
| 包内 strip 核心 | 74,961,680 | `0c36d0a49215d3fa2d22dae518ea71c0bd5a346ae5d022a49ba54bbe02725524` |

worker、libc++ 与 GeoIP/override 摘要沿用前述本次构建值。独立 reviewer 已复核 `e658f6b`：两项 P2、一项 P3 均关闭，未发现新增阻断问题；独立核对 11 项源码摘要与最终 HAP 摘要一致。复核未重跑重型构建，未作 GitHub 批准/合并操作；完整 Full CI、手机与 UI/Controller 合流边界继续适用。
