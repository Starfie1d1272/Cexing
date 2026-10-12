# 2026-10-12 CI 与离线面板组合问题

固定 PR #8 `d3255402b756c4d6a2cecf84eeb8c2f306255293` 与 PR #10 `86df6179a7be894a719917f267a20f085c5e915e` 无文本冲突，但 Full 没有准备被忽略的离线 rawfile。干净组合树上资源回归通过，`python3 scripts/zashboard-assets.py verify` 却实际因缺少 `rawfile/zashboard/manifest.json` 失败。Full 最终调用同一前置门禁，因此独立 HAP 证据不能证明这条组合入口通过。

本 Draft 增加提交锁定的 pnpm 11.20.0 工具和一次性源码准备入口，Full 只在存在面板源码声明时调用。实际来源、SHA、原始锁与宿主补丁沿用 #10 门禁，生成的 manifest 与 Pin 必须仍与已审查输入相同。没有修改平台安全、Controller、生产依赖或面板会话，不开放面板入口。

需要独立复核；未经复核不合入此 Draft。真机、认证 REST/WS、取消恢复和并发重载仍不在此检查的证明范围。

本轮实际验证：干净 pinned 源码以 pnpm 11.20.0 构建，46 个文件、5,825,286 字节，版本 `46d47f5edfb3da6c9b2bf7d3f706ae2dad2ff4248248c85381f7eb4c248cb839` 与 #10 已提交清单一致。来源 SHA、冻结锁与宿主补丁门禁均保留。XDG/pnpm 缓存必须在源码目录之外，避免 Tailwind 扫描缓存中的类名改变资源；曾将缓存放在 checkout 内的尝试被身份门禁拒绝，未接受变化后的清单。
