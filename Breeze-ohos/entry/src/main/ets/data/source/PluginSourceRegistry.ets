/**
 * 职责：插件清单（PluginStore）↔ SourceManager 图源注册表的同步层（G1）。
 * 三约束（三条约束的裁决依据）：
 *  1. 只在 initBuiltIn() 之后被调用（否则顺序错乱/被覆盖）。
 *  2. syncFromStore 内部整体 try/catch 吞异常 + Logger.w —— 启动链上任何抛错都会让 app 白屏。
 *  3. 只注册清单静态信息（uuid/name/localFile）。清单没有显示名时用文件名派生，
 *     **绝不为取 name 去装载 bundle**（装载是异步且昂贵的，chip 条同步渲染）。
 * 本文件所有公开方法都不得抛（UI/启动链直接调用）。
 * 依据系统 Kit：无（纯 ArkTS，依赖 util + data 层）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SourceManager } from './SourceManager';
import { MangaSource } from './Source';
import { SourceInfo } from '../model/Models';
import { PLUGIN_SOURCE_PREFIX, PluginSourceAdapter } from './PluginSourceAdapter';
import { PluginImageOps } from './PluginImageOps';
import { PluginStore, PluginRecord } from '../../util/PluginStore';
import { Logger } from '../../util/Logger';

/** 清单显示名为空时，用文件名派生（去 .bundle.cjs/.cjs/.js 尾巴），不装载 bundle。 */
function deriveName(localFile: string): string {
  let n: string = localFile;
  if (n.endsWith('.bundle.cjs')) {
    n = n.slice(0, n.length - 11);
  } else if (n.endsWith('.cjs')) {
    n = n.slice(0, n.length - 4);
  } else if (n.endsWith('.js')) {
    n = n.slice(0, n.length - 3);
  }
  return n.length > 0 ? n : localFile;
}

/** 从 unknown 异常提取 message 原文（同 Index.ets:86 已验证写法）。 */
function em(e: Object): string {
  const x = e as Error;
  const m = x.message;
  if (typeof m === 'string' && m.length > 0) {
    return m;
  }
  return String(e);
}

export class PluginSourceRegistry {
  /**
   * 清单 → 注册表全量对齐（幂等，可反复调）：
   *  - 启用且文件存在的行 ⇒ register 适配器（只对象注册，零装载）。
   *  - 已注册但清单里被停用/删除/文件消失的 ⇒ unregister（chip 消失）。
   * 全程吞异常：返回同步条数只作日志用。
   */
  static async syncFromStore(context: common.Context): Promise<number> {
    let touched: number = 0;
    try {
      const filesDir: string = context.filesDir;
      const recs: PluginRecord[] = await PluginStore.loadAll(context);
      const want: Map<string, PluginRecord> = new Map<string, PluginRecord>();
      for (let i = 0; i < recs.length; i++) {
        const r: PluginRecord = recs[i];
        if (r.uuid.length === 0 || r.localFile.length === 0) {
          continue;
        }
        if (!r.enabled) {
          continue;
        }
        // 文件存在性校验：清单在、文件被外部删掉 ⇒ 不注册死图源（点了必错）。
        let exists: boolean = false;
        try {
          exists = fs.accessSync(filesDir + '/plugins/' + r.localFile);
        } catch (e) {
          exists = false;
        }
        if (!exists) {
          Logger.w('插件文件缺失，跳过图源注册：' + r.localFile);
          continue;
        }
        want.set(r.uuid, r);
      }

      const mgr: SourceManager = SourceManager.getInstance();
      const ops: PluginImageOps = PluginImageOps.install();

      // 先注销不再需要的（含本层注册过但已失效的）
      const stale: string[] = [];
      const infos: SourceInfo[] = mgr.list();
      for (let i = 0; i < infos.length; i++) {
        const id: string = infos[i].id;
        if (!id.startsWith(PLUGIN_SOURCE_PREFIX)) {
          continue;
        }
        const uuid: string = id.slice(PLUGIN_SOURCE_PREFIX.length);
        if (!want.has(uuid)) {
          stale.push(id);
        }
      }
      for (let i = 0; i < stale.length; i++) {
        mgr.unregister(stale[i]);
        ops.invalidate(stale[i]);
        touched++;
      }

      // 再注册/替换需要的（register 同 id 覆盖实例但保持顺序；重复 sync 安全）
      want.forEach((r: PluginRecord): void => {
        const name: string = r.name.length > 0 ? r.name : deriveName(r.localFile);
        const id: string = PLUGIN_SOURCE_PREFIX + r.uuid;
        mgr.register(new PluginSourceAdapter(r.uuid, name, r.localFile, filesDir));
        // 取图通道里缓存的适配器引用必须一起作废（否则更新后的插件还被旧实例代理）
        ops.invalidate(id);
      });
      touched += want.size;
      Logger.i('插件图源同步完成：启用 ' + want.size + ' 个，注销 ' + stale.length + ' 个');
    } catch (e) {
      Logger.w('插件图源同步失败（忽略，不影响启动）：' + em(e as Object));
    }
    return touched;
  }

  /** 单个插件注册（装载/启用后立即出现在发现页）。不抛。 */
  static registerOne(context: common.Context, uuid: string, name: string, localFile: string): void {
    if (uuid.length === 0) {
      return;
    }
    try {
      const disp: string = name.length > 0 ? name : deriveName(localFile);
      SourceManager.getInstance().register(
        new PluginSourceAdapter(uuid, disp, localFile, context.filesDir));
      PluginImageOps.install().invalidate(PLUGIN_SOURCE_PREFIX + uuid);
    } catch (e) {
      Logger.w('插件图源注册失败：' + em(e as Object));
    }
  }

  /** 单个注销（停用/删除/更新后调用；幂等）。不抛。 */
  static unregisterOne(uuid: string): void {
    if (uuid.length === 0) {
      return;
    }
    try {
      SourceManager.getInstance().unregister(PLUGIN_SOURCE_PREFIX + uuid);
      PluginImageOps.install().invalidate(PLUGIN_SOURCE_PREFIX + uuid);
    } catch (e) {
      Logger.w('插件图源注销失败：' + em(e as Object));
    }
  }

  /**
   * 更新落盘后的重载联动：适配器在内存里 ⇒ bundleLoadFromPath 覆盖装新文件；
   * 不在内存 ⇒ 不用管（下次取数自然装新文件）。不抛（失败仅日志 + 返回 false 给 UI 提示）。
   */
  static async reloadOne(context: common.Context, uuid: string): Promise<boolean> {
    if (uuid.length === 0) {
      return false;
    }
    try {
      const src: MangaSource | null = SourceManager.getInstance().get(PLUGIN_SOURCE_PREFIX + uuid);
      if (src === null) {
        return false;
      }
      if (!(src instanceof PluginSourceAdapter)) {
        return false;
      }
      const ad: PluginSourceAdapter = src as PluginSourceAdapter;
      if (!ad.isLoaded()) {
        return false;
      }
      await ad.reload();
      return true;
    } catch (e) {
      Logger.w('插件图源重载失败：' + em(e as Object));
      return false;
    }
  }
}
