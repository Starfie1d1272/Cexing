# ADR 0005：以 UID 来源、访问目标和用户备注构成分流入口

状态：接受。日期：2026-11-01。

## 决策与范围

策星面向普通消费者设备，采用公开 VPN 能力取得连接 UID，以 UID 流量来源为对象，展示可观测的域名或原始目标 IP，自动持续统计并保留本地来源历史和用户备注，用户可以选择跟随分流、内核 DIRECT 或当前出口，出口规则持久保存并在重连时恢复。用户从实际来源列表操作，不填写包名或 UID。

这是已选定的产品方向。自动显示真实应用名称、图标及系统级应用排除，不属于本方案的普通待开发项或验收条件。只有获得适用于普通分发、普通签名和目标设备的可复现身份接口后，才另行评估扩展。本决定不声称平台未来永远无法提供该能力。

## 官方能力与权限依据

本次核查使用 API 26、版本 `26.0.0.105` 的 SDK 原始声明，并交叉核对官方文档。SDK 版本取自 ETS 组件的 `oh-uni-package.json`。公开文档的 `master` 会更新，后续复核应同时核对实际构建 SDK、接口起始版本和目标系统。

| 能力 | 已核对的声明与限制 | 对本方案的含义 |
|---|---|---|
| 连接 → UID | SDK `@ohos.net.connection.d.ts` 的 `getConnectOwnerUid` / `getConnectOwnerUidSync` 标记 API 23，要求 `GET_NETWORK_INFO`，仅 VPN 应用可调用；未匹配返回 -1。端口为零可能扩大匹配；UDP 查询无远端匹配时可退回本地地址匹配。[官方网络连接参考](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-net-connection) | 可以查询来源 UID；需要完整原始四元组、失败处理和协议边界。UID 结果不等于系统验证的应用名称，也不能把 UDP 回退解释为严格四元组或 socket 代际证明。 |
| UID → 包名 | SDK `@ohos.bundle.bundleManager.d.ts` 的 `getBundleNameByUid` 自 API 14 提供。声明列出两种权限；[官方接口文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-ability-kit/js-apis-bundleManager.md#bundlemanagergetbundlenamebyuid14)进一步区分：三方应用要求 `GET_BUNDLE_INFO_PRIVILEGED`，系统应用才可使用 `GET_BUNDLE_INFO` 替代。 | `GET_BUNDLE_INFO` 的 normal 等级不能据此推导为普通三方应用可查任意 UID。 |
| 包信息特权 | [官方权限清单](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/permissions-for-enterprise-apps.md#ohospermissionget_bundle_info_privileged)将 `GET_BUNDLE_INFO_PRIVILEGED` 定义为 system_basic，并列明系统/企业应用的开放范围。 | 企业或系统分发条件不等于普通消费者安装即可获得的能力；声明权限或展示用户授权弹窗本身不能证明已获授权。 |
| 枚举全部应用 | [包管理系统接口](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-ability-kit/js-apis-bundleManager-sys.md#bundlemanagergetallbundleinfo)将 `getAllBundleInfo` 列为系统接口，要求 `GET_INSTALLED_BUNDLE_LIST`；[华为官方 FAQ](https://developer.huawei.com/consumer/en/doc/harmonyos-faqs-V14/faqs-ability-45-V14)说明全应用查询的 system_basic 权限要求。 | 不能把设备调试工具能枚举应用，作为普通应用内置选择器的能力依据。 |
| 名称与图标资源 | [bundleResourceManager 官方说明](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-ability-kit/js-apis-bundleResourceManager-sys.md)自 API 11 提供系统接口，API 12 扩展名称/图标查询范围；要求 `GET_BUNDLE_RESOURCES`，其[权限等级为 system_basic](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/permissions-for-system-apps.md#ohospermissionget_bundle_resources)。 | 能读取自身资源或知道包名，都不能单独证明可以取得其他应用的真实展示资源。 |
| 系统 VPN 应用范围 | SDK `@ohos.net.vpnExtension.d.ts` 及[官方声明](https://github.com/openharmony/interface_sdk-js/blob/master/api/%40ohos.net.vpnExtension.d.ts)中，`trustedApplications`、`blockedApplications` 自 API 11 提供，元素为包名字符串，二者互斥；API 23 起名单上限由 64 增至 256。 | 系统名单不接收 UID。来源 DIRECT 仍经 TUN 和内核，不能标作系统排除应用。 |

`getConnectOwnerUid` 的 API 23 注释和 UDP 回退规则已在上述 SDK 原始文件中核对；公开源码镜像与商业 SDK 的收录节奏可能不同，不能仅凭镜像缺少符号判断设备支持情况。

复核时，在对应 SDK 的 `ets/api` 目录检索 `getConnectOwnerUid`、`getBundleNameByUid`、`trustedApplications`、`blockedApplications`，读取紧邻声明的 `@since`、权限与说明；再核对权限清单及系统接口标记。仅检索接口名或看到 TypeScript 声明存在，不足以确认普通签名的运行授权。受限签名、企业设备和普通零售设备必须分别记录证据。

## 已评估路线及取舍

历史评估覆盖了公开 API、原生实现和用户辅助辨认。下面记录的是采用条件与证据边界，不把未执行的实验写成运行结论。

| 路线 | 评估结论 |
|---|---|
| 直接获取包名、安装列表、名称和图标 | 上述接口存在明确权限或系统接口条件；当前没有满足普通消费者分发条件的完整实证链路。 |
| 换用 Go/C++、读取 `/proc` 或调用隐藏接口 | 更换语言不改变应用令牌、沙箱与服务端权限。尚无公开契约和普通签名的可复现结果证明这些路径能稳定取得其他应用身份；不把底层可调用性当成授权。 |
| 通过 HDC、调试命令或外部辅助程序导入映射 | 调试会话具有独立操作条件；其查询结果也可能随安装、卸载或 UID 复用失效。可用于开发时核对，不能作为普通用户必须依赖的产品链路。 |
| 临时隔离单个应用、黑白名单试探 | 系统 VPN 名单仍需先知道包名；切换范围还会改变实际网络覆盖。它没有解决从未知 UID 取得应用身份的前置问题。 |
| 根据域名、IP 或时间窗口推断应用 | 多个应用可共享服务、CDN 和 UID，后台请求也会混入观察窗口。只作为用户辨认线索；用户备注保存为用户输入，不转成系统认证的应用身份。 |

因此采用来源列表可以在现有公开能力内完成“看到实际流量 → 辨认来源 → 指定出口 → 核对真实行为”的操作。域名可用时显示域名；纯 IP 保留原始目标 IP，不用反向解析、运营商或地理位置补造应用名称。详情中的 UID 用于技术核对，不作为普通输入项。

## 证据边界与验收口径

已经核实的是接口声明、权限边界和当前源码所采用的数据路径。本机合成验证覆盖会话隔离、端口复用分区、身份请求取消、认证及调度；这些证据不证明真实设备上的 UID 成功率、共享 UID 行为或实际网络出口。涉及设备的具体结果与产物身份记录在对应 Issue/PR 或本地私有证据中，本 ADR 不维护进度表。

本方案验收聚焦来源归因、目标展示、用户备注和实际分流效果；未知身份必须保持未知，保存策略不能代替出口验证。系统 DNS 劫持、既有连接、共享 UID、UID 重用及不同 API 版本的降级条件，以[流量契约](../reference/traffic.md)为准。普通入口不得重新引入手填包名或 UID，也不得因真实应用名/图标不在当前权限范围而判定整个来源方案未完成。

后续若官方新增普通应用可用的身份接口，或取得覆盖签名、分发、设备与资源查询的有效授权证据，可重新评估真实名称/图标及系统名单操作。评估须验证共享 UID、卸载重装和映射失效处理，并保留已有来源与用户备注的含义。
