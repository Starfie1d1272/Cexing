# 热重载社区案例、失败检测与恢复判断

截至 2026-10-13（用户时区）。本页给出本轮最终产品建议；[生命周期源码核对](2026-10-13-client-reload-lifecycle.md) 与 [鸿蒙平台及停止边界](2026-10-13-release-boundary.md) 提供技术依据。只读调研，无新增实验、生产代码、依赖或产品行为改动。

## 最终建议

**近期保留热重载，明确已知并发限制，将本组 race 记为后续非阻塞调研；不要仅凭检测报告冻结整个项目或默认禁用功能。** 这个判断不撤销技术事实：活跃请求与 reload 的未同步访问已经复现，只是不把它等同于已证实普通用户必然崩溃或全项目发布阻塞。

“热重载失败时受控断开、应用并恢复”是有开源先例的可观察故障恢复方向，**不是本组 race 的自动兜底**。应按故障类型判断：无效配置通常不应断开重试；明确的核心不可用/业务应用失败可以考虑受控停启；HTTP 超时是结果不明，不能假定核心没应用。当前代码没有证明整内核 drain，也未完成 last-good 回退，因此本报告不将自动断开重连推荐为已经可无条件上线的修复。

进程隔离只作为普通 stop 无法可靠收尾后的备选。当前已使用 VPN 扩展专用进程模型，优先核实既有扩展的正常停止/退出语义即可，不必先另造 child 架构。其他功能继续按自身证据推进，当前 research 不代替父任务对 PR #9 的其他验收或合流判断。

## 检索范围与公开证据分级

对 Mihomo、Clash Verge Rev、FlClash、CMFA 的公开 issue/PR，检索了 open 与 closed（不限定单一状态）。关键词包括 reload、重载、data race、race、temporaryUpdateGeneral、DefaultHosts、DisableIPv6、DirectHostResolver、SetAllowedIPs、skipAuthPrefixes、DefaultResolver、hosts、panic。按相关候选读取正文、状态、日期及讨论；单次搜索最多取前 20/30 条，不是全历史穷尽。

CMFA 的 GitHub API 返回 `has_issues:false`、`has_discussions:true`，因此 issue 搜索为空不能解释为没有故障；另阅读公开 Discussions 的切换/崩溃候选。部分 Discussions 页面显示加载错误，检索覆盖有限。

分级含义：A=触及同一机制并有源码/维护者确认；B=真实使用或复现报告，但根因不同或尚未归因；C=普通解析/下载/宿主错误；这些级别不是严重程度，也不代表本次已重新运行他人的复现。

| 来源 / 日期 / 状态 | 报告版本与症状 | 与本次吻合程度、维护者讨论 |
|---|---|---|
| [Mihomo #2837](https://github.com/MetaCubeX/mihomo/issues/2837)，2026-05-27 UTC，open | Android 16、v1.19.25；报告长 ParseRawConfig 的 temporaryUpdateGeneral rollback 把 geoMode 恢复为 false，GEOIP.Match→mmdb.IPInstance 打开缺失 MMDB 并 fatal | A（解析副作用相关），但变量为 geodata，报告另要求解析/Apply 重叠，不是本组 resolver/hosts/IPv6 的普通故障实证。2026-05-29 [协作者 wwqgtxx 评论](https://github.com/MetaCubeX/mihomo/issues/2837#issuecomment-4569554130) 确认 race 存在，同时认为正常流程不应并发 Parse/Apply，并否定简单去掉 rollback 的提案 |
| [Mihomo #3281](https://github.com/MetaCubeX/mihomo/issues/3281)，2026-10-06 UTC，open；[PR #3283](https://github.com/MetaCubeX/mihomo/pull/3283)，2026-10-08 合并 | v1.19.32、alpha-9f053c4；相同文件 reload 后 fake-IP 映射起初保留，但分配 cursor 重置，新域名覆盖旧地址 | B（确定的重载兼容缺陷），不是 globals race；PR 合并 SHA `e4dd968de9e10ecc6770acfafd306edeb578eb52` 保留 offset/cycle，不能作为本组竞争修复；report 的 AdGuard 普通使用关联也明确未闭合因果链 |
| [Mihomo #3255](https://github.com/MetaCubeX/mihomo/issues/3255)，2026-09-27 UTC，open；[PR #3271](https://github.com/MetaCubeX/mihomo/pull/3271)，2026-10-03 UTC，open、未合并 | macOS 26.7、alpha-63bd52e；PUT 后旧 WireGuard device/UDP socket 残留，同 key 的新旧端口让 peer endpoint 抖动；PR 报告本地 hold connection timeout | B（旧资源生命周期），不是 DNS/hosts bool 发布 race。PR head `6b3b99b1d4926f2c0ddaa1570683b8956c1410ea` 采用同代理新实例启用时关闭旧 device，而非全核心停启；旧连接不迁移 |
| [Mihomo #368](https://github.com/MetaCubeX/mihomo/issues/368)，2023-02-04 UTC，closed；[讨论](https://github.com/MetaCubeX/mihomo/issues/368#issuecomment-1420919342) | alpha-cbc217e 与当时稳定 Windows；使用 providers，在 Dashboard reload 后约 30 秒卡顿、约 800MB 增长，多次点击更重 | B（用户重载症状），没有本组栈。2024-10-20 因模板格式关闭，不能当已修复；后续内存增长评论甚至不需要切换 |
| [Mihomo #1250](https://github.com/MetaCubeX/mihomo/issues/1250)，2024-05-08 UTC，open | Windows 21H2、alpha-6d1c62b；Clash Verge 多次切换配置内存增长，提供 heap；另用户报告 CVR 1.7.5 四订阅切换增长 | B（用户资源症状），没有本组 race 栈；评论讨论 HY2/QUIC 连接释放，只能称资源方向线索 |
| [CVR #6028](https://github.com/clash-verge-rev/clash-verge-rev/issues/6028)，2026-01-07 UTC，open；[PR #6384](https://github.com/clash-verge-rev/clash-verge-rev/pull/6384)，2026-02-27 合并 | CVR 2.4.4、Windows 10；切订阅卡顿、需结束 service；日志有远端配置 404、服务 IPC 超时 | C/B（可检测应用/宿主失败）；PR 明确以 API 先试、超时后重启 core 改善外部资源下载导致的切换失败。合并 SHA `25a83388bb6fd0665bda5610731742a8769504e6`；不是对 Go race 做 runtime 检测 |
| [CVR #7267](https://github.com/clash-verge-rev/clash-verge-rev/issues/7267)，2026-06-10 UTC，open | CVR 2.5.0、Mihomo 1.19.25、macOS 14.6；XNU lock_mtx.c kernel panic，用户回忆与特定 profile 切换相关 | B（确有另一崩溃报告），只有 OS 锁栈，用户明确无切换瞬间日志；[讨论](https://github.com/clash-verge-rev/clash-verge-rev/issues/7267#issuecomment-4677107137) 区分 XNU 与 Go；不能把它归为本组 globals 或拿来推断鸿蒙必崩 |
| [CVR #7764](https://github.com/clash-verge-rev/clash-verge-rev/issues/7764)，2026-08-18 UTC，closed | CVR 2.5.2、Mihomo 1.19.29/30、Windows 11；TUN 回灌导致 thread exhaustion，崩溃后反复 reload/replace | B（不同缺陷），有 dialer/forwarder 栈但非 updateDNS/hosts 读写。报告者在[后续讨论](https://github.com/clash-verge-rev/clash-verge-rev/issues/7764#issuecomment-5353194724) 归因误选虚拟网卡及 DoH 自举，且[纠正](https://github.com/clash-verge-rev/clash-verge-rev/issues/7764#issuecomment-5356783612)“proxy-server-nameserver 未生效”的误读；不能仅凭标题说重载并发崩溃 |
| [FlClash #2158](https://github.com/chen08209/FlClash/issues/2158)，2026-06-24 UTC，open | 0.8.93 Windows 11；启动失败后切规则，提示 handleAction(updateConfig) nil pointer，未提供完整日志 | C/B（宿主调用前提错误候选），没有 DNS/hosts/IPv6 栈。核查当前 core 的 currentConfig==nil 防护，但没有证据把该报告归到本组 race |
| [FlClash #1044](https://github.com/chen08209/FlClash/issues/1044)，2025-03-25 UTC，closed/not_planned | 0.8.80 Android；修改代理端口后网络近乎不可用，改回可能恢复 | C/B（端口变更症状），没有重载同步栈或维护者根因，不将其等同于 hosts race |
| [FlClash #2675](https://github.com/chen08209/FlClash/issues/2675)，2026-10-12 UTC，open | 报告者审查 0.8.94，附加规则引用已改名节点，parseRules 返回 proxy not found | C（可返回的解析错误），作者明确未故意在真实环境复现；不是 race，也不能靠停启把无效配置变有效 |
| [CMFA Discussion #797](https://github.com/MetaCubeX/ClashMetaForAndroid/discussions/797)，2026-07-09，无回复 | 2.11.31、Android 16；跨订阅后仍用旧节点，称重启恢复 | B（用户切换效果），无日志/栈，无法归因 globals 或旧连接复用 |
| [CMFA Discussion #389](https://github.com/MetaCubeX/ClashMetaForAndroid/discussions/389)，2024-11-14，closed | 2.11.2；Rule 模式切应用/打开 VPN App 导致 panic: leaking buffer | B（用户崩溃），没有 reload writer/本组 reader 栈；作者后来称域名规则规避，不是维护者确认的本组修复 |
| [CMFA Discussion #275](https://github.com/MetaCubeX/ClashMetaForAndroid/discussions/275)，2024-07-24，closed | 用户希望切节点立即打断旧连接，称需重启才使用新节点；7月31日作者称预览版 PR 已解决，未附明确版本/PR编号 | 活跃连接策略证据，不是配置 globals 竞争；说明“保留旧连接”和“新选择立刻生效”本来是不同产品取舍 |

**本轮没有找到准确覆盖 inbound 三前缀、DefaultHosts/trie、DefaultResolver/DirectHostResolver 和 DisableIPv6 热加载读写的公开普通使用故障案例或完整成熟补丁。** 有解析副作用相关的维护者确认、有其他真实重载故障，但不能合并归因。检索覆盖及 CMFA issue 关闭状态限制了结论，不能写“社区从未出过”或“全社区普遍受影响”。

## 失败自动恢复能检测到什么

PR #9 当前 [CoreApi.request](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/ets/lib/CoreApi.ets#L90) 以 8 秒 connect/read timeout 请求，2xx 返回正文、其他状态/传输异常统一 null；[reloadConfig](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/ets/lib/CoreApi.ets#L206) 只返回 bool。当前把 invalid candidate、会话过期、接口不可达、超时等混成 false，不能按这个 false 无区别自动断开。

| 情形 | 可检测性与恢复判断 |
|---|---|
| 候选语法/类型/规则解析错误，HTTP 400 | 真实错误可返回；应保持现有运行并报告候选无效。相同无效候选断开重试通常仍失败，反而丢掉本来可用连接 |
| 会话冲突/已停止，HTTP 409 | 会话状态可返回，应与当前会话核对；不能让迟到失败再停止新会话 |
| HTTP 超时/连接断开 | 能检测请求未得到结果，但不能断定 Apply 没完成；核心可能稍后完成。仅依据超时直接重试/回滚不能证明一致性 |
| Apply 内部 listeners/provider 初始化失败 | [executor.ApplyConfig](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/hub/executor/executor.go#L83) 返回 void，若干错误只记日志；[PatchInboundListeners](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/listener/listener.go#L627) Listen error 后 continue。PUT 204 不等于数据面全部健康，也不存在统一 apply error 可以直接捕获 |
| 此次 data race | 由开发时 -race 的插桩报告；正常 OHOS c-shared 构建没有“race 出现→reload 返回 false”的事件。此前复现 40 个 PUT 全部 204，说明只在 false 分支恢复不能覆盖这些 race |
| 已观察核心失联或真实请求持续失败 | 可作为普通故障处理线索，但没有唯一归因到 race；重启能改善某些故障，不等于已修竞争 |

下载/通话/SSH 等已有连接在受控停启时会中断。可恢复“VPN 已连接”和节点选择，不能替应用保证下载自动续传或通话不中断。为改善一次不可达而每次自动停启，需要比较确定中断的成本与尚未证实的偶发影响；本轮不自动选用该策略。

## 当前 stop 与最小补齐的边界

[停止核对](2026-10-13-release-boundary.md#断开等旧任务重连缺的具体对象) 已逐项列出缺口：已接受 proxy handler、未注册 tracker 的拨号、TUN 发出的 DNS reader、resolver reset goroutine，以及宿主没有等待 stopVpnExtensionAbility Promise/完整退出。Controller Serve/logs 的局部 join 已存在，不应把这部分说成未实现。

单补齐“等待宿主 stop Promise/cleanup 完成”是明确且范围较小的生命周期改进方向，但它只能证明这些操作完成，不自动 join 全部 Go 数据面任务。只补 CloseAllConnections 也不会涵盖未建好连接的 Dial/Lookup。当前公开 API 没有一个能等待所有上述 reader 完成的屏障；要做完整库内 drain，需要核心配合跟踪/取消对应任务，超出加一次 wrapper 锁或两文件前缀 patch，不能承诺已经能小改报绿。

这不意味着进程隔离必须成为项目前置：普通可检测应用错误可单独处理、其他模块继续推进；若未来选择“先断开再应用”且要证明跨会话无旧 reader，优先验证既有 VPN 专用进程的完整退出；仅在其不可用时再考虑新进程模型。该验证不是本轮已完成的交付。

## “失败保持旧配置”目前能保证到哪里

[reloadPlatformConfig](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/core/controller_security.go#L313) 在 prepare 返回 error 时不调用 Apply，已有最终运行配置原则上继续使用；但 prepare 中的 temporaryUpdateGeneral 曾短暂写 live 状态，因此不能声称失败过程从未影响读者。

一旦 Apply 已开始，它是分步更新且无整体错误返回，不具备“失败自动回滚完整旧内核状态”的承诺。当前 [ProfileStore.updateFromOrigin](https://github.com/Starfie1d1272/clash-OpenHarmony/blob/1b23e76297d51212b250da85b7375dd7fdab1c1b/clash-openharmony/entry/src/main/ets/lib/ProfileStore.ets#L470) 先覆盖保存文件，ProfilePage activate 先改 active 标记；旧运行仍可存在，但旧文件/选择不一定保留。没有 last-good 运行快照、持久候选副本和恢复验证，自动断开后也不保证能重新加载旧配置。FlClash 的解析失败默认配置回退同样不是这一保证。

## 分开记录，分别推进

- **已有 race 证据：成立。** 精确源码和真实 PUT/回环流量已复现；无需双按钮，没有因此改变任何生产行为。
- **本项目普通使用故障证据：尚未建立。** 未做鸿蒙真实订阅/长期转发，不声称用户必崩或所有 reload 都失败。
- **社区影响范围：存在相关解析 race 与多类重载故障，具体本组字段的用户影响范围未知。** 用 issue 数量、普及程度或另一 OS panic 估计严重程度都不充分。
- **后续定位：适合作已知技术债的非阻塞调研。** 保留功能、保留复现和限制；普通失败恢复可成为独立产品可靠性任务，不把 runtime race 检测当作现成触发器，也不将研究文档中的备选措施当作已接受的产品决定。

后续若获得同版本正常构建下的可归因崩溃、持续请求错误或完整停启恢复证据，再据此重新评估优先级。此次未创建新上游 issue、未留言、未改功能。
