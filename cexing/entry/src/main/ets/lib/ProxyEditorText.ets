import { common } from '@kit.AbilityKit';

/** Presentation only; user names and values never become resource keys. */
export namespace ProxyEditorText {
  export function text(context: common.Context, name: string, first?: string | number,
    second?: string | number, third?: string | number): string {
    if (third !== undefined) { return context.resourceManager.getStringByNameSync(name, first ?? '', second ?? '', third); }
    if (second !== undefined) { return context.resourceManager.getStringByNameSync(name, first ?? '', second); }
    if (first !== undefined) { return context.resourceManager.getStringByNameSync(name, first); }
    return context.resourceManager.getStringByNameSync(name);
  }

  export function failure(context: common.Context, message: string): string {
    if (message === '') { return ''; }
    const keys: Record<string, string> = {
      '该项目需使用原始配置编辑': 'proxy_form_requires_original',
      '请填写名称': 'proxy_form_require_name', '请填写类型': 'proxy_form_require_type',
      '请填写服务器': 'proxy_form_require_server', '请填写加密方式': 'proxy_form_require_cipher',
      '请填写密码': 'proxy_form_require_password', '请填写UUID': 'proxy_form_require_uuid',
      '请填写文件路径': 'proxy_form_require_path', '请填写来源链接': 'proxy_form_require_url',
      '请填写有效数字': 'proxy_form_require_number', '端口应为 1–65535': 'proxy_form_invalid_port',
      '该字段请使用高级编辑': 'proxy_form_use_advanced', '高级字段格式无效': 'proxy_form_invalid_json',
      '高级字段需要是对象': 'proxy_form_require_object', '请在高级编辑中填写节点列表': 'proxy_form_require_payload',
      '请添加节点或订阅来源': 'proxy_form_require_members',
      '连接此订阅后可查看来源状态': 'proxy_editor_connect_for_source',
      '来源更新失败，请重试': 'proxy_editor_source_update_failed',
      '配置已变化，请重新读取': 'proxy_editor_config_changed',
      '来源状态读取失败，请重试': 'proxy_editor_source_status_failed'
    };
    return text(context, keys[message] ?? 'proxy_form_failed');
  }
}
