# Hokit 签名与手机首测

云端交付未签名 HAP；本地使用用户已有的 Hokit/HoKit 一键签名流程，选择下载的 HAP，核对包名与设备范围后签名并安装。无需在本次首测重新走旧 keytool/AGC 手动流程。云端不读取签名材料、不连接设备、不正式发商店。

## 最短操作

1. 下载 GitHub 首测制品中的 `entry-default-unsigned.hap` 和 `SHA256SUMS`，核对摘要。
2. 手机启用开发者模式和 USB 调试，连接电脑并在手机上允许调试。
3. 在 Hokit/HoKit 中选择该 HAP，按已有的一键签名/安装流程操作；不要卸载或清空已有数据来绕过升级问题。
4. 打开应用，在「订阅」导入并启用原有 URL、YAML 文件或粘贴配置；回「连接」点击 VPN，确认系统首次授权。
5. 点击「Zashboard 面板」选择原有 Selector 组的节点；用手机浏览器访问目标站点，核对实际代理链及双向流量。

不同 Hokit 版本的入口名称可能不同；按本地已有流程完成。包名以包内 AppScope 身份为准，应用名称尚未最终确定。

## Smart 与模型

无模型即可使用 `type: smart` 的统计策略。将订阅中的一个现有组改成 Smart，引用至少两个已有可用节点，让规则引用该组；最小片段及参数见 [Smart 契约](../reference/smart-beta.md)。

需要 LightGBM 时，在「设置 → Smart → 获取官方 Model.bin」打开 [官方 Release](https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model)，下载 **Model.bin** 到手机（不要选择 middle/large）。然后点「选择模型文件并导入」。固定大小 9,345,218 字节，SHA-256 为 `23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788`；服务端校验摘要及解析后原子安装。HAP 不打包模型，也不自动下载。

导入提示需要重启时，使用「重启应用使模型生效」：会断开 VPN 并重启整个应用，包括持有 Go runtime 的 VPN Extension。重新打开后手动连接。随后在订阅编辑页把目标 Smart 组的 `uselightgbm` 改为 `true` 并重新连接；`collectdata: false`、`prefer-asn: false`、`lgbm-auto-update: false` 适用于首测。只刷新页面或停止/启动 VPN 不能清除模型首次失败的进程缓存。

「模型已加载」与「有效预测次数」分别展示；次数为零表示尚无模型参与证据，非零是全部 Smart 组的进程累计观测，不证明某一次请求采用模型。Controller 不可达不显示成 Smart 已启用。

## 待手机验收

- 原有订阅、节点名与选择恢复；URL/文件/粘贴、更新、重命名、编辑和启用后首页同步。
- 首次授权、启动中取消、正常断开/重连、错误配置；旧断开确认不能影响新会话。
- 面板 REST/流量 WS 可用，返回、隐藏、失联/重连不停止 VPN，离线资源/CSP/ArkWeb 缓存和导航行为正常。
- 导入模型后应用重启，确认 VPN Extension 进程换代；重新连接产生「模型已加载」及实际有效预测。失败提示保留且可重试。
- 手机浏览器真实 TUN 请求、TLS/REALITY、DNS/UDP、IPv6、Wi-Fi/蜂窝切换；低流量、息屏 15/30 分钟、关窗和回前台。

记录源码 SHA、HAP 摘要、系统版本及脱敏结果。源码审查、Linux 转发、SDK 构建与手机验收是不同证据；Connected 或 `/version` 不能单独证明真实转发。公共反馈不要上传订阅 URL、节点凭据或原始配置。详细 UI 条目见 [原生 UI 检查清单](../evidence/native-ui/DEVICE-CHECKLIST.md)。
