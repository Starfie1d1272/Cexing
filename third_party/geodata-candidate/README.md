# GeoIP 候选交接（未接入产品）

这是独立实验材料，不是发行许可结论，不改变产品构建或 `release.py`。输入快照与 `SHA256SUMS` 保存在本目录；服务商列表的再分发条款及 GeoSite 完整来源仍由 Astra 复核。请勿仅凭这里的结果发布或把该文件夹打进 HAP。

## 构建和验证

在干净环境设置 Go 1.27.2、Python 3、`patch`、`tar` 和可写的 Go 缓存，执行：

```sh
bash third_party/geodata-candidate/build.sh /path/to/output
```

脚本核对所有输入摘要，从固定快照生成 V2Ray GeoIP protobuf，解包固定的 `MetaCubeX/geo` 源码，应用 `metadb-epoch.patch`，再编译转换器并生成 `geoip.metadb`。Go 模块按上游 `go.mod` / `go.sum` 获取并校验；来源源码包目前不包含转换器 Go 模块缓存，正式接入需将对应源码按既有 release 打包方式纳入。

原转换器的 `mmdbwriter` 默认使用当前时间作为数据库时间戳；相同输入的两次 `.metadb` 摘要不同。补丁将时间戳固定为 Tor 快照时间 `2026-10-29T19:11:33Z`。实测两次 `.dat` 摘要均为 `02ec4566b23662b3508b481c4a35136fa9d2b56436775dd87a0c11860f89b001`，补丁后两次 `.metadb` 均为 `378a5083bde959a7c487f2c8f2dcd439bad5a48a23142f1f1d4e194d511f67c5`。这是所测工具链和快照的结果，尚不是跨平台逐字节可复现保证。

`IP-DIFF.jsonl` 是每个分类逐 IPv4/IPv6 的地址集合增减数量，由 `compare.py` 计算。参照输入为 [Loyalsoldier release 提交 3382413 的 geoip.dat](https://github.com/Loyalsoldier/geoip/blob/33824131927ddbc19c540f2a301cc4ef4e123478/geoip.dat)，SHA-256 `fbf747a085be25eb61ecac8c27140b4ab0bf8181af6fdb104caa325bd93cf117`；该输入包含 GeoLite，未将参考文件加入此交接包。它不一定是 MetaCubeX 当前 `.metadb` 的确切输入，因此此比较不能替代对最终资产和真实订阅的检查。两份比较输入均无 reverse-match 分类；候选没有增删分类，`PRIVATE`、`TELEGRAM` 和 `CLOUDFRONT` 地址集合相同，其余包括国家、Cloudflare、Google、Tor 存在变化。IPv6 数量是地址个数而非前缀个数，不宜与 IPv4 数量直接比较。

代表查询：使用固定转换器读取候选 `.metadb`，`1.1.1.1` 命中 AU/CLOUDFLARE、`8.8.8.8` 命中 US/GOOGLE、`149.154.167.51` 命中 GB/TELEGRAM、`10.0.0.1` 命中 PRIVATE；未验证真实配置、DNS 或策略出口。

## 输入及变换

所有输入的实际文件摘要见 `SHA256SUMS`，均为 2026-10-29 获取的快照：

- `dbip-country.csv.gz` 和 `dbip-asn.csv.gz`：DB-IP 2026-10 Country Lite / ASN Lite，官方 [Country](https://db-ip.com/db/download/ip-to-country-lite)、[ASN](https://db-ip.com/db/download/ip-to-asn-lite)，CC BY 4.0，须署名。国家地址范围分解为 CIDR；CN 被运营商列表替换；ASN 按配置中各服务的 ASN 集合选择。DB-IP Lite 与 GeoLite 覆盖和精度不同。
- `cn4.txt.gz`、`cn6.txt.gz`：gaoyifan/china-operator-ip 的 `ip-lists` 提交 `af96830e7e2c992a00889745c58e3bef9ebc8587`，该分支附带的 MIT 文本为 `gaoyifan-LICENSE`。上游描述来源含 BGP 与 RIR；本候选保留其 CN 分类方法，具体数据条件仍需核实。
- `tor.txt.gz`：[Tor Metrics exit list](https://collector.torproject.org/recent/exit-lists/2026-10-29-19-11-33)，取 `ExitAddress`；[Tor Metrics 数据声明](https://metrics.torproject.org/development.html)为 CC0。时间及数据源与上游 `torbulkexitlist` 不完全相同。
- `cf4.txt.gz`、`cf6.txt.gz`：`https://www.cloudflare.com/ips-v4`、`https://www.cloudflare.com/ips-v6`；`telegram.txt.gz`：`https://core.telegram.org/resources/cidr.txt`；`google.txt.gz`、`googlecloud.txt.gz`：`https://www.gstatic.com/ipranges/goog.json`、`https://www.gstatic.com/ipranges/cloud.json`；`fastly.txt.gz`：`https://api.fastly.com/public-ip-list`；`aws.txt.gz`：`https://ip-ranges.amazonaws.com/ip-ranges.json`。只取上游原有配置规定的地址字段和 CloudFront 服务；各地址源的再分发适用条件尚待核对。
- `loyalsoldier-config.json`：固定的 [Loyalsoldier/geoip 配置](https://github.com/Loyalsoldier/geoip/blob/084eb113e458b82374919dabefbc49cd2c2dd079/config.json)，用于确定 ASN 和服务字段。`PRIVATE` 前缀依据同一提交的 `plugin/special/private.go`；项目仓库声明 CC BY-SA 4.0，具体适用范围仍需核对。
- `metacubex-geo.tar.gz`：`MetaCubeX/geo` 提交 `a4db326ccfd7e21276d5d05f4f7e512d14415553`，上游 GPL-3.0；补丁只固定生成时间戳。

尚未做候选 HAP 构建、合成配置和真实脱敏订阅出口检查，也未确认上面全部输入的再分发条件。切换默认 GeoIP 前须完成这些检查及对应源码包，并依据 Astra 的最小分发准则处理现有阻断。
