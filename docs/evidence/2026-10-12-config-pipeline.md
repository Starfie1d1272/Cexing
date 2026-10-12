# 独立配置流水线验证：2026-10-12

基线 main `7f731d5c9c8d4eba7a1680bcb3981d7877232bcc`，分支 `feat/config-pipeline`。实现范围仅 `core/configpipeline` 及其独立参考/证据文档；未修改生产入口、四个 C ABI、依赖版本、ProfileStore、AutoUpdater、VPN 生命周期或应用身份。工作区及仓库 `.agents/skills` 没有可用文件，工作区 `.agents` 为空；规范/架构/开发顺序/配置/平台/集成/构建文档及 Library 原任务②已读取。

## 实际验证

Linux amd64 云环境，Go 1.27.2、Node 26.11.1、JDK 27、Huawei Command Line Tools 26.0.0.851/API 26。Go 依赖仍为仓库锁定的 Mihomo v1.19.32 与 yaml.v3 v3.0.1；未升级模块图。

- `go test -race ./configpipeline` 与 `go vet ./configpipeline` 通过。测试涵盖无覆写、重复多层 mapping 合并、所有命名数组整体替换、null 保留键、DNS 直接子字段/hosts 整体替换、有序 YAML alias/merge、规则数组内容与优先级保持、独立 Strategy 按名更新幂等、引用缺失/组环、provider-only、原文保留、固定字段差异摘要、订阅更新重应用、生成/保存/激活/提交失败、取消后恢复、回滚失败单独报告、保留上次成功、私有文件权限及陈旧/并发 revision 拒绝。
- 完整解析回调的集成检查在一次性子进程调用锁定 Mihomo `config.Parse`：普通代理与 inline provider-only 通过，无效代理协议与 `smart` 组拒绝。其余单元测试使用固定 mock，不能当作完整内核、平台安全或资源获取验收。
- 四个现有 Node 回归通过：profile-name（11 项）、vpn-startup、app-runtime、background-lifecycle。首次调用未加载仓库 env 导致路径缺失，加载正确环境后四项全部通过；没有修改检查脚本。
- `bash scripts/build-core.sh` 交叉编译通过，沿用仓库已匹配的 gVisor 补丁；`ohpm install`、`hvigorw clean --no-daemon`、未签名 `bash scripts/build-hap.sh` 通过（33 tasks 全部执行）。独立包尚未被生产导入，HAP 构建证明原入口未破坏，不能证明新模块已被应用执行。
- HAP ZIP CRC、必要资源及三个原生库 AArch64 ELF 检查通过。HAP SHA-256：`16417f7d346af6c99db07da64eb2185928a4ce3e6e88f767e102fa9c334c041a`；包内 libmihomo.so：`b021bb60317ba469c29b3bb66505807e1ef0e5ca39826f659cc2d62efe2a8b35`。确认 libentry.so、libc++_shared.so、override.yaml、geodata/geoip.metadb 存在；产物未提交/签名/发布。
- `git diff --check` 通过；新增文档链接检查通过。未操作真实设备、VPN/安全设置，未使用真实订阅或私有凭据，无权限拒绝。

## 并行交接与未覆盖边界

[接入契约](../reference/config-pipeline.md) 给安全线 `Transform(ctx, *yaml.Node)` 和必填完整 Validator、策略线同型可选转换、宿主 Store/Activator/Restore 与 expectedActiveRevision。安全值和强约束只由安全线提供；本包不实现第二套 Controller/TUN 限制。完整校验必须在宿主 worker 串行执行并处理 Mihomo 的临时状态/对象/资源/日志责任。

只读参考兼容线 [PR #2](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/2)，初次核对身份 `bda3a0abe8355a34bbb03df8eb252a1404a622ba`，没有基于其未合并分支修改代码。按父任务基于上游源码的统一决定，通用 Merge 已改为 Clash Verge v2.5.8 固定来源语义：mapping 递归、所有数组替换、null 为值、DNS 直接子字段替换及整个 hosts 替换；按名组更新仅由 Strategy 负责。没有生产存量自定义方言数据，不保留 `$delete`/removePaths/第二套公开方言。规则不在通用 Merge 中隐式去重；Strategy 自身必须幂等，订阅更新从新原文重应用，不复刻 Canonical 旧转换的累积缺陷。

兼容线的 PlanRequestV1/验证回执/平台-provider-内核能力快照属于宿主协议；本包加入成功版本 revision 拒绝迟到更新，未声称已实现该完整 ArkTS 协议、provider 获取、必要区域策略或全部 20 个目标场景。生产接入还需按固定输入分类、快照、网络身份/内核能力绑定以及策略 ID/版本联调。

文件指针的原子提交和进程内回滚已测；掉电/进程退出期间运行内核与文件不能组成跨进程原子事务。需宿主单写者及启动时从 Current 恢复，回滚失败应阻断进一步激活并显示恢复状态。未验收真实系统会话、启动/REST 重载平台一致性、设备转发或 OHOS 文件系统掉电行为。

共享 README、AGENTS、development 没有编辑。父任务可在文档索引增加独立接入契约链接，并在开发顺序引用已固定来源版本的 Merge 语义与平台联调门槛。

## 运行时写入事务交接补充

只读核对运行时 [PR #4](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/4)，head `4694e45fe6b6ea8fbe55d93ba0798d9a61db22d3`。该线阻止迟到更新的成功时间戳/重载，不负责已进入 ProfileStore 的下载/原文写入。本线在接入契约增加 profileId/sourceRevision/selectionEpoch/expectedActiveRevision ticket、选择与提交同一锁、候选暂存、原文及元数据统一 manifest 发布与取消/过期恢复要求，明确 Current.ID 单独不能保护待选 profile 的切换。新增的是后续集成门槛与验证剧本；未修改/验证生产 ProfileStore 写入路径，不声称现有在途写入风险已解决。

## 固定上游 Merge 来源与补充验证

实际读取 Clash Verge v2.5.8 提交 `4337bd85758d54d7b9044b2da3c9ac1176eae1f3` 的 src-tauri/src/enhance/merge.rs（blob `c1c00fc05474e261953784acd6365c54c95a4ee3`）及 field.rs。直接核对 use_merge 的 DNS mapping extend、hosts 整体 insert、其余 deep_merge 和 overlay 顶层 ASCII 小写化；源码内包含 nameserver-policy/fallback-filter/hosts 替换及空值清空的回归。DNS/hosts 版本边界为上游提交 `6a85d0344e5df34c750ca3158e53b8b37a5ddf82`。旧版来源不声明等价迁移。

实现调整后 `go test -race ./configpipeline`、`go vet ./configpipeline` 通过：命名数组整体替换且不残留旧项字段、null 保留键、DNS 子 mapping/hosts 丢弃旧字段、未指定 DNS 项及普通递归 mapping 保留、显式空 mapping/array 清空、规则数组内容不被 Merge 改写，以及 Strategy 独立按名更新幂等。事务/失败回滚/revision 和锁定解析器测试也通过。没有生产入口/模块图变化；原有 ArkTS 与完整 HAP 检查证明原入口/资源可构建，不能当作本包已生产集成的证据。

## 独审阻塞复现与修复

按独审会话 `01a1311c-bf5d-72a5-9f7d-ec1884f030bb` 的转述在 head `39a9d1cc6c39fb56ee913c8f04a67438c4fb635c` 独立添加最小回归，实际复现失败：自定义 scalar/mapping/sequence/root tag 及不支持的标准 collection tag 被接受；Platform 注入合成 Controller Secret 后生成/成功 YAML 与 source provenance 可持久化，直接 FileStore.Stage 也可绕过；旧 Previous 中 secret 进入差异 section。当前没有可调用的该会话读取工具，没有声称已读取审查员完整会话。

只读核对安全 [PR #9](https://github.com/Starfie1d1272/clash-OpenHarmony/pull/9)，身份 `9ecb964f319edff6fccfd36d78850c6b8e4fa609`。其 enforcePlatformSecurity/preparePlatformConfig 明确仅构造内存运行态，Secret 来自安全模块专用私有存储；不能将该运行态函数直接适配成 Compiler 的持久投影。修复将 Platform 类型明确为 PlatformProjection，契约只允许非敏感可持久化字段；Validator/Activate/Restore 必须在宿主私有副本中调用同一安全模块注入敏感运行态。本包不读取/生成/另存 Secret、不复制平台安全字段或数值约束，只在序列化边界拒绝顶层 secret（含别名、大小写、null/空串）。输入/Strategy/Platform 产出及 FileStore.Stage 的 YAML/原文/覆写都检查；错误为固定文本，错误接入在写盘前拒绝，差异清单移除 secret。

Tag 支持明确限定为标准 map/seq、str/bool/int/float/null/timestamp/binary scalar 及实际 merge-key；自定义 tag 与 !!set/!!omap 等不支持的 collection tag 不再静默接受。检查包括别名目标、overlay 和回调输出；合法标准隐式/显式 tag 与已有 alias/merge-key 回归保持通过。

最终 `go test -race ./configpipeline`、`go vet ./configpipeline` 通过。新增回归验证所有上述拒绝路径、拒绝前无文件生成/无激活、上一成功指针和运行版本不变、直接 Stage 的伪造 Result 拒绝，以及合成 Secret 仅在宿主校验副本内使用：不进入生成 YAML/备份/差异，轮换不改变候选 Digest。正常 Merge/引用/事务/取消/回滚/revision 及锁定 Mihomo 子进程测试继续通过。新增测试使用合成标记和 mock runtime injection；没有实现或声称安全 PR #9 的生产 adapter 联调、真实凭据或真机认证。安全线需提供非敏感投影 adapter 后才能生产接入；当前依旧独立模块。
