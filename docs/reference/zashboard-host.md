# Zashboard 宿主边界

本模块独立于 CoreApi、engine 和 VPN 生命周期。资源准备与页面组件可以独立构建；当前仅登记无会话的封闭导航目的地，不提供进入按钮，不替换 ProxyPage。正式接入需安全线及配置线的契约验收。

## 合流所需最小接口

- 配置线调用 `ZashboardAssets.prepare(context)`，得到 `directory`、`version`、`fallback` 和 `error`。`directory` 非空时恒为 `<filesDir>/ui`，符合安全线固定 external-ui 强约束；必须删除用户提供的 `external-ui-url`，禁止运行时下载。失败且无旧版本时，禁用面板入口并继续 VPN 启动。不要在面板里调用 VPN start/stop。
- `ui/versions/<version>` 是只读完整资源。`ui/index.html` 同时记录 current/previous 和同源跳转目标，单文件原子替换完成切换及回退。旧页面继续使用旧版本相对资源，重开时切到新版本；无需改变内核目录配置或重启。`rollback(context)` 仅切换静态入口并返回版本，调用方更新页面 version。
- 已核对安全线 `docs/reference/controller-security.md`：`CoreApi.getControllerAccess()` 返回内存中的 `{ httpBase, wsBase, secret } | null`，地址为 `http://127.0.0.1:9090` / 对应 WS。资源模块不调用 CoreApi；正式会话适配器应从此接口取得凭据并在受信任前端内存注入/撤销。页面 props 仅接受无凭据 URL 和资源版本，未验证认证前 `authenticated` 必须为 false。禁止导航 URL/query/hash 中传 secret；不能用静态页 200 证明认证。
- 上游默认将 backend/password 存入 localStorage，并用 URL token 建立 WS；正式接入前必须另行完成内存凭据适配、WS 鉴权及撤销、配置重载后凭据保持测试。当前组件不会请求或持有 secret，也不会绕过鉴权。
- 安全线还需在前端执行前配置仅允许实际 Controller HTTP/WS origin 的 CSP/网络约束；ArkWeb 请求回调的 WebSocket 覆盖不应被假定为已验证。任何会话注入机制只能给可信固定资源授权，不能放开外部 backend 或自定义远端脚本。
- 原生页使用独立 ArkWeb；只允许相同回环 origin 的 `/ui/` 文档导航，无 JS bridge、文件访问或弹窗。页面关闭只释放 WebView。未启用组件不能被解释为 REST/WS 已验收。

## 资源事务

从锁定源码和 pnpm lock 构建本地 Fira Sans 字体版，携带许可、图标、PWA 资源和逐文件 SHA-256 清单。资源以内容清单摘要命名私有版本目录；进程内串行，并持有文件独占锁防止跨进程并发铺盘。先写服务目录以外的 staging、逐文件验证，再 rename 到 ui/versions，最后原子替换 ui/index.html。损坏或缺失保留上个校验通过的版本并返回可恢复错误。路径必须为受限相对路径，无绝对路径、空段、点段、反斜线或编码转义；磁盘内容禁止 symlink。

`external-ui` 路径只来自宿主，不能接受 WebView 或用户提供的路径。已有版本在每次使用前复验。完整文件集合校验防止额外文件混入。旧版本不自动删除，以免旧 WebView 的资源目录消失。安全线 `9ecb964` 的整个 UI 树 symlink 扫描会通过 startController → coreStartTun 升级为 VPN 启动失败，这是明确的合流阻塞；须改成拒绝危险静态资源而保留认证 API/VPN，并通过跨线测试。凭据失败仍须拒绝匿名运行。实际核查与安全降级约束见 [合流证据](../evidence/2026-10-12-zashboard-security-convergence.md)。

同一版本的现有目录损坏时，prepare 重新从固定入包资源在服务根外构建并完整校验。只有新副本可用后才把坏目录 rename 到私有 zashboard-quarantine 目录，再发布新目录；发布失败恢复原目录并尝试旧版本。隔离副本不自动删除。平台不支持非空目录交换，因此修复同一路径的两次 rename 之间可能短暂 404，不会暴露半成品；版本选择入口仍为单文件原子替换。此修复不负责安全线的 Controller/VPN 降级。

## Smart 和缓存验收

固定上游 `src/api/clash.ts` 使用 `GET /group/weights`，响应包含 `message` 与 `weights: Record<string, NodeRank[]>`，节点字段 `Name`、`Rank`、`Weight`；清理权重使用无请求体 `POST /cache/smart/flush`。这仅核实前端调用，不证明基线 Mihomo 支持 Smart；本线不换核。

打包检查须核实清单每个资源在 HAP 中且摘要一致。页面采用禁用 HTTP 缓存并显式阻止 service worker 注册的宿主构建，版本切换使用重新创建 WebView；PWA 文件仍入包。正式接入时还需真机验证旧缓存迁移、关闭/重开、离线 REST/WS、无凭据拒绝、正确凭据成功和资源失败不影响 VPN。
