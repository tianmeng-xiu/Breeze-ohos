/**
 * 职责：ImageCache 的插件侧实现（data/image/BytesChannel 的接线端）。
 * 为什么放 data/source：这里要 import SourceManager / PluginSourceAdapter / PreferenceStore，
 *   反向放在 data/image 会形成 import 环（ImageCache→SourceManager→Adapter→…→ImageCache）。
 * 三件事：
 *   1. 取字节：图源已注册且是 PluginSourceAdapter ⇒ 转调 Adapter.fetchImageBytes（带插件
 *      Referer/风控头）；内置图源（MangaDex）回 null，让 ImageCache 走宿主 HTTP。
 *   2. 反混淆意图：读 preferences `jmDeobf:<uuid>`（auto/on/off）→ 再按章节号是否可能分块裁剪。
 *      ★ 必须对同一入参稳定（结果参与缓存键），所以这里不查图像内容、不看时间。
 *   3. isJm 探测：成功/失败都记忆（照抄上游 picture.dart:33-68 的记忆表语义），避免每页跨一次 QJS。
 * 约定：对外一律收**图源 id**（'plugin:<uuid>'），前缀运算只在本文件内做一次。
 * 依据系统 Kit：无（纯 data 层）。
 */
import { PluginImageChannel, BytesChannels } from '../image/BytesChannel';
import { shouldDeobfuscate, segmentationNum, pictureNameOf } from '../image/JmDeobfuscate';
import { SourceManager } from './SourceManager';
import { MangaSource } from './Source';
import { PLUGIN_SOURCE_PREFIX, PluginSourceAdapter } from './PluginSourceAdapter';
import { PreferenceStore, PrefKeys } from '../kv/PreferenceStore';
import { Logger } from '../../util/Logger';

/** 空入参对象（bundleCall 要求 args 是数组，元素形状由 fnPath 决定；isJm 上游传 {}）。 */
class EmptyArg {
}

export class PluginImageOps implements PluginImageChannel {
  /** 图源 id → 适配器（页图量大，每页查一次注册表太碎）。 */
  private adapters: Map<string, PluginSourceAdapter> = new Map<string, PluginSourceAdapter>();
  /** isJm 探测记忆：抛错与 false 都记 false（上游 picture.dart:36 同语义）。 */
  private jmProbe: Map<string, boolean> = new Map<string, boolean>();
  /** 反混淆模式记忆（写开关时由 setMode 主动更新）。 */
  private modes: Map<string, string> = new Map<string, string>();

  private static instance: PluginImageOps | null = null;

  /** 装进通道（DataBootstrap 里调一次；幂等）。 */
  static install(): PluginImageOps {
    if (PluginImageOps.instance === null) {
      PluginImageOps.instance = new PluginImageOps();
      BytesChannels.register(PluginImageOps.instance);
    }
    return PluginImageOps.instance;
  }

  static current(): PluginImageOps | null {
    return PluginImageOps.instance;
  }

  /** 图源注册/注销后调用，丢掉缓存的适配器引用（否则更新后的插件还被旧实例代理）。 */
  invalidate(sourceId: string): void {
    this.adapters.delete(sourceId);
    this.modes.clear();
  }

  private adapterFor(sourceId: string): PluginSourceAdapter | null {
    const hit: PluginSourceAdapter | undefined = this.adapters.get(sourceId);
    if (hit !== undefined) {
      return hit;
    }
    if (!sourceId.startsWith(PLUGIN_SOURCE_PREFIX)) {
      return null;
    }
    const src: MangaSource | null = SourceManager.getInstance().get(sourceId);
    if (src === null || !(src instanceof PluginSourceAdapter)) {
      return null;
    }
    const ad: PluginSourceAdapter = src as PluginSourceAdapter;
    this.adapters.set(sourceId, ad);
    return ad;
  }

  async fetch(sourceId: string, url: string): Promise<ArrayBuffer | null> {
    const ad: PluginSourceAdapter | null = this.adapterFor(sourceId);
    if (ad === null) {
      return null;
    }
    return ad.fetchImageBytes(url);
  }

  /** 读模式（不抛，缺省 auto）。 */
  private modeOf(uuid: string): string {
    const hit: string | undefined = this.modes.get(uuid);
    if (hit !== undefined) {
      return hit;
    }
    let m: string = 'auto';
    try {
      m = PreferenceStore.getInstance().getString(PrefKeys.JM_DEOBF_PREFIX + uuid, 'auto');
    } catch (e) {
      m = 'auto';
    }
    if (m !== 'on' && m !== 'off' && m !== 'auto') {
      m = 'auto';
    }
    this.modes.set(uuid, m);
    return m;
  }

  /** 设置页改开关时调用：先写偏好库，再更新内存（写库失败也接受本次内存值，不阻塞 UI）。 */
  async setMode(sourceId: string, mode: string): Promise<void> {
    const m: string = mode === 'on' || mode === 'off' ? mode : 'auto';
    const uuid: string = sourceId.startsWith(PLUGIN_SOURCE_PREFIX)
      ? sourceId.slice(PLUGIN_SOURCE_PREFIX.length)
      : sourceId;
    try {
      await PreferenceStore.getInstance().putString(PrefKeys.JM_DEOBF_PREFIX + uuid, m);
    } catch (e) {
      Logger.w('写入反混淆开关失败（本次仅内存生效）');
    }
    this.modes.set(uuid, m);
  }

  /** 当前模式（设置页回显用）。 */
  mode(sourceId: string): string {
    const uuid: string = sourceId.startsWith(PLUGIN_SOURCE_PREFIX)
      ? sourceId.slice(PLUGIN_SOURCE_PREFIX.length)
      : sourceId;
    return this.modeOf(uuid);
  }

  /** isJm 探测（异步、记忆、吞异常；只认裸 true = 上游 _parseIsJmResult 语义）。 */
  private async probeIsJm(ad: PluginSourceAdapter): Promise<boolean> {
    const hit: boolean | undefined = this.jmProbe.get(ad.uuid);
    if (hit !== undefined) {
      return hit;
    }
    let isJm: boolean = false;
    try {
      const raw: ESObject = await ad.callExt('探测 isJm', 'isJm', new EmptyArg());
      isJm = raw === true;
    } catch (e) {
      isJm = false;
    }
    this.jmProbe.set(ad.uuid, isJm);
    Logger.i('插件 isJm 探测：' + ad.displayName + ' = ' + isJm);
    return isJm;
  }

  async deobfIntent(sourceId: string, chapterId: string, url: string): Promise<string> {
    const ad: PluginSourceAdapter | null = this.adapterFor(sourceId);
    if (ad === null) {
      return '';
    }
    const mode: string = this.modeOf(ad.uuid);
    if (mode === 'off') {
      return '';
    }
    // 章节号根本不会分块 ⇒ 直接免做（省一次探测与解码后的检测）
    const epsId: number = parseInt(chapterId, 10);
    if (!isFinite(epsId) || segmentationNum(epsId, pictureNameOf(url)) <= 1) {
      return '';
    }
    if (mode === 'on') {
      return 'force';
    }
    const probed: boolean = await this.probeIsJm(ad);
    return shouldDeobfuscate('auto', ad.uuid, probed) ? 'force' : 'detect';
  }
}
