import { NativeTheme as UI } from './NativeTheme';
import { NativeMaterial, NativeTabStyle } from './NativeMaterial';
import { SmartPage } from './SmartPage';
import { DiagnosticsPage } from './DiagnosticsPage';
import { HomePage } from './HomePage';
import { ProfilePage, ProfileDetailBus } from './ProfilePage';
import { SettingsPage } from './SettingsPage';
import { ProxyPage } from './ProxyPage';
import { ZashboardPage } from './ZashboardPage';
import { NetworkSettingsPage } from './NetworkSettingsPage';
import { OverridePage } from './OverridePage';
import { ProfileEditPage } from './ProfileEditPage';
import { ConnectionEntryPage } from './ConnectionEntryPage';
import { ConnectionEntry } from '../lib/ConnectionEntry';

@Entry
@Component
struct Index {
  @StorageLink('connectionEntryRequest') @Watch('openConnectionEntry') entryRequest: number = 0;
  @Provide('nav') navStack: NavPathStack = new NavPathStack();
  @Provide('profileRevision') profileRevision: number = 0;
  @Provide('rootVisible') rootVisible: boolean = true;
  @Provide('tab') currentVisibleTab: number = 0;
  @Provide('tabJump') @Watch('onTabJump') tabJump: number = -1;
  @State currentTab: number = 0;
  @State windowWidth: number = 390;
  @State private smartVisible: boolean = false;
  @State private zashboardVisible: boolean = false;

  aboutToAppear(): void { this.openConnectionEntry(); }

  private openConnectionEntry(): void {
    if (!ConnectionEntry.takeNavigation()) { return; }
    const names = this.navStack.getAllPathName();
    if (names[names.length - 1] !== 'connectionEntry') {
      this.navStack.pushPath({ name: 'connectionEntry' });
    }
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
    if (name === 'connectionEntry') {
      NavDestination() { ConnectionEntryPage() }.title('连接快捷入口')
    } else if (name === 'proxies') {
      NavDestination() { ProxyPage() }.title('代理组')
    } else if (name === 'zashboard') {
      NavDestination() { ZashboardPage({ visible: this.zashboardVisible }) }.title('控制面板')
        .onShown(() => { this.zashboardVisible = true; })
        .onHidden(() => { this.zashboardVisible = false; })
    } else if (name === 'smart') {
      NavDestination() { SmartPage({ visible: this.smartVisible }) }.title('Smart')
        .onShown(() => { this.smartVisible = true; })
        .onHidden(() => { this.smartVisible = false; })
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
        .fontColor([this.currentTab === index ? UI.accentText : UI.muted])
      Text(label).fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(this.currentTab === index ? UI.accentText : UI.muted)
    }.width('100%').height(60).justifyContent(FlexAlign.Center)
      .backgroundColor(this.currentTab === index ? UI.soft : Color.Transparent).borderRadius(24)
      .accessibilityGroup(true).accessibilityText(label).accessibilityDescription(this.currentTab === index ? '已选中' : '')
  }

  build() {
    Navigation(this.navStack) {
      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() {
          Column() { HomePage() }.width('100%').height('100%').padding({ bottom: NativeMaterial.contentInset() })
        }.tabBar(this.TabItem('连接', $r('sys.symbol.power'), 0))
        TabContent() {
          Column() { ProfilePage() }.width('100%').height('100%').padding({ bottom: NativeMaterial.contentInset() })
        }.tabBar(this.TabItem('订阅', $r('sys.symbol.doc'), 1))
        TabContent() {
          Column() { SettingsPage() }.width('100%').height('100%').padding({ bottom: NativeMaterial.contentInset() })
        }.tabBar(this.TabItem('设置', $r('sys.symbol.slider_horizontal_2'), 2))
      }
      .width('100%')
      .height('100%')
      .scrollable(false)
      .animationDuration(0)
      .attributeModifier(new NativeTabStyle(this.windowWidth))
      .onAreaChange((_old: Area, area: Area) => { this.windowWidth = Number(area.width); })
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
