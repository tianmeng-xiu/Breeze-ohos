/**
 * 职责：HTTP Cookie 持久化（按 host 存一条 "k=v; k2=v2"），供登录态类站点复用会话。
 * 替换原 Flutter 依赖：dio_cookie_manager / cookie_jar（原项目用 WindHttp 时无持久化，这里补齐）。
 * 依据系统 Kit：@kit.ArkData (preferences，经 PreferenceStore)。
 */
import { common } from '@kit.AbilityKit';
import { Logger } from '../../util/Logger';
import { PreferenceStore, PrefKeys } from '../kv/PreferenceStore';

/** 已出现过的 Cookie host 名单的配置键。 */
const HOST_INDEX_KEY: string = 'cookie_hosts';

/** set-cookie 里需要剔除的属性名（小写）。 */
const ATTR_BLACKLIST: string[] = [
  'path', 'domain', 'expires', 'max-age', 'samesite', 'httponly', 'secure',
  'version', 'comment', 'priority', 'partitioned'
];

export class CookieJar {
  private static instance: CookieJar | null = null;

  static getInstance(): CookieJar {
    if (CookieJar.instance === null) {
      CookieJar.instance = new CookieJar();
    }
    return CookieJar.instance;
  }

  /** 只是把底层的 PreferenceStore 拉起来，幂等。 */
  async init(context: common.UIAbilityContext): Promise<void> {
    await PreferenceStore.getInstance().init(context);
  }

  /** 手写 URL host 提取，避免依赖 @ohos.url（减少 API 差异风险）。 */
  hostOf(urlText: string): string {
    let s: string = urlText ? urlText : '';
    const schemeIdx: number = s.indexOf('://');
    if (schemeIdx >= 0) {
      s = s.substring(schemeIdx + 3);
    }
    const atIdx: number = s.indexOf('@');
    if (atIdx >= 0) {
      s = s.substring(atIdx + 1);
    }
    const cut: number[] = [s.indexOf('/'), s.indexOf('?'), s.indexOf('#')];
    let end: number = s.length;
    for (let i = 0; i < cut.length; i++) {
      const idx: number = cut[i];
      if (idx >= 0 && idx < end) {
        end = idx;
      }
    }
    s = s.substring(0, end);
    const portIdx: number = s.indexOf(':');
    if (portIdx >= 0) {
      s = s.substring(0, portIdx);
    }
    return s.toLowerCase();
  }

  /** 取该 URL 对应的 Cookie 请求头值，无则返回空串。 */
  headerFor(url: string): string {
    const host: string = this.hostOf(url);
    if (host.length === 0) {
      return '';
    }
    return PreferenceStore.getInstance().getString(PrefKeys.cookieKey(host), '');
  }

  /** 直接设置整条 Cookie 头（登录成功后手动注入用）。 */
  async setCookie(url: string, cookie: string): Promise<void> {
    const host: string = this.hostOf(url);
    if (host.length === 0) {
      return;
    }
    await PreferenceStore.getInstance().putString(PrefKeys.cookieKey(host), this.merge('', cookie));
    await this.rememberHost(host);
  }

  /** 把响应的 Set-Cookie（可能多条拼在一起）并进该 host 的 Cookie。 */
  async saveFromResponse(url: string, setCookie: string): Promise<void> {
    const host: string = this.hostOf(url);
    if (host.length === 0 || !setCookie || setCookie.length === 0) {
      return;
    }
    const key: string = PrefKeys.cookieKey(host);
    const oldStr: string = PreferenceStore.getInstance().getString(key, '');
    const merged: string = this.merge(oldStr, setCookie);
    if (merged === oldStr) {
      return;
    }
    await PreferenceStore.getInstance().putString(key, merged);
    await this.rememberHost(host);
    Logger.d('Cookie 已更新 host=' + host);
  }

  /** 清空全部已记录 host 的 Cookie（偏好库无前缀枚举，故自行维护 host 名单）。 */
  async clear(): Promise<void> {
    const prefs: PreferenceStore = PreferenceStore.getInstance();
    const hosts: string[] = this.knownHosts();
    for (let i = 0; i < hosts.length; i++) {
      await prefs.remove(PrefKeys.cookieKey(hosts[i]));
    }
    await prefs.remove(HOST_INDEX_KEY);
    Logger.i('已清空 Cookie，共 ' + hosts.length + ' 个 host');
  }

  /** 只清一个 host 的 Cookie，host 名单里保留（下次再拿到 Set-Cookie 不用重新登记）。 */
  async removeHost(host: string): Promise<void> {
    const h: string = host.trim().toLowerCase();
    if (h.length === 0) {
      return;
    }
    await PreferenceStore.getInstance().remove(PrefKeys.cookieKey(h));
  }

  /** 已记录过的 host 列表（逗号分隔）。 */
  knownHosts(): string[] {
    const raw: string = PreferenceStore.getInstance().getString(HOST_INDEX_KEY, '');
    if (raw.length === 0) {
      return [];
    }
    const parts: string[] = raw.split(',');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const h: string = parts[i].trim();
      if (h.length > 0) {
        out.push(h);
      }
    }
    return out;
  }

  /** 记录 host，避免 clear 时漏删（偏好库不支持按前缀枚举）。 */
  private async rememberHost(host: string): Promise<void> {
    const hosts: string[] = this.knownHosts();
    if (hosts.indexOf(host) >= 0) {
      return;
    }
    hosts.push(host);
    await PreferenceStore.getInstance().putString(HOST_INDEX_KEY, hosts.join(','));
  }

  /** 合并：旧串在前，新串覆盖同名键；属性名（Path/Domain/...）一律丢弃。 */
  private merge(oldStr: string, incoming: string): string {
    const map: Map<string, string> = new Map();
    this.collect(oldStr, map);
    this.collect(incoming, map);
    const parts: string[] = [];
    map.forEach((v: string, k: string) => {
      if (k.length > 0) {
        parts.push(k + '=' + v);
      }
    });
    return parts.join('; ');
  }

  private collect(raw: string, out: Map<string, string>): void {
    if (!raw) {
      return;
    }
    const normalized: string = raw.replace(/\r?\n/g, ';');
    const segments: string[] = normalized.split(';');
    for (let i = 0; i < segments.length; i++) {
      const seg: string = segments[i].trim();
      if (seg.length === 0) {
        continue;
      }
      const eq: number = seg.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const name: string = seg.substring(0, eq).trim();
      const value: string = seg.substring(eq + 1).trim();
      if (name.length === 0) {
        continue;
      }
      if (ATTR_BLACKLIST.indexOf(name.toLowerCase()) >= 0) {
        continue;
      }
      out.set(name, value);
    }
  }
}