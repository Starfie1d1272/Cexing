# Smart 首个测试版来源

- 基于 vernesong/mihomo `daf3ad03021cca6031f4a7303ca6d861a14d5a16`（GPL-3.0），模块 ZIP 与 go.mod 摘要固定于 `core/go.sum`。本目录补丁新增离线模型校验、状态/导入 REST 路由、实际模型预测计数，并禁用全部联网模型更新与未校验热重载。
- `github.com/vernesong/leaves@2a1c022f37d0`：MIT，Copyright (c) 2018 Dmitry Khominich，构建模块内完整 `LICENSE.md` 必须保留。CI notice inventory 包含真实模块身份和各 notice 摘要；发行前仍须包含完整 notices 与对应源码，不能把清单视为法律审批。
- 上游 `LightGBM-Model/Model.bin` 仅在忽略的临时目录读取验证；本仓库与 HAP 不包含它。固定 SHA-256 `23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788`，9,345,218 B。上游 release 明确提供使用方式，但未注明模型单独分发许可，不因此声称可再分发。
- 用户可自行取得合法模型，通过受 Controller 认证保护的 `/smart/model` 导入自己的应用沙箱。宿主只接受上述真实资产，不生成模型或伪造预测，不代理下载，不上传训练数据。导入后的模型不进入 Git 或构建资源。
- Linux 回环节点仅用于真实核心/模型/连接路径测试，不包含订阅、用户节点、凭据或设备数据。
- `inbound-policy-race.patch` 仅对上述固定 fork 的构建专用模块缓存应用：LAN 允许/拒绝与免认证前缀以拷贝后的 atomic 快照发布，避免热重载写入与 mixed 入站读取并发访问同一 slice。源码与补丁摘要写入构建身份；编译后恢复原模块字节并复验完整性。此补丁不更改热重载行为，也不证明真机转发故障的因果。
