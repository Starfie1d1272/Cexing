# 签名与设备验收

未签名构建在云端完成；零售设备的 AGC 调试签名及系统授权在有权访问账号和设备的环境完成。先确认设备空闲、当前包名和用户数据，不卸载已有应用来绕过升级问题。

## 签名准备

账号与下载入口：[华为开发者](https://developer.huawei.com/consumer/cn/)、[AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)。零售真机需要应用、调试证书、注册设备和对应的调试 Provision Profile；SDK demo 证书仅适用于获授权的 OpenHarmony 设备/模拟器。

复用有效材料，避免重建密钥。脚本要求 `clash-openharmony/.signing/` 中的 `clashoh-debug.p12`、`clashoh-debug.cer`、`clashoh-debug.p7b`、`store_pw`；目录及文件限制权限，全部忽略。首次准备可用本地 keytool 生成 EC P-256 keystore/CSR，在 AGC 申请证书和设备 profile。口令由私有渠道保存，不放进命令日志或文档。

核对证书与密钥匹配、profile 的应用身份与设备绑定、有效期，再签名。包名以 `AppScope/app.json5` 为准，安装脚本、profile 与包内身份必须一致。若选用 HoKit 重签，同样核对应用与设备范围。

## 安装与启动

```bash
source scripts/env.sh
hdc list targets
bash scripts/sign-agc.sh
bash scripts/install.sh
bash scripts/logs.sh
```

真机需开启开发者模式并允许 HDC 调试；首次 VPN 系统授权由设备用户确认。应用配置入口支持 URL、YAML 文件及剪贴板；先导入并激活，再点击连接。

## 验收方法

1. 记录源码 SHA、模块/SDK 身份、包摘要、系统版本和脱敏配置条件。
2. 验证授权、扩展连接和内核就绪；不能仅凭页面 Connected 或 `/version` 判定转发。
3. 从手机浏览器发起请求，确认 Controller 的 Tun 连接、规则/代理链和双向字节增长。混合代理端口测试不能代替 TUN 验收。
4. 验证正常停止、重连、启动中取消、错误配置、异常回收与失败回滚。
5. 单独验证 UDP/DNS、HTTPDNS 排除路由、双栈 IPv6 接管及泄漏、Wi-Fi/蜂窝切换。
6. 观察低流量、息屏超过 15/30 分钟、关窗、回前台与系统取消后台任务的行为。面板接入后再测关闭 WebView 及资源损坏。

诊断可临时使用 `hdc fport tcp:19090 tcp:9090` 访问控制面；内核/设备重连后需重建转发。测试完移除临时转发并清理私有中间文件。日志用 `hilog -x` 获取有界快照，不把订阅、节点或凭据贴入公共报告。

已有基线证据见 [P0 记录](../evidence/2026-10-12-p0.md)，它不证明后续构建具有同样设备行为。
