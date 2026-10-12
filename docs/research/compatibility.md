# 环境与构建验证记录

日期：2026-10-12（Asia/Shanghai）。基线 SHA：`3b141e3bc6050fc081aaccd5f77bf523dd4620cb`。

## 本机与设备

| 项 | 本轮读回 |
|---|---|
| Git / 分支 | Git 2.55.0；干净 main 起点，新分支 `starfie1d/initial-research` |
| remote | origin 为 Starfie1d1272 Fork，upstream 为 tom-cat-mao；两个 main 远端均为基线 SHA |
| Go | 1.27.2 darwin/arm64，`/opt/homebrew/bin/go` |
| Node | 24.20.0，现有 fnm 环境 |
| Java | Temurin OpenJDK 27；构建打包成功，实际证书签名待验证 |
| DevEco 工具 | hvigor 6.26.1、ohpm 26.0.0.410、HDC 3.2.0c |
| SDK/NDK | API 26，`26.0.0.23`，metadata 标注 Beta1；clang 与 hap-sign-tool.jar 存在 |
| 设备 | [真机验证] HDC 在线；param 读回 HBN-AL00、7.0.0.109 SP8、API 26；未记录地址/UDID |

保留当前可用工具版本。已装 SDK 为 Beta1，原文档记录 Beta2；本轮成功构建证明此安装可用于打包，不构成最新正式 SDK 的确认。未来更换 SDK 前记录官方版本和 releaseType，再做相同检查。

## 复用 DevEco 工具链

本地忽略目录 `command-line-tools/` 只包含指向现有安装的链接：

```bash
mkdir -p command-line-tools
ln -s /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin command-line-tools/bin
ln -s /Applications/DevEco-Studio.app/Contents/sdk command-line-tools/sdk
ln -s /Applications/DevEco-Studio.app/Contents/tools/hvigor command-line-tools/hvigor
ln -s /Applications/DevEco-Studio.app/Contents/tools/ohpm command-line-tools/ohpm
```

以上为本轮首次配置命令，已有目录时先核对链接，勿重复覆盖。scripts/env.sh 的检查通过；未修改脚本检查、shell 配置、系统服务或其他项目环境。删除这四个链接即可撤销；升级 DevEco 后需重新验证目标布局。

## 原始基线 [构建确认]

为避免 `patch-gvisor-tun-fd.sh` 修改共享 Go 缓存，本轮用系统临时目录的 GOMODCACHE/GOCACHE。日志与参考源码也在同一临时目录，收尾清理。

```bash
# task_tmp 为 mktemp -d 创建的目录
GOMODCACHE="$task_tmp/gomod" GOCACHE="$task_tmp/gocache" bash scripts/build-core.sh
bash -c 'source scripts/env.sh && export PATH="$CLT_ROOT/ohpm/bin:$PATH" && cd clash-openharmony && ohpm install'
bash -c 'source scripts/env.sh && cd clash-openharmony && hvigorw clean --no-daemon && hvigorw assembleHap --no-daemon'
```

原始 libmihomo.so：65,022,776 B，SHA-256 `1f956c38493c5573ef381dfa00bc6e0fbb241a33493581b18217d482ab9e64a4`。`llvm-nm -D --defined-only` 确认四个 mihomo 导出。

最终 HAP：59,965,355 B，SHA-256 `b9cc3fe196d69c49204e27c90a61c77adba2e3a5e43d667751ae04c83df786c5`。ZIP CRC 检查通过；以下库均为 ELF64/AArch64（machine=183）：

| HAP 内容 | 大小（B） | SHA-256 |
|---|---:|---|
| libs/arm64-v8a/libmihomo.so | 57,764,272 | `707ecd1bdf7ed71317ed535e4914bb6b534e24f7c40911bc56722484fd164cf2` |
| libs/arm64-v8a/libentry.so | 107,528 | `0d7b2d656fa8e9d4729a18349971a97ec91289a5695aa0f644c7925e4dd6c4c8` |
| libs/arm64-v8a/libc++_shared.so | 1,262,504 | `e18522ffe1a721673e5b1fa0b05731b0214958a4dd697a227502085a9217079f` |

HAP 中另有 `resources/rawfile/override.yaml`；当前无 Smart 模型和 Zashboard。hvigor 会 strip，故库文件与包内库摘要不同。早期前端探测包未包含正在编译的内核，已用 clean 后最终包替代；仅以上最终包作为证据。

构建警告：entry 的 oh-package version 非 SemVer、Java Unsafe 弃用警告、缺 signingConfigs 导致跳过签名。未发现需要降级 Node/Go/Java 的构建错误。

## 最新 Smart 隔离试验 [构建确认]

vernesong Alpha `daf3ad03021cca6031f4a7303ca6d861a14d5a16`，使用原 wrapper 与构建脚本，副本只更新模块替换/依赖。内核 83,746,200 B，SHA-256 `7113d94fe6734104a2c60f56a8239d3b2c32404e02159973006c5c9dde362490`；头文件 cmp 相同，四个 ABI 导出存在。

隔离 HAP 构建成功：77,364,203 B，SHA-256 `3d62858217ade02d8cfbe131a2af74de05cd6cb7fbf25c851ac9e44ec2576033`；包内 Smart 库 75,163,120 B、AArch64，摘要 `73ba2e1fbd40f9e22afe886464e514e828b1037decc3294707fa7eee4256790d`，ZIP CRC 通过。体积比原始包增加约 17.4 MB，性能与内存尚未测量。模型未入包，不能据此宣称 LightGBM 已生效。

## 最新标准稳定版对照 [构建确认]

查询确认 MetaCubeX 最新正式版为 `v1.19.32`，提交 `88dcbf7f1614a67c3b36b848ee3592dfa92ada36`。另一隔离副本仅将 module require 更新到该版本并执行 tidy，沿用原 wrapper、平台补丁和构建脚本。内核/HAP 均构建成功，生成头文件与原始版本字节一致。

内核 81,854,256 B，SHA-256 `fbda520c0ee6e46990a8f99c8e07cc20f6c888c4e168d5f46334f5ba105a02db`。HAP 75,720,139 B，摘要 `32109574937c90a7d19516c0fcebd7786fdc267459c564d019e35095cad0a357`；包内内核为 AArch64，73,519,056 B，摘要 `629d555912d6ce856db7daff233fa8a927f1d1753b6eaffcd005d258b7668f83`，ZIP CRC 通过。

最新稳定版测试包保留在忽略目录 `clash-openharmony/dist/mihomo-v1.19.32-unsigned.hap`。后续可显式传给 sign-agc.sh；实际签名安装前核对身份与 profile，并将它与原始包分别验收。本轮未把模块升级写入产品源码。

## 签名与真机阻断

已按 INSTALL.md 4.1 生成独立 EC P-256 keystore、CSR 与随机口令，文件位于 `clash-openharmony/.signing/`，目录/私密文件采用限制权限且全部忽略。只把 CSR 用于证书申请。

实际运行 `bash scripts/sign-agc.sh` 在缺少 `clashoh-debug.cer` 时退出；`clashoh-debug.p7b` 也未提供。未签名包尚未安装，应用启动、VPN 转发、控制面通信和后台行为均 **[待验证]**。`bm dump -n com.clash.dev` 返回无法获取信息，尚不能证明设备已安装此包；安装前再确认是否会覆盖既有应用。

下一步由用户按 [INSTALL.md 第 4 步](../../INSTALL.md#4-签名材料零售真机必须-网页--辅助) 在 AGC 完成应用、调试证书及当前设备 profile，放回 cer/p7b。包名暂为 `com.clash.dev`；如账号内冲突，确认新包名后按手册同步。不复用其他应用的 profile，也不公开设备 UDID。签名后由 Agent 校验、安装和抓日志；订阅导入与首次 VPN 授权由用户完成。
