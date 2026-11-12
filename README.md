# Breeze-ohos

HarmonyOS / OpenHarmony 原生漫画阅读器：ArkTS（ArkUI）应用 + Rust 编写的 QuickJS 插件引擎，从 Flutter 版 [Breeze](https://github.com/breeze-project-org/Breeze) 移植而来。插件 ABI、宿主桥接路由、设置页数据契约、配置桶格式等接口事实由上游行为逆向得出，在 ArkTS 与 Rust 里重新实现，未复制上游任何 Dart 源码。

代码按 [GPL-3.0-or-later](LICENSE) 发布，来源与第三方许可见 [NOTICE.md](NOTICE.md)。

现成安装包见[装到设备](#装到设备)（未签名 HAP，可自签，也可在开启开发者模式的设备上用 hdc 装），自己编译见[构建](#构建)。功能并不完整，请先读一遍[已知限制](#已知限制)。

## 功能

插件引擎（本项目的核心）：ArkTS 经 NAPI 调一个 Rust cdylib，Rust 内跑 QuickJS，把上游「插件 = 一个 .cjs 包 + 一组约定函数名」的契约原样搬过来。

- 引擎导出 19 个 NAPI 函数（`init` / `eval` / `selftest` / bundle 调用 / 文件与网络桥接等），重活走 `napi_async_work`，不阻塞 UI 线程。
- 宿主向 JS 注入 5 条宿主路由（fetch、文件、缓存、存储根、日志），注入写成单个表达式并做回读全等校验，不匹配就写进诊断。
- 入参契约与上游逐条对齐：插件函数永远收到恰好一个对象参数且必带 `extern` 键。
- 自带三个 rawfile 载荷：`plugin_mgr`（插件索引与下载）、`selftest`（引擎自检）、`real`（端到端验证用的真插件夹具，第三方作品，见 [NOTICE.md](NOTICE.md) §3）。

应用侧：书架（阅读进度与续读）、发现页、云端收藏、历史记录、作品详情页、评论区；搜索支持多图源并行、结果栅格与搜索记录（含长按删单条）；阅读器为横向 Swiper 翻页、单击屏中显隐顶栏、双指缩放、左右点按翻页、放大后可选点按平移、阅读方向跟随 RTL 设置、进度落库；图源插件管理含索引拉取、下载、安装、每插件设置页与账号登录（文本 / 密码 / 图形验证码 / 滑块验证码）；通用设置页含网络 User-Agent 与 Cookie、阅读方向、放大后点按是否翻页、外观模式（跟随系统 / 亮 / 暗，三态持久化）。

## 仓库结构

```text
仓库根/
├── Breeze-ohos/                  ArkTS 应用（entry 模块）
│   ├── AppScope/                 应用级配置与图标
│   └── entry/src/main/
│       ├── ets/                  ArkTS 源码：entryability（启动初始化、深浅色、数据引导）、pages（11 条路由）、view（10 个组件分组）、data（db / image / kv / model / net / source）、util（引擎门面、宿主路由、设置、主题、日志）
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

## 构建

产物是未签名 HAP：本仓库不分发可执行文件，也不含签名材料。bundleName `com.breeze.ohos`，`compileSdkVersion = compatibleSdkVersion = 26.0.0`，`runtimeOS = HarmonyOS`。

```sh
# 1) 原生引擎 → 编译并拷入 Breeze-ohos/entry/libs/arm64-v8a/libbreeze_qjs_ohos.so
bash scripts/build_rust_ohos.sh --install

# 2) HAP 包 → Breeze-ohos/entry/build/default/outputs/default/entry-default-unsigned.hap
bash scripts/build_hap.sh Breeze-ohos --mode release
```

构建环境变量（SDK、Node、JDK、hvigor 缓存、子进程 shim）集中在 `scripts/build_env.sh`，默认假定工具链在仓库根的 `toolchain/`（不入库），可用 `OHOS_ROOT` 改根路径。NDK clang、sysroot、libclang、mingw 头文件等每台机器都不同的项，由 `node scripts/sync_cargo_config.cjs` 现算后写进 gitignore 的 `breeze_qjs_ohos/.cargo/config.local.toml`（构建脚本每次运行前自动调用），不要手工往 `config.toml` 写绝对路径。

工具链要求（均为实测结论）：

| 组件 | 要求 |
| --- | --- |
| SDK | API 26（`compileSdkVersion 26.0.0`） |
| Node.js | Command Line Tools 自带 `tool/node` |
| JDK | 17（hvigor 的 PackageHap 阶段要 `java`） |
| Rust 宿主 | `nightly-x86_64-pc-windows-gnu`，必须 gnu：msvc 宿主没有 `link.exe`，`-Zbuild-std` 链接必失败 |
| Rust 目标 | `aarch64-unknown-linux-ohos`，配 `-Zbuild-std` |
| C 交叉编译 | NDK clang + OHOS sysroot；宿主侧另需一个 C 编译器（`rquickjs-macro` 会为宿主编一份 QuickJS C 源码） |

改 Rust 前先读 `scripts/build_rust_ohos.sh` 的头部注释，里面写清了四处不可回退的偏差与原生模块装载的几条实测约束（`nm_modname` 命名、显式链 NAPI 库、`oh-package.json5` 声明原生包，以及无 `length` 参数的 NAPI API 只认 NUL 结尾 C 串）。

## 自检

```sh
node scripts/check_imports.cjs     # ArkTS import 图与循环依赖
node scripts/so_names_check.cjs    # 引擎导出名逐项校验（19/19）
node scripts/hap_list.cjs <hap>    # 逐 entry 列大小与 sha256
```

整包 sha256 不可复现：HAP 是 zip，头部内嵌 DOS 时间戳，clean 重打固定差约 120 字节。校验完整性用上面的脚本逐 entry 比 sha256；纯 ArkTS 改动后，`.so` 与三个 rawfile 载荷必须逐字节不变。

## 装到设备

产物是未签名 HAP，本仓库不代替你签名。HarmonyOS 与 OpenHarmony 设备都可以安装，前提是先开启设备的开发者模式。

- DevEco Studio 打开 `Breeze-ohos/`，配好自动签名后直接 Run；
- 或开启开发者模式后自行签名（SDK 自带 `hap-sign-tool`），或用 `hdc` 直接安装未签名包：

```sh
hdc file send Breeze-3.0.37-s11-cache-cloud-shelf-search-flat-release-unsigned.hap /data/local/tmp/
hdc shell bm install -p /data/local/tmp/
```

证书、profile、密钥库等签名材料一律不入库（`.gitignore` 已排除）。未签名包不能覆盖安装已签名的同名应用，先卸载再装。

## 已知限制

以下只列影响使用决策的条目；本项目的性质与修复承诺见文末 [声明与免责](#声明与免责)。

- 编译目标为 phone 与 tablet（`module.json5` 的 `deviceTypes`），但只在 HUAWEI Mate 80 Pro Max（应用内取到的型号串 = `SGT-AL10`，OpenHarmony 7.0.0.111，API 26）这一台手机上做过真机验证；平板与其他机型 / ROM 仅编译通过，未实测。
- 阅读器功能偏薄：目前只有单图横向翻页。长条/连页模式、亮度与常亮控制、章节目录跳转、翻页动画选项等尚未实现。
- 宿主提供登录态持久化接口，插件是否调用由插件自己决定；插件登录还依赖其实现 `getLoginBundle`，未实现的插件回「该插件不支持登录」属正常行为。
- 图片反混淆只覆盖一种形态（横向切成 N 条带并倒序），其他形态走「检测不出就不动图」的安全分支。
- 启动窗底色只跟随系统色档：启动画面早于任何 JS 执行，手动选深色而系统当前是浅色时启动窗仍是白底。
- 尚未实现：下载管理、WebDAV 同步、阅读统计。
- 明确不做（不是遗漏）：书架高级筛选、多图源同款作品去重。本应用的书架范围就是收入书架并按加入时间列表；多图源的用法是在搜索页切换来源分别搜索，同一作品在不同来源就是两条独立书架记录，属预期行为。

## 声明与免责

使用本仓库或其构建产物前，请先读完本节。继续使用即视为你已阅读、理解并同意本节全部内容。

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

### 2. 无担保与责任限制

本项目按「原样（AS IS）」提供，作者不作任何形式的担保（含适销性、特定用途适用性、不侵犯第三方权利、无错误、无中断运行），也不对使用、复制、修改或分发本项目造成的任何直接、间接、特殊、附带或后果性损害承担责任（含数据丢失、设备损坏或变砖、账号风险、阅读记录或下载内容丢失、网络费用、业务中断与经济损失）。

作者没有义务持续更新本应用，没有义务修复任何 BUG，没有义务实现任何功能，也没有义务提供技术支持、答疑或适配新机型与新系统版本，并保留在不通知的情况下修改、暂停或终止本项目的权利。使用者须自行评估适用性、自担全部使用风险，并确保使用行为符合所在国家或地区的法律法规。若接受外部贡献：贡献者的行为仅代表其个人立场，作者不对贡献者行为及其贡献内容承担责任。

### 3. 与上游及第三方的关系

本项目是个人移植项目，与 Breeze、NextE、qingye-reader 的原作者无隶属关系，也未获得任何授权、背书或认可；提及这些项目仅为说明移植来源与设计参考。本仓库不含任何图源内容（不内置、不分发、也不代查任何漫画内容或图源站点）。

插件由第三方作者独立开发与分发，其功能、内容、合法性、安全性与可用性完全由插件作者负责，插件内容与使用责任由插件作者与使用者承担，与本项目及作者无关。本项目所依赖的第三方库、工具与服务见 [NOTICE.md](NOTICE.md)，作者不对这些第三方资源的内容、功能、安全性或合法性负责。若上游项目或第三方权利人认为本仓库存在不当之处，请开 Issue 说明，作者会在力所能及的范围内处理，同样不承诺时限。

### 4. 内容与合规提示

本仓库及作者不提供、不托管、不推荐任何漫画内容或图源；通过插件访问的内容版权与合法性由内容源、插件作者与使用者各自负责。使用者应仅将本项目用于个人学习与技术交流，并遵守所在国家或地区的法律法规。

## 许可

代码本体为 GPL-3.0-or-later（全文见 [LICENSE](LICENSE)）；来源、许可表与随源码分发的第三方组件见 [NOTICE.md](NOTICE.md)，各 vendored 目录保留原始许可文本，不得删除。上文声明与免责中的「原样提供、无担保、无支持义务」与 GPL 第 16、17 条一致适用；任何分发行为均须同时携带许可文本与本声明。
