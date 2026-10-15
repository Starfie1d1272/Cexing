import { common } from '@kit.AbilityKit';
import { EditorDraftHost } from '../lib/ConfigEditor';
import { EditorDraftHosts } from '../lib/EditorDraftHosts';
import { TemplateWizard } from './TemplateWizard';

export class ProfileTemplateBus {
  static file: string = '';
  static backGuard: (() => boolean) | null = null;
}

/** A host belongs to one visible navigation session, never the selected tab. */
@Component
export struct ProfileTemplatePage {
  @Prop @Watch('visibilityChanged') visible: boolean = false;
  @Consume('nav') navStack: NavPathStack;
  @Consume('profileRevision') profileRevision: number;
  @State private ready: boolean = false;
  private file: string = '';
  private editor: EditorDraftHost | undefined = undefined;

  aboutToAppear(): void { this.file = ProfileTemplateBus.file; this.visibilityChanged(); }
  aboutToDisappear(): void { this.release(); }
  private release(): void {
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

  build() {
    if (this.ready && this.editor !== undefined) {
      TemplateWizard({ registerBackGuard: (guard: (() => boolean) | null) => { ProfileTemplateBus.backGuard = guard; }, profileId: this.file, editor: this.editor, onClose: () => {
        if (this.visible) { this.navStack.pop(); }
      } })
    }
  }
}
