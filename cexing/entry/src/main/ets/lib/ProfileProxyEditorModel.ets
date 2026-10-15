import { common } from '@kit.AbilityKit';
import { ConfigEditor, EditableSnapshot, EditIntent, EditTarget, SmartGroupChange, EditorDraftHost, EditorDraftPreview } from './ConfigEditor';
import { ProfileStore } from './ProfileStore';
import { ProfileTransactions, EditTicket, ProfileApplyState } from './ProfileTransactions';
import { MergePreview } from './CoreValidator';
import { EffectiveVersions, RegionPlan } from './EffectiveVersions';
import { Settings } from './Settings';
import { EditorDraftHosts } from './EditorDraftHosts';

/** UI session over the published #164/#172 APIs. Never writes a sidecar directly. */
export class ProfileProxyEditorModel {
  snapshot: EditableSnapshot | null = null;
  intent: EditIntent | null = null;
  preview: MergePreview | null = null;
  busy: boolean = false;
  private context: common.Context;
  private file: string;
  private ticket: EditTicket | null = null;
  private original: string = '';
  private overlay: string = '';
  private region: RegionPlan | undefined = undefined;
  private generation: number = 0;
  private editor: EditorDraftHost | null = null;
  private confirmed: EditorDraftPreview | null = null;
  private history: Array<EditIntent | null> = [];
  private committedRevision: string = '';
  private committedHasIntent: boolean = false;

  constructor(context: common.Context, file: string) { this.context = context; this.file = file; }
  cancel(): void { this.generation++; }
  profileVersion(): string { return this.ticket?.profileVersion ?? ''; }
  publishedProviderName(target: EditTarget, addition: boolean = false): string {
    const version = EffectiveVersions.read(this.context)?.Profiles[this.file];
    const intent = version === undefined ? null : EffectiveVersions.editIntent(this.context, version);
    let name = target.name ?? '';
    if (addition) {
      if (intent === null || intent.disabled === true) { return ''; }
      const added = intent.operations.find((operation) => operation.kind === 'add' &&
        operation.section === 'proxy-providers' && operation.id === target.item.id);
      return added?.name ?? '';
    }
    if (intent === null || intent.disabled === true) { return name; }
    for (const op of intent.operations) {
      if (op.section !== 'proxy-providers' || op.target !== target.item.id) { continue; }
      if (op.kind === 'delete') { return ''; }
      if (op.kind === 'rename') { name = op.name ?? name; }
    }
    return name;
  }

  private check(ticket: EditTicket): void {
    if (JSON.stringify(ProfileTransactions.editTicket(this.context, this.file)) !== JSON.stringify(ticket)) {
      throw new Error('配置或草稿已变化，请重新打开');
    }
  }

  async load(): Promise<boolean> {
    const request = ++this.generation;
    const ticket = ProfileTransactions.editTicket(this.context, this.file);
    const original = ProfileStore.getProfileContent(this.context, this.file);
    if (original === null) { throw new Error('原始配置读取失败'); }
    const overlay = ProfileStore.getEnabledMerge(this.context, this.file);
    const draft = ProfileStore.readEditDraft(this.context, this.file);
    const version = EffectiveVersions.read(this.context)?.Profiles[this.file];
    const committed = version === undefined ? null : EffectiveVersions.editIntent(this.context, version);
    const region = version === undefined ? undefined : EffectiveVersions.regionPlan(this.context, version) ?? undefined;
    const baseline = draft.intent === null ? undefined : JSON.parse(JSON.stringify(draft.intent)) as EditIntent;
    if (baseline !== undefined) { baseline.operations = []; baseline.disabled = false; }
    const snapshot = await ConfigEditor.list(this.context, original, overlay, ticket.activeVersion,
      undefined, baseline, region);
    if (request !== this.generation) { return false; }
    this.check(ticket);
    if (JSON.stringify(this.ticket) !== JSON.stringify(ticket)) { this.history = []; }
    this.committedRevision = committed?.revision ?? ''; this.committedHasIntent = committed !== null;
    this.ticket = ticket;
    this.original = original;
    this.overlay = overlay;
    this.region = region;
    this.snapshot = snapshot;
    this.intent = draft.intent;
    this.preview = null; this.editor = null; this.confirmed = null;
    return true;
  }

  workingIntent(): EditIntent {
    if (this.snapshot === null) { throw new Error('请先读取配置'); }
    return this.intent === null ? { schemaVersion: 1, revision: 'pending',
      sourceRevision: this.snapshot.sourceRevision, operations: [] } :
      JSON.parse(JSON.stringify(this.intent)) as EditIntent;
  }

  private baseline(): EditIntent | undefined {
    if (this.intent === null) { return undefined; }
    const intent = this.workingIntent(); intent.operations = []; intent.disabled = false;
    return intent;
  }

  async target(section: string, id: string): Promise<EditTarget | null> {
    if (this.ticket === null || this.busy) { return null; }
    const request = ++this.generation;
    const ticket = this.ticket;
    this.check(ticket);
    const target = await ConfigEditor.target(this.context, this.original, this.overlay,
      ticket.activeVersion, section, id, undefined, this.baseline(), this.region);
    if (request !== this.generation) { return null; }
    this.check(ticket);
    return target;
  }

  /** Render the compiler's current projection, including references rewritten
   * by another item's rename. Keep the authoring target for field conditions. */
  async presentTarget(section: string, baseline: EditTarget): Promise<EditTarget | null> {
    if (this.ticket === null || this.busy) { return null; }
    const request = ++this.generation; const ticket = this.ticket;
    this.check(ticket);
    const intent = this.workingIntent(); intent.disabled = false;
    let name = baseline.name ?? '';
    for (const operation of intent.operations) {
      if (operation.section === section && operation.target === baseline.item.id && operation.kind === 'rename') {
        name = operation.name ?? name;
      }
    }
    const snapshot = await ConfigEditor.list(this.context, this.original, this.overlay,
      ticket.activeVersion, undefined, intent, this.region);
    if (request !== this.generation) { return null; }
    this.check(ticket);
    const item = snapshot.sections.find((part) => part.section === section)?.items.find((entry) => entry.name === name);
    if (item === undefined) { throw new Error('项目已变化，请重新读取'); }
    const target = await ConfigEditor.target(this.context, this.original, this.overlay,
      ticket.activeVersion, section, item.id, undefined, intent, this.region);
    if (request !== this.generation) { return null; }
    this.check(ticket); return target;
  }

  async smartChoices(): Promise<SmartGroupChange[] | null> {
    if (this.ticket === null || this.busy) { return null; }
    const request = ++this.generation; const ticket = this.ticket;
    this.check(ticket);
    const choices = await ConfigEditor.smartPreview(this.context, this.original, this.overlay,
      ticket.activeVersion, Settings.load(this.context).smartAutoConvert, this.workingIntent(), undefined, this.region);
    if (request !== this.generation) { return null; }
    this.check(ticket); return choices;
  }

  async save(intent: EditIntent | null, recordHistory: boolean = true): Promise<boolean> {
    if (this.busy || this.ticket === null) { return false; }
    const request = ++this.generation;
    const ticket = this.ticket;
    this.check(ticket);
    this.busy = true;
    this.preview = null; this.editor = null; this.confirmed = null;
    try {
      if (request !== this.generation) { return false; }
      this.check(ticket);
      const revision = await ProfileTransactions.saveEditDraft(this.context, ticket, intent);
      if (request !== this.generation) { return false; }
      // The next identity is derived from this request's acknowledged revision,
      // not from an unrelated later editTicket read after the worker completes.
      const next: EditTicket = { file: ticket.file, profileIdentity: ticket.profileIdentity,
        profileVersion: ticket.profileVersion, activeVersion: ticket.activeVersion,
        activeFile: ticket.activeFile, draftRevision: revision };
      this.check(next);
      if (recordHistory) { this.history.push(this.intent); }
      const saved = intent === null ? null : JSON.parse(JSON.stringify(intent)) as EditIntent;
      if (saved !== null) { saved.revision = revision; }
      this.intent = saved;
      this.ticket = next;
      return await this.confirmPreview(next, request);
    } finally { this.busy = false; }
  }

  private async confirmPreview(ticket: EditTicket, request: number): Promise<boolean> {
    const editor = EditorDraftHosts.create(this.context, this.file);
    const session = await editor.load();
    if (request !== this.generation) { return false; }
    this.check(ticket);
    const receipt = await editor.preview(session.revision);
    if (request !== this.generation) { return false; }
    this.check(ticket);
    this.editor = editor; this.confirmed = receipt; this.preview = receipt.changes;
    return true;
  }

  async previewSaved(): Promise<boolean> {
    if (this.busy || this.ticket === null) { return false; }
    const request = ++this.generation;
    const ticket = this.ticket;
    this.check(ticket);
    this.busy = true;
    this.preview = null; this.editor = null; this.confirmed = null;
    try {
      return await this.confirmPreview(ticket, request);
    } finally { this.busy = false; }
  }

  canUndo(): boolean {
    return this.history.length > 0 || (this.intent === null ? this.committedHasIntent : this.intent.revision !== this.committedRevision);
  }
  undoNeedsConfirmation(): boolean { return this.history.length === 0 && this.canUndo(); }

  async undo(): Promise<boolean> {
    if (this.busy || this.history.length === 0) { return false; }
    const previous = this.history.pop() ?? null;
    const ticket = this.ticket;
    try { return await this.save(previous, false); }
    catch (error) { if (this.ticket === ticket) { this.history.push(previous); } throw new Error((error as Error).message); }
  }

  async reset(): Promise<boolean> {
    if (this.busy) { return false; }
    const version = EffectiveVersions.read(this.context)?.Profiles[this.file];
    const intent = version === undefined ? null : EffectiveVersions.editIntent(this.context, version);
    return await this.save(intent);
  }

  async apply(): Promise<ProfileApplyState | null> {
    if (this.busy || this.ticket === null || this.preview === null || this.editor === null || this.confirmed === null) { return null; }
    const request = ++this.generation;
    const ticket = this.ticket;
    this.busy = true;
    try {
      this.check(ticket);
      const result = await this.editor.apply(this.confirmed);
      if (result !== 'applied' && result !== 'saved') { throw new Error('应用结果未确认'); }
      if (request !== this.generation) { return null; }
      this.preview = null; this.editor = null; this.confirmed = null;
      this.history = [];
      return result;
    } finally { this.preview = null; this.editor = null; this.confirmed = null; this.busy = false; }
  }
}
