import { ProxyEditorText } from '../lib/ProxyEditorText';
import { common } from '@kit.AbilityKit';
import { EditTarget } from '../lib/ConfigEditor';
import { ProxyNodeImport } from '../lib/ProxyNodeImport';
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
  onOriginal: () => void = () => {};
  @State loadFailed: boolean = false;
  @State linkOpen: boolean = false;
  @State nodeLink: string = '';
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

  private t(name: string, first?: string | number, second?: string | number, third?: string | number): string {
    return ProxyEditorText.text(getContext(this) as common.UIAbilityContext, name, first, second, third);
  }

  aboutToAppear(): void {
    this.loadFailed = false;
    try {
    this.form = new ProxyMappingForm(this.section, this.target);
    this.type = this.form.text('type') || (this.section === 'proxies' ? 'ss' :
      this.section === 'proxy-providers' ? 'http' : 'select');
    this.transport = this.form.text('network');
    this.reality = this.form.nestedText(['reality-opts', 'public-key']) !== '';
    this.form.setText('type', this.type);
    this.members = this.form.list('proxies');
    this.providers = this.form.list('use');
    } catch (error) {
      this.loadFailed = true;
      this.error = ProxyEditorText.failure(getContext(this) as common.UIAbilityContext, (error as Error).message);
    }
  }

  aboutToDisappear(): void { this.generation++; this.nodeLink = ''; }

  private importLink(): void {
    if (this.submitting || this.busy || this.loadFailed || this.section !== 'proxies' || this.target !== null) { return; }
    try {
      this.form.replaceAdvanced(JSON.stringify(ProxyNodeImport.parse(this.nodeLink)));
      this.type = this.form.text('type'); this.transport = this.form.text('network');
      this.reality = this.form.nestedText(['reality-opts', 'public-key']) !== '';
      this.nodeLink = ''; this.linkOpen = false; this.error = '';
    } catch (_) { this.error = this.t('proxy_form_invalid_link'); }
  }

  private transportTypes(): string[] {
    const common = ['tcp', 'ws', 'grpc'];
    return this.transport === '' || common.includes(this.transport) ? common : [this.transport].concat(common);
  }

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
    if (this.submitting || this.busy || this.loadFailed) { return; }
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
      if (request === this.generation) { this.error = ProxyEditorText.failure(getContext(this) as common.UIAbilityContext, (error as Error).message); }
    } finally { this.submitting = false; }
  }

  @Builder
  Field(label: string, key: string, secret: boolean = false, numeric: boolean = false) {
    Column({ space: 6 }) {
      Text(label).accessibilityLevel('no').fontSize(14).fontColor(UI.muted).width('100%')
      TextInput({ text: this.form.text(key), placeholder: label }).accessibilityText(label)
        .type(secret ? InputType.Password : (numeric ? InputType.Number : InputType.Normal))
        .width('100%').constraintSize({ minHeight: 48 }).enabled(!this.submitting)
        .onChange((value: string) => {
          if (numeric) { this.form.setNumber(key, value); }
          else if (key === 'sample-rate') { this.form.setFraction(key, value); } else { this.form.setText(key, value); }
        })
    }.width('100%')
  }

  @Builder
  NestedField(label: string, path: string[], secret: boolean = false) {
    Column({ space: 6 }) {
      Text(label).accessibilityLevel('no').fontSize(14).fontColor(UI.muted).width('100%')
      TextInput({ text: this.form.nestedText(path), placeholder: label }).accessibilityText(label).constraintSize({ minHeight: 48 }).width('100%')
        .type(secret ? InputType.Password : InputType.Normal).enabled(!this.submitting)
        .onChange((value: string) => {
          try { this.form.setNestedText(path, value); this.error = ''; }
          catch (_) { this.error = this.t('proxy_form_use_advanced'); }
        })
    }.width('100%')
  }

  @Builder
  NodeFields() {
    this.Field(this.t('proxy_form_server'), 'server')
    this.Field(this.t('proxy_form_port'), 'port', false, true)
    if (this.type === 'ss' || this.type === 'vmess') { this.Field(this.t('proxy_form_cipher'), 'cipher') }
    if (this.type === 'ss' || this.type === 'trojan') { this.Field(this.t('proxy_form_password'), 'password', true) }
    if (this.type === 'vmess' || this.type === 'vless') { this.Field(this.t('proxy_form_uuid'), 'uuid', true) }
    if (this.type === 'vmess') { this.Field(this.t('proxy_form_alter_id'), 'alterId', false, true) }
    if (this.type === 'vless') { this.Field(this.t('proxy_form_flow'), 'flow') }
    Row() {
      Text($r('app.string.proxy_form_udp')).accessibilityLevel('no').fontSize(14).fontColor(UI.ink).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.form.flag('udp') }).accessibilityText($r('app.string.proxy_form_udp')).enabled(!this.submitting)
        .onChange((value: boolean) => { this.form.setFlag('udp', value); })
    }.width('100%')
    if (this.type !== 'ss') {
      if (this.type !== 'trojan') {
        Row() {
          Text($r('app.string.proxy_form_tls')).accessibilityLevel('no').fontSize(14).fontColor(UI.ink).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.form.flag('tls') }).accessibilityText($r('app.string.proxy_form_tls')).enabled(!this.submitting)
            .onChange((value: boolean) => { this.form.setFlag('tls', value); })
        }.width('100%')
      }
      Select(this.transportTypes().map((value: string) => new ProxyFormOption(value))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
        .accessibilityText($r('app.string.proxy_form_transport')).value(this.transport || 'tcp').enabled(!this.submitting).onSelect((_, value: string) => {
          this.transport = value; this.form.setText('network', value);
        })
      if (this.transport === 'ws') {
        this.NestedField(this.t('proxy_form_request_path'), ['ws-opts', 'path'])
        this.NestedField(this.t('proxy_form_host'), ['ws-opts', 'headers', 'Host'])
      }
      if (this.transport === 'grpc') { this.NestedField(this.t('proxy_form_service'), ['grpc-opts', 'grpc-service-name']) }
      this.Field(this.t('proxy_form_server_name'), this.type === 'trojan' ? 'sni' : 'servername')
      this.Field(this.t('proxy_form_fingerprint'), 'client-fingerprint')
    }
    if (this.type === 'vless') {
      Button(this.reality ? this.t('proxy_form_reality') : this.t('proxy_form_add_reality')).constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.ink)
        .onClick(() => { this.reality = true; })
      if (this.reality) {
        this.NestedField(this.t('proxy_form_reality_key'), ['reality-opts', 'public-key'])
        this.NestedField(this.t('proxy_form_short_id'), ['reality-opts', 'short-id'])
      }
    }
  }

  @Builder
  ProviderFields() {
    if (this.type === 'http') {
      this.Field(this.t('proxy_form_url'), 'url', true)
      this.Field(this.t('proxy_form_update_interval'), 'interval', false, true)
    }
    if (this.type === 'http' || this.type === 'file') { this.Field(this.t('proxy_form_path'), 'path') }
  }

  @Builder
  GroupFlag(label: string, key: string, defaultValue: boolean = false) {
    Row() {
      Text(label).fontSize(14).fontColor(UI.ink).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.form.flagOrDefault(key, defaultValue) }).accessibilityText(label).enabled(!this.submitting)
        .onChange((value: boolean) => this.form.setFlag(key, value))
    }.width('100%').constraintSize({ minHeight: 48 })
  }
  @Builder
  GroupFields() {
    Text($r('app.string.proxy_form_members')).fontSize(15).fontColor(UI.ink).width('100%')
    ForEach(this.members, (name: string, index: number) => {
      Row({ space: 8 }) {
        Text(name).fontSize(14).fontColor(UI.ink).layoutWeight(1)
        Button($r('app.string.proxy_form_move_up')).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 44 }).accessibilityText(this.t('proxy_form_move_up_member', name)).enabled(index > 0).onClick(() => { this.moveMember(index, -1); })
        Button($r('app.string.proxy_form_move_down')).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 44 }).accessibilityText(this.t('proxy_form_move_down_member', name)).enabled(index < this.members.length - 1).onClick(() => { this.moveMember(index, 1); })
        Button($r('app.string.proxy_form_remove')).backgroundColor(Color.Transparent).fontColor(UI.error).constraintSize({ minHeight: 44 }).accessibilityText(this.t('proxy_form_remove_member', name)).onClick(() => { this.members = this.members.filter((_, i: number) => i !== index); })
      }.width('100%')
    }, (name: string) => name)
    Select(this.names.concat(['DIRECT', 'REJECT']).filter((name: string) =>
      name !== this.form.text('name') && !this.members.includes(name)).map((name: string) => new ProxyFormOption(name))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
      .value(this.t('proxy_form_add_member')).onSelect((_, name: string) => { this.members = this.members.concat([name]); })
    Text($r('app.string.proxy_editor_sources')).fontSize(15).fontColor(UI.ink).width('100%')
    ForEach(this.providers, (name: string) => {
      Row() {
        Text(name).fontSize(14).fontColor(UI.ink).layoutWeight(1)
        Button($r('app.string.proxy_form_remove')).backgroundColor(Color.Transparent).fontColor(UI.error).constraintSize({ minHeight: 44 }).accessibilityText(this.t('proxy_form_remove_member', name)).onClick(() => { this.providers = this.providers.filter((value: string) => value !== name); })
      }.width('100%')
    }, (name: string) => name)
    Select(this.providerNames.filter((name: string) => !this.providers.includes(name))
      .map((name: string) => new ProxyFormOption(name))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).value(this.t('proxy_form_add_source'))
      .onSelect((_, name: string) => { this.providers = this.providers.concat([name]); })
    if (this.type !== 'select') {
      this.Field(this.t('proxy_form_check_url'), 'url')
      this.Field(this.t('proxy_form_check_interval'), 'interval', false, true)
      this.Field(this.t('proxy_form_timeout'), 'timeout', false, true)
      this.Field(this.t('routing_expected_status'), 'expected-status')
      this.Field(this.t('routing_max_failed'), 'max-failed-times', false, true)
      this.GroupFlag(this.t('routing_lazy'), 'lazy', true)
    }
    this.GroupFlag(this.t('routing_include_all'), 'include-all')
    this.GroupFlag(this.t('routing_include_proxies'), 'include-all-proxies')
    this.GroupFlag(this.t('routing_include_providers'), 'include-all-providers')
    this.Field(this.t('routing_filter'), 'filter')
    this.Field(this.t('routing_exclude_filter'), 'exclude-filter')
    this.Field(this.t('routing_exclude_type'), 'exclude-type')
    if (this.type === 'smart' || this.type === 'url-test') { this.Field(this.t('routing_tolerance'), 'tolerance', false, true) }
    if (this.type === 'smart') {
      this.Field(this.t('routing_policy_priority'), 'policy-priority')
      this.GroupFlag(this.t('routing_lightgbm'), 'uselightgbm')
      this.GroupFlag(this.t('routing_collectdata'), 'collectdata')
      this.Field(this.t('routing_sample_rate'), 'sample-rate')
      this.GroupFlag(this.t('routing_prefer_asn'), 'prefer-asn')
    }
  }

  build() {
    Column({ space: 12 }) {
      if (!this.loadFailed) {
      Scroll() {
        Column({ space: 16 }) {
          if (this.advanced) {
            TextArea({ text: this.advancedText }).accessibilityText($r('app.string.proxy_form_advanced')).fontSize(14).fontFamily('HarmonyOS Sans Mono')
              .constraintSize({ minHeight: 320 }).onChange((value: string) => { this.advancedText = value; })
          } else {
            if (this.section === 'proxies' && this.target === null) {
              Button($r('app.string.proxy_form_import_link')).constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.ink)
                .onClick(() => { this.linkOpen = !this.linkOpen; })
              if (this.linkOpen) {
                TextInput({ text: this.nodeLink, placeholder: this.t('proxy_form_node_link') }).type(InputType.Password).maxLength(8192)
                  .onChange((value: string) => { this.nodeLink = value; })
                Button($r('app.string.proxy_form_read')).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 44 }).onClick(() => { this.importLink(); })
              }
            }
            this.Field(this.t('proxy_form_name'), 'name')
            Select(this.types().map((value: string) => new ProxyFormOption(value))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).accessibilityText($r('app.string.proxy_form_type')).value(this.type)
              .onSelect((_, value: string) => { this.type = value; this.form.setText('type', value); })
            if (this.section === 'proxies') {
              if (['ss', 'vmess', 'vless', 'trojan'].includes(this.type)) { this.NodeFields() }
            }
            else if (this.section === 'proxy-providers') { this.ProviderFields() }
            else { this.GroupFields() }
            Button($r('app.string.proxy_form_advanced')).constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => {
              if (this.section === 'proxy-groups') {
                this.form.setList('proxies', this.members); this.form.setList('use', this.providers);
              }
              this.advancedText = this.form.advancedText(); this.advanced = true;
            })
          }
        }.width('100%')
      }.width('100%').layoutWeight(1).enabled(!this.submitting && !this.busy)
      }
      if (this.error.length > 0) { Text(this.error).fontSize(14).fontColor(UI.error).width('100%') }
      if (this.loadFailed) {
        Button($r('app.string.proxy_form_open_original')).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 44 }).enabled(!this.busy && !this.submitting)
          .onClick(() => { this.onOriginal(); })
      }
      Row({ space: 12 }) {
        Button($r('app.string.proxy_editor_cancel')).constraintSize({ minHeight: 44 }).layoutWeight(1).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
          .onClick(() => { this.onCancel(); })
        if (!this.loadFailed) {
        Button($r('app.string.proxy_editor_preview')).constraintSize({ minHeight: 44 }).layoutWeight(1).constraintSize({ minHeight: 48 }).backgroundColor(UI.action).fontColor(UI.onAccent)
          .enabled(!this.submitting && !this.busy).onClick(() => { this.submit(); })
        }
      }.width('100%')
    }.width('100%').height('100%').padding(16).backgroundColor(UI.paper)
  }
}
