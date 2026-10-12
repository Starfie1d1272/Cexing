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
| 必要设置 | [settings](settings-390x844.png) · [全页](settings-390-full.png) |
| Zashboard 交接 | [panel](panel-390x844.png) |
| 面板加载失败 | [panel-error](panel-error-390x844.png) |

| 手机尺寸 | 首次使用 | 已连接 |
| --- | --- | --- |
| 360×800 | [截图](empty-360x800.png) | [截图](connected-360x800.png) |
| 412×915 | [截图](empty-412x915.png) | [截图](connected-412x915.png) |
| 320×568 | [截图](empty-320x568.png) | [截图](connected-320x568.png) |

四种尺寸各验证全部 15 种状态，共 60 组；24 张交付截图。小屏的长内容允许垂直滚动，底部主动作始终可达。390×844、360×800、412×915 的已连接首页保证面板交接区域位于底部操作上方；320×568 的首次使用页仍完整显示三个导入入口。
