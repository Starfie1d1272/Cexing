import { EditTarget } from '../lib/ConfigEditor';
import { ProxyMappingForm, ProxyMappingDraft } from '../lib/ProxyMappingForm';
import { NativeTheme as UI } from './NativeTheme';

class ProxyFormOption {
  value: string;
  constructor(value: string) { this.value = value; }
}

/** Local form only. Preview/application are owned by the common editor host. */
@Component
export struct ProxyMappingFormPage {
  @Prop section: string = 'proxies';
  @Prop busy: boolean = false;
  @Prop target: EditTarget | null = null;
  @Prop names: string[] = [];
  @Prop providerNames: string[] = [];
  onDraft: (draft: ProxyMappingDraft) => Promise<void> = async () => {};
  onCancel: () => void = () => {};
  @State type: string = '';
  @State submitting: boolean = false;
  @State transport: string = '';
  @State reality: boolean = false;
  private generation: number = 0;
  @State members: string[] = [];
  @State providers: string[] = [];
  @State error: string = '';
  @State advanced: boolean = false;
  @State advancedText: string = '';
  private form: ProxyMappingForm = new ProxyMappingForm('proxies');

  aboutToAppear(): void {
    this.form = new ProxyMappingForm(this.section, this.target);
    this.type = this.form.text('type') || (this.section === 'proxies' ? 'ss' :
      this.section === 'proxy-providers' ? 'http' : 'select');
    this.transport = this.form.text('network');
    this.reality = this.form.nestedText(['reality-opts', 'public-key']) !== '';
    this.form.setText('type', this.type);
    this.members = this.form.list('proxies');
    this.providers = this.form.list('use');
  }

  aboutToDisappear(): void { this.generation++; }

  private types(): string[] {
    const supported = this.section === 'proxies' ? ['ss', 'vmess', 'vless', 'trojan'] :
      this.section === 'proxy-providers' ? ['http', 'file', 'inline'] :
        ['select', 'url-test', 'load-balance', 'smart', 'fallback'];
    return supported.includes(this.type) ? supported : [this.type].concat(supported);
  }

  private moveMember(index: number, delta: number): void {
    const next = index + delta;
    if (next < 0 || next >= this.members.length) { return; }
    const members = this.members.slice();
    const value = members[index]; members[index] = members[next]; members[next] = value;
    this.members = members;
  }

  private async submit(): Promise<void> {
    if (this.submitting || this.busy) { return; }
    const request = this.generation;
    this.submitting = true;
    try {
      if (this.advanced) { this.form.replaceAdvanced(this.advancedText); }
      else if (this.section === 'proxy-groups') {
        this.form.setList('proxies', this.members);
        this.form.setList('use', this.providers);
      }
      const draft = this.form.finish();
      await this.onDraft(draft);
      if (request === this.generation) { this.error = ''; }
    } catch (error) {
      if (request === this.generation) { this.error = (error as Error).message; }
    } finally { this.submitting = false; }
  }

  @Builder
  Field(label: string, key: string, secret: boolean = false, numeric: boolean = false) {
    Column({ space: 6 }) {
      Text(label).fontSize(14).fontColor(UI.muted).width('100%')
      TextInput({ text: this.form.text(key), placeholder: label })
        .type(secret ? InputType.Password : (numeric ? InputType.Number : InputType.Normal))
        .width('100%').height(48).enabled(!this.submitting)
        .onChange((value: string) => {
          if (numeric) { this.form.setNumber(key, value); }
          else { this.form.setText(key, value); }
        })
    }.width('100%')
  }

  @Builder
  NestedField(label: string, path: string[], secret: boolean = false) {
    Column({ space: 6 }) {
      Text(label).fontSize(14).fontColor(UI.muted).width('100%')
      TextInput({ text: this.form.nestedText(path), placeholder: label }).height(48).width('100%')
        .type(secret ? InputType.Password : InputType.Normal).enabled(!this.submitting)
        .onChange((value: string) => {
          try { this.form.setNestedText(path, value); this.error = ''; }
          catch (_) { this.error = '该字段请使用高级编辑'; }
        })
    }.width('100%')
  }

  @Builder
  NodeFields() {
    this.Field('服务器', 'server')
    this.Field('端口', 'port', false, true)
    if (this.type === 'ss') { this.Field('加密方式', 'cipher') }
    if (this.type === 'ss' || this.type === 'trojan') { this.Field('密码', 'password', true) }
    if (this.type === 'vmess' || this.type === 'vless') { this.Field('UUID', 'uuid', true) }
    if (this.type === 'vmess') { this.Field('Alter ID', 'alterId', false, true) }
    if (this.type === 'vless') { this.Field('流控', 'flow') }
    Row() {
      Text('TLS').fontSize(14).fontColor(UI.ink).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.form.flag('tls') }).enabled(!this.submitting)
        .onChange((value: boolean) => { this.form.setFlag('tls', value); })
    }.width('100%')
    Select(['tcp', 'ws', 'grpc', 'http', 'h2', 'quic'].map((value: string) => new ProxyFormOption(value)))
      .value(this.transport || 'tcp').enabled(!this.submitting).onSelect((_, value: string) => {
        this.transport = value; this.form.setText('network', value);
      })
    if (this.transport === 'ws') {
      this.NestedField('请求路径', ['ws-opts', 'path'])
      this.NestedField('Host', ['ws-opts', 'headers', 'Host'])
    }
    if (this.transport === 'grpc') { this.NestedField('服务名称', ['grpc-opts', 'grpc-service-name']) }
    this.Field('服务器名称', 'servername')
    this.Field('客户端指纹', 'client-fingerprint')
    if (this.type === 'vless') {
      Button(this.reality ? 'Reality 参数' : '添加 Reality 参数').backgroundColor(UI.soft).fontColor(UI.ink)
        .onClick(() => { this.reality = true; })
      if (this.reality) {
        this.NestedField('Reality 公钥', ['reality-opts', 'public-key'])
        this.NestedField('Short ID', ['reality-opts', 'short-id'])
      }
    }
  }

  @Builder
  ProviderFields() {
    if (this.type === 'http') {
      this.Field('来源链接', 'url', true)
      this.Field('更新间隔（秒）', 'interval', false, true)
    }
    if (this.type === 'http' || this.type === 'file') { this.Field('文件路径', 'path') }
  }

  @Builder
  GroupFields() {
    Text('组成员').fontSize(15).fontColor(UI.ink).width('100%')
    ForEach(this.members, (name: string, index: number) => {
      Row({ space: 8 }) {
        Text(name).fontSize(14).fontColor(UI.ink).layoutWeight(1)
        Button('上移').enabled(index > 0).onClick(() => { this.moveMember(index, -1); })
        Button('下移').enabled(index < this.members.length - 1).onClick(() => { this.moveMember(index, 1); })
        Button('移除').onClick(() => { this.members = this.members.filter((_, i: number) => i !== index); })
      }.width('100%')
    }, (name: string) => name)
    Select(this.names.concat(['DIRECT', 'REJECT']).filter((name: string) =>
      name !== this.form.text('name') && !this.members.includes(name)).map((name: string) => new ProxyFormOption(name)))
      .value('添加节点或组').onSelect((_, name: string) => { this.members = this.members.concat([name]); })
    Text('订阅来源').fontSize(15).fontColor(UI.ink).width('100%')
    ForEach(this.providers, (name: string) => {
      Row() {
        Text(name).fontSize(14).fontColor(UI.ink).layoutWeight(1)
        Button('移除').onClick(() => { this.providers = this.providers.filter((value: string) => value !== name); })
      }.width('100%')
    }, (name: string) => name)
    Select(this.providerNames.filter((name: string) => !this.providers.includes(name))
      .map((name: string) => new ProxyFormOption(name))).value('添加订阅来源')
      .onSelect((_, name: string) => { this.providers = this.providers.concat([name]); })
    if (this.type !== 'select') {
      this.Field('检测地址', 'url')
      this.Field('检测间隔（秒）', 'interval', false, true)
      this.Field('超时（毫秒）', 'timeout', false, true)
    }
  }

  build() {
    Column({ space: 12 }) {
      Scroll() {
        Column({ space: 16 }) {
          if (this.advanced) {
            TextArea({ text: this.advancedText }).fontSize(14).fontFamily('HarmonyOS Sans Mono')
              .constraintSize({ minHeight: 320 }).onChange((value: string) => { this.advancedText = value; })
          } else {
            this.Field('名称', 'name')
            Select(this.types().map((value: string) => new ProxyFormOption(value))).value(this.type)
              .onSelect((_, value: string) => { this.type = value; this.form.setText('type', value); })
            if (this.section === 'proxies') { this.NodeFields() }
            else if (this.section === 'proxy-providers') { this.ProviderFields() }
            else { this.GroupFields() }
            Button('高级编辑').backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => {
              if (this.section === 'proxy-groups') {
                this.form.setList('proxies', this.members); this.form.setList('use', this.providers);
              }
              this.advancedText = this.form.advancedText(); this.advanced = true;
            })
          }
        }.width('100%')
      }.width('100%').layoutWeight(1).enabled(!this.submitting && !this.busy)
      if (this.error.length > 0) { Text(this.error).fontSize(14).fontColor(UI.error).width('100%') }
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).height(48).backgroundColor(UI.soft).fontColor(UI.ink)
          .onClick(() => { this.onCancel(); })
        Button('预览').layoutWeight(1).height(48).backgroundColor(UI.action).fontColor(UI.onAccent)
          .enabled(!this.submitting && !this.busy).onClick(() => { this.submit(); })
      }.width('100%')
    }.width('100%').height('100%').padding(16).backgroundColor(UI.paper)
  }
}
