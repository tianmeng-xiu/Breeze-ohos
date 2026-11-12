/**
 * 职责：把「插件回包里的字符串值」洗成能直接上屏的显示文案 —— 一处实现，两处共用：
 *  1) data/source/PluginLogin.ets 的 cleanInitialValue：登录表单初值（真机 BUG3-a，
 *     用户名/密码框一进来就带着两个引号字符，要手删才能输）；
 *  2) pages/PluginSettingsPage.ets 的 valOf：设置页每行副标题与「未设置」判定
 *     （同一根因的第二现场：插件把未登录的账号存成引号字面量 ⇒ 判不空 ⇒ 原样显示成两个引号）。
 *
 * 根因在插件侧，不在宿主：不少插件把「没填过」序列化成引号字面量（两个双引号、两个单引号、
 * 或带反斜杠的转义形态），而上游 values 原样铺平、登录页又是 TextInput 直接吃初值
 * ⇒ 引号直接落进输入框 / 落进设置页副标题。清洗规则只在**本文件这一处**定义，
 * 两个调用方都不得再各写一份（历史上正是「只洗了登录侧、没洗设置侧」才漏出这一屏）。
 *
 * 规则（与原 PluginLogin 里的实现逐字等价，没有新增、也没有放宽任何一条）：
 *  1) trim 后为空 ⇒ 视为未提供（登录侧不写进 initial，设置侧走「未设置」）；
 *  2) 整值被一对引号包住 ⇒ 逐层剥掉再判空：空引号对 ⇒ 空、引号包 abc ⇒ abc；
 *  3) 其余原样返回。数字/布尔由调用方先 String 再过同一规则（它们的字面量里没有引号对，
 *     等价于只 trim），非文本字段的原值语义不变。
 *
 * 纯函数、无副作用、不读全局 ⇒ 可离线单测（_tmp/login_fix/clean_cases.cjs 覆盖八个形态）。
 */
export function cleanDisplayValue(raw: string): string {
  let s: string = raw.trim();
  // 最多剥三层：真实形态最深是「转义引号包空串」，三层足够且不会死循环（每轮长度必减）
  for (let i = 0; i < 3; i++) {
    const n: number = s.length;
    if (n < 2) {
      break;
    }
    const head: string = s.charAt(0);
    const tail: string = s.charAt(n - 1);
    // 成对引号（双引号与单引号两种形态）整体剥一层
    if ((head === '"' && tail === '"') || (head === "'" && tail === "'")) {
      s = s.substring(1, n - 1).trim();
      continue;
    }
    // 转义形态：首尾各是「反斜杠 + 引号」，合计 4 个字符
    if (n >= 4 && s.startsWith('\\\"') && s.endsWith('\\\"')) {
      s = s.substring(2, n - 2).trim();
      continue;
    }
    break;
  }
  return s.trim();
}
