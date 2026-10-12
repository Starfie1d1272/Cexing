# 完整首测集成证据（2026-10-12）

## 输入和边界

main `da622b707d3dc2ed6676e53f5d4baa1587b8ab7b`；Controller #9 `1b23e76297d51212b250da85b7375dd7fdab1c1b`；原生 UI #15 `0ff4dbca673a3d19074bf8dee954bb3c5007a836`；Smart #16 `87baaace2bb227d35d8487bd992a7d66c97f86e4`；面板 #17 `a6c70d724af51458e426852f37b9e01016884964`。旧 owner 未推送的 WIP 未采用，按可读远端重建，Draft PR #18。

新的合流保留 Home/Index 的 rootVisible、profileRevision、诊断和面板 onShown/onHidden。Smart 页面复用 CoreApi Bearer，选择/有界读取二进制文件上传，区分加载与预测次数，显示官方模型获取入口；重启使用应用级 ApplicationContext.restartApp，取消恢复、结束 VPN、等待 Controller 退出、flush 会话断开标记和释放后台资源。四 C ABI 不变。

模型不在仓库/HAP内，首版由用户从官方 Release 下载并导入。名称未定，保留现有身份；Hokit 本地签名安装，云端没有设备、凭据或商店操作。Mihomo inherited race 后续跟踪，未抑制测试、未声称并发问题全修复。

## 实際检查

Linux 环境，官方 CLT 26.0.0.851/API 26，Go 1.27.2、Node 26.11.1、JDK 27。

- `3399672` 代码初轮联合核心、SDK clean HAP：33 tasks/33 executed，CRC、ARM64/四 C ABI、fresh core→strip→HAP、模块图与源码身份、全部 rawfile/46 个面板资源通过。初轮产物不能代替最终 main 构建。
- 实际 SDK transpile 回归覆盖原生页面、Profile、Controller REST/WS、恢复、后台生命周期、Smart 短读/关闭/隐藏回调、二进制 Bearer 上传与应用重启失败/超时。
- 实际 Go Controller + 构建的面板 + Chromium 通过认证 REST/流量 WS、匿名拒绝、CSP HTTP/WS/inline-script/worker 拒绝、重载、实际服务重启后的 WS 重连、撤销/重进和服务停止。不是 ArkWeb/TUN 验收。
- `scripts/test-smart.sh` 使用自行从官方 Release 获取的固定 Model.bin：30 特征，PredictSingle=0.920044907231；12 个实际 mixed HTTP 请求均通过 local-a，10 次有效模型预测；停止 a 后测试报告 recovered=6、b 接受6。这是一次 Linux 测试结果，不表示手机或无损切换保证。此前独审测试仅完整5/6也保留其范围。
- 模型状态/原子导入/错误与匿名认证、bridge缺符号失败清理、真实 parser/router、配置流水线、module verify 同脚本通过。模型文件只在忽略的临时目录，未复制进 rawfile/HAP。

## 保留的失败及独审

初次面板资源重建因缺少锁定 pnpm 11.20.0 失败，安装仓库锁定 scripts/ci 工具后，同一46文件摘要重建通过；未改资源锁。

新独审对 `3399672ba9e6ee25c9d73b44830f3dba9360abb8` Smart/UI/应用重启范围通过，但整体 REQUEST_CHANGES：两类 provider 的 Type/Path 大小写别名绕过初版检查，ui/model宿主路径也未保护。定向实际parse复现8个候选，不写凭据。原有Controller suite全部通过未发现这些旁路，不能把既有绿测试当成安全证明。修复与最终增量独审见 PR #18；未经复审不合主线。

SDK 首轮保留警告，未隐藏；真实Controller测试一次因并行占9090而失败，释放端口重跑通过。日志只用合成节点/临时随机测试凭据，证据不打印凭据值。

## 手机待验收

Hokit签名/系统VPN授权、原有订阅与实际节点转发、ArkWeb文档注入/CSP/缓存/隐藏/返回、应用级重启后VPN Extension进程换代、TLS/REALITY、DNS/UDP、IPv6、网络切换、息屏与后台。最短流程见 [设备指南](../../how-to/device.md)。Linux/Core/浏览器/SDK结果不代替这些验收。
