# 配置引擎接口提案 v1

这是研究接口，不新增 ArkTS/Go ABI，也不改变 ProfileStore 格式。唯一事务及持久化归属遵循 [现有契约](../configuration.md)。配置引擎负责生成与验证候选，运行时负责激活、内核应用确认与回滚。

## 输入（宿主内部对象，不写日志）

```typescript
type ArtifactKind = 'complete-yaml' | 'clash-verge-merge-2.5.8' | 'provider-payload'
  | 'verge-script' | 'openclash-shell' | 'unknown';
interface PlanRequestV1 {
  version: 1;
  transactionId: string;
  reason: 'import' | 'edit' | 'switch' | 'subscription-update' | 'reload';
  expectedActiveRevision: string; // compare-and-swap，阻止旧下载覆盖新选择
  source: { kind: ArtifactKind; contentHandle: string; digest: string };
  base?: { contentHandle: string; digest: string };
  merge?: {
    contentHandle: string; digest: string;
    dialect: 'clash-verge-merge-2.5.8';
    sourceVersion?: string; // 原平台已知版本；缺省为未知，不假定等价迁移
  };
  policy?: {
    id: string; version: string; digest: string;
    family: 'mobile-client' | 'gateway-smart';
    lightgbm: 'disabled' | 'required'; // 独立于组 type
    quic: 'preserve' | 'reject-udp443';
    lan: 'preserve' | 'direct';
  };
  providerSnapshot?: { handle: string; digest: string; networkEpoch: string };
  platformSnapshot: { handle: string; digest: string; networkEpoch: string };
  coreIdentity: { module: string; revision: string; capabilitiesDigest: string };
}
```

contentHandle 是宿主私有不可遍历句柄，不是公开 URL 或任意路径。Merge 方言固定为 Verge v2.5.8，具体语义见 [规范](spec.md)；Canonical 管理项更新只属于 Strategy，不使用按名称合并的通用 Merge。获取 provider、订阅凭据保管与错误脱敏在宿主边界；计划阶段禁止额外网络请求/执行 JS/sh。providerSnapshot 必须给出每个 provider 的固定摘要、可用叶节点、已解析健康检查和获取结果；未解析不视为零节点，也不视为成功。转换到候选时保持 provider 身份，更新使快照失效并重新验收必要节点。

platformSnapshot 包括系统 TUN 地址族/路由/DNS/MTU、白名单或排除名单、宿主排除身份，以及 Controller 回环端口、secret/UI 私有句柄。不要把密钥放进 diff。capabilitiesDigest 必须对应具体内核解析器与模型证据，不能用版本字符串猜 smart/LightGBM 可用。

## 输出

```typescript
interface PlanResultV1 {
  version: 1;
  transactionId: string;
  status: 'ready' | 'needs-input' | 'rejected';
  diagnostics: Array<{
    code: string; severity: 'error' | 'warning';
    stage: 'detect' | 'merge' | 'policy' | 'platform' | 'validate';
    path?: string; // 结构路径，不能包含动态节点名/URL/凭据
    messageKey: string;
  }>;
  candidate?: {
    privateHandle: string; digest: string;
    inputDigest: string; expectedActiveRevision: string;
    platformDigest: string; coreCapabilitiesDigest: string;
    validationReceipt: string;
  };
  preview?: { privateHandle: string; redactedSummary: string[] };
}
```

ready 必须完成 Merge、策略、平台投影及固定内核完整解析/资源引用检查；没有内核验证回执不能 ready。needs-input/rejected 不返回可激活 candidate。诊断路径和摘要只呈现字段类别、数量与受管理组语义；真实详情仅限本机用户受控预览。

规范错误码：FORMAT_AMBIGUOUS、FORMAT_UNSUPPORTED、BASE_REQUIRED、MERGE_CONFLICT、PROTECTED_FIELD、PROVIDER_UNRESOLVED、REQUIRED_REGION_EMPTY、DUPLICATE_IDENTITY、REFERENCE_MISSING、REFERENCE_CYCLE、RESOURCE_MISSING、DNS_POLICY_REQUIRED、IPV6_UNVERIFIED、CAPABILITY_UNAVAILABLE、CORE_VALIDATION_FAILED、STALE_REVISION。缺美国节点必须失败，不能转 DIRECT。Google 所需 JP/SG/US 区域为空按 REQUIRED_REGION_EMPTY 处理；不隐式删掉服务选项。

## 激活与回退的交接

运行时以 transactionId + expectedActiveRevision + validationReceipt 提交，原始输入/覆写/候选分别存储。提交前再次比对 activeRevision、网络/platform/provider 与内核能力身份，过期返回 STALE_REVISION 并重新计划。临时文件落盘和摘要验证后原子替换；内核应用收到成功且系统参数一致才更新 activeRevision。失败恢复旧内核与旧持久状态，回滚也失败时报告独立故障并保留两份材料，不能假装旧版本正在运行。

接口不提供 `/restart`、设备设置写入、模型下载、Shell/JS 执行或直接合并 PR。配置引擎的实现测试应消费 [fixtures](fixtures/cases.json)：正常叶节点、过滤后为空、provider 未解析、规则幂等、受保护字段、订阅更新和失败回退。事务用例是验收剧本，不是本研究已通过的生产测试。
