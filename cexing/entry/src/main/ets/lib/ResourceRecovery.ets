import { common } from '@kit.AbilityKit';
import { GeoDataAssets, ResourceCancellation } from './GeoDataAssets';
import { SmartModelAssets } from './SmartModelAssets';
import { ZashboardAssets } from './ZashboardAssets';

export type RecoverableResource = 'model' | 'geodata' | 'panel';
export interface ResourceStatus {
  id: RecoverableResource;
  label: string;
  state: string;
}

// No controller, network or settings mutation. Entry owners must offer recovery
// only after stopping the engine; the returned files are adopted on next start.
export class ResourceRecovery {
  private static queue: Promise<void> = Promise.resolve();

  static async inspect(context: common.Context): Promise<ResourceStatus[]> {
    const model = await SmartModelAssets.inspect(context);
    const geodata = await GeoDataAssets.inspect(context);
    const panel = await ZashboardAssets.inspect(context);
    return [{ id: 'model', label: 'Smart 模型', state: model.state },
      { id: 'geodata', label: 'GeoData', state: geodata },
      { id: 'panel', label: '面板', state: panel }];
  }

  static restore(context: common.Context, id: RecoverableResource,
    cancellation: ResourceCancellation, canRestore: () => boolean): Promise<void> {
    const job = ResourceRecovery.queue.then(async (): Promise<void> => {
      if (cancellation.cancelled) { throw new Error('已取消'); }
      if (!canRestore()) { throw new Error('请先断开连接'); }
      if (id === 'geodata') {
        try { await GeoDataAssets.restore(context, cancellation, canRestore); }
        catch (_) {
          if (cancellation.cancelled) { throw new Error('已取消'); }
          if (!canRestore()) { throw new Error('请先断开连接'); }
          throw new Error('GeoData 恢复失败，请检查安装包与可用空间');
        }
      } else if (id === 'model') {
        const result = await SmartModelAssets.prepare(context);
        if (result.state !== 'ready') { throw new Error('模型恢复失败，请检查安装包与可用空间'); }
      } else if (id === 'panel') {
        const result = await ZashboardAssets.prepare(context);
        if (result.directory === '' || result.fallback) { throw new Error('面板恢复失败，已保留可用版本'); }
      } else { throw new Error('无法恢复此资源'); }
    });
    ResourceRecovery.queue = job.then(() => {}, () => {});
    return job;
  }
}
