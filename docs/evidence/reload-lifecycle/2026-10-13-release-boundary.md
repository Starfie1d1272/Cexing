# 配置重载：产品边界与鸿蒙进程可行性

本次为只读补充判断，基于 PR #9 `1b23e76297d51212b250da85b7375dd7fdab1c1b`、Mihomo v1.19.32 / `88dcbf7f1614a67c3b36b848ee3592dfa92ada36`。没有追加实验、修改代码或依赖。此前 host 复现和客户端精确 SHA 见 [客户端生命周期调研](2026-10-13-client-reload-lifecycle.md)。本报告不把单项重载缺口提升成冻结整个项目的前置条件。

## 产品结论

**最终建议见 [社区与恢复判断](2026-10-13-community-and-recovery.md)：保留热重载并记录已知限制，暂存/禁用仅为可选边界，未采纳、未实现，不冻结整个项目。**

可以继续推进已有初始化、连接、流量观察、订阅下载、离线配置管理及现有热加载。当前不宜宣称“活跃流量下无损且并发安全的配置热加载”，也不宜将“点击断开→立即重连”包装成经过证明的替代方案。

近期不改内核时，**运行期订阅更新仅写入待用配置、保持当前运行配置不变**，是可以采用的功能边界。更新下载成功不等于已应用，也不等于候选配置通过核心完整校验。“下次启动”必须区分新 Ability 会话和真正的新核心进程；前者未证明清空旧任务，后者隔离旧运行态。若近期没有验证完整停启，最保守的应用边界是已确认旧核心进程退出后再启动，而不是为整个应用新增“必须先实现另一个 child-process 架构”的条件。

关闭热加载只减少已知触发路径，不让所有配置竞争自动消失：首次 generic listener 发布、同进程快速重启、候选完整解析、独立 mode/log-level 修改仍各有边界。它们应该分别记录、分别验收，不合并成一句“所有功能不可发布”。上述产品边界尚未在代码中实现。

## 一个按钮与 Connected 状态为什么仍能竞争

现有 runLock 和 C++ worker 保护外部配置调用的串行性，但 forwarding reader 不经过这两者。用户只触发一次配置应用，Go 内部已接受的连接、在途 DNS、拨号 goroutine 就能与它并发。其他页面的按钮不需要同时点击。

- 写者：[reloadPlatformConfig](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/core/controller_security.go#L256) 先 preparePlatformConfig→ParseRawConfig，再 ApplyConfig。
- 读者：[HTTP accept 后独立 HandleConn](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/listener/http/server.go#L127) 与 [代理 Direct.DialContext](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/adapter/outbound/direct.go#L26) 不获取 wrapper runLock。
- [ApplyConfig 的 OnSuspend](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/hub/executor/executor.go#L83) 已经存在；[OnSuspend](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/tunnel/tunnel.go#L135) 只改状态，不等待旧 reader 全部退出。Connected 是宿主就绪状态，不是 Go 内核无活跃请求的证明。

因此禁用 Connecting 期间 reload 对启动秩序有帮助，但**Connected 后允许 reload 并不能消除本组竞争**。已有实验即在初始化与监听完成后启动流量、执行单一串行 PUT 循环；没有并发配置写者，更没有模拟双页面双按钮。

## 证据到底证明了什么

此前 Linux/Go race 实验：40 次真实鉴权 PUT 返回 204，同时得到 130 次成功回环代理响应；检测到 resolver/hosts/trie/IPv6 与前缀相关竞争，写栈确实通过 PUT handler，读栈含真实 Direct.DialContext。另有显式 LookupIP/LookupIPv6 reader 帮助稳定捕获解析边界，不能把所有报告都说成真实公网请求捕获。前缀的部分报告来自首次 generic listener 启动，不全由 PUT 产生。

已证明：这些访问未建立必需的同步关系，writer/reader 在产品可达路径上并存；对 candidate 做完整 ParseRawConfig 即便最后不 Apply，也会经 temporaryUpdateGeneral 临时改 live 状态。它不是纯“两个外层方法同时调用”的问题。

未证明：真机必然崩溃、日常发生率、稳定可见 DNS 答案错误、所有用户的断流、凭据泄露、永久卡死、OHOS 栈实际公网双栈转发错误。实验日志包含 IPv6 loopback backend 不存在、解析版本不匹配的连接失败，但该实验主动翻转 IPv6，不能将这些失败全部归因于 race。race 检测本身以测试失败退出，不等于应用发生用户崩溃。仍可能有混合代际、短暂失败等用户影响，这是基于源码的风险推断，不能写成已观察事实。

## 是否所有代理都这样

这是核查的 Mihomo 实现中普通全局变量发布、读侧绕过同步与解析副作用共同造成的问题，**不是代理协议必然具有的通病**。任意代理在共享可变运行态时都可能犯同类错误，但不应据此推断所有内核或所有版本存在同一问题。

| 客户端与固定源码 | 实际规避情况 |
|---|---|
| Verge Rev `3693efcf6c516275e86f212a6a8ff944a5134bb9` | 普通切换优先 [reload_or_restart](https://github.com/clash-verge-rev/clash-verge-rev/blob/3693efcf6c516275e86f212a6a8ff944a5134bb9/src-tauri/src/core/manager/config.rs#L443)，即 PUT /configs；显式 sidecar restart 才 kill 并确认退出。不能拿桌面宿主隔离证明普通 reload 安全 |
| FlClash `4b59eca853778d4e7be3de26589252889c899bc5`；fork `8597778c7df410ebe88c57e59eaab32d203156df` | [applyConfig](https://github.com/chen08209/FlClash/blob/4b59eca853778d4e7be3de26589252889c899bc5/core/common.go#L397) 仍调用 hub.ApplyConfig，本组 fork globals 未修；桌面显式 restart 确认进程退出，Android stop/start 仍是 shared-library 业务生命周期 |
| CMFA `3cc102aab3f251ef460a3b6e2835b6c1eb581e73` | Android :background 隔离 UI；[Load](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/3cc102aab3f251ef460a3b6e2835b6c1eb581e73/core/src/main/golang/native/config/load.go#L63) 仍同进程 Apply，且实际子模块与本 PR 为同一 Mihomo tag |
| sing-box `e4b7e692f4545890bfc9d43960328e1449fa803b` | [实例关闭再重建](https://github.com/SagerNet/sing-box/blob/e4b7e692f4545890bfc9d43960328e1449fa803b/daemon/started_service.go#L250)、DNS/router 按实例归属，避免采用上述 Mihomo globals；本次未证明整个 sing-box 无 race，也不是当前 wrapper 可直接复制的修复 |

真正进程重建会断开旧 TCP/UDP 会话；恢复节点选择、fake-IP/cache 只恢复逻辑状态。没有发现这些客户端把旧 socket 迁移给新内核。

## 暂存订阅能采用，但必须覆盖所有写入口

当前 [ProfileStore.updateFromOrigin](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/ets/lib/ProfileStore.ets#L470) 仅下载、内容清洗、字符串级检查、写文件和 metadata，没有调用 Go Parse。**只保留这部分，不调用 reload，就不直接改本组 Go globals。** 这为“下载继续，应用延后”提供了已有实现基础；字符串检查不是完整 YAML/核心有效性验证。当前覆盖文件原路径也不能自动提供 last-good 回退保障，不能宣称已经实现完善的 pending 事务。

需要明确区分的路径：

| 当前入口 | 即使禁止自动订阅热加载，仍会发生什么 |
|---|---|
| [AutoUpdater:89](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/ets/lib/AutoUpdater.ets#L89) | 当前下载后会主动 reload；这是暂存边界要取消的运行期应用动作 |
| [ProfilePage:103/171/359](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/ets/pages/ProfilePage.ets#L103)、[ProfileEditPage:60](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/ets/pages/ProfileEditPage.ets#L60) | 激活、手动更新、编辑等仍可应用，不能只处理后台定时器 |
| REST PUT /configs 与 /configs/ | 直接调用者仍可绕过页面约束；处理必须在候选完整解析之前才真正避开此写路径 |
| [preparePlatformConfig:201](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/core/controller_security.go#L201) | 即便“只校验候选而不提交”，ParseRawConfig 仍经 [temporaryUpdateGeneral](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/config/config.go#L638) 改 live IPv6/mode 等再回滚；当前并没有独立 Go 验证 API，不能为了暂存新添该旁路 |
| [coreStartTun:217/225](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/core/engine.go#L217) | 启动仍 Parse/Apply；同进程快速重启的旧请求会跨进这一轮；fresh process 也仍有 generic listener 先起后写前缀的首次窗口 |
| [PATCH configs:325](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/core/controller_security.go#L325) | wrapper 仅允许 mode/log-level，不开放 IPv6；但 [SetMode](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/tunnel/tunnel.go#L255)、[SetLevel](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/log/log.go#L78) 仍写普通 globals，有独立并发边界；日志订阅资源修复不等于 log level 已 atomic |
| coreInit | [设置 log level 和全局 home](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/core/engine.go#L106)；不能一边旧业务还读，一边把 init 当彻底清零 |

以上是需要产品边界覆盖的调用清单，不要求把其他功能统一暂停。providers、组选择等其他运行态操作不自动落入此次 DNS/hosts 重载结论，本报告也没有完成它们的全量并发审计。

## “断开、等旧任务、重连”：缺的具体对象

当前 [coreStop](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/core/engine.go#L304) 关闭 TUN、generic listeners、静态 tunnels/TUIC、固定监听端口、DNS server 和 Controller。关闭端口、拒绝新 TCP 已有独立证据，但没有全内核 drain/join 契约。

- **已接受 HTTP/SOCKS/mixed handler 和由它们启动的代理任务**：[HTTP Close](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/listener/http/server.go#L37) 仅标记并 close listener；其 [独立 HandleConn goroutine](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/listener/http/server.go#L147) 没有统一取消/等待。wrapper Stop 没有遍历关闭所有 statistic tracker；即使添加遍历，也不是所有 handler 的退出证明。
- **尚未建好连接的拨号与 resolver 查询**：[tunnel.handleTCPConn](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/tunnel/tunnel.go#L573) 用 context.Background 的超时 context，不是由 coreStop 取消的会话 context；尚未完成 Dial 的对象不一定已进入统计 tracker。因此“connections 面板为空”不是 drain 完成证据。
- **TUN 分流出的 DNS 查询及 resolver 后台重置**：[TUN DNS](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/listener/sing_tun/dns.go) 存在独立查询处理；[TUN Close](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/listener/sing_tun/server.go#L670) 关闭 stack/interface 等，但 wrapper 未取得跨 resolver 所有任务完成的等待句柄。[ResetConnection](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/component/resolver/resolver.go#L240) 还会启动 goroutine，函数返回不是重置完成。
- **外部 DNS 服务关闭不等于所有解析关闭**：[ReCreateServer](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/dns/server.go#L64) 的 tcp/udp Shutdown 是具体 DNS server 的关闭；不等待从 outbound、TUN 等其他入口启动的全部 resolver reader。
- **Controller 的已有等待是局部保证**：[stopControllerLocked](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/core/controller_listener.go#L94) 等 Serve 退出、取消/等待 logs；明确不等待全部 queued API write。runLock/epoch 解决部分旧写事务，不能替代 proxy/DNS reader drain。
- **ArkTS stop 状态不是进程退出确认**：[VpnController.stop](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/ets/lib/VpnController.ets#L309) 调 stopVpnExtensionAbility 后立即置 Disconnected，没有 await 其 Promise。扩展 [onDestroy/cleanup](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/ets/vpnability/ClashVpnAbility.ets#L224) 会 await starting/stopCore，但 onDestroy 返回 void、异步 cleanup 被启动后没有对主进程暴露完成信号。

所以最小可采用的边界是：运行期仅暂存；明确应用可以接受断连接，但重新启动必须以可证实的旧读者退出或旧进程退出为前提。当前没有前一种整体等待接口，也未验证后一种退出确认。无需默认另造独立内核 child process；先核对现有 VpnExtensionAbility 专用进程是否能提供完整重建，是较小且相关的验证方向。本报告不编写取消/等待实现、不新增测试。

## 鸿蒙官方边界：已有专用扩展进程，完整重建待验证

官方文档固定在 OpenHarmony/docs `f41b9345badd47c7ab0c263344cd7f4b5a549afb`，不是以桌面或 Android 经验代替。商业 HarmonyOS 对应系统行为仍需目标设备验证。

1. [Stage process-model](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/en/application-dev/application-models/process-model-stage.md#basic-process-types) 规定同应用同类型 ExtensionAbility 默认位于自己的专用进程（Service/DataShare 等另有规则），并说明进程内全部 Ability 退出是销毁进程的必要条件，进程名称没有固定规则。
2. 当前 [module.json5](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/module.json5) 已声明 type:vpn，扩展是唯一导入 libentry.so 的 ArkTS 文件；[bridge.cpp](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/cpp/bridge.cpp#L90) 在该进程 dlopen libmihomo.so。这已符合“在 VPN 扩展进程内托管库”的架构，并非必须先拆另一 HAP 或 child process 才有进程隔离。文件注释中的 :vpn 不是实际 PID/进程名证据。
3. [VpnExtensionAbility onDestroy](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/en/application-dev/reference/apis-network-kit/js-apis-VpnExtensionAbility.md#vpnextensionabilityondestroy) 是释放业务资源的回调；[stopVpnExtensionAbility](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/en/application-dev/reference/apis-network-kit/js-apis-net-vpnExtension.md#vpnextensionstopvpnextensionability) 说明停止能力并返回 Promise<void>，没有承诺返回时所有 native goroutine 已 join、Go 库卸载，或旧 PID 已退出且下一 start 必定使用新 PID。
4. [VPN 开发指南生命周期](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/en/application-dev/network/net-vpnExtension.md#service-lifecycle-management) 说明调用 start 的应用进程退出或 VPN 服务进程销毁会自动停止 VPN。因此不能用杀主进程来维持“VPN 连着无损更换内核”，也不能假设销毁扩展进程仍保留原 VPN/TUN。
5. 原生子进程是另一选项，而不是默认前置：[childProcessManager](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/en/application-dev/reference/apis-ability-kit/js-apis-app-ability-childProcessManager.md#childprocessmanagerstartnativechildprocess13) 和 [native_child_process.h](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/en/application-dev/reference/apis-ability-kit/capi-native-child-process-h.md#oh_ability_startnativechildprocess) 对 PC/2-in-1/tablet 有支持，phone 不在上述文档支持范围；API 22 的 KillChildProcess 高于本项目 compatible API 21，API 20 exit callback 明确主要用于异常退出，不能单凭名称当普通退出 wait/join。

当前若使用原生 child API还缺：对应入口/IPC 实现、fd 跨进程所有权、child 网络保护、失败清理与退出确认；已有 C ABI 及 pthread worker 可继续是 child 内部约束，不能当这些缺口已完成。当前应用中 protectProcessNet 在 VPN 扩展内调用，其保护是否覆盖另起子进程未验证。无需声称新增系统权限就一定解决设备能力限制。

## 可行性与短期发布分类

| 分类 | 判断 | 当前条件/发布含义 |
|---|---|---|
| 可行 | 继续做订阅下载与离线文件维护，不触发核心解析/Apply | 已有 ProfileStore 文件路径；暂存与已应用必须区分。需要覆盖全部调用入口，当前代码仍会 reload，不能说已实现 |
| 可行 | 将无损热重载从近期承诺中移出，按 feature 单独验收 | 不影响无关工作继续推进；已有运行功能仍各按原验收，不把此 race 推成必然崩溃 |
| 可行（文档层） | VPN 扩展托管 Go 库的专用进程边界 | Stage 官方模型与当前打包吻合；实际设备进程映射尚未记录 |
| 待验证 | 正常 stop 扩展→确认旧 PID 完整退出→重启扩展 | 比另建 child 架构更贴近现有实现；当前没等 stop Promise/cleanup/PID 消亡，官方 Promise 不提供完整 drain 保证 |
| 待验证 | 现有库内 stop 加足取消和等待后再 Apply | 可以作为后续限定改进方向，但当前缺具体 reader 生命周期/等待句柄；没有证明只加一次 CloseAllConnections 就足够 |
| 待验证（受设备限制） | tablet/2-in-1 使用官方 native child 托管 core | 文档允许，但需要 IPC/fd/network/lifecycle 集成；不是当前实现，不是近期发布前置 |
| 不可按当前证据采用 | phone 直接使用上述官方 native child API | 文档不支持该设备范围；商业平台若另有能力需新证据，而不是猜权限 |
| 不可作为修复依据 | Connected 才 Apply、sleep 后重连、仅 await coreStop、dlclose Go runtime、exec 型 /restart | 前三者未建立读者完成关系；后两者违反当前运行边界或宿主模型 |
| 不可宣称 | 保留原 TCP/UDP 会话的进程重建 | 重建进程会断开原连接；没有会话迁移实现 |

具体发布口径可以是“配置更新可下载保存；运行会话保持原配置；新配置在符合停启边界后应用”，而不是“整个项目等待并发热重载修好”。第一次启动的 generic 前缀窗口、mode/log-level 等旁路须独立标记，不能用关闭 PUT 的结果一并报绿。没有选择最终产品策略或改变任何用户行为。

## 文档证据身份

| 官方文件（均在上述 docs commit） | Git blob SHA |
|---|---|
| process-model-stage.md | `46994b393e9570072cc34be231b79135684f5f50` |
| net-vpnExtension.md | `3de1674434a5c687a426a0bd13bbc3f778271b67` |
| js-apis-VpnExtensionAbility.md | `3a66f5995c3c7ff5ed6260270150271b73eec540` |
| js-apis-net-vpnExtension.md | `a1558dcc21a70ba7fd1550bb6d484a3ffec6e893` |
| capi-nativechildprocess-development-guideline.md | `3112a60bf65efe3b7a426268d3bc2651283aff0d` |
| capi-nativechildprocess-exit-info.md | `cfe72ba5d451aa2cda5b6f917c5461c36fc45f6f` |
| capi-native-child-process-h.md | `f2403d31af37a275d62c5cbb7c3b4e2f8b8e6994` |

此次仅源码/文档核对，不新增实验。此前实验结论及许可证边界留在主调研报告，不宣称真机或稳定发行已验证。
