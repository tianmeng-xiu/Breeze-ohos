/**
 * 职责：图源注册表（单例）。内置源在构造时自动注册，也允许运行期 register 自定义源。
 * 替换原 Flutter 依赖：breeze 的 comic_source 全局实例与 dart 侧 switch 分支。
 * 依据系统 Kit：无（纯 ArkTS），仅依赖 data/source 内的接口。
 */
import { SourceInfo } from '../model/Models';
import { MangaSource, SourceIds } from './Source';
import { MangadexSource } from './MangadexSource';
import { Logger } from '../../util/Logger';

export class SourceManager {
  private static instance: SourceManager | null = null;
  /** id -> 源实例；插入顺序即 list() 顺序。 */
  private sources: Map<string, MangaSource> = new Map();
  private order: string[] = [];
  private builtInDone: boolean = false;

  private constructor() {
  }

  /** 单例：首次取用时自动注册内置源（幂等）。 */
  static getInstance(): SourceManager {
    if (SourceManager.instance === null) {
      const mgr: SourceManager = new SourceManager();
      mgr.initBuiltIn();
      SourceManager.instance = mgr;
    }
    return SourceManager.instance;
  }

  /** 注册（同 id 覆盖元数据但保持位置）。 */
  register(s: MangaSource): void {
    if (s === null || s === undefined) {
      return;
    }
    const id: string = s.info().id;
    if (id.length === 0) {
      Logger.w('忽略 id 为空的源');
      return;
    }
    if (!this.sources.has(id)) {
      this.order.push(id);
    }
    this.sources.set(id, s);
    Logger.i('图源已注册：' + id);
  }

  /** 注销一个源（G1：插件停用/删除后 chip 消失）。不存在则忽略；两张表同删，重注册顺序稳定。 */
  unregister(id: string): void {
    if (!this.sources.has(id)) {
      return;
    }
    this.sources.delete(id);
    const i: number = this.order.indexOf(id);
    if (i >= 0) {
      this.order.splice(i, 1);
    }
    Logger.i('图源已注销：' + id);
  }

  /** 已注册源描述列表（供设置页/发现页展示）。 */
  list(): SourceInfo[] {
    const out: SourceInfo[] = [];
    for (let i = 0; i < this.order.length; i++) {
      const s: MangaSource | undefined = this.sources.get(this.order[i]);
      if (s !== undefined) {
        out.push(s.info());
      }
    }
    return out;
  }

  get(id: string): MangaSource | null {
    const s: MangaSource | undefined = this.sources.get(id);
    return s === undefined ? null : s;
  }

  /** 取源，取不到直接抛可展示的中文错误（调用方不必再判空）。 */
  require(id: string): MangaSource {
    const s: MangaSource | null = this.get(id);
    if (s === null) {
      throw new Error('未找到图源：' + id);
    }
    return s;
  }

  has(id: string): boolean {
    return this.sources.has(id);
  }

  /** 注册内置源；重复调用安全。 */
  initBuiltIn(): void {
    if (this.builtInDone) {
      return;
    }
    this.builtInDone = true;
    this.register(new MangadexSource());
    Logger.i('内置图源数量：' + this.order.length + '（' + SourceIds.MANGADEX + '）');
  }
}
