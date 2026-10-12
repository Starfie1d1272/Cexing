# 构建离线 Zashboard

身份由 [source.json](../../third_party/zashboard/source.json)、原始 package.json 和 pnpm-lock.yaml 固定；本仓库仅维护必要的 [宿主补丁](../../third_party/zashboard/host.patch)。变更源码、锁或补丁后应审查资源清单和许可。保留独立上游 checkout，不复用用户工作目录，不通过 reset 清理修改。

```bash
git clone --depth 1 --branch v3.29.1 https://github.com/Zephyruso/zashboard.git /tmp/zashboard-source
# 使用已安装的 pnpm 11.20.0；其身份见上游 packageManager 字段。
bash scripts/build-zashboard.sh /tmp/zashboard-source
```

首次安装需获取锁定依赖；缓存完整后 `bash scripts/build-zashboard.sh /tmp/zashboard-source --offline` 使用冻结锁离线安装与构建。设置 pnpm store 和 XDG 目录时使用自己的可写缓存目录。脚本拒绝错误 SHA、锁变更、任何暂存改动、上游额外修改和未跟踪源码，不清理它们；比较 HEAD 到工作区的完整差异，只允许固定宿主补丁。仅构建本地字体变体，禁用 service worker 自动注册与内核 restart，使用系统 emoji。

输出到忽略的 `clash-openharmony/entry/src/main/resources/rawfile/zashboard/`。更新 `third_party/zashboard/manifest.json` 和 `ZashboardPin.ets` 后通过 Git diff 审查；未审查的更新不应发行。依赖许可文件、上游纹理 attribution 与字体许可也在清单内。

按 [构建指南](build.md) 准备内核和 geodata，然后：

```bash
source scripts/env.sh
node scripts/test-zashboard-assets.cjs
python3 scripts/test-zashboard-source.py /tmp/zashboard-source
(cd clash-openharmony && hvigorw clean --no-daemon)
bash scripts/build-hap.sh
```

HAP 脚本在构建前验证 rawfile 全集，构建后检查 ZIP CRC、包内全集及逐项摘要。构建不包含运行时联网下载。实际铺盘由宿主调用 [宿主接口](../reference/zashboard-host.md)，不由页面启动 VPN。资源使用固定私有 ui 根和 versions 子目录，原子替换 ui/index.html 切换或回退版本。第一次使用失败时返回无目录的可恢复错误；有已校验版本则回退。文件锁竞争直接返回可重试错误，调用方应保留现有 UI 配置并继续 VPN 流程。

页面和资源模块会编译入 HAP，但没有进入按钮，默认拒绝加载 WebView。安全会话、内存 secret/WS 适配和真机验收完成前不得开放或删除 ProxyPage。上游 PWA 文件保留入包，但不自动注册；历史 service worker 缓存迁移需要真机单独验证。
