import { UiText } from '../lib/UiText';
import { RuleDnsText } from '../lib/RuleDnsText';
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
  onOperation: (operation: EditOperation) => void = (_: EditOperation): void => { throw new Error(UiText.get($r('app.string.rule_unwired'))); };
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
        if (this.providerType === 'http' && this.interval.trim() === '') { throw new Error(UiText.get($r('app.string.rule_interval_required'))); }
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
          if (!this.name.trim() || /[,\r\n\u0000]/.test(this.name)) { throw new Error(UiText.get($r('app.string.rule_hosts_required'))); }
          operation = { id, kind: 'add', section: 'hosts', name: this.name.trim(), value };
        } else { operation = { id, kind: 'update', section: 'hosts', target: this.selected.item.id,
          expected: this.selected.item.revision, value }; }
      }
      this.onOperation(operation);
    } catch (error) { this.error = RuleDnsText.failure(error, $r('app.string.rule_validation_failed')); }
  }

  private optionLabel(label: string, value: string): string {
    if (label === UiText.get($r('app.string.rule_target'))) { return value === 'DIRECT' ? UiText.get($r('app.string.rule_direct')) : value === 'REJECT' ? UiText.get($r('app.string.rule_reject')) : value; }
    if (label === UiText.get($r('app.string.rule_providers'))) { return value; }
    switch (value) {
      case 'DOMAIN': return UiText.get($r('app.string.rule_domain'));
      case 'DOMAIN-SUFFIX': return UiText.get($r('app.string.rule_suffix'));
      case 'DOMAIN-KEYWORD': return UiText.get($r('app.string.rule_keyword'));
      case 'IP-CIDR': return UiText.get($r('app.string.rule_ipv4'));
      case 'IP-CIDR6': return UiText.get($r('app.string.rule_ipv6'));
      case 'RULE-SET': return UiText.get($r('app.string.rule_providers'));
      case 'MATCH': return UiText.get($r('app.string.rule_final'));
      case 'http': return UiText.get($r('app.string.rule_remote'));
      case 'file': return UiText.get($r('app.string.rule_local'));
      case 'domain': return UiText.get($r('app.string.rule_domain_type'));
      case 'ipcidr': return UiText.get($r('app.string.rule_ip_range'));
      case 'classical': return UiText.get($r('app.string.rule_classical'));
      case 'text': return UiText.get($r('app.string.rule_text'));
      case 'fake-ip': return 'Fake IP';
      case 'redir-host': return UiText.get($r('app.string.rule_real_ip'));
      default: return value;
    }
  }
  @Builder
  choose(label: string, values: string[], current: string, changed: (value: string) => void) {
    Row({ space: 12 }) {
      Text(label).fontColor(UI.ink).layoutWeight(1)
      Select(values.map((value: string): SelectOption => ({ value: this.optionLabel(label, value) }))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).value(this.optionLabel(label, current)).accessibilityText(label)
        .selected(values.indexOf(current)).onSelect((index: number) => changed(values[index]))
    }.width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.advanced) {
          TextArea({ text: this.advancedText }).onChange((value: string) => { this.advancedText = value; })
            .height(280).fontSize(15).accessibilityText(UiText.get($r('app.string.rule_advanced_fields')))
        } else if (this.section === 'rules') {
          this.choose(UiText.get($r('app.string.rule_type')), !this.isNew && RuleDnsForms.parseRule(this.selected.value)?.type === 'MATCH' ? ['MATCH'] : COMMON_RULE_TYPES, this.kind, (value: string) => { this.kind = value; this.noResolve = false; })
          if (this.kind !== 'MATCH') {
            if (this.kind === 'RULE-SET') {
              this.choose(UiText.get($r('app.string.rule_providers')), this.providers, this.condition, (value: string) => { this.condition = value; })
            } else {
              TextInput({ placeholder: UiText.get($r('app.string.rule_condition')), text: this.condition }).onChange((value: string) => { this.condition = value; })
            }
          }
          if (this.isNew && this.kind !== 'MATCH' && this.positions.length > 0) {
            Select(this.positions.map((_item: EditableItem, index: number): SelectOption => ({ value: UiText.get($r('app.string.rule_before'), index + 1) }))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
              .selected(this.positions.findIndex((item: EditableItem) => item.id === this.ruleBefore))
              .onSelect((index: number) => { this.ruleBefore = this.positions[index].id; }).accessibilityText(UiText.get($r('app.string.rule_position')))
          }
          this.choose(UiText.get($r('app.string.rule_target')), this.targets, this.destination, (value: string) => { this.destination = value; })
          if (['IP-CIDR', 'IP-CIDR6', 'GEOIP'].includes(this.kind)) {
            Row() {
              Text(UiText.get($r('app.string.rule_no_resolve'))).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.noResolve }).accessibilityText(UiText.get($r('app.string.rule_no_resolve'))).accessibilityChecked(this.noResolve).onChange((value: boolean) => { this.noResolve = value; })
            }
          }
        } else if (this.section === 'rule-providers') {
          if (this.isNew) { TextInput({ placeholder: UiText.get($r('app.string.rule_name')), text: this.name }).onChange((value: string) => { this.name = value; }) }
          this.choose(UiText.get($r('app.string.rule_source')), ['http', 'file'], this.providerType, (value: string) => { this.providerType = value; })
          this.choose(UiText.get($r('app.string.rule_content')), ['domain', 'ipcidr', 'classical'], this.behavior, (value: string) => { this.behavior = value; })
          this.choose(UiText.get($r('app.string.rule_format')), ['yaml', 'text', 'mrs'], this.format, (value: string) => { this.format = value; })
          TextInput({ placeholder: this.providerType === 'http' ? UiText.get($r('app.string.rule_address')) : UiText.get($r('app.string.rule_relative_path')), text: this.location })
            .onChange((value: string) => { this.location = value; })
          if (this.providerType === 'http') {
            TextInput({ placeholder: UiText.get($r('app.string.rule_interval')), text: this.interval }).type(InputType.Number)
              .onChange((value: string) => { this.interval = value; })
          }
        } else if (this.section === 'dns') {
          Row() {
            Text('DNS').layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.dnsEnabled }).accessibilityText('DNS').accessibilityChecked(this.dnsEnabled).onChange((value: boolean) => { this.dnsEnabled = value; })
          }
          this.choose(UiText.get($r('app.string.rule_dns_mode')), ['fake-ip', 'redir-host'], this.mode, (value: string) => { this.mode = value; })
          TextArea({ placeholder: UiText.get($r('app.string.rule_nameservers')), text: this.nameservers }).height(120)
            .onChange((value: string) => { this.nameservers = value; })
          TextArea({ placeholder: UiText.get($r('app.string.rule_bootstrap')), text: this.bootstrap }).height(100)
            .onChange((value: string) => { this.bootstrap = value; })
        } else if (this.section === 'hosts') {
          if (this.isNew) { TextInput({ placeholder: UiText.get($r('app.string.rule_name')), text: this.name }).onChange((value: string) => { this.name = value; }) }
          TextArea({ placeholder: UiText.get($r('app.string.rule_hosts_values')), text: this.hosts }).height(120).onChange((value: string) => { this.hosts = value; })
        }
        if (!this.advanced && !this.isNew && this.section !== 'hosts') {
          Button(UiText.get($r('app.string.rule_advanced'))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => { this.advanced = true; })
        }
        if (this.error !== '') { Text(this.error).fontSize(14).fontColor(UI.error) }
        Row({ space: 12 }) {
          Button(UiText.get($r('app.string.rule_cancel'))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.onClose())
          Button(UiText.get($r('app.string.rule_preview'))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.submit())
        }
      }.width('100%').padding(20)
    }.width('100%').backgroundColor(UI.paper)
  }
}
