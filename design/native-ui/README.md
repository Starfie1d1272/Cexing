# 原生界面概念

设计评审产物，基于 `main` 的 `7f731d5c9c8d4eba7a1680bcb3981d7877232bcc`。仅此目录发生变化。应用名、包名、图标及仓库名保持原样；原型页标题为中性占位。所有订阅、速率、错误和授权均为合成演示，不代表集成已完成。

从仓库根目录运行 `python3 -m http.server 8769 --bind 127.0.0.1 --directory design/native-ui`，浏览器打开 `http://127.0.0.1:8769/`。也可直接打开 [index.html](index.html)，不需要构建或安装依赖。URL 参数 `scene=connected&theme=dark&depth=moderate` 可直接定位场景。手机通过「演示选项」切换外观和场景，桌面使用侧栏。首次进入依次点击添加订阅、继续、校验与预览、启用配置、连接，再模拟授权和就绪。阶段变化由明确的演示按钮驱动，没有自动假连接。

- [截图总览](overview.html)：六张浏览器渲染画面与深度对比。
- [全部截图](screenshots/manifest.json)：21 场景的深浅色 390×844 截图，以及 360×800、412×915 和 moderate 对比。
- [信息架构与旅程](journeys.md)：边界、状态、失败恢复及交互行为。
- [视觉规范](visual-spec.md)：颜色、文字、触区与响应式。
- [ArkTS 实施建议](implementation.md)：实际源码映射、待协作接口与门槛。
- [验证证据](evidence.md)：实际完成的检查与限制。

本次优先推荐 `ark + minimal`：保留连接／订阅／设置三页签，直线分区与方形状态标记只服务层级识别。`moderate` 在相同内容上增加分区导轨与一处斜切，供评审比较；不据此锁定品牌。

## 来源与许可

只读核对 [Brandon030722/ark-ui-skill](https://github.com/Brandon030722/ark-ui-skill/tree/0b22e94f025282dc3372469f278ac9d13da6a079) 的公开说明、根目录与许可元数据（2026-10-12）。该项目的 Ark 指鹰角邻接视觉语法，不是 HarmonyOS ArkUI。该快照无根目录 LICENSE，GitHub `license` 为 `null`；不能视作取得模板或素材的再分发许可。本目录 HTML/CSS/JS、布局与文字为独立实现，没有复制该仓库代码、字体、图标、游戏素材或执行其软件。仅参考公开说明中直线分区、方形控件、几何与深度区分的方法。颜色为中性灰绿占位；字体使用系统已有中文字体，不分发字体。

用户安排来源：Library 附件 `libfile_5617346dcabc8191892343c0945dffec`，第 938–1100 行任务 ⑨；源附件未复制进仓库。仓库约束依据 [架构](../../docs/architecture.md)、[配置契约](../../docs/reference/configuration.md)、[组件集成](../../docs/reference/integrations.md)、[平台参考](../../docs/reference/platform.md)。工作区 `.agents` 为空，仓库无 `.agents/skills`。

入口文档修改建议由父任务统筹：在设计评审阶段可给文档索引增加此目录链接，生产实现验收完成前不修改总体开发门槛。
