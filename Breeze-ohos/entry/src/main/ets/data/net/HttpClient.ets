/**
 * 职责：全局 HTTP 客户端。GET/POST、自定义 header（Map）、超时、Cookie 自动带上/回写、gzip 自动解压、
 *       非 2xx 抛 HttpStatusError（含状态码与 body 片段）、UA 可设置、getBytes 返回 ArrayBuffer。
 * 替换原 Flutter 依赖：dio / WindHttp（network/http/wind_http.dart，rust reqwest 桥接）。
 * 依据系统 Kit：@kit.NetworkKit (http)，Cookie 持久化走 @kit.ArkData (preferences)。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../util/Logger';
import { CookieJar } from './CookieJar';

/**
 * 默认 UA：写成「应用标识」而不是浏览器串。
 * 原因（实测，2026-11）：MangaDex 的 Cloudflare 机器人策略对「浏览器 UA + 非浏览器 TLS 指纹」直接返回
 *   403 'Bot challenge not passed, refresh this page.'
 * 换成 'Breeze-OHOS/1.0' 这类非浏览器 UA 后 /ping、/manga、uploads 封面全部 200。
 * 需要伪装浏览器的站点请自行 setUserAgent() 或按请求传 User-Agent header 覆盖。
 */
/** 供设置页「清空即恢复默认」比对与回写用（s7a）：别再抄第二份字面量。 */
export const DEFAULT_UA: string = 'Breeze-OHOS/1.0';

/**
 * 非 2xx 响应异常：沿用 FetchException 的语义（保留状态码与正文片段便于降级）。
 * 同时暴露 code（= statusCode），因此也可以按 BusinessError 的方式 catch：
 *   catch (e) { const be = e as BusinessError; if (be.code === 404) { ... } }
 */
export class HttpStatusError extends Error {
  code: number = 0;
  statusCode: number = 0;
  bodyPreview: string = '';

  constructor(status: number, message: string, preview: string) {
    super(message);
    this.name = 'HttpStatusError';
    this.code = status;
    this.statusCode = status;
    this.bodyPreview = preview;
  }
}

export class HttpClient {
  private static instance: HttpClient | null = null;
  private ua: string = DEFAULT_UA;
  private timeoutMs: number = 30000;
  private connectTimeoutMs: number = 15000;

  static getInstance(): HttpClient {
    if (HttpClient.instance === null) {
      HttpClient.instance = new HttpClient();
    }
    return HttpClient.instance;
  }

  setUserAgent(ua: string): void {
    if (ua && ua.length > 0) {
      this.ua = ua;
    }
  }

  getUserAgent(): string {
    return this.ua;
  }

  /** 设置读超时（同时把连接超时收敛到不超过读超时）。 */
  setTimeout(ms: number): void {
    if (ms > 0) {
      this.timeoutMs = ms;
      this.connectTimeoutMs = ms > 15000 ? 15000 : ms;
    }
  }

  // ------------------------------------------------------------ GET

  async getText(url: string, headers?: Map<string, string>): Promise<string> {
    const res: http.HttpResponse =
      await this.request(url, http.RequestMethod.GET, http.HttpDataType.STRING, headers, undefined);
    const raw: string | Object | ArrayBuffer = res.result;
    if (typeof raw === 'string') {
      return raw as string;
    }
    throw new Error('网络响应类型异常：期望文本，实际不是');
  }

  async getJson<T>(url: string, headers?: Map<string, string>): Promise<T> {
    const text: string = await this.getText(url, headers);
    if (text.length === 0) {
      throw new Error('网络响应为空，无法解析 JSON');
    }
    try {
      const parsed: T = JSON.parse(text) as T;
      return parsed;
    } catch (err) {
      throw new Error('JSON 解析失败：' + (err as Error).message);
    }
  }

  async getBytes(url: string, headers?: Map<string, string>): Promise<ArrayBuffer> {
    const res: http.HttpResponse =
      await this.request(url, http.RequestMethod.GET, http.HttpDataType.ARRAY_BUFFER, headers, undefined);
    const raw: string | Object | ArrayBuffer = res.result;
    if (raw instanceof ArrayBuffer) {
      return raw as ArrayBuffer;
    }
    throw new Error('网络响应类型异常：期望二进制，实际不是');
  }

  // ------------------------------------------------------------ POST

  /** 以字符串 body 发 POST（默认 Content-Type: application/json，可由 headers 覆盖）。 */
  async postText(url: string, body: string, headers?: Map<string, string>): Promise<string> {
    const res: http.HttpResponse =
      await this.request(url, http.RequestMethod.POST, http.HttpDataType.STRING, headers, body);
    const raw: string | Object | ArrayBuffer = res.result;
    if (typeof raw === 'string') {
      return raw as string;
    }
    throw new Error('网络响应类型异常：期望文本，实际不是');
  }

  // ------------------------------------------------------------ 内部

  private async request(url: string, method: http.RequestMethod, dataType: http.HttpDataType,
    extra?: Map<string, string>, body?: string): Promise<http.HttpResponse> {
    const hasBody: boolean = body !== undefined && body !== null;
    const headerMap: Map<string, string> = this.buildHeaderMap(url, extra, hasBody);
    const options: http.HttpRequestOptions = {
      method: method,
      header: this.mapToObject(headerMap),
      connectTimeout: this.connectTimeoutMs,
      readTimeout: this.timeoutMs,
      expectDataType: dataType,
      usingCache: false
    };
    if (body !== undefined) {
      options.extraData = body;
    }

    const req: http.HttpRequest = http.createHttp();
    let res: http.HttpResponse | null = null;
    try {
      res = await req.request(url, options);
    } catch (err) {
      const be = err as BusinessError;
      Logger.e('网络请求失败 ' + url + ' code=' + be.code + ' message=' + be.message);
      throw new Error('网络请求失败(' + be.code + ')：' + (be.message ? be.message : '请检查网络连接'));
    } finally {
      req.destroy();
    }
    if (res === null) {
      throw new Error('网络请求未返回结果：' + url);
    }

    const code: number = res.responseCode;
    if (code < 200 || code >= 300) {
      const preview: string = this.previewOf(res);
      Logger.e('HTTP ' + code + ' ' + url + ' ' + preview);
      throw new HttpStatusError(code, '请求失败 HTTP ' + code + '：' + url, preview);
    }

    // 回写 Cookie（失败不影响本次请求）
    const setCookie: string = res.cookies;
    if (setCookie && setCookie.length > 0) {
      try {
        await CookieJar.getInstance().saveFromResponse(url, setCookie);
      } catch (err) {
        Logger.ex('Cookie 回写失败', err as Object);
      }
    }
    return res;
  }

  private buildHeaderMap(url: string, extra: Map<string, string> | undefined, hasBody: boolean): Map<string, string> {
    const m: Map<string, string> = new Map();
    m.set('User-Agent', this.ua);
    // 不要手动设 Accept-Encoding：@kit.NetworkKit 默认已请求 gzip 并自动解压，
    // 手动声明反而可能拿到未解压的字节流。
    m.set('Accept', '*/*');
    m.set('Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8');
    if (hasBody) {
      m.set('Content-Type', 'application/json; charset=utf-8');
    }
    const cookie: string = CookieJar.getInstance().headerFor(url);
    if (cookie.length > 0) {
      m.set('Cookie', cookie);
    }
    if (extra !== undefined && extra !== null) {
      extra.forEach((v: string, k: string) => {
        m.set(k, v);
      });
    }
    return m;
  }

  /**
   * Map -> 普通对象。ArkTS 禁止索引签名，无法动态赋值属性，
   * 因此借 JSON.parse 构造（JSON.parse 返回 Object，正好匹配 header?: Object）。
   */
  private mapToObject(m: Map<string, string>): Object {
    const parts: string[] = [];
    m.forEach((v: string, k: string) => {
      if (k.length > 0) {
        parts.push(JSON.stringify(k) + ':' + JSON.stringify(v));
      }
    });
    const text: string = '{' + parts.join(',') + '}';
    const header: Object = JSON.parse(text);
    return header;
  }

  private previewOf(res: http.HttpResponse): string {
    const raw: string | Object | ArrayBuffer = res.result;
    if (typeof raw === 'string') {
      const normalized: string = (raw as string).replace(/\s+/g, ' ').trim();
      return normalized.length > 200 ? normalized.substring(0, 200) + '…' : normalized;
    }
    if (raw instanceof ArrayBuffer) {
      return '(二进制响应 ' + (raw as ArrayBuffer).byteLength + ' 字节)';
    }
    return '';
  }
}