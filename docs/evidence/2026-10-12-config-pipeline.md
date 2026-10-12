# 独立配置流水线验证：2026-10-12

基线 main `7f731d5c9c8d4eba7a1680bcb3981d7877232bcc`，分支 `feat/config-pipeline`。实现范围仅 `core/configpipeline` 及其独立参考/证据文档；未修改生产入口、四个 C ABI、依赖版本、ProfileStore、AutoUpdater、VPN 生命周期或应用身份。工作区及仓库 `.agents/skills` 没有可用文件，工作区 `.agents` 为空；规范/架构/开发顺序/配置/平台/集成/构建文档及 Library 原任务②已读取。

## 实际验证

Linux amd64 云环境，Go 1.27.2、Node 26.11.1、JDK 27、Huawei Command Line Tools 26.0.0.851/API 26。Go 依赖仍为仓库锁定的 Mihomo v1.19.32 与 yaml.v3 v3.0.1；未升级模块图。

- `go test -race ./configpipeline` 与 `go vet ./configpipeline` 通过。测试涵盖无覆写、重复多层命名合并/删除、有序 YAML alias/merge、规则优先级与精确去重、引用缺失/组环、provider-only、原文保留、固定字段差异摘要、订阅更新重应用、生成/保存/激活/提交失败、取消后恢复、回滚失败单独报告、保留上次成功、私有文件权限及陈旧/并发 revision 拒绝。
- 完整解析回调的集成检查在一次性子进程调用锁定 Mihomo `config.Parse`：普通代理与 inline provider-only 通过，无效代理协议与 `smart` 组拒绝。其余单元测试使用固定 mock，不能当作完整内核、平台安全或资源获取验收。
- 四个现有 Node 回归通过：profile-name（11 项）、vpn-startup、app-runtime、background-lifecycle。首次调用未加载仓库 env 导致路径缺失，加载正确环境后四项全部通过；没有修改检查脚本。
- `bash scripts/build-core.sh` 交叉编译通过，沿用仓库已匹配的 gVisor 补丁；`ohpm install`、`hvigorw clean --no-daemon`、未签名 `bash scripts/build-hap.sh` 通过（33 tasks 全部执行）。独立包尚未被生产导入，HAP 构建证明原入口未破坏，不能证明新模块已被应用执行。
- HAP ZIP CRC、必要资源及三个原生库 AArch64 ELF 检查通过。HAP SHA-256：`16417f7d346af6c99db07da64eb2185928a4ce3e6e88f767e102fa9c334c041a`；包内 libmihomo.so：`b021bb60317ba469c29b3bb66505807e1ef0e5ca39826f659cc2d62efe2a8b35`。确认 libentry.so、libc++_shared.so、override.yaml、geodata/geoip.metadb 存在；产物未提交/签名/发布。
- `git diff --check` 通过；新增文档链接检查通过。未操作真实设备、VPN/安全设置，未使用真实订阅或私有凭据，无权限拒绝。

## 并行交接与未覆盖边界

[接入契约](../reference/config-pipeline.md) 给安全线 `Transform(ctx, *yaml.Node)` 和必填完整 Validator、策略线同型可选转换、宿主 Store/Activator/Restore 与 expectedActiveRevision。安全值和强约束只由安全线提供；本包不实现第二套 Controller/TUN 限制。完整校验必须在宿主 worker 串行执行并处理 Mihomo 的临时状态/对象/资源/日志责任。

只读参考兼容线 [PR #2](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/2)，身份 `bda3a0abe8355a34bbb03df8eb252a1404a622ba`，没有基于其未合并分支修改代码。存在需父任务裁定的 Merge 方言差异：本包 `pipeline-merge-v1` 为命名数组按 name 合并、null 删除；其研究提案 `merge-v1` 为所有数组替换、null 保留、removePaths 删除。两者不能互标相同方言，父任务选择最终产品格式后另作显式 adapter/修订与回归。旧 Canonical 的重复规则缺陷没有复刻，规则精确重复只保留第一项。

兼容线的 PlanRequestV1/验证回执/平台-provider-内核能力快照属于宿主协议；本包加入成功版本 revision 拒绝迟到更新，未声称已实现该完整 ArkTS 协议、provider 获取、必要区域策略或全部 20 个目标场景。生产接入还需按固定输入分类、快照、网络身份/内核能力绑定以及策略 ID/版本联调。

文件指针的原子提交和进程内回滚已测；掉电/进程退出期间运行内核与文件不能组成跨进程原子事务。需宿主单写者及启动时从 Current 恢复，回滚失败应阻断进一步激活并显示恢复状态。未验收真实系统会话、启动/REST 重载平台一致性、设备转发或 OHOS 文件系统掉电行为。

共享 README、AGENTS、development 没有编辑。父任务可在文档索引增加独立接入契约链接，并在开发顺序引用最终裁定的 Merge 方言与平台联调门槛。
