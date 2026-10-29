# GeoSite 差异检查

从 `core` 目录运行 `go run ../scripts/ci/compare-geosite.go OLD.dat NEW.dat > differences.txt`。
输出按分类和条目排序，`+` / `-` 表示新增 / 删除，数字表示重复次数差异。
每条记录包含匹配类型、值及全部属性（包括布尔或整数值）；分类新增和删除单独列出。
结果只说明数据差异，不证明域名覆盖、命中出口或许可兼容，必须结合实际配置及来源逐项审查。
测试可用 `go test ../scripts/ci/compare-geosite.go ../scripts/ci/compare-geosite_test.go`。

## 一次基线调查

2026-10-29，以 [MetaCubeX release 分支提交 be456e5](https://github.com/MetaCubeX/meta-rules-dat/tree/be456e5c402c4a9c98519e73f09256c96914cefd) 的 `geosite.dat`（SHA-256 `38aac2a107485a3818501106292efbbc92214588aa1d62ac5fb5d8a1d1a335f7`）为旧数据；以 [v2fly/domain-list-community 提交 333d8a1](https://github.com/v2fly/domain-list-community/tree/333d8a1810d04600bcb00870155a369954ed37f5) 自带生成器及数据、Go 1.26.9 构建的文件（SHA-256 `540f9381e421493e1e26cc5e484b5feb2bd1abfe33e5d6eb3a24f60783b1b93f`）为新数据。比较结果包含 121,130 行差异（含分类行），新文件缺少 `APPLE-CN`、`BILIINTL`、`GFW`、`GOOGLE-CN`、`HTTPDNS`、`SHAREPOINT`、`TRACKER`、`WIN-EXTRA`、`WIN-SPY` 和 `WIN-UPDATE`。

两者输入版本和生成流程均不同，因此这些差异不能全部归因于 MetaCubeX 的定制；但足以说明直接采用该原版文件会改变分类和规则。当前比较未构成替代方案，也未消除 [NOTICE](NOTICE.md) 所述来源缺口。
