# 2026-10-12 运行时取消恢复修复与自动检查

独审拒绝 Draft #12 旧 head `eaadbaa8adffb6d1c4a39e88fcfa4e527ba22daf`：改名使仍真实失败的恢复测试退出 Quick/Full 的 `scripts/test-*.cjs` 自动门槛。该旧方案撤回，不能合入。独立 #4 `c1db85075992a6df0b00cd57c928e879bd6bfe50` 的旧探活在取消/当前 Ability 销毁后仍提交 Connected，并启动后台服务及订阅，这是运行缺陷而非单纯检查入口问题。

本次只拆出 #9 `1b23e76297d51212b250da85b7375dd7fdab1c1b` 中独立 ArkTS 恢复保护：`recoveryAttempt`、过期结果/回调拒绝、`cancelRecovery()`，有效 start 和显式 stop 使旧恢复失效。`AppRuntime.cancelRestore()` 同步调用取消接口；现有 Ability Context 所有权判断保持。没有复制 `CoreApi.bindContext`，没有改 Controller/Go/NAPI/安全配置或依赖，没有合入 #9 的任何 Go 重载实现。

恢复测试已恢复原 `test-runtime-recovery-integration.cjs` 名称，全部原断言保留，补充旧探活不得启动订阅调度的断言；新增 `test-vpn-recovery.cjs` 自动覆盖 start/cancel、新意图覆盖、Disconnected stop、显式取消与正常恢复。Quick/Full 的 glob 自动执行两项真实恢复测试，不跳过失败或动态检测能力。

该 Draft 继续基于 #4，只有独立复核通过后才能按依赖合流；#4 与 #9 当前均保持未合入。构建、mock 与 Controller 可达仍不证明系统 TUN 健康或真机恢复。
