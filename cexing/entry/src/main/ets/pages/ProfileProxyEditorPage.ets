import { ProfileApplyFeedback, ProfileApplyFailureKind } from '../lib/ProfileApplyFeedback';
import { ProfileApplyRecovery } from '../lib/ProfileApplyRecovery';
import { ProfileImportInput } from '../lib/ProfileImportInput';
import { ProxyEditorText } from '../lib/ProxyEditorText';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { NativeTheme as UI } from './NativeTheme';
import { EditableItem, EditTarget, EditOperation, EditIntent, EditIntentFailure } from '../lib/ConfigEditor';
import { ProfileProxyEditorModel } from '../lib/ProfileProxyEditorModel';
import { ProxyIntentEdits } from '../lib/ProxyIntentEdits';
import { ProxyMappingDraft } from '../lib/ProxyMappingForm';
import { ProxyMappingFormPage } from './ProxyMappingFormPage';
import { ProfileEditBus } from './ProfileEditPage';
import { ProxyProviderStatus, ProxyProviderNode } from '../lib/ProxyProviderStatus';

export class ProfileProxyEditorBus { static file: string = ''; }

class ProxyEditorRow {
  id: string;
  label: string;
  type: string;
  added: boolean;
  disabled: boolean = false;
  constructor(id: string, label: string, type: string, added: boolean) {
    this.id = id; this.label = label; this.type = type; this.added = added;
  }
}

class ProxySourceChoice {
  key: string;
  value: string;
  constructor(key: string, value: string) { this.key = key; this.value = value; }
}

@Component
export struct ProfileProxyEditorPage {
  @Prop @Watch('visibilityChanged') visible: boolean = false;
  @Consume('profileRevision') profileRevision: number;
  @Consume('nav') navStack: NavPathStack;
  @Consume('tabJump') tabJump: number;
  @State section: string = 'proxies';
  @State rows: ProxyEditorRow[] = [];
  @State query: string = '';
  @State sourceKey: string = 'all';
  @State sourceLabel: string = '';
  @State sourceChoices: ProxySourceChoice[] = [];
  @State sourceNodes: ProxyProviderNode[] = [];
  @State sourceCount: number = 0;
  @State sourceReady: boolean = false;
  @State visibleCount: number = 100;
  @State busy: boolean = false;
  @State error: string = '';
  @State private applyFailure: ProfileApplyFailureKind | '' = '';
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
  private newAction: string = '';
  private labels: Record<string, string> = {};
  private missingRevision: string = '';
  private epoch: number = 0;
  private active: boolean = false;

  private t(name: string, first?: string | number, second?: string | number, third?: string | number): string {
    return ProxyEditorText.text(getContext(this) as common.UIAbilityContext, name, first, second, third);
  }

  aboutToAppear(): void {
    this.file = ProfileProxyEditorBus.file;
    this.model = new ProfileProxyEditorModel(getContext(this) as common.UIAbilityContext, this.file);
    this.active = this.visible;
    if (this.active) { this.load(); }
  }
  aboutToDisappear(): void { this.sourceNodes = []; this.sourceReady = false; this.active = false; this.epoch++; this.model?.cancel(); }
  private visibilityChanged(): void {
    if (this.active === this.visible) { return; }
    this.active = this.visible; this.epoch++; this.model?.cancel(); this.formOpen = false; this.sourceNodes = []; this.sourceReady = false;
    if (this.active) { this.load(); }
  }
  private current(epoch: number): boolean { return this.active && epoch === this.epoch; }

  private async load(): Promise<void> {
    if (this.model === null) { return; }
    const epoch = ++this.epoch; this.busy = true;
    this.sourceKey = 'all'; this.sourceLabel = this.t('proxy_editor_all_sources'); this.sourceNodes = []; this.sourceReady = false;
    try {
      if (await this.model.load() && this.current(epoch)) {
        const snapshot = this.model.snapshot;
        const direct = snapshot?.sections.find((part) => part.section === 'proxies')?.items.length ?? 0;
        const sources = snapshot?.sections.find((part) => part.section === 'proxy-providers')?.items.length ?? 0;
        const added = this.model.workingIntent().operations.some((op: EditOperation) => op.kind === 'add' && op.section === 'proxies');
        if (this.section === 'proxies' && direct === 0 && sources > 0 && !added) { this.section = 'proxy-providers'; }
        this.sync(); this.applyFailure = ProfileApplyFeedback.recovery(getContext(this) as common.UIAbilityContext);
        this.error = this.applyFailure === '' ? '' : this.t(ProfileApplyFeedback.key(this.applyFailure));
      }
    }
    catch (_) { if (this.current(epoch)) { this.error = this.t('proxy_editor_load_failed'); } }
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
        `${item.type ?? this.t('proxy_editor_item')} ${index + 1}`, item.type ?? '', false)); }
    }
    for (const op of operations.filter((entry: EditOperation) => entry.section === this.section)) {
      if (op.kind === 'add') {
        const value = op.value as Record<string, Object>;
        const row = new ProxyEditorRow(op.id, op.name ?? String(value['name'] ?? this.t('proxy_editor_add')), String(value['type'] ?? ''), true);
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
    if (this.section === 'proxies') {
      for (const row of rows) { row.disabled = ProxyIntentEdits.nodeDisabled(intent, row.id, row.added); }
    }
    this.rows = rows;
    const choices: ProxySourceChoice[] = [new ProxySourceChoice('all', this.t('proxy_editor_all_sources')),
      new ProxySourceChoice('raw', this.t('proxy_editor_original')), new ProxySourceChoice('custom', this.t('proxy_editor_custom'))];
    const sources = model.snapshot.sections.find((part) => part.section === 'proxy-providers')?.items ?? [];
    for (const item of sources) {
      const name = operations.find((op: EditOperation) => op.kind === 'rename' && op.target === item.id)?.name ?? item.name;
      if (name !== undefined && !operations.some((op: EditOperation) => op.kind === 'delete' && op.target === item.id)) {
        choices.push(new ProxySourceChoice(`provider:${item.id}`, name));
      }
    }
    for (const operation of operations.filter((entry: EditOperation) => entry.kind === 'add' && entry.section === 'proxy-providers')) {
      choices.push(new ProxySourceChoice(`added:${operation.id}`, operation.name ?? this.t('proxy_editor_new_source')));
    }
    this.sourceChoices = choices;
    if (!choices.some((choice) => choice.key === this.sourceKey)) { this.sourceKey = 'all'; }
    this.sourceLabel = choices.find((choice) => choice.key === this.sourceKey)?.value ?? this.t('proxy_editor_all_sources');
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
    const sectionNames: Record<string, string> = { 'proxies': 'proxy_editor_nodes', 'proxy-groups': 'proxy_editor_groups', 'proxy-providers': 'proxy_editor_sources' };
    this.previewText = model.preview?.changes.map((change) => this.t('proxy_editor_change_count',
      this.t(sectionNames[change.section] ?? 'proxy_editor_config'), change.before, change.after)).join(' · ') ?? '';
    if (this.previewReady) {
      const smart = model.smartChanges.filter((change) => change.override || change.before !== change.after)
        .map((change) => this.t('proxy_editor_smart_type_change', change.before, change.after));
      this.previewText = [this.previewText, ...smart].filter((part) => part.length > 0).join(' · ');
    }
  }

  private isProviderSource(): boolean { return this.sourceKey.startsWith('provider:') || this.sourceKey.startsWith('added:'); }

  private filteredRows(): ProxyEditorRow[] {
    const source = this.section === 'proxies' ? this.sourceKey : 'all';
    return this.rows.filter((row: ProxyEditorRow) =>
      (source !== 'raw' || !row.added) && (source !== 'custom' || row.added) &&
      (row.label.includes(this.query) || row.type.includes(this.query)));
  }

  private shownRows(): ProxyEditorRow[] { return this.filteredRows().slice(0, this.visibleCount); }

  private moreRows(): void {
    const count = this.section === 'proxies' && this.isProviderSource() ? this.sourceNodes.filter((node: ProxyProviderNode) =>
      node.name.includes(this.query) || node.type.includes(this.query)).length : this.filteredRows().length;
    if (this.visibleCount < count) { this.visibleCount = Math.min(this.visibleCount + 100, count); }
  }

  private async chooseSource(index: number): Promise<void> {
    if (this.busy || this.model === null || index < 0 || index >= this.sourceChoices.length) { return; }
    const choice = this.sourceChoices[index];
    this.sourceKey = choice.key; this.sourceLabel = choice.value; this.sourceNodes = [];
    this.sourceReady = false; this.sourceCount = 0; this.visibleCount = 100; this.error = '';
    if (!this.isProviderSource()) { return; }
    const id = choice.key.slice(choice.key.indexOf(':') + 1);
    const source = choice.key.startsWith('provider:') ? this.model.snapshot?.sections.find((part) => part.section === 'proxy-providers')?.items.find((item) => item.id === id) : undefined;
    const added = this.model.workingIntent().operations.find((operation: EditOperation) =>
      operation.kind === 'add' && operation.section === 'proxy-providers' && operation.id === id);
    if (source === undefined && added === undefined) { return; }
    const value: Record<string, Object> = {};
    const item: EditableItem = source ?? { id: id, revision: '' };
    const target: EditTarget = { item: item, name: source?.name ?? added?.name, missingFieldRevision: this.missingRevision, value: value };
    const name = this.model.publishedProviderName(target, choice.key.startsWith('added:'));
    if (name === '') { this.error = this.t('proxy_editor_source_not_applied'); return; }
    const epoch = ++this.epoch; this.busy = true;
    try {
      const observation = await ProxyProviderStatus.observe(getContext(this) as common.UIAbilityContext,
        this.file, this.model.profileVersion(), name, false);
      if (!this.current(epoch)) { return; }
      this.sourceNodes = observation.nodes; this.sourceCount = observation.count;
      this.sourceReady = observation.available; this.error = ProxyEditorText.failure(getContext(this) as common.UIAbilityContext, observation.error);
    } catch (_) { if (this.current(epoch)) { this.error = this.t('proxy_editor_source_nodes_failed'); } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private async editSelectedSource(): Promise<void> {
    const id = this.sourceKey.slice(this.sourceKey.indexOf(':') + 1);
    const choice = this.sourceChoices.find((item) => item.key === this.sourceKey);
    if (this.busy || choice === undefined) { return; }
    this.section = 'proxy-providers'; this.sync();
    const row = this.rows.find((item: ProxyEditorRow) => item.id === id);
    if (row !== undefined) { await this.open(row); }
  }

  private async open(row: ProxyEditorRow): Promise<void> {
    if (this.busy || this.model === null || row.disabled) { return; }
    const epoch = ++this.epoch; this.busy = true; this.providerState = '';
    try {
      const intent = this.model.workingIntent(); this.newAction = '';
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
        const projected = await this.model.presentTarget(this.section, target);
        if (!this.current(epoch) || projected === null) { return; }
        this.formTarget = projected;
      }
      if (this.current(epoch)) { this.formOpen = true; this.error = ''; }
    } catch (_) { if (this.current(epoch)) { this.error = this.t('proxy_editor_item_failed'); } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private openOriginal(): void {
    if (!this.active || this.busy) { return; }
    const paths = this.navStack.getAllPathName();
    if (paths[paths.length - 1] === 'profileEdit') { return; }
    this.epoch++; this.model?.cancel(); this.formOpen = false;
    ProfileEditBus.current = this.file;
    this.navStack.pushPath({ name: 'profileEdit' });
  }

  private async provider(update: boolean): Promise<void> {
    const target = this.originalTarget ?? (this.selectedAdd !== '' ? this.formTarget : null);
    if (this.busy || this.model === null || target === null || this.section !== 'proxy-providers') { return; }
    const epoch = ++this.epoch; this.busy = true;
    try {
      const name = this.model.publishedProviderName(target, this.selectedAdd !== '');
      if (name === '') { this.error = this.t('proxy_editor_source_not_applied'); return; }
      const observation = await ProxyProviderStatus.observe(getContext(this) as common.UIAbilityContext,
        this.file, this.model.profileVersion(), name, update);
      if (!this.current(epoch)) { return; }
      this.providerState = observation.available ? this.t('proxy_editor_loaded_count', observation.count) +
        (observation.updatedAt > 0 ? ` · ${new Date(observation.updatedAt).toLocaleString()}` : '') : '';
      this.error = ProxyEditorText.failure(getContext(this) as common.UIAbilityContext, observation.error);
      if (observation.refreshed && observation.available) {
        promptAction.showToast({ message: this.t('proxy_editor_source_updated'), duration: 1800 });
      }
    } catch (_) { if (this.current(epoch)) { this.error = this.t('proxy_editor_source_status_failed'); } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private add(): void {
    if (this.busy) { return; }
    if (this.section === 'proxies') { this.sourceKey = 'custom'; this.sourceLabel = this.t('proxy_editor_custom'); }
    this.originalTarget = null; this.formTarget = null; this.selectedAdd = ''; this.newAction = ''; this.formOpen = true;
  }

  private previewFailure(intent: EditIntent, error: Error): string {
    const failure = error instanceof EditIntentFailure ? error as EditIntentFailure : null;
    const operation = failure !== null ? intent.operations[failure.operation] : intent.operations[intent.operations.length - 1];
    if (failure?.code === 'missing_target') { return this.t('proxy_editor_item_changed'); }
    if (failure?.code === 'conflict') { return this.t('proxy_editor_conflict'); }
    if (operation?.section === 'proxy-groups') { return this.t('proxy_editor_group_invalid'); }
    if (operation?.section === 'proxy-providers') { return this.t('proxy_editor_source_invalid'); }
    if (operation?.section === 'proxies') { return this.t('proxy_editor_node_invalid'); }
    return this.t('proxy_editor_preview_invalid');
  }

  private async save(next: EditIntent): Promise<void> {
    if (this.busy || this.model === null || this.needsRecovery()) { return; }
    const epoch = ++this.epoch; this.busy = true; this.previewReady = false;
    try {
      const ready = await this.model.save(next);
      if (!this.current(epoch)) { return; }
      this.sync(); this.formOpen = false; this.applyFailure = '';
      this.error = ready ? '' : this.t('proxy_editor_preview_failed');
    } catch (error) {
      if (this.current(epoch)) { this.sync(); this.error = this.previewFailure(next, error as Error); }
    } finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private async saveForm(draft: ProxyMappingDraft): Promise<void> {
    if (this.model === null || this.busy) { return; }
    let next = this.model.workingIntent();
    if (this.selectedAdd !== '') {
      next.operations = next.operations.map((op: EditOperation) => op.id === this.selectedAdd ?
        { id: op.id, kind: 'add', section: op.section, name: draft.name, value: draft.value, before: op.before } : op);
    } else {
      if (this.originalTarget === null && this.newAction === '') { this.newAction = util.generateRandomUUID(true); }
      next = ProxyIntentEdits.mapping(next, this.originalTarget, draft,
        this.originalTarget === null ? this.newAction : util.generateRandomUUID(true), this.missingRevision);
    }
    await this.save(next);
  }

  private async remove(row: ProxyEditorRow): Promise<void> {
    if (this.busy || this.model === null) { return; }
    const epoch = ++this.epoch;
    let used = false;
    AlertDialog.show({ title: this.t('proxy_editor_delete_confirm'), message: row.label,
      primaryButton: { value: this.t('proxy_editor_cancel'), action: () => { used = true; } },
      secondaryButton: { value: this.t('proxy_editor_delete'), action: async () => {
        if (used || !this.current(epoch) || this.busy || this.model === null) { return; }
        used = true;
        const intent = this.model.workingIntent();
        if (row.added) { await this.save(ProxyIntentEdits.removeAddition(intent, row.id)); }
        else {
          this.busy = true;
          try {
            const target = await this.model.target(this.section, row.id);
            if (!this.current(epoch) || target === null) { return; }
            this.busy = false;
            await this.save(ProxyIntentEdits.remove(intent, this.section, target, util.generateRandomUUID(true)));
          } catch (_) { if (this.current(epoch)) { this.error = this.t('proxy_editor_delete_failed'); } }
          finally { if (this.current(epoch)) { this.busy = false; } }
        }
      } } });
  }

  private async toggleNode(row: ProxyEditorRow): Promise<void> {
    if (this.busy || this.model === null || this.section !== 'proxies') { return; }
    const epoch = ++this.epoch;
    if (row.disabled) {
      await this.save(ProxyIntentEdits.enableNode(this.model.workingIntent(), row.id, row.added)); return;
    }
    let used = false;
    AlertDialog.show({ title: this.t('proxy_editor_disable_node_named', row.label), message: this.t('proxy_editor_disable_node_risk'),
      primaryButton: { value: this.t('proxy_editor_cancel'), action: () => { used = true; } },
      secondaryButton: { value: this.t('proxy_editor_disable_node'), action: async () => {
        if (used || !this.current(epoch) || this.busy || this.model === null || this.section !== 'proxies') { return; }
        used = true; this.busy = true;
        let next: EditIntent | null = null;
        try {
          const target = await this.model.nodeTarget(row.id, row.added);
          if (!this.current(epoch) || target === null || this.section !== 'proxies') { return; }
          next = ProxyIntentEdits.disableNode(this.model.workingIntent(), target,
            row.added ? `${row.id}:disable` : util.generateRandomUUID(true));
        } catch (_) { if (this.current(epoch)) { this.error = this.t('proxy_editor_node_state_failed'); } }
        finally { if (this.current(epoch)) { this.busy = false; } }
        if (next !== null && this.current(epoch)) { await this.save(next); }
      } } });
  }

  private moveHandler(): OnMoveHandler | undefined {
    if (this.busy || this.query !== '' || this.section === 'proxy-providers' ||
      (this.section === 'proxies' && this.sourceKey !== 'all')) { return undefined; }
    return (from: number, to: number): void => { this.moveRow(from, to); };
  }

  private async moveRow(from: number, to: number): Promise<void> {
    if (this.section === 'proxies' && this.sourceKey !== 'all') { return; }
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

  private async smart(row: ProxyEditorRow): Promise<void> {
    if (this.busy || this.model === null || row.added) { return; }
    const epoch = ++this.epoch; this.busy = true;
    let next: EditIntent | null = null;
    try {
      const choices = await this.model.smartChoices();
      if (!this.current(epoch) || choices === null) { return; }
      const choice = choices.find((entry) => entry.choiceId === row.id);
      if (choice === undefined) { this.error = this.t('proxy_editor_smart_unsupported'); return; }
      const result = await promptAction.showDialog({ title: row.label,
        message: this.t('proxy_editor_smart_type_change', choice.before, choice.after), buttons: [{ text: this.t('proxy_editor_follow_global'), color: $r('app.color.ui_muted') },
          { text: this.t('proxy_editor_enable'), color: $r('app.color.ui_accent_text') }, { text: this.t('proxy_editor_keep_type'), color: $r('app.color.ui_muted') }] });
      if (!this.current(epoch)) { return; }
      next = this.model.workingIntent();
      if (next.smartGroups === undefined) { next.smartGroups = {}; }
      if (result.index === 0) {
        const overrides: Record<string, boolean> = {};
        for (const id of Object.keys(next.smartGroups)) { if (id !== choice.choiceId) { overrides[id] = next.smartGroups[id]; } }
        next.smartGroups = overrides;
      }
      else if (result.index === 1 || result.index === 2) { next.smartGroups[choice.choiceId] = result.index === 1; }
      else { next = null; }
    } catch (_) { if (this.current(epoch)) { this.error = this.t('proxy_editor_smart_failed'); } }
    finally { if (this.current(epoch)) { this.busy = false; } }
    if (next !== null && this.current(epoch)) { await this.save(next); }
  }

  private async undo(): Promise<void> {
    if (this.busy || this.model === null || !this.model.canUndo()) { return; }
    if (!this.model.undoNeedsConfirmation()) { await this.performUndo(false); return; }
    const epoch = ++this.epoch; let used = false;
    AlertDialog.show({ title: this.t('proxy_editor_undo'), message: this.t('proxy_editor_restore_draft'),
      primaryButton: { value: this.t('proxy_editor_cancel'), action: () => { used = true; } },
      secondaryButton: { value: this.t('proxy_editor_restore'), action: async () => {
        if (used || !this.current(epoch) || this.busy || this.model === null) { return; }
        used = true; await this.performUndo(true);
      } } });
  }

  private async performUndo(restore: boolean): Promise<void> {
    if (this.busy || this.model === null) { return; }
    const epoch = ++this.epoch; this.busy = true;
    try {
      if (restore) { await this.model.reset(); } else { await this.model.undo(); }
      if (this.current(epoch)) { this.sync(); this.error = ''; }
    }
    catch (_) { if (this.current(epoch)) { this.error = this.t('proxy_editor_undo_failed'); } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private async inspect(): Promise<void> {
    if (this.busy || this.model === null || this.needsRecovery()) { return; }
    const epoch = ++this.epoch; this.busy = true;
    try { await this.model.previewSaved(); if (this.current(epoch)) { this.sync(); this.error = ''; } }
    catch (_) { if (this.current(epoch)) { this.previewReady = false; this.error = this.t('proxy_editor_preview_invalid'); } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private async apply(): Promise<void> {
    if (this.busy || this.model === null || this.needsRecovery()) { return; }
    const epoch = ++this.epoch; this.busy = true;
    try {
      const result = await this.model.apply();
      if (!this.current(epoch) || result === null) { return; }
      this.profileRevision++;
      promptAction.showToast({ message: result === 'applied' ? this.t('proxy_editor_applied') : this.t('proxy_editor_saved'), duration: 1800 });
      this.previewReady = false;
      this.load();
    } catch (error) { if (this.current(epoch)) {
      this.previewReady = false; this.profileRevision++;
      const kind = ProfileApplyFeedback.classify((error as Error).message);
      this.applyFailure = ProfileApplyFeedback.recovery(getContext(this) as common.UIAbilityContext) === 'unconfirmed' ? 'unconfirmed' : kind;
      this.error = this.t(ProfileApplyFeedback.key(this.applyFailure));
    } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private needsRecovery(): boolean {
    return this.applyFailure === 'unconfirmed' || this.applyFailure === 'committed-pending';
  }

  private async recoverApply(): Promise<void> {
    if (this.busy || !this.active || !this.needsRecovery()) { return; }
    const epoch = ++this.epoch; this.busy = true;
    try {
      const accepted = await ProfileApplyRecovery.reconnect(getContext(this) as common.UIAbilityContext, () => this.current(epoch));
      if (!this.current(epoch) || accepted === null) { return; }
      if (accepted) {
        this.applyFailure = ''; this.error = ''; this.profileRevision++;
        promptAction.showToast({ message: this.t('apply_feedback_starting'), duration: 1800 });
        if (!ProfileImportInput.hasPending()) { this.tabJump = 0; }
        this.navStack.clear();
      } else { this.error = this.t('apply_feedback_recovery_failed'); }
    } catch (_) { if (this.current(epoch)) { this.error = this.t('apply_feedback_recovery_failed'); } }
    finally { if (this.current(epoch)) { this.busy = false; } }
  }

  private repairSelection(): void {
    if (!this.active || this.busy || this.applyFailure !== 'selection-required') { return; }
    this.navStack.pushPath({ name: 'zashboard' });
  }

  build() {
    Column({ space: 12 }) {
      if (this.formOpen) {
        if (this.section === 'proxy-providers' && (this.originalTarget !== null || this.selectedAdd !== '')) {
          Row({ space: 8 }) {
            Button($r('app.string.proxy_editor_view_status')).constraintSize({ minHeight: 44 }).enabled(!this.busy).onClick(() => { this.provider(false); })
            Button($r('app.string.proxy_editor_update_source')).constraintSize({ minHeight: 44 }).enabled(!this.busy).onClick(() => { this.provider(true); })
          }
          if (this.providerState !== '') { Text(this.providerState).fontSize(13).fontColor(UI.muted).width('100%') }
        }
        ProxyMappingFormPage({ busy: this.busy, section: this.section, target: this.formTarget, names: this.names, providerNames: this.providers,
          onDraft: (draft: ProxyMappingDraft) => this.saveForm(draft), onOriginal: () => { this.openOriginal(); }, onCancel: () => { this.epoch++; this.model?.cancel(); this.formOpen = false; this.sourceNodes = []; this.sourceReady = false; this.busy = false; } }).layoutWeight(1)
      } else {
        Row({ space: 8 }) {
          Button($r('app.string.proxy_editor_nodes')).constraintSize({ minHeight: 44 }).accessibilitySelected(this.section === 'proxies').onClick(() => { this.section = 'proxies'; this.sync(); })
          Button($r('app.string.proxy_editor_sources')).constraintSize({ minHeight: 44 }).accessibilitySelected(this.section === 'proxy-providers').onClick(() => { this.section = 'proxy-providers'; this.sync(); })
          Button($r('app.string.proxy_editor_groups')).constraintSize({ minHeight: 44 }).accessibilitySelected(this.section === 'proxy-groups').onClick(() => { this.section = 'proxy-groups'; this.sync(); })
        }.enabled(!this.busy)
        if (this.disabled) { Text($r('app.string.proxy_editor_edits_disabled')).fontSize(13).fontColor(UI.muted).width('100%') }
        if (this.section === 'proxies') {
          Select(this.sourceChoices).accessibilityText($r('app.string.proxy_editor_source_picker')).constraintSize({ minHeight: 44 }).value(this.sourceLabel).enabled(!this.busy)
            .onSelect((index: number) => { this.chooseSource(index); })
        }
        Search({ value: this.query, placeholder: this.t('proxy_editor_search') }).onChange((value: string) => { this.query = value; this.visibleCount = 100; })
        if (this.section === 'proxies' && this.isProviderSource()) {
          Row({ space: 8 }) {
            if (this.sourceReady) { Text(this.t('proxy_editor_loaded_count', this.sourceCount)).fontSize(13).fontColor(UI.muted).layoutWeight(1) }
            Button($r('app.string.proxy_editor_source_settings')).constraintSize({ minHeight: 44 }).enabled(!this.busy).onClick(() => { this.editSelectedSource(); })
            Button($r('app.string.proxy_editor_refresh')).constraintSize({ minHeight: 44 }).enabled(!this.busy).onClick(() => { this.chooseSource(this.sourceChoices.findIndex((item) => item.key === this.sourceKey)); })
          }
          List({ space: 8 }) {
            ForEach(this.sourceNodes.filter((node: ProxyProviderNode) => node.name.includes(this.query) || node.type.includes(this.query))
              .slice(0, this.visibleCount), (node: ProxyProviderNode) => {
              ListItem() { Row({ space: 8 }) { Text(node.name).fontColor(UI.ink).layoutWeight(1); Text(node.type).fontSize(12).fontColor(UI.muted) }.width('100%').padding(12) }
            }, (_node: ProxyProviderNode, index: number) => `${this.sourceKey}:${index}`)
          }.width('100%').layoutWeight(1).onReachEnd(() => { this.moreRows(); })
        } else {
        List({ space: 8 }) {
          ForEach(this.shownRows(), (row: ProxyEditorRow) => {
            ListItem() {
              Row({ space: 8 }) {
                Button(row.label).constraintSize({ minHeight: 44 }).layoutWeight(1).enabled(!row.disabled).onClick(() => { this.open(row); })
                if (this.section === 'proxies') {
                  Button(row.disabled ? this.t('proxy_editor_enable_node') : this.t('proxy_editor_disable_node'))
                    .constraintSize({ minHeight: 44 }).accessibilityText(this.t(row.disabled ?
                      'proxy_editor_enable_node_named' : 'proxy_editor_disable_node_named', row.label))
                    .onClick(() => { this.toggleNode(row); })
                }
                if (this.section === 'proxy-groups' && !row.added) {
                  Button($r('app.string.proxy_editor_smart')).constraintSize({ minHeight: 44 }).accessibilityText(this.t('proxy_editor_smart_named', row.label)).onClick(() => { this.smart(row); })
                }
                if (this.moveHandler() !== undefined) { Text('≡').accessibilityLevel('no').fontSize(20).fontColor(UI.muted) }
                Button($r('app.string.proxy_editor_delete')).constraintSize({ minHeight: 44 }).accessibilityText(this.t('proxy_editor_delete_named', row.label)).onClick(() => { this.remove(row); })
              }.enabled(!this.busy && !this.needsRecovery())
            }
          }, (row: ProxyEditorRow) => row.id).onMove(this.moveHandler())
        }.width('100%').layoutWeight(1).onReachEnd(() => { this.moreRows(); })
        }
        Button($r('app.string.proxy_editor_add')).constraintSize({ minHeight: 44 }).width('100%').constraintSize({ minHeight: 48 }).enabled(!this.busy && !this.needsRecovery()).onClick(() => { this.add(); })
        Row({ space: 8 }) {
          Button($r('app.string.proxy_editor_undo')).constraintSize({ minHeight: 44 }).enabled(!this.busy && !this.needsRecovery() && (this.model?.canUndo() ?? false)).onClick(() => { this.undo(); })
          Button(this.disabled ? this.t('proxy_editor_enable_edits') : this.t('proxy_editor_disable_edits')).constraintSize({ minHeight: 44 }).enabled(!this.busy && !this.needsRecovery()).onClick(() => {
            if (this.model !== null) { const next = this.model.workingIntent(); next.disabled = !next.disabled; this.save(next); }
          })
          if (!this.previewReady && !this.needsRecovery()) { Button($r('app.string.proxy_editor_preview')).constraintSize({ minHeight: 44 }).enabled(!this.busy).onClick(() => { this.inspect(); }) }
          if (this.previewReady && !this.needsRecovery()) { Button($r('app.string.proxy_editor_apply')).constraintSize({ minHeight: 44 }).enabled(!this.busy).onClick(() => { this.apply(); }) }
        }
        if (this.renameReferences) { Text($r('app.string.proxy_editor_rename_refs')).fontSize(13).fontColor(UI.muted).width('100%') }
        if (this.previewText !== '') { Text(this.previewText).fontSize(13).fontColor(UI.muted) }
        if (this.model?.snapshot === null && !this.busy) { Button($r('app.string.proxy_editor_retry')).constraintSize({ minHeight: 44 }).onClick(() => { this.load(); }) }
      }
      if (this.busy) { LoadingProgress().accessibilityText($r('app.string.proxy_editor_busy')).width(28).height(28) }
      if (this.error !== '') {
        Text(this.error).fontSize(14).fontColor(UI.error).width('100%')
        if (this.needsRecovery()) {
          Button($r('app.string.apply_feedback_reconnect')).constraintSize({ minHeight: 44 }).enabled(!this.busy)
            .onClick(() => { this.recoverApply(); })
        } else if (this.applyFailure === 'selection-required') {
          Button($r('app.string.apply_feedback_panel')).constraintSize({ minHeight: 44 }).enabled(!this.busy)
            .onClick(() => { this.repairSelection(); })
        }
        Button($r('app.string.proxy_editor_reload')).constraintSize({ minHeight: 44 }).enabled(!this.busy).onClick(() => { this.load(); })
      }
    }.width('100%').height('100%').padding(16).backgroundColor(UI.paper)
  }
}
