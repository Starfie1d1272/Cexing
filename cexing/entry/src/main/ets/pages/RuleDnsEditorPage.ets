import { util } from '@kit.ArkTS';
import { RegionPlan } from '../lib/EffectiveVersions';
import { common } from '@kit.AbilityKit';
import { NativeTheme as UI } from './NativeTheme';
import { RuleDnsEditForm } from './RuleDnsEditForm';
import { ConfigEditor, EditIntent, EditOperation, EditableSnapshot, EditableSection, EditableItem, EditTarget } from '../lib/ConfigEditor';
import { RuleDnsForms } from '../lib/RuleDnsForms';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { RuleProviderStatus } from '../lib/RuleProviderStatus';
import { RuleDnsDraft } from '../lib/RuleDnsDraft';
import { ProfileTransactions, EditTicket } from '../lib/ProfileTransactions';
import { EffectiveVersions } from '../lib/EffectiveVersions';
import { ProfileStore } from '../lib/ProfileStore';

export class RuleDnsEditorBus { static file: string = ''; static section: string = 'rules'; }

@Component
export struct RuleDnsEditorPage {
  @Prop @Watch('visibilityChanged') visible: boolean = true;
  @State section: string = 'rules';
  @State items: EditableItem[] = [];
  @State additions: EditOperation[] = [];
  @State insertionBefore: string = '';
  @State selected: EditTarget | null = null;
  @State isNew: boolean = false;
  @State busy: boolean = false;
  @State message: string = '';
  @State previewReady: boolean = false;
  @State targets: string[] = ['DIRECT', 'REJECT'];
  @State providers: string[] = [];
  @State choiceSection: string = '';
  @State choices: EditableItem[] = [];
  @State rename: string = '';
  @State providerState: string = '';
  @State providerError: string = '';
  @State showProviderError: boolean = false;
  private active: boolean = false;
  private epoch: number = 0;
  private file: string = '';
  private original: string = '';
  private localOverlay: string = '';
  private ticket: EditTicket | null = null;
  private snapshot: EditableSnapshot | null = null;
  private intent: EditIntent | null = null;
  private undo: EditIntent | null = null;
  private liveProviderName: string = '';
  private region: RegionPlan | null = null;

  aboutToAppear(): void { this.file = RuleDnsEditorBus.file; this.section = RuleDnsEditorBus.section; this.active = this.visible; if (this.active) { this.load(); } }
  aboutToDisappear(): void { this.active = false; this.epoch++; this.busy = false; }
  private visibilityChanged(): void {
    if (this.active === this.visible) { return; }
    this.active = this.visible; this.epoch++; this.busy = false; this.selected = null;
    if (this.active) { this.load(); }
  }
  private current(epoch: number): boolean { return this.active && this.epoch === epoch; }
  private list(): void {
    this.items = (this.snapshot?.sections.find((part: EditableSection) => part.section === this.section)?.items ?? []).slice();
    this.additions = []; this.selected = null; this.isNew = false;
  }
  private async load(): Promise<void> {
    const epoch = ++this.epoch; this.busy = true; this.previewReady = false;
    this.ticket = null; this.snapshot = null; this.intent = null; this.items = []; this.additions = []; this.selected = null; this.undo = null;
    this.targets = ['DIRECT', 'REJECT']; this.providers = []; this.choices = [];
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const ticket = ProfileTransactions.editTicket(context, this.file);
      const original = ProfileStore.getProfileContent(context, this.file);
      if (original === null) { throw new Error('原始配置不存在'); }
      const overlay = ProfileStore.getEnabledMerge(context, this.file);
      const draft = ProfileStore.readEditDraft(context, this.file).intent;
      const version = EffectiveVersions.read(context)?.Profiles[this.file];
      const region = version !== undefined ? EffectiveVersions.regionPlan(context, version) : null;
      const viewIntent = draft === null ? undefined : JSON.parse(JSON.stringify(draft)) as EditIntent;
      if (viewIntent !== undefined) { viewIntent.disabled = false; }
      const view = await ConfigEditor.list(context, original, overlay, ticket.activeVersion, undefined, viewIntent, region ?? undefined);
      if (!this.current(epoch)) { return; }
      this.ticket = ticket; this.original = original; this.localOverlay = overlay; this.region = region; this.snapshot = view;
      this.intent = draft ?? { schemaVersion: 1, revision: ticket.draftRevision || 'new-draft', sourceRevision: view.sourceRevision, operations: [] };
      this.targets = ['DIRECT', 'REJECT'].concat(view.sections.find((part: EditableSection) => part.section === 'proxy-groups')?.items.map((item: EditableItem) => item.name ?? '').filter((name: string) => name !== '') ?? []);
      this.providers = view.sections.find((part: EditableSection) => part.section === 'rule-providers')?.items.map((item: EditableItem) => item.name ?? '').filter((name: string) => name !== '') ?? [];
      this.choiceSection = ''; this.list(); this.message = '';
    } catch (_) { if (this.current(epoch)) { this.message = '无法打开编辑，请重试'; } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }
  private viewIntent(): EditIntent | undefined {
    if (this.intent === null) { return undefined; }
    const view = JSON.parse(JSON.stringify(this.intent)) as EditIntent;
    view.disabled = false;
    return view;
  }
  private async refreshList(context: common.UIAbilityContext, epoch: number): Promise<void> {
    if (this.ticket === null) { return; }
    const snapshot = await ConfigEditor.list(context, this.original, this.localOverlay, this.ticket.activeVersion,
      undefined, this.viewIntent(), this.region ?? undefined);
    if (!this.current(epoch)) { return; }
    this.snapshot = snapshot;
    const groups = snapshot.sections.find((part: EditableSection) => part.section === 'proxy-groups')?.items ?? [];
    const providers = snapshot.sections.find((part: EditableSection) => part.section === 'rule-providers')?.items ?? [];
    this.targets = ['DIRECT', 'REJECT'].concat(groups.map((item: EditableItem) => item.name ?? '').filter((name: string) => name !== ''));
    this.providers = providers.map((item: EditableItem) => item.name ?? '').filter((name: string) => name !== '');
    this.list();
  }

  private async open(item: EditableItem): Promise<void> {
    if (this.busy || !this.active || this.ticket === null) { return; }
    const epoch = ++this.epoch; this.busy = true;
    try {
      const value = await ConfigEditor.target(getContext(this) as common.UIAbilityContext,
        this.original, this.localOverlay, this.ticket.activeVersion, this.section, item.id, undefined, this.viewIntent(), this.region ?? undefined);
      if (!this.current(epoch)) { return; }
      this.liveProviderName = value.name ?? '';
      this.selected = value; this.isNew = false; this.providerState = ''; this.providerError = ''; this.showProviderError = false;
    } catch (_) { if (this.current(epoch)) { this.message = '配置已变化，请重新打开'; } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }
  private choose(section: string): void {
    if (this.busy) { return; }
    this.choiceSection = section;
    this.choices = this.snapshot?.sections.find((part: EditableSection) => part.section === section)?.items ?? [];
  }
  private async pick(item: EditableItem): Promise<void> {
    if (this.busy || this.ticket === null) { return; }
    const epoch = ++this.epoch; const section = this.choiceSection; this.busy = true;
    try {
      const value = await ConfigEditor.target(getContext(this) as common.UIAbilityContext,
        this.original, this.localOverlay, this.ticket.activeVersion, section, item.id, undefined, this.viewIntent(), this.region ?? undefined);
      if (!this.current(epoch)) { return; }
      const name = value.name ?? '';
      if (name !== '') {
        if (section === 'proxy-groups' && !this.targets.includes(name)) { this.targets = this.targets.concat([name]); }
        if (section === 'rule-providers' && !this.providers.includes(name)) { this.providers = this.providers.concat([name]); }
      }
      this.choices = []; this.choiceSection = '';
    } catch (_) { if (this.current(epoch)) { this.message = '无法读取此选项，请重试'; } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }
  private intentIdentity(intent: EditIntent | null): string {
    if (intent === null || (intent.operations.length === 0 && (intent.smartGroups === undefined || Object.keys(intent.smartGroups).length === 0))) { return ''; }
    const value = JSON.parse(JSON.stringify(intent)) as EditIntent;
    value.revision = ''; value.sourceRevision = ''; value.disabled = value.disabled === true;
    return JSON.stringify(value);
  }
  private async provider(update: boolean): Promise<void> {
    if (this.busy || this.selected === null || this.selected.name === undefined) { return; }
    if (this.ticket?.activeFile !== this.file || VpnController.status !== VpnStatus.Connected || ProfileTransactions.isBusy()) { this.message = '此订阅尚未运行'; return; }
    const context = getContext(this) as common.UIAbilityContext;
    const version = EffectiveVersions.read(context)?.Profiles[this.file];
    const published = version !== undefined ? EffectiveVersions.editIntent(context, version) : null;
    if (this.intentIdentity(this.intent) !== this.intentIdentity(published)) { this.message = '请先应用修改'; return; }
    const epoch = ++this.epoch; const name = this.liveProviderName; const ticket = this.ticket; this.busy = true;
    try {
      const observation = update ? await RuleProviderStatus.refresh(name) : await RuleProviderStatus.read(name);
      if (!this.current(epoch)) { return; }
      const current = ProfileTransactions.editTicket(getContext(this) as common.UIAbilityContext, this.file);
      if (current.activeVersion !== ticket.activeVersion || current.activeFile !== this.file || ProfileTransactions.isBusy()) { this.message = '运行配置已变化，请重试'; return; }
      this.providerState = observation.available ? `${observation.count} 条规则` : '运行状态未确认';
      if (observation.available && observation.references >= 0) { this.providerState += ` · 关联 ${observation.references} 条规则`; }
      this.providerError = observation.error; this.showProviderError = false;
      if (observation.error !== '') { this.message = update ? '更新失败，可重试' : '暂无法读取运行状态'; }
    } finally { if (this.current(epoch)) { this.busy = false; } }
  }
  private renameProvider(): void {
    if (this.busy || this.selected === null || this.rename.trim() === '' || /[,\r\n\u0000]/.test(this.rename)) { return; }
    this.edit({ id: `rename-${util.generateRandomUUID(true)}`, kind: 'rename', section: 'rule-providers',
      target: this.selected.item.id, expected: this.selected.item.revision, name: this.rename.trim() });
  }
  private add(): void {
    if (this.busy || this.section === 'dns') { return; }
    const empty: Record<string, Object> = {};
    this.selected = { item: { id: '', revision: '' }, missingFieldRevision: this.snapshot?.missingFieldRevision ?? '', value: this.section === 'rules' ? '' : empty };
    this.isNew = true; this.insertionBefore = this.items[0]?.id ?? '';
  }
  private async preview(next: EditIntent | null): Promise<void> {
    if (this.busy || !this.active || this.ticket === null) { return; }
    const epoch = ++this.epoch; const ticket = this.ticket; this.busy = true; this.previewReady = false;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      await ProfileTransactions.saveEditDraft(context, ticket, next);
      if (!this.current(epoch)) { return; }
      // Only this successful, still-current save authorizes capturing its new ticket.
      this.ticket = ProfileTransactions.editTicket(context, this.file);
      this.intent = ProfileStore.readEditDraft(context, this.file).intent;
      const result = await ProfileTransactions.previewEditDraft(context, this.ticket);
      if (!this.current(epoch)) { return; }
      await this.refreshList(context, epoch);
      if (!this.current(epoch)) { return; }
      this.previewReady = true;
      const sections = result.changes.map((change) => change.section).filter((name: string) => ['rules', 'rule-providers', 'dns', 'hosts'].includes(name));
      const labels = sections.map((name: string) => name === 'rules' ? '规则' : name === 'rule-providers' ? '规则源' : name === 'dns' ? 'DNS' : 'hosts');
      this.message = labels.length > 0 ? `${labels.join(' / ')} 已校验` : result.changes.length > 0 ? '变更已校验' : '没有变更';
    } catch (error) { if (this.current(epoch)) {
      const message = (error as Error).message;
      this.message = /未确认|恢复|变化|正在进行|不存在/.test(message) ? message : '变更未通过校验，可修改或撤销';
    } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }
  private edit(operation: EditOperation): void {
    if (this.intent === null || this.busy) { return; }
    if (operation.section === 'rules' && operation.kind === 'add' && operation.value !== undefined && RuleDnsForms.parseRule(operation.value)?.type === 'MATCH' &&
      this.items.some((item: EditableItem) => item.type === undefined)) { this.message = '无法读取最终规则，请重试'; return; }
    if (operation.section === 'rules' && operation.value !== undefined && RuleDnsForms.parseRule(operation.value)?.type === 'MATCH' &&
      (this.items.some((item: EditableItem) => item.type === 'MATCH' && item.id !== operation.target) ||
        this.additions.some((op: EditOperation) => RuleDnsForms.parseRule(op.value ?? '')?.type === 'MATCH' && op.id !== this.selected?.item.id))) { this.message = '已有最终规则，请编辑它'; return; }
    this.undo = JSON.parse(JSON.stringify(this.intent)) as EditIntent;
    if (this.isNew && this.selected !== null && this.selected.item.id !== '') { operation.id = this.selected!.item.id; }
    if (this.isNew && operation.section === 'rules' && operation.kind === 'add' && operation.value !== undefined &&
      RuleDnsForms.parseRule(operation.value)?.type !== 'MATCH' && operation.before === undefined) {
      // New user rules take precedence; no bulk reads of private conditions.
      operation.before = this.items[0]?.id ?? '';
    }
    this.preview(RuleDnsDraft.put(this.intent, operation));
  }
  private async apply(): Promise<void> {
    if (this.busy || !this.previewReady || this.ticket === null || !this.active) { return; }
    const epoch = ++this.epoch; const ticket = this.ticket; this.busy = true;
    try {
      const state = await ProfileTransactions.applyEditDraft(getContext(this) as common.UIAbilityContext, ticket);
      if (!this.current(epoch)) { return; }
      this.message = state === 'applied' ? '已应用' : '已保存'; this.previewReady = false;
      this.ticket = ProfileTransactions.editTicket(getContext(this) as common.UIAbilityContext, this.file);
    } catch (error) { if (this.current(epoch)) { this.previewReady = false; this.message = (error as Error).message; } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }
  private move(from: number, to: number): void {
    if (this.busy || this.section !== 'rules' || from === to || from < 0 || to < 0 ||
      from >= this.items.length || to >= this.items.length) { return; }
    const item = this.items[from];
    const final = this.items.find((entry: EditableItem) => entry.type === 'MATCH')?.id ?? '';
    if (item.type === 'MATCH' || item.id === final || (final !== '' && to >= this.items.findIndex((entry: EditableItem) => entry.id === final))) { this.message = '最终规则保持在末尾'; return; }
    const revised = this.items.slice(); revised.splice(from, 1); revised.splice(to, 0, item);
    const before = revised[to + 1]?.id ?? '';
    this.edit(RuleDnsForms.moveRule(`move-${util.generateRandomUUID(true)}`, item, before, final));
    this.items = revised;
  }
  private preset(recommended: boolean): void {
    if (this.intent === null || this.selected === null || this.busy) { return; }
    if (recommended) { this.edit(RuleDnsForms.recommendedDns(this.selected)); }
    else {
      this.undo = JSON.parse(JSON.stringify(this.intent)) as EditIntent;
      const next = JSON.parse(JSON.stringify(this.intent)) as EditIntent;
      next.operations = next.operations.filter((op: EditOperation) => op.section !== 'dns');
      this.preview(next);
    }
  }
  build() {
    Column({ space: 12 }) {
      if (this.selected !== null) {
        if (this.section === 'rules') {
          Row({ space: 12 }) {
            Button('选择策略组').enabled(!this.busy).onClick(() => this.choose('proxy-groups'))
            Button('选择规则源').enabled(!this.busy).onClick(() => this.choose('rule-providers'))
          }
          ForEach(this.choices, (item: EditableItem, index: number) => {
            Button(`${item.type ?? '选项'} ${index + 1}`).enabled(!this.busy).onClick(() => this.pick(item))
          }, (item: EditableItem) => item.id)
        }
        if (this.section === 'rule-providers' && !this.isNew) {
          Row({ space: 8 }) {
            Button('查看状态').enabled(!this.busy).onClick(() => this.provider(false))
            Button('更新').enabled(!this.busy).onClick(() => this.provider(true))
          }
          if (this.providerState !== '') { Text(this.providerState).fontSize(14) }
          if (this.providerError !== '') {
            Button('错误详情').onClick(() => { this.showProviderError = !this.showProviderError; })
            if (this.showProviderError) { Text(this.providerError).fontSize(14).fontColor(UI.error) }
          }
          Row({ space: 8 }) {
            TextInput({ placeholder: '新名称', text: this.rename }).onChange((value: string) => { this.rename = value; }).layoutWeight(1)
            Button('重命名').enabled(!this.busy).onClick(() => this.renameProvider())
          }
        }
        if (this.section === 'dns') {
          Row({ space: 12 }) {
            Button('默认').enabled(!this.busy).onClick(() => this.preset(false))
            Button('推荐').enabled(!this.busy).onClick(() => this.preset(true))
          }
        }
        RuleDnsEditForm({ section: this.section, selected: this.selected, isNew: this.isNew,
          targets: this.targets, providers: this.providers, positions: this.items, insertionBefore: this.insertionBefore, matchId: this.items.find((item: EditableItem) => item.type === 'MATCH')?.id ?? '',
          onOperation: (operation: EditOperation) => this.edit(operation), onClose: () => { this.selected = null; } }).layoutWeight(1)
      } else {
        Row({ space: 8 }) {
          Button('规则').onClick(() => { this.section = 'rules'; this.list(); })
          Button('规则源').onClick(() => { this.section = 'rule-providers'; this.list(); })
          Button('DNS').onClick(() => { this.section = 'dns'; this.list(); })
          Button('hosts').onClick(() => { this.section = 'hosts'; this.list(); })
        }.enabled(!this.busy)
        List({ space: 8 }) {
          ForEach(this.items, (item: EditableItem, index: number) => {
            ListItem() {
              Row() {
                Button(item.name ?? `${item.type ?? this.section} ${index + 1}`).layoutWeight(1).onClick(() => this.open(item))
                if (this.section !== 'dns') {
                  Button('删除').onClick(() => this.edit(RuleDnsForms.deleteItem(`delete-${util.generateRandomUUID(true)}`, this.section, item)))
                }
              }.enabled(!this.busy)
            }
          }, (item: EditableItem) => item.id).onMove((from: number, to: number) => this.move(from, to))
        }.layoutWeight(1)
        if (this.section !== 'dns') { Button('新增').enabled(!this.busy).onClick(() => this.add()) }
        if (this.previewReady) { Button('应用').enabled(!this.busy).onClick(() => this.apply()) }
        if (this.undo !== null) { Button('撤销').enabled(!this.busy).onClick(() => this.preview(this.undo)) }
        Button(this.intent?.disabled === true ? '启用修改' : '停用修改').enabled(!this.busy).onClick(() => {
          if (this.intent !== null) { const next = JSON.parse(JSON.stringify(this.intent)) as EditIntent; next.disabled = !next.disabled; this.preview(next); }
        })
      }
      if (this.snapshot === null && !this.busy) { Button('重试').onClick(() => this.load()) }
      if (this.busy) { LoadingProgress().width(24).height(24) }
      if (this.message !== '') { Text(this.message).fontSize(14).fontColor(UI.muted) }
    }.width('100%').height('100%').padding(16).backgroundColor(UI.paper)
  }
}
