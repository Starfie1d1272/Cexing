import { HomePage } from './HomePage';
import { ProfilePage } from './ProfilePage';
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
    } else if (name === 'network') {
      NavDestination() { NetworkSettingsPage() }.title('网络设置')
    } else if (name === 'override') {
      NavDestination() { OverridePage() }.title('内核设置')
    } else if (name === 'profileEdit') {
      NavDestination() { ProfileEditPage() }.title('编辑配置')
    }
  }

  build() {
    Navigation(this.navStack) {
      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() { HomePage() }.tabBar('连接')
        TabContent() { ProfilePage() }.tabBar('配置')
        TabContent() { SettingsPage() }.tabBar('设置')
      }
      .width('100%')
      .height('100%')
      .scrollable(false)
      .onChange((index: number) => {
        this.currentTab = index;
        this.currentVisibleTab = index;
      })
    }
    .hideTitleBar(true)
    .navDestination(this.PageMap)
  }
}
