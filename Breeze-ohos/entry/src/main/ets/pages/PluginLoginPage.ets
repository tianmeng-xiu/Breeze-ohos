/**
 * 职责：插件「账号登录」页（第 10 路由）。用户回传缺陷③「插件的登录功能未实现」。
 * 流程对齐上游（权威两份，改逻辑前先读它们）：
 *   Breeze/lib/page/login/login_page.dart             :116 取方案 / :142-232 建表单 /
 *                                                     :236-276 验证码图 / :351-419 提交
 *   Breeze/lib/page/login/slider_captcha_dialog.dart   滑块取题 / 轨迹 / 验题（一次一题）
 * 业务调用全在 data/source/PluginLogin.ets（入参口径 + 会话保持真相写在那份文件头），
 * 本页只管状态机、表单与手势。
 *
 * 入口：pages/PluginSettingsPage「登录」分组 → router.pushUrl('pages/PluginLoginPage',
 *       data/source/PluginLogin.ets 导出的 PluginLoginParams)。
 * 状态机：loading（取方案）→ form（表单）/ error（不支持或取方案失败，给「重试」）。
 * 滑块：页内底部弹层（上游是独立 Dialog 路由；我方无登录路由栈 ⇒ 弹层等价，
 *       遮罩与卡片仍是 Stack 兄弟层：ClickEvent 没有 stopPropagation）。
 *       轨迹口径 = [elapsedMs, dx/scale 一位小数, y 取整]，首点 [0,0,0]，>500 点去掉第二个，
 *       <3 点不上报只归零；验题失败立刻换新题（旧 token 作废）。
 *
 * ⚠ 四条实现约束（都是本仓库已验证的坑，别顺手「优化」）：
 * 1) PixelMap 由页面持有，替换与 aboutToDisappear 都要 release（本页会反复进出）。
 * 2) 表单值表用**非 @State 的 Map** 持有：TextInput 的 text 只在重绘时回读，
 *    onChange 写 Map 不触发重绘 ⇒ 中文输入法不跳字。做成 @State 每敲一个字光标回开头。
 * 3) V1 @State 只观察**顶层属性赋值**：滑块的位移/错误/图都是一级 @State 字段，
 *    没有塞进某个 @State 对象的二级属性里（那样改了不重绘）。
 * 4) 值表变更后需要重绘的地方（验证码图）用「换整个 Map 引用」触发（同 PluginSettingsPage 口径）。
 */
import { promptAction, router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme, Dim } from '../view/common/Theme';
import { LoadingView, ErrorView } from '../view/common/StateViews';
import {
  PluginLogin,
  PluginLoginParams,
  LoginScheme,
  LoginField,
  SliderChallenge,
  CaptchaImage,
  LoginResult
} from '../data/source/PluginLogin';
import { PluginSettings } from '../data/source/PluginSettings';
import { Logger } from '../util/Logger';

/** 轨迹点上限（上游 >500 去掉第二个点）。 */
const TRACK_MAX: number = 500;

/** busy 的「正在提交」取值（提交期间禁用按钮并改文案）。 */
const BUSY_SUBMIT: string = '__submit__';

@Entry
@Component
struct PluginLoginPage {
  @StorageProp('isDark') isDark: boolean = false;

  // ---------------- 路由参数与页面阶段 ----------------
  @State uuid: string = '';
  @State pluginName: string = '';
  @State localFile: string = '';
  @State loading: boolean = true;
  @State loadError: string = '';
  @State scheme: LoginScheme | null = null;

  // ---------------- 表单 ----------------
  /** 值表：非 @State（见文件头约束 2）。键 = field.key（含滑块 pass 与验证码文本）。 */
  private values: Map<string, string> = new Map<string, string>();
  /** 验证码图：@State + 每次整体换引用（约束 4）。 */
  @State captchaImages: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  /** 正在取验证码的字段 key（空串 = 没有）。 */
  @State captchaBusyKey: string = '';
  /** 取失败过的字段 key（行内给「点击重试」提示）。 */
  @State captchaFailedKeys: string[] = [];
  @State busy: string = '';

  // ---------------- 滑块弹层（全部一级 @State，约束 3）----------------
  @State sliderOpen: boolean = false;
  @State sliderLoading: boolean = false;
  @State sliderErr: string = '';
  @State sliderBg: image.PixelMap | undefined = undefined;
  @State sliderPiece: image.PixelMap | undefined = undefined;
  @State sliderImageW: number = 320;
  @State sliderImageH: number = 180;
  @State sliderPieceY: number = 0;
  @State sliderPieceSize: number = 52;
  @State sliderBgW: number = 0;
  @State sliderKnob: number = 0;
  /** 当前滑块字段（弹层归属，不需要重绘 ⇒ 普通字段） */
  private sliderField: LoginField | null = null;
  private sliderToken: string = '';
  private sliderCreateFn: string = '';
  private sliderVerifyFn: string = '';
  private dragBaseDx: number = 0;
  private dragStartT: number = 0;
  private track: number[][] = [];

  aboutToAppear(): void {
    // 参数取法与 pages/PluginSettingsPage.ets:91-107 同范式（pushUrl 传实例 ⇒ instanceof；
    // 兜底 ESObject 分支应对外部直接 router.pushUrl 传字面量）
    try {
      const raw: Object = router.getParams();
      if (raw instanceof PluginLoginParams) {
        this.uuid = raw.uuid;
        this.pluginName = raw.name;
        this.localFile = raw.localFile;
      } else if (raw !== null && raw !== undefined) {
        const src: ESObject = raw;
        this.uuid = src.uuid !== undefined ? String(src.uuid) : '';
        this.pluginName = src.name !== undefined ? String(src.name) : '';
        this.localFile = src.localFile !== undefined ? String(src.localFile) : '';
      }
    } catch (err) {
      Logger.w('PluginLoginPage 参数解析失败：' + (err as Error).message);
    }
    this.load();
  }

  aboutToDisappear(): void {
    // 页面销毁时释放所有 PixelMap（验证码图 + 滑块底图/拼图）
    this.captchaImages.forEach((pm: image.PixelMap, k: string): void => {
      this.releasePm(pm, 'captcha:' + k);
    });
    this.captchaImages = new Map<string, image.PixelMap>();
    this.releasePm(this.sliderBg, 'sliderBg');
    this.releasePm(this.sliderPiece, 'sliderPiece');
    this.sliderBg = undefined;
    this.sliderPiece = undefined;
  }

  /** scheme 的窄化取用（build 里不能写局部变量，if 分支的窄化在 ArkTS 里不可依赖）。 */
  private sch(): LoginScheme {
    const s: LoginScheme | null = this.scheme;
    return s === null ? new LoginScheme() : s;
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg });
  }

  private releasePm(pm: image.PixelMap | null | undefined, tag: string): void {
    if (pm === null || pm === undefined) {
      return;
    }
    pm.release().catch((e: Object): void => {
      Logger.ex('PixelMap 释放失败 ' + tag, e);
    });
  }

  // ---------------- 取方案 ----------------

  private load(): void {
    this.loading = true;
    this.loadError = '';
    // 先确保在引擎里（重启后直接进登录页时未装载）
    PluginSettings.ensureLoaded(this.uuid, this.absPath()).then((err: string): Promise<void> => {
      if (err.length > 0) {
        this.loadError = err;
        this.loading = false;
        return Promise.resolve();
      }
      return PluginLogin.fetchScheme(this.uuid).then((r: LoginResult<LoginScheme>): void => {
        if (!r.ok || r.data === null) {
          this.loadError = r.err.length > 0 ? r.err : '该插件不支持登录';
          this.loading = false;
          return;
        }
        const s: LoginScheme = r.data;
        this.scheme = s;
        // 初值：scheme.initial（上游 values = {...data, ...data.values}）
        const m: Map<string, string> = new Map<string, string>();
        s.initial.forEach((v: string, k: string): void => {
          m.set(k, v);
        });
        this.values = m;
        this.loading = false;
        // 有验证码图字段的，逐个预取一次（上游 _refreshAllCaptchas 的等价）
        for (let i = 0; i < s.fields.length; i++) {
          if (s.fields[i].isCaptchaImage()) {
            this.fetchCaptcha(s.fields[i]);
          }
        }
      });
    }).catch((e: Object): void => {
      this.loadError = '打开登录页失败：' + (e as Error).message;
      this.loading = false;
      Logger.ex('登录页初始化失败', e);
    });
  }

  private absPath(): string {
    if (this.localFile.length === 0) {
      return '';
    }
    return this.ctx().filesDir + '/plugins/' + this.localFile;
  }

  // ---------------- 值表读写 ----------------

  /**
   * 按 key 取字段。@Builder 一律传 key（string）而不是 LoginField 对象：
   * V1 的 @Builder 按值传对象是拷贝，子结构不随状态更新（本仓库已踩过，同 PluginSettingsPage 口径）。
   */
  private fieldOf(key: string): LoginField {
    const s: LoginScheme = this.sch();
    for (let i = 0; i < s.fields.length; i++) {
      if (s.fields[i].key === key) {
        return s.fields[i];
      }
    }
    return new LoginField();
  }

  private valOf(key: string): string {
    const v: string | undefined = this.values.get(key);
    return v === undefined ? '' : v;
  }

  private putVal(key: string, v: string): void {
    this.values.set(key, v);
  }

  // ---------------- 验证码图 ----------------

  private fetchCaptcha(f: LoginField): void {
    if (f.captchaFetchFnPath.length === 0 || this.captchaBusyKey.length > 0) {
      return;
    }
    this.captchaBusyKey = f.key;
    PluginLogin.fetchCaptcha(this.uuid, f.captchaFetchFnPath).then((r: LoginResult<CaptchaImage>): void => {
      this.captchaBusyKey = '';
      if (!r.ok) {
        this.captchaFailedKeys = this.captchaFailedKeys.concat([f.key]);
        this.toast(r.err);
        return;
      }
      const pm: image.PixelMap | undefined =
        (r.data === null || r.data.pixelMap === null) ? undefined : r.data.pixelMap;
      if (pm === undefined) {
        this.captchaFailedKeys = this.captchaFailedKeys.concat([f.key]);
        this.toast('验证码图片为空');
        return;
      }
      // 换引用才会重绘；旧图释放
      const next: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
      this.captchaImages.forEach((old: image.PixelMap, k: string): void => {
        next.set(k, old);
      });
      const prev: image.PixelMap | undefined = next.get(f.key);
      if (prev !== undefined) {
        this.releasePm(prev, 'captcha:' + f.key);
      }
      next.set(f.key, pm);
      this.captchaImages = next;
      // 上游取到新图就清空该字段输入（旧码对新图无意义）
      this.putVal(f.key, '');
    }).catch((e: Object): void => {
      this.captchaBusyKey = '';
      this.captchaFailedKeys = this.captchaFailedKeys.concat([f.key]);
      this.toast('验证码获取失败：' + (e as Error).message);
    });
  }

  private captchaOf(key: string): image.PixelMap | undefined {
    return this.captchaImages.get(key);
  }

  private captchaFailed(key: string): boolean {
    return this.captchaFailedKeys.indexOf(key) >= 0;
  }

  // ---------------- 滑块 ----------------

  private openSlider(f: LoginField): void {
    this.sliderField = f;
    this.sliderCreateFn = f.sliderCreateFnPath;
    this.sliderVerifyFn = f.sliderVerifyFnPath;
    this.sliderOpen = true;
    this.loadSlider();
  }

  private closeSlider(): void {
    this.sliderOpen = false;
    this.sliderErr = '';
    this.sliderKnob = 0;
    this.track = [];
    this.dragBaseDx = 0;
    this.releasePm(this.sliderBg, 'sliderBg');
    this.releasePm(this.sliderPiece, 'sliderPiece');
    this.sliderBg = undefined;
    this.sliderPiece = undefined;
  }

  private loadSlider(): void {
    this.sliderLoading = true;
    this.sliderErr = '';
    this.sliderKnob = 0;
    this.track = [];
    this.dragBaseDx = 0;
    PluginLogin.createSlider(this.uuid, this.sliderCreateFn, this.values)
      .then((r: LoginResult<SliderChallenge>): void => {
        this.sliderLoading = false;
        if (!r.ok || r.data === null) {
          this.sliderErr = r.err;
          return;
        }
        const c: SliderChallenge = r.data;
        this.releasePm(this.sliderBg, 'sliderBg-old');
        this.releasePm(this.sliderPiece, 'sliderPiece-old');
        this.sliderToken = c.token;
        this.sliderBg = c.bg === null ? undefined : c.bg;
        this.sliderPiece = c.piece === null ? undefined : c.piece;
        this.sliderImageW = c.imageWidth;
        this.sliderImageH = c.imageHeight;
        this.sliderPieceY = c.pieceY;
        this.sliderPieceSize = c.pieceSize;
      })
      .catch((e: Object): void => {
        this.sliderLoading = false;
        this.sliderErr = '滑块获取失败：' + (e as Error).message;
      });
  }

  /** scale = 显示宽 / 原图宽（底图未测到宽先按 1，避免首帧抖动，同上游回退口径）。 */
  private sliderScale(): number {
    if (this.sliderBgW <= 0 || this.sliderImageW <= 0) {
      return 1;
    }
    return this.sliderBgW / this.sliderImageW;
  }

  private sliderMaxMove(): number {
    const s: number = this.sliderScale();
    const m: number = this.sliderBgW - this.sliderPieceSize * s;
    return m > 0 ? m : 0;
  }

  private round1(v: number): number {
    return Math.round(v * 10) / 10;
  }

  private onSliderDragStart(): void {
    this.dragBaseDx = 0;
    this.dragStartT = Date.now();
    this.track = [];
    this.track.push([0, 0, 0]);
  }

  private onSliderDragUpdate(ev: GestureEvent): void {
    if (this.sliderBg === undefined || this.dragStartT === 0) {
      return;
    }
    const raw: number = this.dragBaseDx + ev.offsetX;
    let dx: number = raw < 0 ? 0 : raw;
    const max: number = this.sliderMaxMove();
    if (max > 0 && dx > max) {
      dx = max;
    }
    this.sliderKnob = dx;
    const s: number = this.sliderScale();
    const imgX: number = this.round1(dx / s);
    // FingerInfo 没有 x/y（gesture.d.ts:592 起只有 localX/localY/globalX/globalY/displayX/displayY）
    // ⇒ 取 globalY（应用窗口内绝对 Y，语义最接近上游的 clientY）
    let y: number = 0;
    if (ev.fingerList.length > 0) {
      y = Math.round(ev.fingerList[0].globalY);
    }
    this.track.push([Date.now() - this.dragStartT, imgX, y]);
    if (this.track.length > TRACK_MAX) {
      this.track.splice(1, 1);
    }
  }

  private onSliderDragEnd(): void {
    if (this.sliderBg === undefined || this.sliderVerifyFn.length === 0) {
      return;
    }
    const s: number = this.sliderScale();
    const x: number = this.round1(this.sliderKnob / s);
    if (this.track.length < 3) {
      // 上游：轨迹点太少不上报，把手归零重来
      this.sliderKnob = 0;
      this.track = [];
      return;
    }
    const snapshot: number[][] = this.track.slice();
    this.busy = 'slider';
    PluginLogin.verifySlider(this.uuid, this.sliderVerifyFn, this.sliderToken, x, snapshot)
      .then((r: LoginResult<string>): void => {
        this.busy = '';
        const f: LoginField | null = this.sliderField;
        if (r.ok && f !== null) {
          // 上游 values[key] = pass 原文（不写死 'true'）
          this.putVal(f.key, r.data === null ? 'true' : r.data);
          this.toast('滑块验证通过');
          this.closeSlider();
          return;
        }
        this.sliderErr = r.err;
        this.sliderKnob = 0;
        this.track = [];
        // 一次一题：旧 token 作废，立刻换新题
        this.loadSlider();
      })
      .catch((e: Object): void => {
        this.busy = '';
        this.sliderErr = '滑块校验失败：' + (e as Error).message;
        this.sliderKnob = 0;
        this.loadSlider();
      });
  }

  // ---------------- 提交 ----------------

  private onSubmit(): void {
    const s: LoginScheme | null = this.scheme;
    if (s === null || this.busy.length > 0) {
      return;
    }
    for (let i = 0; i < s.fields.length; i++) {
      const f: LoginField = s.fields[i];
      if (f.isSlider()) {
        if (this.valOf(f.key).length === 0) {
          this.toast('请先完成「' + f.label + '」验证');
          return;
        }
        continue;
      }
      if (f.required && this.valOf(f.key).trim().length === 0) {
        this.toast(f.label + ' 不能为空');
        return;
      }
    }
    this.busy = BUSY_SUBMIT;
    PluginLogin.submit(this.uuid, s.submitFnPath, this.values)
      .then((r: LoginResult<string>): void => {
        this.busy = '';
        if (r.ok) {
          this.toast(r.data === null || r.data.length === 0 ? '登录成功' : r.data);
          setTimeout((): void => {
            router.back();
          }, 900);
          return;
        }
        this.toast(r.err);
        // 上游：失败后若有验证码字段，全部刷新（旧码已作废）
        this.refreshAllCaptchas(s);
      })
      .catch((e: Object): void => {
        this.busy = '';
        this.toast('登录失败：' + (e as Error).message);
        this.refreshAllCaptchas(s);
      });
  }

  private refreshAllCaptchas(s: LoginScheme): void {
    for (let i = 0; i < s.fields.length; i++) {
      const f: LoginField = s.fields[i];
      if (f.isCaptchaImage()) {
        this.fetchCaptcha(f);
      }
    }
  }

  // ---------------- 视图 ----------------

  @Builder
  SectionCard(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(Theme.text2(this.isDark))
      .width('100%')
      .padding({ left: Dim.pagePadding, top: 16, bottom: 6 })
      .textAlign(TextAlign.Start)
  }

  @Builder
  FieldRow(key: string) {
    // 条件渲染只依赖 scheme（取方案后字段集合不再变）；随状态变的部分全走 @State
    if (this.fieldOf(key).isSlider()) {
      Column() {
        Text(this.fieldOf(key).label + (this.fieldOf(key).required ? ' *' : ''))
          .fontSize(13)
          .fontColor(Theme.text2(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)
        Row() {
          Text(this.valOf(key).length > 0 ? '已通过，点击可重新验证' : '拖动滑块完成人机验证')
            .fontSize(14)
            .fontColor(Theme.text1(this.isDark))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.valOf(key).length > 0 ? '已验证' : '去验证 ›')
            .fontSize(13)
            .fontColor(this.valOf(key).length > 0 ? Theme.success : Theme.brand)
            .margin({ left: 8 })
        }
        .width('100%')
        .constraintSize({ minHeight: 44 })
        .margin({ top: 6 })
        .padding({ left: 12, right: 12 })
        .backgroundColor(Theme.fillColor(this.isDark))
        .borderRadius(8)
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => {
          this.openSlider(this.fieldOf(key));
        })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .alignItems(HorizontalAlign.Start)
    }

    if (this.fieldOf(key).showsInput()) {
      Column() {
        Text(this.fieldOf(key).label + (this.fieldOf(key).required ? ' *' : ''))
          .fontSize(13)
          .fontColor(Theme.text2(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)

        if (this.fieldOf(key).isCaptchaImage()) {
          // 验证码图：点图换一张（上游 refreshText 的等价入口）
          Row() {
            if (this.captchaOf(key) !== undefined) {
              Image(this.captchaOf(key))
                .width(104)
                .height(38)
                .borderRadius(6)
                .objectFit(ImageFit.Contain)
                .onClick(() => {
                  this.fetchCaptcha(this.fieldOf(key));
                })
            } else {
              Text(this.captchaBusyKey === key ? '加载中…'
                : (this.captchaFailed(key) ? '点击重试' : '获取验证码'))
                .fontSize(13)
                .fontColor(Theme.text2(this.isDark))
                .width(104)
                .height(38)
                .textAlign(TextAlign.Center)
                .backgroundColor(Theme.fillColor(this.isDark))
                .borderRadius(6)
                .onClick(() => {
                  this.fetchCaptcha(this.fieldOf(key));
                })
            }
            Text(this.fieldOf(key).captchaRefreshText.length > 0 ? this.fieldOf(key).captchaRefreshText : '看不清？换一张')
              .fontSize(12)
              .fontColor(Theme.text3(this.isDark))
              .margin({ left: 10 })
          }
          .width('100%')
          .margin({ top: 8 })
        }

        if (this.fieldOf(key).isMultiline()) {
          TextArea({ text: this.valOf(key), placeholder: this.fieldOf(key).label })
            .fontSize(15)
            .height(88)
            .margin({ top: 6 })
            .backgroundColor(Theme.fillColor(this.isDark))
            .borderRadius(8)
            .onChange((v: string): void => {
              this.putVal(key, v);
            })
        } else {
          TextInput({ text: this.valOf(key), placeholder: this.fieldOf(key).label })
            .type(this.fieldOf(key).isPassword() ? InputType.Password : InputType.Normal)
            .fontSize(15)
            .height(44)
            .margin({ top: 6 })
            .backgroundColor(Theme.fillColor(this.isDark))
            .borderRadius(8)
            .onChange((v: string): void => {
              this.putVal(key, v);
            })
        }
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .alignItems(HorizontalAlign.Start)
    }
  }
  /** 滑块浮层（与 pages/SettingPage.ets:313 UaOverlay 同构：一个 Stack 里遮罩与卡片是兄弟层） */
  @Builder
  SliderPanelView() {
    Stack() {
      // 遮罩层
      Column()
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.45)')
      .onClick(() => {
        this.closeSlider();
      })

    Column() {
      Text('安全验证')
        .fontSize(16)
        .fontColor(Theme.text1(this.isDark))
        .width('100%')
        .textAlign(TextAlign.Start)
      if (this.sliderErr.length > 0) {
        Text(this.sliderErr)
          .fontSize(12)
          .fontColor(Theme.error)
          .margin({ top: 6 })
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      // 底图区：宽随屏、高按原图比例；拼图绝对定位在 pieceY
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.sliderBg !== undefined) {
          Image(this.sliderBg)
            .width('100%')
            .aspectRatio(this.sliderImageW / (this.sliderImageH > 0 ? this.sliderImageH : 180))
            .objectFit(ImageFit.Fill)
            .onAreaChange((_o: Area, n: Area): void => {
              const w: number = Number(n.width);
              if (w > 0 && w !== this.sliderBgW) {
                this.sliderBgW = w;
              }
            })
        }
        if (this.sliderPiece !== undefined) {
          Image(this.sliderPiece)
            .width(this.sliderPieceSize * this.sliderScale())
            .height(this.sliderPieceSize * this.sliderScale())
            .objectFit(ImageFit.Contain)
            .position({ x: this.sliderKnob, y: this.sliderPieceY * this.sliderScale() })
        }
        if (this.sliderLoading) {
          Column() {
            LoadingView()
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Theme.maskColorFor(this.isDark))
        }
      }
      .width('100%')
      .margin({ top: 10 })

      // 把手轨道
      Stack({ alignContent: Alignment.TopStart }) {
        Row()
          .width('100%')
          .height(40)
          .backgroundColor(Theme.fillColor(this.isDark))
          .borderRadius(20)
        Text(this.sliderKnob > 0 ? this.round1(this.sliderKnob / this.sliderScale()).toFixed(0) : '')
          .fontSize(12)
          .fontColor(Theme.text3(this.isDark))
          .margin({ left: 14, top: 10 })
        Row()
          .width(40)
          .height(40)
          .backgroundColor(Theme.brand)
          .borderRadius(20)
          .position({ x: this.sliderKnob, y: 0 })
          .gesture(
            PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
              .onActionStart(() => {
                this.onSliderDragStart();
              })
              .onActionUpdate((ev: GestureEvent): void => {
                this.onSliderDragUpdate(ev);
              })
              .onActionCancel((): void => {
                this.sliderKnob = 0;
              })
              .onActionEnd((): void => {
                this.onSliderDragEnd();
              })
          )
      }
      .width('100%')
      .margin({ top: 12 })

      Row() {
        Text('换一张')
          .fontSize(15)
          .fontColor(Theme.text2(this.isDark))
          .padding(10)
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            this.loadSlider();
          })
        Blank()
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.text2(this.isDark))
          .padding(10)
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            this.closeSlider();
          })
      }
      .width('100%')
      .margin({ top: 6 })
    }
        .width('92%')
        .padding(20)
        .backgroundColor(Theme.cardColor(this.isDark))
        .borderRadius(Dim.radius)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  build() {
    Stack() {
      Column() {
        BreezeTopBar({
          title: (this.scheme !== null && this.sch().title.length > 0)
            ? this.sch().title
            : (this.pluginName.length > 0 ? this.pluginName : '账号登录'),
          showBack: true,
          scrollProgress: 1
        })

        if (this.loading) {
          LoadingView()
            .layoutWeight(1)
        } else if (this.loadError.length > 0 || this.scheme === null) {
          ErrorView({
            msg: this.loadError.length > 0 ? this.loadError : '该插件不支持登录',
            onRetry: (): void => {
              this.load();
            }
          })
            .layoutWeight(1)
        } else {
          Scroll() {
            Column() {
              this.SectionCard('登录信息')
              Column() {
                ForEach(this.sch().fields, (f: LoginField) => {
                  this.FieldRow(f.key)
                }, (f: LoginField) => f.key)
              }
              .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
              .backgroundColor(Theme.cardColor(this.isDark))
              .borderRadius(Dim.radius)
              .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

              // 会话保持的实话（PluginLogin.sessionNote 同源）
              Text(PluginLogin.sessionNote())
                .fontSize(12)
                .fontColor(Theme.text3(this.isDark))
                .width('100%')
                .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 12 })
                .textAlign(TextAlign.Start)

              Button(this.busy === BUSY_SUBMIT ? '登录中…' : this.sch().submitLabel)
                .type(ButtonType.Normal)
                .fontSize(16)
                .fontColor(Theme.white)
                .backgroundColor(this.busy === BUSY_SUBMIT ? Theme.brandPressed : Theme.brand)
                .borderRadius(Dim.radius)
                .width('100%')
                .height(48)
                .enabled(this.busy.length === 0)
                .margin({ top: 20, left: Dim.pagePadding, right: Dim.pagePadding })
                .clickEffect({ level: ClickEffectLevel.LIGHT })
                .onClick(() => {
                  this.onSubmit();
                })
            }
            .width('100%')
            .padding({ bottom: 24 })
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.background(this.isDark))

      if (this.sliderOpen) {
        this.SliderPanelView()
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
