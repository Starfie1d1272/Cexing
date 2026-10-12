# Zashboard 资源与隔离页面验证

日期：2026-10-12。应用基线 `7f731d5c9c8d4eba7a1680bcb3981d7877232bcc`，源码为该基线加本 PR 的 `feat/zashboard-integration` 变更；最终提交身份由 PR head 核对。未改 CoreApi、engine、VPN 生命周期、应用名、包名或仓库名。

## 来源与构建身份

- 官方 [稳定 release](https://github.com/Zephyruso/zashboard/releases/tag/v3.29.1)：v3.29.1，2026-09-23 发布；查询时 `draft=false`、`prerelease=false`。固定源码 `50717b02dac68425cdc5b80cb754bea768ee4fc9`，MIT。
- 原始 pnpm lock SHA-256：`a3b76781a7f2ccf3a21ff979c80036945a673372fd47a3a3317ffab497d0820d`；pnpm 11.20.0 冻结安装，未升级依赖。
- 宿主补丁 SHA-256：`3b327792393402b49b0f9377a34c197f8a1228d20f2556b6ec1bf9d0bb7ffb93`。关闭 restart 前端动作及调用、service worker 自动注册；去掉许可未完整核实的旗帜字体，使用系统 emoji。仅打包本地 Fira Sans（OFL 1.1），保留地球贴图 CC BY 4.0 attribution 和依赖 notices。
- 参考 KaringX/clashmi 源码 `daef7be6c40d49a98a174a82c10599e163e71afd` 的 `lib/app/modules/zashboard.dart`：其额外 HTTP server 和 URL secret 不适用本项目，未复制实现。
- Linux x86_64；Node 26.11.1、Huawei Command Line Tools 26.0.0.851/API 26、JDK 27，沿用环境已有同基线 `libmihomo.so`。本线未重建或替换 Go 内核。

## 实际操作与结果

1. 从固定 tag 克隆，核对 HEAD；冻结锁安装。执行 `FONT=firasans pnpm run build`，随后通过本仓库脚本 `--offline` 构建。再进行一次离线构建，清单字节与已审查清单完全一致。
2. 生成 46 个离线资源（5,825,287 字节），含 index、JS/CSS、14 个本地 Fira Sans woff/woff2、图标、PWA 文件、上游 LICENSE、FiraSans-LICENSE、纹理 attribution、依赖 notices。无 registerSW 自动注册文件，无 CSS/HTML 字体 CDN 引用。
3. 清单 SHA-256：`e9384731f93a6fc6c4a43b94565ac11ab33d130438004f69c53405e1ea63c07f`；资源版本（规范文件清单的 SHA-256）：`64073e6939bfc5d490a613566e9da5a83dec228f832f0fd40fa4131c855e2538`。
4. 使用真实 SDK transpiler 执行资源模块/导航策略回归，文件操作落在临时本地目录，rawfile 和 crypto API 为 mock。覆盖冻结资源安装、串行复用、选择记录损坏修复、合成锁竞争、原子选择写入失败保持原版本、显式回退、坏资源回退、穿越/symlink/多余文件拒绝、回环 origin/端口及导航与生命周期端点限制。未运行真实设备文件锁/资源 API。
5. 项目四个既有回归脚本全部通过：profile-name、VPN startup、AppRuntime、background lifecycle。新页面默认无会话，没有用户进入按钮，ProxyPage 保留。
6. 执行 `hvigorw clean --no-daemon` 后构建未签名 HAP 成功；最后一次 33 tasks，32 executed、1 up-to-date。核实 SDK 编译缓存和 protoBin 包含 ZashboardPage、ZashboardPolicy、ZashboardAssets、ZashboardPin，避免仅资源入包而未编译新增源码的误判。
7. HAP ZIP CRC 检查成功，包内 Zashboard 文件全集与清单一致，46 项 SHA-256 均一致。HAP SHA-256：`abc93eeaa5e64d2d3e8a939a3c66f3948f60accf4b90635361fe8a48d720fe97`；未签名 HAP 保留在本地忽略的默认构建输出，不提交。

包内已有必需资源与库也存在。三个 `.so` 的 ELF machine 均为 183（AArch64）：

| 文件 | SHA-256 |
|---|---|
| libmihomo.so | `1378453d2cb9db1b87b1dc29b9b1c95f5e9dfeffc37a6b193c35672fade09a1f` |
| libentry.so | `72846b45abc1c910d65453fd030f2ab31167e740cf4cbd9de913217a57bf3cfe` |
| libc++_shared.so | `965803c3fe53e02452e4c0479ad13c88f166c04207d27e3c531161a7c75a6c17` |
| override.yaml | `baf412f57eef8ef5ff3923286041976ec9334e7badf6b753f8726201666fcb76` |
| geodata/geoip.metadb | `b8f447617c3f6d8ef0f7528c23dfba695bca16a31a396bc4c1fca49e9f038ae3` |

## 未验证与合流边界

安全线/配置线最小接口见 [宿主契约](../reference/zashboard-host.md)。目前尚未接通 Controller external-ui 配置、内存 secret 注入或 REST/WS 会话；未进行无凭据拒绝/正确凭据成功测试。请求回调是否覆盖 WS 不作保证，需要安全线的精确 origin CSP/网络约束。

本次仅核对上游 Smart 调用源码：`GET /group/weights`（message、weights，Name/Rank/Weight）及无请求体 `POST /cache/smart/flush`。未换核，未声称基线支持 Smart 或已进行预测。

无真机、签名、VPN 流量、进程终止/断电事务持久性、旧 service worker 缓存迁移、页面重开 REST/WS 或字体渲染验证。编译有平台 crypto syscap、可能抛异常、原项目弃用 API 及 API 26/21 兼容警告；资源 API 失败返回可恢复结果，VPN 行为保持既有实现。后续接入不得把这份构建/mock 证据替代真机验收。
