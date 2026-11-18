# 许可与第三方来源声明（NOTICE）

本仓库（<https://github.com/tianmeng-xiu/Breeze-ohos>）以 **GNU GPL v3.0**（或稍后版本）发布，
全文见根目录 [`LICENSE`](LICENSE)。本文件说明**代码来源、各自原始许可，以及组合成 GPL 作品的依据**。

> 结论先行：本项目的 ArkTS 应用层与 Rust 引擎主体是**原创实现**，参考了三个开源项目的
> **设计与接口契约**；同时，为满足 OHOS 交叉编译与宿主桥接，**随源码分发了第三方项目的源码副本**
> —— 其规模与许可见 §2 的逐目录表格（下表为准，不要按「少量」理解其体量）。所有第三方来源逐项列于下表，
> 每项标注其许可与不确定之处。

## 1. 上游与参考项目

| 项目 | 许可 | 本项目如何使用 | 依据 / 位置 |
| --- | --- | --- | --- |
| [Breeze](https://github.com/breeze-project-org/Breeze)（Flutter 原版漫画阅读器） | **MPL-2.0** | **未复制任何 Dart 源码**。仅按其源码逆向出「插件 ABI / bridge 路由 / 设置页数据契约 / 配置桶格式」等**接口事实**，在 ArkTS 与 Rust 里重新实现。 | 契约权威位置写在对应源文件头部注释里（如 `Breeze-ohos/entry/src/main/ets/data/source/PluginSettings.ets` 头部引用了 `Breeze/lib/page/plugin_settings/*` 的文件与行号） |
| [NextE](https://github.com/erosTeam/NextE)（HarmonyOS 漫画阅读器） | **MIT** | 作为 HarmonyOS **交互范式与 UI 版式参考**（悬浮底栏参数集、材质降级阶梯、详情页版式思路）。本项目未复制其源码文件；若将来逐段借鉴，将在文件头注明来源与 MIT 版权行（MIT 允许，须保留声明）。 | 代码内文件头注释（截至本版本 0 处逐段借鉴） |
| [qingye-reader](https://github.com/wip3l/qingye-reader)（HarmonyOS 阅读器） | **GPL-3.0** | 交互设计参考（阅读统计、书架筛选、共享元素转场）。**GPL-3 与本项目许可相同**，故逐段借鉴合法，但必须①保留其版权声明 ②对修改过的文件作显著说明（GPL §5a）。截至本版本**尚未复制其任何源码**。 | 代码内文件头注释（截至本版本 0 处逐段借鉴） |
| [Breeze-plugin-list](https://github.com/breeze-project-org/Breeze-plugin-list) | 各插件自定 | 本项目运行时向该索引发起 HTTP 请求以拉取插件列表与插件文件；此外，`plugin_mgr` 载荷内**内置了一份来自该上游索引数据的离线兜底副本**（随本仓库分发）。本项目不托管任何插件文件或内容，**索引条目与插件的功能、内容、合法性由上游索引维护者与插件作者各自负责**。 | `Breeze-ohos/entry/src/main/resources/rawfile/plugins/plugin_mgr.bundle.cjs` |

## 2. 随源码分发的第三方组件（vendored）

这些目录**包含在本仓库内**，各自保留原始许可文本，不得删除：

| 路径 | 许可 | 说明 |
| --- | --- | --- |
| `breeze_qjs_ohos/vendored/rquickjs-sys/` | **MIT**（`Cargo.toml` `license = "MIT"`；该目录内无独立 `LICENSE` 文件，其下 `quickjs/LICENSE` 是内嵌 QuickJS 的许可，见下一行） | rquickjs-sys **0.12.2** 交叉编译补丁副本（对应上游 PR DelSkayn/rquickjs#709），为 OHOS 目标关掉 bindgen、改 CFLAGS 分目标/宿主两套。宿主侧 `rquickjs` / `-core` / `-macro` 走 **crates.io 0.12.x**（其上游各 crate 的 `license` 字段与 `LICENSE` 均为 **MIT 单许可**），仅 `rquickjs-sys` 被 `[patch.crates-io]` 指向本目录。 |
| `breeze_qjs_ohos/vendored/rquickjs-sys/quickjs/` | **MIT**（该目录 `LICENSE`，版权行 = Fabrice Bellard、Charlie Gordon、Ben Noordhuis、Saúl Ibarra Corretgé） | ⚠ **这是 quickjs-ng，不是 Bellard 原版 QuickJS**：`quickjs.h` 内 `#define QUICKJS_NG 1`、`QJS_VERSION_MAJOR/MINOR/PATCH = 0/15/1`。两者许可文本不同 —— 原版 QuickJS 用 X11/ISC 风格许可，**quickjs-ng 分支已改用 MIT 全文**，本项目分发的正是后者，故按 MIT 处理，与 GPL-3 兼容。 |
| `breeze_qjs_ohos/vendored/playground/` | **上游未声明许可**（该目录无 `LICENSE`，`Cargo.toml` 无 `license` 字段，且 `rquickjs_playground` 未发布到 crates.io） | 上游宿主骨架（bridge / native buffer / bundle dispatcher）的本地副本，改动限于 rustls provider 与去掉 bindgen。**本项目已尽合理注意仍未能确定其许可条款**，在此如实标注来源与不确定状态；若权利人提出，将在下一个版本移除或按其条款处理。 |
| `breeze_qjs_ohos/vendored/playground/js/THIRD_PARTY_TEMPORAL_POLYFILL.LICENSE` | **MIT**（版权行 = Adam Shaw） | `Temporal` polyfill（full 构建），来自 <https://github.com/fullcalendar/temporal-polyfill>，随 `js/` 目录原样分发，许可文本不得删除。 |

## 2b. Rust 依赖的许可概览

`breeze_qjs_ohos/Cargo.toml` 的直接依赖全部为 **MIT 或 Apache-2.0**（含双许可可选）类别，与 GPL-3 兼容。
其中几个值得点名的：

| crate | 许可（取自 `Cargo.lock` 冻结版本对应的 crate 清单 `license` 字段） | 备注 |
| --- | --- | --- |
| `reqwest` 0.13.5 / `rustls` 0.23.46 / `rustls-webpki` 0.103.16 / `rustls-pki-types` 1.15.1 | MIT OR Apache-2.0（`rustls-webpki` = ISC） | 本项目用 `rustls-no-provider` + `rustls` 的 `ring` feature（等价替代上游的 aws-lc-rs provider，因 aws-lc-sys 需 cmake） |
| `ring` 0.17.14 | **Apache-2.0 AND ISC**（混合：OpenSSL 派生代码 ISC，其余 ISC + MSSL 组件 Apache-2.0） | 上游清单明确标注为混合许可，非单一 MIT |
| `rustls-native-certs` 0.8.5 | Apache-2.0 OR ISC OR MIT | **TLS 根证书来源**：读系统信任库。依赖树里**没有** `webpki-roots`（两个 `Cargo.lock` 均已核实），故本项目不分发任何内置 CA 集合 |
| `rquickjs` / `rquickjs-core` / `rquickjs-macro` 0.12.x | **MIT**（上游各 crate 的 `license` 字段与 `LICENSE` 均为 MIT 单许可） | 走 crates.io；仅 `rquickjs-sys` 被 `[patch.crates-io]` 指向本地 `vendored/rquickjs-sys/`（见 §2） |
| `icu` 2.4.0 / `icu_properties` 2.4.0 / `writeable` 0.6.4 | **Unicode-3.0** | 允许再分发，须保留其 NOTICE 文本；由 `jiff-icu` 引入 |
| `jiff` / `jiff-icu` | Unlicense OR MIT | — |
| `subtle` 2.6.1 | **BSD-3-Clause** | 唯一 BSD-3 项，须保留其版权行与两项条件 |
| `scraper` 0.27.0 / `ego-tree` 0.11.1 | ISC | — |
| 其余（`serde*` `tokio` `url` `base64` `uuid` `md5` `aes` `aes-gcm` `cbc` `hmac` `sha1` `sha2` `pbkdf2` `flate2` `getrandom` `filetime` `anyhow` `tracing` `async-trait` `http*` `reqwest-middleware` `srcmap-sourcemap` `indexmap` `libc` `cc` `fluent-bundle` `unic-langid` `regex`） | MIT 或 Apache-2.0（多数为二者任选） | 均与 GPL-3 兼容 |

**完整清单的可重建方式**：`breeze_qjs_ohos/Cargo.lock` 与 `breeze_qjs_ohos/vendored/playground/Cargo.lock`
**已随源码入库**（依赖版本冻结 ⇒ 许可清单可复现生成）。发布前执行：

```sh
cargo install cargo-about          # 一次性
cd breeze_qjs_ohos
cargo about init                   # 生成默认 about.hbs 模板
cargo about generate about.hbs > THIRD_PARTY_RUST.html
```

ArkTS 侧依赖仅为 OpenHarmony / HarmonyOS SDK 自带的 kit 与 `@ohos/*` 构建工具（Apache-2.0），
不随源码分发。


## 2c. 随源码分发的简繁转换词典数据（OpenCC）

设置项「简繁转换」（仅界面显示层）使用 [OpenCC](https://github.com/BYVoid/OpenCC) 的**词库文本**，
以 TSV 形式放在 `Breeze-ohos/entry/src/main/resources/rawfile/convert/`，由应用运行时读取：

| 文件 | 字节 | 条目 | 许可 |
| --- | --- | --- | --- |
| `TSPhrases.tsv` | 8,571 | 468 | **Apache-2.0**（OpenCC） |
| `TSCharacters.tsv` | 26,233 | 3,221 | **Apache-2.0**（OpenCC） |
| `STPhrases.tsv` | 839,167 | 40,158 | **Apache-2.0**（OpenCC） |
| `STCharacters.tsv` | 32,715 | 3,881 | **Apache-2.0**（OpenCC） |

- **来源与许可**：四份文本均取自 OpenCC 仓库 `config/` 下的同名词库（<https://github.com/BYVoid/OpenCC>，
  **Apache-2.0**）。本项目不改动词库内容语义，只做**为适配转换算法而做的行级裁剪**（见下条），
  每份文件头两行注释保留了来源名与上游地址。Apache-2.0 与 GPL-3 兼容。
- **由原词库到这四份 TSV 的转换过程**：转换脚本与全部取证都在开发过程中的临时目录里
  （不入库，因而不是可复现构建的一部分），做三件事：① 把「一词多译」的行裁成首见译法，
  使产物成为**一列对一列**的确定映射；② **保留**词组表里那些**能拦住字表误替换**的恒等行
  （`TSPhrases.tsv` 中 111 条、`STPhrases.tsv` 中 1,579 条，例如「乾隆 → 乾隆」），
  丢掉那些字表本就不碰的恒等行以省体积；③ 逐行输出 `key<TAB>value`，UTF-8、首行为来源注释。
- **有意不采用的部分**：OpenCC 的 `TWPhrases`、`TWVariants`、`TWVariantsPhrases` 三张表**未随包分发**。
  前者是台式用语语义替换表（`U盤 → 隨身碟` 一类），对漫画标题与章节名属于过度本地化；
  后两枚是字形异体变体转换，随包体积翻倍而收益极小。理由同时写在
  `Breeze-ohos/entry/src/main/ets/util/TextConvert.ets` 的文件头注释里。
- **用途边界**：这套词典只在 ArkTS 侧做**显示层**转换，不参与搜索词规范化与屏蔽词匹配；
  Rust 引擎侧的 `opencc.convert` 路由仍是**有意 passthrough**（原样返回文本），二者互不依赖。


## 3. 随源码分发的第三方插件夹具

`Breeze-ohos/entry/src/main/resources/rawfile/plugins/real.bundle.cjs`（23,496 B）是第三方插件
**Breeze-plugin-mangadex**（作者 `k623615746`，<https://github.com/k623615746/Breeze-plugin-mangadex>）
的已编译（minify）产物，在本仓库里**仅作为插件引擎的端到端自测夹具**：它实现了真实的插件函数
契约，用来验证「索引 → 加载 → 搜索 → 取图 → 登录」整条引擎链路，不用于任何图源内容分发。

- 本项目对该文件**不主张任何版权**，也不把它视为本项目的源码贡献；
- 该文件的**著作权与许可以其来源仓库为准**。核查时该仓库未附带 LICENSE 文件，本项目已尽合理
  注意但仍未能确定其许可条款，故在此明确标注来源与权利人；
- 若权利人认为随附不当，提出后本项目将在下一个版本移除（该文件可从构建中剔除，代价是失去唯一
  一个真插件回归夹具，其余功能不受影响）；
- 同目录另外两个载荷 `plugin_mgr.bundle.cjs` 与 `selftest.bundle.cjs` 是本项目原创代码，
  随本仓库按 GPL-3 分发。

## 4. GPL-3 义务清单（发布前逐项确认）

1. **附许可全文** —— 根目录 `LICENSE`（GNU GPL v3.0 官方文本）。
2. **保留版权声明** —— 上表所有 vendored 目录的 `LICENSE` 文件必须原样保留。
3. **对修改过的文件作显著说明（§5a）** —— vendored 的 `rquickjs-sys/build.rs` 等被本仓库改过，
   改动点集中记录在 `scripts/build_rust_ohos.sh` 的头部注释（「四处不可回退偏差」）与各
   vendored 文件的改动处注释里，本仓库自包含，不依赖外部文档。
4. **提供完整对应源码（Corresponding Source）** —— 推送到公开仓库即满足；
   **注意** `toolchain/` 与 `out/` 不属于源码（见根目录 `.gitignore`），
   构建步骤必须写在 [`README.md`](README.md) 与 §5 里，让人能据此重建可执行文件。
5. **不得附加进一步限制** —— 例如不得声明「禁止商用」「必须闭源衍生」。
6. **构建说明** —— 本项目为可执行目标文件（`.hap`）+ 原生动态库（`.so`）的工程，
   §5 的命令即为「安装开发信息」。

## 5. 构建开发信息（Corresponding Source 的可重建性）

```sh
# 1) 原生插件（QuickJS 引擎 .so，目标 aarch64-unknown-linux-ohos）
bash scripts/build_rust_ohos.sh --install

# 2) HAP 应用包
bash scripts/build_hap.sh Breeze-ohos --mode release
```

工具链与版本要求详见 [`README.md`](README.md)「构建」一节。

## 6. 免责声明

本项目性质（娱乐性质的 AI 生成项目）、无担保与责任限制、与上游及第三方的关系、内容与合规提示，
**统一只列在 [`README.md`](README.md) 的「声明与免责」一节**，本文件不再单列，以免两处文本各自漂移。
本文件涉及的第三方库与工具见 §2、§2b、§3；作者不对这些资源的内容、功能、安全性或合法性负责。

只保留一句与许可直接相关的结论：README 的「原样提供、无担保、无支持义务」与根目录 `LICENSE`
（GPL-3.0）第 16、17 条的免责声明一致适用，且**不构成 GPL §10 意义上的「附加限制」**
（GPL 本身就无担保、无责任、无支持义务）。
