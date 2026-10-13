# GitHub-hosted HarmonyOS HAP 调查与验证（2026-10-13）

基线：从远端 main `81215c5` 创建 `ci/github-hosted-hap`。范围仅 CI、构建入口和操作文档；不签名、不操作 HDC/手机、不读取真实配置、不自动合并。调查过程中用户明确允许社区/镜像来源，故实施以固定摘要核验的已有镜像，而非声称已完成官方下载授权。

## Full 排队原因

[原运行 38337622322](https://github.com/Starfie1d1272/clash-OpenHarmony/actions/runs/38337622322) 的 REST jobs 返回 full=`queued`、labels=`self-hosted, linux, x64, harmonyos-ci`、runner_id=0、runner_name 为空、steps 为空。该 job 尚未分配 runner，不是 Go/ArkTS 编译慢。GitHub 不自动创建符合自托管标签的机器。`environment: harmonyos-ci` 也不提供机器。当前连接无列举 runners/environment 管理权限（403），因此不能断言仓库完全没有注册 runner；能确认的是这个 job 没有被合适的在线 runner 接走。可能的 environment 审批/分支规则需管理员另行核对。

## 真实社区实践

以下核对了实际 YAML、Setup 脚本、REST run/jobs、Release assets；run success 与存在下载资产分别记录。过期日志/Artifact 不当作可再次下载或真机安装证据。

| 项目与 workflow | 工具来源/环境 | 真实命令与产物 | 成功证据 / API 26 适用性 |
|---|---|---|---|
| [DaLongZhuaZi/NGF](https://github.com/DaLongZhuaZi/NGF)，[build.yml](https://github.com/DaLongZhuaZi/NGF/blob/093eeac9e20a6da8f67a763496e1bdf20126e563/.github/workflows/build.yml) | ubuntu-latest + ghcr.io/dalongzhuazi/harmonyos-ci:api26r；[Dockerfile](https://github.com/DaLongZhuaZi/harmonyos-ci/blob/main/docker/harmonyos-ci.Dockerfile) 从传入 URL 下载 CLT，实际推荐 ErBWs 分片镜像。镜像浮动 tag，摘要校验可选。Node/JDK/SDK 镜像预装 | ohpm install --all；hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon --stacktrace；上传 hap-unsigned，再发 nightly Release。未签名阶段不需要个人证书或 Huawei 登录 | [37609962611](https://github.com/DaLongZhuaZi/NGF/actions/runs/37609962611)，2026-10-07，jobs 构建/上传/Release 全成功；Artifact 11477915382，5,496,468 bytes；[nightly](https://github.com/DaLongZhuaZi/NGF/releases/tag/nightly) 有 entry-default-unsigned.hap。API 26 Release/CLT 821，证明 API 26 可在托管 Linux 构建，不证明本项目固定 851/SDK .105 组合 |
| [OHOTP/ohtotptoken](https://github.com/OHOTP/ohtotptoken)，[build.yaml](https://github.com/OHOTP/ohtotptoken/blob/main/.github/workflows/build.yaml) | ubuntu-latest，ErBWs/setup-ohos@v1，version=latest/cache=true。其 [setup.sh](https://github.com/ErBWs/setup-ohos/blob/main/setup.sh) 从 ErBWs/ohos-sdk Release 拼接 .aa/.ab，检查镜像提供的 sha256 后解压；内置 Node/ohpm/hvigor/sdk | ohpm install --all；hvigorw clean assembleHap -p buildMode=release --config properties.ignoreSignHap=true；上传 unsigned.hap，并在合并触发发布 Release。无人工登录/个人签名，权限 write-all 比本项目宽 | [30505665559](https://github.com/OHOTP/ohtotptoken/actions/runs/30505665559)，2026-07-30，Build hap/Upload artifact/Create Release 均 success；[1.2.5](https://github.com/OHOTP/ohtotptoken/releases/tag/1.2.5) 有未签名 HAP。近期 Quality 成功不能替代 HAP build 成功。浮动 latest，不能直接视作 API 26/.105 证明 |
| [fcitx-contrib/fcitx5-harmony](https://github.com/fcitx-contrib/fcitx5-harmony)，[ci.yml](https://github.com/fcitx-contrib/fcitx5-harmony/blob/19d61297e6313014bff8b15a488d843ffbcfc1bd/.github/workflows/ci.yml) | ubuntu-24.04；Node 18/JDK 17；[ohpm-cli-tools](https://github.com/fcitx-contrib/ohpm-cli-tools/blob/master/action.yml) 下载自己的 5.1.0.840 CLT Release 分片。虽然 action 标题叫 OpenHarmony SDK，不能凭标题把这个 CLT 与纯开源 SDK 等同 | ohpm install --all；hvigorw assembleHap --mode module -p product=default -p buildABI=arm64-v8a/x86_64 -p buildMode=release --parallel --no-daemon；Artifact + nightly HAP。没有个人签名/交互登录。其 strict_ssl=false 和失败远程调试不采用 | [19953215012](https://github.com/fcitx-contrib/fcitx5-harmony/actions/runs/19953215012)，2025-12-05，两个架构 build 及 release success；[latest](https://github.com/fcitx-contrib/fcitx5-harmony/releases/tag/latest) 有两个 HAP。日志 steps 已被清理，不能重读编译日志；老工具组合不适用于本项目 API 26 |
| [jiegec/NetworkToolsHarmony](https://github.com/jiegec/NetworkToolsHarmony)，[build.yml](https://github.com/jiegec/NetworkToolsHarmony/blob/ec672bda75c82b3caf42665c507ffd1ec2435cc0/.github/workflows/build.yml) | ubuntu-latest；[openharmony-rs/setup-ohos-sdk](https://github.com/openharmony-rs/setup-ohos-sdk/blob/main/action.yml) 安装 **OpenHarmony 5.1.0**；npm hvigor/plugin 5.18.4、ArkUI-X plugin 4.2.3，复制本地 license 文件 | node ./node_modules/@ohos/hvigor/bin/hvigor.js -p product=ohos assembleHap；上传 entry-default-unsigned.hap。没有个人签名或登录步骤；不代表下载许可证自动处理适用于 NEXT | [19851981006](https://github.com/jiegec/NetworkToolsHarmony/actions/runs/19851981006)，2025-12-02，Ubuntu build success；历史 Artifact 已清理，无 Release。只证明 OpenHarmony/ArkUI-X 路线，不能替换 HarmonyOS NEXT 商业 SDK |
| [ohosvscode/harmony-next-pipeline](https://github.com/ohosvscode/harmony-next-pipeline)，[harmonyos-ci.yml](https://github.com/ohosvscode/harmony-next-pipeline/blob/master/.github/workflows/harmonyos-ci.yml) | ubuntu-latest + 社区 GHCR v5.0.4；ohpm/hvigor/SDK 预装，容器标签未固定摘要，不能确认再分发授权 | ohpm install --all；hvigorw clean --no-daemon；hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon；Artifact，tag 时可选签名和 Release | [v1.0.1](https://github.com/ohosvscode/harmony-next-pipeline/releases/tag/v1.0.1) 有 entry-default-unsigned.hap；REST success runs 已为空，不能声称最近流水线已验证成功。该老工具组合不是 API 26 依据 |

补充：[Okysu/harmony-auto-build](https://github.com/Okysu/harmony-auto-build/blob/main/demo.yml) 是 demo.yml 模板，仓库无已安装的实际 workflow，仅镜像 CLT 6.1.0.816 Release，不能把 README 产物说明当成功构建。[harmonyos-dev/hos-sdk](https://github.com/harmonyos-dev/hos-sdk) 示例为 macOS、CLI 2.0.0.2/sdkmgr API 9，也不是 NEXT API 26 方案。Setup Action 的社区许可证不重新许可其中 Huawei SDK。

## 官方获取、许可及来源

[官方获取文档](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-hmos-commandline-get) 明确 CLT 已含 HarmonyOS SDK，无需另行下载；[下载中心](https://developer.huawei.com/consumer/cn/download/command-line-tools-for-hmos) 提供 Linux 工具与 SHA-256/完整性指引。[26 Release 说明](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/deveco-studio-new-features-2600) 列出 SDK 和 Linux 支持。官方文档证明产品支持，不代表获得当前归档下载权限。

实际读取下载中心公开前端：route 有登录 guard；getToolVersionDownloadUrl 会检查联盟协议、版本协议和实名状态后返回 downloadUrl。匿名 delegate 请求按其公开请求格式发送后，服务返回缺少 X-HD-CSRF；未继续构造登录令牌、登录他人账号或调用协议签署。没有发现已验证、可长期无人值守获得 851 的官方下载接口。下载登录与**离线构建不需登录**是两件事。

现有云环境保留了 `commandline-tools-linux-x64-26.0.0.851.zip`，2,348,063,309 bytes、SHA-256 `ab604bd92721d5cbcafd154e6461d46b9f1b105e7b89eab04a9d046681198082`。这个摘要独立匹配 [社区 PKGBUILD](https://github.com/alex3236/devecostudio-linux/blob/e94cf6d0022f03e69e8231c26767bf55b03602e9/PKGBUILD)，但两者都不是本次独立取得的官方 checksum。已安装官方格式的文件声明 CLT 851、SDK .105/API 26；这是内容/版本证据，不是下载来源或许可证明。

镜像 pin 复用此前提供的南京大学网盘文件服务 URL（本次 HEAD 200、Content-Type application/zip、大小与文件名一致）。它是临时文件 URL，**不是已证明长期稳定的官方服务**。此限制写进 pin 和操作文档。ErBWs 最新 Linux Release 是 26.0.0.821，未看到 851；避免为套用社区 action 擅自更换固定 SDK。不采用来源不明 SDK、浮动容器、他人公开贴出的私有签名下载凭证、关闭 TLS 或修改官方工具内部文件。

归档 LICENSE.txt 的 DevEco 1.6 与 SDK 附件 B 3.1允许为 HarmonyOS 应用开发下载/安装/复制/运行，1.7(i)(j)和附件 B 4.1(d)限制提供给他人/再分发；本报告不把社区镜像存在当作华为书面授权，也不做供应商授权承诺。安装归档的协议摘要记录到身份。用户允许镜像来源，构建仍要求维护者已接受适用使用许可。仓库不再分发 SDK。

[GitHub 缓存规则](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching) 说明 PR 作者可读 base branch 缓存。因此不把商业 SDK 写入本公开仓库缓存；没有可据以断言合法公开缓存 SDK 的证据。只缓存公开模块下载归档和经完整摘要验证的面板/GeoIP。可选 URL secret 仅用于同摘要文件下载；不索取 Huawei 密码/Cookie/账号 Token，不需要签名证书或 PAT。

## 架构、耗时和成本比较

| 路线 | 可行性/维护 | 来源与身份、稳定性 | 时间/成本与 Artifact |
|---|---|---|---|
| A 托管 Ubuntu + 官方安装 | Linux 技术可行；无自建服务器。当前官方授权 URL 获取未完成，不能宣称零配置落地 | 官方直链+固定摘要最好；URL有效期/下载权限影响冷启动 | SDK约 2.35GB 下载+约 7.1GB 解压；首次下载时间依地区/带宽而变。本项目未实测前不估算成功耗时；Actions 上传体验标准 |
| A' 托管 Ubuntu + 本次固定镜像 | 本任务实施；不换工具版本，无自建服务器 | 摘要与已用归档一致；非官方来源、镜像许可与临时 URL 仍有限制；到期明确失败而非用历史 HAP | 每次 SDK 冷准备，公开依赖/面板/GeoIP 可热复用；不需要长期主机账单 |
| B 托管 + SDK 缓存 | 技术可行；本公开仓库不启用，需先解决缓存可读范围及独立授权 | 重新核验原始归档可避免缓存改包；公开 SDK 缓存增加分发风险；未解压校验的可执行缓存也有供应链风险 | 理论省下载/解压但不能给本项目未经测量的热缓存数字；SDK占用大，缓存驱逐会恢复冷下载 |
| C 自托管预装 | 保留可选入口，需在线 runner/标签；持续主机或一次性云 VM 需运维 | 可固定官方工具，但需限制仓库/分支、清洁环境和账号隔离 | 不付托管 runner 分钟也有主机/运维成本；SDK冷准备可摊销。原 Full 无在线匹配 runner 所以没有耗时/Artifact |
| D 授权外部云构建 | 现有 Codex Cloud 已证明能构建；没有已验证由 Actions 调度的云 API/身份方案，不虚构接入 | 需授权云提供商、精确SHA/产物校验、短期凭证和失败传播 | 无必需自建服务器，但云额度/传输/API集成费用因服务而异；转回 Actions upload-artifact 可统一下载，尚未实现此协调 |

[GitHub billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) 的标准 GitHub-hosted 公共仓库使用与私有/更大 runner 计费不同。当前为公开仓库、标准 Ubuntu；不启用付费 larger runner 或额外缓存计费扩容。7天 Artifact/缓存保留会影响存储/可下载性，具体账号额度以 billing 为准。维护成本主要是下载链接/工具pin、上游GeoIP快照变化、依赖与缓存审核；不包含设备或商店发布。

阶段结构：SDK下载/摘要/CRC/解压 → Zashboard冷源码构建或完整校验命中 → Go下载+verify → Smart回归 → 原生Mihomo Smart新编译 → ohpm → 固定GeoIP → clean → Hvigor C++ NAPI/ArkTS/打包 → CRC/ELF/ABI/完整资源/模块身份校验 → SHA一致Artifact上传。Go跨编译和Smart测试不复用编译输出；缓存仅减少重复公开依赖下载。Hvigor日志提供CMake/ArkTS任务计时，timings artifact 提供整体阶段和失败退出码。

## 本任务验证

实现检查：下载主机限制、拒绝错误SHA/路径穿越/越界符号链接的合成ZIP用例通过；tracked source-check、shell语法和git diff --check通过。未启用SDK缓存，Quick workflow 保留原样。完整本地构建与实际 Actions 的结果在完成后补充，不把已有历史 HAP作为本任务产物。
