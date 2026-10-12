# 独审发现的源码检查与重铺盘修复

2026-10-12，基于面板 PR #10 head `2c0c1ed95c06f65770445a82f5afd59adb43376c` 修复两项已复现缺陷；最终实现身份取本 PR head。未改安全线文件、CoreApi、engine 或 VPN 生命周期，入口仍关闭。

## 暂存源码绕过固定身份检查

旧构建脚本只检查 `git diff`（index 到工作区）。在固定 HEAD 的独立上游 checkout 中，保留未暂存的合法 host.patch，再把 `src/main.ts` 的合成改动暂存：旧脚本允许其进入 pnpm 安装，实际源码已偏离固定 SHA。

`scripts/test-zashboard-source.py` 使用真实 Git checkout、真实暂存操作，以及从 `2c0c1ed` 读取的原脚本复现此路径。pnpm stub 只作为“已进入依赖执行”的哨兵并立即退出，不执行受修改源码的构建，也不改现有资源。随后运行修复脚本，同一 checkout 在任何 pnpm 调用前拒绝，并断言 index/工作区完整差异没有被修改。

修复：拒绝任何 `git diff --cached HEAD` 差异，合法 host.patch 的比较明确使用 `git diff HEAD`，不再以 index 作为源码基准。不会 reset、清理或自动接受用户暂存改动。

## 同一版本损坏后无法重铺盘

旧实现检测到版本目录已存在就校验；校验失败直接退出。即使入包资源完好、用户重复 prepare，也一直返回无可用目录。

`scripts/test-zashboard-assets.cjs` 用真实 SDK transpiler 分别加载 `2c0c1ed` 原资源模块与本次修复模块，crypto/rawfile 使用合成 mock，文件操作使用真实临时文件系统。先通过旧模块安装，再损坏唯一版本文件：旧模块两次重试均失败；修复模块从同一入包版本恢复原始字节，并通过完整校验。

修复：在服务根以外重新 staging 并完整校验；然后把损坏目录 rename 到私有 quarantine，发布新副本。发布 rename 失败时恢复原目录；坏入包资源不会提前移动旧目录，仍返回可用旧版本或明确错误。损坏副本只隔离，不自动删除。该逻辑也处理缺失文件、损坏 manifest、多余文件及版本路径中的 dangling symlink。

关键故障验证已通过：

- 同一版本损坏且无 previous：坏入包副本仍失败，恢复入包副本后成功修复。
- 当前版本损坏且有 previous：坏入包副本回退；新副本发布失败恢复原坏目录，选择入口字节保持不变；取消注入故障后成功重铺盘。
- missing asset、损坏 manifest、多余文件、dangling symlink 的重新准备成功；原有穿越/导航策略、串行、锁竞争、原子选择失败与回退回归保留。

平台没有在本线使用非空目录交换 API。修复同一目录时，隔离旧目录与发布新目录的两次 rename 之间可能短暂 404；不会暴露半成品。正常版本切换的 ui/index.html 仍原子替换。进程终止/断电、真实文件锁与真机 WebView 未测。

## 构建与身份

锁定 Zashboard SHA、pnpm lock、host.patch、资源字节及资源版本均未变化。真实 `--offline` 构建通过，资源清单 SHA-256 仍为 `c331e981f5f8219dcbff106c1d9e2ca97aa0ce2848e08161a827d9347430b251`。

四个既有项目回归全部通过。执行 hvigor clean 后进行了真实 SDK 构建；修正 ArkTS 不允许直接 throw 未定类型 catch 值的问题，最终 HAP 构建成功（33 tasks，18 executed、15 up-to-date）。包内全部 46 项资源的全集、SHA-256 和 ZIP CRC 验证成功。

本次未签名 HAP SHA-256：`163d76166bfb28065c03ffdc561a51e37e1b9e01e7970e480e72a06a3f3733cb`。HAP 只保留在忽略的构建目录，不提交。安全线的 UI/VPN 降级修正由其拥有者处理；本次不重新实现或声称已经合流验证。内存凭据、secret 持久化适配、WS/CSP 与真机验收继续是未完成接入边界。
