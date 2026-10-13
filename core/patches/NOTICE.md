# Smart 首个测试版来源

- 基于 vernesong/mihomo `daf3ad03021cca6031f4a7303ca6d861a14d5a16`（GPL-3.0），模块 ZIP 与 go.mod 摘要固定于 `core/go.sum`。本目录补丁新增离线模型校验、状态/导入 REST 路由、实际模型预测计数，并禁用全部联网模型更新与未校验热重载。
- `github.com/vernesong/leaves@2a1c022f37d0`：MIT，Copyright (c) 2018 Dmitry Khominich，构建模块内完整 `LICENSE.md` 必须保留。CI notice inventory 包含真实模块身份和各 notice 摘要；发行前仍须包含完整 notices 与对应源码，不能把清单视为法律审批。
- 上游 [LightGBM-Model release](https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model) 的 `Model.bin` 固定 SHA-256 `23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788`、9,345,218 B，发布标签提交 `16d678a879606447b2be49a21b293dde69189f57`。该标签的 [README 许可段落](https://github.com/vernesong/mihomo/blob/LightGBM-Model/README.md#license) 与 [LICENSE](https://github.com/vernesong/mihomo/blob/LightGBM-Model/LICENSE) 声明项目 GPL-3.0；未发现模型资产排除声明。按项目发布声明打包原始模型，不声称作者给出单独授权。固定来源见 `third_party/smart-model/source.json`，完整 GPL 正文见同目录 LICENSE，实际二进制仅下载到忽略的资源目录并随 HAP 分发，不进入 Git。
- 对应源码保留本仓库公开的 `core/`、`core/go.mod` / `go.sum`、离线补丁、构建脚本和对应提交；模型上游发布资产、标签与项目源码一并标注。未找到官方完整训练流水线，不能把模型来源声明说成训练可复现。发行时仍需逐项核对 GPL 对应源码提供方式和其他依赖义务，署名并非全部要求。
- 认证保护的 `/smart/model` 手动导入保留为替换/恢复入口；宿主只接受同一固定身份，不生成假模型或上传训练数据。内置模型首次离线铺盘到实际 Go HomeDir，损坏文件备份后恢复；加载失败保留统计 Smart 回退。
- Linux 回环节点仅用于真实核心/模型/连接路径测试，不包含订阅、用户节点、凭据或设备数据。
