# Smart 首个测试版来源

- 基于 vernesong/mihomo `daf3ad03021cca6031f4a7303ca6d861a14d5a16`（GPL-3.0），模块 ZIP 与 go.mod 摘要固定于 `core/go.sum`。本目录补丁新增离线模型校验、状态/导入 REST 路由、实际模型预测计数，并禁用全部联网模型更新与未校验热重载。
- `github.com/vernesong/leaves@2a1c022f37d0`：MIT，Copyright (c) 2018 Dmitry Khominich，构建模块内完整 `LICENSE.md` 必须保留。CI notice inventory 包含真实模块身份和各 notice 摘要；发行前仍须包含完整 notices 与对应源码，不能把清单视为法律审批。
- 上游 [LightGBM-Model release](https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model) 的 `Model.bin` 固定 SHA-256 `23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788`、9,345,218 B，发布标签提交 `16d678a879606447b2be49a21b293dde69189f57`。该标签的 [README 许可段落](https://github.com/vernesong/mihomo/blob/LightGBM-Model/README.md#license) 与 [LICENSE](https://github.com/vernesong/mihomo/blob/LightGBM-Model/LICENSE) 声明项目 GPL-3.0；未发现模型资产排除声明。按项目发布声明打包原始模型，不声称作者给出单独授权。固定来源见 `third_party/smart-model/source.json`，完整 GPL 正文见同目录 LICENSE，实际二进制仅下载到忽略的资源目录并随 HAP 分发，不进入 Git。
- 对应源码保留本仓库公开的 `core/`、`core/go.mod` / `go.sum`、离线补丁、构建脚本和对应提交；模型上游发布资产、标签与项目源码一并标注。未找到官方完整训练流水线，不能把模型来源声明说成训练可复现。发行时仍需逐项核对 GPL 对应源码提供方式和其他依赖义务，署名并非全部要求。
- 认证保护的 `/smart/model` 手动导入保留为替换/恢复入口；宿主只接受同一固定身份，不生成假模型或上传训练数据。内置模型首次离线铺盘到实际 Go HomeDir，损坏文件备份后恢复；加载失败保留统计 Smart 回退。
- Linux 回环节点仅用于真实核心/模型/连接路径测试，不包含订阅、用户节点、凭据或设备数据。
- `inbound-policy-race.patch` 仅对上述固定 fork 的构建专用模块缓存应用：LAN 允许/拒绝与免认证前缀以拷贝后的 atomic 快照发布，避免热重载写入与 mixed 入站读取并发访问同一 slice。源码与补丁摘要写入构建身份；编译后恢复原模块字节并复验完整性。此补丁不更改热重载行为，也不证明真机转发故障的因果。
- `app-traffic.patch` 基于同一固定 fork：在 TCP/UDP statistic 的计数路径加入可选宿主观察器，仅对 `pushToManager` 的 tracker 发创建/增量/关闭通知；初始计数包含在内，关闭不补加终值。outbound 包装器保留首个实际 adapter 的流量类别，避免按用户命名猜测 DIRECT。只向 Go 内存聚合发送增量，不逐包调用平台或写盘；TUN UDP 复用已有 handler 身份隔离 NAT key，防止跨 listener 重用旧 tracker，原始地址元数据不变。同样经私有模块缓存、原始字节校验、产物绑定及恢复复验。
