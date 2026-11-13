/**
 * 职责：第 7 条「插件安装后自动装载；重新启动应用（或类似过程）自动载入」的唯一执行者。
 *       2026-11-11 用户裁定：插件管理页只留启用开关、不再提供「打开/装载」按钮
 *       => 所有装载时机从「用户点一下」迁到这里，页面不再自己持有装载逻辑。
 * 三个入口：
 *  - autoLoadAll：启动链（DataBootstrap）与插件页 refresh 共用，清单里「启用 + 文件在 + 不在内存」的全装。
 *  - loadOne：开关打开、设置页需要 bundle 在内存时的单点补装。
 *  - adoptAndLoad：目录里有文件但清单没有（商店刚下载完 / 用户自己丢文件）=> 登记 + 装载一步做完。
 * 三条硬约束：
 *  1. 任何方法都不抛（启动链与 UI 直接调）：失败只 Logger.w + 计数，插件故障绝不拖垮启动。
 *  2. 幂等：装载前 bundleList 实查，已在内存直接算成功 —— loadBundle 是整体替换语义，
 *     重复装载会洗掉插件内存态（登录态就是它洗掉的），所以「已装载」必须是 no-op。
 *  3. 与图源联动：装载成功即 registerOne + bump pluginSourceEpoch（发现页/搜索页 chip 即时同步）。
 * 开关持久化不用本文件负责：PluginStore.setEnabled 已落盘，enabled 随清单跨进程保留。
 * 依据系统 Kit：@kit.AbilityKit、@kit.CoreFileKit。
 */
import { common } from "@kit.AbilityKit";
import { fileIo as fs } from "@kit.CoreFileKit";
import { bundleCall, bundleList, bundleLoadFromPath } from "../../util/PluginRuntime";
import { PluginStore, PluginRecord } from "../../util/PluginStore";
import { jparse, jstr } from "../../util/JsonUtil";
import { deriveLocalUuid } from "../../util/PluginUuid";
import { Logger } from "../../util/Logger";
import { PluginSourceRegistry } from "./PluginSourceRegistry";

/** getInfo 本地超时（同 PluginManagerView 口径：三方 getInfo 可能自发网络请求，3.5s 后不等）。 */
const INFO_TIMEOUT_MS: number = 3500;

/** autoLoadAll 的汇总结果（UI 拿去显示一行文案，不参与判定）。 */
export class LoadOutcome {
  loaded: number = 0;
  failed: number = 0;
  /** 因为「已在内存 / 停用 / 文件缺失」跳过的条数（正常态就该有这个数）。 */
  skipped: number = 0;
  /** 首个失败原因（只留一条，够定位；全量在 hilog）。 */
  firstError: string = "";
  /** 清单里启用且可用的条数（UI 显示「已装载 k/n」的分母）。 */
  expected: number = 0;
}

function em(e: Object): string {
  const x = e as Error;
  const m = x.message;
  if (typeof m === "string" && m.length > 0) {
    return m;
  }
  return String(e);
}

function hasName(list: string[], name: string): boolean {
  for (let i = 0; i < list.length; i++) {
    if (list[i] === name) {
      return true;
    }
  }
  return false;
}

/** 图源注册表变了 => 通知发现页/搜索页刷 chip（键与 PluginManagerView 同一枚）。 */
function bumpSourceEpoch(): void {
  const n: number = (AppStorage.get<number>("pluginSourceEpoch") ?? 0) + 1;
  AppStorage.setOrCreate<number>("pluginSourceEpoch", n);
}

/** 全仓唯一一份「正在批量装载」闸门：启动链与插件页 refresh 并发时后者直接退让。 */
let batchRunning: boolean = false;

export class PluginAutoLoader {
  /** 批量装载是否在跑（UI 用来决定要不要提示「正在装载」）。 */
  static isBusy(): boolean {
    return batchRunning;
  }

  /**
   * 装载单个插件（幂等，不抛）：已在内存 => 直接 true；否则 bundleLoadFromPath + registerOne + bump。
   * 返回 false 表示装载失败（原因已进 hilog），调用方只改文案、不要弹错。
   */
  static async loadOne(context: common.Context, uuid: string, localFile: string, name: string): Promise<boolean> {
    if (uuid.length === 0 || localFile.length === 0) {
      return false;
    }
    const abs: string = context.filesDir + "/plugins/" + localFile;
    try {
      let inMem: boolean = false;
      try {
        inMem = hasName(await bundleList(), uuid);
      } catch (e) {
        inMem = false;
      }
      if (!inMem) {
        const ret: string = await bundleLoadFromPath(uuid, abs);
        if (ret !== "ok") {
          throw new Error("bundleLoadFromPath returned " + ret);
        }
      }
      PluginSourceRegistry.registerOne(context, uuid, name, localFile);
      if (!inMem) {
        bumpSourceEpoch();
      }
      return true;
    } catch (e) {
      Logger.w("插件自动装载失败 " + localFile + "：" + em(e as Object));
      return false;
    }
  }

  /**
   * 目录有文件、清单没有 => 登记 + 装载（旧「打开」按钮的语义，现在自动做）。
   * name 走一次带超时的 getInfo（失败不影响登记，标题退回 uuid，同历史行为）。
   * s13 第 1 条两点补强：
   *  ① nameHint/versionHint = 商店下载时随 shopMap 落盘的名字与版本号。getInfo 可能自己发网络
   *     请求而超时（INFO_TIMEOUT_MS 只有 3.5s），有 hint 就别让名字退化成文件名 —— 真机上
   *     「云收藏/插件管理显示 bf99008d-0.0.7.bundle.cjs 这串」就是这么来的。
   *  ② getInfo 成功顺手落一份原文进 PluginStore 的 getInfo 缓存（对齐 PluginSettings.info :596 的
   *     上游 persistGetInfoJson 语义）。此前全仓只有设置页会写那枚缓存，用户没进过设置页 ⇒ 云收藏
   *     的 resolveNames 永远读不到名字。
   * 成功返回登记用的 uuid，失败返回空串。不抛。
   */
  static async adoptAndLoad(context: common.Context, localFile: string, indexUuid: string,
    nameHint: string = '', versionHint: string = ''): Promise<string> {
    if (localFile.length === 0) {
      return "";
    }
    try {
      const uuid: string = deriveLocalUuid(localFile);
      if (!(await PluginAutoLoader.loadOne(context, uuid, localFile, ""))) {
        return "";
      }
      let name: string = "";
      let version: string = "";
      try {
        // getInfo 上游 argsJson 恒 "{}"（plugin_registry_service.dart:269）=> 传 "[{}]"，不是 "[]"。
        const infoJson: string = await Promise.race([
          bundleCall(uuid, "getInfo", "[{}]"),
          new Promise<string>((_resolve: (v: string) => void, reject: (err: Error) => void): void => {
            setTimeout((): void => {
              reject(new Error("getInfo timeout " + INFO_TIMEOUT_MS + "ms"));
            }, INFO_TIMEOUT_MS);
          })
        ]);
        const o: ESObject = jparse(infoJson);
        name = jstr(o, "name", "");
        if (jstr(o, "version", "").length > 0) {
          version = jstr(o, "version", "");
        }
        // 只在真拿到内容时落盘（与 PluginStore.saveGetInfo 的「失败绝不覆盖旧值」口径一致）
        if (name.length > 0 || version.length > 0) {
          await PluginStore.saveGetInfo(context, uuid, infoJson);
        }
      } catch (e) {
        // 三方 getInfo 可能自己发网络请求，超时不影响装载与登记
      }
      // 没商店名就退商店名（getInfo 超时档），两级都没有才由调用方退 uuid/文件名
      if (name.length === 0) {
        name = nameHint;
      }
      if (version.length === 0) {
        version = versionHint;
      }
      // 装载时（loadOne）名字还是空的 => 图源适配器显示名退成了文件名。这里拿到真名后补登记一次，
      // 否则云收藏 chip 的 cap.name（= adapter.displayName）会一直显示落盘文件名。registerOne 幂等。
      if (name.length > 0) {
        PluginSourceRegistry.registerOne(context, uuid, name, localFile);
      }
      const rec: PluginRecord = new PluginRecord();
      rec.uuid = uuid;
      rec.name = name;
      rec.localFile = localFile;
      rec.version = version;
      rec.sourceUrl = "";
      rec.sha256 = "";
      rec.enabled = true;
      rec.indexUuid = indexUuid;
      await PluginStore.save(context, rec);
      return uuid;
    } catch (e) {
      Logger.w("插件自动登记失败 " + localFile + "：" + em(e as Object));
      return "";
    }
  }

  /**
   * 批量自动装载（启动链 fire-and-forget、插件页 refresh 各调一次）：
   * 清单里 enabled 且文件存在且不在内存 => 逐个 loadOne。整体不抛，只汇总。
   * 并发的第二次调用直接返回空结果（batchRunning 闸门），免得两个 refresh 互相洗内存态。
   */
  static async autoLoadAll(context: common.Context): Promise<LoadOutcome> {
    const out: LoadOutcome = new LoadOutcome();
    if (batchRunning) {
      out.skipped = -1;
      return out;
    }
    batchRunning = true;
    try {
      const recs: PluginRecord[] = await PluginStore.loadAll(context);
      let inMem: string[] = [];
      try {
        inMem = await bundleList();
      } catch (e) {
        inMem = [];
      }
      for (let i = 0; i < recs.length; i++) {
        const r: PluginRecord = recs[i];
        if (!r.enabled || r.uuid.length === 0 || r.localFile.length === 0) {
          continue;
        }
        let exists: boolean = false;
        try {
          exists = fs.accessSync(context.filesDir + "/plugins/" + r.localFile);
        } catch (e) {
          exists = false;
        }
        if (!exists) {
          out.skipped++;
          continue;
        }
        out.expected++;
        if (hasName(inMem, r.uuid)) {
          out.loaded++;
          out.skipped++;
          continue;
        }
        if (await PluginAutoLoader.loadOne(context, r.uuid, r.localFile, r.name)) {
          out.loaded++;
        } else {
          out.failed++;
          if (out.firstError.length === 0) {
            out.firstError = r.localFile;
          }
        }
      }
    } catch (e) {
      out.firstError = em(e as Object);
      Logger.w("插件批量自动装载失败（忽略）：" + out.firstError);
    }
    batchRunning = false;
    return out;
  }

  /** 内存里现有 bundle 名单（插件页 join 用；失败给空数组，不抛）。 */
  static async memoryNames(): Promise<string[]> {
    try {
      return await bundleList();
    } catch (e) {
      return [];
    }
  }
}
