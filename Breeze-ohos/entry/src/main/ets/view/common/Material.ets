/**
 * 职责：材质能力探测 + 材质对象工厂（三档降级链与探测链的唯一实现点）。
 * 依赖：@kit.ArkUI（uiMaterial）、@kit.UIDesignKit（hdsMaterial / SystemMaterialParams）。
 * 规范（§6）：
 *  - 坑1：不许按 deviceInfo API level / 机型猜能力，必须运行时探测；探测结果一次缓存，禁止每帧重算。
 *  - 降级链：tier=2（HDS 沉浸材质可用）→ tier=1（原生 uiMaterial 沉浸材质可用）→ tier=0（平铺 + 不透明等价底色）。
 *  - 坑2：`.systemMaterial()` 与 `.backgroundColor()/.borderColor()/.borderWidth()/.shadow()` 互斥，
 *         调用方必须 if 二选一（本文件只生产材质对象，互斥由使用方分支保证）。
 *  - 坑3：无材质时下栏胶囊必须有「不透明等价底色」（见 Theme.capsuleFallback），本文件不提供颜色。
 * 关于 try：ArkTS 的顶层 `import` 无法 try 包裹。@kit.UIDesignKit / uiMaterial 已由 spike（spike-float）
 *  证明在本地 SDK 6.0.26 可编译，且目标机为华为 API26 真机；真正可能「运行时无该能力」的是探测调用本身，
 *  故所有能力查询与材质构造都包 try，失败即视为不支持（降级）。
 *
 * ===== s5e 真机修正：材质能力 ≠ 悬浮能力（两个独立维度，别混）=====
 * 真机 SGT-AL10 / OpenHarmony-7.0.0.111 / API26 回传「底栏未悬浮」，取证结果：hdsImmersive() 与
 * supported() **都是 false**（该 ROM 未开放沉浸材质），于是旧 tier() 直接落 FLAT ⇒ 走了平铺全宽栏。
 * 但悬浮胶囊本身不依赖材质：tabs.d.ts:1683 `barFloatingStyle(style: Optional<FloatingTabBarStyle>)`
 * 是 **@since 26.0.0 的布局属性**，且 FloatingTabBarStyle(:824) 全字段 optional ⇒ systemMaterial 可省。
 * 故拆两个闸门：tier() 只回答「能不能上材质」，floating() 只回答「能不能悬浮」。
 * floating() 用 SDK API 版本判定（不用 try 探测）：它是纯布局属性，没有可探测的构造调用，
 * 且在低版本系统上误用只是被忽略、不会抛错 ⇒ 与坑1（禁止用 API level 猜**材质**渲染力）不冲突。
 */
import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';
import deviceInfo from '@ohos.deviceInfo';

/**
 * §3 材质 Token（纯常量，类加载时不求值任何 HDS / ArkUI API —— 枚举一律在使用函数内取，
 * 避免在非华为运行时因类初始化失败导致整个模块 import 崩掉）。
 */
export class MaterialTokens {
  /** 底栏胶囊沉浸材质样式：REGULAR（§3） */
  static readonly barStyleName: string = 'REGULAR';
  /** 顶栏玻璃材质样式：THIN（§3，薄一档避免抢内容） */
  static readonly topBarStyleName: string = 'THIN';
  /** 材质叠加色：浅色模式 Transparent（§3） */
  static readonly materialColorLight: Color = Color.Transparent;
  /** 材质叠加色：深色模式 10% 白（§3） */
  static readonly materialColorDark: string = '#1A1C1C1E';
  /** 是否由系统绘制投影（§3） */
  static readonly applyShadow: boolean = true;
  /** 材质是否响应按压光效（§3：关闭，交互反馈统一交给 clickEffect） */
  static readonly interactive: boolean = false;
  /** 胶囊圆角（与 spike SPIKE-06 一致） */
  static readonly barCornerRadius: number = 28;
  /** 背景饱和度（与 spike SPIKE-06 一致） */
  static readonly barSaturation: number = 1.6;
}

/** 三档降级链的档位常量 */
export class Tier {
  static readonly FLAT: number = 0;
  static readonly NATIVE: number = 1;
  static readonly HDS: number = 2;
}

/** AppStorage 键：诊断面板显示探测明细用（不硬编码字符串，避免与 Index 侧拼写漂移） */
export class MatKeys {
  static readonly tier: string = 'matTier';
  static readonly hds: string = 'matHds';
  static readonly native: string = 'matNative';
  static readonly floating: string = 'matFloating';
  static readonly apiLevel: string = 'matApiLevel';
  /**
   * 底栏**实际渲染分支**（由 BreezeBottomTab 写入，取值 'hds' / 'native-material' / 'native-flat'）。
   * s5g 新增：s5e/s5f 两版都栽在「探测档位 ≠ 实际渲染」——面板报 float=true 但组件其实走了平铺分支，
   * 光看 tier/floating 两个布尔根本判不出真机为什么没浮起来。有这一行，一眼看出用的是哪个组件。
   */
  static readonly barMode: string = 'matBarMode';
}

/** 材质能力探测与材质对象工厂 */
export class SurfaceMaterial {
  /** tier 缓存哨兵：-1 = 未探测 */
  private static cachedTier: number = -1;
  /** floating 缓存哨兵：-1 = 未探测 */
  private static cachedFloating: number = -1;
  /** 沉淀 API 版本（诊断用） */
  private static cachedApi: number = 0;

  /** 原生沉浸材质是否可用（uiMaterial 能力闸门，§6 SPIKE-02 同源写法） */
  static supported(): boolean {
    try {
      return uiMaterial.isImmersiveMaterialSupported();
    } catch (err) {
      return false;
    }
  }

  /** HDS 沉浸材质是否可用（系统返回的可用材质类型里含 IMMERSIVE 才算） */
  static hdsImmersive(): boolean {
    try {
      const types: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
      return types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
    } catch (err) {
      return false;
    }
  }

  /**
   * 悬浮胶囊能力闸门（与材质无关）：Tabs.barFloatingStyle 是 @since 26.0.0 的布局属性，
   * FloatingTabBarStyle 全字段 optional ⇒ 无材质也能悬浮（s5e 真机修正，见文件头）。
   */
  static floating(): boolean {
    if (SurfaceMaterial.cachedFloating < 0) {
      let api: number = 0;
      try {
        api = deviceInfo.sdkApiVersion;
      } catch (err) {
        api = 0;
      }
      SurfaceMaterial.cachedApi = api;
      SurfaceMaterial.cachedFloating = api >= 26 ? 1 : 0;
    }
    return SurfaceMaterial.cachedFloating === 1;
  }

  /** 降级档位（探测一次即缓存，§6 明确要求不可每帧调） */
  static tier(): number {
    if (SurfaceMaterial.cachedTier < 0) {
      // 探测只跑一次，结果既定档也落 AppStorage
      const h: boolean = SurfaceMaterial.hdsImmersive();
      const n: boolean = SurfaceMaterial.supported();
      let t: number = Tier.FLAT;
      if (h) {
        t = Tier.HDS;
      } else if (n) {
        t = Tier.NATIVE;
      }
      SurfaceMaterial.cachedTier = t;
      // 探测明细写 AppStorage：诊断面板要能一眼看到「材质不可用但已悬浮」这种组合，
      // 否则真机又会把「无材质」误读成「改造没生效」（s5e 就是这么绕了一圈）。
      const f: boolean = SurfaceMaterial.floating();
      AppStorage.setOrCreate<number>(MatKeys.tier, t);
      AppStorage.setOrCreate<boolean>(MatKeys.hds, h);
      AppStorage.setOrCreate<boolean>(MatKeys.native, n);
      AppStorage.setOrCreate<boolean>(MatKeys.floating, f);
      AppStorage.setOrCreate<number>(MatKeys.apiLevel, SurfaceMaterial.cachedApi);
    }
    return SurfaceMaterial.cachedTier;
  }

  /** 当前档位能否使用原生 systemMaterial()（tier>=1） */
  static hasMaterial(): boolean {
    return SurfaceMaterial.tier() >= Tier.NATIVE;
  }

  /**
   * 构造沉浸材质对象。style 传 uiMaterial.ImmersiveStyle 枚举值，
   * materialColor 不传则按 §3 用「浅色 Transparent / 深色 #1A1C1C1E」。
   */
  static immersive(style: uiMaterial.ImmersiveStyle, materialColor?: ResourceColor): uiMaterial.ImmersiveMaterial {
    const color: ResourceColor = materialColor ?? MaterialTokens.materialColorLight;
    return new uiMaterial.ImmersiveMaterial({
      style: style,
      materialColor: color,
      applyShadow: MaterialTokens.applyShadow,
      interactive: MaterialTokens.interactive
    });
  }

  /** 底栏胶囊材质（REGULAR，§3） */
  static barMaterial(isDark: boolean): uiMaterial.ImmersiveMaterial {
    return SurfaceMaterial.immersive(
      uiMaterial.ImmersiveStyle.REGULAR,
      isDark ? MaterialTokens.materialColorDark : MaterialTokens.materialColorLight
    );
  }

  /** 顶栏玻璃材质（THIN，§3） */
  static topBarMaterial(isDark: boolean): uiMaterial.ImmersiveMaterial {
    return SurfaceMaterial.immersive(
      uiMaterial.ImmersiveStyle.THIN,
      isDark ? MaterialTokens.materialColorDark : MaterialTokens.materialColorLight
    );
  }

  /** HDS 材质参数（SPIKE-03 实证写法：类型化对象字面量对 SDK interface 合法） */
  static hdsParams(): SystemMaterialParams {
    const p: SystemMaterialParams = {
      materialType: hdsMaterial.MaterialType.IMMERSIVE,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
    };
    return p;
  }

  /**
   * HDS「自动档」材质参数（s5g 引入，抄 NextE 已上线写法）。
   * 依据 NextE shared/settings/ImmersiveMaterialSettings.ets:125-155 effect()：
   * 当 getSystemMaterialTypes() 里**没有** IMMERSIVE 时，它**不降级组件**，而是照旧用 HdsTabs，
   * 只把参数换成 ADAPTIVE/ADAPTIVE 交给系统自行选择材质。
   * 这条路线是 NextE 在同类华为机型上跑通的悬浮胶囊形态；我们 s5f 的 tier0+barBackgroundColor
   * 路线在真机上渲染成平铺全宽栏（用户反馈「底栏未成胶囊」），故改走这里。
   */
  static hdsParamsAuto(): SystemMaterialParams {
    let immersive: boolean = false;
    try {
      const types: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
      immersive = types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
    } catch (err) {
      immersive = false;
    }
    const p: SystemMaterialParams = immersive
      ? {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
      : {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      };
    return p;
  }
}
