# Ark 本家细节试稿 · 保留轻盈基线

基线固定为 **`9127864ab4fb1ac4cc971238cd8581be40ff4a03`**。开始前已核实本地与 PR #11 都指向该提交，工作区干净。本轮是单独提交的可选试稿，用户看完对照再决定。

## 查看

- [三页同尺寸前后对照](comparison.html)：连接、订阅、设置；390×844 / 960×720。
- [试稿交互入口](../ark.html?state=connected)。
- [冻结的轻盈基线](../baseline-9127864/index.html?state=connected)：独立 HTML / CSS / JS，SHA-256 见 [IDENTITY.json](../baseline-9127864/IDENTITY.json)。
- [现有评审入口](../review.html)：选择“Ark 本家细节 · 试稿”或“鸿蒙轻盈 · 9127864 基线”。默认仍是轻盈版，未替用户选定最终稿。

旧 `index.html`、`app.js`、`styles.css`、`native-light.css` 及旧 PNG 均未覆盖。冻结文件与 Git `9127864` 的字节逐一核对一致。新增截图全部放在本目录。

## 变化理由

1. **青色信号**：短状态线和选中提示使用 Ark 青色；文字、按钮和关键图标仍用可读的深青色。状态卡保持白色与圆角，没有恢复大黑板。
2. **真实数字的排版**：速率、配置数量及时间等现有值使用系统等宽字体与等宽数字；只包裹已有数字，没有新增仪表、数据、条码或编号。中文标签字体不变。
3. **少量结构细节**：双短杠标记实际分组，细线隔开上传 / 下载，原有方向箭头更统一。没有在每一行铺装饰。
4. **原创连接符号**：两端端口与中间连线，用于三个根页标题、连接页签和状态区；不是应用 Logo、包图标或已确定的品牌名。无受保护 Logo、立绘、字体文件或素材。
5. **状态动效**：只在连接中让中间连线短暂移动；已连接 / 未连接都有静态表达。`prefers-reduced-motion` 下移除动画，状态文字与取消按钮继续可用。

三个底部页签、轻盈材质、胶囊按钮、圆角分组、手机与展开态布局均保留。运行代码仍共用既有原型状态机；新脚本只在 `ark.html` 中装饰已生成的界面，不修改原始配置或运行状态。

## 同数据、同视口截图

| 页面 | 手机 390×844 | 展开态 960×720 |
| --- | --- | --- |
| 连接 | [前后对照](screenshots/connected-390x844-compare.png) · [before](screenshots/before/connected-390x844.png) · [after](screenshots/after/connected-390x844.png) | [前后对照](screenshots/connected-960x720-compare.png) |
| 订阅 | [前后对照](screenshots/profiles-390x844-compare.png) · [before](screenshots/before/profiles-390x844.png) · [after](screenshots/after/profiles-390x844.png) | [前后对照](screenshots/profiles-960x720-compare.png) |
| 设置 | [前后对照](screenshots/settings-390x844-compare.png) · [before](screenshots/before/settings-390x844.png) · [after](screenshots/after/settings-390x844.png) | [前后对照](screenshots/settings-960x720-compare.png) |

12 张独立视口 PNG + 6 张浏览器生成的前后对照板；没有把品牌细节画到旧截图上。六组比较的状态快照完全一致，显示文字去除布局空白后一致；仅允许排版产生的换行差异。

## 验证与视觉自审

[验证明细](validation.json)，[可复现脚本](verify.py)。从仓库根目录启动既有静态服务，然后运行 `python3 design/native-ui-fresh/ark-detail/verify.py`；输出只写本目录，不改旧截图。

- 四组任务链覆盖导入、授权拒绝 / 允许、连接、跨页、更新、非法端口、面板失败保持会话、断开、取消过滤迟到回调、窗口连续性及减少动效。
- 手机和展开态各 16 种状态，加另外八种窗口的三个根页，共 56 组检查。三个页签可见，无横向溢出，主窗口可用控件触区≥44px，无浏览器异常。
- 已自行查看三个手机页及展开态：中文标签和按钮层次保持，技术数字没有挤压速率单位；白色卡片、圆角和轻盈留白仍为主体。基线内容未增加或重复。
- Skill 启发式审查完整目录为 0 errors、2 warnings：静态扫描无法识别运行时生成的 `.brand` / `.hero` / 数字包裹等挂钩；冻结副本增加了重复颜色字面量。浏览器已实际验证对应 DOM 与统一色系，未为消除扫描提示修改基线。单独只扫 HTML 会漏掉外链 CSS 与动态语义，不能据此判断真实界面。

所有原生 HDS、SDK 与真机边界沿用 [版本矩阵](../VISUAL-RESEARCH.md)。这是浏览器原型，不声称原生材质、实际 VPN 转发或折叠硬件接入完成。仅改 PR #11 设计目录，不改生产、不合并。
