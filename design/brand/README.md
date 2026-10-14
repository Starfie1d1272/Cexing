# 策星图标

星球、向右上倾斜的环带和右上卫星构成品牌标志。立体版本使用青色球体和浅青环带，背景为深色 `#091A20`；简化标志使用青色与浅青色，保留透明背景。

## 资源

| 文件 | 用途 |
|---|---|
| [app_icon_foreground.png](../../cexing/AppScope/resources/base/media/app_icon_foreground.png) | 1024×1024 RGBA 立体前景；也用于启动窗口 |
| [app_icon_background.png](../../cexing/AppScope/resources/base/media/app_icon_background.png) | 1024×1024 完全不透明背景，无预裁圆角 |
| [app_icon_layered.json](../../cexing/AppScope/resources/base/media/app_icon_layered.json) | 应用与入口 Ability 的分层图标定义 |
| [app_icon.png](../../cexing/AppScope/resources/base/media/app_icon.png) | 前后景原尺寸合成，用于现有快捷方式的单张图片引用 |
| [cexing-mark-flat.png](cexing-mark-flat.png) | 1024×1024 透明简化标志，供文档及品牌展示使用 |

应用资源统一保存在 AppScope。构建会将其合入模块资源，entry 中不要再放置同名副本。启动窗口使用透明前景，与系统启动窗口背景组合；快捷方式保留单张图片。此目录的品牌展示资源不打入 HAP。

## 平台约束

依据华为官方[应用图标：图标资源规范](https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/application-icon-0000001953444009#section634668113212)：手机、折叠屏、平板使用 1024×1024 PNG 前景、背景两层；背景不得含透明像素，资源保持完整正方形，圆角与遮罩由系统处理。主体居中且避开四角，保留正确压缩与清晰度。

[配置应用图标和名称](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/layered-image)规定使用 `layered-image` 对象引用 `background` 与 `foreground`，应用和入口 Ability 的 `icon` 均引用该 JSON 资源。AppScope 同名资源会覆盖模块资源。

## 编辑与验证

前景和简化标志由内置 imagegen 基于已选定的星域设计生成，当前源文件为 PNG，无矢量母版。生成要求为：保留青色星球、左下至右上的斜环与右上卫星；立体前景保留球体光影，简化版减少光影；透明方形画布，无文字、底板、外部投影。工程资源从较大原图等比缩小至 1024×1024，未放大。

修改前景后，将其与背景按相同画布、原尺寸叠合，更新 `app_icon.png`。保持前后景尺寸一致，不把预览中的圆角写入资源。导出后检查 PNG 尺寸、前景透明通道、背景全不透明，并比较 32、48、64、128、256 像素显示效果。检查圆形及圆角遮罩不会切掉主体。

按[构建指南](../../docs/how-to/build.md)执行回归及包含 clean 的 HAP 构建；检查包内分层 JSON、三张图标 PNG 与配置引用。真机桌面、启动窗口和系统主题效果须单独验收。应用市场上传素材应在提交时按 AGC 素材规范另行核对。
