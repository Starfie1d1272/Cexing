# 原生轻盈：视觉来源、版本边界与窗口适配

研究日期：2026-10-12。新版保留 Ark UI 的任务顺序、单一强调色、状态与数据的单一所有者；形状、材质和交互优先遵循用户要求的鸿蒙原生感觉。旧版保持可交互，入口为 `index.html?state=connected&variant=classic`；新版默认 `variant=native-light`。

## 实际看过的界面

下面的观察来自已下载并逐张查看的真实 UI 图，未凭 README 描述推断外观。原图只用于研究，没有复制到仓库、原型或公开截图中。开源许可不自动覆盖截图中的影视海报、专辑封面或品牌素材。

| 来源与证据 | 维护 / 原生身份核对 | 适用边界 |
| --- | --- | --- |
| [京墨文库](https://github.com/hefengbao/jingmo-for-HarmonyOS) · [真实首页图](https://raw.githubusercontent.com/hefengbao/jingmo-for-HarmonyOS/a208f3fdc95c0914749072e811301b9dfd6678d6/screenshot/0.png) | ArkTS / ArkUI；MIT；核对提交 `a208f3f`（2026-01-14），小型已发布应用，不宣称大型成熟产品 | 手机入口分组、浅色材质和留白；图中没有底部页签，不从此图推导导航样式 |
| [冲浪喵](https://github.com/awaLiny2333/LinysBrowser_NEXT) · [普通设置](https://raw.githubusercontent.com/awaLiny2333/LinysBrowser_NEXT/f8f07a66482c8713ba21427889fc969c1ca56ab2/previews/Settings-normal.jpg) / [效果设置](https://raw.githubusercontent.com/awaLiny2333/LinysBrowser_NEXT/f8f07a66482c8713ba21427889fc969c1ca56ab2/previews/Settings-effects.jpg) | 原生 ArkUI；MIT；核对提交 `f8f07a6`（2026-09-04），有持续开发与 2.0 重构 | 作者展示的桌面设置页，只借鉴圆角分组和软边界；不沿用多列密度或桌面底部工具条到手机 |
| [FinVideo](https://github.com/OHPG/FinVideo) · [手机首页](https://ohpg.org/assets/statics/FinVideo/Market/FinVideo1.jpg) / [媒体库](https://ohpg.org/assets/statics/FinVideo/Market/FinVideo4.jpg) / [详情](https://ohpg.org/assets/statics/FinVideo/Market/FinVideo2.jpg) | ArkTS / ArkUI；GPL-3.0；提交 `669916b`（2026-07-28），有 AppGallery / Release 发布路径 | 作者网站发布的 UI 图；观察中央实际应用界面，不借用外部营销渐变、封面或内容。网站图片不证明今天的安装包界面完全相同 |
| [FinMusic](https://github.com/OHPG/FinMusic) · [手机播放页](https://ohpg.org/assets/statics/FinMusic/Market/FinMusic3.jpg) | ArkTS / ArkUI；GPL-3.0；提交 `ca869fd`（2026-06-01），有 AppGallery 发布路径 | 只观察字号梯度、圆角内容与动作主次；不借用专辑封面或播放页业务结构 |
| [官方控件示意](https://developer.huawei.com/consumer/cn/doc/guidebook/solution-0000002784570841) · “沉浸光感”中的控件图 | 官方页面更新时间 2026-10-09；实际查看标题、页签、按钮、半模态等示意图，图像 ID `zh-cn_image_0000002755012076` | 观察浮动胶囊、轻边界及动作主次；不把摄影背景或完整视效搬进 VPN 工具 |
| [官方 ArkUI 按钮示例](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-basic-components-button.md#示例3-设置按钮文本样式) · [实际示例图](https://raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/figures/imageButtonLabelStyle.png) | OpenHarmony 官方文档；实际查看胶囊按钮示例图 | 作为常规原生按钮形状的补充，不能据此假定新 HDS 材质已兼容所有系统 |

## 六个维度的比较

表中为视觉观察，非像素测量或官方强制值；宣传图缩放不能直接换算 vp。

| 维度 | 京墨 | 冲浪喵设置（桌面） | FinVideo / FinMusic（手机） | 官方控件图 | 新版选择 |
| --- | --- | --- | --- | --- | --- |
| 圆角 | 浅灰圆角入口块 | 外层大圆角、分组小圆角、分段胶囊 | 大圆角封面，柔和内容边界 | 胶囊按钮、悬浮圆角页签 | 卡片 24–28px；按钮 28px；弹层 32px；这些是本原型的实现值 |
| 留白 | 分类间距大，列表内部紧凑 | 用组间空隙代替到处画线 | 标题与内容区分离，空白保留给内容 | 操作区周围有独立空间 | 24px 手机边距；只给有关联的设置组共享表面 |
| 材质 | 白底、浅灰入口，不靠重阴影 | 普通版层级色面；效果版有通透面 | 白底为主，图像内容不加硬框 | 通透背板、细边界、轻阴影 | 大块黑底改白色卡片；浮动导航轻微透明；普通表面也可独立工作 |
| 字号 | 标题强、入口文字常规 | 组标题强，选项次一级 | 大标题 / 内容名 / 元数据分层 | 标签与动作清楚 | 36px 状态标题；16px 行标题；12–13px 元数据；受限高度重新编排 |
| 导航 | 图中仅有顶部设置入口 | 图中为桌面工具条，不是手机页签 | FinVideo 图中底部图标＋文字，蓝色标识选中 | 浮动胶囊与底部操作层区分 | 三个页签固定、文字始终可见、唯一选中态；主按钮独立在上方 |
| 主按钮 | 此首页图没有突出提交按钮 | 组内动作与开关相邻 | FinMusic 用一个显著播放动作压住其他控件 | 强调 / 普通 / 轻量动作分层 | 未连接时实色“连接 VPN”；已连接时用柔和色面“断开连接”，避免诱导停止 |

不是给旧黑卡加圆角：状态区的黑色面积被移除，设置从独立硬边行改为关联组，主按钮与导航材质分开；保留原有任务、状态、数值和动作。没有新增科技仪表、背景图片或装饰动画。

## 原生能力与版本矩阵

本仓 [build-profile](../../clash-openharmony/build-profile.json5) 明确：`targetSdkVersion: 26.0.0`，`compatibleSdkVersion: 6.0.1(21)`，`runtimeOS: HarmonyOS`。目标 SDK 可声明某能力，不表示 API 21 的运行设备也能执行它。

| 能力 | 核对证据 / 版本 | 当前原型 | 后续实现与回退 |
| --- | --- | --- | --- |
| 常规 ArkUI 圆角、系统字号、Button、Navigation、Tabs | 已有生产 ArkTS 使用基础组件；本次未改变最低兼容级别 | HTML/CSS 表达原生布局与几何 | 使用系统资源与真实 ArkUI 组件；API 21 基础体验仍可用，材质不可用时保留纯色圆角与同一导航 |
| `NavigationTitleOptions.systemMaterial` | [官方 Navigation API](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/ts-basic-components-navigation)；本地 SDK `openharmony/ets/component/navigation.d.ts` 注释 `since 26.0.0` | 未调用；仅示意轻表面 | 对 API 26 与对应 Syscap 做守卫；低版本用普通标题栏。不能只看目标 SDK 就直接调用 |
| Tabs 系统材质选项 | 本地 SDK `openharmony/ets/component/tabs.d.ts` 中 `systemMaterial?: UIMaterial.ImmersiveMaterial`，`since 26.0.0` | 浮动底栏的 CSS 透明 / blur 示意 | 确认具体 Tabs 选项与运行支持后接入；低版本保持纯色浮动页签 |
| HDS `hdsMaterial.MaterialType.IMMERSIVE` | 本地 SDK `hms/ets/api/@hms.hds.hdsMaterial.d.ets`，`since 6.1.0(23)`；Syscap 为 `UIDesign.HDSComponent.Core` | 未导入 HDS；无真实原生材质绑定 | HDS 与基础 ArkUI 材质不是同一个接口；按具体组件分别守卫，不能把所有 IMMERSIVE 都说成 API 26 才有 |
| HDS 标题 / 浮动页签、光随指动与融合 | [官方白皮书](https://developer.huawei.com/consumer/cn/doc/guidebook/solution-0000002784570841) 的控件图与说明 | 只示意浮动层次、按压与焦点；未仿制光线扭曲或融合动画 | 逐项核对组件声明、系统策略、性能与减少动态效果；不把 CSS 当成原生已接入证据 |
| HarmonyOS / OpenHarmony 差异 | 基础 ArkUI 类型在 `openharmony` SDK；HDS 增强定义在 `hms` SDK | 浏览器不代表任一设备运行时 | 通用 ArkUI 可作基础；HMS/HDS 的存在不证明纯 OpenHarmony 设备也有该增强能力。设备 Syscap、SDK 与实机验证分别检查 |
| 窗口与键盘适配 | [官方阔折叠适配入口](https://developer.huawei.com/consumer/cn/newdevice/pura-x-max/) | 根据实际窗口宽高和 `dvh` 重排；不使用设备型号分支 | 原生接入窗口尺寸、避让区和键盘事件；布局变更不改变 AppRuntime、VPN 会话或订阅事务 |

本次只写原型，没有替换 HDS 控件、改生产 SDK 或提交 HAP。也没有声称完成折叠硬件、键盘、原生材质或真机转发验收。

## 多形态方案

[多形态图与同尺寸前后对照](comparison.html) 使用本任务实际浏览器截图。尺寸是逻辑窗口夹具，覆盖比例和断点，不是某款硬件的物理分辨率。

| 场景 | 逻辑窗口 | 处理 |
| --- | --- | --- |
| 直屏 | 390×844；兼顾 320×568、360×800、412×915 | 单列；三个页签固定；主动作保持可达 |
| 阔直屏 | 480×900 | 单列扩大留白，不扩张文字或装饰 |
| 阔折叠宽窗口 | 960×720 | ≥700px 时将状态 / 速率与订阅 / 面板并列 |
| 双折展开 | 840×1120 | 两栏共享一份状态；固定底部动作与导航 |
| 三折展开 | 1200×900 | 内容最大宽度 1120px，避免一张卡跨满大屏；仍只显示一份数据 |
| 高度受限横向窗口 | 844×390 | 紧凑状态 / 速率；正文为有边界的滚动区，与动作层分开，不让字藏在按钮下面 |
| 键盘 / 窗口高度减少 | 390×520 | 测试输入与焦点连续、字段滚入可见区；此夹具不模拟真实系统键盘事件 |

不采用“折叠一下重新加载页面”。CSS 断点只改变排布；浏览器实测 390 → 960 → 840 → 1200 → 高度受限 → 390 后，VPN 状态、当前页签、输入值与输入焦点保持。后续 ArkTS 将这些状态放在宿主 / 页面 ViewModel，不能在断点变化时创建新 VpnController 或停止后台服务。
