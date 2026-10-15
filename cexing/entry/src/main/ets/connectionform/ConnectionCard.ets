const storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct ConnectionCard {
  @LocalStorageProp('label') label: string = '未连接';
  @LocalStorageProp('reportedAt') reportedAt: string = '';
  @LocalStorageProp('action') action: string = 'connect';
  @LocalStorageProp('verifiedAt') @Watch('refreshFreshness') verifiedAt: number = 0;
  @State fresh: boolean = false;

  aboutToAppear(): void { this.refreshFreshness(); }

  private refreshFreshness(): void {
    const age = Date.now() - this.verifiedAt;
    this.fresh = this.verifiedAt > 0 && age >= 0 && age <= 60000;
  }

  private statusText(): ResourceStr {
    if (this.verifiedAt === 0) { return $r('app.string.card_title'); }
    if (this.label === '已连接') { return $r('app.string.card_connected'); }
    if (this.label === '连接中') { return $r('app.string.card_connecting'); }
    if (this.label === '断开中') { return $r('app.string.card_disconnecting'); }
    if (this.label === '未连接') { return $r('app.string.card_disconnected'); }
    return $r('app.string.card_stop_unknown');
  }

  private buttonText(): ResourceStr {
    if (this.label === '断开中' && this.fresh) { return $r('app.string.card_stopping'); }
    return this.action === 'disconnect' ? $r('app.string.card_stop') : $r('app.string.card_start');
  }

  private open(): void {
    postCardAction(this, { action: 'router', moduleName: 'entry', abilityName: 'EntryAbility',
      params: { cexingConnectionAction: this.action } });
  }

  build() {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Row({ space: 4 }) {
          Image($r('app.media.app_icon')).accessibilityLevel('no').width(12).height(12).borderRadius(3)
          if (this.fresh || this.verifiedAt === 0) {
            Text($r('app.string.card_brand')).fontSize(10).fontColor($r('app.color.ui_muted'))
          } else {
            Text($r('app.string.card_previous')).fontSize(10).fontColor($r('app.color.ui_muted'))
          }
          TextClock().format('HH:mm').fontSize(9).fontColor($r('app.color.ui_muted'))
            .width(this.fresh ? 26 : 0).opacity(this.fresh ? 1 : 0)
            .onDateChange(() => this.refreshFreshness())
        }.width('100%')
        Text(this.statusText()).fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor(this.fresh && this.label === '已连接' ? $r('app.color.ui_accent_text') : $r('app.color.ui_ink'))
          .maxLines(1).minFontSize(12).maxFontSize(18)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button(this.buttonText()).constraintSize({ minWidth: 56, minHeight: 44 }).padding(0).fontSize(14).fontWeight(FontWeight.Medium)
        .backgroundColor(this.action === 'disconnect' ? $r('app.color.ui_soft') : $r('app.color.ui_action'))
        .fontColor(this.action === 'disconnect' ? $r('app.color.ui_accent_text') : $r('app.color.ui_on_accent'))
        .enabled(!(this.fresh && this.label === '断开中')).onClick(() => this.open())
    }.padding(12).width('100%').height('100%')
      .backgroundColor($r('app.color.ui_surface'))
  }
}
