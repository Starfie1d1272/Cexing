const storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct ConnectionCard {
  @LocalStorageProp('label') label: string = '状态待确认';
  @LocalStorageProp('reportedAt') reportedAt: string = '打开应用核对';

  private open(action: string): void {
    postCardAction(this, { action: 'router', moduleName: 'entry', abilityName: 'EntryAbility',
      params: { cexingConnectionAction: action } });
  }

  build() {
    Column({ space: 6 }) {
      Row() {
        Text('策星 · 连接').fontSize(12).fontColor('#52616A').layoutWeight(1)
        Text('应用最近报告').fontSize(10).fontColor('#52616A')
      }.width('100%')
      Text(this.label).fontSize(18).fontWeight(FontWeight.Medium).fontColor('#17262F')
        .width('100%').layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.reportedAt).fontSize(10).fontColor('#52616A').width('100%').maxLines(1)
      Row({ space: 10 }) {
        Button('连接').layoutWeight(1).height(40).fontSize(14).backgroundColor('#17262F')
          .fontColor(Color.White).onClick(() => this.open('connect'))
        Button('断开').layoutWeight(1).height(40).fontSize(14).backgroundColor('#E6F3F5')
          .fontColor('#006A7C').onClick(() => this.open('disconnect'))
      }.width('100%')
    }.padding(12).width('100%').height('100%')
      .backgroundColor('#FFFFFF').borderRadius(24)
  }
}
