import { ProfileApplyRecovery } from '../lib/ProfileApplyRecovery';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { EditorDraftHosts, EditorSourceCandidate } from '../lib/EditorDraftHosts';
import { EditTicket, ProfileTransactions } from '../lib/ProfileTransactions';
import { EditIntent, EditorDraftHost, EditorDraftPreview } from '../lib/ConfigEditor';
import { TemplateUpdateHost, TemplateUpdatePreview } from '../lib/TemplateUpdates';
import { createTemplateUpdateSource } from '../lib/TemplateUpdateSource';
import { createTemplateUpdateHost } from '../lib/TemplateUpdateHost';
import { TemplateUpdateReview } from './TemplateUpdateReview';
import { NativeTheme as UI } from './NativeTheme';

export interface ProfileUpdateRequest { file: string; source: EditorSourceCandidate; ticket: EditTicket; }
/** One in-memory handoff. No downloaded Original is written before receipt apply. */
export class ProfileUpdateBus { static request: ProfileUpdateRequest | null = null; }

@Component
export struct ProfileUpdatePage {
  @Prop @Watch('visibilityChanged') visible: boolean = false;
  @Consume('nav') navStack: NavPathStack;
  @Consume('profileRevision') profileRevision: number;
  @State private ready: boolean = false;
  private recovering: boolean = false;
  private recoveryGeneration: number = 0;
  @State private failed: boolean = false;
  private file: string = '';
  private request: ProfileUpdateRequest | null = null;
  private host: TemplateUpdateHost | undefined = undefined;
  private started: boolean = false;

  aboutToAppear(): void {
    this.request = ProfileUpdateBus.request; ProfileUpdateBus.request = null;
    this.file = this.request?.file ?? ''; this.visibilityChanged();
  }
  aboutToDisappear(): void { this.release(); }
  private release(): void {
    this.recoveryGeneration++;
    if (this.ready) { this.profileRevision++; }
    this.host?.reset?.(); this.host = undefined; this.request = null;
    this.ready = false; this.failed = true;
  }
  private visibilityChanged(): void {
    if (!this.visible) { if (this.started) { this.release(); } return; }
    if (this.ready || this.started) { return; }
    this.started = true;
    const request = this.request; this.request = null;
    if (request === null) { this.failed = true; return; }
    const context = getContext(this) as common.UIAbilityContext;
    let expected = JSON.parse(JSON.stringify(request.ticket)) as EditTicket;
    const current = (): boolean => JSON.stringify(ProfileTransactions.editTicket(context, this.file)) === JSON.stringify(expected);
    try {
      if (!current()) { throw new Error('UPDATE_SOURCE_CHANGED'); }
      const editor = EditorDraftHosts.create(context, this.file, request.source);
      const source = createTemplateUpdateSource(context, this.file, request.source);
      // Only acknowledged saves may advance this download's draft ticket. A
      // foreign update/reset cannot recapture a newer source for an old body.
      const bound: EditorDraftHost = {
        load: async () => {
          if (!current()) { throw new Error('UPDATE_SOURCE_CHANGED'); }
          const session = await editor.load();
          if (!current()) { throw new Error('UPDATE_SOURCE_CHANGED'); }
          return session;
        },
        target: (section: string, id: string, revision: string) => editor.target(section, id, revision),
        save: async (intent: EditIntent, revision: string) => {
          if (!current()) { throw new Error('UPDATE_SOURCE_CHANGED'); }
          const session = await editor.save(intent, revision);
          if (session.intent === null) { throw new Error('UPDATE_SOURCE_CHANGED'); }
          expected = { file: expected.file, profileIdentity: expected.profileIdentity, profileVersion: expected.profileVersion,
            activeVersion: expected.activeVersion, activeFile: expected.activeFile, draftRevision: session.intent.revision };
          return session;
        },
        preview: (revision: string) => editor.preview(revision),
        apply: (preview: EditorDraftPreview) => editor.apply(preview),
        undo: (revision: string) => editor.undo(revision)
      };
      const host = createTemplateUpdateHost(context, this.file, bound, source);
      this.host = { reset: host.reset, label: host.label, detail: host.detail, preview: host.preview,
        apply: async (preview: TemplateUpdatePreview): Promise<string> => {
          const result = await host.apply(preview);
          const paths = this.navStack.getAllPathName();
          if (this.visible && this.ready && paths[paths.length - 1] === 'profileTemplateUpdate') {
            this.release(); this.navStack.pop();
            promptAction.showToast({ message: context.resourceManager.getStringByNameSync('profile_update_done'), duration: 1800 });
          }
          return result;
        } };
      this.ready = true;
    } catch (_) { this.failed = true; }
  }

  private async recover(selection: boolean): Promise<void> {
    if (!this.visible || !this.ready || this.recovering) { return; }
    if (selection) { this.navStack.pushPath({ name: 'zashboard' }); return; }
    this.recovering = true;
    const generation = this.recoveryGeneration;
    const current = (): boolean => this.visible && this.ready && generation === this.recoveryGeneration;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const accepted = await ProfileApplyRecovery.reconnect(context, current);
      if (!current() || accepted === null) { return; }
      promptAction.showToast({ message: context.resourceManager.getStringByNameSync(
        accepted ? 'apply_feedback_starting' : 'apply_feedback_recovery_failed'), duration: 1800 });
      if (accepted) { this.release(); this.navStack.pop(); }
    } catch (_) {
      if (current()) {
        promptAction.showToast({ message: context.resourceManager.getStringByNameSync('apply_feedback_recovery_failed'), duration: 1800 });
      }
    } finally { this.recovering = false; }
  }

  build() {
    if (this.ready && this.host !== undefined) {
      TemplateUpdateReview({ onRecovery: (selection: boolean) => this.recover(selection), profileId: this.file, host: this.host, onClose: () => {
        this.release(); if (this.visible) { this.navStack.pop(); }
      } })
    } else if (this.failed) {
      Column({ space: 16 }) {
        Text($r('app.string.profile_update_expired')).fontColor(UI.muted)
        Button($r('app.string.profile_update_back')).constraintSize({ minHeight: 44 })
          .onClick(() => { this.release(); if (this.visible) { this.navStack.pop(); } })
      }.width('100%').height('100%').padding(20).justifyContent(FlexAlign.Center)
    }
  }
}
