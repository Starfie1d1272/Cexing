import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { NativeTheme as UI } from './NativeTheme';
import { EditableItem, EditTarget, EditOperation, EditIntent } from '../lib/ConfigEditor';
import { ProfileProxyEditorModel } from '../lib/ProfileProxyEditorModel';
import { ProxyIntentEdits } from '../lib/ProxyIntentEdits';
import { ProxyMappingDraft } from '../lib/ProxyMappingForm';
import { ProxyMappingFormPage } from './ProxyMappingFormPage';
import { ProxyProviderStatus } from '../lib/ProxyProviderStatus';

export class ProfileProxyEditorBus { static file: string = ''; }

class ProxyEditorRow {
  id: string;
  label: string;
  type: string;
  added: boolean;
  constructor(id: string, label: string, type: string, added: boolean) {
    this.id = id; this.label = label; this.type = type; this.added = added;
  }
}

@Component
export struct ProfileProxyEditorPage {
  @Prop @Watch('visibilityChanged') visible: boolean = false;
  @Consume('profileRevision') profileRevision: number;
  @State section: string = 'proxies';
  @State rows: ProxyEditorRow[] = [];
  @State query: string = '';
  @State busy: boolean = false;
  @State error: string = '';
  @State formOpen: boolean = false;
  @State formTarget: EditTarget | null = null;
  @State names: string[] = [];
  @State providers: string[] = [];
  @State previewReady: boolean = false;
  @State renameReferences: boolean = false;
  @State disabled: boolean = false;
  @State previewText: string = '';
  @State providerState: string = '';
  private file: string = '';
  private model: ProfileProxyEditorModel | null = null;
  private originalTarget: EditTarget | null = null;
  private selectedAdd: string = '';
  private labels: Record<string, string> = {};
  private missingRevision: string = '';
  private epoch: number = 0;
  private active: boolean = false;

  aboutToAppear(): void {
    this.file = ProfileProxyEditorBus.file;
    this.model = new ProfileProxyEditorModel(getContext(this) as common.UIAbilityContext, this.file);
    this.active = this.visible;
    if (this.active) { this.load(); }
  }
  aboutToDisappear(): void { this.active = false; this.epoch++; this.model?.cancel(); }
  private visibilityChanged(): void {
    if (this.active === this.visible) { return; }
    this.active = this.visible; this.epoch++; this.model?.cancel(); this.formOpen = false;
    if (this.active) { this.load(); }
  }
  private current(epoch: number): boolean { return this.active && epoch === this.epoch; }

  private async load(): Promise<void> {
    if (this.model === null) { return; }
    const epoch = ++this.epoch; this.busy = true;
    try {
      if (await this.model.load() && this.current(epoch)) {
        const snapshot = this.model.snapshot;
        const direct = snapshot?.sections.find((part) => part.section === 'proxies')?.items.length ?? 0;
        const sources = snapshot?.sections.find((part) => part.section === 'proxy-providers')?.items.length ?? 0;
        const added = this.model.workingIntent().operations.some((op: EditOperation) => op.kind === 'add' && op.section === 'proxies');
        if (this.section === 'proxies' && direct === 0 && sources > 0 && !added) { this.section = 'proxy-providers'; }
        this.sync(); this.error = '';
      }
    }
    catch (_) { if (this.current(epoch)) { this.error = '配置读取失败，请重试'; } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private sync(): void {
    const model = this.model;
    if (model?.snapshot === null || model === null) { return; }
    const intent = model.workingIntent();
    const operations = intent.operations;
    this.disabled = intent.disabled === true;
    this.missingRevision = model.snapshot.missingFieldRevision;
    let rows: ProxyEditorRow[] = [];
    const items = model.snapshot.sections.find((part) => part.section === this.section)?.items ?? [];
    for (let index = 0; index < items.length; index++) {
      const item = items[index];
      const renamed = operations.find((op: EditOperation) => op.kind === 'rename' && op.target === item.id);
      const deleted = operations.some((op: EditOperation) => op.kind === 'delete' && op.target === item.id);
      if (!deleted) { rows.push(new ProxyEditorRow(item.id, renamed?.name ?? item.name ?? this.labels[item.id] ??
        `${item.type ?? '项目'} ${index + 1}`, item.type ?? '', false)); }
    }
    for (const op of operations.filter((entry: EditOperation) => entry.section === this.section)) {
      if (op.kind === 'add') {
        const value = op.value as Record<string, Object>;
        const row = new ProxyEditorRow(op.id, op.name ?? String(value['name'] ?? '新增'), String(value['type'] ?? ''), true);
        const before = rows.findIndex((entry: ProxyEditorRow) => entry.id === op.before);
        rows.splice(before < 0 ? rows.length : before, 0, row);
      } else if (op.kind === 'move') {
        const from = rows.findIndex((entry: ProxyEditorRow) => entry.id === op.target);
        if (from < 0) { continue; }
        const moved = rows.splice(from, 1)[0];
        const before = rows.findIndex((entry: ProxyEditorRow) => entry.id === op.before);
        rows.splice(before < 0 ? rows.length : before, 0, moved);
      }
    }
    this.rows = rows;
    const names: string[] = [];
    const providers: string[] = [];
    for (const part of model.snapshot.sections) {
      if (!['proxies', 'proxy-groups', 'proxy-providers'].includes(part.section)) { continue; }
      for (const item of part.items) {
        if (operations.some((op: EditOperation) => op.kind === 'delete' && op.target === item.id)) { continue; }
        const renamed = operations.find((op: EditOperation) => op.kind === 'rename' && op.target === item.id);
        const name = renamed?.name ?? item.name ?? this.labels[item.id];
        if (name === undefined) { continue; }
        if (part.section === 'proxy-providers') { providers.push(name); } else { names.push(name); }
      }
    }
    for (const op of operations.filter((entry: EditOperation) => entry.kind === 'add')) {
      const name = op.name ?? String((op.value as Record<string, Object>)?.['name'] ?? '');
      if (op.section === 'proxy-providers') { providers.push(name); }
      else if (op.section === 'proxies' || op.section === 'proxy-groups') { names.push(name); }
    }
    this.names = names; this.providers = providers;
    this.previewReady = model.preview !== null;
    this.renameReferences = this.previewReady && operations.some((op: EditOperation) => op.kind === 'rename');
    this.previewText = model.preview?.changes.map((change) => `${change.section} ${change.before} → ${change.after}`).join(' · ') ?? '';
  }

  private async open(row: ProxyEditorRow): Promise<void> {
    if (this.busy || this.model === null) { return; }
    const epoch = ++this.epoch; this.busy = true; this.providerState = '';
    try {
      const intent = this.model.workingIntent();
      if (row.added) {
        const operation = intent.operations.find((op: EditOperation) => op.id === row.id);
        if (operation?.value === undefined) { return; }
        this.selectedAdd = row.id; this.originalTarget = null;
        this.formTarget = { item: { id: row.id, revision: '' }, missingFieldRevision: this.missingRevision, name: operation.name, value: operation.value };
      } else {
        const target = await this.model.target(this.section, row.id);
        if (!this.current(epoch) || target === null) { return; }
        this.originalTarget = target; this.selectedAdd = '';
        this.labels[target.item.id] = target.name ?? String((target.value as Record<string, Object>)['name'] ?? row.label);
        this.formTarget = ProxyIntentEdits.shownTarget(target, intent, this.section);
      }
      if (this.current(epoch)) { this.formOpen = true; this.error = ''; }
    } catch (_) { if (this.current(epoch)) { this.error = '项目读取失败，请重试'; } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private async provider(update: boolean): Promise<void> {
    if (this.busy || this.model === null || this.originalTarget === null || this.section !== 'proxy-providers') { return; }
    const epoch = ++this.epoch; this.busy = true;
    try {
      const name = this.model.publishedProviderName(this.originalTarget);
      if (name === '') { this.error = '此来源尚未应用'; return; }
      const observation = await ProxyProviderStatus.observe(getContext(this) as common.UIAbilityContext,
        this.file, this.model.profileVersion(), name, update);
      if (!this.current(epoch)) { return; }
      this.providerState = observation.available ? `已加载 ${observation.count} 个节点` +
        (observation.updatedAt > 0 ? ` · ${new Date(observation.updatedAt).toLocaleString()}` : '') : '';
      this.error = observation.error;
      if (observation.refreshed && observation.available) {
        promptAction.showToast({ message: '来源已更新', duration: 1800 });
      }
    } catch (_) { if (this.current(epoch)) { this.error = '来源状态读取失败，请重试'; } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private add(): void {
    if (this.busy) { return; }
    this.originalTarget = null; this.formTarget = null; this.selectedAdd = ''; this.formOpen = true;
  }

  private async save(next: EditIntent): Promise<void> {
    if (this.busy || this.model === null) { return; }
    const epoch = ++this.epoch; this.busy = true; this.previewReady = false;
    try {
      const ready = await this.model.save(next);
      if (!this.current(epoch)) { return; }
      this.sync(); this.formOpen = false;
      this.error = ready ? '' : '预览未完成，请重试';
    } catch (_) {
      if (this.current(epoch)) { this.sync(); this.error = '预览未通过，请检查修改或撤销'; }
    } finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private async saveForm(draft: ProxyMappingDraft): Promise<void> {
    if (this.model === null || this.busy) { return; }
    let next = this.model.workingIntent();
    if (this.selectedAdd !== '') {
      next.operations = next.operations.map((op: EditOperation) => op.id === this.selectedAdd ?
        { id: op.id, kind: 'add', section: op.section, name: draft.name, value: draft.value, before: op.before } : op);
    } else {
      next = ProxyIntentEdits.mapping(next, this.originalTarget, draft, util.generateRandomUUID(true), this.missingRevision);
    }
    await this.save(next);
  }

  private async remove(row: ProxyEditorRow): Promise<void> {
    if (this.busy || this.model === null) { return; }
    const epoch = ++this.epoch;
    let used = false;
    AlertDialog.show({ title: '删除项目？', message: row.label,
      primaryButton: { value: '取消', action: () => { used = true; } },
      secondaryButton: { value: '删除', action: async () => {
        if (used || !this.current(epoch) || this.busy || this.model === null) { return; }
        used = true;
        const intent = this.model.workingIntent();
        if (row.added) { intent.operations = intent.operations.filter((op: EditOperation) => op.id !== row.id); await this.save(intent); }
        else {
          this.busy = true;
          try {
            const target = await this.model.target(this.section, row.id);
            if (!this.current(epoch) || target === null) { return; }
            this.busy = false;
            await this.save(ProxyIntentEdits.remove(intent, this.section, target, util.generateRandomUUID(true)));
          } catch (_) { if (this.current(epoch)) { this.error = '删除未完成，请重试'; } }
          finally { if (this.current(epoch)) { this.busy = false; } }
        }
      } } });
  }

  private async moveRow(from: number, to: number): Promise<void> {
    if (this.busy || this.model === null || this.query !== '' || this.section === 'proxy-providers' ||
      from === to || from < 0 || to < 0 || from >= this.rows.length || to >= this.rows.length) { return; }
    const revised = this.rows.slice();
    const moved = revised.splice(from, 1)[0]; revised.splice(to, 0, moved);
    let next = this.model.workingIntent();
    if (!moved.added) {
      const before = revised.slice(to + 1).find((row: ProxyEditorRow) => !row.added)?.id ?? '';
      next = ProxyIntentEdits.move(next, this.section, moved.id, before, util.generateRandomUUID(true));
    }
    // New additions use their declared before anchor, never a guessed compiler ID.
    const additions: EditOperation[] = [];
    for (let index = 0; index < revised.length; index++) {
      const row = revised[index];
      if (!row.added) { continue; }
      const source = next.operations.find((op: EditOperation) => op.id === row.id);
      if (source !== undefined) {
        const operation = JSON.parse(JSON.stringify(source)) as EditOperation;
        operation.before = revised.slice(index + 1).find((entry: ProxyEditorRow) => !entry.added)?.id ?? '';
        additions.push(operation);
      }
    }
    let additionIndex = 0;
    next.operations = next.operations.map((op: EditOperation) =>
      op.section === this.section && op.kind === 'add' ? additions[additionIndex++] : op);
    await this.save(next);
  }

  private async undo(): Promise<void> {
    if (this.busy || this.model === null) { return; }
    const epoch = ++this.epoch; this.busy = true;
    try { await this.model.undo(); if (this.current(epoch)) { this.sync(); this.error = ''; } }
    catch (_) { if (this.current(epoch)) { this.error = '撤销未完成，请重试'; } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private async apply(): Promise<void> {
    if (this.busy || this.model === null) { return; }
    const epoch = ++this.epoch; this.busy = true;
    try {
      const result = await this.model.apply();
      if (!this.current(epoch) || result === null) { return; }
      this.profileRevision++;
      promptAction.showToast({ message: result === 'applied' ? '已应用' : '已保存', duration: 1800 });
      this.previewReady = false;
      this.load();
    } catch (_) { if (this.current(epoch)) { this.error = '应用未完成，请检查配置或连接状态后重试'; } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  build() {
    Column({ space: 12 }) {
      if (this.formOpen) {
        if (this.section === 'proxy-providers' && this.originalTarget !== null) {
          Row({ space: 8 }) {
            Button('查看状态').enabled(!this.busy).onClick(() => { this.provider(false); })
            Button('更新来源').enabled(!this.busy).onClick(() => { this.provider(true); })
          }
          if (this.providerState !== '') { Text(this.providerState).fontSize(13).fontColor(UI.muted).width('100%') }
        }
        ProxyMappingFormPage({ busy: this.busy, section: this.section, target: this.formTarget, names: this.names, providerNames: this.providers,
          onDraft: (draft: ProxyMappingDraft) => this.saveForm(draft), onCancel: () => { this.epoch++; this.model?.cancel(); this.formOpen = false; this.busy = false; } }).layoutWeight(1)
      } else {
        Row({ space: 8 }) {
          Button('节点').onClick(() => { this.section = 'proxies'; this.sync(); })
          Button('订阅来源').onClick(() => { this.section = 'proxy-providers'; this.sync(); })
          Button('策略组').onClick(() => { this.section = 'proxy-groups'; this.sync(); })
        }.enabled(!this.busy)
        if (this.disabled) { Text('修改已停用').fontSize(13).fontColor(UI.muted).width('100%') }
        Search({ value: this.query, placeholder: '搜索' }).onChange((value: string) => { this.query = value; })
        List({ space: 8 }) {
          ForEach(this.rows.filter((row: ProxyEditorRow) => row.label.includes(this.query) || row.type.includes(this.query)), (row: ProxyEditorRow) => {
            ListItem() {
              Row({ space: 8 }) {
                Button(row.label).layoutWeight(1).onClick(() => { this.open(row); })
                Button('删除').onClick(() => { this.remove(row); })
              }.enabled(!this.busy)
            }
          }, (row: ProxyEditorRow) => row.id).onMove((from: number, to: number) => { this.moveRow(from, to); })
        }.width('100%').layoutWeight(1)
        Button('新增').width('100%').height(48).enabled(!this.busy).onClick(() => { this.add(); })
        Row({ space: 8 }) {
          Button('撤销').enabled(!this.busy).onClick(() => { this.undo(); })
          Button(this.disabled ? '启用修改' : '停用修改').enabled(!this.busy).onClick(() => {
            if (this.model !== null) { const next = this.model.workingIntent(); next.disabled = !next.disabled; this.save(next); }
          })
          if (this.previewReady) { Button('应用').enabled(!this.busy).onClick(() => { this.apply(); }) }
        }
        if (this.renameReferences) { Text('名称修改会同步更新引用').fontSize(13).fontColor(UI.muted).width('100%') }
        if (this.previewText !== '') { Text(this.previewText).fontSize(13).fontColor(UI.muted) }
        if (this.model?.snapshot === null && !this.busy) { Button('重试').onClick(() => { this.load(); }) }
      }
      if (this.busy) { LoadingProgress().width(28).height(28) }
      if (this.error !== '') {
        Text(this.error).fontSize(14).fontColor(UI.error).width('100%')
        Button('重新读取').enabled(!this.busy).onClick(() => { this.load(); })
      }
    }.width('100%').height('100%').padding(16).backgroundColor(UI.paper)
  }
}
