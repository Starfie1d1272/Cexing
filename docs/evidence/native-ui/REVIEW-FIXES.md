# PR #15 独立审核后最小修正

原 reviewer：`01a13208-33c2-72cb-a13a-8cd25f63109e`。固定修复前 head `21865e1331e8fe8b6e41499b1d174e4292e5f90b`；修复代码提交 `ef6a819c484eb4d2394cb67146a4d023b9381c8e`。本轮只修改 HomePage 和实际页面逻辑回归，另补证据与设备清单；视觉构图、布局、颜色、文案与其他技术线均保持。

## P1：旧断开确认不能停止新会话

此前确认仅检查当前状态仍为 Connected；断开再连接后状态重新相同，旧闭包会停止新会话。修正使用一个页面内确认世代计数：订阅的状态事件、离开页签/根页面、销毁/重新出现均使其失效；打开新确认替换旧确认。确认动作同时要求世代匹配、页面/根页面/连接页签仍可见及 Controller 状态仍 Connected。取消或成功确认立即作废，不接受重复回调。不改 Controller/API 或引入共享会话基础设施。

固定旧源码经 SDK TypeScript 转译运行真实非 Builder 页面逻辑：打开确认 → Disconnected → Connecting → Connected → 执行旧确认，实际 stop count=1，期望0，**失败 exit 1**。修复后同一复现 stop count=0，**通过 exit 0**。新增切页返回、二级页隐藏返回、销毁再出现、取消后迟到确认均无效；当前有效确认只停止一次，页面销毁不停止 VPN。

## P2：配置存在状态与显示名分离

`hasProfile` 根据现有 getActiveFile 返回值是否为空设置；显示名只负责显示。首页空态及主操作条件都读取该标记，合法 `未导入.yaml` / `未导入.yml` 不再匹配空配置 UI。未新增存储格式或配置解析。

同一旧源码复现中，合法文件显示名为“未导入”，此前独立存在状态 undefined（期望 true），**失败**；修复后 true，空选择为 false，**通过**。此测试与原先的显示名分支源码证据说明错误来源，不声称进行了原生画面渲染。

## 检查与复现

- 六项 SDK 编译器驱动回归：native-ui、profile-name、vpn-startup、app-runtime、background-lifecycle、runtime-recovery-integration 通过。
- 官方 API 26 SDK 未签名 HAP 构建：33 tasks，17执行/16缓存；128条 SDK 警告保留。
- 新包 CRC、ARM64、四个 C ABI、当前新内核身份、全部 rawfile 哈希与46个锁定面板资源通过。详情见 [产物身份](review-fixes-build-identity.json) 和 [前后复现记录](review-fixes-validation.json)。

在按[构建指南](../../how-to/build.md)激活 SDK 后，`node scripts/test-native-ui.cjs` 跑完整页面回归。针对性前后复现接受导出的固定源码目录作为第一个参数、`review-repro` 为第二个参数：

```bash
node scripts/test-native-ui.cjs /path/to/exported-source review-repro
```

先将 Git `21865e1` 的 pages 目录导出到独立临时目录，预期两项 FAIL 与 exit1；修复后的源码目录预期两项 PASS 与 exit0。测试执行真实页面逻辑及 mock 状态事件；HAP 编译验证 ArkUI API/Builder，不替代原生设备截图。

新 HAP SHA-256：`b8cb8ea755bdedc211b8cae00ff2f44c484411525c3e89e7f2e4819c0f1cd370`。本轮未签名、未操作设备、未新增原生截图；原有截图仍仅是浏览器原型参考。此前 Library 保存已在鉴权401和一次原样重试后停止，本轮未绕过授权重新上传。新包保留在云工作区。

PR 保持 Draft，待原独立 reviewer 复审，不自审、不自合、不发布。云环境仍无 cloud_threads.send_message，可由父会话把新 head 与此证据交回原 reviewer。
