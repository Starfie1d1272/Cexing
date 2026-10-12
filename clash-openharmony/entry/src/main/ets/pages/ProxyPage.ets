// Zashboard 验收前保留的最小节点选择入口，仅以运行内核为数据源。
import { promptAction } from '@kit.ArkUI';
import { CoreApi, ProxyInfo } from '../lib/CoreApi';

@Component
export struct ProxyPage {
  @State groups: ProxyInfo[] = [];
  @State message: string = '';
  @State busy: boolean = false;

  aboutToAppear(): void {
    this.refresh();
  }

  private async refresh(): Promise<void> {
    this.busy = true;
    const proxies = await CoreApi.getProxies();
    const config = await CoreApi.getConfigs();
    this.groups = [];
    if (proxies === null) {
      this.message = '内核未运行或控制面不可达';
    } else {
      const groups: ProxyInfo[] = [];
      for (const name of Object.keys(proxies)) {
        const group = proxies[name];
        if (group.all !== undefined && group.all.length > 0 &&
          (name !== 'GLOBAL' || (config !== null && config.mode === 'global'))) {
          groups.push(group);
        }
      }
      this.groups = groups;
      this.message = groups.length === 0 ? '配置中没有代理组' : '';
    }
    this.busy = false;
  }

  private choose(group: ProxyInfo): void {
    // 自动组由内核选路，不在原生界面固定其节点。
    if (group.type !== 'Selector') {
      return;
    }
    const sheets: SheetInfo[] = [];
    for (const name of group.all) {
      sheets.push({ title: name, action: () => { this.select(group.name, name); } });
    }
    ActionSheet.show({ title: group.name, message: '选择出口节点', sheets: sheets });
  }

  private async select(group: string, name: string): Promise<void> {
    if (!(await CoreApi.selectProxy(group, name))) {
      promptAction.showToast({ message: '节点切换失败' });
    }
    await this.refresh();
  }

  build() {
    Column({ space: 12 }) {
      Button('刷新').enabled(!this.busy).onClick(() => this.refresh())
      if (this.message.length > 0) {
        Text(this.message)
      }
      List({ space: 8 }) {
        ForEach(this.groups, (group: ProxyInfo) => {
          ListItem() {
            Column({ space: 6 }) {
              Text(group.name).fontSize(18)
              Text(group.now === undefined ? group.type : `${group.type} · ${group.now}`)
              if (group.type === 'Selector') {
                Button('选择节点').enabled(!this.busy).onClick(() => this.choose(group))
              }
            }
            .alignItems(HorizontalAlign.Start)
            .padding(12)
          }
        }, (group: ProxyInfo) => group.name)
      }.layoutWeight(1)
    }
    .padding(16)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
