# 实际手机浏览器截图

Chromium，device scale factor = 1，真实视口与 PNG 像素尺寸一致。以 `verify.py` 从 HTTP 页面渲染，QA 状态固定在内存中；没有合成手机外壳、图片拼贴或旧设计素材。全页截图补充较长页面，不代替视口验证。

| 390×844 状态 | 截图 |
| --- | --- |
| 首次使用 | [empty](empty-390x844.png) |
| 准备连接 | [ready](ready-390x844.png) |
| 系统授权示意 | [permission](permission-390x844.png) |
| 连接中 / 可取消 | [connecting](connecting-390x844.png) |
| 已连接 · minimal | [connected](connected-390x844.png) |
| 已连接 · moderate 对照 | [moderate](connected-moderate-390x844.png) |
| 断开确认 | [disconnect](disconnect-390x844.png) |
| 订阅确认 | [review](review-390x844.png) |
| 覆写方案 | [overrides](overrides-390x844.png) |
| 首次导入失败 | [import-error](import-error-390x844.png) |
| 订阅更新失败 | [update-error](update-error-390x844.png) · [全页](update-error-390-full.png) |
| 网络中断 | [network-error](network-error-390x844.png) |
| 分层诊断 | [diagnostics](diagnostics-390x844.png) |
| 订阅页签 | [profiles](profiles-390x844.png) |
| 必要设置 | [settings](settings-390x844.png) · [全页](settings-390-full.png) · [滚动到底](settings-scrolled-390x844.png) |
| Zashboard 交接 | [panel](panel-390x844.png) |
| 面板加载失败 | [panel-error](panel-error-390x844.png) |

| 手机尺寸 | 首次使用 | 已连接 |
| --- | --- | --- |
| 360×800 | [截图](empty-360x800.png) | [截图](connected-360x800.png) |
| 412×915 | [截图](empty-412x915.png) | [截图](connected-412x915.png) |
| 320×568 | [截图](empty-320x568.png) | [截图](connected-320x568.png) |

十种窗口各验证全部 16 种状态，共 160 组。当前目录交付 40 张 PNG，classic 子目录保留 38 张原版与同窗口对照图。小屏的长内容允许垂直滚动，“连接 / 订阅 / 设置”三个页签固定在视口底部，滚动主内容后仍完整可达；主动作独立位于页签上方。390×844、360×800、412×915 的已连接首页保证面板交接区域位于底部操作上方；320×568 的首次使用页仍完整显示三个导入入口。

## 本轮优先交付

- [390×844 同尺寸前后对照](comparison-connected-390x844.png)；[保留的原版](classic/connected-390x844.png)。
- [960×720 展开态](connected-960x720.png)；[同尺寸原版](classic/connected-960x720.png)。
- [多形态图](window-forms.png)与[可切换同尺寸对照](../comparison.html)。
- 补充窗口：[阔直屏 480×900](connected-480x900.png)、[双折展开 840×1120](connected-840x1120.png)、[三折展开 1200×900](connected-1200x900.png)、[高度受限 844×390](connected-844x390.png)、[高度减少 390×520](connected-390x520.png)。

这里的像素为浏览器逻辑窗口夹具，非指定硬件规格。CSS 透明和 blur 只示意材质层次，不代表原生 HDS 接入。第三方参考图不在本目录，来源见 [视觉研究](../VISUAL-RESEARCH.md)。
