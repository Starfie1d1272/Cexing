# 构建离线 Zashboard

身份由 [source.json](../../third_party/zashboard/source.json)、原始 package.json 和 pnpm-lock.yaml 固定；本仓库仅维护必要的 [宿主补丁](../../third_party/zashboard/host.patch)。变更源码、锁或补丁后应审查资源清单和许可。保留独立上游 checkout，不复用用户工作目录，不通过 reset 清理修改。

```bash
git clone --depth 1 --branch v3.29.1 https://github.com/Zephyruso/zashboard.git /tmp/zashboard-source
# 使用已安装的 pnpm 11.20.0；其身份见上游 packageManager 字段。
bash scripts/build-zashboard.sh /tmp/zashboard-source
```

首次安装需获取锁定依赖；缓存完整后 `bash scripts/build-zashboard.sh /tmp/zashboard-source --offline` 使用冻结锁离线安装与构建。设置 pnpm store 和 XDG 目录时使用自己的可写缓存目录。脚本拒绝错误 SHA、锁变更、任何暂存改动、上游额外修改和未跟踪源码，不清理它们；比较 HEAD 到工作区的完整差异，只允许固定宿主补丁。仅构建本地字体变体，禁用 service worker 自动注册与内核 restart，使用系统 emoji。

输出到忽略的 `cexing/entry/src/main/resources/rawfile/zashboard/`。更新 `third_party/zashboard/manifest.json` 和 `ZashboardPin.ets` 后通过 Git diff 审查；未审查的更新不应发行。依赖许可文件、上游纹理 attribution 与字体许可也在清单内。

`third_party/zashboard/dependency-notices.json` 是按 pnpm 锁文件审查的许可证正文语料，范围是**全部锁定包**，包括仅在 macOS、Linux 或其他平台安装的可选构建二进制；每条保留来源、平台约束及正文 SHA-256。打包时先核对语料与锁文件身份、完整包集合、非空正文和摘要，再复制到资源。这样 Linux 与 macOS 使用同一资源字节；若锁更新或有许可正文缺失，构建失败。补充来源时须从相同版本的 npm tarball、其父包许可或对应版本源码/明确 SPDX 声明核对，不能从当前机器安装结果推导完整清单。

少数精确 npm tarball 只声明 SPDX 许可标识而未带版权声明。清单保留标准 SPDX 全文、声明来源及上游未提供完整版权行的说明，不推定作者就是版权人；这不替代发行前的版权归属与对应源码义务审查。实际 macOS/Linux 资源身份由 `Zashboard portability` 工作流在两种 runner 上重新构建并比对锁定 manifest。

按 [构建指南](build.md) 准备内核和 geodata，然后：

```bash
source scripts/env.sh
node scripts/test-zashboard-assets.cjs
python3 scripts/test-zashboard-source.py /tmp/zashboard-source
bash scripts/build-hap.sh
```

HAP 脚本在构建前检查 rawfile 缓存；缓存缺失或过期时，从当前声明的源码重新构建资源。首次准备或刷新缓存需要网络和 `scripts/ci` 中的构建依赖，可先执行 `npm ci --prefix scripts/ci --ignore-scripts --no-audit --no-fund`。有效缓存直接复用；刷新在 staging 完成内容、许可证和 reviewed manifest/Pin 校验后提交，失败保留原缓存与身份文件。资源准备完成后由 HAP 入口统一执行一次 Hvigor clean，再打包。构建后检查 ZIP CRC、包内全集及逐项摘要。构建不包含运行时联网下载。实际铺盘由宿主调用 [宿主接口](../reference/zashboard-host.md)，不由页面启动 VPN。资源使用固定私有 ui 根和 versions 子目录，原子替换 ui/index.html 切换或回退版本。第一次使用失败时返回无目录的可恢复错误；有已校验版本则回退。文件锁竞争直接返回可重试错误，调用方应保留现有 UI 配置并继续 VPN 流程。

连接页已有 Zashboard 入口，会话检查通过后才创建 WebView；断开、无认证或缺少当前固定资源时显示可恢复提示。内存凭据和 WS 适配的行为见宿主接口，ProxyPage 文件保留到 ArkWeb 真机验收完成。上游 PWA 文件保留入包，但不自动注册；历史 service worker 缓存迁移需要真机单独验证。


可选真实浏览器联调（需已激活官方 SDK/Go、Python Playwright 与 Chromium，先构建资源）：

```bash
python3 scripts/test-zashboard-browser.py
```

用独立临时沙箱启动真实 Go Controller 与构建后的前端，不创建系统 TUN、代理监听或 DNS 服务。使用临时测试凭据、合成 DIRECT/REJECT 策略组；原生 bootstrap 由实际 SDK 转译代码生成。结果只打印脱敏断言，不能保存带 token 的浏览器网络追踪。此测试证明 Chromium 行为，ArkWeb 导航、文档开始注入、控制台拦截、旧缓存及手机系统生命周期另按设备指南验收。
