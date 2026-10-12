# 运行时与安全线的恢复取消合流

对接来源：[运行时 PR #4](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/4) 的 `f6228e60bbccf4c9c44d142e92c2fe1490bfe3b7` 与[安全 PR #9](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/9) 的 `9ecb964f319edff6fccfd36d78850c6b8e4fa609`。共同基线为 `7f731d5c9c8d4eba7a1680bcb3981d7877232bcc`。双方独占源码没有相互修改；下列补丁由父任务在组合审查/集成分支应用。

## 契约与最小接点

PR #9 的 `VpnController.cancelRecovery(): void` 同步增加独立 recoveryAttempt，使在途 recover 探活既不提交 Connected，也不调用旧 onDone；它不调用 VPN stop、不改变现有状态、不撤销 startAttempt 或启动 IPC。有效 start、显式 stop、更新 recover 在安全线内已使旧探活失效。

[待应用补丁](runtime-cancel-recovery.patch) 仅两处各加一行：

1. `AppRuntime.cancelRestore()` 在递增 restoreGeneration 后调用 `VpnController.cancelRecovery()`，然后照常清理 restoreTimer。
2. `scripts/test-app-runtime.cjs` 的 Controller mock 补上同步 `cancelRecovery`，保持现有独立运行时测试可执行。

不额外修改 EntryAbility：`abilityDestroyed(ctx)` 的当前 Context 判断已确保旧 Ability 的迟到销毁不调用 cancelRestore；当前 Ability 销毁会经上述调用同时失效 runtime timeout 和 Controller 探活。initialize 的已有 cancelRestore 会先撤销旧探活，再发起新 recover；状态变化和显式取消也走同一接点。服务正常连接时，sync 取消恢复只撤销恢复意图，不停止 VPN/后台服务。

PR #4 独立分支的 AppRuntime 仍未调用该方法，基线没有该 API；补丁是未应用的普通文件，不被 ArkTS 编译。没有动态方法检测、类型逃逸、重复实现 Controller 代次或假装在独立基线上已经合流。父任务若只合入其中一个 PR，不应应用本补丁。

## 父任务应用与验证

在同时包含上述两线源码的集成分支执行：

```bash
git apply --check docs/integration/runtime-cancel-recovery.patch
git apply docs/integration/runtime-cancel-recovery.patch
source scripts/env.sh
node scripts/test-runtime-recovery-integration.cjs
node scripts/test-vpn-recovery.cjs
node scripts/test-app-runtime.cjs
node scripts/test-background-lifecycle.cjs
node scripts/test-profile-name.cjs
node scripts/test-vpn-startup.cjs
git diff --check
```

`test-runtime-recovery-integration.cjs` 只在合流后运行，加载实际 AppRuntime 与 VpnController 的 SDK 转译源码，使用同一个 Controller 实例及 deferred CoreApi 探活。它不是产品动态能力判断；独立基线运行会暴露缺少合流接点。可传第一个参数为导出的组合源码根目录，以免修改独立 checkout。

验证覆盖：仅 cancelRestore、当前 Ability 销毁后的旧 alive=true 不提交状态/启动后台/安排 restore；旧 Ability 销毁不失效新 Context 的探活；新鲜 alive=true 仍正常启动服务；已连接的 Ability 销毁不停止 VPN/后台；新鲜 alive=false 仍安排一个恢复计时器，旧 alive=true 不取消它。

## 2026-10-12 实际结果与限制

在临时目录导出 PR #4 `f6228e6`，将基线→PR #9 `9ecb964` 的完整 tracked diff 应用到导出树，`git apply --check` 无冲突。未合并、未改 main 或独立分支运行源码。

- 未应用接点时：组合测试在第一项失败，`explicit: late alive must not commit Connected`，状态为 Connected 而非 Disconnected。这证明安全线内部 start/stop 保护不能替代纯运行时取消接点。
- 应用两行补丁后：组合测试、PR #9 的 test-vpn-recovery、四组既有回归全部通过。
- PR #4 独立源码：四组既有回归再次通过，AppRuntime/EntryAbility/Controller 运行源码与此前已构建提交一致。

环境为 Linux 云端、Node 26.11.1、官方 API26 SDK 转译器，平台 IO/后台服务为 mock。本轮没有组合内核重编译、合流 HAP 构建或真机测试；父任务仍需对最终集成 tree 做 clean 构建及设备验收。此前两条独立 PR 的构建证据不能替代最终合流产物证据。

这将封闭运行时报告的 recover 提交竞态，前提是两线源码与接点全部合入；Controller 探活不证明系统 TUN 健康、ProfileStore 在途写入事务边界和 native loader 的 dlclose 风险均仍独立存在。
