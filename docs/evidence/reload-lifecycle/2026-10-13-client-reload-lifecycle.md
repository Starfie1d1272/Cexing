# PR #9 配置重载生命周期专项调研

日期：2026-10-13（用户时区）；源码读取与 host 实验日志为 2026-10-12 UTC。范围仅限配置切换、内核生命周期与活跃连接，不涉及 UI 或网络安全功能设计。本次交付为可复核研究文档，没有修改生产源码、依赖、模块缓存，没有合并或发布。

## 结论

最终产品建议见 [社区与恢复判断](2026-10-13-community-and-recovery.md)；本页是源码与实验事实，不是禁用热重载、阻塞发布或实施进程隔离的决定。

1. **未找到能从这些客户端直接移植到当前鸿蒙进程内 Mihomo 动态库、且已证明解决这组 race 的现成重载实现。** Clash Verge Rev 常规切换使用 PUT /configs；FlClash 与 CMFA 常规切换使用进程内 hub.ApplyConfig。外层串行任务、写侧锁、独立 UI/服务进程，都不等于保护内核的并发读者。
2. **真正重建内核进程能够隔离旧 Go 全局变量和 goroutine。** Verge 的显式 sidecar 重启、FlClash 桌面 restart 属于这一类；普通配置切换不属于。旧连接会断开，保存选中节点或 fake-IP 映射也不是迁移 TCP/UDP 会话。
3. **sing-box 的实例生命周期值得参考，但不是 Mihomo 的即插即用修复。** 核查版本把 DNS/router/连接管理器放进 Box/context；重载关闭旧实例，再构造新实例，连接管理器参与清理。它避免采用 Mihomo 这组进程级全局变量的架构；本次未运行 sing-box race 全套，不能据此宣布整个项目无竞争。
4. **当前 coreStop 后再 coreStartTun 仍不能视为进程重建。** Go 动态库、全局变量和旧 handler 仍可能存活；C++ 单 worker 只串行外部调用，不串行 Go goroutine。dlclose 和上游进程 exec 型 /restart 都不适用于当前宿主。
5. **最小证据已复现。** 指定 PR head 的真实鉴权 PUT 与回环代理请求并发，40 次 PUT 均返回 204，成功代理响应 130 次，Go race 检查失败。报告涉及前缀、解析阶段 IPv6、hosts/trie 发布、resolver 指针，以及真实 Direct.DialContext 读路径。61 条 race 报告是重复事件数量，不是 61 个独立漏洞或字段。

## 源码身份与锁定依赖

先读取了指定 head 的 [race-boundary](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/docs/evidence/controller-security/2026-10-12-race-boundary.md) 和 [upstream-reload-review](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/docs/evidence/controller-security/2026-10-12-upstream-reload-review.md)，并读取 AGENTS、文档索引、架构、平台与构建指南。该 head 没有 .agents/skills；另已读取相关比较仓库的 AGENTS 和 FlClash core-platform skill。其他仓库仅做只读比较。

| 仓库 | 本次固定 SHA | 内核来源核对 |
|---|---|---|
| [clash-OpenHarmony PR #9](https://github.com/Starfie1d1272/clash-OpenHarmony/tree/1b23e76297d51212b250da85b7375dd7fdab1c1b) | `1b23e76297d51212b250da85b7375dd7fdab1c1b` | core/go.mod 为 Mihomo v1.19.32；无 replace；官方 tag `88dcbf7f1614a67c3b36b848ee3592dfa92ada36` |
| [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/tree/3693efcf6c516275e86f212a6a8ff944a5134bb9) | `3693efcf6c516275e86f212a6a8ff944a5134bb9` | dev 快照；Cargo.lock 将 tauri-plugin-mihomo 锁到 `7a03d16f4d39b1bb885b7babe66b9e153e34b615`；prebuild 使用可变 release/version.txt，不能仅凭客户端 SHA 确认发行二进制的内核 SHA |
| [FlClash](https://github.com/chen08209/FlClash/tree/4b59eca853778d4e7be3de26589252889c899bc5) | `4b59eca853778d4e7be3de26589252889c899bc5` | main 快照；go.mod replace 到子模块；[chen08209/Clash.Meta](https://github.com/chen08209/Clash.Meta/tree/8597778c7df410ebe88c57e59eaab32d203156df) gitlink `8597778c7df410ebe88c57e59eaab32d203156df` |
| [Clash Meta for Android](https://github.com/MetaCubeX/ClashMetaForAndroid/tree/3cc102aab3f251ef460a3b6e2835b6c1eb581e73) | `3cc102aab3f251ef460a3b6e2835b6c1eb581e73` | main 快照；go.mod 虽写 v1.7.0，实际 replace 到子模块 Mihomo `88dcbf7f1614a67c3b36b848ee3592dfa92ada36`，与本 PR 锁定 tag 一致 |
| [SFA](https://github.com/SagerNet/sing-box-for-android/tree/bc73504fcb858400a939140ad785ed92f4c9f429) | `bc73504fcb858400a939140ad785ed92f4c9f429` | dev 快照；Gradle 引用本地 libbox.aar/libbox-legacy.aar，仓库未提供足以确定该 AAR 核心 SHA 的锁；本次不声称与下面核心构成已验证发行配对 |
| [sing-box](https://github.com/SagerNet/sing-box/tree/e4b7e692f4545890bfc9d43960328e1449fa803b) | `e4b7e692f4545890bfc9d43960328e1449fa803b` | testing 快照；独立核查实例生命周期，不当作稳定发行承诺 |

上述仓库身份通过 GitHub repo/ref API 与本地 Git checkout 验证。默认分支快照不等于稳定 release，也不以流行程度证明正确性。PR 依赖校验条目为 `v1.19.32 h1:uD7ZC3P77isWD554NNvtee65L+99+/C5hyc+Lk8rVEk=`。已有上游后续提交的结论沿用指定证据，本次没有将 Alpha 当作修复。

## 客户端实际重载路径

### Clash Verge Rev：常规热加载与进程重启是两条路径

[manager/config.rs](https://github.com/clash-verge-rev/clash-verge-rev/blob/3693efcf6c516275e86f212a6a8ff944a5134bb9/src-tauri/src/core/manager/config.rs#L387) 的 apply_config 在 sidecar 模式调用 reload_or_restart；首先 reload_config，成功即返回，失败才 restart_core_during_config_update。service 模式也优先重载已 stage 的配置，失败或 staging 能力不足才替换 core。这里的 stage 是配置文件/资源代际，不代表内核请求使用不可变 DNS 代际。

锁定插件的 [mihomo.rs:1037](https://github.com/clash-verge-rev/tauri-plugin-mihomo/blob/7a03d16f4d39b1bb885b7babe66b9e153e34b615/src/mihomo.rs#L1037) 发送 `PUT /configs?force=true`、body 为 path，并使用 60 秒超时。客户端生命周期锁防止宿主操作交错，但不能为内核 resolver reader 建立读写同步。

显式 restart 则经过 [lifecycle.rs:785](https://github.com/clash-verge-rev/clash-verge-rev/blob/3693efcf6c516275e86f212a6a8ff944a5134bb9/src-tauri/src/core/manager/lifecycle.rs#L785) 的 stop→start；sidecar 的 [state.rs:316](https://github.com/clash-verge-rev/clash-verge-rev/blob/3693efcf6c516275e86f212a6a8ff944a5134bb9/src-tauri/src/core/manager/state.rs#L316) kill 该 child 后等待退出事件，最长 5 秒；退出未确认返回错误，交接被阻断。**此 sidecar 路径确实隔离旧进程。** service 路径委托外部 service IPC，本次没有审查服务端二进制实现，不把其返回值等同于已证明 OS 进程退出。

配置路径包含恢复已选节点；没有看到活跃 TCP/UDP socket 转移到新进程的代码。正常热加载可能保留旧连接，进程重启一定打断该进程连接。API 超时或失败回退可能造成额外重连，不提供无损保证。

### FlClash：桌面重启有退出确认，Android 重启仍是库内业务生命周期

[setup.dart:550](https://github.com/chen08209/FlClash/blob/4b59eca853778d4e7be3de26589252889c899bc5/lib/providers/actions/setup.dart#L550) 的配置任务写文件后 `_core.setupConfig`；[core/common.go:397](https://github.com/chen08209/FlClash/blob/4b59eca853778d4e7be3de26589252889c899bc5/core/common.go#L397) 加 configMu、解析、hub.ApplyConfig、恢复 SelectedMap、更新 listeners。解析失败会应用 built-in 默认配置并返回原错误，**不是“失败时完全保留旧配置”**。

必须核对其 fork：与官方锁定 tag 比较，fork 的 executor.ApplyConfig 取消自动 updateListeners/updateTun，由宿主调用；但 [resolver.go](https://github.com/chen08209/Clash.Meta/blob/8597778c7df410ebe88c57e59eaab32d203156df/component/resolver/resolver.go)、host.go、inbound/ipfilter.go 与 auth.go 中本组普通全局访问仍在。宿主 updateListeners 仍先 PatchInboundListeners 再写前缀；updateConfig 还直接写 DisableIPv6。fork 在别处有并发快照，不代表这组字段已修复。**本次结论是源码可达和缺同步，不声称在 FlClash 自身运行了 race 复现。**

桌面 [lifecycle.dart](https://github.com/chen08209/FlClash/blob/4b59eca853778d4e7be3de26589252889c899bc5/lib/core/desktop/lifecycle.dart#L579) 持有 CoreProcessLease，旧退出未确认时保留 lease、阻止直接启动另一进程；[launcher.dart:81](https://github.com/chen08209/FlClash/blob/4b59eca853778d4e7be3de26589252889c899bc5/lib/core/desktop/launcher.dart#L81) direct-child 停止使用 kill 并等待 exitCode。这是实际进程边界，与普通 setup 区分。

Android [lib.dart:73](https://github.com/chen08209/FlClash/blob/4b59eca853778d4e7be3de26589252889c899bc5/lib/core/lib.dart#L73) restart 调 stop→start，stop 调服务 shutdown；[core/hub.go:93](https://github.com/chen08209/FlClash/blob/4b59eca853778d4e7be3de26589252889c899bc5/core/hub.go#L93) shutdown 停 listeners/updater、executor.Shutdown、清配置并 GC。service manifest 无专用 android:process，Go c-shared 在应用进程。GC/FreeOSMemory 不重建 Go runtime，不能直接作为当前鸿蒙问题的解决方法。

SelectedMap/route epoch 属于选择状态恢复与路由探测失效；未见将既有网络连接完整移交到新内核的机制。

### CMFA：后台进程隔离了 UI，没有隔离每次配置 reload

[service manifest](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/3cc102aab3f251ef460a3b6e2835b6c1eb581e73/service/src/main/AndroidManifest.xml) 将 ClashService/TunService 等放入 `:background`。但 [ConfigurationModule.kt](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/3cc102aab3f251ef460a3b6e2835b6c1eb581e73/service/src/main/java/com/github/kr328/clash/service/clash/module/ConfigurationModule.kt) 在同一运行服务中消费配置事件并调用 Clash.load；[native/config/load.go:63](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/3cc102aab3f251ef460a3b6e2835b6c1eb581e73/core/src/main/golang/native/config/load.go#L63) 解析后 hub.ApplyConfig。

ClashRuntime 的 globalLock 串行 runtime 启停；退出 finally 执行 reset。reset 的实际顺序是 [native/main.go:38](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/3cc102aab3f251ef460a3b6e2835b6c1eb581e73/core/src/main/golang/native/main.go#L38)：LoadDefault（先 ApplyConfig）→ResetStatistic→CloseAllConnections→GC。先应用再关 tracker，且 [conn.go](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/3cc102aab3f251ef460a3b6e2835b6c1eb581e73/core/src/main/golang/native/tunnel/conn.go) 只遍历统计 tracker 关闭，不等待所有 DNS/HTTP reader。不能认定此 reset 形成读者清空屏障。

同版本 Mihomo 的 ApplyConfig 已有 OnSuspend/OnInnerLoading/OnRunning；OnSuspend 只设置 atomic status。它限制部分新请求处理，**不是等待已有请求全部退出**。这不是其他客户端额外补上的竞争修复。native/tunnel/Suspend 明确忽略屏幕 suspend，与配置同步没有关系。

ConfigurationModule 从 SelectionDao 恢复用户选中节点，常规 load 没有调用 reset 的 CloseAllConnections。后台进程死亡会断连接，但普通 profile reload 没有每次杀进程。

### SFA / sing-box：实例替换，不做活跃会话迁移

SFA 的 [BoxService.kt:215](https://github.com/SagerNet/sing-box-for-android/blob/bc73504fcb858400a939140ad785ed92f4c9f429/app/src/main/java/io/nekohasekai/sfa/bg/BoxService.kt#L215) 在 serviceReload0 调 commandServer.startOrReloadService。单看这个 API 名称仍不能证明安全，需继续读核心。

独立核查的 sing-box [StartedService:250](https://github.com/SagerNet/sing-box/blob/e4b7e692f4545890bfc9d43960328e1449fa803b/daemon/started_service.go#L250) 用 lifecycleAccess 串行重载，撤下 oldInstance，调用 oldInstance.Close，再 newInstance 和 Start；不是更新 Mihomo 式 resolver 全局。新实例失败时进入错误状态，本路径没有自动恢复旧实例。Close 返回的错误被忽略，这一点也不能包装成全局正确性证明。

[daemon/instance.go:85](https://github.com/SagerNet/sing-box/blob/e4b7e692f4545890bfc9d43960328e1449fa803b/daemon/instance.go#L85) 为新实例扩展 context、独立 cancel 并调用 box.New；Close 先 cancel，再关闭实例。[box.go](https://github.com/SagerNet/sing-box/blob/e4b7e692f4545890bfc9d43960328e1449fa803b/box.go#L209) 创建各实例 DNS/router/连接管理器；Scope.Close 反序执行组件 cleanup。[route/conn.go:46](https://github.com/SagerNet/sing-box/blob/e4b7e692f4545890bfc9d43960328e1449fa803b/route/conn.go#L46) 注册连接关闭 cleanup，CloseAll 取出并关闭 tracked connections。

因此旧请求持有旧对象或被取消、连接被关闭；新请求进入新实例。没有证据表明全部 goroutine 都同步 join 完才返回，也没有迁移旧 TCP/UDP socket。可借鉴的是对象归属和关闭契约，不是复制一个 stop 函数到仍使用 Mihomo 全局的 wrapper。

cache-file 中 mode、group selected、fake-IP 数据可按配置持久化；保存这些逻辑状态不会保住已经断开的 SSH、下载连接、QUIC 会话。

## 当前鸿蒙条件下的可采用性与体验影响

| 研究结论 | 当前进程内 Go 库可直接照用吗 | 用户影响 |
|---|---|---|
| 宿主串行配置任务、选中节点保存与恢复 | 可以借鉴，但不解决上游并发读写 | 避免请求互相覆盖，节点选择更稳定；不承诺流量无损 |
| 调同一 ApplyConfig，或外层仅加写锁 | 已是当前基本结构，不能当本组修复 | reload 可能保留连接，但持续存在本次 race |
| stop listeners/TUN、关闭统计连接再 Apply | 公开 API 可调用，但不能证明清空全部旧 reader | 会主动断开连接、增加停顿，同时仍可能 race |
| 确认旧内核进程退出再启动新进程 | 真正隔离，但当前 ABI/宿主未提供此边界 | 所有旧连接断开；客户端需重连；可恢复选择状态，不能无损迁移会话 |
| sing-box 的独立实例归属 | 不能靠 wrapper 一处调用移植到 Mihomo 全局结构 | 关闭旧实例的路线仍会断旧连接；需要较大内核生命周期工作 |

短期结论：**如果不能修改依赖或进程模型，不能宣称当前活跃会话热加载已安全。** 保持运行配置、把修改延后到真正冷启动是保守的产品取舍，但同进程 stop→start 不等于冷启动；本报告不实现这一取舍，也不设计 UI 或控制面策略。

长期结论：能形成清晰边界的两类路线是可确认退出的独立核心进程，或内核内部具有明确对象归属的配置/请求生命周期。前者代价是断连接和平台集成，后者代价是持续维护上游修改；本报告仅比较，不提供实现设计。

平台项单列：当前项目保留四 C ABI、单 pthread worker、不 dlclose。设备为 phone/tablet，target API 26、compatible API 21。不能把桌面 exec/fork 或 Android manifest :background 生搬到鸿蒙。已核对 [OpenHarmony childProcessManager 文档](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/en/application-dev/reference/apis-ability-kit/js-apis-app-ability-childProcessManager.md)：startNativeChildProcess API 13+ 接收动态库入口和 fd；文档标注 PC/2-in-1/tablet 支持，其他设备可能返回 801；SELF_FORK 继承资源且不支持 Binder。这里既有设备能力限制，也有父子进程/IPC/TUN fd 所有权变化，不能宣称 phone 可用或只需要普通 INTERNET 权限。该文档属于 OpenHarmony，商业 HarmonyOS 对应能力与 VPN Extension 场景尚未设备验证；不建议在已运行多线程 Go runtime 内随意 fork。

## 最小复现与证据边界

配套 [host 测试源码](reload_lifecycle_research_test.go.txt) 和 [脱敏关键日志摘录](reload-race.sanitized.log) 可一起复核。测试源码为纯实验文件，放回指定 head 的 core 目录后执行：

```bash
go test -race -run '^TestResearchReloadTraffic$' -count=1 -v
```

实验条件：Linux 6.18.44 x86_64、Go 1.27.2，PR head 和 v1.19.32。使用该环境现成模块缓存，只读使用，没有应用/修改本组上游补丁。构建环境的 gVisor Fstat 平台适配补丁属于已有缓存条件，未以 go mod verify 声称缓存全量原始无修改。

先初始化一次、创建回环 generic HTTP proxy 和 HTTP backend。四个 goroutine 持续通过代理请求 reload.test；另一个 reader 持续调用 LookupIP/LookupIPv6，hosts 命中避免依赖公网 DNS。串行 40 个真实 localhost PUT /configs，每次翻转 DNS enable、IPv6、use-system-hosts 并重新构造 hosts。鉴权只是调用真实入口的前提，不是此次研究功能。DNS nameserver 为回环地址，没有真实订阅/节点。

实际输出：

```text
40 authenticated PUTs; successful real loopback proxy responses: 130
race detected during execution of test
--- FAIL: TestResearchReloadTraffic (1.02s)
FAIL core 1.044s
```

日志中的主要冲突包括：

| reader | writer / 意义 |
|---|---|
| inbound.isAllowed/isDisAllowed/skipAuth | updateListeners setter；首次 generic 启动就存在未建立同步的发布边界，不全是 PUT 触发 |
| LookupIPv6WithResolver | preparePlatformConfig → ParseRawConfig → temporaryUpdateGeneral/updateGeneral 及 rollback；证明“只保护最终 Apply”不足 |
| Hosts.Search → DomainTrie/Node/map lookup | updateHosts 发布及候选解析构建；未同步对象发布会连带暴露 trie 初始化内容 |
| LookupIP 的 DefaultResolver 参数读取 | executor.updateDNS 的接口指针发布 |
| Direct.DialContext（真实代理请求） | updateDNS；不是仅补充 reader 模拟出来的 DNS 路径 |

本次还有 log.SetLevel、模式相关的 race 报告，保留原始完整日志，不把它们扩展成其他功能改造任务。没有出现已修 AuthStore 的原冲突，不据此扩大证明范围。

局限：真实 HTTP 转发为回环 IPv4，另读 IPv6 解析策略；不宣称验证双栈公网转发。61 条报告重复同类访问，未做字段去重计数；一次成功捕获足以否定本路径 race-free，不能估计真机发生率。后续 mixed fixture尝试未完成有效流量复现（一次沙箱 socket 拒绝、一次 IPv6 后端不匹配），不算成功证据。用户收窄为只调研后停止方案实验，**没有拒绝热加载对照成功结果**。未执行 OHOS 真机、HAP 构建或其他客户端运行测试；无运行源码变更，不把 host 结果当设备验证。

## 许可证核对

固定快照的 Verge、FlClash、CMFA、当前项目 LICENSE 为 GPL v3 文本；SFA/sing-box 的声明为 GPL v3-or-later。FlClash fork 源自 Mihomo，需要连同核心及依赖单独保留声明。本次只读比较，没有复制这些客户端代码或新增分发组件，未作完整发行许可证/依赖兼容审计。源码能参考与代码能怎样分发是不同问题，许可证核对未阻止只读研究。
