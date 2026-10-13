# CI 与构建身份

Quick 在 GitHub 托管 Ubuntu runner 上执行；Full 只由人工调度到 GitHub-hosted Ubuntu 或预装授权 SDK 的可信 runner。两者均不签名、不安装设备、不发布到商店或自动合并。Full 完成校验后保存该次 CI 构建的未签名测试包。仓库、应用名称和 bundleName 保持源声明。

## Quick

```bash
npm ci --prefix scripts/ci --ignore-scripts --no-audit --no-fund
bash scripts/ci/quick.sh
```

使用 `scripts/ci/toolchain.json` 中的 Go/Node 组合；Actions 按完整 commit 固定。检查受 Git 跟踪的 JSON/JSON5/YAML、默认配置、ARM64 构建声明、空签名配置、shell 语法、敏感文件/常见密钥模式和来源声明。扫描发现风险只输出文件名，不打印匹配值；模式扫描不能证明所有秘密都已发现，也不能替代完整许可证审查。

四个现有回归脚本通过固定 TypeScript 运行真实 `.ets` 中可在宿主执行的逻辑，系统 API 使用既有 mocks。`arkts-mocks.cjs` 只替换编译器导入，**这不是 ArkTS 编译或 SDK/API 验证**。Full 使用 SDK 内的编译器重跑这些回归并编译工程。

Go 在独立临时模块/构建缓存执行 `go mod download`、`go mod verify` 和 `go test ./...`，强制 `-mod=readonly`、`GOTOOLCHAIN=local`。基线根 Go 包没有测试文件，此步骤首先提供宿主编译检查；后续独立模块的真实测试可由相同入口运行。已下载的选定模块许可证/NOTICE 的相对路径及 SHA-256 形成清单，完全缺少声明时失败；只有子目录声明的模块和未下载的扩展模块图依赖单列待审查；清单不代表 GPL 或数据源分发义务已完成。

## Full 的官方环境

按 [构建指南](build.md) 和 [华为入口](https://developer.huawei.com/consumer/cn/download/) 核对工具链许可。托管 Full 使用 `scripts/ci/sdk-download.json` 中已核对的镜像归档，固定版本、字节数和 SHA-256，校验 ZIP 路径/符号链接/CRC 后解压；来源与摘要依据写入构建身份。此摘要与已有云归档和独立社区 PKGBUILD 一致，**不是独立取得的华为官方摘要，也不证明镜像发布者拥有再分发许可**。仓库不分发 SDK/NDK 或开发者凭据。只在接受供应商许可、获准使用该环境后运行。

默认镜像的文件服务 URL 有有效期。失效时，管理员可在 `harmonyos-ci` environment 设置可选 secret `HARMONYOS_CLT_URL`，替换为允许主机上的同版本归档；不得改变摘要来接受未知内容。该 secret 只用于下载，不授予 GitHub/Huawei 账号权限，不应填入 Cookie、密码或访问账号的 Token。更换镜像主机需审查 `setup-clt.py` 主机列表。没有官方无人值守登录接口的验证证据；CI 不自动登录或接受账号协议。

SDK 不进入公开 Actions Cache。公共仓库缓存可被 PR 工作流读取，不能把它当私有 SDK 存储；确认独立分发/缓存授权前，不启用该优化。公开 Go 下载归档和 Zashboard 资源可缓存，每次仍校验模块或完整资源摘要。新内核始终重新编译，NAPI/ArkTS 始终 clean 构建，不缓存 HAP、签名目录、解压/打补丁的模块或 Go 编译缓存。

经审查的组合保存在 `scripts/ci/toolchain.json`：CLT 26.0.0.851、SDK/NDK 26.0.0.105/API 26、Hvigor/plugin 6.26.8、ohpm 26.0.0.630、wrapper pnpm 10.28.2、Go 1.27.2、Node 26.11.1、JDK 27。不同组合需独立验证并更新该文件及 Actions 声明。构建前校验声明，构建后校验实际 wrapper pnpm。全新环境用独立 integrity lock 安装固定 wrapper pnpm 至隔离 Hvigor home，不修改官方 SDK；版本不符仍明确失败。

Runner 提供以下环境：

- `HARMONYOS_CLT_ROOT`：官方 CLT 根目录；默认使用忽略的 `command-line-tools/`。
- `JAVA_HOME`/`DEVECO_JDK_HOME` 和 PATH：选择 JDK 27。
- `NODE_HOME`/`DEVECO_NODE_HOME`：若设置，须选择同一固定 Node，不能覆盖 Actions 选择的版本。
- 可选 `CI_HVIGOR_WRAPPER_TOOLS`：受审查的公开 `wrapper/tools` 目录，用于种子化隔离 Hvigor home；不复制账号、配置或签名目录。实际 pnpm 必须符合固定版本。

```bash
npm ci --prefix scripts/ci --ignore-scripts --no-audit --no-fund
bash scripts/ci/full.sh
```

Full 要求干净、已提交的 checkout。Go 解压模块、编译、npm 和 Hvigor 缓存分别写入临时目录，退出时清理；公开 Go 下载归档只作为副本种子，校验后复用，补丁不改共享归档。ohpm 声明目前只有本地 NAPI 类型依赖，没有外部包；提交官方 ohpm 生成的 entry lockfile，安装后确认未改变输入；引入外部依赖时 source-check 会拒绝，届时须增加受审查的锁文件/冻结安装方式。供应商内部依赖保留官方安装内容，未声明实现整个 SDK 的逐字节可复现。

有离线面板源码声明时，Full 校验已有缓存的完整 Zashboard 文件集及摘要；缓存未命中时以提交锁定的 pnpm 和一次性源码目录准备 Zashboard，验证实际 SHA、上游锁、宿主补丁及已有资源清单。生成的 manifest/Pin 必须与已审查 Git 输入相同，差异立即失败；不自动接受新的资源摘要。

顺序是：模块完整性和许可证清单 → SDK mock 回归 → ohpm → 新编译 native core → 再次模块完整性 → 固定 GeoIP → Hvigor clean → 未签名 HAP → wrapper 版本 → 包内校验。GeoIP 每次解析上游 latest 的非预发布 Release，验证该 asset 的上游 SHA-256 和大小，再记录 release/asset ID、发布日期、来源和实际摘要。HAP 验证比较本次记录与包内数据，不永久锁定昨日快照。API/下载/摘要检查失败仍失败，不以旧文件顶替。

内核构建使用 `-trimpath` 和自行创建的临时模块缓存：Go 1.27 禁止 overlay 覆盖模块缓存，因此下载并验证原始依赖后，只补丁所选固定 gVisor 的 `endpoint.go`，不更改共享 Go 缓存，不触碰其他版本。仅接受原归档或完全一致的历史 Fstat 补丁，其他差异失败；构建后在专用缓存中临时还原该文件执行模块完整性检查并恢复补丁；旧 `patch-gvisor-tun-fd.sh` 是保留的历史手动工具，CI 不调用它。Android stub 每次由所选 NDK 重编译，避免继承旧 clang 产物。现有 `build-core.sh` 的调用方式不变。

报告生成到忽略的 `clash-openharmony/dist/ci/`：

- `build-identity.json`：commit/tree、固定工具组合、应用版本、输入 SHA-256、Go 实际版本/依赖图、HAP/native 和每个 ZIP entry 的摘要。
- `module-notices.json`：已下载选定模块的许可证与 NOTICE 摘要，以及模块图中未下载和仅有子目录许可的依赖；发行授权明确标为未批准。

校验 HAP CRC、路径和重复条目、证书形状文件、三个 ARM64 ELF DYN 库、四个 C ABI 及生成头文件原型、包内 Go metadata 与新编译库一致，且包内核心等于新核心经官方 `llvm-strip --strip-all` 的结果。逐项检查全部 rawfile、默认配置、固定 GeoIP 和包内应用/SDK 版本；strip 不改变内核身份的判断不能仅依赖 `/version`。

这是可重复执行和可审计身份流程，**没有宣称 HAP 每次逐字节相同**。Hvigor ZIP 时间戳和 SDK 内部依赖等仍需单独研究；摘要记录实际产物，构建成功不证明 VPN 转发、后台稳定性、SDK 低版本兼容性或发行许可。

## GitHub 配置

Quick 在 PR、main/本 CI 分支 push 和人工调度运行，只授予 `contents: read`，checkout 不保留凭据，无共享 Go 缓存。

Full 只有 `workflow_dispatch`。默认 `runner=github-hosted` 运行在 `ubuntu-24.04`，自动安装固定 Go、Node、JDK 27 和固定 CLT/SDK。`runner=self-hosted` 仅是可选备用，要求标签 `self-hosted, linux, x64, harmonyos-ci`，不要求用户购买或维护服务器。

调度前审查本次提交，填写 `reviewed_sha`（所选分支完整 40 位 SHA）和 `authorized_sdk=true`。仅允许本仓库分支，须由有调度权限的维护者人工审查明确 SHA；不运行 PR 或 `pull_request_target`，不接受任意 checkout ref。任务仅 `contents: read`，checkout 不保留凭据。仓库管理员应为 `harmonyos-ci` environment 配置受信分支限制与审批；环境名称本身不建立审批规则。人工 SHA 复核也不等于 GitHub 的独立 reviewer 审批。请保护允许的分支和 workflow 写权限。

```bash
sha=$(git rev-parse HEAD)
gh workflow run full.yml --ref ci/github-hosted-hap \
  -f runner=github-hosted -f authorized_sdk=true -f reviewed_sha="$sha"
```

`build-timings-<SHA>-<run>-<attempt>` artifact 保存 SDK 准备、Go 下载、Smart 测试/内核编译、Zashboard、ohpm、GeoIP、Hvigor clean、NAPI/ArkTS/HAP 和验证阶段的秒数/退出码，失败也保留已有计时。NAPI 与 ArkTS 分项时间可从同一 Hvigor 日志读取；上传时间在 Actions steps 中读取。SDK 每次冷下载，GeoIP 每次查询 latest，所谓热缓存仅表示公开依赖与面板资源命中，不意味着复用 SDK。没有成功跑两次前，不给出本项目冷/热耗时承诺。来源调查、方案成本和实测见 [调查证据](../evidence/2026-10-13-github-hosted-hap.md)。

Full 成功完成所有检查后，将该次 CI 构建的未签名 HAP、build-identity.json、module-notices.json、GO-NOTICES.txt（已下载模块的声明全文）、项目 GPL 许可、第三方/Smart notices、Hokit 说明和 SHA256SUMS 保存为 Actions artifact，7 天后过期。暂存前要求报告 commit 与 GITHUB_SHA 相同、signed=false，并核对 HAP 字节摘要与已验证产物一致；不以本地旧包替代 CI 输出。artifact 名包含完整源码 SHA、run ID 和 attempt；没有宣称与其他构建逐字节相同。

下载方式：进入该次 Full run，在 Artifacts 下载 unsigned-test-hap 包并解压，核对 SHA256SUMS，然后用用户本地 Hokit 一键签名安装。HAP 包内包含所需原生库；不单独上传 SDK、工具、签名材料或用户配置。Quick 不生成 HAP。若 Full 排队等待 runner 或 environment 授权，尚无测试包，不能把 Quick 成功当成包已生成。GeoIP 数据源 notices 和分发义务仍需发行负责人核查。若镜像下载、版本、摘要或构建校验失败，Full 明确失败且不上传 HAP；Quick 可独立运行。签名仍遵循 [设备指南](device.md)，不属于 CI。

机制参考：[Go overlay/trimpath](https://pkg.go.dev/cmd/go)、[GitHub Actions runner 与依赖固定](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions)。

## 最新稳定版与定期升级

优先选用最新稳定版。主 CI 使用已验证的版本组合，bot 定期开升级 PR，在合并前验证新版本；不因一次上游发布直接更换 main 的编译器，也不把版本锁永久保留当目标。GeoIP 是逐次更新的数据，单独采用 latest-stable 及每次构建的实际摘要记录。

Dependabot 每周一上海时间 09:00 检查 npm 工具依赖和 Actions。`toolchain-updates.yml` 同时查询 Go 官方稳定版、Node 正式发行版、Adoptium JDK、ErBWs SDK 镜像及 npm pnpm，提出更高的 Go/Node/JDK 版本并同步 workflow 声明；SDK/pnpm 候选写入 PR 供配套兼容验证，镜像落后时不降级。pnpm 涉及供应商 wrapper 与 Zashboard 资源清单，不能由通用 npm bot 单独替换。SDK/Hvigor/ohpm 的配套版本由下载归档验证后一起更新，不能凭 SDK Release tag 猜测。

升级 PR 必须执行 Quick 和经审查 SHA 的人工 Full；自建 bot 显式调度 Quick，Full 不自动调度。升级失败不自动合并，main 继续使用已经验证的组合。没有自动合并配置。Dependabot/定时工作流在本 PR 合并 main 后才开始生效；自建更新 workflow 使用仅本仓库 `contents: write`、`pull-requests: write` 和 `actions: write`（显式调度 Quick，避免内置 Token 创建的 PR 不触发检查） 的内置 GITHUB_TOKEN，仓库还需允许 Actions 创建 PR。未获此设置权限时如实失败，不要求个人 PAT。API 故障也会失败，不伪造“已升级”。
