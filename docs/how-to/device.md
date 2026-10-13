# 签名与设备验证

先核对源码 SHA、HAP 摘要、包名和设备范围。正式身份为 `com.starfie1d.cexing`。

使用官方工具链构建未签名包，再由本地匹配包名的 AGC Profile 签名。`scripts/sign-agc.sh` 默认读取工程内 `.signing/cexing-debug.{p12,cer,p7b}` 与 `CEXING_STORE_PW`（或私有 `store_pw`），私钥别名为 `cexing-debug`。签名材料不得入库；旧包名的 Profile 不能直接用于策星。也可使用用户已有 HoKit 签名流程。

通过 HDC 核对目标设备后，运行 `scripts/install.sh` 覆盖安装并启动。手机调试与 VPN 首次授权由用户确认。包名变更会使用独立沙箱，先保留旧应用并通过其导出功能迁移配置；禁止卸载或清除用户数据来绕过问题。

## Smart 与模型

无模型即可使用 `type: smart` 的统计策略。将订阅中的一个现有组改成 Smart，引用至少两个已有可用节点，让规则引用该组；最小片段及参数见 [Smart 契约](../reference/smart-beta.md)。

HAP 已内置 [官方 Release](https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model) 的 **Model.bin**，首次离线安装无需手机再下载。固定大小 9,345,218 字节，SHA-256 为 `23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788`；Extension 在 Go 首次加载前核对并铺盘。原有「获取官方模型」「导入模型」保留作损坏恢复与手动替换入口，服务端仍校验摘要及解析。

导入提示需要重启时，使用「重启应用使模型生效」：会断开 VPN 并重启整个应用，包括持有 Go runtime 的 VPN Extension。重新打开后手动连接。随后在订阅编辑页把目标 Smart 组的 `uselightgbm` 改为 `true` 并重新连接；`collectdata: false`、`prefer-asn: false`、`lgbm-auto-update: false` 适用于首测。只刷新页面或停止/启动 VPN 不能清除模型首次失败的进程缓存。

「模型已加载」与「有效预测次数」分别展示；次数为零表示尚无模型参与证据，非零是全部 Smart 组的进程累计观测，不证明某一次请求采用模型。Controller 不可达不显示成 Smart 已启用。

## 验收方法

- 原有订阅、节点名与选择恢复；URL/文件/粘贴、更新、重命名、编辑和启用后首页同步。
- 首次授权、启动中取消、正常断开/重连、错误配置；迟到操作不能影响新会话。
- 面板 REST/流量 WS 可用，返回、隐藏、失联/重连不停止 VPN，离线资源/CSP/ArkWeb 缓存和导航行为正常。
- 导入模型后应用重启，确认 VPN Extension 进程换代；重新连接产生「模型已加载」及实际有效预测。失败提示保留且可重试。
- 手机浏览器真实 TUN 请求、TLS/REALITY、DNS/UDP、IPv6、Wi-Fi/蜂窝切换；低流量、息屏 15/30 分钟、关窗和回前台。

记录源码 SHA、HAP 摘要、系统版本及脱敏结果。源码审查、Linux 转发、SDK 构建与手机验收是不同证据；Connected 或 `/version` 不能单独证明真实转发。公共反馈不要上传订阅 URL、节点凭据或原始配置。
