# 2026-10-12 ArkTS 原生页面落地证据

已确认首页基准：PR #11 的 `0974f9dd021130fe2b17554af773db554d05ddb5`；工具页一致性基准：`8131567d44ce02f9af3b149c5eb83c9cf238d93c`。基于 main `da622b707d3dc2ed6676e53f5d4baa1587b8ab7b`，原生代码提交 `cc387cf0ab90c341e09cc6981f268bd1ab5a680c`。紧随其后的 `21865e1` 仅补文档及产物身份；独立审核发现的两项修正与新包身份另见 [审核修正](REVIEW-FIXES.md)，初轮证据保留。

## 交付与文件边界

修改 ArkTS `pages/Index、Home、Profile、ProfileEdit、Settings、NetworkSettings、Override、Proxy`；新增 `NativeTheme`、`DiagnosticsPage` 和 `scripts/test-native-ui.cjs`。HTML 原型未修改。`Index` 是路由/状态提供者协调点；`HomePage` 是面板入口协调点。Zashboard 路由及现有门禁保留，节点入口仍调用现有 `ProxyPage`/`CoreApi`。未修改 `lib/`、Go/C++、模型、面板实现、配置流水线、凭据、身份或依赖声明；构建只是生成忽略的资源和内核库。

- 保留原生三页签“连接 / 订阅 / 设置”；详情、编辑、诊断、网络、内核设置使用 Navigation 栈。
- 原生 Polygon 组成白色状态场、灰黑静态斜面和青色接缝，速率归黑色数据带；工具页采用轻盈圆角、短文字与克制小符号。无大连接图标、堆叠说明或装饰动画。
- 首页接现有状态、WS 流量与模式 API；离页/二级导航仅释放展示 WS，超过 4 秒没有新样本清空速率，页面销毁不停止 VPN。断开需要原生确认并复核实时状态。
- 订阅保留 URL、文件、剪贴板与手动 URL/YAML 粘贴、激活、更新、重命名、编辑、另存、导出及删除。导入成功可确认启用或稍后启用；URL 失败保留输入。页面修订信号同步列表/详情/当前订阅，不改存储格式。
- 删除入口/确认用红棕错误色。运行中的当前订阅要求先手动断开；保留现有状态 API，不在此引入自动停止后删除的异步事务。此行为与浏览器原型不同。
- 设置采用原生开关/选择，间隔 14fp/48vp；网络页可滚动。内核参数在明确保存时校验端口，非法值保留输入、不写入默认值；提示下次启动生效。Merge YAML 仍由配置线接入，本页不假装实现它。
- 诊断只做现有 `/version` 控制面探活，迟到结果过滤；系统会话与真实转发明确为待设备验证。没有假冒网络健康、分享日志或模型预测结果。

## 实际检查与保留失败

Linux 云环境，官方 CLT 26.0.0.851 / SDK API 26，Node 26.11.1 / Go 1.27.2 / JDK 27；最低兼容 API 21 未经设备验证。

1. 首次 `build-hap.sh` 失败：已有 Zashboard rawfile/manifest 缺失。使用仓库 `scripts/ci/prepare-zashboard.sh` 与其要求的 pnpm 11.20.0 恢复锁定资源；清洁源码、host.patch、manifest/ZashboardPin 未变化。没有把面板资源修改混入本 PR。现有 CI toolchain 的 pnpm 10.28.2 与面板脚本要求 11.20.0 不一致，本轮不修改 CI/面板线约束，也不声称 Full CI 通过。
2. 初次 ArkTS 编译失败：Select 未显式声明选项类型、误用 `.fontSize` 以及不存在的 `slider_horizontal_3` 符号。改为 `SelectOption[]`、`.font({size:14})` 和 SDK 已有 `slider_horizontal_2`；SDK 编译通过。
3. 首次 HAP 身份检查失败：复用旧内核库的 `github.com/ajg/form` 模块与 main 不一致。重新执行仓库 `build-core.sh`，隔离缓存中的原始模块与 gVisor 补丁检查通过，再 clean 与构建。旧失败包不作为交付物。
4. 页面行为回归首跑失败：测试移除装饰器的表达式误处理了 import 中的 `@kit`，缺少 `.ArkUI` mock。修正测试只处理装饰器行；实际源码逻辑回归通过。
5. 通过：页面行为回归（陈旧流量、切页/二级导航展示资源、断开取消/迟到确认、离页不停止 VPN、诊断迟到结果、非法端口、导入重试/启用确认、当前订阅删除保护）；profile-name、vpn-startup、app-runtime、background-lifecycle、runtime-recovery-integration 六个 SDK 编译器驱动的脚本。

`test-native-ui.cjs` 只运行从真实页面截取的非 Builder 逻辑，SDK TypeScript 转译和 mock API 不代表 UI 渲染或设备行为；完整 ArkUI Builder/API 由实际 HAP 编译检查。底层四项 C ABI 保持不变。最终 33 个构建任务（32 执行/1 缓存）成功；128 条 SDK 警告包含既有废弃 API/最低兼容 API 差异，未删检查或压制警告。最终包检查与摘要见 [build-identity.json](build-identity.json)。HAP、SDK、原生库与签名材料不入 Git。步骤结果及截图摘要见 [validation.json](validation.json)。

## 截图身份

已实际查看并用于原生翻译的参考图，均为 PR #11 提供的**既有 Chromium 浏览器原型截图**，此处只按原字节复制，不是本 PR 原生截图，也不是新一轮浏览器渲染：

- [确认首页，390×844](screenshots/browser-baseline-home.png)：`connection-planes/screenshots/after/connected-390x844.png`，固定首页基准。
- [设置，390×844](screenshots/browser-baseline-settings.png)：`page-consistency/screenshots/after/settings-390x844.png`，8131567 工具页基准。
- [订阅详情，390×844](screenshots/browser-baseline-profile.png)：`page-consistency/screenshots/after/profile-390x844.png`，8131567 工具页基准。

云环境没有已授权的原生渲染设备或模拟器。本轮**没有实际原生运行截图、没有手机运行/转发通过结论、没有完成逐像素原生对照**。文字字号、导航安全区、原生系统控件和大字号布局需按[设备清单](DEVICE-CHECKLIST.md)验收；SDK 编译成功不代替这些检查。

## 集成与独立审核交接

Draft PR，不自审、不自合、不正式发布。当前环境没有 `cloud_threads.send_message` 可调用能力，未能直接向集成线程 `01a131b6-b0b9-717b-bc7a-41937affc0a5` 投递边界；PR 记录 `Index/Home` 协调点，父会话可转交。

面板仍由它的 session/认证门禁控制，Smart 模型与预测、统一配置事务均由各线完成。当前包是可本地签名测试的原生宿主候选，不是所有技术线已验收的完整发布版。新独立 reviewer 应检查上述协调点、Profile 导航/修订传播、真实状态展示与设备清单；本轮作者检查仅为实现验证，不算独立审查。HoKit/Hokit 签名、安装、系统授权、截图及 TUN/后台行为留给明早本地设备验收。

未签名 HAP SHA-256：`d89902888c1531e098ef01f9da2e40a75841422c3a94bdbdfdafe75837da7283`。测试包尝试保存到 Library，helper 鉴权 HTTP 401；依据授权原样重试一次仍失败，上传停止且无已保存文件结论。包只保留在本云工作区，不创建公开 Release/附件；本地下载交付需恢复授权。
