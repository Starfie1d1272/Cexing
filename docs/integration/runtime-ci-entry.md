# 2026-10-12 运行时与 CI 检查入口复核

固定 PR #4 `c1db85075992a6df0b00cd57c928e879bd6bfe50` 与 PR #8 `d3255402b756c4d6a2cecf84eeb8c2f306255293`。CI Quick/Full 的 `scripts/test-*.cjs` 会发现恢复组合测试，但该测试明确要求尚未合入的 PR #9 和恢复取消接点。

独立运行 #4 的组合测试实际失败：`explicit: late alive must not commit Connected`，Connected (2) 不等于 Disconnected (0)。这不是 CI 偶发失败，也不证明恢复竞态已修复。四项普通宿主回归与该组合测试属于不同检查目标。

本 Draft 将组合测试改名为 `verify-runtime-recovery-integration.cjs`，保留全部断言和显式执行入口，并同步合流指南。没有跳过或改写断言，没有应用缺少 API 的恢复补丁，没有改变任何生产模块。Quick/Full 继续发现全部普通宿主回归；组合恢复门槛仍按 [指南](runtime-cancel-recovery.md) 在 #4 + #9 + 接点同时存在时强制执行。

本改动需要独立复核后才能纳入 #4。本轮不将 Draft 合入 main，不宣称恢复竞态或真机流程通过。
