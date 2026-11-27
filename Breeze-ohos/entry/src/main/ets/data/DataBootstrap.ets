/**
 * 职责：数据层统一初始化入口。EntryAbility.onCreate 里只需调用一次 initDataLayer(this.context)。
 * 替换原 Flutter 依赖：main.dart 里的 ObjectBox.create()/SharedPreferences.getInstance()/GetIt 注册。
 * 依据系统 Kit：@kit.AbilityKit (common.UIAbilityContext)。
 *
 * 初始化顺序（有依赖，不可打乱）：
 *   PreferenceStore -> CookieJar(依赖偏好库) -> DbHelper -> MangaRepository -> ImageCache -> SourceManager
 * 全部幂等，重复调用安全（热重载/多页面并发调用都不会重复建库）。
 */
import { common } from '@kit.AbilityKit';
import { PreferenceStore, PrefKeys } from './kv/PreferenceStore';
import { CookieJar } from './net/CookieJar';
import { HttpClient } from './net/HttpClient';
import { DbHelper } from './db/DbHelper';
import { MangaRepository } from './db/MangaRepository';
import { ImageCache } from './image/ImageCache';
import { SourceManager } from './source/SourceManager';
import { PluginSourceRegistry } from './source/PluginSourceRegistry';
import { PluginImageOps } from './source/PluginImageOps';
import { PluginAutoLoader, LoadOutcome } from './source/PluginAutoLoader';
import { Logger } from '../util/Logger';

/** 建议在 EntryAbility.onCreate 的 onWindowStageCreate 之前 await 一次。 */
export async function initDataLayer(context: common.UIAbilityContext): Promise<void> {
  await PreferenceStore.getInstance().init(context);
  await CookieJar.getInstance().init(context);

  // 用户自定义 UA 优先，未设置则用 HttpClient 内置默认值
  const savedUa: string = PreferenceStore.getInstance().getString(PrefKeys.USER_AGENT, '');
  if (savedUa.length > 0) {
    HttpClient.getInstance().setUserAgent(savedUa);
  }

  await DbHelper.getInstance().init(context);
  await MangaRepository.getInstance().init(context);
  await ImageCache.getInstance().init(context);
  // 插件取图/反混淆通道（s6j）：必须在 ImageCache 之后、图源注册之前，纯对象注册零副作用
  PluginImageOps.install();

  // 注册内置图源（MangaDex），幂等。s52：这一句同时按偏好把内置源的可见性下发一遍
  // （内置源默认关 ⇒ 它仍在册可读，只是不进发现页/搜索页的来源条，见 data/source/SourceManager 头注释）。
  SourceManager.getInstance().initBuiltIn();

  // G1：插件清单 → 图源注册表。必须在 initBuiltIn() 之后；内部整体吞异常，
  // 这里再兜一层 try/catch —— 插件链任何故障都不得拖垮 EntryAbility 启动。
  try {
    await PluginSourceRegistry.syncFromStore(context);
  } catch (e) {
    Logger.w('插件图源同步失败（忽略）：' + ((e as Error).message ?? String(e)));
  }
  Logger.i('数据层初始化完成');

  // 第 7 条（2026-11-11 用户裁定）：插件自动装载。**刻意不 await**：
  //  - 三方 bundle 的顶层代码可能自发网络请求，等它 = 拖慢首帧（本函数整体是 fire-and-forget，
  //    但内部 await 链一长，图源 chip 出现得更晚）；
  //  - 装载失败不影响启动（PluginAutoLoader 内部逐个 try/catch，只计数不抛）。
  // 顺序约束：必须在 syncFromStore 之后 —— 先有适配器再有 bundle，chip 与取数才对得上。
  // 引擎侧无需等待：EntryAbility.onCreate 里 probePluginEngine 的 engineInit 是同步跑的。
  PluginAutoLoader.autoLoadAll(context).then((n: LoadOutcome): void => {
    Logger.i('插件自动装载：成功 ' + n.loaded + '，失败 ' + n.failed + '，跳过 ' + n.skipped);
  }).catch((e: Error): void => {
    Logger.w('插件自动装载失败（忽略）：' + (e.message ?? String(e)));
  });
}
