# Zashboard 宿主边界

资源部署独立于 Controller/VPN；`ZashboardSession` 和 `ZashboardPage` 负责页面授权与展示生命周期。原生连接页提供实际面板入口，只有 Connected、受认证 Controller 会话、可用静态根和当前固定资源全部成立时才创建 WebView。代码依赖 Controller 安全契约；首次测试版的 ArkWeb 真机验收仍须完成。

## 会话与授权

- VPN Extension 在初始化内核前调用 `ZashboardAssets.prepare(context)`。失败返回可恢复错误，不能阻止认证 API/VPN 启动；持久化投影的 external-ui 固定为 ui，运行态 ExternalUI 清空以禁用上游下载器；宿主 SetUIPath 只指向验证后的私有根，禁止联网下载。页面不调用 VPN start/stop。
- `CoreApi.getControllerSession()` 读取受认证 `/ohos/session` 的非敏感代次，`getControllerUiStatus()` 区分静态资源可用性。静态 `/ui/` 的 200 不能建立面板授权。页面只接受当前 `ZASHBOARD_VERSION`，旧版回退资源可保留给宿主，但不接收本版凭据注入。
- `javaScriptOnDocumentStart` 在前端 JS 之前运行；脚本规则限固定 Controller origin，脚本另行检查 top、准确版本路径和无 query。密钥只放入一次性、非枚举 bootstrap；前端模块立即删除该入口并清空 bootstrap 对象，将密钥保留在闭包。没有原生 JS bridge、URL/query/hash 凭据、后端密码编辑器或持久化后端列表。
- 前端 REST 仅对受控相对路径添加 Bearer，固定 base origin；浏览器 WS 按锁定 Controller 的 token 查询契约握手，每次重连从内存读取。定时器和 socket 由宿主适配器持有，撤销后关闭已有 WS、取消重试并中止 HTTP。原生 `StreamWatcher` 仍使用 Authorization header。后端展示对象 password 恒为空，不包含真实凭据。
- 构建后的 HTML 在任何页面脚本前声明 CSP：脚本仅同源、不允许 inline/eval；connect 仅固定 Controller HTTP/WS；禁止 worker/frame/object、远程字体/图片及表单导航，referrer 为 no-referrer。Vue 的动态样式需要 style unsafe-inline；该许可不用于脚本。service worker 不自动注册，worker CSP 也拒绝显式注册。固定构建内的本地字体与资源不依赖外部 CDN。
- ArkWeb 禁止文件、数据库、混合内容、弹窗和外部文档导航；保留本地展示偏好所需的 DOM storage。`onConsole` 消费控制台消息，不将浏览器错误对象或带 token 的 WS 诊断写入宿主日志。浏览器内部开发者诊断可能含 WS token URL；不能打开调试/导出完整网络追踪。手机上此回调和默认关闭的调试行为仍须验收。

## 概览与城市定位

首次默认分离概览，面板根路径进入概览；用户已关闭分离概览时保留原代理组入口。全球连接视图默认星空。沿上游 `useStorage` 默认值与路由实现，已有分离概览/星空偏好不覆盖。

上游全球连接的城市数据库使用独立 DB-IP City Lite MMDB，由 Web Worker 读取 IndexedDB 并按需下载；它不是内核路由用的 `geoip.metadb`。离线宿主维持 `worker-src 'none'`、固定同源联网范围和 ArkWeb 数据库禁用，不启动无法完成的城市库检查，明确显示离线城市定位暂不可用并保留全球视图背景及其他连接功能。页面不会把远端失败或未执行检查显示为数据库已就绪，也不提供无效的重试下载动作。

[DB-IP City Lite](https://db-ip.com/db/download/ip-to-city-lite) 使用 CC BY 4.0，要求数据来源署名及使用结果页面链接。当前面板不内置该数据库；若后续分发，须独立固定来源/摘要、归属声明、大小预算和符合现有离线边界的数据读取方案。

## 主题

宿主 Web 显式使用 `WebDarkMode.Auto`，让 ArkWeb 的 `prefers-color-scheme` 与宿主/系统主题一致；加载背景使用原生主题资源。保留锁定上游的自动主题（默认开启）与媒体查询监听，不启用强制网页反色，也不注入脚本或改写本地主题偏好。面板自动主题开启时随系统实时切换；用户在面板设置中关闭自动主题后，以面板选择的主题为准。宿主标题栏继续跟随系统。

## 页面生命周期

关闭、隐藏导航目的地或重新打开时停止页面会话观察、撤销前端资源并释放 Web 组件；不停止 VPN 或后台任务。异步探活按页面代次过滤，关闭后的迟到结果不能重新授权。每三秒串行探测，失联立即撤销，恢复后重新验证资源并创建新 WebView；Controller 换代也重建页面。页面错误和渲染进程退出可手动重开，提示不打印原始 URL/错误。

生产导航使用 Zashboard，旧原生代理页没有导航调用；面板错误恢复直接由 ZashboardPage 和原生连接/诊断入口承担。不能把 Chromium、SDK 编译或 host mock 当作手机验收；当前证据见 [测试版接入证据](https://github.com/Starfie1d1272/Cexing/blob/df757138/docs/evidence/2026-10-12-zashboard-session.md)。

## 资源事务

从锁定源码和 pnpm lock 构建本地 Fira Sans 字体版，携带许可、图标、PWA 资源和逐文件 SHA-256 清单。资源以内容清单摘要命名私有版本目录；进程内串行，并持有文件独占锁防止跨进程并发铺盘。先写服务目录以外的 staging、逐文件验证，再 rename 到 ui/versions，最后原子替换 ui/index.html。损坏或缺失保留上个校验通过的版本并返回可恢复错误。路径必须为受限相对路径，无绝对路径、空段、点段、反斜线或编码转义；磁盘内容禁止 symlink。

`external-ui` 路径只来自宿主，不能接受 WebView 或用户提供的路径。已有版本在每次使用前复验。完整文件集合校验防止额外文件混入。旧版本不自动删除，以免旧 WebView 的资源目录消失。安全线 PR #9 已将危险静态资源降级为 404，保留认证 API/VPN；重载、停止与旧会话资源回收受宿主 Controller 生命周期保护，相关行为由真实 REST/WS 回归验证。凭据失败仍须拒绝匿名运行。实际核查与安全降级约束见 [合流证据](https://github.com/Starfie1d1272/Cexing/blob/df757138/docs/evidence/2026-10-12-zashboard-security-convergence.md)。

同一版本的现有目录损坏时，prepare 重新从固定入包资源在服务根外构建并完整校验。只有新副本可用后才把坏目录 rename 到私有 zashboard-quarantine 目录，再发布新目录；发布失败恢复原目录并尝试旧版本。隔离副本不自动删除。平台不支持非空目录交换，因此修复同一路径的两次 rename 之间可能短暂 404，不会暴露半成品；版本选择入口仍为单文件原子替换。此修复不负责安全线的 Controller/VPN 降级。

## Smart 和缓存验收

固定上游 `src/api/clash.ts` 使用 `GET /group/weights`，响应包含 `message` 与 `weights: Record<string, NodeRank[]>`，节点字段 `Name`、`Rank`、`Weight`；清理权重使用无请求体 `POST /cache/smart/flush`。当前锁定 Smart fork 提供相同接口，前后端均通过真实核心 API fixture；仅有接口响应仍不证明模型参与预测，需另核模型/真实转发证据。

打包检查须核实清单每个资源在 HAP 中且摘要一致。页面采用禁用 HTTP 缓存并显式阻止 service worker 注册的宿主构建，版本切换使用重新创建 WebView；PWA 文件仍入包。真机仍须验证旧缓存迁移、关闭/重开、离线 REST/WS、无凭据拒绝、正确凭据成功和资源失败不影响 VPN。
