# Breeze-ohos

HarmonyOS / OpenHarmony 原生漫画阅读器：ArkTS（ArkUI）应用 + Rust 编写的 QuickJS 插件引擎，
从 Flutter 版 [Breeze](https://github.com/breeze-project-org/Breeze) 移植而来。

**未复制上游任何 Dart 源码**：插件 ABI、宿主桥接路由、设置页数据契约、配置桶格式等「接口事实」
由上游行为逆向得出，在 ArkTS 与 Rust 里重新实现。许可证 [GPL-3.0](LICENSE)，
来源与第三方许可见 [NOTICE.md](NOTICE.md)。

> **先读这一句**：本项目是**娱乐性质**的个人移植实验（同时是对当前 AI 编码能力的一次探索），
> 处于**初始阶段、已知存在较多问题，是否修复与修复时间均待定**，作者不承诺任何更新或修复义务。
> 完整性质说明与作者免责声明见文末 [声明与免责](#声明与免责)。

- bundleName `com.breeze.ohos`，versionName `3.0.37`
- **真机验证设备 = HUAWEI Mate 80 Pro Max**（应用内取到的设备型号 = `SGT-AL10`，OpenHarmony 7.0.0.111，API 26），
  **设备类型为「手机」**。全部功能、UI、材质降级与真机缺陷取证都只在这**一台**手机上完成。
- **平板（tablet）未做任何真机验证**：`module.json5` 的 `deviceTypes` 里虽声明了 `tablet`，
  那只是**编译目标声明**，不等于验证过 —— 平板上的布局、手势与材质表现均未实测，不保证可用。
- 编译目标：`compileSdkVersion = compatibleSdkVersion = 26.0.0`，`runtimeOS = HarmonyOS`

## 功能

**插件引擎（本项目的核心）** ArkTS 经 NAPI 调一个 Rust `cdylib`，Rust 内跑 QuickJS，
把上游「插件 = 一个 `.cjs` 包 + 一组约定函数名」的契约原样搬过来：

- 引擎导出 19 个 NAPI 函数（`init` / `eval` / `selftest` / bundle 调用 / 文件与网络桥接等），
  重活走 `napi_async_work`，不阻塞 UI 线程。
- 宿主向 JS 注入 5 条宿主路由（fetch、文件、缓存、存储根、日志）。注入一律写成单个表达式并做
  回读全等校验，不匹配就写进诊断，绝不静默判成功。
- 入参契约与上游逐条对齐：插件函数永远收到**恰好一个对象参数且必带 `extern` 键**。
- 自带三个 rawfile 载荷：`plugin_mgr`（插件索引与下载）、`selftest`（引擎自检）、
  `real`（端到端验证用的真插件夹具，**第三方作品**，见 [NOTICE.md](NOTICE.md) §3）。

**应用侧**

- 书架（阅读进度与续读）、发现页、云端收藏、历史记录。
- 搜索：多图源并行、结果栅格、搜索记录（含长按删单条）。
- 作品详情页、评论区。
- 阅读器：横向 `Swiper` 翻页、单击屏中显隐顶栏、双指缩放、左右点按翻页、放大后可选点按平移、
  阅读方向跟随 RTL 设置、进度落库。
- 图源插件管理：索引拉取、下载、安装、每插件设置页、插件账号登录
  （文本 / 密码 / 图形验证码 / 滑块验证码）。
- 通用设置页：网络 User-Agent 与 Cookie、阅读方向、放大后点按是否翻页、外观模式
  （跟随系统 / 亮 / 暗，三态持久化）。

## 仓库结构

```text
仓库根/
├── Breeze-ohos/                  ArkTS 应用（entry 模块）
│   ├── AppScope/                 应用级配置与图标
│   └── entry/src/main/
│       ├── ets/                  ArkTS 源码（下列子目录按职责分）
│       │   ├── entryability/     启动闸门、深浅色三态落地、数据初始化
│       │   ├── pages/            11 条页面路由（清单见下方「路由与组件」）
│       │   ├── view/             组件层（10 个分组，同上）
│       │   ├── data/             数据层：db、image、kv、model、net、source
│       │   └── util/             引擎门面、宿主路由、用户设置、主题、日志
│       ├── cpp/                  NAPI 类型声明（index.d.ts）
│       ├── resources/rawfile/plugins/  3 个内置 JS 载荷
│       └── libs/arm64-v8a/       构建产出的 .so 落点（不入库）
├── breeze_qjs_ohos/              Rust 插件引擎（cdylib）
│   ├── src/                      NAPI 表层、引擎、宿主桥接、原生路由
│   ├── vendored/                 QuickJS 本体与交叉编译补丁副本
│   └── .cargo/config.toml        目标 rustflags（机器相关路径不在此）
├── scripts/                      构建与自检脚本
├── LICENSE                       GPL-3.0 全文
├── NOTICE.md                     来源、许可表、第三方组件、GPL 义务清单
└── README.md                     本文件
```

上面说明列只写一句话，长清单在下方展开：

- `ets/pages/` 11 条路由：Index、ReaderPage、SearchPage、DetailPage、CommentPage、
  PluginManagerPage、PluginSettingsPage、PluginLoginPage、HistoryPage、SettingPage、AboutPage
- `ets/view/` 10 个组件分组：bookshelf、cloud、common、detail、discover、home、
  mine、plugins、reader、search
- `ets/util/` 6 个门面：PluginRuntime（原生门面）、BreezeHost（宿主路由）、
  UserSettings、ThemeStore、Logger、JsonUtil
- `breeze_qjs_ohos/src/` 6 个模块：lib.rs、napi.rs、engine.rs、host_bridge.rs、
  host_routes.rs、host_stubs.rs
- `vendored/` 三样：QuickJS 本体（quickjs-ng）、rquickjs-sys 交叉编译补丁副本、
  playground 宿主骨架 —— 各自保留原始许可文本，**不得删除**

开发过程中的方案、审计、逐轮取证记录属于本地工程文档，不随本仓库分发；
关键结论以代码注释与 [NOTICE.md](NOTICE.md) 为准。

## 构建

两步，产物是**未签名** `.hap`（本仓库不分发可执行文件，也不含签名材料）：

```sh
# 1) 原生引擎 → 编译并拷入 Breeze-ohos/entry/libs/arm64-v8a/libbreeze_qjs_ohos.so
bash scripts/build_rust_ohos.sh --install

# 2) HAP 包 → Breeze-ohos/entry/build/default/outputs/default/entry-default-unsigned.hap
bash scripts/build_hap.sh Breeze-ohos --mode release
```

`scripts/build_env.sh` 集中管理构建环境变量（SDK、Node、JDK、hvigor 缓存、子进程 shim），
两个构建脚本都 source 它。默认假定工具链在仓库根的 `toolchain/`（不入库），
可用环境变量 `OHOS_ROOT` 改根路径。

`breeze_qjs_ohos/.cargo/config.toml` 只保留**机器无关**的配置。交叉编译必需的 NDK clang、
sysroot、libclang、mingw 头文件、临时目录等**每台机器都不同**，由
`node scripts/sync_cargo_config.cjs` 按仓库根与环境变量现算，写进 gitignore 的
`breeze_qjs_ohos/.cargo/config.local.toml`（`build_rust_ohos.sh` 每次运行前会自动调用它）。
所以 clone 后第一件事是把工具链放进 `toolchain/`（或设置相应环境变量），不要手工往
`config.toml` 里写绝对路径。

工具链要求（均为实测结论）：

| 组件 | 要求 |
| --- | --- |
| SDK | API 26（`compileSdkVersion 26.0.0`） |
| Node.js | Command Line Tools 自带 `tool/node` |
| JDK | 17（hvigor 的 PackageHap 阶段要 `java`） |
| Rust 宿主 | **`nightly-x86_64-pc-windows-gnu`**，必须 gnu：msvc 宿主没有 `link.exe`，`-Zbuild-std` 链接必失败 |
| Rust 目标 | `aarch64-unknown-linux-ohos`，配 `-Zbuild-std` |
| C 交叉编译 | NDK clang + OHOS sysroot；宿主侧另需一个 C 编译器（`rquickjs-macro` 会为宿主编一份 QuickJS C 源码） |

`scripts/build_rust_ohos.sh` 的头部注释写清了四处**不可回退**的偏差（reqwest 换 rustls+ring、
rquickjs-sys 全 vendoring 且关 bindgen、cc 的 CFLAGS 分目标与宿主两套、禁用 vendored build.rs
里「target == host 时复制 bundled binding」的分支）。改 Rust 前先读它。

## 自检

```sh
node scripts/check_imports.cjs     # ArkTS import 图与循环依赖
node scripts/so_names_check.cjs    # 引擎导出名逐项校验（19/19）
node scripts/hap_list.cjs <hap>    # 逐 entry 列大小与 sha256
```

仓库里只有 **`scripts/`** —— 纯构建与自检脚本，输入输出都是仓库内的相对路径，任何人 clone 下来都能跑；只在维护者单机上成立的本地辅助脚本不入仓。

**整包 sha256 不可复现**：`.hap` 是 zip，30 个 local header 与 30 个 central header 各嵌
2 字节 DOS 时间戳，clean 重打固定差约 120 字节。校验完整性只能逐 entry 比 sha256。
纯 ArkTS 改动后，`.so` 与三个 rawfile 载荷必须逐字节不变。

### 原生模块装载三要件（真机踩过，缺一不可）

ArkTS 里 `import from 'libxxx.so'` **静默返回 `undefined`** 而不是报错，通常是这三条之一没满足：

1. `nm_modname` 严格等于 so 文件名去掉 `lib` 前缀与 `.so` 后缀（本项目 = `breeze_qjs_ohos`）。
2. `cdylib` 显式链 NAPI 库：`.cargo/config.toml` 的
   `[target.aarch64-unknown-linux-ohos].rustflags` 含 `-C link-arg=-lace_napi.z`；
   用 `llvm-objdump -p` 确认 `NEEDED` 里有 `libace_napi.z.so`（只有 `libc.so` 就是错的）。
3. `entry/oh-package.json5` 的 dependencies 声明
   `"libbreeze_qjs_ohos.so": "file:./src/main/cpp/types/libbreeze_qjs_ohos"`，
   该目录含 `oh-package.json5` + `index.d.ts`；改完跑 `ohpm install --all`。

还有一条更隐蔽的：凡签名里没有 `length` 参数的 NAPI API（`napi_set_named_property` 等），
名字只能传 **NUL 结尾的 C 串**。递 Rust `&str` 的 `as_ptr()` 既不报编译错也不崩，
症状是「import 成功、模块对象拿到了，但只有第一个导出可调用，其余 `undefined`」。

## 装到设备

产物是未签名 HAP，本仓库不代替你签名。二选一：

- DevEco Studio 打开 `Breeze-ohos/`，配好自动签名后直接 Run；
- 或用 SDK 自带 `hap-sign-tool` 自行签名，再 `hdc install`。

证书、profile、密钥库等签名材料一律不入库（`.gitignore` 已排除）。

## 已知限制

本项目**仍处于初始阶段，存在较多已知与未知的 BUG**。下列是已经明确的主要缺口；
**是否修复、何时修复均待定**，不构成任何承诺（见文末 [声明与免责](#声明与免责)）。

- **阅读器功能偏薄**：目前只有单图横向翻页。长条/连页模式、亮度与常亮控制、章节目录跳转、
  翻页动画档位等尚未实现。
- **插件登录态由插件自己持有**：Rust 引擎与宿主都不托管插件 cookie，登录态存在插件 JS 的
  引擎内存里，杀进程或引擎重载后可能失效需重登。
- **插件登录依赖插件实现 `getLoginBundle`**：未实现的插件回「该插件不支持登录」属正常行为。
- 尚未实现：下载管理、WebDAV 同步、阅读统计、书架高级筛选、多图源去重。
- 仅在 HUAWEI Mate 80 Pro Max（手机）上验证过；平板与其他机型/ROM 未实测。

## 声明与免责

**使用本仓库或其构建产物前，请先读完本节。继续使用即视为你已阅读、理解并同意本节全部内容。**

### 1. 项目性质与初衷

- 本项目**纯属娱乐性质**的个人业余项目，同时也是**对当前 AI 编码能力边界的一次探索**：
  作者想看看 AI 工具能把一个跨语言（ArkTS + Rust + NAPI）的移植项目做到什么程度。
- **作者本人不是专业开发者，也不是相关行业从业者。** 本项目的**整体由 AI 工具完成**：
  前期立项与初始界面由 **DeepSeek V4.1 Flash 1017** 完成，后期插件相关工作及其完善由
  **Qwen 3.8 flash next** 完成。
- 因此本项目应被理解为**一份 AI 生成结果的公开样本**，而不是一个经过专业工程评审的软件产品。
  代码质量、安全性、正确性与可维护性**均未作任何保证**。
- 项目**处于初始阶段，存在很多 BUG**。已知与未知的问题都很多；**是否修复、如何修复、何时修复均待定**，
  作者保留在不通知的情况下修改、暂停或终止本项目的权利。

### 2. 作者义务与责任限制

- 作者**不对本项目承担任何责任**，具体包括但不限于：
  - **没有义务持续更新**本应用；
  - **没有义务修复任何 BUG**，也不承诺任何问题的响应时间或修复时间；
  - **没有义务实现**任何被提出、被许愿或文档里写着「尚未实现」的功能；
  - **没有义务提供**技术支持、答疑、适配新机型/新系统版本或迁移指导。
- 作者对因使用、复制、修改、分发本项目（包括直接使用、二次开发或集成进其他项目）而产生的
  **任何直接、间接、特殊、附带或后果性损害不承担任何责任**，包括但不限于数据丢失、设备损坏或变砖、
  账号被封禁、阅读记录或下载内容丢失、网络费用、业务中断、利润损失或其他经济损失。
- 本项目以**「原样（AS IS）」**提供，作者**不作任何形式的担保**，包括但不限于：适销性、特定用途适用性、
  不侵犯第三方权利、无错误、无中断运行、内容准确性与安全性。效果不满意、装不上、跑不起来、
  被系统或厂商拦截，都属于**使用者自行承担**的结果。
- 用户应**自行评估适用性并承担全部使用风险**，并自行确保使用行为符合所在国家或地区的法律法规。
  因违反法律法规或不当使用而产生的一切后果，由使用者本人承担，与作者无关。
- 若接受外部贡献：贡献者的行为仅代表其个人立场，不代表作者的观点或立场；作者对贡献者行为及其贡献内容
  不承担责任。

### 3. 与上游及第三方的关系

- **本仓库是个人移植项目**，与 **Breeze**、**NextE**、**qingye-reader** 的原作者**无隶属关系**，
  也**未获得任何授权、背书或认可**。提及这些项目仅为说明移植来源与设计参考。
- 本项目**不含任何图源内容**（不内置、不分发、也不代查任何漫画内容或图源站点）。
- **插件由第三方作者独立开发与分发**，其功能、内容、合法性、安全性与可用性完全由插件作者负责；
  **插件内容与使用责任由插件作者与使用者承担**，与本项目及作者无关。
- 本项目可能依赖或引用第三方库、工具、服务或其他资源；作者不对这些第三方资源的内容、功能、安全性或
  合法性负责，使用第三方资源的风险由使用者自行评估与承担。第三方许可清单见 [NOTICE.md](NOTICE.md)。
- 若上游项目或第三方权利人认为本仓库存在不当之处，请开 Issue 说明，作者会在力所能及的范围内处理
  （但同样**不承诺时限**）。

### 4. 内容与合规提示

- 本仓库及作者**不提供、不托管、不推荐任何漫画内容或图源**；通过插件访问的内容版权与合法性由内容源、
  插件作者与使用者各自负责。
- 使用者应仅将本项目用于**个人学习与技术交流**，并遵守所在国家或地区的法律法规。
- 本项目的插件引擎依赖系统网络与设备能力，异常使用可能影响设备或账号状态，风险自负。

---

## 许可

代码本体 **GPL-3.0（或稍后版本，GPL-3.0-or-later）**（全文见 [LICENSE](LICENSE)）；来源、许可表与
随源码分发的第三方组件见 [NOTICE.md](NOTICE.md)。随源码分发的 vendored 目录各自保留原始许可文本，不得删除。

> GPL-3.0 授予你复制、分发、修改的自由，同时上文 [声明与免责](#声明与免责) 中的「原样提供、无担保、
> 无支持义务」与 GPL 第 16 条（WARRANTY DISCLAIMER）及第 17 条（LIMITATION OF LIABILITY）**一致适用**；
> 任何分发行为均须同时携带上述许可文本与本声明。
