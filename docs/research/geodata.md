# 首次连接 GeoIP 数据

日期：2026-10-12。本轮 v1.19.32 真机启动需要 GeoIP 数据，内核默认联网下载在当前设备超时。构建时先执行 `bash scripts/prepare-geodata.sh`，校验官方快照后将其作为 rawfile 打包；扩展在首次启动时原子复制到私有目录，保留已有非空数据库。后续手动更新仍由内核处理。

- 来源：[MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)，[geoip.metadb 资产](https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb)。
- release 元数据日期：2026-10-12T01:31:04Z，文件 8,414,245 B。
- SHA-256：`b8f447617c3f6d8ef0f7528c23dfba695bca16a31a396bc4c1fca49e9f038ae3`。
- GitHub 根项目许可：GPL-3.0；正式分发前继续核对数据库源数据的 notices 和授权条件。
- 二进制位于忽略目录 `entry/src/main/resources/rawfile/geodata/`，不会提交入库。当前用于本机签名测试。

latest 资产会变化，摘要不匹配时准备脚本失败。更新须重新核对来源、许可、大小与摘要，再更新锁定值；首次下载后的重复执行会校验已有文件。增加/修改 rawfile 后必须 clean HAP，并检查包内资源摘要。

此快照覆盖当前规则所需的 GeoIP。其他订阅如需额外 GeoSite、ASN 或 provider 文件，启动状态会持续显示 Connecting，错误通过启动状态 IPC 返回；相应离线资源准备需要按实际配置另行补齐。
