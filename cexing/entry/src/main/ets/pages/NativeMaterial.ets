import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { NativeTheme as UI } from './NativeTheme';

// Keep API 26 method calls inside the runtime branch, not on an old-device chain with undefined.
export class NativeMaterial {
  static floatingAvailable(): boolean {
    return deviceInfo.sdkApiVersion >= 26 && canIUse('SystemCapability.ArkUI.ArkUI.Full');
  }

  static fontGrowth(fontScale: number = 1): number { return Math.max(0, fontScale - 1) * 40; }

  static contentInset(fontScale: number = 1): number {
    return NativeMaterial.floatingAvailable() ? 92 + NativeMaterial.fontGrowth(fontScale) : 0;
  }

  static barWidth(windowWidth: number): number {
    return Math.min(Math.max(windowWidth - 32, 0), 472);
  }
}

export class NativeTabStyle implements AttributeModifier<TabsAttribute> {
  private windowWidth: number;
  private fontScale: number;
  constructor(windowWidth: number, fontScale: number = 1) { this.windowWidth = windowWidth; this.fontScale = fontScale; }

  applyNormalAttribute(tabs: TabsAttribute): void {
    if (!NativeMaterial.floatingAvailable()) {
      tabs.barOverlap(false).barHeight(76 + NativeMaterial.fontGrowth(this.fontScale)).barBackgroundColor(UI.surface);
      return;
    }
    const supported = uiMaterial.isImmersiveMaterialSupported();
    const width = NativeMaterial.barWidth(this.windowWidth);
    tabs.barHeight(68 + NativeMaterial.fontGrowth(this.fontScale)).barOverlap(true);
    if (!supported) { tabs.barBackgroundBlurStyle(BlurStyle.NONE); }
    tabs.barBackgroundColor(supported ? Color.Transparent : UI.surface);
    tabs.barFloatingStyle({
      barWidth: { smallBarWidth: width, mediumBarWidth: width, largeBarWidth: width },
      barSideMargin: 16, barBottomMargin: 8,
      systemMaterial: supported ? new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN, interactive: true, lightEffect: {}
      }) : undefined
    });
  }
}
