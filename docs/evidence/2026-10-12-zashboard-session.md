# 2026-10-12：首个测试版 Zashboard 会话接入

## 身份与边界

运行代码 commit `839de5c8c85bf82305c1c6ebe887ecb1d2bfb113`，tree `3bcc186b6ff0e06040405a7d7136cb848ec2d32b`。集成基线为 main `da622b7`；本地组合 Controller 安全线 PR #9 的 `1b23e76297d51212b250da85b7375dd7fdab1c1b`，组合 commit `d8a7d27`。没有合并远端 PR，没有更换 Go 依赖或四 C ABI。

只处理 WebView/controller adapter 与必要入口接线，不处理样式、Smart 或模型。公共接线文件是 CoreApi、ClashVpnAbility、HomePage、Index；新增 ZashboardSession，修改 ZashboardPage 与固定上游 host.patch/生成资源身份。环境和仓库没有可读的 `.agents/skills` 文件；已读取 AGENTS、架构、构建、组件/Controller/面板契约。

环境为 Debian 13 x86_64。官方 CLT 26.0.0.851，SDK 26.0.0.105/API 26，Go 1.27.2、Node 26.11.1、JDK 27；上游包管理器保持 pnpm 11.20.0。浏览器为 Chromium 154.0.8037.57，使用环境已有 Python Playwright。所有测试使用独立临时沙箱、生成的测试凭据和合成 DIRECT/REJECT 策略组；不创建系统 TUN、代理监听或 DNS 服务，不操作用户系统网络、设备、凭据或签名。

## 实际验证

- `scripts/ci/prepare-zashboard.sh` 从全新固定 SHA checkout 构建，得到 46 文件、5,822,883 B；与已提交 manifest/Pin 完全相同。版本 `e91b122ae0c2fa3882e22ab02775cb79b87a12a2f48dad8b9a94f35f053f2128`，manifest SHA-256 `fb0b09e54b1af89b4a49a8c05ffc98e6fd6a4d32d4091f5803be17a1d7be8e1a`，host.patch SHA-256 `c9205fb8a72a5dec1d95b98f5abf9b4d9fbec3d69d7ea2ddc043dde9331c88ea`。
- 全部 `scripts/test-*.cjs` 使用实际 SDK 的转译器执行，通过。包括页面代次、认证失联/恢复、拒绝旧版资源注入、迟到异步结果、停止后的重试清理；扩展在资源不可用时仍可初始化并报告内核就绪。系统 API 使用 mocks，这些断言不证明原生 ArkWeb 行为。
- `go test ./...` 完整功能回归通过：core 与 configpipeline。未宣称 race 通过。资源 source gate、tracked source 检查、`git diff --check` 和官方工具组合检查通过。
- `scripts/test-zashboard-browser.py` 启动真实 Go Controller，服务真实构建资源，用 SDK 转译后的 ZashboardSession.bootstrap 注入。真实页面加载 Local test 策略组，实际 REST 请求携带 Bearer，实际流量 WS 接收数据；匿名 REST 401，匿名 WS 失败，正确凭据 WS 接收流量数据；服务器拒绝 restart 405。
- 同一浏览器中，CSP 实际拒绝外部 HTTP、外部 WS 与 inline script；显式 service worker 注册失败且没有注册项。受认证重载成功且认证保持。真实 Controller 停止/重新初始化后，原页面 WS 创建新连接并恢复数据；撤销后没有新 socket，关闭/重新进入页面重新取得内存会话；最后实际关闭 Controller。
- bootstrap 在模块执行后不存在，展示/导航 URL 与 localStorage/sessionStorage 中没有测试 Secret；Controller 日志没有测试 Secret。浏览器 WS 按上游契约使用 token 查询，可能被浏览器内部诊断显示；脚本不保存完整 console/URL/网络 trace。ArkWeb 的 onConsole 消费及默认禁用调试必须在手机验证，不能把 Chromium 结果外推。
- 从上述已提交代码重新 ARM64 编译，然后 `hvigorw clean --no-daemon` 和 `scripts/build-hap.sh`；官方 SDK ArkTS/NAPI/原生打包成功。`verify-hap.py` 通过未签名 HAP CRC、60 ZIP entry 的摘要、46 项 Zashboard 资源、fresh core → strip → HAP 一致性、ARM64/C ABI、应用和依赖身份。存在现有 deprecated/API 26 与 compatible API 21 警告，未证明低版本运行行为。

构建身份与逐 entry 摘要见 [实际构建报告](zashboard-session/2026-10-12-build-identity.json)。未签名 HAP SHA-256 `f103cdb5f1c86cfeca43519941923f8d3831f08ab45fedda652e9a121396b244`；fresh libmihomo SHA-256 `c640b1acc753bf4a4075d277c0d06051b8a43a1db536fecaa068e62edee6b960`。二进制留在忽略的构建输出，未提交、上传或发布。报告记录的是运行代码 commit，之后仅新增本证据，不改变应用输入。

## 保留的失败

1. 初次 pnpm 安装使用默认 home cache，因环境该目录不可写而 ENOENT；改为独立可写 XDG 测试缓存后构建成功，没有修改 SDK或依赖。
2. 新增资源准备后，原 VPN startup mock 缺少 ZashboardAssets 模块而真实失败；增加缺失模块，并断言准备顺序和资源失败不阻止内核就绪后通过。
3. 初次合成浏览器 fixture 将 MATCH,DIRECT 写成两个 YAML rule，解析验证真实失败；将合成用例修正为一个 rule 后继续，没有削弱平台校验。
4. 第一版实际页面没有流量 WS。固定依赖 reconnectingwebsocket 1.0.0 不支持 URL-provider function；这不是认证成功。改用具有代次/撤销/有界重试的原生 WebSocket 后，实际页面流量和真实服务重启恢复才通过，未升级依赖。
5. 未提交新 manifest/Pin 时，fresh preparation 的 Git diff 门禁按预期失败；提交新 host patch/身份后，从全新源码重建并与已提交清单完全匹配。

## 未验收与合流门槛

PR #9 的完整 race 仍有已记录的上游 resolver/hosts/IPv6、入站前缀及解析期间 live 状态竞争；本线不修复或抑制，不能据此合流为并发安全首测版。详见安全线的 [race 边界](controller-security/2026-10-12-race-boundary.md) 和 [上游调查](controller-security/2026-10-12-upstream-reload-review.md)。

没有运行原生 ArkWeb 或鸿蒙手机。手机专属待验收：Hokit 本地签名安装；文档开始注入时序和准确版本保护；HTTP/WS+CSP 与外部导航阻断；onConsole/调试/日志不暴露 token；导航隐藏、返回、重新进入、页面错误/渲染进程退出及失联恢复；旧 service worker/cache 的迁移；资源失败只影响面板；VPN 实际转发和后台/系统生命周期。安全线启动时静态根不可用的快照须经下一次原生 Controller 初始化恢复，页面不会自动停止/重启 VPN。

保留 ProxyPage 源码到首次 ArkWeb 真机验收；真实入口已切到面板。只开 Draft PR，交新独立 reviewer；不自审、不自动合并，不签名安装设备或正式发布。

## 官方来源

[OpenHarmony Web 属性](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-arkweb/arkts-basic-components-web-attributes.md) 的 document-start 说明与环境 SDK ScriptItem 声明核对：注入早于页面 JS、scriptRules 匹配 origin，故另外检查固定 top-level pathname。[Mihomo API](https://wiki.metacubex.one/en/api/) 的 Bearer 契约与固定模块真实 router 对照；浏览器 token WS 的行为以固定模块和实际握手验证。[CSP Level 3](https://www.w3.org/TR/CSP3/) 的 connect/script/worker 限制由真实 Chromium 拒绝测试支持。
