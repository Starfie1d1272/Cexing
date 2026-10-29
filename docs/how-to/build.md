# 构建与回归

所有命令从仓库根目录在 Bash 执行。需要 Go、Node.js、JDK、Python 3，以及官方 HarmonyOS Command Line Tools（hvigor、ohpm、SDK/NDK）。SDK 目标以 `cexing/build-profile.json5` 为准，Go 约束以 `core/go.mod` 为准；具体工具组合的通过记录放在 evidence，避免把一次测试版本当成永久下限。

## 工具链

工具链默认位于忽略的 `command-line-tools/`。放在其他目录时设置 `HARMONYOS_CLT_ROOT`，再初始化：

```bash
source scripts/env.sh
node --version
go version
java -version
command -v hvigorw
"$CLT_ROOT/ohpm/bin/ohpm" --version
```

复用 DevEco 安装时核对 bin/sdk/ohpm 的目录布局；不要假设 macOS 安装路径在 Linux 存在。云环境自身的激活命令放在环境配置中，不提交机器绝对路径、账号设置或 SDK 压缩包。下载及授权入口见 [华为官方下载](https://developer.huawei.com/consumer/cn/download/)。

## 构建

```bash
source scripts/env.sh
(cd cexing && "$CLT_ROOT/ohpm/bin/ohpm" install)
bash scripts/build-core.sh
bash scripts/prepare-geodata.sh
python3 scripts/prepare-smart-model.py
bash scripts/build-hap.sh
```

内核生成到 `cexing/entry/libs/arm64-v8a/`；未签名包位于 `cexing/entry/build/default/outputs/default/entry-default-unsigned.hap`。这些文件不入 Git。只改 ArkTS 时可复用同一模块图的内核；依赖变化须重建内核并核对模块元数据。`build-hap.sh` 在资源准备完成后统一执行一次 Hvigor clean；直接构建与 Full 共用此入口，避免打包旧缓存。

`build-core.sh` 使用 OHOS clang，以 `GOOS=android GOARCH=arm64` 和 `netgo ohos cmfa with_gvisor` 构建 c-shared。脚本每次重建 Android 日志 stub，并自动使用构建专用临时模块缓存应用固定 gVisor 的 Fstat 补丁；不修改开发者共享缓存。原理与升级检查见 [平台参考](../reference/platform.md)。

GeoIP 准备脚本每次解析上游 latest 稳定发布，核对公开 SHA-256 与大小；GeoSite 使用固定上游产物及本地分类数据重建，核对输入和输出摘要。构建身份记录各自来源和实际摘要；下载或摘要不符会失败。固定产物不等于完整上游输入可复现，来源限制见 `third_party/geodata/NOTICE.md`。构建检查不能替代实际 HAP 资源检查。

## 回归与产物检查

```bash
source scripts/env.sh
node scripts/test-profile-name.cjs
node scripts/test-vpn-startup.cjs
node scripts/test-app-runtime.cjs
node scripts/test-background-lifecycle.cjs
git diff --check
```

用 ZIP 工具检查 HAP CRC，确认包含 `libmihomo.so`、`libentry.so`、`libc++_shared.so`、`override.yaml` 和 `geodata/geoip.metadb`、`geodata/geosite.dat`；读取包内库的 ELF 架构及摘要。跨编译与 mock 测试只证明各自覆盖的构建/状态机行为，网络与后台运行用 [设备指南](device.md) 验收。

内核脚本在临时缓存中验证原始模块、应用所选 gVisor 补丁，构建后临时还原该文件再次执行完整性检查。旧手动补丁曾改写开发者缓存的环境仍须核对历史差异，或用新隔离缓存验证；不忽略其他依赖完整性失败。固定工具组合、Quick/Full 入口与包内版本/ABI/资源检查见 [CI 指南](ci.md)。
