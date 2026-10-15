import { UiText } from './UiText';

/** Presentation only. Does not change backend error or edit identities. */
export namespace RuleDnsText {
  export function failure(error: Object, fallback: Resource): string {
    const message = (error as Error).message ?? '';
    if (message === '请输入更新间隔' || message === UiText.get($r('app.string.rule_interval_required'))) { return UiText.get($r('app.string.rule_interval_required')); }
    if (message === '请输入 hosts 名称' || message === UiText.get($r('app.string.rule_hosts_required'))) { return UiText.get($r('app.string.rule_hosts_required')); }
    if (message === '配置已变化，请重新打开' || message === UiText.get($r('app.string.rule_changed'))) { return UiText.get($r('app.string.rule_changed')); }
    if (message === '已有最终规则，请编辑它' || message === UiText.get($r('app.string.rule_final_exists'))) { return UiText.get($r('app.string.rule_final_exists')); }
    if (message === '请填写规则与目标' || message === UiText.get($r('app.string.rule_fill_required'))) { return UiText.get($r('app.string.rule_fill_required')); }
    if (message === '此规则不支持 no-resolve' || message === UiText.get($r('app.string.rule_no_resolve_unsupported'))) { return UiText.get($r('app.string.rule_no_resolve_unsupported')); }
    if (message === '最终规则必须在末尾' || message === UiText.get($r('app.string.rule_final_required'))) { return UiText.get($r('app.string.rule_final_required')); }
    if (message === '规则位置未变化' || message === UiText.get($r('app.string.rule_order_unchanged'))) { return UiText.get($r('app.string.rule_order_unchanged')); }
    if (message === 'DNS 监听由系统管理' || message === UiText.get($r('app.string.rule_dns_listener'))) { return UiText.get($r('app.string.rule_dns_listener')); }
    if (message === '字段版本未读取，请重新打开' || message === UiText.get($r('app.string.rule_field_unread'))) { return UiText.get($r('app.string.rule_field_unread')); }
    if (message === '请检查规则源类型' || message === UiText.get($r('app.string.rule_provider_type_invalid'))) { return UiText.get($r('app.string.rule_provider_type_invalid')); }
    if (message === '更新间隔应为 0–604800 秒' || message === UiText.get($r('app.string.rule_interval_invalid'))) { return UiText.get($r('app.string.rule_interval_invalid')); }
    if (message === '请输入 HTTP 或 HTTPS 地址' || message === UiText.get($r('app.string.rule_http_required'))) { return UiText.get($r('app.string.rule_http_required')); }
    if (message === '请输入私有目录内的相对路径' || message === UiText.get($r('app.string.rule_path_required'))) { return UiText.get($r('app.string.rule_path_required')); }
    if (message === '请检查 DNS 服务器' || message === UiText.get($r('app.string.rule_dns_invalid'))) { return UiText.get($r('app.string.rule_dns_invalid')); }
    if (message === 'DNS 不能整段删除' || message === UiText.get($r('app.string.rule_dns_delete'))) { return UiText.get($r('app.string.rule_dns_delete')); }
    if (message === '请输入单条规则' || message === UiText.get($r('app.string.rule_single_required'))) { return UiText.get($r('app.string.rule_single_required')); }
    if (message === '请输入 hosts 地址' || message === UiText.get($r('app.string.rule_hosts_address'))) { return UiText.get($r('app.string.rule_hosts_address')); }
    if (message === '高级字段必须是 JSON 对象' || message === UiText.get($r('app.string.rule_json_object'))) { return UiText.get($r('app.string.rule_json_object')); }
    if (message === '应用未确认，请重连恢复' || message === UiText.get($r('app.string.rule_apply_unknown'))) { return UiText.get($r('app.string.rule_apply_unknown')); }
    if (message === '已有配置操作正在进行，请稍后重试' || message === UiText.get($r('app.string.rule_busy'))) { return UiText.get($r('app.string.rule_busy')); }
    if (message.includes('未确认') || message.includes('结果未知')) { return UiText.get($r('app.string.rule_apply_unknown')); }
    return UiText.get(fallback);
  }
}
