import { CoreApi, TrafficMsg, formatRate } from '../lib/CoreApi';
import { TrafficStats, TrafficView, TrafficPoint } from '../lib/TrafficStats';
import { TrafficBucket } from '../lib/TrafficLedger';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';

function bytes(value: number): string {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let index = 0;
  while (value >= 1024 && index < units.length - 1) { value /= 1024; index++; }
  return `${value.toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

@Component
export struct TrafficPage {
  @State private snapshot: TrafficView = new TrafficView();
  @State private up: string = '—';
  @State private down: string = '—';
  @State private chartWidth: number = 280;
  @State private uploads: number[][] = [];
  @State private downloads: number[][] = [];
  @State private chartMax: string = '';
  private timer: number = -1;
  private lastRate: number = 0;
  private active: boolean = false;
  private watcher: CoreApi.StreamWatcher<TrafficMsg> = new CoreApi.StreamWatcher<TrafficMsg>();
  private listener = (_status: VpnStatus): void => { this.openRates(); };

  aboutToAppear(): void {
    this.active = true;
    VpnController.onChanged(this.listener);
    this.refresh(); this.openRates();
    this.timer = setInterval(() => {
      this.refresh();
      if (Date.now() - this.lastRate > 4000) { this.up = '—'; this.down = '—'; }
    }, 1000);
  }
  aboutToDisappear(): void {
    this.active = false;
    clearInterval(this.timer); this.timer = -1;
    this.watcher.stop(); VpnController.offChanged(this.listener);
  }
  private openRates(): void {
    this.watcher.stop(); this.up = '—'; this.down = '—'; this.lastRate = 0;
    if (this.active && VpnController.status === VpnStatus.Connected) {
      this.watcher.start('/traffic', (sample: TrafficMsg) => {
        this.lastRate = Date.now(); this.up = formatRate(sample.up); this.down = formatRate(sample.down);
      });
    }
  }
  private refresh(): void {
    this.snapshot = TrafficStats.view();
    const points = this.snapshot.points;
    // Break rather than connect across missing samples; curve is a short,
    // bounded observation history, not a reconstructed daily timeline.
    const now = Date.now();
    let start = points.length - 1;
    while (start > 0 && points[start].at - points[start - 1].at <= 15000) { start--; }
    const recent = points.slice(Math.max(0, start)).filter((p: TrafficPoint) => now - p.at <= 300000);
    let max = 1;
    recent.forEach((p: TrafficPoint) => { max = Math.max(max, p.up, p.down); });
    this.chartMax = formatRate(max);
    this.uploads = recent.map((p: TrafficPoint) => [Math.max(0, this.chartWidth * (1 - (now - p.at) / 300000)), 88 - 80 * p.up / max]);
    this.downloads = recent.map((p: TrafficPoint) => [Math.max(0, this.chartWidth * (1 - (now - p.at) / 300000)), 88 - 80 * p.down / max]);
  }
  @Builder
  Rate(upload: boolean) {
    Column({ space: 8 }) {
      Text(upload ? '↑ 上传' : '↓ 下载').fontSize(13).fontColor(upload ? UI.accentText : UI.muted)
      Text(upload ? this.up : this.down).fontSize(24).fontWeight(FontWeight.Medium).fontColor(UI.ink).fontFeature('tnum')
    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
  }
  private bucket(index: number): TrafficBucket {
    return index === 0 ? this.snapshot.current : (index === 1 ? this.snapshot.today : this.snapshot.month);
  }
  @Builder
  Period(index: number, label: string) {
    Column({ space: 16 }) {
      Row() {
        Text(label).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UI.ink).layoutWeight(1)
        if (this.bucket(index).partial) { Text('部分记录').fontSize(12).fontColor(UI.muted) }
      }.width('100%')
      Row() {
        Column({ space: 7 }) {
          Text('上传').fontSize(12).fontColor(UI.muted)
          Text(this.snapshot.ready && (index !== 0 || this.snapshot.currentReady) ? bytes(this.bucket(index).up) : '—').fontSize(17).minFontSize(12).maxFontSize(17).maxLines(1).fontColor(UI.ink).fontFeature('tnum')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 7 }) {
          Text('下载').fontSize(12).fontColor(UI.muted)
          Text(this.snapshot.ready && (index !== 0 || this.snapshot.currentReady) ? bytes(this.bucket(index).down) : '—').fontSize(17).minFontSize(12).maxFontSize(17).maxLines(1).fontColor(UI.ink).fontFeature('tnum')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 7 }) {
          Text('合计').fontSize(12).fontColor(UI.muted)
          Text(this.snapshot.ready && (index !== 0 || this.snapshot.currentReady) ? bytes(this.bucket(index).up + this.bucket(index).down) : '—').fontSize(17).minFontSize(12).maxFontSize(17).maxLines(1).fontWeight(FontWeight.Medium)
            .fontColor(UI.ink).fontFeature('tnum')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
    }.width('100%').padding({ top: 22, bottom: 22 })
  }
  build() {
    Scroll() {
      Column({ space: 0 }) {
        Row({ space: 12 }) { this.Rate(true); this.Rate(false) }.width('100%').padding({ top: 12, bottom: 20 })
        if (this.uploads.length > 1) {
          Column({ space: 6 }) {
            Text(this.chartMax).fontSize(11).fontColor(UI.muted).width('100%')
            Stack() {
              Polyline().points(this.uploads).fill(Color.Transparent).stroke(UI.accentText).strokeWidth(2)
              Polyline().points(this.downloads).fill(Color.Transparent).stroke(UI.muted).strokeWidth(2)
            }.width('100%').height(96).clip(true)
              .onAreaChange((_old: Area, area: Area) => { this.chartWidth = Number(area.width); })
            Row() {
              Text('5 分钟前').layoutWeight(1).fontSize(11).fontColor(UI.muted)
              Text('现在').fontSize(11).fontColor(UI.muted)
            }.width('100%')
          }.width('100%').padding({ bottom: 10 }).accessibilityGroup(true).accessibilityText('最近五分钟上传与下载速率')
        }
        this.Period(0, '本次')
        Divider().color(UI.line)
        this.Period(1, '今日')
        Divider().color(UI.line)
        this.Period(2, '本月')
        if (!this.snapshot.saved) {
          Text('记录未保存').fontSize(12).fontColor(UI.muted).width('100%').padding({ bottom: 16 })
        }
      }.width('100%').constraintSize({ maxWidth: 640 }).padding({ left: 24, right: 24, bottom: 24 })
    }.width('100%').height('100%').backgroundColor(UI.paper).scrollBar(BarState.Off)
  }
}
