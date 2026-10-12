# PR #9 / #10 合流核查

核查日期 2026-10-12。安全线固定为 PR #9 `9ecb964f319edff6fccfd36d78850c6b8e4fa609`，面板线实现为 PR #10 `264a5a8dd73f76556e752e7d8623710d6c8bc615`。仅只读核查安全源码和锁定上游；未合并、未启用页面、未修改安全线文件。

## 已对齐与缺口

| 边界 | 实际实现 | 合流结论 |
|---|---|---|
| UI 路径 | #9 `enforcePlatformSecurity` 固定 `external-ui=ui`；#10 返回 `<filesDir>/ui`，完整版本在 ui/versions，单文件 ui/index.html 原子选择并同源跳转 | 已对齐；页面 props 的 version 必须与 prepare/rollback 回执一致，版本切换无需重启 Controller/VPN |
| 获取凭据 | #9 `CoreApi.getControllerAccess()` 从私有文件读取并返回 `{httpBase, wsBase, secret}` 或 null；#10 页面只有无凭据 URL、version、authenticated props | 未接通。authenticated 只是渲染门，不能凭 getControllerAccess 非空就当作认证验收完成；需要可信资源校验后的内存注入/销毁协议 |
| 前端保存 | 固定 Zashboard `src/store/setup.ts` 用 useStorage 保存整个 backendList（含 password）；`src/helper/utils.ts` 读取导航中的 secret 并提供 localStorage 备份导入/导出 | 不满足宿主契约。正式适配需只保留单一宿主 backend、内存 secret，禁用 query secret/外部 backend 和含凭据的保存/分享/备份路径。不能直接调用 addBackend 注入真实 secret |
| REST | 上游 axios interceptor 从 activeBackend.password 构造 Bearer；#9 API 要求相同 Bearer | 调用形态兼容，但当前没有注入或 REST 成功/拒绝验证。必须验证 API 401 与静态 UI 匿名 200 的区别 |
| WS | #9 原生 WS 使用 Bearer header；浏览器允许握手 `?token=`。上游 createClashWebSocket 正好从 backend.password 添加 token | 两端协议描述兼容，不等于已接通。浏览器不能直接复用原生 header 代码；需限制同源 WS、每次新连接/重连取得有效内存凭据、屏蔽 URL/异常诊断，销毁页面撤销会话。#10 请求回调是否覆盖 WS 未实测 |
| CSP | #9 只配置 Controller CORS；其静态路由和 #10 资源均未设置 CSP | 缺失。CORS 不阻止页面向外发请求。需在前端执行前施加精确 HTTP/WS origin、脚本/字体/worker 等策略；#10 的入口选择器含 inline script，单独加 script-src self 会破坏跳转，应按实际选择器处理 hash/nonce 或外部受信任脚本 |
| 生命周期 | #9 服务器拒绝 restart/upgrade；#10 禁用 restart 并拦截相关请求，页面关闭仅 stop WebviewController，不调用 VPN | 源码已对齐；真实关闭/重开、WS 断开和配置重载后的认证保持未验证 |
| 资源失效 | #10 digest/全集校验失败会回退或返回空 directory，旧目录不自动删除；#9 扫描整个 ui 树，无逐文件 digest 校验 | **P0 合流阻塞，见下文** |

## 已确认：UI symlink 会阻止 VPN 启动

安全线源码调用链：

1. `core/controller_security.go:193` 的 `validateUIRoot()` 对整个 `<homeDir>/ui` 执行 WalkDir；任意 symlink、特殊文件或遍历错误返回 error。它不区分已选择和未选择版本。
2. `core/controller_security.go:206` 的 `startController()` 原样返回该 error，没有启动受认证 Controller。
3. `core/engine.go:222` 的 `coreStartTun()` 原样返回 startController error，发生在 executor.ApplyConfig 和系统 fd 的 gVisor listener 创建之前。

因此，`ui/versions/<未选择的旧版本>/unused-link` 足以使 VPN start 失败，即使当前选择器和新版本资源完整。这不是待证实的接口假设；源码错误传播已经明确。真机系统后续撤销行为没有在本核查中执行。

隔离复现直接摘取 #9 的 validateUIRoot 原函数，使用 Go 1.27.2、临时目录和合成资源，不链接或启动 VPN。实际输出：

```text
missing UI: accepted
corrupt regular bytes: accepted (no checksum validation)
unselected old UI symlink: controller: UI must contain only app-owned files, no symlinks
```

该复现只验证真实校验函数；`coreStartTun` 的传播由上面的源码链支持，没有声称已执行完整 Controller 或真机 VPN 回归。

## 需要父任务协调的修正与验收

安全线须区分凭据故障与静态面板故障：凭据异常仍拒绝匿名 Controller/VPN；UI 缺失、校验失败或 symlink 则拒绝静态访问、返回 404 并向面板报告可恢复错误，受认证 API 与 VPN 可以继续。不能简单忽略 symlink 错误并继续使用原危险目录，也不能靠删除所有旧目录规避扫描。

不要未经验证地用 `route.SetUIPath("")` 禁用 UI：锁定 Mihomo 的 `hub/route/server.go:101` 会调用 `C.Path.Resolve`，`constant/path.go:80` 把空相对路径解析成 homeDir，反而可能把私有根作为静态根。应显式禁用静态路由或使用受约束的不可用资源根，并确保 ApplyConfig/重载不会重新恢复危险 UI 路径。具体修正由安全线拥有者完成。

合流的最低实际验收场景：UI 完全缺失、当前文件损坏、未选择旧版本含 symlink、ui 根为 symlink/普通文件、铺盘或原子入口替换失败。每种场景要同时证明不返回危险静态文件、API 无凭据仍拒绝、正确凭据仍成功、VPN 初始化不因为 UI 状态失败；正常版本与回退后的 HTTP/WS、页面关闭/重开及 CSP 限域另行验证。

本次只补核查文档。入口保持关闭；内存凭据适配、CSP、跨线故障回归和真机验收均未完成。
