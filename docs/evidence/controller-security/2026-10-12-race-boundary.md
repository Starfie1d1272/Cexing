# 入站 policy race 归属与修复边界（2026-10-12）

基于 PR #9 `a558fe8672810603fd9d1e2c32cfe299e428cbbb` 继续，模块仍为 Mihomo v1.19.32。此前具体 race 与资源验证见 [资源清理证据](2026-10-12-resource-cleanup.md)。本次安全范围内修复了默认代理 authStore 的并发访问；剩余三项需要锁定上游同步改动，未改 go.mod、模块缓存或其他线文件。

## 两类实际并发栈

以下为真实 Go race 检查捕获的函数栈，去除机器路径/地址。writer 最下层是合成回归，生产入口链单独在下一节说明；没有声称抓取真机栈。

前缀切片 reader（generic HTTP accept goroutine）：

```text
inbound.isAllowed                 ipfilter.go:42
inbound.IsRemoteAddrDisAllowed    ipfilter.go:36
http.NewWithConfig.func2          server.go:139
```

与之并发的 writer：

```text
inbound.SetAllowedIPs            ipfilter.go:14
executor.updateListeners         executor.go:195
executor.ApplyConfig             executor.go:107
TestControllerSecurity generic ApplyConfig/restart fixture
```

另外两项同形：isDisAllowed（ipfilter.go:46）/SetDisAllowedIPs（:18，updateListeners:196），skipAuth（auth.go:37）/SetSkipAuthPrefixes（:13，updateListeners:194）。这些 reader 直接读取私有切片变量，原 setter/getter 也无同步。

默认 proxy authenticator reader（已接受 HTTP 的独立 handler）：

```text
listener/auth.authStore.Authenticator   auth.go:12
http.HandleConn                        proxy.go:45
http.NewWithConfig.func2.gowrap1        server.go:147
```

writer：

```text
listener/auth.authStore.SetAuthenticator auth.go:16
executor.updateUsers                     executor.go:433
executor.ApplyConfig                     executor.go:99
TestControllerSecurity next ApplyConfig after stop
```

## 产品路径可达性与归属

- 启动：coreStartTun → executor.ApplyConfig(force=true) → updateListeners。上游先 PatchInboundListeners 并启动 generic accept goroutine（executor.go:187），再写 skip/allowed/disallowed 三个全局切片（:194–196）。新接受连接能读这三个变量，wrapper 的 runLock 不在这些 reader 上。
- 热重载：reloadPlatformConfig → 同一个 executor.ApplyConfig。既有 generic listener 可因 Config.Equal 保留、仍接受连接；updateListeners/updateUsers 写入与 accept/HTTP handler 读取可重叠。没有“所有客户端只会在配置完成后连接”的产品保证。
- 停止/快速重启：PatchInboundListeners 移除并关闭监听器，但其 Close 没有等待全部已接受 HTTP handler。旧 handler 的 Authenticator() 读可与下一次 ApplyConfig/updateUsers 写重叠；这正是新增两轮真实 TCP 回归捕获的第四项。

因此不是纯测试故障。已有 runLock/executor.mux 只串行化配置应用，不串行化上游接受连接/handler。移动创建顺序只能减少首次启动窗口；清空监听器后再 apply 仍不能证明旧已接受 handler 全部退出，也会改变无差异重载行为。未采用 sleep、删场景、fixture 改认证、race 抑制或写侧单独加锁来掩盖。

## 已在 wrapper 修复的默认 proxy authStore

通过上游公开 auth.AuthStore 接口，在本包 init 时一次性将 exported Default 包装为 RWMutex 保护的代理对象，内部继续委托原 store。模块源码核对 Default 使用均在运行时；在启动 reader 之前安装，之后不更换全局对象。HTTP/SOCKS/mixed 与 executor 保持同一 store 身份，保留已有 nil/用户名密码/不可变 authenticator 快照语义。这是代理认证，**不是 Controller Secret 注入或新的认证策略**。

定向并发替换/读取的 race 测试通过，1000 次 nil/有效对象切换，不删除或放宽 Verify；generic 两轮场景重新执行后仅剩三个前缀切片 race，原 authStore 冲突不再出现。完整功能回归与 vet 通过，跨编译、clean 未签名 HAP/CRC/资源/AArch64/新库→strip→HAP 身份通过。当前完整 race 仍不能报绿，因为三项未修复。

## 需要上游边界的最小提案（未应用）

[review-only patch](../../reference/controller-security-upstream-sync.proposed.patch) 仅针对两个固定上游文件：

- adapter/inbound/ipfilter.go：声明共享 inboundPolicyMu，保护两个 setter/getter 和两个直接匹配 reader；复制传入/返回切片，避免外部别名修改共享状态。
- adapter/inbound/auth.go：同一个锁保护 skipAuthPrefixes 的 setter/getter/直接 reader，同样复制切片。

没有把 patch 接入脚本、下载修改版、建立 replace 或编辑缓存。该提案尚未应用/编译/运行，不能宣称已修复。它按现有独立 setter API 解决数据同步，不提供三个 setter 跨调用的原子 policy 事务，也不改前缀匹配与认证语义。

需要父任务先确定锁定上游的补丁/来源管理方式，涉及明确的内核依赖源改动；即使保持 go.mod 版本文本不变，改源码仍改变依赖身份和构建完整性，不能偷偷编辑共享缓存。获定后必须在隔离依赖环境完整 race、启动/重载/快速重启和 OHOS HAP 重验，交独审再决定合流。

## 最新 wrapper 产物摘要

| 产物 | SHA-256 |
|---|---|
| libmihomo.so（包内） | `d11cab1aedc1369a22bb1816c1a252d56bc0afd977f7c4758b2277741373b680` |
| libentry.so（包内） | `72846b45abc1c910d65453fd030f2ab31167e740cf4cbd9de913217a57bf3cfe` |
| libc++_shared.so（包内） | `965803c3fe53e02452e4c0479ad13c88f166c04207d27e3c531161a7c75a6c17` |
| 未签名 HAP | `c64e210b3f17a4d5560f38d6680eb390d424a3913b92c3be68521fab3a3485ea` |
| libmihomo.so（去符号前） | `8b9f252c6c8994f6faf058e9cbfe5f1a1075f3de79759eb51dba6cb8c03f6513` |

无真实设备、真实订阅/长期凭据、签名、安装、合并或发布操作。证据仅覆盖上述合成 host 测试及构建；真实转发与前后台运行仍未执行。
