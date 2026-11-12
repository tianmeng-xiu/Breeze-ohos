/**
 * 职责：JSON 动态取值工具。ArkTS 禁止把 JSON.parse 的结果当 any 用，因此所有来源解析都经这里逐字段取值，
 *       字段缺失/类型不符时返回默认值，保证解析永远"防御式"不抛异常。
 * 替换原 Flutter 依赖：dart:convert 的 dynamic 取值 (json['k'] as String?)。
 * 依据系统 Kit：ArkTS 标准库 (JSON / Array.isArray)，无三方依赖。
 */

/** 共享的空对象，供字段缺失/解析失败时回退（只读，调用方不得写入）。 */
const EMPTY_OBJ: ESObject = JSON.parse('{}');

/** 取字符串；number/boolean 会被转成字符串，其余返回 def。 */
export function jstr(o: ESObject, k: string, def: string): string {
  if (o === null || o === undefined) {
    return def;
  }
  const v: ESObject = o[k];
  if (v === null || v === undefined) {
    return def;
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number') {
    return (v as number).toString();
  }
  if (typeof v === 'boolean') {
    return (v as boolean) ? 'true' : 'false';
  }
  return def;
}

/** 取数字；无法转换时返回 def（含 NaN 保护）。 */
export function jnum(o: ESObject, k: string, def: number): number {
  if (o === null || o === undefined) {
    return def;
  }
  const v: ESObject = o[k];
  if (v === null || v === undefined) {
    return def;
  }
  if (typeof v === 'number') {
    const n: number = v as number;
    return isNaN(n) ? def : n;
  }
  if (typeof v === 'string') {
    const n: number = parseFloat(v as string);
    return isNaN(n) ? def : n;
  }
  return def;
}

/** 取整型（用于分页、序号）。 */
export function jint(o: ESObject, k: string, def: number): number {
  const n: number = jnum(o, k, def);
  return Math.trunc(n);
}

/** 取布尔；字符串 'true' 也算 true。 */
export function jbool(o: ESObject, k: string, def: boolean): boolean {
  if (o === null || o === undefined) {
    return def;
  }
  const v: ESObject = o[k];
  if (v === null || v === undefined) {
    return def;
  }
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  if (typeof v === 'string') {
    return (v as string).toLowerCase() === 'true';
  }
  if (typeof v === 'number') {
    return (v as number) !== 0;
  }
  return def;
}

/** 取子对象；不是对象时返回共享空对象（后续 jstr 会安全回退到 def）。 */
export function jobj(o: ESObject, k: string): ESObject {
  if (o === null || o === undefined) {
    return EMPTY_OBJ;
  }
  const v: ESObject = o[k];
  if (v === null || v === undefined || typeof v !== 'object') {
    return EMPTY_OBJ;
  }
  if (Array.isArray(v)) {
    return EMPTY_OBJ;
  }
  return v;
}

/** 取数组；不是数组时返回空数组。 */
export function jarr(o: ESObject, k: string): ESObject[] {
  if (o === null || o === undefined) {
    return [];
  }
  const v: ESObject = o[k];
  if (v === null || v === undefined || !Array.isArray(v)) {
    return [];
  }
  return v as ESObject[];
}

/** 取字符串数组（过滤非字符串元素）。 */
export function jstrArr(o: ESObject, k: string): string[] {
  const arr: ESObject[] = jarr(o, k);
  const out: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    const v: ESObject = arr[i];
    if (typeof v === 'string') {
      out.push(v as string);
    }
  }
  return out;
}

/** 是否含有该键且值非 null。 */
export function jhas(o: ESObject, k: string): boolean {
  if (o === null || o === undefined) {
    return false;
  }
  const v: ESObject = o[k];
  return v !== null && v !== undefined;
}

/**
 * 安全解析：空串/非法 JSON 返回共享空对象（不抛异常、不返回 null，避免 ESObject|null 联合类型）。
 * 用 jisEmpty 判断是否解析失败。
 */
export function jparse(text: string): ESObject {
  if (text === null || text === undefined || text.length === 0) {
    return EMPTY_OBJ;
  }
  try {
    const root: ESObject = JSON.parse(text);
    if (root === null || root === undefined || typeof root !== 'object') {
      return EMPTY_OBJ;
    }
    return root;
  } catch (err) {
    return EMPTY_OBJ;
  }
}

/** 是否为"解析失败/空响应"的共享空对象。 */
export function jisEmpty(o: ESObject): boolean {
  return o === EMPTY_OBJ;
}

/** string[] -> 数据库 TEXT 列（JSON 数组字面量）。 */
export function encodeTags(tags: string[]): string {
  if (tags === null || tags === undefined || tags.length === 0) {
    return '[]';
  }
  try {
    return JSON.stringify(tags);
  } catch (err) {
    return '[]';
  }
}

/** 数据库 TEXT 列 -> string[]，解析失败返回空数组。 */
export function decodeTags(text: string): string[] {
  const root: ESObject = jparse(text);
  if (!Array.isArray(root)) {
    return [];
  }
  const arr: ESObject[] = root as ESObject[];
  const out: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    const v: ESObject = arr[i];
    if (typeof v === 'string') {
      out.push(v as string);
    }
  }
  return out;
}