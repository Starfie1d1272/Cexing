import { promptAction } from '@kit.ArkUI';
import { ProfileApplyRecovery } from '../lib/ProfileApplyRecovery';
import { common } from '@kit.AbilityKit';
import { EditorDraftHost } from '../lib/ConfigEditor';
import { EditorDraftHosts } from '../lib/EditorDraftHosts';
import { TemplateWizard } from './TemplateWizard';

export class ProfileTemplateBus { static file: string = ''; }

/** A host belongs to one visible navigation session, never the selected tab. */
@Component
export struct ProfileTemplatePage {
  @Prop @Watch('visibilityChanged') visible: boolean = false;
  @Consume('nav') navStack: NavPathStack;
  @Consume('profileRevision') profileRevision: number;
  @State private ready: boolean = false;
  private recovering: boolean = false;
  private recoveryGeneration: number = 0;
  private file: string = '';
  private editor: EditorDraftHost | undefined = undefined;

  aboutToAppear(): void { this.file = ProfileTemplateBus.file; this.visibilityChanged(); }
  aboutToDisappear(): void { this.release(); }
  private release(): void {
    this.recoveryGeneration++;
    if (this.ready) { this.profileRevision++; }
    this.ready = false; this.editor = undefined;
  }
  private visibilityChanged(): void {
    if (!this.visible) { this.release(); return; }
    if (this.file === '') { return; }
    if (this.ready) { return; }
    this.editor = EditorDraftHosts.create(getContext(this) as common.UIAbilityContext, this.file);
    this.ready = true;
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
    if (this.ready && this.editor !== undefined) {
      TemplateWizard({ onRecovery: (selection: boolean) => this.recover(selection), profileId: this.file, editor: this.editor, onClose: () => {
        if (this.visible) { this.navStack.pop(); }
      } })
    }
  }
}
