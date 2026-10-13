# HarmonyOS 原生材质与布局

保留 PR #11 的 Ark minimal：白色状态场、静态灰黑斜面、连接时青色接缝、黑色速率带，以及连接/订阅/设置三入口。材质用于导航和系统交互区域，内容卡片保持实体表面。API 26 构建通过只证明接口及打包有效；实际光感、系统强度、低算力降级、手势区和无障碍必须在手机验证。

## 官方能力使用矩阵

起始版本按实际接口区分，不用“H7”统称所有能力。最低兼容仍为 API 21，目标 API 26。Huawei 文档网站部分指南为动态内容，完整正文未能读取；下表的可执行签名及版本同时核对官方 SDK 声明和官方 OpenHarmony API 文档，来源摘要见 [sources.json](../evidence/h7-native-2026-10-13/sources.json)。不把社区示例当官方限制。

| 能力及官方资料 | 起始 API | 使用条件及当前状态 | 本产品适用性/复杂度 | 兼容与功耗影响 |
| --- | --- | --- | --- | --- |
| [uiMaterial / ImmersiveMaterial](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-uimaterial)；[官方API正文](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkts-apis-uimaterial.md) | 26.0.0 | Stage、ArkUI.Full；先版本/Syscap，再 `isImmersiveMaterialSupported()`。导航明确设置THIN；不铺主卡或全页 | 适合悬浮交互，中 | 系统决定硬件算力等级与强度；不强制模拟高档。静态内容无材质循环或额外传感器 |
| [应用级 MaterialState](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkts-apis-uimaterial.md#materialstate) | 26.0.0 | entry metadata `ohos.arkui.UIMaterial.state=enable`。原main无此metadata，对应默认状态，不能称“全部材质关闭” | 启用系统交互，低 | DEFAULT只默认开启部分弹出/文本菜单；ENABLE扩至Toggle/Select/Sheet等；DISABLE禁止。全局enable不能使任意卡片自动变玻璃 |
| [HDS hdsMaterial](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ui-design-hds-material) | 6.1.0(23) | UIDesign.HDSComponent.Core；`getSystemMaterialTypes()`查询；MaterialType/Level两者可用ADAPTIVE。仅独立试验使用 | 适用HDS导航，中 | HarmonyOS/HMS能力不是通用OpenHarmony承诺；ADAPTIVE依据设备策略，不固定EXQUISITE；与uiMaterial等级枚举不同 |
| [普通Tabs官方悬浮](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-container-tabs.md#barfloatingstyle) | 26.0.0；基础Tabs 7、barOverlap 10 | End、横向、barOverlap=true三条件；生产已接官方FloatingTabBarStyle。最大472vp，左右16vp，底8vp，68vp栏高 | **采用**，中 | 无重复背景模糊；内容另留92vp，不让固定按钮藏底栏。API<26不调用新方法，普通Tabs回退 |
| [HdsTabs / HdsTabsFloatingStyle](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ui-design-hdstabs) | HdsTabs 6.0.0(20)，悬浮23 | `systemMaterialEffect`不是普通Tabs的`systemMaterial`；两套width字段也不同。试验已编译，生产不替换组件 | 候选，中到高 | 需HDS Core；温控 `thermoCtrl=true` 只在试验启用；迁移与页面生命周期必须真机对比，不能以可编译推断更稳定 |
| [Navigation / NavDestination](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/ts-basic-components-navigation) | 现有导航满足21；title systemMaterial为26 | 保留现有Navigation/页面栈及onShown/onHidden。ENABLE可使系统标题交互背板采用默认材质 | 适合，低 | **标题材质范围是返回键、菜单按钮和更多弹出背板，不是整条标题或整页。** 不为光感改导航模式或铺全屏模糊 |
| [ActionSheet](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-methods-action-sheet)、[Dialog](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-methods-alert-dialog)、[Sheet](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-attributes-sheet-transition.md) | 基础ActionSheet/Dialog 8、bindSheet 10；systemMaterial选项26 | 现有原生控件继承ENABLE，不逐个强加材质或模糊。试验保留默认背景以观察系统容器 | 适合，低 | 老静态ActionSheet/AlertDialog接口有弃用警告；本轮不重写功能回调。自定义Sheet内部实体白卡可能遮部分光感，须截图后局部处理 |
| [Toggle](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-components-toggle)、[Select](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-components-select) | 基础Toggle 8、Select 8；ENABLE材质26 | 生产已用Switch与Select，无自绘替身；应用级使能，选中色保留原青色 | 适合，低 | 全局ENABLE可能优先于背景/阴影参数，静态色对比检查不能代替实际系统材质可读性 |
| [SymbolGlyph与符号效果](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-components-symbolglyph) | SymbolGlyph 11；symbolEffect/常用Bounce 12 | 已用系统符号。本轮保留小符号、合并页签无障碍标签，未增加循环Bounce | 适合符号，不需要额外动画，低 | 不恢复大连接图标；系统原生光感反馈代替自绘扫光，无新定时动画 |
| [可变字重 / fontFeature](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-basic-components-text.md) | fontWeight options 12；fontFeature 12 | 标题600并启用可变字重；速率用tnum，数字28fp、单位12fp。只用系统字体，不分发字体文件 | 适合，中 | 可变字重需要对应系统字体；不保证每一系统字体都有tnum，系统回退可用。不开字重动画 |
| [系统主题与资源限定词](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/resource-categories-and-access) | base/dark资源机制非26专属 | NativeTheme指向base/dark资源；不强制系统ColorMode。白色状态场使用独立固定墨色，保持确认设计 | 适合，中 | 系统弹层、Web与应用可能有不同主题时机，切换待测；亮色接缝不是全局品牌改动 |
| [安全区与窗口](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-arkui-1089) | expandSafeArea 10、safeAreaPadding 14；基础尺寸监听已满足21 | 沿用系统避让，未启用全屏覆盖手势区；根页预留底栏占位，工具页max760、首页max1120、700vp两列 | 必需，中 | 沉浸式全屏与沉浸材质是两件事。避免把可点按钮扩入系统手势区。Navigation Auto仍由平台决定，宽窗二级页待测 |
| [字体缩放与无障碍](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-accessibility) | accessibilityGroup/Text等非26专属；配置fontSizeScale满足21 | 保留fp；主卡高度按系统字号放大，短屏隐藏重复眉题；速率不强制单行截断，页签/速率整组朗读 | 必需，中 | 系统字号没有被全局封顶；布局公式不是渲染验证，最大字号/键盘/焦点须真机 |
| [触觉反馈](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-vibrator) | startVibration的effect接口9；各组件自身enableHapticFeedback版本不同 | 当前生产无VIBRATE权限；本轮不加主动震动，不以点击导航触发额外振动 | 普通切签无需新增，低 | 额外权限与硬件能力需要明确用途；高频震动增加打扰和功耗。真正需要确认反馈时另行评估 |

## 材质实际启用方案

生产仅在entry添加`enable`，由系统为原生弹窗/开关/选择/半模态提供可用材质。Tabs显式设置THIN；设备不支持材质时保留官方悬浮几何与实体背景，关闭该分支的普通模糊。API21–25不调用barFloatingStyle或uiMaterial查询，保留普通TabBar；不承诺旧系统具有26的光感效果。

`NativeTabStyle`用AttributeModifier把新方法调用放入运行分支。旧H7只传undefined，却仍调用新方法的写法不再使用。`getGlobalMaterialLevel()`反映设备能力，**不是用户设置的强/均衡/弱**；应用不伪造开关去改变系统强度，不固定最高算力档位。

可生效区域按具体组件契约判断：Tabs悬浮背板需End/横向/overlap；Navigation标题选项只作用于交互背板；Dialog/Sheet作用于系统容器。通用systemMaterial存在并不证明主卡上材质与原生标题效果等价。本产品无需在页面背景、全部卡片、密集设置行增加材质。没有额外shadow、backgroundBlurStyle与材质重复叠加；不使用自绘玻璃、光斑或循环动效。

## 普通 Tabs 与 HdsTabs 的选择

| 维度 | 普通Tabs加官方悬浮 | HdsTabs加HDS材质 |
| --- | --- | --- |
| 设计还原 | 支持独立背板、明确留白、三项布局；保留原有选中胶囊 | 同样支持浮动背板；HDS默认栏宽/样式不同，需实机确认 |
| 光感与性能 | uiMaterial THIN、交互形变/光反馈；不固定硬件等级 | HDS ADAPTIVE type/level，试验开启温控；不能凭接口断言比前者省电 |
| 栈与运行风险 | 现有Tabs实例/提供者/页面栈关系保持，改动小 | 需要替换组件与核对选择、缓存、销毁/显示回调，整合风险更大 |
| 安全区/响应式 | 栏宽随实际窗口计算，max472；根内容预留92 | 有独立HDS width分档和底边距；试验同样预留92 |
| 版本/依赖 | 悬浮26，旧设备基础Tabs回退，无HDS生产依赖 | 悬浮23，HDS Core可用且有HMS组件；不能只看SDK版本 |
| 实际SDK结果 | 独立试验及生产HAP编译通过 | 同一独立试验HAP编译通过 |
| 当前建议 | **用于生产隔离分支，等待真机验收** | 保留试验用于同机比较，不为多一层材质重写页面栈 |

没有设备数据证明两者的实际帧率、能耗、光感优劣。选择依据是已验证签名/构建、生产改动规模和现有生命周期契约。

## 局部视觉实现与降级

- 首页保持白场/斜面/接缝，不改变其信息所有权；速率改标签在上、数字在下、小单位，未连接黑带恢复短提示。短窗压缩眉题，字号增大时主卡增加高度。
- 三根页内容预留底栏区域，固定连接按钮仍在导航上方。最大栏宽472及侧边16使它区别于全宽底条。
- 工具页限制760vp，居中保留空白；未引入另一套页面状态，也未为设置两列重排增加不稳定组件挂载。
- Smart只把策略、模型、预测/消息分组并缩短操作文案，保留模型安装、摘要校验、重启和统计策略说明。Zashboard只修宿主错误壳层；Web配置、认证、事件和运行页面不变，正常时取消冗余版本行/重复重开按钮。
- 主题颜色按资源自动切换。状态色仍`#00869B`，青缝仍`#18D1FF`；小字用原型深青`#006E83`、实色按钮用`#007F91`，两者是功能角色而非新品牌。深色按钮前景为深墨，避免亮青底配白字。

已有功能/状态缺陷（PR20 T1–T4）、配置事务、系统健康、VPN Extension、核心、Controller安全与品牌不属于此规范的修复范围。
