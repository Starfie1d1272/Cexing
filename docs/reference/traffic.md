# 原生流量账本

## 口径与上游依据

上传、下载是当前内核跟踪的数据字节，合计为两者之和；不是系统网卡总量、运营商计费量或订阅套餐余额。日/月账本不采集应用、域名、连接明细，不同步到云端；应用本次汇总见下文。

固定内核 [Mihomo statistic manager](https://github.com/vernesong/mihomo/blob/daf3ad03021cca6031f4a7303ca6d861a14d5a16/tunnel/statistic/manager.go) 的 `Total()` / `Snapshot()` 为进程累计，`Now()` 为一秒速率；连接关闭不会扣除累计。当前固定模块图没有 `ResetStatistic()` 调用，但客户端仍防御计数回退。参考 [v2rayN StatisticsManager](https://github.com/2dust/v2rayN/blob/master/v2rayN/ServiceLib/Manager/StatisticsManager.cs) 将日累计、总累计与存储分离的思路，本实现另加会话检查点和缺失区间处理；不把 Web 面板短时曲线当作跨重启账本。首页、详情的实时速率沿用 `/traffic`；账本只用 `/connections` 的 `uploadTotal/downloadTotal`，不积分速率。

“本次”是扩展核实的 VPN 会话；断开后保留最后一次值，新会话首样本建立基线；确认会话身份变化后、累计读取成功前，本次显示未知，日/月历史保持原值，未知本次状态单独持久化，首样本失败后断开或进程恢复也不回显旧会话。Go runtime 可在重连时继续存在，因此首样本总量不能全算成本次。首次启用之前不恢复历史；今日/本月只含启用后有证据的增量。单位沿用内核页面的 1024 进位 B/KB/MB/GB/TB。

## 采集与恢复

`AppRuntime` 既有五秒健康检查在核实会话后触发一个 single-flight 累计采样，连接成功时立即触发首样本。页面不拥有采集器；Ability 销毁不释放 VPN/采集。`LiveViewKeeper` 复用最近采样差分速率，删除原六十秒 REST 轮询。未取得长时任务、系统取消/挂起后台执行或用户关闭保活时，不能保证五秒调度；同一会话下后续累计样本仍能追回总差额，但不保证每日的完整分配。

会话身份由 VPN Extension IPC 核实，采样开始和完成都核对身份；断开使在途回调失效。热重载不改变会话身份，正常累加；内核进程退出后新扩展会话建立新基线。同会话恢复接续持久检查点，不靠“新值大于旧值”猜测进程连续性。若计数回退，两个方向都重新基线，保留已记字节并标缺失，不把回退后的计数加作历史。

初始基线之前和断开前未采到的尾段不具备精确分配证据，本次与相应日/月标“部分记录”。暂时请求失败本身不会丢弃基线；同身份再次采到累计值能恢复中间增量。首次启用的日/月有启用前缺失，始终标部分。

## 日/月与时间变化

按设备本地日历键分桶。同日同月且时间前进、时区偏移不变的差额正常计入。样本跨午夜时，差额能计入本次；如果仍在同月，也能计入本月，但不能确定它属于哪一天，故不分摊到日桶，并标两端日桶缺失。跨月相同处理。时钟回退或时区偏移变化时，差额只进入本次，日/月不造数，两端标缺失。前跳未跨日/月时整段仍属于同一桶。

曲线只保留内存中最近五分钟、至多六十个采样点，显示实际观测间隔的平均速率，与实时 `/traffic` 数值可能不同；超过十五秒的区间断线，进程恢复不补曲线。

## 持久化与故障边界

应用私有 Preferences 独立存储一个版本化 JSON，同时保存累计和原始检查点。保留最近访问的三十五个日桶和十四个月桶；数据最大三十二 KB，不包含连接元数据。单 writer 与一个可替换 pending 快照，慢盘不会积压无限任务。异步 `flush` 不被 VPN 启停等待；存储失败只提示“记录未保存”，不阻止连接。

进程异常退出可能发生在最近检查点落盘前；同一核实会话可用下次累计差额补回，若内核一同退出则无法恢复尾段，保留已保存值并标部分。初始化读存储失败可在前台/上下文重绑重试，读取成功前不采样以免覆盖旧历史；结构损坏（包括缺少检查点对应日/月桶）或不支持版本时保留原文件，当前进程只显示未保存的新记录，不覆盖原历史。不得把部分记录称为全天准确统计。支持文件中的固定源码/产物身份仍按构建、主机模拟和真机证据分别记录。

## 界面约束

首页不增加卡片，通过现有速率区的箭头打开流量页，未连接时同一区域也能打开已保存统计。详情只显示上传/下载实时速率、短曲线、本次/今日/本月上传下载及合计；实际缺失标“部分记录”，写失败标“记录未保存”。口径说明仅在工程文档，不在页面放常驻解释或套餐暗示。

## 应用本次汇总

应用计量独立于上述日/月账本，范围仅为本机系统 TUN 进入内核、已建立 statistic tracker 的客户端字节。排除 VPN 的应用不可观测；DNS 劫持、建连失败等没有 tracker 的路径不造数，节点封装与机场账单也不在此口径。旧 `/connections` 和日/月采样不变，应用明细不追溯补分历史。

固定内核补丁覆盖 TCP 普通/buffer/unwrap 读写、UDP 读写及创建时的初始 `peekLen`。只给 `pushToManager` 路径创建观察句柄，避免嵌套 tracker 重复；通过现有 TUN metadata addition 携带不序列化的会话上下文，旧 TUN 的迟到 tracker 也不进入新会话；句柄属于原 TUN 会话，Close 幂等且只减少活跃连接数，关闭后的并发迟到增量仍记同一行，不再累计终值。TUN UDP 的 NAT key 复用既有 `handlerId + source` 自定义地址，使快速重连后相同源端口不会复用旧 listener 的出站 tracker；原始地址元数据独立保留。出站首个实际 adapter 类型区分代理、内核 DIRECT 与未分类，不依赖策略名。应用身份未知与路由未分类互不替代。

Tracker 创建时复制 `RawSrcAddr/RawDstAddr` 的原始地址和非零端口，不能使用 Fake-IP 还原后的目的地址。Go 请求队列至多 256 条、8 秒过期，通过同一认证 Controller 的单个 `/ohos/app-traffic/identity` WS 每批至多 32 条发送。VPN Extension 生命周期持有消费者，API 23+ 仅调用 `connection.getConnectOwnerUid`；API 22 记 unsupported。UID 不等于已验证的应用身份，共享 UID 也可能存在。三方跨 UID 包名/资源查询需要系统级权限，当前没有已验证的普通消费者 VPN 公开替代路线，故不调用包名/图标 API、不声明系统权限，也不猜测应用。官方 UDP 查询可能在远端无匹配时按本地地址匹配，不能解释为严格四元组证据；无 UID 时不自行猜测。平台至多 128 个在途查询，3 秒超时，超时后的底层 Promise 仍占槽直到实际完成，停止/重启也不会绕过上限。

身份批量 POST 带会话 ID 与请求 ID。未知先计数，成功回复在同一聚合锁内移动已累计字节、连接数和活跃数，随后增量直接归已识别行；重复、超时或旧会话回复不再移动。失败原因只保留有界类别计数。最多 128 个已知 UID，超限继续计入未知，转发不等待平台查询。

`GET /ohos/app-traffic` 与 `CoreApi.getAppTraffic()` 返回 schemaVersion 1：`session/state/startedAt/endedAt/partial/totals/apps/identityFailures`；时间是 Unix 毫秒。每行含 `identityStatus/uid/bundleName/bundleVerified/routes/recent`，routes 的 `proxy/direct/unclassified` 分别含 `upload/download/connections/active`。未知行 `identityStatus=unknown、uid=-1`，官方查询成功行仅为 `identityStatus=uid`。所有行 `bundleName` 为空、`bundleVerified=false`，不得据 UID 展示已识别应用或执行快捷排除。每行内存保留最近四条规则类型及至多八段策略链，不含规则 payload、域名或原始地址，全部仅驻内存。真实名称/图标与快捷排除闭环受平台权限阻塞，未完成，不提供模拟正式路径。

应用汇总只保留当前内核会话的内存计数与有界 recent，不单独写盘、不恢复历史。正常停止写内存状态 `closed`，仍有活跃 tracker 时标 partial；Controller 不可达时 `getAppTraffic()` 返回 null，新会话重新开始。现有日/月总量账本的采样与持久化不变。
