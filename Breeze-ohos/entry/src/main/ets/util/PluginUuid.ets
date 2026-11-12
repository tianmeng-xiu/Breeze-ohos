/**
 * 职责：文件名 -> 确定性 uuid 的唯一实现（2026-11-11 第 7 条改造时从
 *       view/plugins/PluginManagerView.ets 的私有函数抽出共享：数据层的自动装载也要用同一套规则，
 *       两份实现一旦漂移，已装载插件的 registry 键就会变 -> 配置与图源失联）。
 * 规则（与历史行为逐字一致，不得改）：尾部依次只剥一次 .bundle.cjs、.cjs、.js；
 *   非 [A-Za-z0-9_-] 全替换为连字符并折叠连续连字符；去首尾连字符；前缀 local-。
 *   纯函数不掺时间戳 => 同一文件重复装载必得同一 uuid。
 * 依据系统 Kit：无（纯 ArkTS）。
 */

/** 文件名 -> 确定性 uuid（ASCII 化，中文文件名转连字符）。 */
export function deriveLocalUuid(localFile: string): string {
  let s: string = localFile;
  if (s.endsWith(".bundle.cjs")) {
    s = s.slice(0, s.length - 11);
  } else if (s.endsWith(".cjs")) {
    s = s.slice(0, s.length - 4);
  } else if (s.endsWith(".js")) {
    s = s.slice(0, s.length - 3);
  }
  let out: string = "";
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    const ok: boolean = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
      || c === "_" || c === "-";
    out += ok ? c : "-";
  }
  while (out.indexOf("--") >= 0) {
    out = out.split("--").join("-");
  }
  if (out.startsWith("-")) {
    out = out.slice(1);
  }
  if (out.endsWith("-")) {
    out = out.slice(0, out.length - 1);
  }
  return "local-" + out;
}

/** 是否按插件文件对待（与 deriveLocalUuid 的剥尾规则一致）。 */
export function looksLikePluginFile(name: string): boolean {
  return name.endsWith(".bundle.cjs") || name.endsWith(".cjs") || name.endsWith(".js");
}
