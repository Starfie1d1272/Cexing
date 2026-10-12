# AGENTS.md — AI Agent 入口

> 你是被用户拉来帮忙安装/构建/二次开发本项目的 AI Agent。本文件是你的行动纲领。
> **若用户让你"帮忙装上/跑起来"：直接以 [INSTALL.md](INSTALL.md) 为执行手册，从第 0 步开始逐步推进。**

## 项目一句话

mihomo（Clash.Meta）内核的鸿蒙原生 VPN 客户端：ArkTS UI（`clash-openharmony/`）+ Go 交叉编译的 libmihomo.so（`core/`，NAPI 桥），纯命令行构建签名安装（`scripts/`），侧载到零售真机运行。

## 当前 P0 验收范围（2026-10-12）

- 标准 mihomo v1.19.32、包名 `com.starfie1d.mihomo`；构建、AGC 调试签名、真机安装、订阅导入/更新、IPv4 浏览器 TUN 代理转发与正常停止/重连已通过。证据见 `docs/research/compatibility.md`。
- Smart 仅隔离试编译通过，模型加载和真实预测待验收；Zashboard 尚未集成。IPv6、UDP/DNS 专项、WS、长时间后台保活、网络切换与异常恢复均待验收。
- 首次连接需要校验过的 GeoIP 快照：构建前执行 `bash scripts/prepare-geodata.sh`。资源变更后按下方规则 clean。
- 回归命令：在 Bash 中 `source scripts/env.sh`，再执行 `node scripts/test-profile-name.cjs` 和 `node scripts/test-vpn-startup.cjs`。
- `/version` 当前仍为上游默认值，真实内核身份以 Go 模块元数据和库摘要确认；版本注入问题见 `docs/research/issues.md`。

## 行为准则（硬性）

1. **人机分工**：🧑 标记的步骤（注册账号、网页下载、AGC 操作、真机授权）**停下并引导用户**，不要假装完成，不要尝试自动化网页登录。🤖 步骤直接执行并跑验证命令。
2. **永不入库**：`.signing/`（任何层级）、`tomvps.yaml`、`*.hap`、`command-line-tools/`、`entry/libs/`、构建产物。提交前 `git status` 自查；发现用户私密节点配置绝不要 `git add`。
3. **不要改 `scripts/*.sh` 的检查逻辑来"绕过"报错**——每个检查对应真实平台约束；报错先查 `clash-openharmony/BUILD.md`（完整坑位清单）。
4. 所有命令默认在**仓库根目录**执行；构建前先 `source scripts/env.sh`（路径自动推导，工具链在别处时提示用户设 `HARMONYOS_CLT_ROOT`）。
5. 改动 `core/` 或 `clash-openharmony/entry/src/main/resources/` 后，构建 HAP 前必须 clean：`cd clash-openharmony && hvigorw clean --no-daemon`（hvigor 缓存不打旧产物，这是坑位①）。

## 仓库速查

| 位置 | 内容 |
|------|------|
| `INSTALL.md` | 安装主线（**事实来源**），含人机分工与验证命令 |
| `scripts/env.sh / build-core.sh / prepare-geodata.sh / build-hap.sh / sign-agc.sh / install.sh / logs.sh` | 流水线，按序执行 |
| `core/` | Go module：mihomo → c-shared 动态库；`platform_ohos.go` 是 ohos build tag 平台层 |
| `clash-openharmony/BUILD.md` | 构建复原指南 + **移植坑位清单（第 4 节）**，遇错先查 |
| `clash-openharmony/DESIGN.md` | UI/交互设计；`LIVEVIEW_DESIGN.md` 实况窗、`QUICK_ACCESS_DESIGN.md` 快捷入口 |
| `core/third_party/android_stub/` | 首次 build-core 自动生成，勿手动提交 |

## 常用验证命令

```bash
source scripts/env.sh
hdc list targets                      # 设备在线？
ls entry 2>/dev/null; ls clash-openharmony/entry/libs/arm64-v8a/  # 内核产物
bash scripts/logs.sh                  # 设备日志（ClashOH 过滤）
```

## 二次开发提示

- 本 Fork 的产品目标、证据与验收任务从 `docs/research/overview.md` 开始；安装事实来源仍为 `INSTALL.md`。
- 用户偏好：在稳定条件下优先测试最新版本。保留可用的新工具链；出现可复现的不兼容才做项目级版本调整并记录错误。开发分支须固定 SHA，注明其稳定性证据。
- 原始基线、Smart 试编译、签名安装、真实转发分别记录；构建通过不能替代真机验收。
- 保留本项目四个 C ABI、NAPI worker 与 VPN 扩展边界；模型和 Web 资源接入前先检查来源、许可、完整性与失败处理。

- 内核调试日志走 hilog（domain 0x3200，tag 见 core/hilog.go）。
- 前端四 Tab 接的是内核 REST/WS 控制面（默认 127.0.0.1:9090，见 `lib/CoreApi.ets`）。
- bundleName 变更要三处同步（AppScope/app.json5、scripts/install.sh、AGC 应用），见 INSTALL.md 4.2。
