# 运行时恢复取消接口

本接点从安全线 PR #9 `1b23e76297d51212b250da85b7375dd7fdab1c1b` 拆出独立 ArkTS 恢复保护，与运行时 PR #4 `c1db85075992a6df0b00cd57c928e879bd6bfe50` 结合；修复由 Draft #12 独立审查。它不依赖 #9 的 Go Controller/并发重载实现，也不包含 `CoreApi.bindContext`。原两行待应用补丁已在源码落实并移除，不能重复应用。旧改名方案已撤回，原因及复现见 [修订证据](runtime-ci-entry.md)。

## 契约

`VpnController.cancelRecovery(): void` 同步递增独立 `recoveryAttempt`，在途 recover 探活既不能提交 Connected，也不能回调旧 onDone；它不调用 VPN stop、不改变现有状态、不撤销 startAttempt 或启动 IPC。每次新的断开态 recover 生成新意图；有效 start 和所有显式 stop（包括仍为 Disconnected 的 stop）取消旧恢复。

`AppRuntime.cancelRestore()` 先递增 restoreGeneration，再调用 cancelRecovery，随后清理 restoreTimer。initialize、显式取消、状态变化和当前 Ability 销毁共用该接点；abilityDestroyed 的 Context 判断仍保护新 Ability 的恢复，旧 Ability 的迟到销毁不能撤销新 Context 意图。已连接 Ability 销毁只撤销恢复意图，不停止 VPN/后台服务。

## 自动验证

Quick/Full 保留 `scripts/test-*.cjs` 门槛，自动执行实际 AppRuntime/VpnController 源码的测试：

```bash
node scripts/test-runtime-recovery-integration.cjs
node scripts/test-vpn-recovery.cjs
```

组合测试覆盖 cancelRestore、当前 Ability 销毁、旧 Ability 销毁和新鲜/过期探活：旧 alive=true 不提交状态、不启动后台服务或订阅、不安排恢复；新 Context 的有效探活保留；已连接销毁不停止服务；新鲜 alive=false 只保留一个计时器，旧结果不能取消它。

Controller 测试覆盖 start 后取消、新意图取代、Disconnected stop、显式 cancelRecovery 和有效恢复。可用组合测试第一个参数或 `VPN_CONTROLLER_SOURCE` 指向导出的旧源码作失败复现；标准入口使用当前真实源码，不跳过或动态检测能力。

测试的系统 IO、后台服务及 CoreApi 探活使用 mock/deferred。通过只证明所覆盖的状态和迟到结果保护；Controller 可达不证明系统 TUN 健康，ProfileStore 在途 IO、Go 并发重载和真机恢复仍有独立边界。
