# 离线资源恢复

`ResourceRecovery.inspect(context)` 只读检查 Smart 模型、GeoData 和面板资源，返回资源 ID、名称和 ready/missing/invalid 状态。不会触发下载、改写选择或访问用户域名。`restore(context, id, cancellation, canRestore)` 串行恢复，复用既有 Smart 模型和 Zashboard 安装器。失败拒绝 Promise，不将面板 last-good fallback 误报为恢复成功。

GeoData 从受信安装包读取；构建阶段 `prepare-geodata.py` 核验上游公开大小和 SHA-256 并记录来源身份。运行时比较入包与已安装文件的摘要，暂存文件写入/fsync 后重新读取核验，再原子 rename。写入、校验、取消、连接状态变化或发布失败均保留原文件。路径固定在应用私有目录，拒绝符号链接。无需在线下载，因此离线和下载取消不会损坏资源。

恢复入口应在内核已停止时使用。`canRestore` 在排队后调用，GeoData 在提交前再次调用；模型和面板复用其原有安装事务。取消令牌阻止排队中的操作；GeoData 支持提交前取消。模型/面板一旦进入既有安装器，完成的是其原子安装事务，页面返回仅忽略旧结果，不宣称已经撤销提交。资源不改变正在运行的模型或 Controller；下次启动采用恢复资源。

## 页面接线契约

UI 整合者导入 `ResourceRecoveryPage`，在高级设置提供“资源”入口，在对应 NavDestination 中渲染此组件。传入 `visible` 状态，并在 NavDestination 的 onShown/onHidden 更新它，覆盖导航缓存与页面切换。组件使用 `NativeTheme`；没有自行注册路由或更改 SettingsPage。列表显示状态与恢复操作，失败显示短反馈。重复点击、返回/重开和旧异步结果由页面 epoch 与服务队列保护。

GeoData 铺盘整合者可在既有资源准备处调用：

```typescript
if (await GeoDataAssets.inspect(context) !== 'ready') {
  await GeoDataAssets.restore(context, { cancelled: false });
}
```

该调用不更改 DNS listener、TUN、路由、Controller 或版本发布指针。无需替换配置事务。启动期间调用的上下文由启动资源所有者控制；设置恢复入口必须传入实时停止态谓词。
