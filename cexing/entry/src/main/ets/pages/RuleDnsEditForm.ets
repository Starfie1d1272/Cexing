import { util } from '@kit.ArkTS';
import { NativeTheme as UI } from './NativeTheme';
import { EditOperation, EditTarget, EditableItem } from '../lib/ConfigEditor';
import { COMMON_RULE_TYPES, RuleDnsForms, RuleFields, ProviderFields, DnsFields } from '../lib/RuleDnsForms';

@Component
export struct RuleDnsEditForm {
  @Prop section: string = 'rules';
  @Prop selected: EditTarget = { item: { id: '', revision: '' }, missingFieldRevision: '', value: '' };
  @Prop providers: string[] = [];
  @Prop targets: string[] = ['DIRECT', 'REJECT'];
  @Prop isNew: boolean = false;
  @Prop matchId: string = '';
  @Prop positions: EditableItem[] = [];
  @Prop insertionBefore: string = '';
  @State ruleBefore: string = '';
  onOperation: (operation: EditOperation) => void = (_: EditOperation): void => { throw new Error('编辑尚未接通'); };
  onClose: () => void = (): void => {};
  @State kind: string = 'DOMAIN-SUFFIX';
  @State condition: string = '';
  @State destination: string = 'DIRECT';
  @State noResolve: boolean = false;
  @State name: string = '';
  @State providerType: string = 'http';
  @State behavior: string = 'domain';
  @State format: string = 'yaml';
  @State location: string = '';
  @State interval: string = '86400';
  @State dnsEnabled: boolean = true;
  @State mode: string = 'fake-ip';
  @State nameservers: string = '';
  @State bootstrap: string = '';
  @State hosts: string = '';
  @State advanced: boolean = false;
  @State advancedText: string = '';
  @State error: string = '';

  aboutToAppear(): void {
    this.ruleBefore = this.isNew && this.selected.item.id !== '' ? this.insertionBefore : this.insertionBefore || this.positions[0]?.id || '';
    this.name = this.selected.name ?? '';
    this.advancedText = this.section === 'rules' ? this.selected.value as string : JSON.stringify(this.selected.value, null, 2);
    if (this.section === 'rules') {
      const fields = RuleDnsForms.parseRule(this.selected.value);
      if (fields !== null) {
        this.kind = fields.type; this.condition = fields.condition; this.destination = fields.target; this.noResolve = fields.noResolve;
      } else if (!this.isNew) { this.advanced = true; }
    } else if (this.section === 'rule-providers') {
      const value = this.selected.value as Record<string, Object>;
      this.providerType = typeof value['type'] === 'string' ? value['type'] as string : 'http';
      this.behavior = typeof value['behavior'] === 'string' ? value['behavior'] as string : 'domain';
      this.format = typeof value['format'] === 'string' ? value['format'] as string : 'yaml';
      this.location = (this.providerType === 'http' ? value['url'] : value['path']) as string ?? '';
      this.interval = `${value['interval'] ?? 86400}`;
      if (!['http', 'file'].includes(this.providerType)) { this.advanced = true; }
    } else if (this.section === 'dns') {
      const fields = RuleDnsForms.dnsFields(this.selected);
      this.dnsEnabled = fields.enabled; this.mode = fields.mode;
      this.nameservers = fields.nameservers.join('\n'); this.bootstrap = fields.bootstrap.join('\n');
    } else if (this.section === 'hosts') {
      this.hosts = Array.isArray(this.selected.value) ? (this.selected.value as string[]).join('\n') : this.selected.value as string;
    }
  }

  private submit(): void {
    this.error = '';
    try {
      const id = `form-${this.section}-${util.generateRandomUUID(true)}`;
      let operation: EditOperation;
      if (this.advanced) {
        operation = this.section === 'rules' ? RuleDnsForms.advancedRule(id, this.selected, this.advancedText) :
          RuleDnsForms.advancedPatch(id, this.section, this.selected, this.advancedText);
      } else if (this.section === 'rules') {
        const fields: RuleFields = { type: this.kind, condition: this.condition.trim(), target: this.destination, noResolve: this.noResolve };
        operation = this.isNew ? RuleDnsForms.addRule(id, fields, this.matchId) : RuleDnsForms.updateRule(id, this.selected, fields);
        if (this.isNew && fields.type !== 'MATCH') { operation.before = this.ruleBefore; }
      } else if (this.section === 'rule-providers') {
        if (this.providerType === 'http' && this.interval.trim() === '') { throw new Error('请输入更新间隔'); }
        const fields: ProviderFields = { name: this.name.trim(), type: this.providerType, behavior: this.behavior,
          format: this.format, location: this.location.trim(), interval: Number(this.interval) };
        const value = RuleDnsForms.providerValue(fields);
        operation = this.isNew ? { id, kind: 'add', section: this.section, name: fields.name, value } :
          RuleDnsForms.patch(id, this.section, this.selected, value);
      } else if (this.section === 'dns') {
        const fields: DnsFields = { enabled: this.dnsEnabled, mode: this.mode,
          nameservers: this.nameservers.split('\n').map((value: string) => value.trim()).filter((value: string) => value !== ''),
          bootstrap: this.bootstrap.split('\n').map((value: string) => value.trim()).filter((value: string) => value !== '') };
        operation = RuleDnsForms.dnsUpdate(id, this.selected, fields);
      } else {
        const value = RuleDnsForms.hostValue(this.hosts);
        if (this.isNew) {
          if (!this.name.trim() || /[,\r\n\u0000]/.test(this.name)) { throw new Error('请输入 hosts 名称'); }
          operation = { id, kind: 'add', section: 'hosts', name: this.name.trim(), value };
        } else { operation = { id, kind: 'update', section: 'hosts', target: this.selected.item.id,
          expected: this.selected.item.revision, value }; }
      }
      this.onOperation(operation);
    } catch (error) { this.error = (error as Error).message; }
  }

  private optionLabel(label: string, value: string): string {
    if (label === '目标') { return value === 'DIRECT' ? '直连' : value === 'REJECT' ? '拒绝' : value; }
    if (label === '规则源') { return value; }
    switch (value) {
      case 'DOMAIN': return '完整域名';
      case 'DOMAIN-SUFFIX': return '域名后缀';
      case 'DOMAIN-KEYWORD': return '域名关键字';
      case 'IP-CIDR': return 'IPv4 地址段';
      case 'IP-CIDR6': return 'IPv6 地址段';
      case 'RULE-SET': return '规则源';
      case 'MATCH': return '最终规则';
      case 'http': return '远程';
      case 'file': return '本地';
      case 'domain': return '域名';
      case 'ipcidr': return 'IP 地址段';
      case 'classical': return '综合规则';
      case 'text': return '文本';
      case 'fake-ip': return 'Fake IP';
      case 'redir-host': return '真实 IP';
      default: return value;
    }
  }
  @Builder
  choose(label: string, values: string[], current: string, changed: (value: string) => void) {
    Row({ space: 12 }) {
      Text(label).fontColor(UI.ink).layoutWeight(1)
      Select(values.map((value: string): SelectOption => ({ value: this.optionLabel(label, value) }))).value(this.optionLabel(label, current))
        .selected(values.indexOf(current)).onSelect((index: number) => changed(values[index]))
    }.width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.advanced) {
          TextArea({ text: this.advancedText }).onChange((value: string) => { this.advancedText = value; })
            .height(280).fontSize(15).accessibilityText('高级字段')
        } else if (this.section === 'rules') {
          this.choose('类型', !this.isNew && RuleDnsForms.parseRule(this.selected.value)?.type === 'MATCH' ? ['MATCH'] : COMMON_RULE_TYPES, this.kind, (value: string) => { this.kind = value; this.noResolve = false; })
          if (this.kind !== 'MATCH') {
            if (this.kind === 'RULE-SET') {
              this.choose('规则源', this.providers, this.condition, (value: string) => { this.condition = value; })
            } else {
              TextInput({ placeholder: '匹配条件', text: this.condition }).onChange((value: string) => { this.condition = value; })
            }
          }
          if (this.isNew && this.kind !== 'MATCH' && this.positions.length > 0) {
            Select(this.positions.map((_item: EditableItem, index: number): SelectOption => ({ value: `规则 ${index + 1} 之前` })))
              .selected(this.positions.findIndex((item: EditableItem) => item.id === this.ruleBefore))
              .onSelect((index: number) => { this.ruleBefore = this.positions[index].id; }).accessibilityText('插入位置')
          }
          this.choose('目标', this.targets, this.destination, (value: string) => { this.destination = value; })
          if (['IP-CIDR', 'IP-CIDR6', 'GEOIP'].includes(this.kind)) {
            Row() {
              Text('不解析域名').layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.noResolve }).onChange((value: boolean) => { this.noResolve = value; })
            }
          }
        } else if (this.section === 'rule-providers') {
          if (this.isNew) { TextInput({ placeholder: '名称', text: this.name }).onChange((value: string) => { this.name = value; }) }
          this.choose('来源', ['http', 'file'], this.providerType, (value: string) => { this.providerType = value; })
          this.choose('内容', ['domain', 'ipcidr', 'classical'], this.behavior, (value: string) => { this.behavior = value; })
          this.choose('格式', ['yaml', 'text', 'mrs'], this.format, (value: string) => { this.format = value; })
          TextInput({ placeholder: this.providerType === 'http' ? '资源地址' : '相对路径', text: this.location })
            .onChange((value: string) => { this.location = value; })
          if (this.providerType === 'http') {
            TextInput({ placeholder: '更新间隔（秒）', text: this.interval }).type(InputType.Number)
              .onChange((value: string) => { this.interval = value; })
          }
        } else if (this.section === 'dns') {
          Row() {
            Text('DNS').layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.dnsEnabled }).onChange((value: boolean) => { this.dnsEnabled = value; })
          }
          this.choose('解析模式', ['fake-ip', 'redir-host'], this.mode, (value: string) => { this.mode = value; })
          TextArea({ placeholder: 'DNS 服务器，每行一个', text: this.nameservers }).height(120)
            .onChange((value: string) => { this.nameservers = value; })
          TextArea({ placeholder: '引导 DNS，每行一个', text: this.bootstrap }).height(100)
            .onChange((value: string) => { this.bootstrap = value; })
        } else if (this.section === 'hosts') {
          if (this.isNew) { TextInput({ placeholder: '名称', text: this.name }).onChange((value: string) => { this.name = value; }) }
          TextArea({ placeholder: '地址，每行一个', text: this.hosts }).height(120).onChange((value: string) => { this.hosts = value; })
        }
        if (!this.advanced && !this.isNew && this.section !== 'hosts') {
          Button('高级编辑').onClick(() => { this.advanced = true; })
        }
        if (this.error !== '') { Text(this.error).fontSize(14).fontColor(UI.error) }
        Row({ space: 12 }) {
          Button('取消').onClick(() => this.onClose())
          Button('预览').onClick(() => this.submit())
        }
      }.width('100%').padding(20)
    }.width('100%').backgroundColor(UI.paper)
  }
}
