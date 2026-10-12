# 设计验证证据 · 2026-10-12

源码基线：`7f731d5c9c8d4eba7a1680bcb3981d7877232bcc`，分支 `design/native-ui-concept`。远端 main 在创建分支时核对为同一 SHA。仅提交 `design/native-ui/`；没有生产代码、品牌身份或共享文档变更。

## 浏览器实际渲染

环境：Linux，Chromium `154.0.8037.57`（Debian 13），Python Playwright `1.62.0`。使用已安装浏览器，不下载或执行参考仓库脚本。本地 HTTP 服务仅绑定回环。截图由 Playwright 的 `page.screenshot` 生成，源画面为本目录实际 HTML/CSS/JS，未使用 ImageGen 或手工画布模拟截图。

命令（仓库根目录）：

```bash
python3 -m http.server 8769 --bind 127.0.0.1 --directory design/native-ui
# 在另一个终端执行；需预装 Python Playwright 与 /usr/bin/chromium
python3 design/native-ui/render.py
```

`render.py` 完成 126 次场景/视口布局检查，生成 46 张原始 PNG 与 1 张六画面总览 PNG；[manifest](screenshots/manifest.json) 记录原始截图身份。21 场景在浅深色各 390×844 渲染；全部场景额外经过 360×800、412×915、浅色 moderate、深色 moderate 的横向溢出检查。额外尺寸与深度保存内核就绪页的四张截图。总览是浏览器渲染原始 PNG 画廊后再次截图，原始页面 PNG 才是逐屏视觉证据。

自动检查通过：主体/页面无横向溢出，主体按钮高至少 48 CSS px，无 JS 页面错误，交互路径期间仅请求回环服务。关键交互检查涵盖：三种导入方式中的文件演示、覆写选择、校验失败返回、启用、授权拒绝与重试、取消连接、超时后重试、面板失败返回保持内核就绪、更新失败保持会话、关闭恢复偏好与取消重置、断开中按钮禁用后完成断开。

人工检查 390×844 的浅/深色内核就绪、连接中与深色预览画面：状态和主动作可见，文字可读，内核就绪首屏显示面板入口。主体允许滚动；长场景与窄屏不强求全部内容首屏显示。minimal 与 moderate 对照保持相同业务内容，新增几何不占用触区。

## 仓库回归

复用环境中官方 CLI 工具链，按构建指南初始化环境后运行：

- `node scripts/test-profile-name.cjs`：11 个真实 helper 用例通过。
- `node scripts/test-vpn-startup.cjs`：就绪、错误传播、取消、扩展生命周期通过。
- `node scripts/test-app-runtime.cjs`：进程级后台服务、恢复、状态切换通过。
- `node scripts/test-background-lifecycle.cjs`：延后启动/停止、迟到事件、上下文重绑定通过。
- 本地文档链接与 `git diff --check` 在提交前检查。

曾在未初始化环境时尝试 profile-name 检查，因要求先 source env.sh 停止；按指南初始化后四项检查通过。这是工具调用前置问题，不是代码修复。浏览器自动检查中曾发现文字定位与底栏同名导致选择器歧义，限定到主体/heading 后通过，未改变业务逻辑规避检查。

`bash scripts/build-hap.sh` 实际尝试后停止在 `Missing GeoIP snapshot` 前置检查。独立工作树未包含忽略的 GeoIP 资源，本次没有生成 HAP，也没有用其他分支构建结果替代本分支证据。设计目录不参与应用打包；这是应用构建证据缺口，不阻塞设计评审 PR。未下载额外地理数据，未进行签名或发布。

## 限制

所有状态均由演示按钮驱动，未证明配置解析、原子事务、系统授权、Controller 认证、实际转发、Smart、Zashboard 或后台保活。截图来自浏览器，不能替代 ArkTS 编译、HarmonyOS 原生布局/无障碍/放大字号/安全区域与真机证据。未操作真实设备 VPN 或安全设置，没有真实订阅、令牌、证书、节点或私有配置。
