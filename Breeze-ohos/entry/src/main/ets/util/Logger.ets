/**
 * 职责：全局日志门面。统一 domain/tag，支持运行期等级开关，其它模块一律经此类输出，不直接调 hilog。
 * 替换原 Flutter 依赖：logger / debugPrint（无三方包，纯自研封装）。
 * 依据系统 Kit：@kit.PerformanceAnalysisKit (hilog)。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 日志域号，Breeze 专用。 */
export const LOG_DOMAIN: number = 0xB2E2;
/** 日志 TAG，随进程出现在 DevEco 的 HiLog 面板。 */
export const LOG_TAG: string = 'Breeze';

/** 等级常量，数值越小越详细。 */
export const LEVEL_DEBUG: number = 0;
export const LEVEL_INFO: number = 1;
export const LEVEL_WARN: number = 2;
export const LEVEL_ERROR: number = 3;
export const LEVEL_NONE: number = 4;

export class Logger {
  private static minLevel: number = LEVEL_DEBUG;

  /** 设置最低输出等级（LEVEL_DEBUG / LEVEL_INFO / LEVEL_WARN / LEVEL_ERROR / LEVEL_NONE）。 */
  static setLevel(level: number): void {
    Logger.minLevel = level;
  }

  static isEnabled(level: number): boolean {
    return level >= Logger.minLevel && Logger.minLevel !== LEVEL_NONE;
  }

  static d(msg: string): void {
    if (!Logger.isEnabled(LEVEL_DEBUG)) {
      return;
    }
    hilog.debug(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }

  static i(msg: string): void {
    if (!Logger.isEnabled(LEVEL_INFO)) {
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }

  static w(msg: string): void {
    if (!Logger.isEnabled(LEVEL_WARN)) {
      return;
    }
    hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }

  static e(msg: string): void {
    if (!Logger.isEnabled(LEVEL_ERROR)) {
      return;
    }
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }

  /** 打印异常：Message 优先取 BusinessError.code，便于定位系统 Kit 报错。 */
  static ex(tag: string, err: Object): void {
    if (!Logger.isEnabled(LEVEL_ERROR)) {
      return;
    }
    let detail: string = '';
    if (err instanceof Error) {
      detail = (err as Error).message;
    } else {
      detail = JSON.stringify(err);
    }
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', tag + ' -> ' + detail);
  }
}
