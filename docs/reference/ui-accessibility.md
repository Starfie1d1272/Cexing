# 中文资源与无障碍契约

默认层只保留当前状态、核心操作、必要失败及修复。新增可见文案必须回答：是否影响当前决策、能否自动处理、能否用布局或操作替代、能否按需展示。技术证据放详情，完整脱敏日志由既有诊断导出承担。LAN、敏感备份、覆盖或数据损失确认只在触发相应动作时出现；读屏标签不能成为重复的可见长说明。

## 字符串资源

原生操作、状态、弹层、占位符、失败及读屏文本使用 entry/resources/zh_CN/element/string.json，base/element/string.json 提供同名英文 fallback。品牌与必要协议名保留原名。相同含义共用资源，不将具体节点、策略名、订阅名或用户输入翻译成固定文案。内部状态码、日志/导出 schema 和 Controller 参数不做显示文案替换。

ResourceStr 支持位置直接使用 `$r('app.string.<name>')`。需要 string 的 API 在展示层用 context.resourceManager.getStringSync(resource.id, ...args) 格式化；不要拼接固定中文句子，不引入另一个偏好、配置或发布系统。错误保留结构化原因，在展示层映射短反馈；未知状态不能借翻译映射成成功。

资源名采用用途明确的 snake_case：共用动作 action_retry/action_cancel 等，领域状态 smart_*、background_*、diagnostics_* 等。所有 locale 的同名资源使用相同格式参数数量和顺序；动态数量使用参数，必要时采用平台 plural 资源。资源文件不得加入私人 URL、Token、真实节点和日志。

## 操作语义

优先使用原生 Button/Toggle/Select。需要保留 Row/Text 点击时使用等价 role、名称、selected/checked 和 disabled 语义；不把点击容器及子文本同时暴露成重复动作。装饰图形排除读屏，按钮名称说明动作；分流三模式、标签与导航提供真实选中态。禁用操作提供简短原因，可在 accessibilityDescription 中补足，不在默认层复制整段说明。

本项目最低兼容 API 允许的语义使用 AccessibilityRoleType.BUTTON、accessibilityText、accessibilityDescription、accessibilitySelected、accessibilityChecked；不要将 role 写成未经 SDK 验证的字符串。ArkUI Component 继承 CommonAttribute，组件状态/方法不能与 background 等平台属性重名。宿主 TypeScript 转译不能证明 ArkTS 类型与 API 兼容，必须由官方 SDK 编译。

## 字号、焦点与异步交互

操作区使用最小高度和内容自适应，避免固定高度裁切增长的文字。长内容放可滚动区，主连接/保存/退出动作和底部导航保持可达；多动作窄屏可以纵向排列。主要触控目标至少 44 vp，按组件实际内容增加。

人工布局矩阵：字号 1.0×、1.3×、1.75×；窄屏/横屏；浅色/深色；读屏和焦点。检查名称/动作/选中/禁用原因、焦点顺序、弹层打开与系统返回后的焦点恢复，以及键盘不遮挡保存。尺寸的源码检查和编译均不能替代实际读屏与布局验收。

每个异步入口保留少量关键风险回归：重复点击、取消/返回、页面切换/重开、旧回调或旧 Controller 结果。页面仅拥有展示观察者，离开不能停止 VPN/后台任务。已经明确应用并提交的事务不能在“取消”文案中伪称已撤销。

## 全仓收口

运行 `node scripts/audit-ui.cjs` 生成当前提交的资源候选/点击点清单。它只读 Git 跟踪的生产 ArkTS 和资源，不访问应用沙箱、私人订阅或设备；候选包括库中的中文错误，需确认是否用户可见。报告为静态线索，不能当成无障碍通过证明。

页面合流前由其单一所有者维护，资源/语义收口在稳定页面上逐个执行，不同时横扫多个组施工的页面。清单中的每个主要操作必须核对资源、原生或等价角色、选中/禁用语义、字号与焦点，验收结果记录在对应 PR/Issue，不在入口文档重复进度表。设备矩阵集中 [#92](https://github.com/Starfie1d1272/Cexing/issues/92)。

依据：[OpenHarmony 通用无障碍属性](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-attributes-accessibility.md)、[ResourceManager 官方接口](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-localization-kit/js-apis-resource-manager.md)。接口签名另与本项目固定 API 26 SDK 声明核对。只借鉴平台契约，无复制外部 UI 模板。
