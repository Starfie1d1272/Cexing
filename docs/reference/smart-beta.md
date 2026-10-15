# Smart 首个测试版

固定核心为 vernesong/mihomo `daf3ad03021cca6031f4a7303ca6d861a14d5a16`，源码 GPL-3.0、leaves MIT 与模型使用边界见 [notices](../../core/patches/NOTICE.md)。构建使用 `core/go.mod` / `go.sum`，只在专用模块缓存应用 [离线补丁](../../core/patches/smart-offline.patch)，不改变共享 Go 缓存。四个基础兼容 ABI、三个生产扩展 ABI、NAPI worker 和 TUN fd 所有权遵循[平台契约](platform.md#abi-与线程)。

## 启用

「设置 → Smart」的自动转换默认开启，可随时关闭。配置事务对生成的运行副本，在 Merge 后、平台投影与 Mihomo 校验前，默认仅把 `url-test` 组改为 `smart`，`load-balance` 保留原算法，仅启用的 `EditIntent.SmartGroups` 明确选择转换时改为 Smart；组名、节点/提供者成员、Selector/Fallback、手选入口和规则引用保留。生成组请求离线 LightGBM 模型，关闭训练 CSV 收集和 ASN 偏好；模型缺失或无效时 Smart 使用统计策略。关闭自动转换会经同一事务从原始订阅与 Merge 重新生成，未显式覆盖的组恢复原类型；已启用的逐组选择仍优先于默认开关。订阅更新、切换与下次启动重新应用这些意图。原始 YAML 不修改。

已有 `smart` 组保持原有参数。没有可转换组的纯 Selector 配置不自动新增组；地区模板另行预览和确认。页面的开关是生成策略意图，运行中的实际 Smart 组与模型加载、预测次数以 Controller 状态为准。

地区预览复用锁定 `golang.org/x/text` 的 ISO/CLDR 国家名、两位/三位代码和旗帜；名称推测不证明节点真实位置。代码支持紧邻数字的常见命名，如 `HK01`、`USA2`，不匹配嵌在其他英文单词中的代码；多地区冲突保留为“其他地区”，可手动修正。预览返回同一地区目录供选项使用，保存仍保留兼容的“未知”值。生成地区子组采用“香港 · Smart”等简洁名称，全部节点组为“全部节点 · Smart”；原策略入口 ID 与原规则目标保持稳定，已有已发布版本不就地改写，新名称在下次明确应用或更新时重新生成。

现有配置页的导入/编辑入口可使用真实 `type: smart` 策略。将需要自动选择的原组改为 Smart，继续引用订阅中已存在的至少两个可用节点，并让规则引用该组；不是把所有组改成 Smart，也不强制选中固定节点。最小组参数：

```yaml
# 配置片段；节点A/节点B须替换为已有配置中的有效节点名称。
proxy-groups:
  - name: Smart
    type: smart
    proxies: [节点A, 节点B]
    uselightgbm: false
    collectdata: false
    prefer-asn: false
    sample-rate: 1
lgbm-auto-update: false
```

`uselightgbm: false` 使用真实 Smart 统计策略。内置模型已校验铺盘后可将测试组改为 `true`。训练 CSV 收集默认不开启；Smart 自身的本地统计学习不等于训练 CSV。`prefer-asn` 首测显式关闭，避免额外 ASN 资源需求。不能把组名、权重排名或上游 `ModelPredicted` 字段当成 LightGBM 参与证据。

## 最小宿主/UI 接口

仅复用既有 Controller 回环地址和 Bearer 认证，不增加服务、C ABI 或进程隔离；没有非空 Controller secret 时两个新增路由均不挂载（404）。UI 会话应使用集成负责人统一的 Controller 客户端，不能建立另一份 secret/端口或记录认证值。原生入口为「设置 → Smart」，状态与二进制文件导入复用 CoreApi 的同一 Bearer 来源；模型官方链接与手机流程见 [设备指南](../how-to/device.md)。

| 请求 | 语义 |
|---|---|
| `GET /smart/status` | `schemaVersion:1`、固定 `core` SHA、`groups`（仅运行中的 Smart 组及其 `useLightGBM` 等真实设置）、`model` 和可直接展示的中文 `message` |
| `POST /smart/model` | `application/octet-stream` 原始模型字节；验证固定尺寸、摘要及 leaves 解析，在应用私有目录原子安装；200 返回 `installed/sha256/restartRequired/message`，400 返回可理解的 `error`；无凭据 401 |
| 上游 `GET /group/weights`、`POST /cache/smart/flush` | 保持真实内核语义；清缓存须用户显式操作，不能在页面打开时调用 |

`model` 字段：`state` 为 `not-requested/loading/missing/invalid/loaded`；`sha256` 是支持的模型身份；`predictions` 是当前进程实际 `PredictSingle` 返回有限正数的累计次数；`networkDownload` 固定 false；`restartRequired` 表示加载失败后导入需重启进程。计数是所有 Smart 组的进程累计观测，不是单组指标，也不证明当前目标请求采用了模型。`loaded` 与 `predictions:0` 必须分别展示“模型已加载”和“尚无模型参与证据”。Controller 暂不可达不能显示为 Smart 已启用。

上游真实模型为 [LightGBM-Model release](https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model)，9,345,218 B，SHA-256 `23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788`。构建从该固定公开资产下载并校验，随 HAP 离线打包；VPN Extension 在第一次 Go 初始化前校验并安装到 HomeDir 的 `Model.bin`。项目标签 GPL 来源、全文和对应源码边界见 [Smart notices](../../core/patches/NOTICE.md)。损坏文件在不覆盖既有备份的前提下另存并由内置模型恢复；资源或文件失败时使用统计 Smart。手动导入仍拒绝超长、损坏和其他版本。模型首次加载失败由上游 `sync.Once` 缓存，导入后须结束应用进程再启动；只停止/启动 VPN 不能重置，绝不通过 `dlclose` 重置 Go runtime。

## 验证与手机边界

按 [构建指南](../how-to/build.md) 使用官方工具链。`scripts/test-smart.sh` 在专用缓存运行实际模型、parser/router 与配置回归；构建 Full 将校验后的公开模型作为 `SMART_REAL_MODEL` 测试真实预测/转发，并核对包内模型及 GPL 文本。Quick 无模型时明确 skip，不能冒称模型验收。实际手机的预测链与资源成本仍须单独测试。

Linux 检查通过实际回环 HTTP 节点、mixed listener、规则和 Smart 统计回调证明模型参与；`scripts/test-smart-loader.sh` 用真实 bridge.cpp 与宿主链接拦截验证缺符号/完整 ABI 路径，其日志桩不证明 OHOS TLS。

未签名 OHOS HAP 的模块身份、平台参数、全部七个生产动态 ABI（四个基础兼容符号与三个扩展，清单见 `scripts/ci/abi_contract.py`）、独立 strip 字节、非空资源及固定模型和 GPL 正文由 `scripts/ci/verify-hap.py` 检查，普通与优化 Python 不能绕过。构建记录还绑定本地生产 Go 源码摘要及文件集合，源码修改/新增不能复用旧核心；构建记录在模块完整性复验通过后才生效，失败不遗留成功记录；记录保护受信工作目录内的构建身份，不是签名供应链证明。生成产物不提交、不签名、不安装、不发布。手机仍须验收真实 TUN、TLS/REALITY、UDP/DNS、IPv6、后台与网络切换；Hokit 签名安装和用户设备操作由本地会话完成。原生文件选择/上传和应用级重启已接入；手机仍需确认重启后 VPN Extension 进程换代。
