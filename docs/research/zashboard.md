# Zashboard 嵌入方案

日期：2026-10-12。[源码确认] 最新正式 release 为 `v3.29.1`，SHA `50717b02dac68425cdc5b80cb754bea768ee4fc9`；main 快照另见来源登记。release 的 `src/api/clash.ts` 已核实调用 `GET /group/weights` 和 `POST /cache/smart/flush`。两种 Smart 候选均在 `hub/route/groups.go`、`cache.go` 提供对应端点。

## 资源与服务 [源码确认][待验证]

main 的 `package.json` 是 Vue/TypeScript + Vite，`build` 为 `vite build`，存在字体打包变体；`vite.config.ts` 使用 `base: './'` 和 PWA。正式集成从 release 固定 SHA 获取源码和 lockfile，按该版本 packageManager 执行 frozen install/build，离线方案选择本地字体；main 的构建选项须在 release 上再核对。本轮未安装 Zashboard 依赖或构建前端。

打包路径建议 `resources/rawfile/zashboard/` 或一个有清单的资源包。记录版本、来源、许可证、逐文件摘要；构建后检查 HAP 的 index.html、所有引用 JS/CSS、字体、图标、SW/PWA 资源。解压到应用私有 `filesDir/ui/<version>`，先写临时目录，再原子切换。禁止路径穿越，失败时保留上次资源并提示。

`hub/route/server.go` 由 `SetUIPath` 解析 external-ui，FileServer 服务 `/ui/`；首选 ArkWeb 加载 `http://127.0.0.1:9090/ui/`。无需另外设计 ArkTS HTTP 服务。先验证 UI/扩展共享目录、ArkWeb 回环 HTTP/WS、相对路径与 PWA 缓存更新。

Clash Mi 的 `lib/app/modules/zashboard.dart` 使用另一端口的 Dart HttpServer，并在 URL 查询里传 secret。本项目借鉴资源管理，认证入口需单独设计。

## 认证和生命周期

[源码确认] 当前 CoreApi 无 Authorization header/WS token；平台 Controller 只提供缺省地址，用户配置可覆盖。接入前强制回环绑定并统一端口，生成随机 secret，保存在私有存储，以受控初始化方式交给原生 API 和面板。认证材料不得写入订阅、日志或导航历史；浏览器 WS token 的使用需要明确日志脱敏规则。

Mihomo 的静态 `/ui/` 与受 secret 保护的 API 是不同路由分组，不能假设静态资源也受同一认证保护。ArkWeb 只允许本地受控入口；第三方导航、JS bridge 与持久化 backend secret 的处理需要审查。

页面关闭/销毁不调用 VPN stop；内核停止后页面显示离线，可在重连后恢复。首次无资源、资源损坏、认证错误与 WS 断连分别给可理解的状态。

## 验收 [待验证]

离线启动完整加载；无凭证 API 被拒绝；正确凭证 REST/WS 成功；权重读取与缓存清理正常；切换版本后 SW 缓存一致；退出/重开页面及模拟资源缺失时 VPN 转发持续；订阅重载后 external-ui/secret 保留。P2 完成前不移除原生控制页，保留排障入口。
