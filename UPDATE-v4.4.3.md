## v4.4.3

> 这一版只动**数据与扫描范围**，不碰挂载和字体处理逻辑。

### ✚ 字体配置扫描补上魅族的 `flyme_*.xml`

魅族的字体配置里有一份 **`flyme_fallback.xml`** —— 名字里**没有 "font"**，
而扫描用的通配一直是 `*font*.xml`，所以**这个文件从来没被读到过**。
它里面是「后备字体链」的映射，漏了它，魅族设备的后备字体完全不参与替换。

现在通配补上 `*/etc/flyme_*.xml`。

> 依据：魅族系的字体配置里 `flyme_fallback.xml` / `flyme_font_fallback.xml`
> 这两个文件确实存在（只是名字里不带 "font"），里面是「后备字体链」的映射。
> 云端报告目前还没有魅族样本，等拿到设备再核实具体内容。

### 🛡 荣耀 / MagicOS：只保护，不替换主字体

MagicOS 的「字体和图标粗细」滑块，调节对象是**主字体和可变字体**。
我们替换上去的是**静态字体**（没有字重轴），而系统配置仍声明"支持粗细调节" ——
这个组合在 MagicOS 上会导致 SystemUI 反复异常（手机基本没法用，只能重启）。
本模块不改字体配置，所以唯一安全的选择是：**这些字体根本不碰**。

新增 `targets/protect.list` —— **任何路径都不许替换**的名单：

```
HnFont.ttf                    荣耀主字体
HnEmoji.ttf / EmojiIcon.otf   荣耀 emoji
HONORSansVFCondensed.ttf      可变窄体（粗细滑块调它）
HONORSansVFConItalic.ttf
HONORSansVFArabic.ttf / UI    可变阿拉伯字体
RobotoFlex-Regular.ttf        可变拉丁
```

⚠️ 只放进 targets 的 `[sym]` 分区是**不够的**：那只挡"名单路径"，
**自动目录扫描**仍会把 `HnFont.ttf` 当普通主字体替换掉。
所以这份名单被并进 `_role_set` 的判定里，与"粗细调节族引用的字体"走同一条路
（`ROLE=vadj` → 计划里永远不出现）。

结论：荣耀上本模块**只替换扫描发现的常规字体**（Noto 语言字体等），
荣耀专属主字体 / 可变字体一律保持系统原样。宁可少换，不许开不了机。

### 🛡 「粗细调节」族引用的字体同样不替换

字体配置里如果某个族带 `supportWeightAdjustment="true"`，说明系统会按字体的
**变体轴**实时调节它。判据刻意收紧成「**有族名(name=)或有语言标签(lang=)**」——
因为有的 ROM 里还有**无名**族也带这个属性、引用的却是通用拉丁主字体，
那种不能挡（挡了英文就不换了）。真机配置上实测：只识别出 4 个可变字体。

### 🔍 新增：厂商 / 主题字体目录统一探测（只读）

各家把「设置里选的字体」放在各自的目录里。报告里现在会列出这些目录的实况：

```
[已覆盖] MIUI主题        /data/system/theme/fonts        —— 17 个字体（普通文件 17 / 链接 0）
[未覆盖] 荣耀主题        /data/system/theme_magic/fonts  —— 4 个字体（普通文件 4 / 链接 0）
[未覆盖] ColorOS-桥接    /data/format_unclear/font       —— 12 个字体（普通文件 4 / 链接 8）
[未覆盖] vivo-bbkcore    /data/bbkcore/theme             —— ...
```

**只探测、不替换**。目的是能回答"这台机器上到底有没有别的地方还存着主题字体"——
如果现象是「部分界面 / 锁屏时钟没变」，多半就是这些「未覆盖」目录在起作用。

其中 `符号链接 → /system/fonts` 的条目，我们替换系统字体时**已经覆盖**；
只有**普通文件**（独立副本）才是真空缺。
**这些目录现在可以真的替换了**（走 WebUI 里的「也替换主题里选的字体」开关，
**默认关**，关着的时候一个字都不碰）：

| 目录 | 厂商 |
|---|---|
| `/data/format_unclear/font` | ColorOS/OPPO 字体桥接 |
| `/data/oplus/uxres/theme` | ColorOS 主题资源 |
| `/data/bbkcore/theme` | vivo/BBK 核心主题 |
| `/data/skin/fonts` | vivo 皮肤 |
| `/data/theme/fonts`、`/data/themes` | 通用主题 |

**只替换普通文件，符号链接一律跳过** —— 链接指向 `/system/fonts` 的条目，
我们替换系统字体时已经覆盖了；去替换链接本身会把链接变成实体文件，
等于永久改变厂商语义（备份也会被污染）。

**刻意不接**：

- `/data/system/theme_magic/fonts`（荣耀）—— 主字体被替换后可能与
  「字体和图标粗细」冲突导致 SystemUI 异常，只探测不替换
- `/data/fonts/**`（AOSP 可更新字体）—— 属于谷歌字体链路，另一套处理

替换走的是现成的 `datafont_swap`：备份原件到字体库、内容没变就不重写（幂等）、
切回「无字体」或卸载模块时自动还原。

### ✚ targets 补三个「系统引用了、却没被替换」的字体

从云端 62 份报告里挖出来的（主语言被配置引用、本次没换、且名单里完全没有）：

| 字体 | 语言 | 出现 | 加到 |
|---|---|---|---|
| `NotoSerifHentaigana.ttf` | ja | 4 台（HyperOS + ColorOS） | hyperos `[kana]`、coloros `[lang]` |
| `Oplus-Serif.ttf` | und | 1 台（一加 PJX110） | coloros `[theme]` |
| `DancingScript-Bold.ttf` | und | 1 台（一加 PJX110） | coloros `[theme]` |

落位是按分区语义来的：`[kana]`/`[lang]` 归「保留其它语言」开关管，
`[theme]` 归「保留特殊字形」开关管 —— 已用 `slots.sh` 里同一套过滤逻辑验证过，
默认设置下会被选中，打开对应开关会被正确排除。

> 生效方式：targets 是**扫描时**用的，所以升级模块时会自动重扫（cache key 里带
> targets 的 mtime，改了就失效）；手动重扫也行（WebUI 的「重新扫描」）。
