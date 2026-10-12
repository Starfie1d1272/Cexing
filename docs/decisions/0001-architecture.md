# ADR 0001：原生 VPN 宿主与 Web 控制面

日期：2026-10-12。状态：产品方向已确定，运行验收待完成。

以 ClashOH 的 ArkTS、VPN 扩展、NAPI worker 和 Go wrapper 为基底。Smart 首选最新 vernesong Alpha 固定提交作研发候选；Zashboard 采用最新正式版，内置静态资源并由 Mihomo external-ui 托管。原生宿主保留启停、订阅、系统授权、状态、设置和诊断。

依据：原始构建成功；最新 Smart 保持现有 ABI 可编译；Zashboard 与内核存在匹配的 Smart 端点。职责与用户产品目标一致，能复用现有平台适配。

影响：必须建立模型许可/校验、Controller 认证、统一配置应用与资源更新机制。平台可靠性需要当前设备验证；试编译不能确定稳定依赖。P0 通过后，P1 换核与 P2 资源准备可分开实施，共享认证/配置 contract 先确定。批准状态随真机结果更新。
