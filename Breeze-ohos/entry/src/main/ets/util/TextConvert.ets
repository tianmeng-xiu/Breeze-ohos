/**
 * 职责：简繁转换引擎（仅界面显示）。把上游 Breeze/lib/util/text/chinese_convert.dart 的
 * convertChineseForDisplay 语义搬到 ArkTS：读 rawfile/convert 下的 OpenCC 官方词典，
 * 同步查表转换标题、简介、章节名等展示文案。
 * 依据系统 Kit：@kit.LocalizationKit (resourceManager)、@kit.ArkTS (util.TextDecoder)。
 *
 * 词典：OpenCC 官方数据（Apache-2.0，https://github.com/BYVoid/OpenCC），
 * 四份 TSV 在 entry/src/main/resources/rawfile/convert/ 下，许可声明见仓库根 NOTICE.md。
 *
 * 三处相对上游的有意偏差（改动前先读这段，别当成疏漏"修回去"）：
 * 一、只带 TSCharacters / TSPhrases / STCharacters / STPhrases 四份，不带
 * TWVariants、TWVariantsPhrases、TWVariantsNouns、TWPhrases。那几份做的是
 * 「异体字与地区用词本地化」（例如 裏→裡、國際化→國際化 一类的选字偏好），
 * 对漫画标题与章节名属于过度本地化：会按地区习惯替换原作选字，且词典翻倍
 * （TWPhrases 一族约 6.6 MB）对包体与首次加载都不划算。上游自己也只在
 * 显示层用了 t2s / s2t 两条曲线（chinese_convert.dart），没有开 TW 一族。
 * 二、转换语义 = OpenCC 的 short_circuit 单趟扫描：同一位置先按短语表从长到短
 * （长度上限取该档短语表实际最大键长）试匹配，命中就整段吐出并跳过整段，
 * 未命中才查单字表。**绝不许拆成"先整趟短语、再整趟单字"两趟**：两趟会把
 * 短语已经产出的字再喂给单字表，乾隆（TSPhrases 里的恒等屏蔽项）会被第二趟
 * 的 乾→干 改坏成 干隆。
 * 三、表里 乾隆→乾隆、乾坤大挪移→乾坤大挪移 这类"键值相同"的行不是冗余，
 * 是 short_circuit 语义必需的屏蔽项（占住位置，阻止后面的单字规则改写它）。
 * 实测条数：TSPhrases 111 条 / STPhrases 1579 条恒等行，两份单字表 0 条。
 * 解析时不得过滤掉这些行。
 *
 * 另两条硬口径：
 * 一、只作用于界面显示。搜索匹配、书名黑名单/屏蔽词匹配一律不参与
 * （上游另有一条固定转简体的 t2s() 用于匹配，本工程刻意不实现，
 * 这是与上游唯一有意的功能差异，写进过 requirements 口径）。
 * 二、cvt 是同步的、给 build() 直调：词典未就绪时原样返回，首帧绝不等待 IO。
 * 词典是异步读入的，读完后经 bumpRev 推 AppStorage 版本号，各显示处用
 * @StorageProp 观察它才会重绘（TabContent 与 @Builder 快照的既有坑都靠这条兜）。
 */
import { resourceManager } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';
import { ChineseConvertMode } from './UserSettings';

/** 词典目录内相对路径（rawfile 下读取一律不带 rawfile/ 前缀）。 */
const RAW_TS_PHRASE: string = 'convert/TSPhrases.tsv';
const RAW_TS_CHAR: string = 'convert/TSCharacters.tsv';
const RAW_ST_PHRASE: string = 'convert/STPhrases.tsv';
const RAW_ST_CHAR: string = 'convert/STCharacters.tsv';

/** 结果缓存条数上限：与上游 chinese_convert.dart 的 2000 一致，超了整表清空。 */
const CACHE_MAX: number = 2000;

/**
 * 简繁转换引擎（进程内单例）。
 * 不用 struct，纯 class：无 UI，只被查表方持有。
 */
export class TextConvert {
  private static inst: TextConvert | undefined = undefined;

  /** 繁→简短语表（TSPhrases）。当前档不需要时保持为空。 */
  private tsPhrase: Map<string, string> = new Map<string, string>();
  /** 繁→简单字表（TSCharacters）。 */
  private tsChar: Map<string, string> = new Map<string, string>();
  /** 简→繁短语表（STPhrases）。 */
  private stPhrase: Map<string, string> = new Map<string, string>();
  /** 简→繁单字表（STCharacters）。 */
  private stChar: Map<string, string> = new Map<string, string>();

  /** 繁→简短语表最大键长（按码点计），空表为 0。 */
  private tsPhraseMax: number = 0;
  /** 简→繁短语表最大键长（按码点计），空表为 0。 */
  private stPhraseMax: number = 0;

  /**
   * 可能作为匹配起点的码点集合：所有单字表的键 + 所有短语键的首码点。
   * 只给"输入里一个都不在就原样返回"这条快路用。必须把短语键的首码点也算进来：
   * 有的短语键（如 大目乾連冥間救母變文）首字在单字表里没有条目，
   * 只按单字表判"有没有可转换的字"会把它整条跳过。
   */
  private heads: Set<string> = new Set<string>();

  /** 当前档：off / simplified / traditional，取值见 UserSettings 的 ChineseConvertMode。 */
  private currentMode: string = ChineseConvertMode.OFF;
  /** 词典已就绪并可供当前档使用（off 档视为直接就绪）。 */
  private readyFlag: boolean = false;
  /** 已实际载入的词典配对（避免同档重复读 800 KB 词典）。 */
  private loadedFor: string = '';
  /** 结果缓存：键 = 档位 + '|' + 原文，与上游同款。 */
  private cache: Map<string, string> = new Map<string, string>();
  /** 最近一次读词典 + 建表的毫秒数（未读过 = -1；诊断 20 号行 featChain 用）。 */
  private loadMs: number = -1;
  /** 本进程切档/就绪推送次数（诊断用；与 AppStorage 版本号同源计数）。 */
  private revCount: number = 0;
  /** 在途加载的档位与 Promise：同档并发只读一次。 */
  private loadingMode: string = '';
  private loadingPromise: Promise<boolean> | undefined = undefined;

  /** 界面响应式副本键：词典就绪或档位切换后自增，各显示处 @StorageProp 观察。 */
  static readonly STORAGE_CONVERT_REV: string = 'textConvertRev';

  private constructor() {
  }

  static getInstance(): TextConvert {
    if (TextConvert.inst === undefined) {
      TextConvert.inst = new TextConvert();
    }
    return TextConvert.inst;
  }

  /** 推一次界面刷新版本号（AppStorage 数值自增，观察方重绘）。 */
  static bumpRev(): void {
    const n: number = (AppStorage.get<number>('textConvertRev') ?? 0) + 1;
    AppStorage.setOrCreate<number>('textConvertRev', n);
    if (TextConvert.inst !== undefined) {
      TextConvert.inst.revCount = n;
    }
  }

  /**
   * 诊断 20 号行用的单行摘要（不计入 verdict）。字段顺序固定，判读口径写在 pages/Index.ets。
   * mode= off/simplified/traditional；ready= 当前档可查表；loadMs= 最近一次读表建表毫秒（-1 = 本进程没读过）；
   * rev= bumpRev 累计次数（0 = 从未就绪过也没切过档 ⇒ 各处 cvtShow 全走原样返回）；
   * cache= 结果缓存条数；tsP/tsC/stP/stC= 四张表当前条数（另一档被 releaseUnused 释放 ⇒ 应为 0）。
   */
  stats(): string {
    return 'mode=' + this.currentMode + ' ready=' + (this.readyFlag ? 1 : 0)
      + ' loadMs=' + this.loadMs + ' rev=' + this.revCount + ' cache=' + this.cache.size
      + ' tsP=' + this.tsPhrase.size + ' tsC=' + this.tsChar.size
      + ' stP=' + this.stPhrase.size + ' stC=' + this.stChar.size;
  }

  /** 当前档（读的是本类字段，与 AppStorage 副本相互独立）。 */
  getMode(): string {
    return this.currentMode;
  }

  /** 当前档是否可直接查表（off 视为就绪，便于调用方不再重试）。 */
  isReady(): boolean {
    return this.readyFlag;
  }

  /**
   * 载入指定档所需的词典配对；off 档不读任何文件。
   * 同档重复调用直接回已有就绪态；同档并发只发一次 IO。
   * @param mode 目标档
   * @param rm 由调用方传入的 resourceManager（单例内不调 getContext）
   */
  async ensureReady(mode: string, rm: resourceManager.ResourceManager): Promise<boolean> {
    this.currentMode = mode;
    if (mode === ChineseConvertMode.OFF) {
      this.readyFlag = true;
      this.loadedFor = ChineseConvertMode.OFF;
      return true;
    }
    if (this.loadedFor === mode && this.readyFlag) {
      return true;
    }
    // 载入期间明确判为未就绪：不这样做的话，切到一档而它的表还是空时，
    // cvt 会把整段文字按「查不到的单字」原样吐出，看起来像转换无声失效。
    this.readyFlag = false;
    if (this.loadingMode === mode && this.loadingPromise !== undefined) {
      const dup: boolean = await this.loadingPromise;
      return dup && this.currentMode === mode && this.readyFlag;
    }
    this.loadingMode = mode;
    const task: Promise<boolean> = this.loadPair(mode, rm);
    this.loadingPromise = task;
    const ok: boolean = await task;
    if (this.loadingMode === mode) {
      this.loadingMode = '';
      this.loadingPromise = undefined;
    }
    // 只在「本档仍是当前档」时提交状态：并发切档（冷启动预热未完就改了设置）时，
    // 后发的那次拥有状态归属，先完成的那次只丢表不点亮就绪位。
    if (ok && this.currentMode === mode) {
      this.loadedFor = mode;
      this.readyFlag = true;
    }
    return ok;
  }

  /**
   * 切档：先落当前档，off 立刻推版本号（让已转换的文案马上退回原文），
   * 其余档异步读词典，读完再推版本号（失败也推：界面据此能显示「词典未就绪」，
   * 而不是假装已经生效停在原文上）。
   */
  async setMode(mode: string, rm: resourceManager.ResourceManager): Promise<void> {
    if (mode === this.currentMode && (mode === ChineseConvertMode.OFF || this.readyFlag)) {
      return;
    }
    this.currentMode = mode;
    if (mode === ChineseConvertMode.OFF) {
      this.releaseUnused(ChineseConvertMode.OFF);
      this.readyFlag = true;
      this.loadedFor = ChineseConvertMode.OFF;
      TextConvert.bumpRev();
      return;
    }
    const ok: boolean = await this.ensureReady(mode, rm);
    if (ok && this.currentMode === mode) {
      this.releaseUnused(mode);
    }
    TextConvert.bumpRev();
  }

  /**
   * 同步转换一段展示文案（build() 可直调）。
   * off 档或词典未就绪 ⇒ 原样返回；输入里没有任何可能命中的字 ⇒ 原样返回且不进缓存。
   */
  cvt(text: string): string {
    if (text.length === 0) {
      return text;
    }
    if (this.currentMode === ChineseConvertMode.OFF || !this.readyFlag) {
      return text;
    }
    const phrase: Map<string, string> = this.currentMode === ChineseConvertMode.SIMPLIFIED
      ? this.tsPhrase : this.stPhrase;
    const single: Map<string, string> = this.currentMode === ChineseConvertMode.SIMPLIFIED
      ? this.tsChar : this.stChar;
    const cacheKey: string = this.currentMode + '|' + text;
    const cached: string | undefined = this.cache.get(cacheKey);
    if (cached !== undefined) {
      return cached;
    }
    // 按码点切片：charCodeAt 落在高位代理区间就取两格 UTF-16 单元当一个字。
    // 单字表里存在星历区（两格一码点）的键，按 UTF-16 单元切会切坏这些键。
    const units: number = text.length;
    const chars: string[] = [];
    const starts: number[] = [];
    let p: number = 0;
    while (p < units) {
      const code: number = text.charCodeAt(p);
      const wide: boolean = code >= 0xD800 && code <= 0xDBFF && p + 1 < units;
      const next: number = wide ? p + 2 : p + 1;
      starts.push(p);
      chars.push(text.substring(p, next));
      p = next;
    }
    starts.push(units);
    const n: number = chars.length;
    let touchable: boolean = false;
    for (let j = 0; j < n; j = j + 1) {
      if (this.heads.has(chars[j])) {
        touchable = true;
        break;
      }
    }
    if (!touchable) {
      return text;
    }
    const maxLen: number = this.currentMode === ChineseConvertMode.SIMPLIFIED
      ? this.tsPhraseMax : this.stPhraseMax;
    let out: string = '';
    let i: number = 0;
    while (i < n) {
      let matched: boolean = false;
      let len: number = maxLen;
      if (len > n - i) {
        len = n - i;
      }
      for (; len >= 2; len = len - 1) {
        const key: string = text.substring(starts[i], starts[i + len]);
        const hit: string | undefined = phrase.get(key);
        if (hit !== undefined) {
          out += hit;
          i += len;
          matched = true;
          break;
        }
      }
      if (matched) {
        continue;
      }
      const one: string | undefined = single.get(chars[i]);
      out += one !== undefined ? one : chars[i];
      i += 1;
    }
    if (this.cache.size > CACHE_MAX) {
      this.cache.clear();
    }
    this.cache.set(cacheKey, out);
    return out;
  }

  /** 只留当前档所需的表，另一档释放（STPhrases 四万条，两档同留太占内存）。 */
  private releaseUnused(mode: string): void {
    if (mode === ChineseConvertMode.SIMPLIFIED) {
      this.stPhrase.clear();
      this.stChar.clear();
      this.stPhraseMax = 0;
    } else if (mode === ChineseConvertMode.TRADITIONAL) {
      this.tsPhrase.clear();
      this.tsChar.clear();
      this.tsPhraseMax = 0;
    } else {
      this.stPhrase.clear();
      this.stChar.clear();
      this.tsPhrase.clear();
      this.tsChar.clear();
      this.stPhraseMax = 0;
      this.tsPhraseMax = 0;
    }
    this.rebuildHeads();
  }

  /** 重建快路用的首字集合（表变动后必须调，否则快路会误判"没有可转换的字"）。 */
  private rebuildHeads(): void {
    this.heads.clear();
    this.tsChar.forEach((target: string, source: string): void => {
      this.heads.add(source);
    });
    this.stChar.forEach((target: string, source: string): void => {
      this.heads.add(source);
    });
    this.addPhraseHeads(this.tsPhrase);
    this.addPhraseHeads(this.stPhrase);
  }

  /** 把短语键的首码点并进快路集合。 */
  private addPhraseHeads(table: Map<string, string>): void {
    table.forEach((target: string, source: string): void => {
      const code: number = source.charCodeAt(0);
      const wide: boolean = code >= 0xD800 && code <= 0xDBFF && source.length > 1;
      this.heads.add(wide ? source.substring(0, 2) : source.substring(0, 1));
    });
  }

  /** 读两份 TSV 并填表（只在真正需要该档时调用）。 */
  private async loadPair(mode: string, rm: resourceManager.ResourceManager): Promise<boolean> {
    const phrasePath: string = mode === ChineseConvertMode.SIMPLIFIED ? RAW_TS_PHRASE : RAW_ST_PHRASE;
    const charPath: string = mode === ChineseConvertMode.SIMPLIFIED ? RAW_TS_CHAR : RAW_ST_CHAR;
    const t0: number = Date.now();
    try {
      const phraseText: string = await this.readRaw(rm, phrasePath);
      const charText: string = await this.readRaw(rm, charPath);
      if (mode === ChineseConvertMode.SIMPLIFIED) {
        this.tsPhraseMax = TextConvert.fillTable(phraseText, this.tsPhrase);
        TextConvert.fillTable(charText, this.tsChar);
      } else {
        this.stPhraseMax = TextConvert.fillTable(phraseText, this.stPhrase);
        TextConvert.fillTable(charText, this.stChar);
      }
      this.rebuildHeads();
      this.loadMs = Date.now() - t0;
      Logger.i('简繁词典就绪 mode=' + mode
        + ' tsP=' + this.tsPhrase.size + ' tsC=' + this.tsChar.size
        + ' stP=' + this.stPhrase.size + ' stC=' + this.stChar.size
        + ' maxLen=' + (mode === ChineseConvertMode.SIMPLIFIED ? this.tsPhraseMax : this.stPhraseMax));
      return true;
    } catch (err) {
      Logger.w('简繁词典读取失败 mode=' + mode + ' err=' + (err as Error).message);
      return false;
    }
  }

  /** 读 rawfile 文本（异步版；getRawFileContentSync 全仓零使用，不引）。 */
  private async readRaw(rm: resourceManager.ResourceManager, path: string): Promise<string> {
    const u8: Uint8Array = await rm.getRawFileContent(path);
    const dec: util.TextDecoder = util.TextDecoder.create('utf-8');
    return dec.decodeToString(u8);
  }

  /**
   * 解析一份 TSV 填进表：跳过空行与首个字符是井号的注释行，
   * 以第一个制表符分键值，值去掉首尾空白，同键取首次出现的行。
   * 键值相同的行是屏蔽项，照旧入表。
   * @returns 该表的最大键长（按码点计）
   */
  static fillTable(rawText: string, table: Map<string, string>): number {
    const rows: string[] = rawText.split('\n');
    let maxKeyLen: number = 0;
    for (let j = 0; j < rows.length; j = j + 1) {
      let row: string = rows[j];
      if (row.length === 0 || row.startsWith('#')) {
        continue;
      }
      if (row.endsWith('\r')) {
        row = row.substring(0, row.length - 1);
      }
      const tab: number = row.indexOf('\t');
      if (tab <= 0) {
        continue;
      }
      const key: string = row.substring(0, tab);
      const target: string = row.substring(tab + 1).trim();
      if (table.has(key)) {
        continue;
      }
      table.set(key, target);
      let cps: number = 0;
      let q: number = 0;
      while (q < key.length) {
        const code: number = key.charCodeAt(q);
        q = (code >= 0xD800 && code <= 0xDBFF && q + 1 < key.length) ? q + 2 : q + 1;
        cps += 1;
      }
      if (cps > maxKeyLen) {
        maxKeyLen = cps;
      }
    }
    return maxKeyLen;
  }
}
