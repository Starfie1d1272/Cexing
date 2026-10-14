import { NativeTheme as UI } from './NativeTheme';
/*
 * NetworkSettingsPage.ets - 网络设置（设置 → 网络设置）
 * IPv6 / 按应用分流（模式 + 手动名单）。改动在下次 VPN 启动时生效。
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Settings } from '../lib/Settings';
import { buildVpnApplicationPolicy, validVpnBundleName, vpnRouteExceptions } from '../lib/VpnController';

const ACCESS_MODES: string[] = ['全部应用', '仅选中应用', '排除选中应用'];
const ACCESS_VALUES: string[] = ['all', 'white', 'black'];

@Component
export struct NetworkSettingsPage {
  @State ipv6: boolean = false;
  @State accessIndex: number = 0;
  @State accessList: string[] = [];
  @State inputPkg: string = '';
  @State showAddDialog: boolean = false;
  @State showRouteDetails: boolean = false;

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    this.ipv6 = s.ipv6;
    this.accessList = s.accessList;
    const idx = ACCESS_VALUES.indexOf(s.accessMode);
    this.accessIndex = idx >= 0 ? idx : 0;
  }

  aboutToDisappear(): void {
    this.cancelAddPackage();
    this.showRouteDetails = false;
  }

  private persist(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.ipv6 = this.ipv6;
    s.accessMode = ACCESS_VALUES[this.accessIndex];
    s.accessList = this.accessList;
    Settings.save(context, s);
  }

  private changedHint(): void {
    promptAction.showToast({ message: '已保存，下次启动 VPN 生效', duration: 1500 });
  }

  private addPackage(): void {
    if (!this.showAddDialog) { return; }
    const pkg = this.inputPkg.trim();
    const context = getContext(this) as common.UIAbilityContext;
    if (!validVpnBundleName(pkg) || pkg === context.applicationInfo.name) {
      promptAction.showToast({ message: '请输入其他应用的有效包名', duration: 1500 });
      return;
    }
    if (this.accessList.indexOf(pkg) >= 0) {
      promptAction.showToast({ message: '应用已添加', duration: 1500 });
      return;
    }
    const next = [...this.accessList, pkg];
    try { buildVpnApplicationPolicy(ACCESS_VALUES[this.accessIndex], next, context.applicationInfo.name); }
    catch (e) { promptAction.showToast({ message: (e as Error).message, duration: 1500 }); return; }
    this.accessList = next;
    this.persist();
    this.changedHint();
    this.inputPkg = '';
    this.showAddDialog = false;
  }

  private cancelAddPackage(): void {
    this.inputPkg = '';
    this.showAddDialog = false;
  }

  @Builder
  ToggleRow(title: string, sub: string, isOn: boolean, onFlip: (v: boolean) => void) {
    Row() {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(UI.ink)
        if (sub.length > 0) {
          Text(sub)
            .fontSize(13)
            .fontColor(UI.muted)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(UI.accent)
        .onChange((v: boolean) => onFlip(v))
    }
    .width('100%')
    .padding({ top: 13, bottom: 13, left: 14, right: 14 })
  }

  @Builder
  AddPkgDialog() {
    Column({ space: 14 }) {
      Text('添加应用包名')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(UI.ink)
      TextInput({ placeholder: '如 com.example.app', text: this.inputPkg }).height(48)
        .width('100%')
        .onChange((v: string) => {
          this.inputPkg = v;
        })
      Row({ space: 12 }) {
        Button('取消')
          .height(48)
          .layoutWeight(1)
          .backgroundColor(UI.soft)
          .fontColor(UI.ink)
          .onClick(() => {
            this.cancelAddPackage();
          })
        Button('添加')
          .height(48).backgroundColor(UI.action).fontColor(UI.onAccent)
          .layoutWeight(1)
          .onClick(() => {
            this.addPackage();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(UI.surface)
    .borderRadius(24)
  }

  @Builder
  RouteDetails() {
    Column({ space: 12 }) {
      Text('系统路由例外').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink)
      Text('以下地址直接使用当前网络，匹配的流量不进入 VPN。')
        .fontSize(13).fontColor(UI.muted).width('100%')
      ForEach(vpnRouteExceptions(), (cidr: string) => {
        Text(cidr).fontSize(14).fontColor(UI.ink).width('100%')
      }, (cidr: string) => cidr)
      Text('每次连接自动恢复默认例外。').fontSize(13).fontColor(UI.muted).width('100%')
      Button('完成').width('100%').height(48).backgroundColor(UI.action).fontColor(UI.onAccent)
        .onClick(() => { this.showRouteDetails = false; })
    }.padding(20).backgroundColor(UI.surface)
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Column() {
          this.ToggleRow('IPv6', '下次启动生效', this.ipv6, (v: boolean) => {
            this.ipv6 = v;
            this.persist();
            this.changedHint();
          })
        }
        .width('100%')
        .backgroundColor(UI.surface)
        .borderRadius(24)

        Column({ space: 0 }) {
          Row() {
            Text('按应用分流')
              .fontSize(13)
              .fontColor(UI.muted)
            Blank()
          }
          .width('100%')
          .padding({ top: 13, bottom: 6, left: 14, right: 14 })

          Row({ space: 0 }) {
            ForEach(ACCESS_MODES, (label: string, index: number) => {
              Text(label)
                .fontSize(14)
                .height(48)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .fontWeight(this.accessIndex === index ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(this.accessIndex === index ? UI.onAccent : UI.muted)
                .backgroundColor(this.accessIndex === index ? UI.action : Color.Transparent)
                .borderRadius(14)
                .padding({ left: 4, right: 4 })
                .stateStyles({
                  pressed: { .opacity(0.6) },
                  normal: { .opacity(1.0) }
                })
                .onClick(() => {
                  this.accessIndex = index;
                  this.persist();
                  this.changedHint();
                })
            }, (label: string) => label)
          }
          .backgroundColor(UI.soft)
          .borderRadius(24)
          .padding(2)
          .margin({ left: 14, right: 14, bottom: 8 })

          if (this.accessIndex > 0) {
            if (this.accessIndex === 1 && this.accessList.filter((pkg: string) =>
              validVpnBundleName(pkg) && pkg !== (getContext(this) as common.UIAbilityContext).applicationInfo.name).length === 0) {
              Text('请添加要连接的应用').fontSize(13).fontColor(UI.error)
                .width('100%').padding({ left: 14, right: 14, bottom: 6 })
            }
            ForEach(this.accessList, (pkg: string) => {
              Row() {
                Text(pkg)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(UI.ink)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Row() {
                  SymbolGlyph($r('sys.symbol.xmark'))
                    .fontSize(16)
                    .fontColor([UI.muted])
                }
                .width(48)
                .height(48)
                .justifyContent(FlexAlign.Center)
                .margin({ left: 8 })
                .stateStyles({
                  pressed: { .opacity(0.6) },
                  normal: { .opacity(1.0) }
                })
                .onClick(() => {
                  this.accessList = this.accessList.filter((x) => x !== pkg);
                  this.persist();
                  this.changedHint();
                })
              }
              .width('100%')
              .padding({ top: 2, bottom: 2, left: 14, right: 6 })
            }, (pkg: string) => pkg)

            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.plus'))
                .fontSize(14)
                .fontColor([UI.accentText])
              Text('添加包名')
                .fontSize(14)
                .fontColor(UI.accentText)
            }
            .width('100%')
            .constraintSize({ minHeight: 48 })
            .padding({ top: 10, bottom: 14, left: 14, right: 14 })
            .stateStyles({
              pressed: { .opacity(0.6) },
              normal: { .opacity(1.0) }
            })
            .onClick(() => {
              this.inputPkg = '';
              this.showAddDialog = true;
            })
          }
        }
        .width('100%')
        .backgroundColor(UI.surface)
        .borderRadius(24)

        Button('系统路由例外').height(48).width('100%').backgroundColor(UI.soft).fontColor(UI.ink)
          .onClick(() => { this.showRouteDetails = true; })

        Text('手动输入应用包名 · 本应用始终直连')
          .fontSize(13)
          .fontColor(UI.muted)
          .width('100%')
          .padding({ left: 4 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 8 })
    }
    .width('100%').height('100%').backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
    .bindSheet($$this.showRouteDetails, this.RouteDetails(), { height: SheetSize.MEDIUM })
    .bindSheet($$this.showAddDialog, this.AddPkgDialog(), { height: SheetSize.MEDIUM })
  }
}
