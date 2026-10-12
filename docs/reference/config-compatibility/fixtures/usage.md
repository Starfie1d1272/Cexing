# 合成验收材料

所有 `.yaml` 文件用 JSON 子集表示 YAML，便于无额外 JS 依赖检查；是真正合成数据，不是私有配置的替换副本。节点地址用文档保留网段，探针使用 `.example`。不要联网、导入真实设备或激活这些示例。DNS 地址和 provider path 不表示现场可运行资源。

`base.yaml` 是含节点/组/规则的完整结构，`expected-mobile.yaml` 是目标语义样本，未提供 Controller/TUN 生产投影。服务域名也是 `.example`，不证明真实业务路由。`provider-config.yaml` 是完整 provider 配置，`provider-payload.yaml` 是只有节点集合的 provider 内容；格式声明必须区分二者。

[cases.json](cases.json) 给未来引擎提供输入分类、fixture 变异、错误码及事务剧本；期待值不是测试执行记录。未声明的前置条件采用已验证平台/内核快照及有效手机 DNS。所列错误码是该场景关注的诊断，出现其他阻断也不能返回 ready。

`merge-base.yaml` + `merge.yaml` → `merge-expected.yaml` 固定为 Clash Verge v2.5.8 合并阶段样本，不运行内核或平台投影。三项关键期待：proxies/proxy-groups/listeners 命名数组整体替换，旧项/旧字段不会按 name 保留；dns.fallback 键仍存在且为 null；指定的 dns.nameserver-policy/fallback-filter 以及整个 hosts mapping 替换，旧条目移除，未指定的 dns.nameserver 保留。一般 mapping 如 tun 仍递归合并。null 是否可用于最终内核字段由后续完整校验决定。

本入口不支持自定义删除操作。旧版来源的 DNS/hosts 不能静默按新语义迁移；来源版本未知需明确展示目标方言。`merge-protected.yaml` 的 secret 是显式合成非秘密占位值，预期拒绝跨越平台字段边界。

独立材料检查：

```bash
python3 docs/reference/config-compatibility/fixtures/check-fixtures.py
```

该检查只证明材料可解析、样本引用/池约束成立及文档链接存在；不执行转换，不调用内核，不消费私有策略，不证明 cases 的所有验收期待已经实现。生产实现应再增加必要的内核验证、更新/激活失败回退及真机 DNS/IPv6 流量证据。
