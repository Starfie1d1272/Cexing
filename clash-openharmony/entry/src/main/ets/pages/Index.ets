import { NativeTheme as UI } from './NativeTheme';
import { DiagnosticsPage } from './DiagnosticsPage';
import { HomePage } from './HomePage';
import { ProfilePage, ProfileDetailBus } from './ProfilePage';
import { SettingsPage } from './SettingsPage';
import { ProxyPage } from './ProxyPage';
import { ZashboardPage } from './ZashboardPage';
import { NetworkSettingsPage } from './NetworkSettingsPage';
import { OverridePage } from './OverridePage';
import { ProfileEditPage } from './ProfileEditPage';

@Entry
@Component
struct Index {
  @Provide('nav') navStack: NavPathStack = new NavPathStack();
  @Provide('profileRevision') profileRevision: number = 0;
  @Provide('rootVisible') rootVisible: boolean = true;
  @Provide('tab') currentVisibleTab: number = 0;
  @Provide('tabJump') @Watch('onTabJump') tabJump: number = -1;
  @State currentTab: number = 0;

  private onTabJump(): void {
    if (this.tabJump >= 0) {
      this.currentTab = this.tabJump;
      this.currentVisibleTab = this.tabJump;
      this.tabJump = -1;
    }
  }

  @Builder
  PageMap(name: string) {
    if (name === 'proxies') {
      NavDestination() { ProxyPage() }.title('代理组')
    } else if (name === 'zashboard') {
      // No entry button/session until security and configuration integration is accepted.
      NavDestination() { ZashboardPage() }.title('Zashboard')
    } else if (name === 'diagnostics') {
      NavDestination() { DiagnosticsPage() }.title('诊断')
    } else if (name === 'network') {
      NavDestination() { NetworkSettingsPage() }.title('网络设置')
    } else if (name === 'override') {
      NavDestination() { OverridePage() }.title('内核设置')
    } else if (name === 'profileDetail') {
      NavDestination() { ProfilePage({ detailFile: ProfileDetailBus.current }) }.title('订阅详情')
    } else if (name === 'profileEdit') {
      NavDestination() { ProfileEditPage() }.title('编辑配置')
    }
  }

  @Builder
  TabItem(label: string, symbol: Resource, index: number) {
    Column({ space: 5 }) {
      SymbolGlyph(symbol).fontSize(20)
        .fontColor([this.currentTab === index ? UI.accent : UI.muted])
      Text(label).fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(this.currentTab === index ? UI.accent : UI.muted)
    }.width('100%').height(60).justifyContent(FlexAlign.Center)
      .backgroundColor(this.currentTab === index ? UI.soft : UI.surface).borderRadius(24)
      .accessibilityText(label).accessibilityDescription(this.currentTab === index ? '已选中' : '')
  }

  build() {
    Navigation(this.navStack) {
      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() { HomePage() }.tabBar(this.TabItem('连接', $r('sys.symbol.power'), 0))
        TabContent() { ProfilePage() }.tabBar(this.TabItem('订阅', $r('sys.symbol.doc'), 1))
        TabContent() { SettingsPage() }.tabBar(this.TabItem('设置', $r('sys.symbol.slider_horizontal_2'), 2))
      }
      .width('100%')
      .height('100%')
      .scrollable(false)
      .barHeight(76)
      .barBackgroundColor(UI.surface)
      .backgroundColor(UI.paper)
      .onChange((index: number) => {
        this.currentTab = index;
        this.currentVisibleTab = index;
      })
    }
    .hideTitleBar(true)
    .onNavBarStateChange((visible: boolean) => { this.rootVisible = visible; })
    .navDestination(this.PageMap)
  }
}
