# PR 11 原生 UI 设计复审

2026 年 10 月 13 日，基于 main **81215c5f5bc10c04f382d526e1b03d6484b26151**。PR #11 最终基准为 **8131567d44ce02f9af3b149c5eb83c9cf238d93c**，其中首页冻结在 **0974f9dd021130fe2b17554af773db554d05ddb5**。

**结论：主要信息架构与首页构图已通过 PR #15/#18 进入 main，但尚不能称为完整设计验收通过。** 当前存在实际配置与运行状态不一致、更新热重载失败反馈缺失、离页启动错误遗漏；悬浮导航、速率排版和工具页响应式也有源码可确认的偏差。保留 PR #11 开放，关闭条件见文末。无需重新设计整套 UI，也无需合并 260 个原型文件。

本次只读生产 ArkTS、关联库和配置入口。新增内容仅是本目录报告、可复现审查脚本和结果。没有设备操作、原生运行截图或新的 HAP 构建；下述 A 表示源码契约相符，不表示已通过真机视觉验收。已有 SDK 编译/历史联调与手机验收是不同证据。

## 设计历史与准确继承关系

| PR 11 提交 | 作用 | 本轮验收地位 |
| --- | --- | --- |
| `4cfbd25` | 全新移动宿主原型 | 起点；不是最终视觉 |
| `f577138` | 固定三页签、压缩连接状态 | 流程和导航契约继承 |
| `9127864` | 原生轻盈浅底、圆角、窗口适配 | 工具页冻结基础 |
| `ce5789e` | Ark 装饰细节试稿 | 明确不采用；不要求复原符号、短杠和装饰 |
| `7c58539` | 状态和速率收为主卡、原创连接图形 | 构图迭代历史 |
| `3f5e300` | 薄壁端口与层次精修 | 被最终静态块面替代；不要求大端口图形 |
| `0974f9d` | 移除独立大图标，白场、灰黑斜面、青色接缝、黑速率带 | 最终确认首页 |
| `8131567` | 首页不变；间隔选择器 14px/48px；删除使用 #923f2e | 最终工具页修订 |

[PR #6][pr6] 是独立探索，已关闭且未合并；PR #11 从旧 main `7f731d5` 独立开始，并非 PR #6 的延续实现。[PR #11][pr11] 有 8 个提交，最终运行入口 [page-consistency/index.html][design-index] 实际依赖 `baseline-9127864/styles.css`、`native-light.css`、`app.js`，再加载 `connection-planes/home.css/home.js` 和 `consistency.css`。因此不能用根目录评审页默认候选或 ark-detail 截图替代最终稿。

已检查全部提交的历史、设计说明、运行文件、对照入口和验证记录。最终首页 CSS/JS/index 与 `0974f9d` 字节相同；冻结 app.js 也相同。最终 [comparison.html][design-compare] 比较的是原型修整前后，不是原型与 ArkTS。[validation.json][design-validation] 52 组比较中 46 组逐像素相同、6 组只涉及间隔/删除的三种状态。初始/轻盈验证有 160 个条目、10 种窗口，最终块面稿有 24 个状态/窗口条目。它们全部是浏览器合成状态。动效记录明确主卡完全静态，仅 connecting/disconnecting 的小圆环旋转。

[IMPLEMENTATION-GAP.md][design-gap] 记录的是旧 main `7f731d5`。其“面板未接入”“新视觉未迁移”“Smart 未换核”等快照已经过时，不能原样当成当前缺口；其中完整配置事务、Merge、设备健康与分享摘要仍需核对实际实现。

## PR 15 与 PR 18 的实际范围

[PR #15][pr15] head `0ff4dbca` 是 main 的祖先，增加/修改 NativeTheme、Home、Index、Profile、ProfileEdit、Settings、NetworkSettings、Override、Diagnostics 等原生页。生产页使用现有 ProfileStore/VpnController/CoreApi；它没有把独立 configpipeline 接到这些操作，也没有完成 Merge 或真机视觉验收。原生页面逻辑回归和 HAP 编译是其历史证据；三个所谓 baseline PNG 的 README 明确声明为 Chromium 参考图。

[PR #18][pr18] head `c6061b2f` 同样是 main 的祖先。其整合提交 `ffc12f5` 也正是 #15 的 merge_commit_sha，不应把两条路线理解成重复重做 UI。相对 #15，生产 pages 只有五个文件变化：Home 把临时代理组入口换成 Zashboard；Index 加入 Smart 及两个页面的 onShown/onHidden；Settings 增加 Smart 入口；新增 SmartPage；ZashboardPage 接入真实 session/认证/离线 Web。Smart 模型导入、状态、有效预测证据与整个应用级重启是新增真实宿主职责。

#18 后至本轮 main 的变化只有 #19 的 Full CI 工作流及 CI 文档，生产 UI 没有额外变化。#18 讨论中独立审核的 Controller/模型/浏览器联调结论属于历史技术证据，不当作本次重新执行或手机验证。#15 的 DEVICE-CHECKLIST 末尾仍说面板关闭/无 Smart，此句已被 #18 取代。

## 分类规则

| 类型 | 含义 |
| --- | --- |
| A | 源码按设计契约实现，仍可能需真机渲染确认 |
| B | 等价实现，平台或产品需求使差异合理 |
| C | 设计已有实现，但布局/视觉偏离；实际影响需截图确认 |
| D | 已有功能的交互或状态与设计不一致 |
| E | 原型/目标中存在，生产入口尚未实现 |
| F | 技术整合后原占位或旧流程不再适用 |

同一页面可有多个独立结论，分别分类。不计算“完成百分比”；尤其不把规划中的 Merge 或健康验证算成虚假完成。

## 逐页面对照

每行同时给出最终设计与固定 main 证据。D 中的 R1–R4 对应 [实际方法复现结果](reproductions.json)。

| 页面或状态 | 最终设计证据 | main 证据与差异 | 分类 |
| --- | --- | --- | --- |
| 1 首次使用/空配置 | [冻结 home()][app-home]：首页三个来源入口、底部添加；[导入确认][app-review] | [Home 270][p-home] 只留导入卡，点击先跳订阅页；[Profile 657][p-profile-empty] 才展示三个来源。新增一次根页跳转。`hasProfile` 实际表示“有激活选择”，有未激活配置时仍显示导入卡 | D 路径变长；C 空态构图缩减 |
| 2 首页未连接 | [ready 实图][shot-ready]、[home.css][home-css]：黑带一句“连接后显示实时速率”，灰接缝 | [Home 188][p-home-card] 几何灰接缝一致；217 始终绘制两列速率“—”，黑带高度与信息密度不同 | A 状态/几何；C 黑带 |
| 3 VPN 连接中 | [app home/start][app-home]：等待内核、可取消、跨页不断连接 | [Home 128][p-home-toggle] 可取消，206 小 LoadingProgress；[VpnController 169][vpn-start] 使用 OS 授权再等扩展就绪。没有自绘授权替身。文案“正在建立系统连接”较粗，缺精细阶段是底层契约限制 | A 取消与小加载；B OS 授权/文案 |
| 4 已连接 | [最终实图][shot-home]：白场静态斜面、青缝、标签在上/数值在下、单位小字 | [Home 188][p-home-card] Polygon 拓扑和连接时青缝对应；[Rate 178][p-rate] 数字在上/标签在下，单位并入整串 26fp；新增模式分段与诊断使下区更密。样本超过4秒清空 | A 几何/新鲜度；C 速率/构图；B 保留模式功能 |
| 5 连接失败 | [冻结 home][app-home]：错误 notice、诊断、重新连接；错误不是正常空闲 | [Home 34][p-home-listener] 只在监听且 visible 时消费错误，显示短 Toast 与泛化状态；重新 appear 只读 status，不读错误。Home 销毁期间失败后返回显示“未连接”，R3 已复现。[VpnController 181][vpn-start] 系统启动拒绝只回 Disconnected，没有错误类别；拒绝授权应与内核失败区分 | D 错误遗漏；C 无持久错误区域 |
| 6 断开确认 | [disconnect 截图][shot-disconnect]、冻结 stop() | [Home 130][p-home-toggle] 原生确认、保持/断开、世代与状态复核；Disconnecting 禁操作。旧会话确认不会停止新会话，现有回归通过 | A 行为；B 原生 AlertDialog |
| 7 订阅列表 | [profiles 实图][shot-profiles]、冻结 profiles() | [ProfileRow 380][p-profile-row] 标题/来源/当前使用/详情；列表不再重复用量，用量归详情。有多个实际配置，合理扩展原型单合成配置 | A 信息所有权；B 多配置 |
| 8 URL/文件/剪贴板导入 | [app import/review][app-import]；失败保留名称和 URL | [Profile 251][p-import] URL 失败保留输入；271 系统选文件/32MB；320 剪贴板失败回退手动；587 手动 URL/YAML。[Ready 613][p-ready] 确认/稍后启用。但无名称输入、完整校验和覆写预览；启用后仍停订阅页而非首页。手动粘贴输入在失败时保留 | A 三来源/输入保留；B 系统 picker/Sheet；D 启用后路径；E 校验/覆写 |
| 9 详情与操作 | [profile 实图][shot-profile]、[冻结 profile()][app-profile]：来源/最近更新/用量，更新固定底部 | [Profile 412][p-profile-detail] 原始编辑/全局参数/重命名/导出/启用/更新/复制/删除真实存在；用量仍归详情。但未显示来源域与明确最近更新时间；更新在 Scroll 内而非固定底部。全局“内核参数覆写”不是每订阅 Merge | A CRUD/用量；C 信息与按钮层次；E Merge |
| 10 更新与失败 | [update-error 实图][shot-update]、[目标回退声明][app-profile] | [Profile 167][p-update] 下载完成先提示“已更新”，忽略 reload 的 false（R2）；[ProfileStore 470][store-update] 校验只检查字符串，直接 TRUNC 写原文件，没有旧版本回退。[下拉 357][p-pull] 与详情各自门禁，可同时更新同源（R4）；[AutoUpdater 113][auto-update] 也忽略 reload 返回值 | D 错误/重复提交；E 校验与事务回退 |
| 11 配置编辑 | [冻结 Merge/差异][app-merge] 明确方案预览，原始与覆写分离 | [ProfileEdit 46][p-edit-save] 实际编辑原文件、保存/另存/热重载，是额外保留能力，不是 Merge 实现；false 至少有失败 Toast，但仍先写盘；[build 149][p-edit-build] dirty 只显示“未保存”，无离页确认，底部“立即生效”忽略失败条件 | B 原始编辑保留；D 失败文案/离页丢草稿风险；E 独立 Merge/差异 |
| 12 网络设置 | [冻结 network()][app-network]：下次启动、IPv6、三模式、手动包名、保存 | [Network 109][p-network] 功能完整；开关/分段/单包名增删即时持久化，删除没有 changedHint；不枚举系统应用，保留自身直连。即时保存符合设置习惯，但需补足统一生效反馈 | B 原生分段/即时保存；D 删除反馈不齐 |
| 13 内核参数 | [冻结 kernel/overrides][app-kernel]：端口/日志/LAN，下次启动；Merge 单列 | [Override 33][p-override] 独立校验1–65535、错误保留输入、原生Select与底部保存；明确“订阅 Merge 尚未接入”。不存在假 Merge 开关 | A 参数契约；B 原生控件；E Merge |
| 14 诊断 | [diagnostics 实图][shot-diagnostics]、[冻结诊断][app-diagnostics]：系统/内核/控制面/网络、分享、面板日志 | [Diagnostics 1][p-diagnostics] 四层仍在，系统会话/转发明确待设备；仅 `/version` 探活、迟到结果过滤。分享摘要、日志交接入口、真实系统/转发检查缺失 | A 分层；B 保守真实状态；E 分享/日志/健康 |
| 15 Smart 状态和模型 | [最终职责说明][design-readme]：组/Smart 归面板，无已启用假承诺 | [Smart 53][p-smart] 区分无组/统计/缺失/无效/加载/有效预测；导入校验及模型缓存要求应用级重启，[119][p-smart-restart] 显式说明断开并手动重连。模型装好≠预测生效，没有无效导入可用假象。页布局为长文字串，无原型精确对应 | B 宿主模型职责；F 原“Smart 未接入”占位；C 新页层次可打磨 |
| 16 Zashboard 入口/错误 | [panel-error 实图][shot-panel-error]、[冻结 panel()][app-panel]：保持 VPN、重试/返回 | [Home 251][p-panel-entry] 连接后直接面板；[Zashboard 78][p-panel] 真实session及ArkWeb，离页释放Web而不stop VPN。85 错误壳层仍是默认文字/按钮、12vp边距、Color.Red、版本片段，无 NativeTheme；重试始终在Web上方且没有48/56高度契约 | A 真实交接/生命周期；F 合成占位；C 错误壳层/残留工具信息 |
| 17 返回/Sheet/系统交互 | [最终README][design-readme]：二级页栈、modal隔离；原型各页仍有底部三签 | [Index 34][p-routes] 所有已用路径有NavDestination；系统返回承担退栈；Sheet/AlertDialog代替浏览器modal，二级页通常不保留根Tabs，属于原生等价。没有找到通向未知路由的入口。[Index 35][p-routes] `proxies` 路由与ProxyPage仍在，但没有push调用，属于旧版不可达残留；待ArkWeb手机验收后再删 | A 路由；B 平台返回/modal；F 临时代理组入口；D 草稿保护见11 |
| 18 深浅色/横屏/窗口 | [native-light.css][light-css]：浅色固定主题、700px两列、工具页max760/设置分组两列、短屏重排 | [NativeTheme][p-theme] 固定浅色，最终原型也无深色契约，不能要求复原PR6或旧稿暗色。深色系统控件与ArkWeb适配待手机检查。[Home 296][p-home-width] 仅≥700vp两列，174vp主卡不随高度变化；Settings等始终全宽一列，没有max宽；Navigation未显式指定模式，展开行为由平台决定 | A 浅色；C 工具页/短屏适配；B px→vp须实测；E 自动深色属于新增增强 |

## 重要视觉差异与截图身份

已经直接查看最终 `page-consistency/screenshots/after/` 的 connected、ready、profile、settings-interval、diagnostics、panel-error 六张图。它们是 **PR #11 的 Chromium 原型参考**。当前仓库没有可用的原生运行对照图；不能画出一个 ArkTS 推测图然后称为原生截图。

| 要素 | 设计与源码结论 | 验收要求 |
| --- | --- | --- |
| 白色状态场/灰黑静态斜面/青色接缝 | home.css 的87/64/74%几何，与Polygon相应点吻合；接缝仅Connected青色，其他灰色；不存在被否决的大连接图标 | 手机截图核对真实区域比例、文字侵入斜面与174vp固定高度，不能仅看颜色 token |
| 黑色速率带 | 已实现容器，但标签顺序倒置、数字26fp vs参考28px、单位同字号；未连接也保留双列，不同于ready短提示 | 明显视觉不一致；局部修正，不需重做主卡 |
| 浅色圆角三页签 | [Index 58][p-tabs] 每个选中项圆角；外层全宽76vp Tabs，缺参考左右16px、底8px、宽472上限、整容器28圆角 | 三签功能A，外壳C；这是悬浮构图缺失，不是Blur材质差异。允许使用原生Tabs，但应保持外壳或明确批准等价调整 |
| 字体角色 | 主标题26 Bold vs参考21/600；状态36 Bold vs38/600；列表17 Medium vs16/550；正文/元数据仍14–16/12–13 | 层次部分继承，字重/体积会改变视觉。fp/px和系统字体不同，不做逐像素阈值；大字号下不能裁剪关键状态 |
| 留白/对齐/卡片 | 24vp边距、24–28圆角存在；新增48vp模式条/诊断占空间，详情把结构化facts改成连续Text | 真机判断密度和首屏面板可见性；模式功能不用为了原型删掉，可在既有布局中压缩重复信息 |
| 线条/图标 | 系统SymbolGlyph替代原创SVG合理；速率箭头变普通字符，青色方向提示丢失；面板入口只剩chevron，少了面板职责提示 | 系统图标B；方向/交接识别C，次要打磨 |
| 弹窗/Sheet/输入 | 原生系统控件合理；14fp/48vp间隔ActionSheet与红棕删除都落地；重命名取消未显式48vp，需核对默认触区 | 不要求复刻浏览器按钮；测键盘、返回关闭、焦点/朗读和点击范围 |
| 响应式 | 首页宽屏两列已写入，工具页max宽/两列和短屏收卡未迁移；长名最多2行，状态固定块高 | 360vp窄屏、844×390横屏、700vp临界、960vp宽窗和系统大字号截图确认，不能拿浏览器结果替代 |
| Zashboard错误壳层 | Web内容由面板设计负责；宿主的版本行、默认重试按钮、错误红色与其余工具页不统一 | 仅整理宿主加载/失败壳层，保留Web隔离和重连，不重设计Zashboard |

参考图入口：[已连接][shot-home]、[未连接][shot-ready]、[设置间隔][shot-interval]、[订阅详情][shot-profile]、[诊断][shot-diagnostics]、[面板失败][shot-panel-error]。main 的 `docs/evidence/native-ui/screenshots/browser-baseline-*` 明确为旧浏览器图，不是当前原生证据。

## 用户工作流与实质缺口

目标是添加 → 确认激活 → 系统授权 → 连接 → 面板 → 更新 → 故障恢复。当前三来源到系统VPN/真实面板的主要入口已存在，页面切换仅释放展示资源。以下偏差影响该链条：

1. 首次首页添加要先跳订阅；Ready启用后不自动回连接页，还需用户切签。主页当前配置卡与“管理”都去同一列表，要再点一次详情。这是D而非必要平台限制；不需要新方向决策，局部接好导航即可。
2. **激活状态不代表运行配置**。`activate`先setActive再reload；false仍保留新标记（R1）。主页显示新名而内核仍旧；重启才生效的Toast不是持久的“待应用”状态。设计单一事实所有者尚不成立。
3. **“已更新”不代表应用成功**。`updateFromOrigin`先覆写磁盘，页面在reload之前提示成功且忽略false（R2）。弱校验可接受非法YAML，HTTP/格式失败在写盘前可能保留旧文件，但不能推出运行应用失败也能回退。独立configpipeline包存在并不等于这些调用使用它。自动更新及下拉也有相同返回值问题。
4. **更新防重只在局部**。详情的updatingFile不保护根列表下拉，也不覆盖AutoUpdater；同一来源可能同时写入（R4复现两个页面同时进入更新）。需共享事务/任务身份，不能仅在按钮加disabled。
5. **失败状态不耐页面生命周期**。Home重新appear不消费lastStartError（R3）。系统授权拒绝又没有独立错误类型。失败原因需在连接页保留并可恢复；不可让别处短Toast成为唯一证据。
6. 详情更新按钮位于Scroll内，错误仅Toast，缺稳定失败/重试面。编辑dirty可直接返回；“保存立即生效”的固定文案与热重载失败不符。这些可以独立修复，不需全UI重构。

合理变化保留：OS授权、系统picker/Sheet/返回；不虚构Wi-Fi/真实转发健康；当前活动配置要求先手动断开再删除（最终冻结原型的删除确认可自动stop后删除，原生先保护是可接受的B）；多配置列表与现有原始编辑；模型文件通过宿主安装/验摘要、应用级重启释放VPN Extension模型缓存。模型导入需要已连接Controller，但并不要求模型存在才能连接，统计策略可用，未形成循环依赖。

Smart组的运行选择、规则、连接和日志仍交给Zashboard。SmartPage的模型安装及当前模型/预测状态是宿主专有责任，允许有限状态重复用于排障，不应再扩建第二套Smart组编辑器。仅使用 YAML 配置组属于后续易用性增强。原型面板占位已失去意义，F；面板自身UI不受首页斜面契约约束。

## 真机待验收

本地Agent继续真机测试，不与其修改同批生产页面。本报告不声称实时取得其截图。后续交接应包含精确源码SHA、未签名/签名包摘要、设备系统/API、窗口vp与截图像素、系统字号、浅深系统模式；全部使用合成配置或脱敏内容。

| 验收批次 | 原生截图与行为 | 通过条件 |
| --- | --- | --- |
| 首页状态 | 空/有配置未连接/授权拒绝/连接中/已连接/启动失败/断开中与确认 | 白场/斜面/接缝/速率布局可读；主动作在导航上方；拒绝可重试、取消不迟到成功；首次路径和错误不丢失 |
| 配置全链 | URL失败/文件picker/剪贴板拒绝手动粘贴/Ready/详情/更新中与失败/编辑 | 输入保留；激活名、磁盘与运行版本一致或明确待应用；失败不报成功；重复操作被共享门禁约束；长名与键盘不遮提交 |
| 工具页 | 间隔选择/非法端口/分流新增删除/诊断 | 48vp触区；输入错误不覆盖；下次生效信息持续可见；状态四层互不推导，健康仍以真实证据为准 |
| Smart | 无组/无模型/坏模型/有效加载/有效预测/导入/重启取消与确认 | 模型Loaded与Predictions区别真实；外部浏览器返回可继续；应用重启实际结束VPN Extension旧进程；导入过程离页不误提交 |
| ArkWeb | 加载/离线资源错误/Controller认证失败/渲染退出/重试/返回 | 有可见错误与返回；VPN持续；REST/WS与凭据上下文正常；不把Web截图当整个原生壳层 |
| 窗口/系统 | 360vp窄屏、正常直屏、横屏低高度、700vp阈值两侧、宽窗、最大常用系统字号、系统深浅 | 无裁字/横溢/主动作遮挡，宽窗不过宽；底部手势区正确；Navigation展开/返回行为合理；键盘/无障碍朗读正常 |
| 生命周期 | 连接中跨签；主页销毁后失败；后台/关窗再开；旧断开弹窗；面板切页返回 | VPN生命周期只归Runtime；错误能回来；旧确认不停止新会话；陈旧速率显示—，真实0流量仍显示0 |

TUN真实请求、DNS/UDP/IPv6、切网、息屏等属于功能验收；不能用原生漂亮截图或Controller可达代替。

## 独立后续任务

| 任务 | 分类与严重性 | 建议边界和验收 |
| --- | --- | --- |
| T1 配置激活/更新的运行结果与回退 | D/E，P1：可能丢失上一份有效磁盘配置并误报成功，影响故障恢复 | 配置线接统一事务或至少有效版本/待应用状态、完整内核校验、共享更新门禁与回退；覆盖手动激活、更新、下拉、自动更新、编辑。失败保留运行/磁盘有效版本，界面不承诺成功；复现R1/R2/R4不再出现 |
| T2 启动错误跨页面保存 | D，P2：错误原因遗漏，排障受阻 | Runtime/Controller保存结构化结果，Home返回消费/订阅持久错误；区分授权拒绝与内核失败，保留诊断/重试。覆盖R3和切签仍挂载场景 |
| T3 连接与订阅的最短路径 | D，P2：额外点击 | 首次添加直接打开来源菜单；启用后回连接页；当前卡直达当前详情，“管理”仍列表；保留多配置与稍后启用 |
| T4 原始编辑未保存退出与生效反馈 | D，P2：易丢草稿 | 系统返回及离页确认/保存草稿；失败/保存未应用要持续提示；不加入新的Merge能力冒充原始编辑 |
| T5 原生主卡和导航局部还原 | C，明显视觉差异，非使用阻断 | 标签/数值/单位、idle短黑带、悬浮圆角Tabs壳层；先比真机图，再最小调整；保留模式与诊断，不添加装饰或更换风格 |
| T6 工具页/窗口/面板错误壳层一致性 | C，次要视觉打磨；若真机遮挡升级为交互缺陷 | 工具页max宽或分组重排、短屏/大字号、稳定更新动作、面板宿主错误语义与触区；不改Web主体或认证策略；清理不可达ProxyPage在ArkWeb手机验收后进行 |
| T7 诊断摘要/日志交接与真实健康 | E，后续产品增强 | 分享脱敏状态摘要、日志跳Zashboard；系统会话/转发探测有真实来源后再接，不把“需设备确认”替换为假肯定 |
| T8 每订阅Merge及差异预览 | E，后续配置产品能力 | 独立保存覆写、更新重应用、平台约束与事务回退；不属于为关闭设计PR而临时增加的功能 |

无新的设计方向分歧需要用户选择。自动深色支持未属于已选native-light契约，是后续增强；若将全宽Tabs保留为长期设计，则需显式确认这项偏离，不能自行改写为“已完全还原”。品牌、名称、图标、Logo、bundleName全部在范围外。

## PR 11 收尾决定

PR #11 已完成**选定设计基准并向原生实现交接**的历史阶段。#15/#18 证明主要UI已经合流，却不证明完整验收。**本轮保留开放，不合并原型分支。** 阻断完整收尾的不是260个文件未入main，而是T1/T2的真实结果契约缺口、尚未归档接受的导航/速率偏差，以及没有原生视觉证据。

关闭可以走两条明确路径：

1. T1/T2修复并核对本轮复现；取得上述原生核心截图，确认T5/T6修正或明确接受，其他增强T7/T8独立跟踪。随后在#11注明“设计主要契约通过#15/#18及后续修复完成”，关闭而不合并。
2. 提前结束设计分支：把T1–T8正式转成有责任边界的独立任务，并明确记录仍未通过的真机验收和C/D/E差异。#11可按“设计交接完成、剩余任务已转移”关闭，**不能写“完整设计验收通过”**。本次报告是任务定义，不假装这些后续任务已经被实施或接受。

最终规范不需拷贝全部历史：main已有三张有身份标记的浏览器基准图；本报告冻结链接到最终入口/关键CSS/工具页修订/对照与验证记录。若需长期维护规范，后续只提取最终契约与少量参考；不复制被否决试稿、不把历史IMPLEMENTATION-GAP当现状。

## 本次验证

- GitHub读取#6/#11/#15/#18元数据与讨论，Git检查#11全部8提交、#15/#18祖先关系、#18→main文件差异；最终设计依赖和冻结首页文件逐字节核对。
- 本轮实际通过：`test-native-ui.cjs`、`test-smart-ui.cjs`、`test-smart-model-restart.cjs`。它们使用官方SDK转译实际方法/合成API，验证资源释放、世代确认、输入保留、模型状态和重启顺序；不渲染Builder。
- 本目录 `reproduce.cjs` 运行真实页面截取方法，以合成false reload、延迟更新与页面销毁重现R1–R4，结果在 `reproductions.json`。脚本的assert通过表示缺陷成功复现，**不是产品行为通过**。复现：仓库根 `source scripts/env.sh` 后 `node docs/evidence/design-review-2026-10-13/reproduce.cjs`。
- 报告链接/截图身份、JSON、`git diff --check`与变更边界另作交付检查。未构建HAP，因为没有修改生产/资源；未重跑全部Go/平台测试或浏览器原型生成，不覆盖其历史结果。

<!-- Frozen evidence references: do not replace with moving main URLs. -->

[pr6]: https://github.com/Starfie1d1272/clash-OpenHarmony/pull/6
[pr11]: https://github.com/Starfie1d1272/clash-OpenHarmony/pull/11
[pr15]: https://github.com/Starfie1d1272/clash-OpenHarmony/pull/15
[pr18]: https://github.com/Starfie1d1272/clash-OpenHarmony/pull/18
[design-index]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/index.html
[design-compare]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/comparison.html
[design-validation]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/validation.json
[design-gap]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/IMPLEMENTATION-GAP.md
[design-readme]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/README.md
[home-css]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/connection-planes/home.css
[light-css]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/baseline-9127864/native-light.css
[app-home]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/baseline-9127864/app.js#L175
[app-import]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/baseline-9127864/app.js#L202
[app-review]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/baseline-9127864/app.js#L205
[app-profile]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/baseline-9127864/app.js#L211
[app-merge]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/baseline-9127864/app.js#L214
[app-network]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/baseline-9127864/app.js#L223
[app-kernel]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/baseline-9127864/app.js#L226
[app-diagnostics]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/baseline-9127864/app.js#L229
[app-panel]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/baseline-9127864/app.js#L232
[shot-ready]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/screenshots/after/ready-390x844.png
[shot-home]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/screenshots/after/connected-390x844.png
[shot-disconnect]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/screenshots/after/disconnect-390x844.png
[shot-profiles]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/screenshots/after/profiles-390x844.png
[shot-profile]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/screenshots/after/profile-390x844.png
[shot-update]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/screenshots/after/update-error-390x844.png
[shot-diagnostics]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/screenshots/after/diagnostics-390x844.png
[shot-panel-error]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/screenshots/after/panel-error-390x844.png
[shot-interval]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/8131567d44ce02f9af3b149c5eb83c9cf238d93c/design/native-ui-fresh/page-consistency/screenshots/after/settings-interval-390x844.png
[p-home]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/HomePage.ets#L270
[p-home-card]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/HomePage.ets#L188
[p-home-toggle]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/HomePage.ets#L118
[p-rate]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/HomePage.ets#L178
[p-home-listener]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/HomePage.ets#L34
[p-panel-entry]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/HomePage.ets#L251
[p-home-width]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/HomePage.ets#L296
[p-profile-empty]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/ProfilePage.ets#L657
[p-profile-row]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/ProfilePage.ets#L380
[p-import]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/ProfilePage.ets#L251
[p-ready]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/ProfilePage.ets#L613
[p-profile-detail]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/ProfilePage.ets#L412
[p-update]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/ProfilePage.ets#L167
[p-pull]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/ProfilePage.ets#L357
[p-edit-save]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/ProfileEditPage.ets#L46
[p-edit-build]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/ProfileEditPage.ets#L149
[p-network]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/NetworkSettingsPage.ets#L109
[p-override]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/OverridePage.ets#L33
[p-diagnostics]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/DiagnosticsPage.ets#L1
[p-smart]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/SmartPage.ets#L53
[p-smart-restart]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/SmartPage.ets#L119
[p-panel]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/ZashboardPage.ets#L78
[p-routes]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/Index.ets#L34
[p-tabs]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/Index.ets#L58
[p-theme]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/pages/NativeTheme.ets#L1
[vpn-start]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/lib/VpnController.ets#L169
[store-update]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/lib/ProfileStore.ets#L470
[auto-update]: https://github.com/Starfie1d1272/clash-OpenHarmony/blob/81215c5f5bc10c04f382d526e1b03d6484b26151/clash-openharmony/entry/src/main/ets/lib/AutoUpdater.ets#L113
