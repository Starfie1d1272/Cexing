# 2026-10-12 CI 与离线面板组合问题

固定 PR #8 `d3255402b756c4d6a2cecf84eeb8c2f306255293` 与 PR #10 `86df6179a7be894a719917f267a20f085c5e915e` 无文本冲突，但 Full 没有准备被忽略的离线 rawfile。干净组合树上资源回归通过，`python3 scripts/zashboard-assets.py verify` 却实际因缺少 `rawfile/zashboard/manifest.json` 失败。Full 最终调用同一前置门禁，因此独立 HAP 证据不能证明这条组合入口通过。

本 Draft 增加提交锁定的 pnpm 11.20.0 工具和一次性源码准备入口，Full 只在存在面板源码声明时调用。实际来源、SHA、原始锁与宿主补丁沿用 #10 门禁，生成的 manifest 与 Pin 必须仍与已审查输入相同。没有修改平台安全、Controller、生产依赖或面板会话，不开放面板入口。

需要独立复核；未经复核不合入此 Draft。真机、认证 REST/WS、取消恢复和并发重载仍不在此检查的证明范围。

本轮实际验证：干净 pinned 源码以 pnpm 11.20.0 构建，46 个文件、5,825,286 字节，版本 `46d47f5edfb3da6c9b2bf7d3f706ae2dad2ff4248248c85381f7eb4c248cb839` 与 #10 已提交清单一致。来源 SHA、冻结锁与宿主补丁门禁均保留。XDG/pnpm 缓存必须在源码目录之外，避免 Tailwind 扫描缓存中的类名改变资源；曾将缓存放在 checkout 内的尝试被身份门禁拒绝，未接受变化后的清单。

官方 SDK Full 在 `df7cd62` 完整通过：clean 未签名 HAP、46 个面板资源全集/摘要、三份 ARM64 库、四 ABI、新内核 strip 身份全部通过。HAP SHA-256 `fe22e7e27011ce8c34494872f9269f89b1848625437c1468ebcd5cffd70b83dc`，产物不提交。

首次托管 Quick run [38303091551](https://github.com/Starfie1d1272/clash-OpenHarmony/actions/runs/38303091551) 复现浅克隆问题：资源回归执行 `git show 2c0c1ed:.../ZashboardAssets.ets` 时失败。该提交只在完整历史中存在；本地完整仓库回归通过不能证明默认 Actions checkout 通过。追加修复让两个工作流 checkout `fetch-depth: 0`，保留旧失败复现及全部当前行为断言，不跳过测试。此后仅工作流/证据变更，不更改已构建的应用、资源或 native 输入。
