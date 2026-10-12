# 2026-10-12 HAP 门禁复现与修复

针对独立审查任务 `01a1311d-1404-77a6-b53a-39a3e450f0a7` 报告，先在原 PR #7 提交 `56ec1b315ae3d7b8fd910226ceca95b8b289e36b` 自行复现，再修复。环境仍为初次实验的 Linux/Go 1.27.2/官方 API 26 工具链，没有签名、安装或设备操作。

## 修复前复现

原库与头文件保持真实实验产物，仅替换临时 HAP 中的内容：构造 112 B 数据，填入 ELF64/LE/AArch64/DYN 标记及四个 ABI 的字符串；其余四个必需项均为空。旧 `verify.py ... hap` 在普通 Python 下退出 0，报告包内核心只有 112 B。旧门禁仅检查核心字符串及资源名称，没有绑定实际构建身份，也没有解析包内动态符号表。

同一临时 HAP 加入 synthetic `resources/rawfile/Model.bin`，普通 Python 退出 1（模型禁止 assert），`PYTHONOPTIMIZE=1` 退出 0。优化模式禁用了包括模型禁止在内的所有 assert。两个漏洞均复现；初次 HAP 门禁证据不充分，本记录补充而不将历史结果改写为充分验证。

## 修复范围与新门禁

只修改 `experiments/smart-core/`：

- 核心门禁核对固定 upstream 模块 path/version/sum、编译 replacement/目标参数、锁/源码补丁摘要，以及 ELF 程序头和四个已定义 FUNC/GLOBAL 动态导出。记录未 strip 与 SDK 独立 `llvm-strip --strip-all` 结果。
- HAP 门禁读取本次核心记录；锁/补丁、原核心或 strip 结果变化即拒绝。包内核心必须与独立 strip 结果逐字节相同，再从包内 ELF 动态表验证四个导出。worker/C++ 库比对独立 strip 的本次 CMake 产物，不能接受空库或旧打包缓存。
- override.yaml 与固定宿主 Git 源码一致，GeoIP 与固定 SHA-256 一致，必需项非空；记录五项尺寸/摘要。CRC、重复条目、Model.bin 禁止使用显式失败判断，兼容 Python 优化模式。
- 构建开始删除旧成功记录，门禁失败不遗留本次成功报告。实验 gVisor 缓存保护中的 assert 也改为显式失败，避免优化模式绕过未知缓存修改检测。

记录保护受信本地工作目录中的构建/打包一致性，不是签名认证；不防同时篡改源码、工具链和记录的外部攻击者。SDK/Hvigor strip 行为变化将明确失败，须独立审查后更新，不能退回“仅含符号字符串”检查。

## 本次验证

- `PYTHONOPTIMIZE=1 bash experiments/smart-core/build.sh hap` 成功：模块完整性检查、OHOS c-shared 编译、clean、C++/ArkTS/HAP 打包与新门禁均执行。
- 同一有效 HAP 在普通 Python 与优化 Python 下通过新门禁。
- `python3 experiments/smart-core/test-verify.py` 共 20 项通过：两种 Python 模式各自接受有效 HAP，拒绝 112 B 伪核心、未 strip 的核心、保留的标准 v1.19.32 旧核心、缺少 mihomoFree 动态导出的 ELF、Model.bin，以及分别置空 libentry/libc++/override/GeoIP 的 HAP。fixture 与原产物隔离。
- Shell 语法、Markdown 相对链接、Git diff 空白检查通过。Go/ArkTS 业务代码未改变，没有重跑无关业务回归。

## 新构建产物身份

本次未签名 HAP 为 85,482,331 B，SHA-256 `8493de2fe0cea60982bcb530339f49491d89b0f60bb8eb2fd66fe6bc239e35bd`。核心与资源字节和初次构建相同，HAP 容器摘要改变；不据此宣称容器可重复构建。

| 门禁绑定项 | 字节数 | SHA-256 |
|---|---:|---|
| 未 strip libmihomo.so | 83,791,920 | `039b74e4933f920714610060d662409e4744fdfa953ad6700955117611d380fe` |
| strip / 包内 libmihomo.so | 75,211,280 | `d4505717db518dafa719254b18ddcf5e81263dd8f2887dabf7723a41896076d4` |
| strip / 包内 libentry.so | 107,528 | `a3b7be55243954ac17d8eedd2e1eb7331592ecb3fc941be1ccff35b0128d9d9a` |
| strip / 包内 libc++_shared.so | 1,262,504 | `965803c3fe53e02452e4c0479ad13c88f166c04207d27e3c531161a7c75a6c17` |
| 包内 override.yaml | 505 | `baf412f57eef8ef5ff3923286041976ec9334e7badf6b753f8726201666fcb76` |
| 包内 GeoIP | 8,414,245 | `b8f447617c3f6d8ef0f7528c23dfba695bca16a31a396bc4c1fca49e9f038ae3` |

模型许可、合法模型加载、真机 TUN/TLS 和实际预测等原有未验收边界仍然存在。

## 独立 worker 问题（未修改）

准确位置：基线 `clash-openharmony/entry/src/main/cpp/bridge.cpp` 的 `ensureLoaded()`，第 102–109 行缺符号失败分支，第 106 行调用 `dlclose(h)`、第 107 行清空 handle；第 85 行成功短路仅检查 handle 和 mihomoInit。

最小后续修复范围限制在此函数及它的加载状态：成功 dlopen 后即保留 handle，缺符号时不卸载 Go runtime；缓存该次不可用结果以免重复 dlopen，只有四个函数指针全部有效才允许返回成功。保留 worker 调用队列、fd 所有权、四 ABI、业务停止语义与错误返回契约。单独验证缺任意符号、重复请求仍失败且没有再次加载/卸载，以及完整 ABI 正常加载。生产文件和该修复未混入研究 PR。
