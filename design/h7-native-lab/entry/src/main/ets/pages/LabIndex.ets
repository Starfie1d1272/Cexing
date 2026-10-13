import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';

class FloatingProbe implements AttributeModifier<TabsAttribute> {
  private materialStyle: uiMaterial.ImmersiveStyle;
  private barSize: number;
  constructor(style: uiMaterial.ImmersiveStyle, width: number) {
    this.materialStyle = style; this.barSize = width;
  }
  applyNormalAttribute(tabs: TabsAttribute): void {
    if (deviceInfo.sdkApiVersion >= 26) {
      tabs.barOverlap(true).barFloatingStyle({
        barWidth: { smallBarWidth: this.barSize, mediumBarWidth: this.barSize, largeBarWidth: this.barSize },
        barSideMargin: 16, barBottomMargin: 8,
        systemMaterial: uiMaterial.isImmersiveMaterialSupported() ?
          new uiMaterial.ImmersiveMaterial({ style: this.materialStyle, interactive: true, lightEffect: {} }) : undefined
      });
    }
  }
}

@Entry
@Component
struct LabIndex {
  @State useHds: boolean = false;
  @State index: number = 0;
  @State barSize: number = 358;
  @State styleIndex: number = 1;
  @State sheet: boolean = false;
  private stack: NavPathStack = new NavPathStack();

  private style(): uiMaterial.ImmersiveStyle {
    if (deviceInfo.sdkApiVersion < 26) { return 1; }
    return [uiMaterial.ImmersiveStyle.ULTRA_THIN, uiMaterial.ImmersiveStyle.THIN,
      uiMaterial.ImmersiveStyle.REGULAR, uiMaterial.ImmersiveStyle.THICK,
      uiMaterial.ImmersiveStyle.ULTRA_THICK][this.styleIndex];
  }

  private capabilities(): string {
    if (deviceInfo.sdkApiVersion < 26) { return 'API <26：基础组件回退'; }
    return `state=${uiMaterial.getMaterialInfo().state} · supported=${uiMaterial.isImmersiveMaterialSupported()} · level=${uiMaterial.getGlobalMaterialLevel()}`;
  }

  @Builder
  SheetContent() {
    Column({ space: 20 }) {
      Text('系统半模态').fontSize(24)
      Toggle({ type: ToggleType.Switch, isOn: true })
      Select([{ value: '第一项' }, { value: '第二项' }]).value('第一项')
      Button('关闭').height(48).onClick(() => { this.sheet = false; })
    }.padding(24).width('100%')
  }

  @Builder
  Destination() {
    NavDestination() { Text('返回不改变页签选择').fontSize(20).padding(24) }.title('二级页面')
  }

  @Builder
  Content(label: string) {
    Column({ space: 12 }) {
      Scroll() {
        Column({ space: 16 }) {
          Text(label).fontSize(28)
          Text(this.capabilities()).fontSize(14)
          Button(this.useHds ? '切换普通 Tabs' : '切换 HdsTabs').height(48)
            .onClick(() => { this.useHds = !this.useHds; })
          Button('选择材质样式').height(48).onClick(() => {
            ActionSheet.show({ title: '材质样式', message: '选择厚度', sheets: ['ULTRA_THIN', 'THIN', 'REGULAR', 'THICK', 'ULTRA_THICK']
              .map((title: string, i: number): SheetInfo => ({ title: title, action: () => { this.styleIndex = i; } })) });
          })
          Button('系统弹窗').height(48).onClick(() => {
            AlertDialog.show({ title: '材质试验', message: '比较 DEFAULT 与 ENABLE',
              confirm: { value: '确定', action: () => {} } });
          })
          Button('系统半模态').height(48).onClick(() => { this.sheet = true; })
          Button('进入页面栈').height(48).onClick(() => { this.stack.pushPath({ name: 'detail' }); })
          Toggle({ type: ToggleType.Switch, isOn: true })
          Select([{ value: '第一项' }, { value: '第二项' }]).value('第一项').height(48)
          ForEach([0, 1, 2, 3, 4, 5], (i: number) => {
            Text(`滚动内容 ${i + 1}`).fontSize(20).padding(24).width('100%')
              .backgroundColor($r('sys.color.comp_background_secondary')).borderRadius(24)
          })
        }.width('100%').padding(24)
      }.layoutWeight(1).width('100%')
      Button('固定主动作').height(56).width('100%')
    }.width('100%').height('100%').padding({ bottom: 92 })
  }

  build() {
    Navigation(this.stack) {
      if (this.useHds && deviceInfo.sdkApiVersion >= 23 && canIUse('SystemCapability.UIDesign.HDSComponent.Core')) {
        HdsTabs({ barPosition: BarPosition.End, index: this.index }) {
          TabContent() { this.Content('连接') }.tabBar('连接')
          TabContent() { this.Content('订阅') }.tabBar('订阅')
          TabContent() { this.Content('设置') }.tabBar('设置')
        }.width('100%').height('100%').barHeight(68).barOverlap(true).scrollable(false)
          .barFloatingStyle({
            barWidth: { smallWidth: this.barSize, mediumWidth: this.barSize, largeWidth: this.barSize },
            barSideMargin: 16, barBottomMargin: 8, thermoCtrl: true,
            systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE,
              materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE }
          }).onChange((i: number) => { this.index = i; })
      } else {
        Tabs({ barPosition: BarPosition.End, index: this.index }) {
          TabContent() { this.Content('连接') }.tabBar('连接')
          TabContent() { this.Content('订阅') }.tabBar('订阅')
          TabContent() { this.Content('设置') }.tabBar('设置')
        }.width('100%').height('100%').barHeight(68).scrollable(false)
          .attributeModifier(new FloatingProbe(this.style(), this.barSize))
          .onChange((i: number) => { this.index = i; })
      }
    }.hideTitleBar(true).mode(NavigationMode.Stack).navDestination(this.Destination)
      .onAreaChange((_old: Area, area: Area) => { this.barSize = Math.min(Math.max(Number(area.width) - 32, 0), 472); })
      .backgroundColor($r('sys.color.background_primary'))
      .bindSheet($$this.sheet, this.SheetContent(), { height: SheetSize.MEDIUM })
  }
}
