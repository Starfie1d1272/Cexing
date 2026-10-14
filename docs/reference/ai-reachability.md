# AI 出口可达性

`core/aiprobe` 只检测固定官方 HTTPS 站点的有限响应，不检查账号、API、付费能力或模型权限。状态为可达、明确地区限制、超时、限频、连接失败或未确认。未绑定到已应用 AI 模板的检测应显示“未检查”。

## 路由与安全

每次检测持有一个短期 `127.0.0.1:0` HTTP listener。复用锁定 Mihomo 的认证 HTTP 入站，在既有 runLock 下捕获经过验证的目标 C.Proxy，以该组的 DialContext 和现有 RelayContext 转发 TCP；不使用共享 mixed-port、delay、GLOBAL 切换或临时组选择。组失效时请求失败，不回落系统直连。listener 使用每次随机认证，接入数有限；只允许白名单目标的 443 端口。所有接受的连接（含尚未认证的连接）都归会话所有，取消/结束关闭监听及连接。

客户端保留 TLS 验证，禁用重定向、Cookie jar、继承代理环境与压缩，响应正文上限 64 KiB。Controller 认证只发给既有本机 Controller；独立 listener 的凭据只用于本机 CONNECT，不进入官方站点请求。未请求订阅、私人 provider、付费 API 或用户 URL；正文及错误详情均不进入结果、缓存或日志。内核自身日志须继续经过统一 #141 普通日志脱敏边界。

## 运行身份

`POST /ohos/ai-probe` 注册在既有认证 Controller 路由内，输入只有 `{revision, retry}`。服务器自行读取 Current 的成功 EditIntent.template；它必须是 AI 模板，指针和请求 revision 相同，目标组可用，实际运行配置摘要与 Current/config.yaml 相同。Caller 不能提供目标 URL/组/凭据。摘要仅在运行内存中，不构成新的发布系统。

宿主需在 `coreStartTun` 的 `executor.ApplyConfig(cfg, true)` 后调用 `observeAIProbeConfig(configJson)`，在认证 reload 的同一位置调用 `observeAIProbeConfig(text)`，均在现有 `runLock` 内。该函数定义在本组新增路由文件中。未接入此观察点会保持“未检查”；不能用发布指针代替真实运行身份。reload 到 commit 的窗口因配置摘要不一致被拒绝。每次成功 ApplyConfig 都增加运行代次，即使 YAML 摘要相同也使旧缓存失效。运行中定期核对 Controller epoch、运行代次、Current、配置摘要、目标图对象身份与手动 Selector 选择；变化后取消旧任务，旧结果不缓存/回写。自动组结果归因于该组的本次路由，不永久声称某个节点。后台转发不再经上游 SpecialProxy 对可变全局代理表的无锁查找；短期会话持有组对象并在取消时关闭两端及等待 worker。依赖全局名称查找的 dialer-proxy 链暂不确认，不能将尚未固定的链路假报为目标出口。目标沿共同编译器不透明身份追踪个人重命名；删除后同名新组不能继承检测授权。

每次最多两个服务并发，整次有时限；每个 Manager 只允许一个检测租约，缓存最多十六个身份、通常两分钟。429 按 Retry-After（限定一分钟到十分钟）退避，手动重试不能绕过退避。缓存命中保留原检测时间。429 在读取正文前处理，不能因正文超时丢失退避；明确 challenge 响应保持未知，不能只凭品牌文字报可达。

## 页面生命周期

`TemplateWizard` 已挂载 `AiProbeStatus`；`AiProbeBinding` 从现有成功版本读取 AI 模板元数据，只有同订阅、同已提交目标才给出 revision，草稿切换不授权检测。`AiProbeStatus` 只接受成功应用的 AI 模板 revision。页面退出、revision 改变、VPN 断开或默认网络丢失时销毁在途 HTTP 请求，Controller 请求取消继续关闭探测 listener。页面不停止 VPN。默认只显示短状态/时间，展开后查看服务结果并可重试。

NetConnection 是只读网络观察，不申请/绑定网络。官方 SDK 声明 register 需要宿主模块的普通权限 `ohos.permission.GET_NETWORK_INFO`，应用模块已声明该权限。注册失败不启动检查；迟到的注册回调只清理旧 observer，不能注销新页面的 observer。

## 来源

- [Cloudflare challenge 响应识别](https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/)：使用官方 cf-mitigated 信号识别 challenge；不复制示例实现。

- [Mihomo listeners proxy](https://wiki.metacubex.one/config/inbound/listeners/#proxy) 定义显式出站语义；实际代码固定在 go.mod 的 replace 版本，而非只看声明版本。
- 锁定 [ProxyAdapter DialContext](https://github.com/vernesong/mihomo/blob/daf3ad03021c/constant/adapters.go) 与 [RelayContext](https://github.com/vernesong/mihomo/blob/daf3ad03021c/common/net/context.go) 仅通过依赖调用，未移植实现。
- 锁定 [HTTP 入站](https://github.com/vernesong/mihomo/blob/daf3ad03021c/listener/http/proxy.go)、[入站元数据](https://github.com/vernesong/mihomo/blob/daf3ad03021c/listener/inbound/base.go) 与 [SpecialProxy 路由](https://github.com/vernesong/mihomo/blob/daf3ad03021c/tunnel/tunnel.go) 通过已有 dependency 调用，未复制客户端检测源码。

真实官方服务可达、VPN 网络保护、Wi-Fi/蜂窝切换与设备后台行为仍需 #92 真机验收。合成 TLS、监听、路由和生命周期测试不构成真实服务解锁或系统 TUN 转发证据。
