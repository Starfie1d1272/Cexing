# Zashboard 宿主边界

本模块独立于 CoreApi、engine 和 VPN 生命周期。资源准备与页面组件可以独立构建；当前仅登记无会话的封闭导航目的地，不提供进入按钮，不替换 ProxyPage。正式接入需安全线及配置线的契约验收。

## 合流所需最小接口

- 配置线调用 `ZashboardAssets.prepare(context)`，得到 `directory`、`version`、`fallback` 和 `error`。`directory` 非空才可生成强约束 `external-ui`；必须删除用户提供的 `external-ui-url`，禁止运行时下载。失败且无旧版本时，省略 UI 参数并继续 VPN 启动。不要在面板里调用 VPN start/stop。
- 资源选择记录与内核使用的配置分开。切换记录不会改变运行中的内核；将返回目录通过配置事务采纳。回退也须由配置事务采纳 `rollback(context)` 返回的目录，不能直接重启内核。
- 安全线提供无凭据的 `http://127.0.0.1:<实际端口>/ui/` 和内存会话注入/撤销机制；统一原生 REST/WS 与面板认证。页面 props 仅接受 URL 和资源版本，未验证认证前 `authenticated` 必须为 false。禁止 URL/query/hash 中传 secret；不能用静态页 200 证明认证。
- 上游默认将 backend/password 存入 localStorage，并用 URL token 建立 WS；正式接入前必须另行完成内存凭据适配、WS 鉴权及撤销、配置重载后凭据保持测试。当前组件不会请求或持有 secret，也不会绕过鉴权。
- 安全线还需在前端执行前配置仅允许实际 Controller HTTP/WS origin 的 CSP/网络约束；ArkWeb 请求回调的 WebSocket 覆盖不应被假定为已验证。任何会话注入机制只能给可信固定资源授权，不能放开外部 backend 或自定义远端脚本。
- 原生页使用独立 ArkWeb；只允许相同回环 origin 的 `/ui/` 文档导航，无 JS bridge、文件访问或弹窗。页面关闭只释放 WebView。未启用组件不能被解释为 REST/WS 已验收。

## 资源事务

从锁定源码和 pnpm lock 构建本地 Fira Sans 字体版，携带许可、图标、PWA 资源和逐文件 SHA-256 清单。资源以内容清单摘要命名私有版本目录；进程内串行，并持有文件独占锁防止跨进程并发铺盘。先写 staging、逐文件验证，再 rename，最后原子替换 active 记录。损坏或缺失保留上个校验通过的版本并返回可恢复错误。路径必须为受限相对路径，无绝对路径、空段、点段、反斜线或编码转义；磁盘内容禁止 symlink。

`external-ui` 路径只来自资源模块，不能接受 WebView 或用户提供的路径。已有版本在每次使用前复验。完整文件集合校验防止额外文件混入。旧版本不自动删除，以免运行中的 external-ui 指向消失目录。

## Smart 和缓存验收

固定上游 `src/api/clash.ts` 使用 `GET /group/weights`，响应包含 `message` 与 `weights: Record<string, NodeRank[]>`，节点字段 `Name`、`Rank`、`Weight`；清理权重使用无请求体 `POST /cache/smart/flush`。这仅核实前端调用，不证明基线 Mihomo 支持 Smart；本线不换核。

打包检查须核实清单每个资源在 HAP 中且摘要一致。页面采用禁用 HTTP 缓存并显式阻止 service worker 注册的宿主构建，版本切换使用重新创建 WebView；PWA 文件仍入包。正式接入时还需真机验证旧缓存迁移、关闭/重开、离线 REST/WS、无凭据拒绝、正确凭据成功和资源失败不影响 VPN。
