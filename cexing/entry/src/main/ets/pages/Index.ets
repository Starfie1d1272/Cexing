import { common } from '@kit.AbilityKit';
import { UiText } from '../lib/UiText';
import { NativeTheme as UI } from './NativeTheme';
import { NativeMaterial, NativeTabStyle } from './NativeMaterial';
import { SmartPage } from './SmartPage';
import { DiagnosticsPage } from './DiagnosticsPage';
import { TrafficPage } from './TrafficPage';
import { HomePage } from './HomePage';
import { ProfilePage, ProfileDetailBus } from './ProfilePage';
import { SettingsPage } from './SettingsPage';
import { ZashboardPage } from './ZashboardPage';
import { ResourceRecoveryPage } from './ResourceRecoveryPage';
import { NetworkSettingsPage } from './NetworkSettingsPage';
import { OverridePage } from './OverridePage';
import { ProfileEditPage, ProfileEditBus } from './ProfileEditPage';
import { ProfileGeneratedPage } from './ProfileGeneratedPage';
import { RuleDnsEditorPage } from './RuleDnsEditorPage';
import { ProfileProxyEditorPage } from './ProfileProxyEditorPage';
import { ProfileTemplatePage } from './ProfileTemplatePage';
import { ProfileUpdatePage } from './ProfileUpdatePage';

@Entry
@Component
struct Index {
  @StorageLink('profileImportRequest') @Watch('openImportEntry') importRequest: number = 0;
  @StorageLink('connectionEntryRequest') @Watch('openConnectionEntry') entryRequest: number = 0;
  @Provide('nav') navStack: NavPathStack = new NavPathStack();
  @Provide('profileRevision') profileRevision: number = 0;
  @Provide('rootVisible') rootVisible: boolean = true;
  @Provide('tab') currentVisibleTab: number = 0;
  @Provide('tabJump') @Watch('onTabJump') tabJump: number = -1;
  @State currentTab: number = 0;
  @State windowWidth: number = 390;
  @State private fontScale: number = 1;
  @State private smartVisible: boolean = false;
  @State private ruleDnsVisible: boolean = false;
  @State private templateVisible: boolean = false;
  @State private templateUpdateVisible: boolean = false;
  @State private proxyEditorVisible: boolean = false;
  @State private zashboardVisible: boolean = false;
  @State private resourcesVisible: boolean = false;

  aboutToAppear(): void {
    if (this.importRequest > 0) { this.openImportEntry(); }
  }

  private openImportEntry(): void {
    // Keep routed editors mounted; their close/back guard owns unsaved data.
    this.currentTab = 1;
    this.currentVisibleTab = 1;
  }

  private openConnectionEntry(): void {
    this.navStack.clear();
    this.currentTab = 0;
    this.currentVisibleTab = 0;
  }

  private onTabJump(): void {
    if (this.tabJump >= 0) {
      this.currentTab = this.tabJump;
      this.currentVisibleTab = this.tabJump;
      this.tabJump = -1;
    }
  }

  @Builder
  PageMap(name: string) {
    if (name === 'zashboard') {
      NavDestination() { ZashboardPage({ visible: this.zashboardVisible }) }.title(UiText.get($r('app.string.nav_panel')))
        .onShown(() => { this.zashboardVisible = true; })
        .onHidden(() => { this.zashboardVisible = false; })
    } else if (name === 'smart') {
      NavDestination() { SmartPage({ visible: this.smartVisible }) }.title('Smart')
        .onShown(() => { this.smartVisible = true; })
        .onHidden(() => { this.smartVisible = false; })
    } else if (name === 'traffic') {
      NavDestination() { TrafficPage() }.title(UiText.get($r('app.string.nav_traffic')))
    } else if (name === 'diagnostics') {
      NavDestination() { DiagnosticsPage() }.title(UiText.get($r('app.string.nav_diagnostics')))
    } else if (name === 'resources') {
      NavDestination() { ResourceRecoveryPage({ visible: this.resourcesVisible }) }.title(UiText.get($r('app.string.nav_resources')))
        .onShown(() => { this.resourcesVisible = true; })
        .onHidden(() => { this.resourcesVisible = false; })
    } else if (name === 'network') {
      NavDestination() { NetworkSettingsPage() }.title(UiText.get($r('app.string.nav_network')))
    } else if (name === 'override') {
      NavDestination() { OverridePage() }.title(UiText.get($r('app.string.nav_core')))
    } else if (name === 'profileDetail') {
      NavDestination() { ProfilePage({ detailFile: ProfileDetailBus.current }) }.title(UiText.get($r('app.string.nav_profile_details')))
    } else if (name === 'profileTemplateUpdate') {
      NavDestination() { ProfileUpdatePage({ visible: this.templateUpdateVisible }) }.title($r('app.string.profile_update_title'))
        .onShown(() => { this.templateUpdateVisible = true; })
        .onHidden(() => { this.templateUpdateVisible = false; })
    } else if (name === 'profileTemplate') {
      NavDestination() { ProfileTemplatePage({ visible: this.templateVisible }) }.title($r('app.string.proxy_editor_template_title'))
        .onShown(() => { this.templateVisible = true; })
        .onHidden(() => { this.templateVisible = false; })
    } else if (name === 'profileProxyEditor') {
      NavDestination() { ProfileProxyEditorPage({ visible: this.proxyEditorVisible }) }.title($r('app.string.proxy_editor_title'))
        .onShown(() => { this.proxyEditorVisible = true; })
        .onHidden(() => { this.proxyEditorVisible = false; })
    } else if (name === 'ruleDnsEditor') {
      NavDestination() { RuleDnsEditorPage({ visible: this.ruleDnsVisible }) }.title($r('app.string.proxy_editor_rules_title'))
        .onShown(() => { this.ruleDnsVisible = true; })
        .onHidden(() => { this.ruleDnsVisible = false; })
    } else if (name === 'profileMerge') {
      NavDestination() { ProfileEditPage({ mergeOnly: true }) }.title(UiText.get($r('app.string.nav_profile_merge')))
        .onBackPressed(() => ProfileEditBus.shouldBlockBack())
    } else if (name === 'profileGenerated') {
      NavDestination() { ProfileGeneratedPage() }.title(UiText.get($r('app.string.nav_generated')))
    } else if (name === 'profileEdit') {
      NavDestination() { ProfileEditPage() }.title(UiText.get($r('app.string.nav_original')))
        .onBackPressed(() => ProfileEditBus.shouldBlockBack())
    }
  }

  @Builder
  TabItem(label: string, symbol: Resource, index: number) {
    Column({ space: 5 }) {
      SymbolGlyph(symbol).fontSize(20)
        .fontColor([this.currentTab === index ? UI.accentText : UI.muted])
      Text(label).fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(this.currentTab === index ? UI.accentText : UI.muted)
    }.width('100%').constraintSize({ minHeight: 60 }).justifyContent(FlexAlign.Center)
      .backgroundColor(this.currentTab === index ? UI.soft : Color.Transparent).borderRadius(24)
      .accessibilityRole(AccessibilityRoleType.BUTTON).accessibilitySelected(this.currentTab === index)
      .accessibilityGroup(true).accessibilityText(label).accessibilityDescription(this.currentTab === index ? UiText.get($r('app.string.state_selected')) : '')
  }

  build() {
    Navigation(this.navStack) {
      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() {
          Column() { HomePage() }.width('100%').height('100%').padding({ bottom: NativeMaterial.contentInset(this.fontScale) })
        }.tabBar(this.TabItem(UiText.get($r('app.string.nav_connection')), $r('sys.symbol.power'), 0))
        TabContent() {
          Column() { ProfilePage() }.width('100%').height('100%').padding({ bottom: NativeMaterial.contentInset(this.fontScale) })
        }.tabBar(this.TabItem(UiText.get($r('app.string.nav_profiles')), $r('sys.symbol.doc'), 1))
        TabContent() {
          Column() { SettingsPage() }.width('100%').height('100%').padding({ bottom: NativeMaterial.contentInset(this.fontScale) })
        }.tabBar(this.TabItem(UiText.get($r('app.string.action_settings')), $r('sys.symbol.slider_horizontal_2'), 2))
      }
      .width('100%')
      .height('100%')
      .scrollable(false)
      .animationDuration(0)
      .attributeModifier(new NativeTabStyle(this.windowWidth, this.fontScale))
      .onAreaChange((_old: Area, area: Area) => { this.windowWidth = Number(area.width);
        this.fontScale = (getContext(this) as common.UIAbilityContext).config.fontSizeScale ?? 1; })
      .backgroundColor(UI.paper)
      .onChange((index: number) => {
        this.currentTab = index;
        this.currentVisibleTab = index;
      })
    }
    .hideTitleBar(true)
    .backgroundColor(UI.paper)
    .onNavBarStateChange((visible: boolean) => { this.rootVisible = visible; })
    .navDestination(this.PageMap)
  }
}
