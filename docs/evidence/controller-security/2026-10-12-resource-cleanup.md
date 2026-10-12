# Generic inbound 与 silent 日志资源清理（2026-10-12）

在 PR #9 `229fade35fc3329e0bcec02b29d61c9502f547ee` 上继续；依赖仍为固定 Mihomo v1.19.32，不修改 go.mod/go.sum、缓存模块或其他线文件。接口见 [Controller 契约](../../reference/controller-security.md)。本证据补充 [P0 合流修复](2026-10-12-p0-followup.md)，不把其历史 race 通过外推到新增 generic 用例。

## 复现与最小改动

- 旧 head 在临时目录使用真实 preparePlatformConfig/executor.ApplyConfig、mixed-port=0、DNS 关闭及 loopback generic HTTP。停止前 TCP 可连；coreStop 后新 TCP 仍可连，新增回归失败。测试不请求外部目标，不证明代理转发。
- 旧 head 使用真实 Bearer /logs?level=silent WS，runtime.Stack 确认上游 getLogs 等待；stopController 返回后其 handler 仍在，新增回归失败。复现不靠持续日志唤醒等待者。
- coreStop 增加公共 PatchInboundListeners 空集合/dropOld、PatchTunnel 空集合和空 TuicServer 清理；Controller 和固定端口的既有清理保留。listener.Cleanup 只处理自动 TUN，因此不是代替方案。
- /logs 改为可取消的宿主 handler，复用锁定 WS 库/上游导出日志记录类型；读取用于 close/ping/pong，退出退订并 join relay/reader。relay 在退订完成前持续排空 observable，避免发射器持锁阻塞导致退订无法完成。
- Controller 停止对日志注册加关闭栅栏，关 socket、取消会话，等待受控日志资源完成；不无限等待所有 API handler。原会话代次仍保护排队 PUT/PATCH。

## 已完成验证

- 完整 `go test -v -tags netgo ./...` 通过，包括之前 8 类坏 UI、16 轮 Controller/WS、认证/路径/重载/Secret 投影等场景。
- Generic HTTP 两轮真实 ApplyConfig→TCP 接受→coreStop→新 TCP 拒绝→立即重绑定通过；fresh ApplyConfig 可再次监听。未证明既有 generic 代理转发连接已全部退出。
- Silent 日志：peer close 不需新日志即可释放 handler；stop 返回时 handler、relay、reader 的 runtime.Stack 帧已消失；新 session 的 silent WS 可再建立/清理。普通和 structured JSON、Controller Secret 脱敏及 ping/pong 通过。
- 定向 silent 资源用例的 `go test -race -v -tags netgo -run 'TestControllerSecurity/silent-log'` 通过，go vet 通过。完整功能通过不冒充完整 race 通过，见下一节。
- 客户端认证/重连、恢复代次与原四组 ArkTS 回归通过。OHOS arm64 跨编译与四 ABI 检查、clean 未签名 HAP、ZIP CRC/必要资源/AArch64 ELF、新库→strip→HAP 身份核验通过。
- git diff --check 通过；不签名、不安装、不发布，不操作真实设备 VPN/安全设置。仅临时合成配置/凭据与本机 loopback TCP。

## 剩余阻塞：上游 generic 入站并发访问

**完整 `go test -race -v -tags netgo ./...` 未通过。** 当前执行捕获四项数据 race，均在锁定上游：

| 读路径 | 写路径 |
|---|---|
| inbound.isAllowed（ipfilter.go:42，HTTP accept 路径） | SetAllowedIPs（ipfilter.go:14，executor.updateListeners） |
| inbound.isDisAllowed（ipfilter.go:46，HTTP accept 路径） | SetDisAllowedIPs（ipfilter.go:18，executor.updateListeners） |
| inbound.skipAuth（auth.go:37，HTTP accept 路径） | SetSkipAuthPrefixes（auth.go:13，executor.updateListeners） |
| listener/auth.authStore.Authenticator（已接受 HTTP 连接） | SetAuthenticator（auth.go:16，executor.updateUsers） |

同一新增 generic 用例在未修改的 229fade 生产源码临时导出上执行 race，复现前三项；旧停止未清理导致第一轮就因 TCP 仍接受而终止，不能据此宣称旧第二轮 authenticator race 已独立复现。当前第四项来自快速重启与已接受连接，源码读写缺少同步；未在本分支修复。

没有关闭 race、忽略其退出码、改 fixture 的认证语义或修改模块缓存来掩盖。当前只证明 P1 监听清理与 P2 受控日志退出功能修复、定向日志并发检查通过，**不能认定完整并发安全已通过**。这项依赖层整改应由父任务/内核线协调；本 PR 仍仅供复核，不自动合并。

## 最新产物摘要

| 产物 | SHA-256 |
|---|---|
| libmihomo.so（包内） | `e4548cdef6f470311abf9fc8f60d0e361522ea22d7e2c22b172534aaa3f43284` |
| libentry.so（包内） | `72846b45abc1c910d65453fd030f2ab31167e740cf4cbd9de913217a57bf3cfe` |
| libc++_shared.so（包内） | `965803c3fe53e02452e4c0479ad13c88f166c04207d27e3c531161a7c75a6c17` |
| 未签名 HAP | `b0b50c90eb2336d4633b74641b9e7ebb8b2942c6531d4ebce3f4e0701c6e025e` |
| libmihomo.so（去符号前） | `ed91d45bd70cebd43c63135f061f2417d98e1d667ee89c9233654f89c5f90dfe` |

真机 generic/Controller、完整转发、后台恢复及系统网络切换仍未执行。stop 不卸载 Go runtime，保留进程级日志 relay；关闭的是每条日志流的订阅/relay/reader，不是永久关闭共享 log observable，以免破坏重启。
