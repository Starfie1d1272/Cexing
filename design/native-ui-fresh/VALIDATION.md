# 2026-10-12 验证记录

源码基线 main `7f731d5c9c8d4eba7a1680bcb3981d7877232bcc`；Skill 固定为 `0b22e94f025282dc3372469f278ac9d13da6a079`。环境为云端 Linux，Chromium 身份、各视口尺寸和逐流程通过记录在 [validation.json](validation.json)。

## 原型验证

- `node --check app.js` 通过。
- Ark UI 自带 `audit-ark-ui.mjs` 审查：0 errors、0 warnings；通过颜色 token、来源、焦点、响应式和 reduced-motion 等启发式检查。启发式检查不等于完整无障碍认证。
- `verify.py`：10 组浏览器任务链通过；60 组视口/状态无横向溢出，所有可用按钮 / 输入框 / 选择器命中区 ≥44px；radio 由整行 label 提供触区；无运行时异常；未写 localStorage。
- 浏览器实际走通 URL、文件、手动粘贴 YAML、Merge 草稿及差异、授权拒绝 / 允许、取消过滤迟到回调、连接 / 断开、更新失败重试、面板失败不停止 VPN、删除前断开、设置、分层诊断和合成文件导出。
- modal 焦点限制 / Escape 返回、减少动态效果均验证；主要页面的长内容用实际滚动可达，未缩小必要文字。
- 1440×1000 桌面评审入口实际渲染，状态切换、手机尺寸选择、moderate 对照和网络恢复控件通过，无横向溢出或运行时异常。
- 本地 HTML / CSS / JS 入口与 Markdown 相对链接检查通过。交付只有原创实现、说明、合成数据与浏览器截图。

复现：先从仓库根目录 `python3 -m http.server 8765 --bind 127.0.0.1`，再 `python3 design/native-ui-fresh/verify.py`。需要环境安装 Python Playwright 与 Chromium，脚本不安装依赖或调用生产 API。

## 自行视觉审查与修订

在实际截图上发现并修复：首次使用第三个导入项被底部操作压住；覆写页可选说明位置太低；360×800 的面板交接说明靠近主操作；moderate 状态标记占据额外高度；部分短文字动作的触区不足。

最终按相同视口重渲染：首次使用三种导入一屏可见；390 / 360 / 412 已连接页面的交接区域与底部按钮不碰撞；320×568 采用紧凑字号和间距、去除已有导入行重复表达的说明；设置与错误详情保留垂直滚动。minimal 不加装饰层，moderate 仅保留边缘壳层与低对比纵线。明暗文本均采用高对比中性色；未使用青色小字作正文。

## 仓库基线回归

按照 AGENTS / 构建指南初始化现有工具链后执行四个现有回归，全部通过：

- `test-profile-name.cjs`：11 个实际 ArkTS 命名用例。
- `test-vpn-startup.cjs`：就绪、错误传播、取消与扩展生命周期。
- `test-app-runtime.cjs`：进程拥有后台服务、恢复、转换与自动恢复。
- `test-background-lifecycle.cjs`：延迟启动 / 停止、过期取消、上下文重新绑定。

`build-hap.sh` 未签名 HAP 构建成功；ZIP CRC 无错误，包含 libmihomo.so、libentry.so、libc++_shared.so、override.yaml 与 geodata/geoip.metadb。产物 SHA-256：`453ab3b2dbac6f397d1b387c8272d433fd872464c7b34ec12b3e3deb45877739`。HAP 不入仓，不作为原型交付。

构建有 main 已有的 SemVer、clang 参数、ArkTS / 弃用 API 与 SDK 兼容警告，本次未修改生产代码处理它们。此构建验证的是 main 生产宿主；原型未打入 HAP，未签名、未安装、未做真机 VPN / 流量测试。
