# Zashboard 与 Smart 接入契约

这是现有生产接入的技术契约；构建、宿主回归和真机验收分别记录。历史源码调查和试编译身份见 [来源快照](https://github.com/Starfie1d1272/Cexing/blob/df757138/docs/evidence/2026-10-12-sources.md)。

## Zashboard

从固定源码 SHA 与 lockfile 构建静态资源，使用对应包管理器冻结安装。资源包含本地字体、JS/CSS、图标与必要 PWA 文件；记录来源、许可及逐文件摘要，检查它们实际进入 HAP。

资源铺到私有版本目录：临时写入、禁止路径穿越、完整校验后切换；损坏时保留上一版并显示可恢复错误。现有单 Controller 的宿主路由托管 `/ui/`，ArkWeb 打开回环页面；订阅不能指定 UI 路径或联网更新资源，未增加另一套 HTTP 服务。

现有 Controller 统一回环绑定、端口、随机 secret、原生 REST/WS 与面板认证。静态 `/ui/` 与受认证的 API 是不同路由，不能把静态页可加载当成认证成功。限制外部导航及 JS bridge；密钥不得写入日志、导航历史或公开配置。面板保持既有首次概览及用户偏好；既有 `disableUpgradeCore`、`disableTunMode` 参数保持启用，不推测其他嵌入参数。系统 TUN、启停及核心升级属于宿主边界。服务端拒绝不适合宿主的 `/restart` 和 `/upgrade` 路由树，不能只依赖前端隐藏。

验收离线资源、REST/WS、无凭据拒绝、正确凭据成功、PWA 缓存更新；关闭/重开 WebView、资源缺失及面板错误不影响 VPN；配置重载保留认证与 UI 参数。原生代理组旧页没有生产导航入口；现有面板加载失败/离线状态及原生故障恢复是独立保留的链路。ArkWeb 真机行为按 #92 验收。

## Mihomo Smart

当前 Go 模块替换为锁定的 vernesong/mihomo Smart fork，完整身份以 go.mod/go.sum 为准；四个基础兼容 ABI 与三个生产扩展通过同一 worker。升级重验 gVisor 补丁、模块图和包内 ELF；不能直接复制其他客户端的 `.so`，不同项目可能使用不同 ABI。

模型启动前检查来源、分发许可、摘要与解析结果；原子铺到内核目录，避免首次连接依赖同步联网下载。坏模型应明确拒绝 LightGBM 或提示降级，不能仅检查文件存在。源代码许可证不自动涵盖模型许可。

Smart 由内核 `type: smart` 组执行，原生界面不得强制固定它的节点。`uselightgbm` 是独立能力选择，保留原策略语义。采集、模型选择/更新与组转换使用现有独立设置，不将这些状态等同于预测已参与；实际转换规则以[配置契约](configuration.md)和[Smart 运行边界](smart-beta.md)为准。

验收至少两个有效节点、离线模型加载、规则进入 Smart 组、`GET /group/weights`、`POST /cache/smart/flush`、真实连接链及目标/故障变化下的选择。延迟排序或组名不是预测参与证据，必须观察预测路径。每次升级记录内核/模型组合，保留上一份可重建依赖与用户配置。
