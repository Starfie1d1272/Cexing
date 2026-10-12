# 上游并发重载只读核查（2026-10-12）

保留安全线 `51fcf6c4139f1c883d9a9491494eda1b917d2aec` 的已修代码。本轮只读检查模块/官方 Git 仓库、提交和 PR；仅更新研究报告及未应用提案，未改运行源码、go.mod/go.sum、模块缓存或依赖来源，未合并。此前双栈真实代理请求与认证 PUT 的 race 由独审报告，本轮确认相应代码链，不声称重新执行其完整双栈复现。

## 当前上游身份与是否已有成熟修复

官方 tag [v1.19.32](https://github.com/MetaCubeX/mihomo/tree/88dcbf7f1614a67c3b36b848ee3592dfa92ada36) 的 SHA 为 `88dcbf7f1614a67c3b36b848ee3592dfa92ada36`（2026-09-30），也是查询时 Meta head；最新列出的发布 tag 仍为该版本。Alpha 固定核查至 [`bc76c1398c6e70089367a30169d0df7c7f77c42d`](https://github.com/MetaCubeX/mihomo/tree/bc76c1398c6e70089367a30169d0df7c7f77c42d)。main 是另一分支，不用它的名称推断内核最新实现。

Alpha 比 tag 领先五个提交：

| SHA | 实际范围 | 对本问题的结论 |
|---|---|---|
| [9f053c49](https://github.com/MetaCubeX/mihomo/commit/9f053c49075de076d83d3e5918241e410f7e9adf) | WireGuard 设备/stack 延迟初始化 | 未修改 resolver/hosts/global policy |
| [1354e52e](https://github.com/MetaCubeX/mihomo/commit/1354e52e6f72b94c1e684788f1a9c3e0a731e544) | loadbalance 测试 | 不是此修复 |
| [80101933](https://github.com/MetaCubeX/mihomo/commit/80101933c007185c7a72efb3a377482b2bb70246) / [PR #3274](https://github.com/MetaCubeX/mihomo/pull/3274) | dns/doh.go 的已放弃查询 dial 取消 | 解决另一资源问题，不同步运行态 global |
| [e4dd968d](https://github.com/MetaCubeX/mihomo/commit/e4dd968de9e10ecc6770acfafd306edeb578eb52) / [PR #3283](https://github.com/MetaCubeX/mihomo/pull/3283) | fake-ip pool Clone 保留已分配状态及测试 | 是重载兼容点，不解决已报全局访问 |
| [bc76c139](https://github.com/MetaCubeX/mihomo/commit/bc76c1398c6e70089367a30169d0df7c7f77c42d) | mieru 依赖更新 | 不是此修复，直接升级还会改变模块图 |

以下八个文件在 tag 与固定 Alpha head 的 Git blob 完全相同：

| 文件 | 相同 blob |
|---|---|
| component/resolver/resolver.go | e87a910357c938b2cfb36ebaa7254038587a6087 |
| component/resolver/host.go | 51445d2c734a89823bc40a681696e003d5ac9b90 |
| component/dialer/dialer.go | 6a05c8bc1e5f6af0a185698a6233be1a9d310e52 |
| adapter/outbound/direct.go | 1e2b2ef70c8e9c70903fa9eb11ddfa58303e4844 |
| hub/executor/executor.go | 796face2f1b9eb498035ce8d2cf72e62ea5a0b0c |
| adapter/inbound/ipfilter.go | 872d0c85a1cb31b11730f2a673b6636d4ca6cf48 |
| adapter/inbound/auth.go | 8317274687f0c334c5b90494ef5bee2114a1f530 |
| listener/auth/auth.go | 9e7632e86863ac84205a14c3f54d118406763e7e |

历史 [fd5b537a](https://github.com/MetaCubeX/mihomo/commit/fd5b537ab1991ba16cf0f6e69e55c0b73d99d9a2) 的 DoH concurrent race 修复仅改 dns/doh.go；[7ed25ddc](https://github.com/MetaCubeX/mihomo/commit/7ed25ddc7494086e00760ef516f658c1b6a4e36d) 的 atomic 使用调整也不涉及这些全局发布点。两者均已是 v1.19.32 祖先。[PR #2556](https://github.com/MetaCubeX/mihomo/pull/2556) 已合并，但针对 dialer tcpConcurrent，不能当作 DNS/hosts 完整修复。官方可见 PR 搜索未找到覆盖本组状态的成熟提交；检索有限，不宣称全网不存在方案。

**结论：本次可确认的更新不能作为成熟并发重载修复，不能仅换成 Alpha 来声称解决。**

## 更广的真实访问边界

[固定 resolver 全局定义与 Lookup](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/component/resolver/resolver.go) 中 DefaultResolver、DirectHostResolver、ProxyServerHostResolver 为普通接口变量，DefaultHosts 为带 trie 指针的结构体，DisableIPv6 为普通 bool。双字接口/结构体发布也不是原子快照。

| 写路径（实际固定源码） | 并发读路径 | 影响 |
|---|---|---|
| executor.updateDNS :240–298，DNS disabled 时也清空对象 | Direct.DialContext/ResolveUDP、outbound.resolveUDPAddr、dialer.resolveAddr 与其他 outbound | direct/proxy/default resolver 的接口引用、比较和回退可能处于变化状态 |
| executor.updateHosts :307 发布 Hosts | resolver Lookup 与 Hosts.Search 对 DomainTrie/alias 的多次读取 | 结构体/指针发布缺少同步；一条 alias 查询还可能跨版本读取 |
| executor.updateGeneral :396 写 DisableIPv6 | resolver.LookupIPv6/LookupIPWithResolver 等 | IPv6 选择与解析行为并发变化 |
| executor.updateDNS :287 写 UseSystemHosts | Hosts.Search 读 UseSystemHosts | 同属配置运行态，不能因本次未报该项就遗漏 |

静态同名引用盘点涉及 27 个非测试 Go 文件；这是审计候选清单，不等于已经确认每个文件都要改。除了四个已报变量，还应审视 DefaultResolver/DefaultHostMapper/DefaultService/UseSystemHosts 与网络 reset 的对象生命周期，否则局部锁不会形成一致边界。

额外入口：[ParseRawConfig](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/config/config.go) :638 调用 temporaryUpdateGeneral，并 defer rollback；该函数在 executor.go:385–390 调用 updateGeneral，连校验/解析阶段也会临时写 live DisableIPv6 等设置。只锁 PUT 的 ApplyConfig 写侧、甚至只修改最终提交，都会漏掉解析期间的写入。[上游 PATCH /configs](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/hub/route/configs.go) 也有直接 bool 写，维护版须处理；宿主当前有限 PATCH 不开放该字段。

## 最小可维护方案与兼容影响

推荐在**固定 tag SHA 的独立依赖维护分支**集中解决发布/读侧，审阅补丁与摘要后再以独立接入 PR 验证；不把锁散布在 wrapper 写侧，不修改共享缓存。当前代码保持不动，先定义来源管理方式。

1. 入站前缀同步只是子集。setter/getter/匹配 reader 必须共享保护；复制使用 slices.Clone 保留 nil 与非 nil 空切片。当前未应用提案已修正这一点，但标记为 PARTIAL，不能作为完整 hot reload 修复。这里只提供独立 setter 的线程安全，不擅自改变匹配语义。
2. 为 resolver/hosts/IPv6 等配置关联状态建立不可变 generation 快照，构造完成后原子发布；读侧统一通过 accessor/session 获取，禁止保留未同步公开全局旁路。逻辑解析/Direct resolver 比较应读取同一版本；不得在持锁期间执行 DNS/网络 I/O。旧快照保留到在途请求结束，并明确 reset/退休资源语义。这里是设计提案，尚未实现或验证。
3. Hosts trie 在发布前完全构造并冻结，alias 查询持有一个 snapshot；继续允许主机 IP 列表/域名 alias 与 use-system-hosts 的既有语义。不要只给 trie 查询加锁而保留 DefaultHosts 的无保护替换。
4. 解析器的 temporaryUpdateGeneral 需要隔离候选 context 或取消其修改 live 运行态的做法；原 geodata/rule-provider 加载依赖必须显式传入。不能仅改 bool 为 atomic 就声称候选解析不会暂时影响业务策略。
5. 维护版需清点所有 accessor 调用点与其他写入口，既有 wrapper AuthStore/日志资源/Controller 绑定保留。内部 Go API 会变化；四 C ABI、ProfileStore/YAML/schema 不应改变。具体文件数须在实现审计后确定，不能承诺两文件解决。

兼容验收必须保留：DNS enabled/disabled 下各 resolver 的 nil 回退与身份比较、direct-nameserver-follow-policy、IPv4/IPv6 选择、hosts alias/system-hosts、fake-ip 既有映射、在途 DNS 请求/连接 reset、同端口重载和失败回退。Alpha 的 fake-ip Clone 修复是需要审查的兼容案例，不代表应该无条件跟进其全部依赖。

临时产品门槛可以是禁止尚未并发验证的热应用，但这涉及配置事务/面板行为，需父任务决定，不能暗自改成 native 重启。coreStop 只移除 listener 及受控日志，不证明所有旧代理/DNS handler 退出；stop→start 本身不是本组全局 race 的解决。进程级重建与 Go runtime 卸载不是同一件事，不采用 dlclose 或不受支持的 /restart。

## 本轮实际检查与未做事项

- 官方 tags/Meta/Alpha、逐提交范围、八文件 blob 比对、相关历史提交与 PR状态核查完成，未发现覆盖该组字段的成熟修复。
- 标准库合成验证确认 slices.Clone 保留 nil/非 nil 空 prefix slice；未应用 partial patch 的 --check/--unidiff-zero 与 git diff --check 通过。这不证明补丁已编译或解决所有 race。
- 没有改依赖/缓存/运行态，没有新增热重载锁，没有重复构建同一未改源码，也没有真实设备操作。已修项仍保留；之前完整 race 未通过的结论仍成立，且两文件提案范围不足。
