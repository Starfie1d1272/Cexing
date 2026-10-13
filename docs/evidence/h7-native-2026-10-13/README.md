# HarmonyOS 原生视觉专项验证

基线main `81215c5f5bc10c04f382d526e1b03d6484b26151`，2026年10月13日。读取PR11/15/18/20，最终设计以`0974f9d`首页和`8131567`工具页为准。PR20审查以固定提交`aa57879`读取，未把未合并报告当作main生产实现。

**本轮完成官方悬浮Tabs、应用级材质使能、主题资源与局部视觉调整；原生实际光感和窗口布局仍待真机。** [能力矩阵及实施规范](../../reference/h7-native-ui.md)、[独立试验](../../../design/h7-native-lab/README.md)、[实际方法测试](../../../scripts/test-native-material.cjs)。没有全面换风格、恢复旧四Tab或大连接图标，也没有修改Web面板主体。

## 旧 H7 与现行实现

检查PR1清理前`77189bc9c9e90c62bc166a23a3a93159dfca27c5`的`clash-openharmony/H7_DESIGN.md`、`lib/H7.ets`、module与Index/Home/Settings。旧H7来自`735f63e`，用普通Tabs.barFloatingStyle、barOverlap、THIN背板、entry enable与系统材质；不是HdsTabs，也不是普通CSS玻璃。

| 旧实现 | 当前处理及原因 |
| --- | --- |
| 四Tab、品牌蓝、大圆环/光晕/旧管理页面 | PR11已替代；不恢复 |
| 只以sdkApiVersion≥26判断H7 | 新查询硬件isImmersiveMaterialSupported及Syscap；版本分支内才调用26方法 |
| 传undefined给新方法并声称旧系统回退 | 新AttributeModifier不在旧系统调用新方法；旧设备基础Tabs回退，不能声称完全相同悬浮光感 |
| REGULAR主卡、THIN信息卡、ULTRA_THIN模式区，强制透明并追加材质 | 主卡和工具内容保持实体；材质集中于官方悬浮导航及系统交互容器 |
| 固定88vp底部补偿 | API26悬浮根页预留92vp（栏高68+底边8+16余量），系统安全区另由平台承担 |
| 手工要求所有材质前透明、所有样式后systemMaterial | 以具体API/应用级模式为准，ENABLE优先级及低算力表现需分别核对；不沿用旧规则作为通用保证 |
| enable默认系统弹层材质 | 生产恢复明确使能；当前main缺metadata对应DEFAULT，不能说“默认完全关闭” |

API26标题材质的生效区只包括返回键/菜单按钮/更多菜单背板；Tabs需要End/横向/overlap三个条件。没有把标题材质解释成整页玻璃。官方动态指南/FAQ部分未能取得正文，这一限制在sources.json保留；采用实际可读取的官方API及SDK声明，不恢复旧稿未验证的广泛铺材质承诺。

## 实际改动边界

生产改动为pages显示层、NativeMaterial/NativeTheme、entry材质metadata与base/dark颜色资源。Home新增的字段只用于尺寸；Index保留导航/修订/可见性提供者与Smart/Zashboard的onShown/onHidden。对Home、Profile、ProfileEdit、Smart、Zashboard、NetworkSettings、Override、Diagnostics、Settings首个Builder/build之前的方法逐段核对，除新的视觉字段/主题import外与main相同；Zashboard的Web参数、策略与事件块逐字节相同。

ProfileStore、所有现有lib、VPN Extension、Go/C++、配置流水线、热重载、模型和安全源码没有改动。ProxyPage仅继承文字颜色角色，没有增入口；保留临时页清理的既有真机门槛。共享页面在独立工作树修改，用户明确要求本轮先完成、最终统一协调；没有进入本地设备Agent工作区。

## 实际构建与保留失败

官方CLT 26.0.0.851/API26 SDK、Node 26.11.1、JDK27、Go1.27.2。独立试验的普通Tabs/HdsTabs由同一真实ArkTS编译器完整编译，DEFAULT/ENABLE/DISABLE三种metadata均产生未签名HAP。生产真实ArkUI Builder完整HAP编译通过，包含官方barFloatingStyle/ImmersiveMaterial、主题资源与显示改动。

- 首次独立试验失败：ArkTS禁止构造器参数属性、组件字段width冲突、ActionSheet缺message、系统颜色background不存在。修正为明确字段/barSize/必填message/有效系统资源后通过；没有压制编译检查。
- 颜色测试首轮发现旧青色在浅soft底对比度约3.73，小字不达4.5；拆分为原型既有深青文字、按钮填充及暗色按钮前景后，检查的正文/元数据/错误/操作组合均≥4.5。它不证明真实材质背景下全部对比度合格。
- 首个生产包复用旧库，完整身份验证因`github.com/ajg/form`模块不匹配失败。该包不作为交付；按当前锁定模块重新生成库、clean构建及完整验证的结果记录于validation.json/build-identity.json。重新生成忽略产物不改变内核源码或依赖。
- SDK兼容与既有弃用警告保留。运行分支测试验证API21/25及无Syscap不查询新材质、不调用新悬浮方法；API26无材质采用实体降级；不对手机兼容作通过承诺。

最终代码提交 `ac01609b05191fdf20d4cd8e7138f9c81a9a38fc` 的未签名HAP SHA-256为 `05b78b2accb2bf0eb1c8ad0551e1cabbfd0991fff2f55f9f279f04b2ecdf9cb6`。最终包摘要、CRC/ABI/面板资源及实际步骤见[validation.json](validation.json)。最终SDK编译有0条ArkTS警告，未隐藏；固定工具链identity里的pnpm10.28.2是仓库pin，恢复面板实际使用脚本要求的11.20.0。上述十个SDK方法/运行时测试全部通过。原生运行截图为空，不引用旧浏览器图作效果证明。HAP、SDK、库与签名材料不入Git；不安装或发布。

## 真机验收清单

| 场景 | 同状态原生图与交互要求 | 状态 |
| --- | --- | --- |
| 360vp、390vp直屏 | 空/未连接/连接中/已连接/失败；白场/斜面/青缝/速率顺序及小单位；栏侧留白；主动作在栏上方 | 待真机；栏宽计算328/358已做方法测试 |
| 横屏短高度 | 844×390等可用窗口；隐藏重复眉题、内容滚动；主动作与Tabs可达；不落手势区域 | 待真机；布局源码已编译 |
| 699/700/701vp | 首页切两列，状态不重置；Navigation Auto展开/退栈；实际栏宽不超容器 | 待真机；宽度上限方法测试 |
| 960vp宽窗 | 工具列max760居中，首页max1120；三页签max472；详情/面板返回保持会话 | 待真机 |
| 大系统字号 | fp放大、不截关键状态/速率单位、主题切换后重排；标题不侵入斜面；48/56vp动作和Tab标签可达 | 待真机；字号未全局锁定 |
| 系统浅/深 | 稳定的白色状态场；其余资源随主题；Toggle/Select/Dialog/Sheet文字可读；ArkWeb主题跟随需单独核对 | 待真机；静态资源组合对比度通过 |
| DEFAULT/ENABLE/DISABLE | 独立试验显示MaterialInfo真实state；每种系统控件同状态截图；DISABLE负对照 | 待真机；三包metadata/SDK构建验证 |
| 系统强/均衡/弱 | 固定metadata和样式切系统强度；不同设备算力另分组；不要把MaterialLevel当强度开关 | 待真机，无程序伪造结果 |
| Tabs/HdsTabs同机 | 同样留白/内容/字号下看THIN与ADAPTIVE；滚动/点击/系统返回/Sheet焦点和重进页面 | 待真机；两套API均已编译 |
| 无障碍/键盘 | 页签/速率组朗读；长文字/键盘避让；焦点不可落隐藏背景；系统返回关闭弹层 | 待真机；系统控件保留 |
| 设备降级和性能 | 不支持材质/低算力/温控；15分钟滚动与切签记录帧率、温升和耗电；静止首页对照 | 待真机，无功耗实测结论 |

后续原生截图需带源码SHA、签名/未签名包摘要、设备型号/API、窗口vp/像素、系统字号、主题、系统光感强度和当前状态。先核对截图身份再做同状态比较；不要覆盖当前本地首测包或测试工作区。

## 功耗与兼容性结论

本轮不引入传感器、主动振动、循环光效或额外轮询；既有流量/Smart轮询未改。材质仅一层原生导航背板，系统弹层由系统策略处理。uiMaterial等级遵守设备策略，HDS试验为ADAPTIVE并开启温控，未强制高档。预计成本范围受控是工程判断，**没有耗电、温升或帧率实测**。

API21–25基础Tabs和原生控件仍是回退；API26硬件不支持材质保留官方悬浮实体背板。API版本/Syscap/硬件查询测试不证明全部旧设备运行，兼容警告与API21真机验收保留。PR只提供隔离原生候选，不自动合并，PR11完整验收与PR20功能缺口仍按各自任务处理。
