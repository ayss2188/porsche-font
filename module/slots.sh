#!/system/bin/sh
# slots.sh - 字体槽位发现与分类
#
# 思路（吸取"按设备真实情况生成"的做法，而不是固定清单硬铺）：
#   1. 只替换设备上"真实存在"的字体文件，不凭空创建不存在的路径（减少挂载节点）
#   2. 候选来源：字体配置 XML 中的主文字族 ∪ 本 ROM 已知文件名 ∪ OEM 命名规则
#   3. 按文件名给每个槽位分角色，默认不碰：其他文字体系/日韩、符号/Emoji、
#      衬线/等宽/时钟/展示/斜体 等"高风险"槽位
#   4. 按字体实际覆盖范围决定范围（中英文 / 仅英文 / 仅中文）
#
# 用法（source 后调用）：
#   slot_plan <模块目录> <scope:all|latin|cjk> <keep_lang:0|1> <keep_special:0|1>
#     -> 每行输出 "角色 目标路径"，目标路径相对 /，如 latin system/fonts/Roboto-Regular.ttf
#   slot_report <模块目录>   -> 角色统计（诊断用）
#
# FSROOT 仅供测试：把真实路径前缀到一个模拟根目录下。

FSROOT=${FSROOT:-}

_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------------
# 真实存在的字体目录（输出绝对路径，不含 FSROOT）
# ---------------------------------------------------------------------------
slot_dirs() {
  # ★ 2026-10-17（作者原则）：**先读安装时存下的环境情报**。
  #   `"$FSROOT"/*/fonts "$FSROOT"/*/*/fonts` 要展开根目录下所有子目录/二级子目录，
  #   而这个函数在一次 apply 里被调用 5~10 次 —— 每次重新 glob 就是几十秒。
  local _el="${LIB:-/data/adb/custom_font_lib}/scanned/env.list"
  if [ -s "$_el" ]; then
    local _hit
    _hit=$(sed -n 's/^dir=//p' "$_el" 2>/dev/null)
    if [ -n "$_hit" ]; then
      printf '%s\n' "$_hit"
      return 0
    fi
  fi
  # ★ 1.0.9.2：**加进程内缓存**（SLOT_DIRS_CACHE）。
  #   这个函数每次调用都要遍历所有分区、用 glob 找 `*/fonts` 目录
  #   （`"$FSROOT"/*/fonts "$FSROOT"/*/*/fonts`）。而它在一次运行里被调用 **6 次以上**
  #   （slot_candidates、slot_scan_candidates、slot_plan、报告第 5 节、字体目录映射…）。
  #   "设备上有哪些字体目录"在一次运行内不会变 —— 重复扫描纯属浪费，
  #   在真机（分区多、目录多）上尤其明显。这是第 1 步里最容易被忽略的一块固定开销。
  # ★ 2026-10-16 修：**空结果不许当缓存**。`${VAR+x}` 只判"变量存在"，
  #   而空串也算存在 —— 分区没就绪时算出的空会被当成有效缓存锁死整场运行
  #   （表现：识别系统误判成类原生、槽位计划为空）。
  if [ -n "${SLOT_DIRS_CACHE+x}" ] && [ -n "$SLOT_DIRS_CACHE" ]; then
    printf '%s\n' "$SLOT_DIRS_CACHE" | grep -v '^[[:space:]]*$'
    return 0
  fi
  SLOT_DIRS_CACHE=$(
    {
      for d in /system/fonts /system_ext/fonts /product/fonts /vendor/fonts /odm/fonts /oem/fonts \
               /my_product/fonts /my_region/fonts /my_company/fonts /my_carrier/fonts /my_stock/fonts \
               /my_heytap/fonts /my_manifest/fonts /my_bigball/fonts /mi_ext/fonts /hw_product/fonts \
               /prism/fonts /optics/fonts /product/vivo/fonts /system_ext/vivo/fonts /vendor/vivo/fonts \
               /oplus_product/fonts /oplus_engineering/fonts /oplus_version/fonts /oplus_region/fonts; do
        [ -d "$FSROOT$d" ] && echo "$d"
      done
      # 未知厂商分区自动发现：/xxx/fonts 与 /xxx/yyy/fonts
      for d in "$FSROOT"/*/fonts "$FSROOT"/*/*/fonts; do
        [ -d "$d" ] || continue
        parent=${d%/fonts}
        [ -L "$parent" ] && continue          # /system/product 之类的符号链接，避免重复
        p=${d#"$FSROOT"}
        case "$p" in
          /data/*|/sdcard/*|/storage/*|/mnt/*|/proc/*|/sys/*|/dev/*|/apex/*|/linkerconfig/*|\
          /config/*|/metadata/*|/cache/*|/acct/*|/debug_ramdisk/*|/second_stage_resources/*|\
          /system/etc/*|/system/usr/*|/system/app/*|/system/priv-app/*) continue ;;
        esac
        echo "$p"
      done
    } | sort -u
  )
  # ★ 2026-10-16 空结果兜底（真机实测：/system/fonts 明明存在，这里却返回 0 条）：
  #   一台有字体的机器**绝不该**一条目录都扫不到 —— 这是不变量。
  #   返回 0 条的后果极严重：_xm_exclusive_font 找不到字体 → 识别系统误判成类原生，
  #   而识别错了会去读 targets/aosp.list（36 条）而不是 targets/hyperos.list（99 条），
  #   替换范围跟着错。
  #   所以：扫完是空 → 直接用硬编码清单兜底（逐个核实存在），不让"0 条"传下去。
  if [ -z "$(printf '%s' "$SLOT_DIRS_CACHE" | tr -d '[:space:]')" ]; then
    SLOT_DIRS_CACHE=$(
      for d in /system/fonts /system_ext/fonts /product/fonts /vendor/fonts \
               /odm/fonts /oem/fonts /mi_ext/fonts /my_product/fonts /hw_product/fonts \
               /prism/fonts /optics/fonts; do
        [ -d "$FSROOT$d" ] && echo "$d"
      done | sort -u
    )
  fi
  printf '%s\n' "$SLOT_DIRS_CACHE" | grep -v '^[[:space:]]*$'
}

# ---------------------------------------------------------------------------
# 字体配置 XML 文件列表
# ---------------------------------------------------------------------------
# 永不替换名单的缓存文件（小写、一行一个名字）
#   由扫描阶段生成，也允许 _role_set 在缺失时兜底生成。
slot_skip_file() {
  printf '%s/scanned/skip.list\n' "${LIB:-/data/adb/custom_font_lib}"
}

# ---------------------------------------------------------------------------
# ★ 2026-10-20：**「粗细调节」族引用的字体 → 一律不替换**
#
#   背景（真机证据：荣耀 MagicOS 11.0.0.109 的 fonts.xml）：
#     <family name="sans-serif-condensed" supportWeightAdjustment="true" honortag="true">
#       <font weight="100" style="normal">HONORSansVFCondensed.ttf <axis tag="wght" .../>
#     <family lang="und-Arab" variant="elegant" supportWeightAdjustment="true">
#       <font weight="400">HONORSansVFArabic.ttf <axis tag="wght" .../>
#
#   这类族是给系统「字体和图标粗细」滑块用的：系统会按字体的**变体轴**实时调节。
#   我们替换的是**静态字体**，轴上没有 wght → 滑块失灵，个别 ROM（MagicOS）
#   还会因此出现 SystemUI 异常（实测过：把这类族换成静态字体后，MagicOS 上
#   SystemUI 会反复异常）。
#   常规解法是"把这些族静态化"（改写 XML），但我们**不改 XML** ——
#   所以选更保守的一条：这些族引用的字体**根本不碰**。
#
#   判据刻意收紧：要求族**有名字(name=)或有语言标签(lang=)**。
#   因为 MagicOS 里还有两块**无名**族也开了 supportWeightAdjustment，引用的却是
#   Roboto-Regular.ttf（通用拉丁主字体）—— 那种不能挡，挡了英文就不换了。
#
#   输出：每行一个字体文件名（已小写，供 _role_set 比对）
# ---------------------------------------------------------------------------
slot_vadj_files() {
  [ -n "${VADJ_CACHE+x}" ] && { [ -n "$VADJ_CACHE" ] && printf '%s\n' "$VADJ_CACHE"; return 0; }
  VADJ_CACHE=""
  local _x _o
  for _x in $(slot_xml_files 2>/dev/null); do
    [ -f "$_x" ] || continue
    _o=$(awk '
      BEGIN { infam = 0; isadj = 0; isid = 0 }
      /<family/ {
        infam = 1; isadj = 0; isid = 0
        if ($0 ~ /supportWeightAdjustment="true"/) isadj = 1
        if ($0 ~ /name="/ || $0 ~ /lang="/)       isid = 1
      }
      infam {
        if (isadj && isid) {
          line = $0
          while (match(line, /[A-Za-z0-9_.-]+\.(ttf|otf|ttc)([[:space:]]|<|$)/)) {
            s = substr(line, RSTART, RLENGTH)
            gsub(/[[:space:]<>]/, "", s)
            print s
            line = substr(line, RSTART + RLENGTH)
          }
        }
        if ($0 ~ /<\/family>/) infam = 0
      }' "$_x" 2>/dev/null)
    [ -n "$_o" ] && VADJ_CACHE="$VADJ_CACHE$_o
"
  done
  VADJ_CACHE=$(printf '%s' "$VADJ_CACHE" | sort -u)
  [ -n "$VADJ_CACHE" ] && printf '%s\n' "$VADJ_CACHE"
  return 0
}

# ---------------------------------------------------------------------------
# 生成"永不替换名单"（小写、一行一个）到 scanned/skip.list
#
#   两份来源合起来：
#     ① 字体配置里「开了粗细调节、又有族名/语言标签」的族所引用的字体
#     ② targets/protect.list（明确点名"任何路径都不许替换"的，例如主字体）
#
#   ①必须要求"有族名/语言标签"：有的 ROM 里还有无名族也开粗细调节、
#   引用的却是通用拉丁主字体，那种挡了会让英文完全不换。
# ---------------------------------------------------------------------------
slot_skip_list() {   # $1=moddir
  local moddir="${1:-${MODDIR:-}}" out pl
  out=$(slot_skip_file 2>/dev/null)
  [ -n "$out" ] || return 0
  mkdir -p "${out%/*}" 2>/dev/null
  pl="$moddir/targets/protect.list"
  {
    slot_vadj_files 2>/dev/null
    if [ -s "$pl" ]; then
      sed -n 's/^[[:space:]]*//; s/[[:space:]]*$//; /^#/d; /^\[/d; /^$/d; p' "$pl" 2>/dev/null
    fi
  } | tr 'A-Z' 'a-z' | sort -u > "$out.tmp.$$" 2>/dev/null &&
    mv -f "$out.tmp.$$" "$out" 2>/dev/null
  rm -f "$out.tmp.$$" 2>/dev/null
  [ -s "$out" ] && cat "$out"
  return 0
}

slot_xml_files() {
  # ★ 2026-10-17（作者原则）：**先读安装时存下的环境情报**，不再 glob。
  #   `"$FSROOT"/*/etc/*font*.xml` 这种写法要展开根目录下所有子目录 ——
  #   而这个函数在一次 apply 里会被 key 计算反复调用（5~10 次）。
  local _el="${LIB:-/data/adb/custom_font_lib}/scanned/env.list"
  if [ -s "$_el" ]; then
    local _hit
    _hit=$(sed -n 's/^xml=//p' "$_el" 2>/dev/null)
    if [ -n "$_hit" ]; then
      printf '%s\n' "$_hit"
      return 0
    fi
  fi
  local x
  # ★ 2026-10-20：补 `flyme_*.xml` —— 魅族的字体配置里有一份 **`flyme_fallback.xml`**，
  #   名字里**没有 "font"**，所以下面那条 `*font*.xml` 通配永远匹配不到它。
  #   魅族系的字体配置里确实存在这个文件（`flyme_fallback.xml` /
  #   `flyme_font_fallback.xml` 都有，只是名字里不带 "font"），里面是
  #   「后备字体链」的映射 —— 漏了它，魅族设备的后备字体就完全不参与替换。
  #   （云端报告目前还没有魅族样本，等拿到设备再核实实际内容。）
  for x in "$FSROOT"/system/etc/*font*.xml "$FSROOT"/system_ext/etc/*font*.xml \
           "$FSROOT"/product/etc/*font*.xml "$FSROOT"/vendor/etc/*font*.xml \
           "$FSROOT"/odm/etc/*font*.xml "$FSROOT"/*/etc/*font*.xml \
           "$FSROOT"/*/etc/flyme_*.xml; do
    [ -f "$x" ] && echo "$x"
  done | sort -u
}

# ---------------------------------------------------------------------------
# 一次扫完所有字体配置，列出**所有被中文（lang 以 zh 开头）引用的 .ttc 合集**：
#   每行 "<文件名> <序号> <lang>"，例如
#   NotoSansCJK-Regular.ttc 2 zh-Hans
#   NotoSansCJK-Regular.ttc 3 zh-Hant,zh-Bopo
#
# 为什么要有它：一个合集里装着好几套字（实测三星 SM-S9280 与魅族 Flyme 12.6 都是
#   0=ja  1=ko  2=zh-Hans  3=zh-Hant,zh-Bopo），**只能换中文那几号**，
# 日/韩留着原字形，否则用户的中文字体没有假名/谚文字形，日韩文本就变方块。
#
# 性能：整份 XML 只起 2 个进程（tr + sed），和 slot_xml_names 一个路子；结果在同一个
# 进程里缓存（TTC_PAIRS_CACHE），一条命令里被问多次也只扫一遍。
# ---------------------------------------------------------------------------
ttc_cn_pairs() {
  local x fam hdr body rest attrs name l idx
  # ★ 2026-10-17（作者原则：扫描只在安装时一次）：**先读安装时存下的 TTC 清单**。
  #   原来这里要把每个 XML 全文读进来（tr + sed + while 逐 family 解析），
  #   用户的 fonts.xml 有几 MB、8~15 个文件 → 一次就要几十秒。
  #   而 ttc_enabled 在一次 apply 里会被调用好几次（每次都是新进程，缓存留不住）。
  #   安装时已经算过一次，存成 scanned/ttc.list，之后直接读它。
  if [ -z "${TTC_PAIRS_CACHE+x}" ]; then
    local _tl="${LIB:-/data/adb/custom_font_lib}/scanned/ttc.list"
    if [ -s "$_tl" ]; then
      # ★ 2026-10-19 修 Bug 2：读到清单后**必须在这里输出**。
      #   原来这里只赋值 + return 0、没有 printf —— 用 `$(ttc_cn_pairs | awk ...)`
      #   的调用方（ttc_cn_indices，决定换哪几个 face）永远拿到空，
      #   只能落到兜底"只换 2 号"，简中/繁中的准确对应就丢了。
      TTC_PAIRS_CACHE=$(grep -v '^[[:space:]]*$' "$_tl" 2>/dev/null)
      [ -n "$TTC_PAIRS_CACHE" ] && printf '%s\n' "$TTC_PAIRS_CACHE"
      return 0
    fi
    if [ -f "$_tl" ]; then
      # 清单在、但是空的 = 安装时确认过这台设备没有中文 TTC 合集。
      # （写入器已经修好，不会再把自己截断成空，所以这个结论可信。
      #   1.3.5~1.3.7 留下的旧空文件由安装阶段的一次性迁移清掉。）
      TTC_PAIRS_CACHE=""
      return 0
    fi
    TTC_PAIRS_CACHE=$(
      for x in $(slot_xml_files); do
        [ -f "$x" ] || continue
        tr '\n\r\t' '   ' 2>/dev/null < "$x" | sed 's/<family/\n<family/g' \
          | while IFS= read -r fam || [ -n "$fam" ]; do
              case "$fam" in '<family'*) ;; *) continue ;; esac
              hdr=${fam%%>*}
              l=""
              case "$hdr" in *' lang="'*) l=${hdr#*' lang="'}; l=${l%%\"*} ;; esac
              case "$l" in [Zz][Hh]*) ;; *) continue ;; esac
              body=${fam#*>}
              rest=$body
              while :; do
                case "$rest" in *'<font'*) ;; *) break ;; esac
                rest=${rest#*<font}
                attrs=${rest%%>*}
                rest=${rest#*>}
                name=${rest%%<*}
                _trim "$name"
                case "$TRIM_OUT" in
                  *.[Tt][Tt][Cc])
                    idx=0
                    case "$attrs" in *' index="'*) idx=${attrs#*' index="'}; idx=${idx%%\"*} ;; esac
                    case "$idx" in ''|*[!0-9]*) idx=0 ;; esac
                    printf '%s %s %s\n' "$TRIM_OUT" "$idx" "$l"
                    ;;
                esac
              done
            done
      done | sort -u
    )
  fi
  [ -n "$TTC_PAIRS_CACHE" ] && printf '%s\n' "$TTC_PAIRS_CACHE"
  return 0
}

# ---------------------------------------------------------------------------
# 某个 .ttc 合集里"哪几号 face 是中文" —— 要换成用户字体的就是这几号
# 用法：ttc_cn_indices <文件名> [face总数]
#
# 兜底：这个文件一个中文引用都没有时，**只换 2 号**那一号 face。
#
# 为什么只换 2 号（以前是"2 号往后全换"）：2 号是 Noto / 三星这几套 CJK 合集里
# 简体中文（zh-Hans）的位置，这是最可靠的一个惯例；再往后是什么**完全没法保证**——
# 万一某机型的 3 号是日文，全换就会把日文换成用户字体、日文直接变方块。
# 换句话说：这里宁可"只让中文跟着变"，也不赌别的语言。
# （配置里能读到中文引用时走上面的 xml 分支，压根用不到这个兜底。）
#
# 顺便把"凭什么这么判"回填到两个全局变量，给诊断报告用（见 fontctl.sh 的 ttc.log）：
#   TTC_CN_SRC    = xml（按字体配置）/ fallback（按惯例兜底）/ none（没得换）
#   TTC_CN_DETAIL = 匹配到的 lang:index 明细，如 "zh-Hans:2 zh-Hant,zh-Bopo:3 "
# 注意：要拿到这两个变量，调用时别用 $(...) 包（那会开子 shell），改成重定向到临时文件再读。
# ---------------------------------------------------------------------------
ttc_cn_indices() {
  local want="$1" total="${2:-0}" pairs hans i
  TTC_CN_SRC="none"; TTC_CN_DETAIL=""
  pairs=$(ttc_cn_pairs 2>/dev/null | awk -v f="$want" '$1 == f { print $3 ":" $2 }' | sort -u)
  if [ -n "$pairs" ]; then
    TTC_CN_SRC="xml"     # 依据：字体配置里的 zh-* 引用
    # 繁体那一号要不要跳过 —— 1.0.8 起按"用户有没有自己调过 + 字体有没有繁体字形"判：
    #   · 用户自己调过 keep_lang  → 完全按他的（1=保留繁体 / 0=连繁体一起换）
    #   · 没调过 → 看字体 meta：没有繁体字形（hant=0）就跳过繁体那一号（免得变方块），有就一起换
    # 例外：如果这个合集**只**被繁中引用（纯繁体用户），就照换 —— 否则中文一点都不会变。
    _skip_hant=0
    _kl_user=$(sed -n 's/^keep_lang=//p' "$SETTINGS" 2>/dev/null | tail -n1 | tr -d '\r\n')
    if [ -n "$_kl_user" ]; then
      [ "$_kl_user" = 1 ] && _skip_hant=1
    else
      _meta_have hant || _skip_hant=1
    fi
    if [ "$_skip_hant" = 1 ]; then
      hans=$(printf '%s\n' "$pairs" | grep -vi 'hant\|bopo')
      if [ -n "$hans" ]; then
        TTC_CN_DETAIL="$(printf '%s' "$pairs" | tr '\n' ' ')（已跳过繁体那一号：你的字体没有繁体字形）"
        pairs="$hans"
      fi
    fi
    [ -n "$TTC_CN_DETAIL" ] || TTC_CN_DETAIL=$(printf '%s' "$pairs" | tr '\n' ' ')
    printf '%s\n' "$pairs" | sed 's/.*://' | sort -n -u
    return 0
  fi
  if [ "$total" -ge 3 ] 2>/dev/null; then
    TTC_CN_SRC="fallback"   # 配置里没找到中文引用 → 只按最可靠的惯例动 2 号
    TTC_CN_DETAIL="配置里没有中文引用，按惯例只换 2 号（zh-Hans 常见位置）"
    printf '2\n'
  fi
  return 0
}

# 某个 <family> 是否属于"主文字族"（无语言 / 拉丁 / 中文），排除衬线、等宽、Emoji 等
# 纯 shell 大小写不敏感匹配，不启动任何外部进程（性能关键）
_xml_family_ok() {
  case "$1" in
    *[Ee][Mm][Oo][Jj][Ii]*|*[Ss][Yy][Mm][Bb][Oo][Ll]*|*[Mm][Oo][Nn][Oo]*|*[Cc][Uu][Rr][Ss][Ii][Vv][Ee]*|\
    *[Cc][Aa][Ss][Uu][Aa][Ll]*|*[Mm][Aa][Tt][Hh]*|*[Mm][Uu][Ss][Ii][Cc]*|*[Cc][Ll][Oo][Cc][Kk]*)
      return 1 ;;
  esac
  case "$1" in
    *[Ss][Aa][Nn][Ss]-[Ss][Ee][Rr][Ii][Ff]*|*[Ss][Aa][Nn][Ss][Ss][Ee][Rr][Ii][Ff]*) : ;;
    *[Ss][Ee][Rr][Ii][Ff]*) return 1 ;;
  esac
  if [ -n "$2" ]; then
    case "$2" in
      *[Zz][Hh]*|*[Uu][Nn][Dd]-[Ll][Aa][Tt][Nn]*|[Ee][Nn]|[Ee][Nn]-*) : ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# 去掉字符串首尾空格（纯 shell，结果写入 TRIM_OUT，不启动进程）
_trim() {
  local s="$1"
  while case "$s" in ' '*) true ;; *) false ;; esac; do s=${s# }; done
  while case "$s" in *' ') true ;; *) false ;; esac; do s=${s% }; done
  TRIM_OUT="$s"
}

# ---------------------------------------------------------------------------
# 语言标签精确判定（2026-10-14 新增）
#
# 为什么需要它：`_role_set` 原来用 `*ko*` / `*ja*` 这种**子串**判日韩，会误命中：
#     lang="und-Nkoo"（西非 NKo 文字）  含 "ko" → 被判成**韩文**
#     lang="und-Java"（爪哇文）          含 "ja" → 被判成**日文**
# 后果不只是"名字叫错"：自适应补全会把这两种字体当成韩文/日文槽位**换掉**，
#   而用户字体里没有 NKo / 爪哇字形 → **那两种文字变方块**。
#
# 判定规则（精确，不是子串）：
#     整串必须是 <码> 或 <码>-<地区…> 的形式；
#     也接受逗号分隔的多个标签（如 `zh-Hant,zh-Bopo`）。
#     `und-Nkoo` 里的 "nkoo" 是以 `und-` 开头的脚本码，**不算**语言码。
# ---------------------------------------------------------------------------
_lang_is() {   # $1=语言标签串  $2=要找的码（如 ko / ja）
  local _s _t _p
  # ★ 2026-10-17：空标签直接返回，别起进程（调用方现在也会先判，这里是兜底）
  [ -n "${1:-}" ] || return 1
  _s=$(_lc "${1:-}")
  _t=$(_lc "$2")
  [ -n "$_s" ] || return 1
  while [ -n "$_s" ]; do
    _p=${_s%%,*}
    case "$_p" in
      "$_t"|"$_t"-*) return 0 ;;
    esac
    case "$_s" in
      *,*) _s=${_s#*,} ;;
      *)   break ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# 【1.0.9 新增】自适应扫描：从**设备自己的字体配置**挖出"哪种语言用哪个字体文件"
#
# 为什么需要（作者要求）：
#   作者手上只有小米机器，适配别的机型全靠别人的真机报告。诊断报告**最核心的价值**
#   就是回答"他这台系统的字体到底靠什么生效"。以前这条信息散在第 5/6 节的原始 XML 里，
#   得人肉去读；这一版直接把它整理成"语言 → 字体文件"的清单。
#
#   另外：**角色判定必须看配置里的语言标签**，不能看文件名。
#   实测教训：UnknownHant-Regular.ttf 这种名字一眼能看出是繁体，但真实机型上
#   中文主字体常常叫 SysSans-Hans-Regular.ttf / VivoFont.ttf / SECCJK-Regular.ttc ——
#   文件名里根本没有 hans/hant/kana 这些字样，猜不出来。配置里的 lang="zh-Hans" 才是实锤。
#
# 输出（每行）："<角色> <文件名> <语言标签>"，角色由 family 的 lang 决定：
#   lang 含 zh-Hant/zh-Bopo/zh-HK/zh-TW/zh-MO → lang   （繁体那份，归"保留日韩等文字"管）
#   lang 含 zh                                 → cjk    （简中 / CJK 主字体）
#   lang 含 ja                                 → kana   （日文）
#   lang 含 ko                                 → hangul （韩文）
#   lang 为空                                  → main   （无语言的通用主字体）
#   lang 含 en / und-Latn                      → latin  （拉丁）
#   其它语言（阿拉伯、泰文、天城文…）           → 跳过   （不归我们碰）
#   family 名带 Emoji/Symbol/Clock/Serif…      → 跳过   （装饰/符号，_xml_family_ok 挡掉）
# 性能：整份 XML 只起 2 个进程（tr + sed），结果在同一进程里缓存（SCAN_NAMES_CACHE）。
# ---------------------------------------------------------------------------
slot_scan_names() {
  local x fam hdr body rest name n l role
  # ★ 2026-10-16 修：空结果不许当缓存（同上）
  if [ -z "${SCAN_NAMES_CACHE+x}" ] || [ -z "$SCAN_NAMES_CACHE" ]; then
    SCAN_NAMES_CACHE=$(
      for x in $(slot_xml_files); do
        [ -f "$x" ] || continue
        tr '\n\r\t' '   ' 2>/dev/null < "$x" | sed 's/<family/\n<family/g' \
          | while IFS= read -r fam || [ -n "$fam" ]; do
              case "$fam" in '<family'*) ;; *) continue ;; esac
              hdr=${fam%%>*}
              n=""; l=""
              case "$hdr" in *' name="'*) n=${hdr#*' name="'}; n=${n%%\"*} ;; esac
              case "$hdr" in *' lang="'*) l=${hdr#*' lang="'}; l=${l%%\"*} ;; esac
              # 装饰/符号/等宽/衬线这类不碰（和主文字族同一套判定）
              _xml_family_ok "$n" "" || continue
              # ★ 按"配置里的语言标签"定角色（这是实锤；文件名只能算线索，见上面说明）
              #
              # ★★ 2026-10-14 修：这里原来是 `*ja*` / `*ko*` **子串**匹配，会误命中：
              #     lang="und-Nkoo"（西非 NKo 文字）含 "ko" → 判成**韩文**
              #     lang="und-Java"（爪哇文）        含 "ja" → 判成**日文**
              #   危害不是"名字叫错"：自适应补全会把这两种字体当韩文/日文槽位**换掉**，
              #   而用户字体没有 NKo / 爪哇字形 → **那两种文字变方块**。
              #   （合成一个"没适配过的 ROM"复现过：NKo、Java 两个都被当成日韩补进了计划。）
              #   现在用 `_lang_is`（完整语言标签判定），`und-Nkoo` 里的 "nkoo" 是以
              #   `und-` 开头的脚本码，不再算语言码。
              l=$(_lc "$l")
              case "$l" in
                *zh-hant*|*zh-bopo*|*zh-hk*|*zh-tw*|*zh-mo*) role=lang ;;
                *zh*)                                          role=cjk ;;
                "")                                            role=main ;;
                *en*|*und-latn*)                               role=latin ;;
                *)
                  if   _lang_is "$l" ja; then role=kana
                  elif _lang_is "$l" ko; then role=hangul
                  else role=""          # 其它语言（阿拉伯、天城文、NKo、爪哇…）：不碰
                  fi ;;
              esac
              [ -n "$role" ] || continue
              body=${fam#*>}
              rest=$body
              while :; do
                case "$rest" in
                  *'>'*'<'*) ;;
                  *) break ;;
                esac
                rest=${rest#*>}
                name=${rest%%<*}
                rest=${rest#*<}
                _trim "$name"; name="$TRIM_OUT"
                case "$name" in *.[Tt][Tt][Ff]|*.[Oo][Tt][Ff]) ;;
                  *) continue ;;
                esac
                printf '%s %s %s\n' "$role" "${name##*/}" "${l:-und}"
              done
            done
      done | sort -u
    )
  fi
  printf '%s\n' "$SCAN_NAMES_CACHE" | grep -v '^[[:space:]]*$'
}

# 从 XML 里取主文字族引用的字体文件名
# 性能：整份 XML 只起 2 个进程（tr + sed），family/文件名都用 shell 内建解析；
# 旧写法是"每个 family 起 4~6 个进程"，500 个 family 会 fork 上千次，手机上要卡好几秒。
# ★ 2026-10-17 提速：给 slot_xml_names（8 个字体配置）加**持久缓存**。
#   它只跟 8 个字体配置 本身有关，切开关完全不影响结果，
#   但原来每次 apply/reapply 都要重算一遍（约 1 秒）。
#   key 取相关文件的 mtime+size，变了自动失效；扫到空不缓存（防开机早期锁死）。
slot_xml_names() {
  local _kc="" _kd
  # 一次 stat 拿全部 XML 的 mtime+size（原来每个文件一次 stat = 8 个进程）
  local _ver
  # ★ 2026-10-17 修：key 里必须带**脚本版本**（slots.sh 的 mtime）。
  #   否则升级模块后，会命中旧逻辑算出来的缓存 —— 用户实测就踩到了：
  #   候选语义从"按开关过滤"改成"固定全读"，但缓存没失效，
  #   于是装新包后槽位从 78 变成 46（少了 [clock] 那批）。
  _ver="$(stat -c '%Y' "${MODDIR:-}/slots.sh" 2>/dev/null)"
  _kc="$_ver|$(stat -c '%n:%Y-%s' $(slot_xml_files 2>/dev/null) 2>/dev/null | tr '\n' '|')"
  _kd="${LIB}/.xmlnames.cache"
  if [ -n "$_kc" ] && [ -s "$_kd" ]; then
    if [ "$(sed -n '1p' "$_kd" 2>/dev/null)" = "$_kc" ]; then
      sed -n '2,$p' "$_kd" 2>/dev/null
      return 0
    fi
  fi
  local _out
  _out=$(slot_xml_names_raw)
  if [ -n "$_out" ]; then
    if [ -n "$_kc" ]; then
      { printf '%s\n' "$_kc"; printf '%s\n' "$_out"; } > "$_kd.tmp.$$" 2>/dev/null \
        && mv -f "$_kd.tmp.$$" "$_kd" 2>/dev/null
    fi
  fi
  printf '%s\n' "$_out"
}

slot_xml_names_raw() {
  local x fam hdr body rest name n l
  for x in $(slot_xml_files); do
    tr '\n\r\t' '   ' 2>/dev/null < "$x" \
      | sed 's/<family/\n<family/g' \
      | while IFS= read -r fam || [ -n "$fam" ]; do
          case "$fam" in '<family'*) ;; *) continue ;; esac
          hdr=${fam%%>*}
          n=""; l=""
          case "$hdr" in *' name="'*) n=${hdr#*' name="'}; n=${n%%\"*} ;; esac
          case "$hdr" in *' lang="'*) l=${hdr#*' lang="'}; l=${l%%\"*} ;; esac
          _xml_family_ok "$n" "$l" || continue
          # family 头之后的部分里，逐个取出 >名字< 形式的内容
          body=${fam#*>}
          rest=$body
          while :; do
            case "$rest" in
              *'>'*'<'*) ;;
              *) break ;;
            esac
            rest=${rest#*>}
            name=${rest%%<*}
            rest=${rest#*<}
            _trim "$name"; name="$TRIM_OUT"
            case "$name" in
              *.[Tt][Tt][Ff]|*.[Oo][Tt][Ff]) printf '%s\n' "$name" ;;
            esac
          done
        done
  done | sed 's#.*/##' | sort -u
}

# 本 ROM 已知文件名（targets/<rom>.list；aosp 清单始终包含）
slot_static_names() {
  # $1=模块目录  $2=keep_lock  $3=keep_lang  $4=keep_special
  #
  # ★ 2026-10-17：targets 改成**分区**格式后，用 awk 一次过完。
  #   为什么不用 shell 循环：while + case + continue 嵌套在真机/toybox 上
  #   容易出"卡住"这种难查的问题（作者真机上真出现过），awk 没有这些坑。
  #
  # 分区 → 开关：
  #   main/base            永远读
  #   clock                 keep_lock=1 时**不读**
  #   cjk/kana/hangul/lang  keep_lang=1 时**不读**
  #   theme/serif/italic/mono/display  keep_special=1 时**不读**
  #   sym                   永不读
  local moddir="$1" keep_lock="${2:-0}" keep_lang="${3:-0}" keep_special="${4:-0}"
  local rom list
  rom=$(tr -d '[:space:]' 2>/dev/null < "$moddir/current_rom")

  for list in "$moddir/targets/$rom.list" "$moddir/targets/aosp.list"; do
    [ -f "$list" ] || continue
    awk -v kl="$keep_lock" -v kg="$keep_lang" -v ks="$keep_special" '
      function trim(s) {
        gsub(/^[ \t\r]+/, "", s); gsub(/[ \t\r]+$/, "", s); return s
      }
      {
        line = trim($0)
        if (line == "") next
        if (substr(line, 1, 1) == "#") next
        # 分区标记：[zone]  后面可能有注释
        if (substr(line, 1, 1) == "[") {
          z = line
          sub(/^\[/, "", z); sub(/\].*$/, "", z)
          zone = trim(z)
          next
        }
        # 按分区决定要不要
        if (zone == "clock" && kl == 1) next
        if ((zone == "cjk" || zone == "kana" || zone == "hangul" || zone == "lang") && kg == 1) next
        if ((zone == "theme" || zone == "serif" || zone == "italic" || \
             zone == "mono" || zone == "display") && ks == 1) next
        if (zone == "sym") next
        # 去掉路径前缀，只要文件名
        n = split(line, a, "/"); print a[n]
      }
    ' "$list"
  done | sort -u
}

# ---------------------------------------------------------------------------
# ★ 2026-10-17（作者要求）：能不能**跳过目录扫描**
#
# 背景：slot_dir_names 要遍历所有字体目录、逐个 stat 判断大小，
#       在真机上是整条链路里最慢的一步。而适配过的机型有 targets 清单，
#       清单里的名字已经覆盖了主力槽位 —— 这时扫描是纯浪费。
#
# 判定（三个都满足才跳，宁可慢也不漏）：
#   ① 有 targets/<rom>.list
#   ② 清单命中率 > 50%（抽查清单里的名字，在这台设备上真存在多少）
#      对不上说明 ROM 版本差异大 → 还是要扫兜底
#   ③ scope = all（部分替换时扫描能补，不跳）
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# ★ 2026-10-17：清单里有没有 [clock] 分区？
#
# 用途：决定「保留锁屏时钟」这个开关走哪条路 ——
#   · 有 [clock] 分区 → 名单已经在 targets 里了，**不用再遍历 XML**（快）
#   · 没有          → 退回原来的 XML 扫描（兜底，1.2.0 的做法）
#
# 为什么这么设计（作者 2026-10-17 定）：
#   1.2.0 是靠遍历 8 个字体配置 XML 找 clock family 得到名单的，慢；
#   现在把那份名单（34 个）预先写进 targets 的 [clock] 分区，
#   开关打开时直接读分区就行 —— 行为跟 1.2.0 一致，但快得多。
#   万一某个机型的清单还没分区（老格式），就还是走扫描，不会漏。
# ---------------------------------------------------------------------------
slot_has_clock_zone() {   # $1=moddir
  local moddir="${1:-${MODDIR:-}}" rom list
  [ -n "$moddir" ] || return 1
  rom=$(tr -d '[:space:]' 2>/dev/null < "$moddir/current_rom")
  [ -n "$rom" ] || return 1
  for list in "$moddir/targets/$rom.list" "$moddir/targets/aosp.list"; do
    [ -f "$list" ] || continue
    grep -q '^\[clock\]' "$list" 2>/dev/null && return 0
  done
  return 1
}


# ---------------------------------------------------------------------------
# ★ 2026-10-17（作者定的架构）：分三个文件，各管各的
#
#   targets/<机型>.list    人工验证的清单（含 [main][clock][theme] 分区）
#                          —— 跟着模块走，升级会更新，是"可信"的那份
#
#   $LIB/scanned/device.list  安装时扫本机得到的（兜底）
#                          —— 本机数据：设备特有的字体、厂商目录里的那些
#                             targets 没覆盖到的，都靠它补
#
#   $LIB/scanned/slots.list   最终槽位 = 上面两份合并去重
#                          —— **apply / reapply 只读这一个文件**
#
# 为什么分开：targets 是"我们验证过这台机型该替换哪些"，
#            scanned 是"这台设备上实际还有什么"。分开存，升级时才能
#            只更新前者、保留后者。
# ---------------------------------------------------------------------------
#   （下面这几个变量只是兜底；三个函数内部也各自算了一遍，
#     因为它们可能被单独 source 或调用，不能依赖顶层求值顺序）
SLOT_SCAN_DIR="${LIB:-/data/adb/custom_font_lib}/scanned"
SLOT_DEV_LIST="$SLOT_SCAN_DIR/device.list"
SLOT_USE_LIST="$SLOT_SCAN_DIR/slots.list"
SLOT_META="$SLOT_SCAN_DIR/slots.meta"


# ---------------------------------------------------------------------------
# ★ 扫描缓存有效性（2026-10-21）
#
#   背景：slot_build_slots 以前只在 device.list 不存在时才扫描，
#        于是从低版本升上来时，那份老缓存（少了新加的目录/新规则扫出来的条目）
#        会被一直沿用 —— 新版扫描逻辑等于没生效。
#
#   现在缓存旁边写一份 .schema：
#       schema=<扫描逻辑版本>   改扫描逻辑时手动 +1
#       rom=<current_rom>       换了系统（刷机/OTA）也要重扫
#       fp=<ro.build.fingerprint> 同 ROM 内的版本升级同样会换字体
#   任何一项对不上就删掉派生缓存重扫。
#   —— "偏低版本一下子升上来"正是靠这里的 schema 差异兜住。
# ---------------------------------------------------------------------------
#   注意：SLOT_SCAN_SCHEMA 只在**改了扫描逻辑**（目录范围、XML 解析、名字归一化等）时 +1。
#         普通发版不要动它 —— 否则每次更新都要重扫，永久目录就没意义了。
#         1.4.5 已经是"强制重扫一次"的版本（customize.sh 里的 FORCE_SCAN_ID），
#         所以这里保持 1 即可。
SLOT_SCAN_SCHEMA=1

slot_scan_cache_valid() {   # $1=moddir
  local moddir="${1:-${MODDIR:-}}"
  local _sd="${LIB:-/data/adb/custom_font_lib}/scanned"
  local mark="$_sd/.schema" sch rom fp
  [ -s "$_sd/device.list" ] || return 1
  [ -s "$mark" ] || return 1                    # 老版本没写过 .schema → 视为失效
  sch=$(sed -n 's/^schema=//p' "$mark" 2>/dev/null | tail -n 1)
  [ "$sch" = "$SLOT_SCAN_SCHEMA" ] || return 1
  rom=$(tr -d '[:space:]' 2>/dev/null < "$moddir/current_rom")
  [ "$(sed -n 's/^rom=//p' "$mark" 2>/dev/null | tail -n 1)" = "$rom" ] || return 1
  fp=$(getprop ro.build.fingerprint 2>/dev/null)
  if [ -n "$fp" ]; then
    [ "$(sed -n 's/^fp=//p' "$mark" 2>/dev/null | tail -n 1)" = "$fp" ] || return 1
  fi
  return 0
}

slot_scan_cache_drop() {
  local _sd="${LIB:-/data/adb/custom_font_lib}/scanned"
  rm -f "$_sd/device.list" "$_sd/slots.list" "$_sd/slots.meta" \
        "$_sd/skip.list" "$_sd/ttc.list" "$_sd/env.list" "$_sd/.schema" 2>/dev/null
  return 0
}

slot_scan_cache_stamp() {   # $1=moddir → 扫描完成后写指纹
  local moddir="${1:-${MODDIR:-}}"
  local _sd="${LIB:-/data/adb/custom_font_lib}/scanned"
  {
    echo "schema=$SLOT_SCAN_SCHEMA"
    echo "rom=$(tr -d '[:space:]' 2>/dev/null < "$moddir/current_rom")"
    echo "fp=$(getprop ro.build.fingerprint 2>/dev/null)"
    echo "time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  } > "$_sd/.schema" 2>/dev/null
  return 0
}

slot_device_scan() {   # $1=moddir → 生成 device.list
  local moddir="${1:-${MODDIR:-}}"
  local _sd="${LIB:-/data/adb/custom_font_lib}/scanned"
  local _dev="$_sd/device.list"
  local tmp n
  [ -n "$moddir" ] || return 1
  mkdir -p "$_sd" 2>/dev/null
  tmp="$_dev.tmp.$$"
  {
    slot_xml_names              | sed 's/^/x /'
    slot_static_names "$moddir" 0 0 0 | sed 's/^/s /'
    slot_oem_names "$moddir"    | sed 's/^/o /'
    slot_dir_names              | sed 's/^/d /'
  } 2>/dev/null > "$tmp.raw"
  awk '{ src=substr($0,1,1); nm=substr($0,3)
         if (nm == "") next
         rank=(src=="x")?1:(src=="s")?2:(src=="o")?3:4
         if (!(nm in R) || rank < R[nm]) { R[nm]=rank; L[nm]=nm } }
       END { for (nm in L) print L[nm] }' "$tmp.raw" > "$tmp.names" 2>/dev/null
  rm -f "$tmp.raw" 2>/dev/null
  : > "$tmp"
  local dirs d role l name
  dirs=$(slot_dirs 2>/dev/null)
  while read -r name; do
    [ -n "$name" ] || continue
    l=$(_lc "$name")
    _role_set "$l"
    role="$ROLE"
    case "$role" in sym|vadj) continue ;; esac
    for d in $dirs; do
      if [ -f "$FSROOT$d/$name" ]; then
        printf '%s %s %s\n' "$role" "$d" "$name" >> "$tmp"
        break
      fi
    done
  done < "$tmp.names"
  rm -f "$tmp.names" 2>/dev/null
  n=$(grep -c . "$tmp" 2>/dev/null || echo 0)
  if [ "${n:-0}" -ge 1 ]; then
    if mv -f "$tmp" "$_dev" 2>/dev/null; then
      slot_scan_cache_stamp "$moddir"
    return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}


# ② 生成 4 种开关组合的槽位清单（刷入时一次做完，切换时直接选文件）
#
#   作者的原则：「前提准备，后续完全无脑」
#   影响槽位的开关只有 keep_lockscreen / theme_fonts 两个 → 4 种组合，
#   每种生成一份文本清单（几百行、几十 KB，不占空间）。
#   切换时按开关直接选文件，**不做任何过滤**。
slot_build_slots() {   # $1=moddir
  local moddir="${1:-${MODDIR:-}}" rom tlist tmp tgt_n dev_n
  # ★ 这三个路径必须在这里自己算 —— 不能依赖顶层变量
  #   （这个函数会被单独 source 进测试，也可能在没有顶层求值的环境里被调）
  local _sd="${LIB:-/data/adb/custom_font_lib}/scanned"
  local _use="$_sd/slots.list"
  local _meta="$_sd/slots.meta"
  [ -n "$moddir" ] || return 1
  mkdir -p "$_sd" 2>/dev/null
  if ! slot_scan_cache_valid "$moddir"; then
    slot_scan_cache_drop
    slot_device_scan "$moddir" >/dev/null 2>&1
  fi
  [ -s "$_sd/device.list" ] || return 1
  rom=$(tr -d '[:space:]' 2>/dev/null < "$moddir/current_rom")
  tlist="$moddir/targets/${rom:-aosp}.list"
  [ -s "$tlist" ] || tlist="$moddir/targets/aosp.list"

  tmp="$_use.tmp.$$"
  cp -f "$_sd/device.list" "$tmp" 2>/dev/null || : > "$tmp"
  dev_n=$(grep -c . "$tmp" 2>/dev/null || echo 0)
  _bs_have=" $(awk '$3 != "" { print $3 }' "$tmp" 2>/dev/null | tr '\n' ' ') "

  tgt_n=0
  if [ -s "$tlist" ]; then
    local dirs d role l name
    dirs=$(slot_dirs 2>/dev/null)
    slot_static_names "$moddir" 0 0 0 2>/dev/null | while read -r name; do
      [ -n "$name" ] || continue
      case "$_bs_have" in *" $name "*) continue ;; esac
      l=$(_lc "$name")
      _role_set "$l"
      role="$ROLE"
      case "$role" in sym|vadj) continue ;; esac
      for d in $dirs; do
        if [ -f "$FSROOT$d/$name" ]; then
          printf '%s %s %s\n' "$role" "$d" "$name" >> "$tmp"
          break
        fi
      done
    done
    # ★ 2026-10-18：统计口径改成"机型清单命中数"。
    #   原来算的是"targets 独有、扫描没覆盖的" —— 而 targets 里的名字本来就会
    #   出现在扫描结果里，所以永远是 0，界面显示"机型清单里的 0 个"看着像没生效。
    #   现在算的是"targets 里、这台设备上真实存在的名字有几个"。
    # ★ 2026-10-18（作者澄清口径）：
    #   机型清单里的 = targets 清单里、这台设备上**真实存在**的名字数
    #   本机扫描补的 = 扫描发现、但 targets 清单里**没有**的（兜底那一部分）
    #   两者相加 = 总槽位
    #   注意要先按"名字"排序再做集合运算（comm 要求有序）。
    # ⚠️ 不能用 `comm <(...)` —— 进程替换是 bash 语法，ash/mksh 没有。
    #    用 awk 做集合运算：targets 里有的算"机型清单"，其余算"本机扫描补的"。
    _tn=$(slot_static_names "$moddir" 0 0 0 2>/dev/null)
    _dn=$(awk '$3 != "" { print $3 }' "$tmp" 2>/dev/null)
    _counts=$(awk -v tn="$_tn" -v dn="$_dn" '
      BEGIN {
        n = split(tn, A, "\n")
        for (i = 1; i <= n; i++) if (A[i] != "") T[A[i]] = 1
        m = split(dn, B, "\n")
        for (i = 1; i <= m; i++) {
          if (B[i] == "") continue
          if (B[i] in T) hit++
          else extra++
        }
        print hit + 0, extra + 0
      }')
    tgt_n=$(printf '%s' "$_counts" | awk '{print $1}')
    _extra_n=$(printf '%s' "$_counts" | awk '{print $2}')
    [ -n "$tgt_n" ] || tgt_n=0
    [ -n "$_extra_n" ] || _extra_n=0
  fi

  dev_n=$(grep -c . "$tmp" 2>/dev/null || echo 0)
  [ "${dev_n:-0}" -ge 1 ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  # 去重（同一个名字只留一条）
  awk '!seen[$3]++' "$tmp" > "$tmp.d" 2>/dev/null && mv -f "$tmp.d" "$tmp" 2>/dev/null
  dev_n=$(grep -c . "$tmp" 2>/dev/null || echo 0)

  # ── 锁屏名单（[clock] 分区）──
  # 用 awk 的字符串匹配（index/substr），不用 /^\[clock\]/ 那种正则写法 ——
  # 后者在这套 ash 上有转义坑，而且字符串匹配更直观。
  # 实测：hyperos.list 能正确取出 34 个名字。
  awk 'index($0, "[clock]") == 1 { f = 1; next }
       substr($0, 1, 1) == "[" { f = 0 }
       f && NF && substr($0, 1, 1) != "#" { print }' \
      "$tlist" 2>/dev/null > "$_sd/lockscreen.list"
  # 永不替换名单也在这里算好（扫描时一次），后面 _role_set 只读小文件
  slot_skip_list "$moddir" >/dev/null 2>&1
  _lk=" $(tr '\n' ' ' < "$_sd/lockscreen.list" 2>/dev/null | tr -s ' ') "

  # ── 四份清单 ──
  #   th=0：直接过滤
  #   th=1：过滤后再追加主题字体（theme_slots 要读目录，所以只在这里跑）
  _gen() {   # $1=输出文件  $2=kl(0/1)  $3=th(0/1)
    awk -v kl="$2" -v lock="$_lk" '
      BEGIN { n = split(lock, A, " "); for (i = 1; i <= n; i++) if (A[i] != "") LK[A[i]] = 1 }
      { if (kl == 1 && ($3 in LK)) next; print }
    ' "$tmp" > "$1" 2>/dev/null
    if [ "$3" = 1 ]; then
      # ★ 强制模式：这时开关可能是关着的，但我们要的是"打开后会是什么样"。
      #   theme_slots 只处理"已经在计划里的名字"，所以喂给它基础计划。
      # ⚠️ theme_slots 期望的是「role 相对路径」两列格式（它读第 2 字段当路径），
      #    而 slots.list 是「role 目录 文件名」三列 —— 必须先转换，
      #    否则它拿到的路径是 /system/fonts，跟文件名永远对不上，一个都加不进来。
      _base2=$(awk 'NF >= 3 { d = $2; sub(/^\//, "", d); print $1 " " d "/" $3 }' "$1" 2>/dev/null)
      ( CFS_FORCE_THEME=1; theme_slots "$_base2" 2>/dev/null ) \
        | awk '!seen[$0]++' >> "$1" 2>/dev/null
      awk '!seen[$0]++' "$1" > "$1.d" 2>/dev/null && mv -f "$1.d" "$1" 2>/dev/null
    fi
  }
  _gen "$_use"                 0 0     # slots.list      kl=0 th=0
  _gen "$_sd/slots.kl1.list"   1 0
  _gen "$_sd/slots.th1.list"   0 1
  _gen "$_sd/slots.kl1th1.list" 1 1

  mv -f "$tmp" "$_sd/device.all" 2>/dev/null

  # ── 环境情报（替代体积大的 glob）──
  {
    slot_xml_files 2>/dev/null | sed 's/^/xml=/'
    slot_dirs     2>/dev/null | sed 's/^/dir=/'
  } > "$_sd/env.list" 2>/dev/null
  # ── TTC 中文合集（读全部 XML，最贵的一步）──
  # ★ 2026-10-19 修 Bug 1（致命）：**绝对不能直接重定向到 ttc.list**。
  #   shell 会先把这个文件截断成 0 字节，然后才执行里面的命令；而 ttc_cn_pairs
  #   第一件事就是读它 —— 读到"存在但为空"就判定"这台机器没有中文 TTC 合集"
  #   并直接返回，于是写出来永远是空 → **从 1.3.5 起 TTC 替换全程失效**
  #   （三星简中走 SECCJK-Regular.ttc，导致中文一直没被换过）。
  #   改成写临时文件再 mv；解析不出东西时不留空文件。
  _ttc_tmp="$_sd/.ttclist.$$"
  {
    unset TTC_PAIRS_CACHE
    ttc_cn_pairs 2>/dev/null
  } > "$_ttc_tmp" 2>/dev/null
  if [ -s "$_ttc_tmp" ]; then
    mv -f "$_ttc_tmp" "$_sd/ttc.list" 2>/dev/null
  else
    # 没解析出东西：只有**确实读到了 XML** 才能得出"没有中文合集"这个结论，
    # 否则（一个 XML 都没读到）删掉清单，下次重新算，别留下错误的空结论。
    _xmln2=0
    for _tx2 in $(slot_xml_files 2>/dev/null); do
      [ -f "$_tx2" ] && _xmln2=$((_xmln2 + 1))
    done
    if [ "$_xmln2" -ge 1 ] 2>/dev/null; then
      : > "$_sd/ttc.list" 2>/dev/null
    else
      rm -f "$_sd/ttc.list" 2>/dev/null
    fi
    rm -f "$_ttc_tmp" 2>/dev/null
  fi

  {
    printf 'built=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    printf 'rom=%s\n' "${rom:-aosp}"
    # 口径（作者澄清）：
    #   targets = targets 清单里、这台设备上真实存在的名字数
    #   extra   = 扫描发现、但 targets 清单里没有的（兜底那一部分）
    #   total   = targets + extra
    printf 'targets=%s\n' "${tgt_n:-0}"
    printf 'extra=%s\n' "${_extra_n:-0}"
    printf 'total=%s\n' "$dev_n"
  } > "$_meta" 2>/dev/null
  return 0
}


# ③ 读最终槽位清单（apply / reapply 只走这里）
slot_device_fonts() {   # $1=moddir
  # 这里也自己算路径（这个函数可能被单独调用，不能依赖顶层变量）
  local _sd="${LIB:-/data/adb/custom_font_lib}/scanned"
  local _use="$_sd/slots.list"
  if [ ! -s "$_use" ]; then
    slot_build_slots "${1:-${MODDIR:-}}" >/dev/null 2>&1
  fi
  [ -s "$_use" ] && grep -v '^[[:space:]]*$' "$_use" 2>/dev/null
  return 0
}

slot_targets_ready() {   # $1=moddir
  local moddir="${1:-}" rom list n
  [ -n "$moddir" ] || return 1
  rom=$(tr -d '[:space:]' 2>/dev/null < "$moddir/current_rom")
  [ -n "$rom" ] || return 1
  list="$moddir/targets/$rom.list"
  [ -s "$list" ] || return 1
  n=$(grep -c . "$list" 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 30 ] || return 1
  return 0
}
# ★ 2026-10-17（作者要求）：新架构下"要不要扫目录"这个问题已经不存在了 ——
#   候选只来自安装时生成的 scanned/slots.list。这个函数保留成恒返回 1（不跳过），
#   是为了让老代码路径（没有清单时）照旧能兜底扫描。
slot_can_skip_scan() {
  return 1
}



# OEM 命名规则：扫描真实目录，匹配厂商主字体命名
# ★ 2026-10-17 提速：给 slot_oem_names（厂商配置）加**持久缓存**。
#   它只跟 厂商配置 本身有关，切开关完全不影响结果，
#   但原来每次 apply/reapply 都要重算一遍（约 0.2 秒）。
#   key 取相关文件的 mtime+size，变了自动失效；扫到空不缓存（防开机早期锁死）。
slot_oem_names() {
  local _kc="" _kd
  for _kf in /data/adb/modules/*/system/etc/fonts.xml /data/adb/modules/*/system/etc/fonts.xml.bak; do [ -f "$_kf" ] && _kc="$_kc|$_kf:$(stat -c '%Y-%s' "$_kf" 2>/dev/null)"; done
  _kd="${LIB}/.oemnames.cache"
  if [ -n "$_kc" ] && [ -s "$_kd" ]; then
    if [ "$(sed -n '1p' "$_kd" 2>/dev/null)" = "$_kc" ]; then
      sed -n '2,$p' "$_kd" 2>/dev/null
      return 0
    fi
  fi
  local _out
  _out=$(slot_oem_names_raw)
  if [ -n "$_out" ]; then
    if [ -n "$_kc" ]; then
      { printf '%s\n' "$_kc"; printf '%s\n' "$_out"; } > "$_kd.tmp.$$" 2>/dev/null \
        && mv -f "$_kd.tmp.$$" "$_kd" 2>/dev/null
    fi
  fi
  printf '%s\n' "$_out"
}

slot_oem_names_raw() {
  local moddir="$1" rom pat d b l t
  rom=$(tr -d '[:space:]' 2>/dev/null < "$moddir/current_rom")
  case "$rom" in
    coloros)  pat='sysfont*|syssans*|oplussans*|oplusosui*|opposans*|opsans*|din*|oppodin*|sourcesanspro*' ;;
    originos) pat='*vivosans*|*vivo-sans*|*originsans*|*origin-sans*|*iqoosans*|*iqoo-sans*' ;;
    flyme)    pat='*flymefont*|*flymesans*|*flyme-sans*|*meizusans*|*meizu-sans*|*mflyme*' ;;
    *) return 0 ;;
  esac
  t="${TMPDIR:-/data/local/tmp}/.oem.$$"
  for d in $(slot_dirs); do
    ls -1 "$FSROOT$d" 2>/dev/null > "$t"
    tr '[:upper:]' '[:lower:]' < "$t" > "$t.l"
    exec 3< "$t"; exec 4< "$t.l"
    while IFS= read -r b <&3 && IFS= read -r l <&4; do
      case "$l" in *.ttf|*.otf) ;; *) continue ;; esac
      case "$l" in
        $pat) [ -f "$FSROOT$d/$b" ] && echo "$b" ;;
      esac
    done
    exec 3<&- 4<&-
  done | sort -u
  rm -f "$t" "$t.l" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 角色分类（按文件名；输出之一）：
#   sym     符号 / Emoji / 图标 / 彩色            默认永不替换
#   lang    其他文字体系 / 日韩                     keep_lang=1 时不替换
#   italic  斜体                                   keep_special=1 时不替换
#   serif mono clock display                       keep_special=1 时不替换
#   latin   拉丁主字体（Roboto / GoogleSans 等）
#   cjk     中文专用槽位（Hans / Hant / SC / TC）
#   main    其他主文字槽位（OEM 中英混合主字体、数字命名权重文件等）
# ---------------------------------------------------------------------------


_role_set() {
  local l="$1" lang="${2:-}"
  # ★ 2026-10-20：「粗细调节」族引用的字体一律不替换（见 slot_vadj_files 的说明）
  # ★ 名单的算法放在 slot_skip_list 里（扫描阶段算一次、落成小文件）。
  #   这里只读文件 —— 子 shell 里反复调用 _role_set 才不会每次都去解析 XML。
  if [ -z "${VADJ_READY:-}" ]; then
    VADJ_READY=1
    VADJ_SPACED=""
    _skf=$(slot_skip_file 2>/dev/null)
    if [ -s "$_skf" ]; then
      VADJ_SPACED=$(tr '\n' ' ' < "$_skf" 2>/dev/null)
    else
      # 兜底：文件还没生成（比如刚装上、还没扫描）→ 现在算一份并写下来
      slot_skip_list "${MODDIR:-${moddir:-}}" >/dev/null 2>&1
      [ -s "$_skf" ] && VADJ_SPACED=$(tr '\n' ' ' < "$_skf" 2>/dev/null)
    fi
  fi
  case " ${VADJ_SPACED:-} " in
    *" $l "*) ROLE=vadj; return ;;
  esac
  case "$l" in
    # ★ 2026-10-13 修：`*cond*`（窄体/浓缩体）必须**排在符号规则之前**。
    #   原因：符号规则里的 `*icon*` 是纯子串匹配，会把 **sem·icon·densed** 命中 ——
    #   于是 `SFPRO-SemiCondensed{Bold,Light}.otf`（魅族自己的西文/数字字体，
    #   见 targets/flyme.list）被判成"符号"，而符号**永不替换**。
    #   实测来源：2 份魅族真机报告（Redmi M098FE / Flyme 12.6）里这两个文件
    #   都在 /product/fonts、都被配置引用，却一个槽位都没进计划。
    #   把窄体判定提上来就正常了 —— **顺序在这里就是语义，别随手调**。
    *condensed*|*cond[-_.]*) ROLE=display; return ;;
    *emoji*|*symbol*|*icon*|*material*|*color*|*flag*|*dingbat*|*lottie*|*braille*|*mathematical*|*music*)
      ROLE=sym; return ;;
    # ★ 2026-10-14 修：日韩改成"**看语言标签**"，不再用 `*ko*`/`*ja*` 子串。
    #   有语言标签时以它为准（配置里的 lang 才是实锤）；
    #   没有标签时才退回文件名，且用更严的边界模式（`korean`/`japanese` 这类整词，
    #   或 `-kr-`/`_kr_`/`.kr.` 这种带分隔符的写法），避免再撞 NKo / Java。
    *)
      # ★ 2026-10-17 提速：**$lang 为空时根本不进 _lang_is**。
      #   原来不管有没有 lang 都调它，而 _lang_is 内部要起 tr 进程做小写化 ——
      #   slot_candidates / slot_dir_names 那条路**不传 lang**，
      #   于是每台机器上 292 个名字 × 4 个进程 = 1168 个进程，
      #   全花在"空字符串里有没有 ko / ja"这种判断上。
      #   改成先判空：有 lang 才调（那才是真需要看标签的场景），没 lang 直接看文件名。
      if [ -n "$lang" ]; then
        if _lang_is "$lang" ko; then ROLE=hangul; return; fi
        if _lang_is "$lang" ja; then ROLE=kana; return; fi
      else
        case "$l" in *korean*|*hangul*|*kore[-_.]*) ROLE=hangul; return ;; esac
        case "$l" in *japanese*|*kana*|*japan[-_.]*) ROLE=kana; return ;; esac
      fi
      case "$l" in
        *jpan*|*jp[-_.]*|*kr[-_.]*) ROLE=lang; return ;;
      esac
      ;;
  esac
  case "$l" in
    *arab*|*hebr*|*thai*|*deva*|*beng*|*taml*|*telu*|*gujr*|*guru*|*knda*|*mlym*|*orya*|*sinh*|\
    *khmr*|*khmer*|*laoo*|*mymr*|*myanmar*|*geor*|*armn*|*ethi*|*tibt*|*tibetan*|*cherokee*|\
    *milanpro*|*naskh*|*nastaliq*|*kufi*|*lao[-_.]*)
      ROLE=lang; return ;;
    *clock*) ROLE=clock; return ;;
    *mono*|*courier*|*cutive*|*michroma*|*consol*|*monaco*|*menlo*) ROLE=mono; return ;;
    *italic*|*oblique*) ROLE=italic; return ;;
    *sansserif*|*sans-serif*) : ;;
    *serif*) ROLE=serif; return ;;
  esac
  case "$l" in
    *lobster*|*dancing*|*comingsoon*|*carrois*|*dela*|*chamberi*|*gulfs*|*neumatic*|*interscaled*|\
    *bebas*|*beihai*|*silk*|*rounded*|*square*|*hz[-_.]*|*qinghe*|*mihaus*|\
    *c800*|*rcf*)
      ROLE=display; return ;;
  esac
  case "$l" in
    # 繁体/香港专用的那一份，归到 lang（=「保留日韩及其他文字」管的范围）。
    # 原因：很多用户导入的是"简体字库"或某字体的 SC 版，里面没有 靉/鶚/懞 这类繁体字；
    # 而 MIUI 的 zh-Hant 家族正好指向 MiSansTCVF.ttf 这类文件 —— 一旦被顶掉，
    # 后面没有别的兜底，那些字就变成方块。保持让它走系统字体最安全；
    # 用户若确实想让繁体也换，把「保留日韩及其他文字的字体槽」关掉即可。
    # 注意：这一组必须排在 `*hans*` 前面，否则 SourceHanSansHK 这类会被 hans 抢先吃掉。
    *hant*|*tc[-_.]*|*tcvf*|*misanstc*|*traditional*|*big5*|*hk[-_.]*) ROLE=lang; return ;;
    *hans*|*cjk*|*chinese*|*sc[-_.]*|*misansl3*) ROLE=cjk; return ;;
    roboto*|googlesans*|google-sans*|productsans*|*latin*|samsungone*|notosans-*|\
    miuiex*|mitype*|inter*|opensans*|lato*|sourcesans*|worksans*|nunito*) ROLE=latin; return ;;
  esac
  ROLE=main
}

# 对外接口：输入原始文件名，输出角色
#   $2 = 可选的**语言标签**（配置里那个 family 的 lang 属性）。
#        给了就用它精确判日韩（`_lang_is`），没有才退回文件名模式。
#        为什么加这个参数：文件名里 `NKo`/`Java` 这种会撞 `*ko*`/`*ja*`，
#        而配置里的 lang 标签是权威的 —— 详见 `_lang_is` 的注释。
slot_role() { _role_set "$(_lc "$1")" "${2:-}"; echo "$ROLE"; }

# ---------------------------------------------------------------------------
# 自动让路（2026-10-12 新增）—— 1.0.8 的核心
#
# 背景：以前"日文/韩文/繁体"和"时钟/斜体/衬线"默认**保留系统字体**，理由是"怕用户字体缺字形"。
#   但作者指出：**用户装了字体就是想全变**，默认保守反而让人以为"模块没生效"；
#   而"缺字形"这件事**导入时就已经测出来了**（界面用 JS 探针把 latin/cjk/hant/kana/hangul
#   写进 $LIB/<id>.meta），根本不用等用户看到方块再回来关开关。
#
# 所以改成：**默认全替换**；只有"字体确实没有那一类字形"时，才**自动**把那部分留给系统字体。
#   · meta 说没有韩文     → 韩文槽位自动保留（不会造方块）
#   · meta 说都有         → 全部替换（用户要的"全局生效"）
#   · 老字体没有 meta     → 保守保留（宁可少换，也不给用户造方块）
# 用户不需要懂这些；报告里会写清"哪些没换、因为你的字体没有那些字形"。
# ---------------------------------------------------------------------------
_meta_have() {   # $1=latin|cjk|hant|kana|hangul  → 0=可以换（有字形，或未知）/ 1=字体确实没有
  local k="$1" id v
  case "$k" in latin|cjk|hant|kana|hangul) ;; *) return 0 ;; esac
  [ -n "${LIB:-}" ] || return 0
  # 选中的字体：优先用外面传进来的（make_plan 会设），否则读 pending_font（开机脚本也用得上）
  id="${SEL_FONT:-}"
  [ -n "$id" ] || id=$(tr -d '[:space:]' 2>/dev/null < "${MODDIR:-}/pending_font")
  case "$id" in ""|none) return 0 ;; esac
  id=${id%%+*}                       # 组合字体（a+b）取主字体做判定
  # 没有元数据（老字体、导入时没测到）→ 按"有"处理、照换。
  #   为什么不保守：保守会让用户看到"某处永远不变"，那正是作者最烦的现象；
  #   而"字体确实缺字形"的情况正常都会被 meta 记下来（hangul=0 这种），不会走到这里。
  [ -f "$LIB/$id.meta" ] || return 0
  v=$(sed -n "s/^$k=//p" "$LIB/$id.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')
  case "$v" in
    1) return 0 ;;                   # 有 → 可以替换
    *) return 1 ;;                   # 0 或空 → 让路
  esac
}

# 某个槽位需要哪一类字形（用文件名判，够稳且不依赖文件名之外的任何东西）
#   hangul 韩文 / kana 日文假名 / hant 繁体 / cjk 其它中文（含简体、没写明语言的 CJK 槽）
_slot_script() {
  case "$1" in
    *[Kk]orean*|*[Hh]angul*|*[Kk]ore*)                  echo hangul ;;
    *[Jj]apan*|*[Kk]ana*)                              echo kana ;;
    *[Tt][Cc][Vv][Ff]*|*[Tt]raditional*|*[Bb]ig5*)  echo hant ;;
    *[Ss]erif[Cc][Jj][Kk]*|*[Cc][Jj][Kk]*)              echo cjk ;;
    *) echo "" ;;
  esac
}

# 该角色在当前设置下是否参与替换
#
# ★ 1.0.9 简化（作者定的）★
#   取消「保留日文/韩文/繁体」与「保留时钟/等宽/斜体」两个开关 —— **默认全部替换**，
#   不给开关、也不再"按字形自动让路"。作者原话："默认就替换这些，不管他是不是方块；
#   如果有方块，那可能是字体没有这些东西 —— 但现在大家导入的字体一般都正常。"
#   少一个开关 = 少一个"用户不知道该不该开"的坑，也才真正是"全局生效"。
#   缺字形这件事**报告里会说清**（第 0 节列出"哪种语言没换、为什么"），不靠开关兜底。
#
#   唯一保留的**极端保护**在 slot_plan 里：字体完全没有中文字形时中文槽位不动 ——
#   否则整个界面全变方块，用户连 WebUI 都看不清、没法换回来。
#   （参数 keep_lang / keep_special 保留只为兼容旧调用方，本函数不再使用它们。）
# ---------------------------------------------------------------------------
# 【2026-10-14 新增】**精确识别锁屏专用字体**
#
# 为什么单独做这一件事（作者的分析）：
#   以前只有一个"保留特殊槽"的大开关，它把 clock/mono/italic/serif/display 一锅端地保留。
#   于是：不开替换 20 个槽位、开了 70 个 —— 多出来的 50 个里真正跟锁屏有关的只有几个，
#   其余（等宽、斜体、衬线、装饰）跟着一起被换 ⇒ 用户体感"替换不全"。
#   把开关关掉只是**治标**：想要自定义锁屏的人也被一起挡住了。
#   病根是"判据不精确" —— 所以这里给出**精确判据**，开关只作用于锁屏那几个。
#
# 判据（确定性，不猜）：
#   Android 锁屏时钟的字体挂在名字里带 `clock` 的 family 下，真机报告实测：
#     miclock / miclock-date / miclock-time / miclock-thin / miclock-thin-ug /
#     miclock-thin-tibetan / miclock-<各家字体名> / mitype-clock / mitype-clock-mono
#   **看 family，不看文件名** —— 真机上 `DelaGothicOne.otf` 名字里没有 clock，
#   只有 family `miclock-dela-gothic-one` 才能说明它是锁屏时钟的
#   （这个坑 diag.sh 里已经踩过一次，那里的注释还在）。
#
# 输出：每行一个**文件名**（不带目录）。进程内只解析一次，之后走缓存。
#
# ★ 性能（2026-10-14，第一版在这里踩了坑）：
#   `slot_plan` 会对**每个候选**问一次"_is_lockscreen 吗"（一台机器几十个），
#   而"设备上有哪些配置 XML"是固定的一小串 —— 所以：
#     ① `slot_xml_files` 只取一次（它自己起 `ls` 那类进程）；
#     ② 解析结果存进**全局** `LOCKSCREEN_CACHE`，
#        ⚠️ 注意必须用 `while ... done < 文件` 或 here-doc，**不能用管道**
#        （`cmd | while` 在 POSIX sh 里跑在子 shell，变量赋值传不出来 ⇒ 每问一次重解析一次、
#         整段计划从十几秒涨到几分钟。第一版就是这么写的，实测卡住好几分钟才发现）。

# ---------------------------------------------------------------------------
# ★ 2026-10-15（作者的理念）：锁屏字体名单 **扫一次存起来，以后直接读**
#   名单是从字体配置 XML 里读出来的，而 XML 只在系统更新/刷机时才变 ——
#   典型"扫一次长期有效"。存在 $LIB/.scan/（专门的缓存目录）。
# ---------------------------------------------------------------------------
_lk_dir() { printf '%s' "$LIB/.scan"; }

_lk_key() {   # 当前状态指纹（变了就说明名单要重算）
  # ★ 2026-10-17 提速：一次 stat 拿全部 XML 的 mtime+size（原来每个文件 fork 两个进程）
  stat -c '%n:%s-%Y' $(slot_xml_files 2>/dev/null) 2>/dev/null | tr '\n' '|'
}

_lk_load() {
  # ★ 2026-10-17（作者要求）：锁屏名单优先读安装时存下的持久文件。
  #   targets 的 [clock] 分区就是人工验证过的名单，安装时已经存成
  #   scanned/lockscreen.list，这里直接读，不再走"缓存 → 分区 → 扫XML"三级。
  local _ll="${LIB:-/data/adb/custom_font_lib}/scanned/lockscreen.list"
  if [ -s "$_ll" ]; then
    _LOCK_LIST_SPACED=" $(tr '\n' ' ' < "$_ll" 2>/dev/null | tr -s ' ') "
    return 0
  fi   # 命中就 set LOCKSCREEN_CACHE 并返回 0
  local d="$LIB/.scan" f cur
  f="$d/lockscreen.txt"
  [ -f "$f" ] || return 1
  [ -s "$d/lockscreen.key" ] || return 1
  cur=$(_lk_key)
  [ "$cur" = "$(cat "$d/lockscreen.key" 2>/dev/null)" ] || return 1
  LOCKSCREEN_CACHE=$(cat "$f" 2>/dev/null)
  # ★ 2026-10-17：上一版是"扫出来是空 → 不算有效缓存 → 每次重扫"。
  #   但很多机型（一加/OPPO 等）**根本没有时钟专用字体**，扫出来永远是空 ——
  #   于是每次开机都白遍历 8 个 XML。现在把"确实是空"也缓存下来：
  #   保存时写 #NONE 标记，这里读到就当作"成功、名单为空"。
  case "$LOCKSCREEN_CACHE" in
    *'#NONE'*) LOCKSCREEN_CACHE="" ;;
  esac
  if [ -n "$LOCKSCREEN_CACHE" ]; then
    _LOCK_LIST_SPACED=$(printf '%s' "$LOCKSCREEN_CACHE" | tr '\n' ' ')
  else
    _LOCK_LIST_SPACED=""
  fi
  return 0
}


# ★ 2026-10-15：按**文件名**补认锁屏字体（作者真机实测出来的缺口）
#   为什么需要：`_role_set` 是按文件名判 clock 角色的（*clock*），
#     而这份名单原来只扫 XML 的 family 名 —— 两边判据不一致，
#     于是"只有文件、配置里没引用"的那批（真机例子：/product/fonts/MiClock.otf、
#     MitypeClock.otf 及其 Mono 变体）进了计划却不在名单里 → 开关对它们无效。
#   这里按文件名再扫一遍字体目录，把漏的补上。
_lk_add_byname() {   # $1=已有名单 → 输出补全后的名单
  # 按**文件名**补认锁屏字体（作者真机实测出来的缺口）。
  #
  # 为什么需要：`_role_set` 是按**文件名**判 clock 角色的（*clock*），
  #   而这份名单原来只扫 XML 的 family 名 —— 两边判据不一致，
  #   于是"只有文件、配置里没引用"的那批（真机例子：/product/fonts/MiClock.otf、
  #   MitypeClock.otf 及其 Mono 变体）进了替换计划却不在名单里 → 开关对它们无效。
  #
  # ⚠️ 路径必须写 `"$FSROOT$d"`：`slot_dirs` 给的是**相对系统根**的路径
  #    （/system/fonts 这种），模块里一律靠 $FSROOT 前缀落到真身
  #    （沙箱里是 /pfbox/system/fonts）。少了这个前缀就扫到空目录、白扫。
  #    我前两版分别漏了它、和改成只认配置名（slot_xml_names 也只认配置里引用的），
  #    两次都没解决问题 —— 这里留个记录，别再犯。
  local d f n out="$1"
  for d in $(slot_dirs 2>/dev/null); do
    [ -d "$FSROOT$d" ] || continue
    for f in "$FSROOT$d"/*; do
      [ -f "$f" ] || continue
      n=${f##*/}
      case "$n" in *'*') continue ;; esac      # glob 没匹配到会原样留着
      case "$(_lc "$n")" in
        *clock*|*keyguard*) ;;
        *) continue ;;
      esac
      case "$out" in
        *"$n"*) ;;                             # 已有，跳过
        *) out="$out$n
" ;;
      esac
    done
  done
  printf '%s' "$out" | grep -v '^[[:space:]]*$' | sort -u
}

_lk_save() {   # $1=名单内容（空 = 这台机器确实没有时钟专用字体）
  local d="$LIB/.scan"
  mkdir -p "$d" 2>/dev/null || return 0
  # ★ 2026-10-17：空名单也存（写 #NONE 标记）—— 见 _lk_load 里的说明。
  #   不存空的话，没时钟字体的机型每次开机都要重新遍历 XML，纯浪费。
  if [ -n "$1" ]; then
    printf '%s\n' "$1" > "$d/lockscreen.txt.tmp.$$" 2>/dev/null
  else
    printf '%s\n' "#NONE" > "$d/lockscreen.txt.tmp.$$" 2>/dev/null
  fi
  [ -f "$d/lockscreen.txt.tmp.$$" ] && \
    mv -f "$d/lockscreen.txt.tmp.$$" "$d/lockscreen.txt" 2>/dev/null
  _lk_key > "$d/lockscreen.key.tmp.$$" 2>/dev/null && \
    mv -f "$d/lockscreen.key.tmp.$$" "$d/lockscreen.key" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
_LOCK_FAM_RE='clock|lock|keyguard|watch'
# ★ 2026-10-17 提速（作者实测 1分50秒）：
#   锁屏名单**优先从 targets 的 [clock] 分区拿** —— 那是安装时就定好的，
#   读一个文本文件即可。扫 XML（要解析十几个文件、几十 MB）降级成最后的兜底。
slot_lockscreen_files() {
  if [ -n "${LOCKSCREEN_CACHE+x}" ]; then
    [ -n "$LOCKSCREEN_CACHE" ] && printf '%s\n' "$LOCKSCREEN_CACHE"
    return 0
  fi
  # ★ 2026-10-15（作者的理念）：**先读磁盘缓存** —— 扫过一次就不用再遍历 XML 了。
  #   命中就设好 LOCKSCREEN_CACHE / _LOCK_LIST_SPACED 并直接返回。
  if _lk_load 2>/dev/null; then
    [ -n "$LOCKSCREEN_CACHE" ] && printf '%s\n' "$LOCKSCREEN_CACHE"
    return 0
  fi
  # ★ 2026-10-17：缓存没有时，**先看 targets 有没有 [clock] 分区**。
  #   有就直接用那份名单（1.2.0 在小米上扫出的就是这 34 个，已原样搬进分区）——
  #   这样不用遍历 8 个 XML。没有分区时才往下走扫描（1.2.0 的老路）。
  if slot_has_clock_zone "${MODDIR:-${moddir:-}}" 2>/dev/null; then
    local _cz _rom
    _rom=$(tr -d '[:space:]' 2>/dev/null < "${MODDIR:-${moddir:-}}/current_rom")
    _cz=$(awk -v mod="${MODDIR:-${moddir:-}}" -v rom="$_rom" '
      BEGIN { }
      /^\[clock\]/ { on = 1; next }
      /^\[/ { on = 0; next }
      on && NF && $0 !~ /^#/ { n = split($0, a, "/"); print a[n] }
    ' "${MODDIR:-${moddir:-}}/targets/$_rom.list" 2>/dev/null)
    if [ -n "$_cz" ]; then
      LOCKSCREEN_CACHE=$(printf '%s\n' "$_cz" | sort -u)
      _LOCK_LIST_SPACED=$(printf '%s' "$LOCKSCREEN_CACHE" | tr '\n' ' ')
      _lk_save "$LOCKSCREEN_CACHE" 2>/dev/null
      printf '%s\n' "$LOCKSCREEN_CACHE"
      return 0
    fi
  fi
  local x fam hdr l body rest name out="" _XLS
  _XLS=$(slot_xml_files)          # ★ 只取一次
  for x in $_XLS; do
    [ -f "$x" ] || continue
    # ⚠️ 不用 `tr | sed | while`：那样 while 在子 shell 里，out 传不出来。
    #    改成"先把文件摊平成一行行的 <family 记录，再用 here-doc 喂给 while"。
    while IFS= read -r fam || [ -n "$fam" ]; do
      case "$fam" in '<family'*) ;; *) continue ;; esac
      hdr=${fam%%>*}
      l=$(_lc "$hdr")
      case "$l" in
        *clock*|*keyguard*) ;;
        *) continue ;;
      esac
      # 这个 family 里的所有字体文件都算进去
      body=${fam#*>}
      rest=$body
      while :; do
        case "$rest" in
          *'>'*'<'*) ;;
          *) break ;;
        esac
        rest=${rest#*>}
        name=${rest%%<*}
        rest=${rest#*<}
        _trim "$name"; name="$TRIM_OUT"
        case "$name" in
          *.[Tt][Tt][Ff]|*.[Oo][Tt][Ff]) out="$out$name
" ;;
        esac
      done
    done <<EOF
$(tr '\n\r\t' '   ' 2>/dev/null < "$x" | sed 's/<family/\n<family/g')
EOF
  done
  # 去目录、去空行、去重
  LOCKSCREEN_CACHE=$(printf '%s' "$out" | sed 's#.*/##' | grep -v '^[[:space:]]*$' | sort -u)
  LOCKSCREEN_CACHE=$(_lk_add_byname "$LOCKSCREEN_CACHE")
  # ★ 再建一份"空格分隔"的副本给 _is_lockscreen 做纯 shell 匹配 —— `tr` 只跑这一次。
  #   （不给它每次现跑 `tr`：那个函数会被调用几十次，每次一个进程。）
  _LOCK_LIST_SPACED=$(printf '%s' "$LOCKSCREEN_CACHE" | tr '\n' ' ')
    # ★ 2026-10-15（作者的理念）：**扫完就存起来** —— 以后（含重启后）直接读，不再遍历 XML。
    _lk_save "$LOCKSCREEN_CACHE" 2>/dev/null
  [ -n "$LOCKSCREEN_CACHE" ] && printf '%s\n' "$LOCKSCREEN_CACHE"
  return 0
}
# 判定单个文件：0 = 锁屏专用（shell 惯例：0 = 真）
#   ★ 零进程：名单在全局 _LOCK_LIST_SPACED 里，用"两侧带空格"的模式匹配避免子串误命中
#     （比如 `Clock.otf` 不该命中 `MiClock.otf`）。
_is_lockscreen() {   # $1=文件名
  [ -n "${1:-}" ] || return 1
  # ★ 2026-10-17 修（跟"空缓存锁死"同一类 bug）：
  #   原来写 `[ -n "${_LOCK_LIST_SPACED+x}" ]` —— 只判"变量是否存在"，
  #   而**空串也算存在** → 不重算名单 → 所有锁屏字体都认不出来 → 开关失灵。
  #   改成判非空：空串/未设都重算。
  [ -n "${_LOCK_LIST_SPACED:-}" ] || slot_lockscreen_files >/dev/null 2>&1
  case " ${_LOCK_LIST_SPACED:-} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

_role_wanted() {
  local role="$1" scope="$2" keep_lang="$3" keep_special="$4" name="${5:-}" keep_lock="${6:-0}"
  # ★ 极端保护（唯一的保留规则）：字体完全没有中文字形 → **除符号槽外一律不换**。
  #   为什么必须管住 main/latin 这些"看着跟中文无关"的角色：
  #     · 很多设备的通用主字体族（无语言的 <family>）**本身就是渲染中文的那个族**；
  #     · 一旦换掉，整个界面（连 WebUI 自己）会变方块，用户连「换回无字体」都点不到。
  #   所以这条是"整体不换"，不是"只不换中文槽"。正常字体（有中文字形）不会命中，一律全替换。
  if [ "${CJK_GUARD:-0}" = 1 ]; then
    return 1
  fi
  # ★ 2026-10-14：**锁屏专用字体**（family 名带 clock，见 slot_lockscreen_files）。
  #   开了「保留锁屏字体」就把它们挡在计划外 —— 这样用户还能在系统里挑锁屏时钟样式；
  #   而**其余所有槽位照旧全替换**。
  #   注意这不是以前那个 keep_special：那个是"clock/mono/italic/serif/display 一锅端"
  #   （不开 20 个、开了 70 个），把等宽/斜体/衬线/装饰也一起留了，
  #   用户体感就是"替换不全"。这里是**精确判据**，实测一台小米机认出 34 个、全对。
  #
  #   ⚠️ 两个性能要点：
  #     ① **先判 keep_lock**，默认（0）时短路，完全不碰锁屏扫描 —— 开关关着就零开销；
  #     ② `_is_lockscreen` 只在开关打开时才会被调用，而它内部有进程内缓存
  #        （`_LOCK_LIST_SPACED`，整个名单在内存里，判定本身零进程）。
  #   为什么在意：建这份表要遍历**所有**字体配置 XML，沙箱实测 107 秒（真机几秒），
  #   而 `slot_plan` 跑在自愈路径上、有超时，不能白花这个时间。
  # ★ 判断逻辑跟 1.2.0 **完全一致**（作者要求：跟 1.2.0 走）
  #   _is_lockscreen 内部会优先用磁盘缓存、其次 targets 的 [clock] 分区、
  #   最后才遍历 XML —— 名单来源变快了，但"哪些算锁屏字体"这个判断没变。
  if [ "$keep_lock" = 1 ] && _is_lockscreen "$name"; then
    return 1
  fi
  case "$role" in
    # ttc = .ttc 合集槽位（三星简中这类）。合集里同时装着 ja/ko/zh 好几套字形，
    # 只有用户选的是"中英文/全覆盖"字体时替换才合理，所以限定 scope=all。
    ttc)
      [ "$scope" = all ] || return 1
      return 0 ;;
    sym|vadj) return 1 ;;
    lang)
      [ "$scope" = all ] || return 1
      return 0 ;;
    italic|serif|mono|clock|display)
      : ;;    # 1.0.9：不再有"保留特殊槽"开关 —— 直接参与替换
  esac
  case "$scope" in
    latin) case "$role" in latin|italic|serif|mono|clock|display) return 0 ;; esac; return 1 ;;
    cjk)   [ "$role" = cjk ] && return 0; return 1 ;;
    *)     return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# 【1.0.9 新增】扫描来的候选：把 slot_scan_names 的结果跟"设备上真实存在的文件"配对
# 输出与 slot_candidates 同格式："角色 目录 文件名"
# 规则（保守，避免乱换）：
#   · 依赖设备自己的字体配置（有引用才认），不靠猜
#   · 排除 Emoji/符号/纯图标字体（_role_set 已经判成 sym 的跳过）
#   · 只输出"配置引用了、且文件确实在某个字体目录里"的项
#
# ★ 2026-10-14：**加进程内缓存**（SCAN_CANDS_CACHE）。
#   为什么必须加：`_role_count`/`slot_adaptive_extra` 和 `slot_plan` 都要这份结果，
#   而这个函数要遍历字体目录**逐文件判定存在性**（起进程）。沙箱实测单次 8 秒、
#   真机约 1 秒 —— 算两遍会让 `slot_plan` 从 20 秒涨到 29 秒，
#   而 `payload_mount` 的自愈有 **20 秒超时** → 超时 → 计划空 → 自愈失效。
#   （这条是回归测试抓到的：newfix-test 第 2 节"自愈没生效"。）
#   "设备上存在哪些字体文件"在一次运行内不会变，缓存是安全的。

# ---------------------------------------------------------------------------
# ★ 2026-10-15（作者的理念）：自适应扫描 **扫一次存起来，切换时直接读**
#   它扫的是"设备配置里的字体 − targets 里已知的 = 剩下没人管的"，
#   而这三样（配置 XML / targets 清单 / 字体目录）平时都不变 ——
#   典型"扫一次长期有效"。存 $LIB/.scan/scan.cache。
# ---------------------------------------------------------------------------
_sc_key() {
  # ★ 2026-10-17 提速：这个函数是"扫描缓存"的指纹，而它在 _sc_load / _sc_save
  #   里各被调一次 —— 原来每个文件/目录都单独 fork 一次（目录还要 `ls | wc -l`
  #   把几百个文件名列出来数一遍）。真机上这一步能吃掉好几秒。
  #   现在：
  #     · XML 和 targets 用**一次 stat 拿全部**（不逐个 fork）
  #     · 目录指纹用 **mtime**（增删文件时它一定会变，语义完全一样），
  #       不再 `ls | wc -l` 去数文件个数
  #     · 结果存进 _SC_KEY_MEM，同一次运行里只算一次
  if [ -n "${_SC_KEY_MEM:-}" ]; then
    printf '%s' "$_SC_KEY_MEM"
    return 0
  fi
  local k="" _xl="" _tl="" _dl="" x
  for x in $(slot_dirs 2>/dev/null); do
    [ -d "$x" ] && _dl="$_dl $x"
  done
  # 一次 stat 拿全部（-c '%n:%s-%Y' 每个文件一行）
  k=$(stat -c '%n:%s-%Y' $(slot_xml_files 2>/dev/null) 2>/dev/null | tr '\n' '|')
  k="$k|$(stat -c '%n:%s-%Y' "$MODDIR"/targets/*.list 2>/dev/null | tr '\n' '|')"
  if [ -n "$_dl" ]; then
    k="$k|$(stat -c '%n:%Y' $_dl 2>/dev/null | tr '\n' '|')"
  fi
  _SC_KEY_MEM="$k"
  printf '%s' "$k"
}

_sc_load() {   # 命中就 set SCAN_CANDS_CACHE 并返回 0
  local d="$LIB/.scan" f="$LIB/.scan/scan.cache" cur
  [ -s "$f" ] || return 1
  [ -s "$d/scan.key" ] || return 1
  cur=$(_sc_key)
  [ "$cur" = "$(cat "$d/scan.key" 2>/dev/null)" ] || return 1
  SCAN_CANDS_CACHE=$(cat "$f" 2>/dev/null)
  return 0
}

_sc_save() {   # $1=候选内容
  local d="$LIB/.scan"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$d/scan.cache.tmp.$$" 2>/dev/null && \
    mv -f "$d/scan.cache.tmp.$$" "$d/scan.cache" 2>/dev/null
  _sc_key > "$d/scan.key.tmp.$$" 2>/dev/null && \
    mv -f "$d/scan.key.tmp.$$" "$d/scan.key" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
slot_scan_candidates() {
  # ★ 2026-10-18（诊断报告提速，用户反馈完整报告要 8 分钟）：
  #   **优先读刷入时生成的永久清单** scanned/device.list。
  #   它就是"这台设备上扫到的全部候选"（格式 role dir name，跟本函数输出一致），
  #   而这里的旧逻辑在缓存失效时会**真的重扫四路** ——
  #   切字体/切开关都会让缓存失效，于是每次点"完整诊断"都要重扫。
  #   诊断报告是排错工具，不该为了它再扫一遍（数据早就有了）。
  local _dl="${LIB:-/data/adb/custom_font_lib}/scanned/device.list"
  if [ -s "$_dl" ]; then
    grep -v '^[[:space:]]*$' "$_dl" 2>/dev/null
    return 0
  fi

  # ★ 2026-10-16 修：空结果不许当缓存（同上）
  if [ -n "${SCAN_CANDS_CACHE+x}" ] && [ -n "$SCAN_CANDS_CACHE" ]; then
    printf '%s\n' "$SCAN_CANDS_CACHE" | grep -v '^[[:space:]]*$'
    return 0
  fi
  # ★ 2026-10-15（作者的理念）：**先读磁盘缓存** —— 扫过一次（含上次开机）就不用再扫了。
  #   命中时 SCAN_CANDS_CACHE 已经在 _sc_load 里设好。
  if _sc_load 2>/dev/null; then
    printf '%s\n' "$SCAN_CANDS_CACHE" | grep -v '^[[:space:]]*$'
    return 0
  fi
  SCAN_CANDS_CACHE=$(_slot_scan_candidates_uncached)
  # 扫完存起来，下次（包括重启后）直接读
  _sc_save "$SCAN_CANDS_CACHE" 2>/dev/null
  printf '%s\n' "$SCAN_CANDS_CACHE" | grep -v '^[[:space:]]*$'
}
_slot_scan_candidates_uncached() {
  local role name lang l d dirs
  dirs=$(slot_dirs)
  # ⚠ 必须读三个字段：slot_scan_names 每行是 "角色 文件名 语言标签"。
  #   只写 `read -r role name` 的话，sh 会把**剩下的整段**塞进最后一个变量
  #   （name 变成 "UnknownHangul-Regular.ttf ko"），后缀判定随即失败 → 整个函数什么都不输出。
  #   这个坑很难看出来，改输出格式时务必同步改这里。
  slot_scan_names | while IFS=' ' read -r role name lang; do
    [ -n "$role" ] && [ -n "$name" ] || continue
    case "$name" in *'*'*) continue ;; esac
    l=$(_lc "$name")
    case "$l" in *.ttf|*.otf) ;; *) continue ;; esac
    # 名字看着是符号/表情的，绝不换（换了就是满屏怪符号）
    # 注：这里写成 if 而不是 `[ ... ] && continue`，纯粹是为了可读性与稳妥。
    _role_set "$l" "$lang"
    case "$ROLE" in sym|vadj) continue ;; esac
    for d in $dirs; do
      # ★ 注意这里输出的是 $role（来自 slot_scan_names 的语言→角色判定），
      #   **不是** $ROLE —— `_role_set` 只是用来挡符号字体。两者的判据不同：
      #   scan 那条看配置的 lang（权威），_role_set 看文件名。
      [ -f "$FSROOT$d/$name" ] && printf '%s %s %s\n' "$role" "$d" "$name"
    done
  done
}

# 从扫描结果里查某个文件的"确定性脚本"（配置里的语言标签 → 脚本）
#   输出：cjk / kana / hangul / hant / ""（空 = 配置没说，或这文件不在配置里）
#   为什么不用文件名猜：真机上中文主字体常叫 SysSans-Hans-Regular.ttf / VivoFont.ttf /
#   SECCJK-Regular.ttc，文件名里没有 hans/hant 字样 —— 配置里的 lang 才是实锤。
_scan_script_of() {
  local want="$1"
  # ★ 2026-10-16 修：空串也算"没有缓存"，要重算
  { [ -n "${SCAN_NAMES_CACHE+x}" ] && [ -n "$SCAN_NAMES_CACHE" ]; } || slot_scan_names >/dev/null 2>&1
  # ★ 1.0.9.2：**先把"文件名→脚本"建成一张内存表**，之后纯内存查。
  #   原来这里是 `printf '%s\n' "$SCAN_NAMES_CACHE" | while read ...` ——
  #   每调用一次就起一个子 shell 管道、再逐行比对。而它被**每个候选各调一次**
  #   （作者机器 75 个候选 → 75 个子 shell + 75×N 次字符串比较），
  #   在手机上这是 sec0（报告第 0 节）里最贵的一块。
  #   现在：建表只做一次（SCAN_SCRIPT_MAP，进程内缓存），查询是纯 shell 模式匹配、不起进程。
  if [ -z "${SCAN_SCRIPT_MAP+x}" ]; then
    SCAN_SCRIPT_MAP=$(printf '%s\n' "$SCAN_NAMES_CACHE" | while IFS=' ' read -r _sr _sn _sl; do
      [ -n "$_sn" ] || continue
      case "$_sr:$_sl" in
        cjk:*)             _ss=cjk ;;
        kana:*)            _ss=kana ;;
        hangul:*)          _ss=hangul ;;
        lang:*zh-hant*|lang:*zh-bopo*|lang:*zh-hk*|lang:*zh-tw*|lang:*zh-mo*) _ss=hant ;;
        lang:*)            _ss=lang ;;
        *)                 _ss="" ;;
      esac
      [ -n "$_ss" ] && printf '|%s=%s' "$_sn" "$_ss"
    done)
  fi
  case "$SCAN_SCRIPT_MAP" in
    *"|$want="*) _SS_T=${SCAN_SCRIPT_MAP#*"|$want="}; printf '%s' "${_SS_T%%|*}" ;;
    *)           printf '%s' "" ;;
  esac
}

# 某个角色在候选里已经有几个（用来决定"要不要用扫描结果补"）
# 用 grep 数"以该角色开头的行"，精确且不受文件名里出现同名字符串干扰
_role_count() {
  printf '%s\n' "$CANDS_TMP" | grep -c "^$1 " 2>/dev/null
}

# ---------------------------------------------------------------------------
# 【1.0.9 新增】解释"某个槽位为什么没进计划"（进报告第 0 节）
#
# 目的：让作者**只看报告**就能定位问题，不用来回问用户。
#   以前报告只说"在/不在计划里"，看不出是"用户关了开关"还是"字体缺字形自动让路"——
#   这两种原因的修法完全相反（一个让用户开开关，一个要让用户换字体）。
#
# 判定用的就是**真实计划逻辑**（_role_wanted + _meta_have），不是另写一套猜的。
# 输出：一句能直接给用户看的话。
# ---------------------------------------------------------------------------
slot_why() {   # $1=角色 $2=文件名 $3=scope $4=keep_lang $5=keep_special
  local role="$1" name="$2" scope="$3" kl="$4" ks="$5" script
  # ① 先看"角色开关"放不放它（这一步和计划完全一致）
  if ! _role_wanted "$role" "$scope" "$kl" "$ks" "$name"; then
    case "$role" in
      lang)
        case "$(_slot_script "$name")" in
          kana)   echo "被保留：开了「保留日文」，日文继续用系统字体" ;;
          hangul) echo "被保留：开了「保留韩文」，韩文继续用系统字体" ;;
          hant)   echo "被保留：开了「保留繁体」，繁体继续用系统字体" ;;
          *)      echo "被保留：「保留日文/韩文/繁体」开着" ;;
        esac ;;
      clock) echo "被保留：开了「保留时钟/等宽/斜体等特殊槽」" ;;
      mono)  echo "被保留：开了「保留等宽槽」（终端那类）" ;;
      italic) echo "被保留：开了「保留斜体槽」" ;;
      serif) echo "被保留：开了「保留衬线槽」" ;;
      ttc)   echo "被保留：「替换 .ttc 合集」没打开（这类机型的中文在合集里）" ;;
      sym)   echo "刻意不动：符号/表情字体换了会显示异常" ;;
      vadj)  echo "刻意不动：这个族开了「粗细调节」，换掉会让系统界面的粗细滑块出问题" ;;
      vadj)  echo "刻意不动：这个族开了「粗细调节」，换掉会让系统界面的粗细滑块出问题" ;;
      *)     echo "被保留：不在本次替换范围（范围=$scope）" ;;
    esac
    return 0
  fi
  # ② 角色开关放行 → 那就是"自动让路"按字形挡住了（字体没有这类字形）
  script=$(_slot_script "$name")
  [ -n "$script" ] || script=$(_scan_script_of "$name")
  case "$script" in
    kana|hangul|hant|cjk)
      echo "自动让路：你的字体里没有「$script」这类字形，这处留给系统字体（避免方块）" ;;
    "") echo "不在计划里（角色开关放行了，但计划里没有它 —— 请把这份报告发给作者）" ;;
    *)  echo "不在计划里（脚本=$script）" ;;
  esac
}
#
# 这是作者最需要的一段：他只有小米机器，适配别的机型全靠别人的报告。
# 以前"这台系统靠什么生效"要人肉去读第 6 节的原始 fonts.xml；现在直接列出来。
# 输出（每行）："zh-Hans|中文简体|SysSans-Hans-Regular.ttf|在计划里/不在计划里|理由"
# ---------------------------------------------------------------------------
slot_scan_report() {
  local role name lang label plan why base_l
  local base="${1:-}" scope="${2:-all}" kl="${3:-0}" ks="${4:-0}"
  # ★★ 1.0.9.2 第三次提速（真机实测这一节 253 秒 → 目标几秒）：
  #   原因：这一节对**每个**"不替换"的字体都调一次 `slot_why`，而 slot_why 里又有
  #   `$(...)` 形式的子进程（_slot_script / _scan_script_of 各一次）。
  #   作者机器上配置引用 279 个字体 → **500 多个进程**，每个进程在手机上要排队几十毫秒
  #   —— 累起来就是 250 秒。
  #   现在：**整节不起任何子进程**：判定和理由全部用纯 shell 的 case 完成。
  #
  # ① 计划表（一次建好）
  if [ -z "${PLAN_NAME_MAP+x}" ]; then
    PLAN_NAME_MAP=$(printf '%s\n' "$base" | while IFS= read -r _pl; do
      [ -n "$_pl" ] || continue
      _pn=${_pl##*/}
      [ -n "$_pn" ] && printf '|%s|' "$_pn"
    done)
  fi
  # ② 脚本表（文件 → 文字体系），一次建好，查询纯匹配
  if [ -z "${SCAN_SCRIPT_MAP+x}" ]; then
    printf '%s\n' "$SCAN_NAMES_CACHE" | while IFS=' ' read -r _sr _sn _sl; do
      [ -n "$_sn" ] || continue
      case "$_sr:$_sl" in
        cjk:*)             _ss=cjk ;;
        kana:*)            _ss=kana ;;
        hangul:*)          _ss=hangul ;;
        lang:*zh-hant*|lang:*zh-bopo*|lang:*zh-hk*|lang:*zh-tw*|lang:*zh-mo*) _ss=hant ;;
        lang:*)            _ss=lang ;;
        *)                 _ss="" ;;
      esac
      [ -n "$_ss" ] && printf '|%s=%s' "$_sn" "$_ss"
    done > "${TMPD:-/data/local/tmp}/.scanmap.$$" 2>/dev/null
    SCAN_SCRIPT_MAP=$(cat "${TMPD:-/data/local/tmp}/.scanmap.$$" 2>/dev/null)
    rm -f "${TMPD:-/data/local/tmp}/.scanmap.$$" 2>/dev/null
  fi
  printf '%s\n' "$SCAN_NAMES_CACHE" | while IFS=' ' read -r role name lang; do
    [ -n "$name" ] || continue
    case "$lang" in
      zh-hans|zh-hans-cn) label="中文（简体）" ;;
      zh-hant|zh-hant-tw|zh-hant-hk|zh-bopo) label="中文（繁体）" ;;
      ja)   label="日文" ;;
      ko)   label="韩文" ;;
      und|"") label="通用（无语言）" ;;
      *)    label="$lang" ;;
    esac
    # 在不在计划里：两次短模式匹配（纯 shell，零进程）
    case "$PLAN_NAME_MAP" in
      *"|$name|"*) _inplan=1 ;;
      *)           _inplan=0 ;;
    esac
    if [ "$_inplan" = 1 ]; then
      plan="✅ 会替换" ; why="—"
    else
      plan="❌ 不替换"
      # ---- 以下替代 slot_why：全部纯 shell，零子进程 ----
      # 先看角色放不放行
      _rw=1
      case "$role" in
        sym|vadj) _rw=0 ;;                              # 符号/emoji、"粗细调节"族：刻意不动
        ttc|lang) [ "$scope" = all ] || _rw=0 ;;
      esac
      case "$scope" in
        latin) case "$role" in latin|italic|serif|mono|clock|display) ;; *) _rw=0 ;; esac ;;
        cjk)   [ "$role" = cjk ] || _rw=0 ;;
      esac
      if [ "$_rw" = 0 ]; then
        case "$role" in
          sym)   why="刻意不动：符号/表情字体换了会显示异常" ;;
          vadj)  why="刻意不动：这个族开了「粗细调节」，换掉会让系统界面的粗细滑块出问题" ;;
          vadj)  why="刻意不动：这个族开了「粗细调节」，换掉会让系统界面的粗细滑块出问题" ;;
          ttc)   why="被保留：替换范围不是 all（合集槽只在全替换时参与）" ;;
          lang)  why="被保留：这个角色只在「全替换」时参与" ;;
          *)     why="被保留：不在本次替换范围（范围=$scope）" ;;
        esac
      else
        # 角色放行了却不在计划里 → 看它的文字体系，给出原因
        _ss=""
        case "$SCAN_SCRIPT_MAP" in
          *"|$name="*) _ss=${SCAN_SCRIPT_MAP#*"|$name="}; _ss=${_ss%%|*} ;;
        esac
        case "$_ss" in
          kana|hangul|hant|cjk) why="不在计划里（脚本=$_ss，可能是该字体没被模板覆盖到最后一步" ;;
          "")                   why="不在计划里（角色放行了，但计划里没有它 —— 请把这份报告发给作者）" ;;
          *)                    why="不在计划里（脚本=$_ss）" ;;
        esac
      fi
    fi
    printf '%-9s %-13s %-40s %-9s %s\n' "$lang" "$label" "$name" "$plan" "$why"
  done | sort -u
}

# ---------------------------------------------------------------------------
# 【1.0.9 新增】自适应补齐：只用**确定性信息**补，不做任何猜测
#
# 判定分两层：
#   ① 角色层（cjk / kana / hangul / hant）：模板一路完全没覆盖到才补。
#      补进来的是"设备自己的配置里、带对应语言标签的字体文件"。
#   ② 脚本层（同一个槽位由几个脚本共用时的去重）：也用配置里的语言标签，
#      而不是文件名 —— 这样 SysSans-Hans-Regular.ttf 这种"名字看不出来"的中文槽位
#      也能被正确识别。
#
# 保守原则：**只补空缺，绝不动模板已经管到的角色**。
#   模板命中的那些是"这个机型真正的主字体"，优先级高于"配置里引用到的一切"；
#   无脑全加会把装饰字体、地区专用字体一起换掉 —— 那不是自适应，是乱来。
#
# ★★★ 2026-10-14 修一个"静默失效"的严重 bug ★★★
#
#   1.0.9.2 那次性能优化把它改成了：
#       scan="$base"        # base = 调用方刚算好的 slot_candidates 输出
#   意图是"别把同一件重活干两遍"。但 **base 里根本没有扫描结果** ——
#   `slot_candidates` 只汇总 XML 引用 + targets 清单 + OEM 命名规则三路，
#   **从来不调用 `slot_scan_candidates`**。于是下面那句
#       printf '%s\n' "$scan" | grep "^$role "
#   变成"从 base 里挑出 base 里已经有的东西" —— **整段自适应等于被关掉了**。
#
#   实测（合成一个"没适配过"的 ROM：配置里只有 lang="ko"/"ja"/"zh-Hans" 三个族）：
#       候选(base)      = main + cjk
#       扫描(scan)      = main + cjk + hangul + kana      ← 韩文/日文在这里
#       自适应补出来的   = **空**                          ← 修之前
#       最终计划         = main + cjk                      ← 韩文/日文永远不换
#
#   代价很隐蔽：**只有"没主动适配过的机型"才会踩到**，而那些机型恰好最需要自适应，
#   而且报告里看不出来（报告第 0 节只会说"模板已覆盖本机需要的角色"）。
#
#   所以这里必须**真的去扫描**。性能上仍保留"一次算好、下面复用"的做法：
#   `slot_scan_names` / `slot_dirs` 都有进程内缓存，重复调用不再重新解析配置。
#
# ★★★ 2026-10-14 第二处修：补的时候**必须再校验语言标签**，不能只看角色名 ★★★
#
#   修好上面那个 bug 之后，三星真机上立刻暴露了第二个坑：
#       hangul /system/fonts NotoSansNKo-Regular.ttf        ← NKo 是西非文字！
#       kana   /system/fonts NotoSansJavanese-Regular.otf   ← 爪哇文！
#   原因在 `slot_scan_names` 的角色判定：`*ko*` 会命中 `NKo`（`lang="und-Nkoo"`），
#   于是 NKo 被判成 hangul；`lang="und-Java"` 之类也会掉进 kana。
#   这些字体**本来就不该被换**，真换上去那几个文字就变方块了。
#
#   所以这里对每个角色**再核一遍它的文字体系**：
#       hangul → 必须真的是 ko        kana → 必须真的是 ja
#   `lang` / `hant` 两种不用额外卡：`_xml_family_ok` 已经把它们限死在 zh* 上了。
#
#   ★ 用什么核：`_scan_script_of <文件名>` —— 它就是"从扫描缓存里查这个文件的文字体系"，
#     读的是**配置里的 lang 标签**（权威），而不是文件名。别自己再解析一遍。
#     注意 `slot_scan_candidates` 的输出是 **3 字段**（角色 目录 文件名）——
#     它**不带语言标签**，所以语言必须另查（第一版就是误以为它带，白折腾了三轮）。
# ---------------------------------------------------------------------------
_adaptive_role_ok() {   # $1=角色 $2=文件名
  local ss
  case "$1" in
    # 只有这两个需要额外核：短语言码容易撞车
    #   lang="und-Nkoo"（西非 NKo）被 *ko* 命中 → 判成 hangul
    #   lang="und-Java"（爪哇文）等被 *ja* 命中 → 判成 kana
    # `_scan_script_of` 返回的是**文字体系** cjk/kana/hangul/hant/lang，
    # 所以这里就是"scan 给的体系必须和角色一致"。
    hangul) [ "$(_scan_script_of "$2")" = hangul ] && return 0; return 1 ;;
    kana)   [ "$(_scan_script_of "$2")" = kana ]   && return 0; return 1 ;;
    *)      return 0 ;;
  esac
}
# ---------------------------------------------------------------------------
# 自适应补齐（只补空缺角色，绝不动模板已覆盖的）
#
# 设计（作者 2026-10-14 定的理念，实现必须严格照这个来）：
#   **自适应 = 扫一遍设备自己的配置 − targets 已知的 = 剩下的就是没适配的 → 模块兜住。**
#   所以就算没主动适配过，别人也能用；报告收多了再把剩下的手工补进 targets。
#
# 保守原则：**只补空缺角色**（cjk / kana / hangul / lang / hant 里，模板一个都没覆盖到的）。
#   模板命中的那些是"这个机型真正的主字体"，优先级高于"配置里引用到的一切"。
#
# ★★ 2026-10-14 修两个"静默失效"的 bug（详见 文档\跨项目同步表.md 16.11.7）★★
#
#   ① 1.0.9.2 那次"提速"把 `scan=$(slot_scan_candidates)` 改成了 `scan="$base"`。
#      但 `slot_candidates` **不含扫描结果**（它只汇总 XML 引用 + targets 清单 + OEM 命名），
#      于是下面的角色 grep 变成"从 base 里挑 base 里已经有的" → **整段自适应等于被关闭**。
#      只有"没主动适配过的机型"会踩到 —— 恰好是最需要它的那些。
#      这里必须**真的去扫描**。
#
#   ② 扫描出来的行是按**配置的 lang** 定的角色，而 `slot_scan_names` 原来用 `*ko*`/`*ja*`
#      **子串**判日韩 → `lang="und-Nkoo"`（西非 NKo）含 "ko"、`lang="und-Java"` 含 "ja"，
#      被当成韩文/日文补进来 → **那两种文字会被换成用户字体、变方块**。
#      已在 `slot_scan_names` 里改用 `_lang_is`（完整语言标签）判掉，这里不再需要额外核验。
#
# ⚠️ 性能：本函数在**自愈路径**上（`payload_mount` → `fontctl.sh apply` → `slot_plan` → 这里），
#    自愈有 `_to_s 20` 的 20 秒上限。所以：
#      · `slot_scan_candidates` 有进程内缓存（`SCAN_CANDS_CACHE`），不会被算两遍；
#      · 下面那个 while **必须用 here-doc 而不是管道** —— 管道会让它跑在子 shell 里，
#        `ADAPT_HANGUL` 的赋值传不出来（表现是"名单永远为空"，又静默失效）。
# ---------------------------------------------------------------------------
slot_adaptive_extra() {
  local base="$1" scan c_cjk c_kana c_hangul c_lang c_hant _r _d _nm _lg
  CANDS_TMP="$base"
  scan=$(slot_scan_candidates)
  [ -n "$scan" ] || return 0

  # 角色计数只算 5 次（原来是每行算一次 = 每行起一个子 shell，把自愈的 20 秒吃光）
  c_cjk=$(_role_count cjk);      c_kana=$(_role_count kana)
  c_hangul=$(_role_count hangul); c_lang=$(_role_count lang); c_hant=$(_role_count hant)

  printf '%s\n' "$scan" | while IFS=' ' read -r _r _d _nm; do
    [ -n "$_r" ] && [ -n "$_nm" ] || continue
    case "$_r" in
      cjk)    n=$c_cjk ;;
      kana)   n=$c_kana ;;
      hangul) n=$c_hangul ;;
      lang)   n=$c_lang ;;
      hant)   n=$c_hant ;;
      *)      continue ;;
    esac
    [ "$n" -gt 0 ] && continue          # 这个角色模板已经管到了 → 不补
    printf '%s %s %s\n' "$_r" "$_d" "$_nm"
  done | sort -u
}

# ---------------------------------------------------------------------------
# 候选枚举：输出 "角色 目录 文件名"（目录为真实路径），仅限设备上真实存在的文件
# 整份名单只转一次小写、成对读取，避免为每个文件名单独启动外部进程

# ---------------------------------------------------------------------------
# ★ 2026-10-15：通用候选层 —— **目录里有、配置没提的字体文件名**
#
#   为什么加：真机反馈「部分应用内字体不生效」，而另一个模块（犬神志-台北正黑）
#   能解决 —— 它的做法是**手塞 34 个"配置里没引用"的字体文件**
#   （RobotoFake-*、MiSans*VF、GoogleSans-*Italic 等，其中 25 个我们的清单里没有）。
#   换句话说：有些 App 是**按固定文件名**取字体，那名字不在 ROM 配置里，
#   我们的候选（配置 + 写死的清单 + 厂商正则）就看不见它 → 漏掉。
#
#   这一层把"目录里实际存在的字体文件"也纳进来 —— **不需要知道 ROM 是哪个**，
#   所以它是通用的：换台机器、换个 ROM，缺哪个名字都自动覆盖。
#
#   安全性由下游保证：角色判定还是走 `_role_set` + `_role_wanted`，
#   emoji/符号/等宽/锁屏/衬线这些**本来就不会被替换**（规则早就在那儿了）。
# ---------------------------------------------------------------------------
# ★ 2026-10-17 提速：给 slot_dir_names（字体目录）加**持久缓存**。
#   它只跟 字体目录 本身有关，切开关完全不影响结果，
#   但原来每次 apply/reapply 都要重算一遍（约 1 秒）。
#   key 取相关文件的 mtime+size，变了自动失效；扫到空不缓存（防开机早期锁死）。
slot_dir_names() {
  local _kc="" _kd
  # 一次 stat 拿全部目录的 mtime（原来每个目录一次 = 13 个进程）
  _kdl=""
  for _kf in /system/fonts /system_ext/fonts /product/fonts /vendor/fonts /odm/fonts /oem/fonts /mi_ext/fonts /my_product/fonts /my_heytap/fonts /hw_product/fonts /prism/fonts /optics/fonts /oplus_product/fonts; do
    [ -d "${FSROOT:-}$_kf" ] && _kdl="$_kdl ${FSROOT:-}$_kf"
  done
  local _ver
  # ★ 2026-10-17 修：key 里必须带**脚本版本**（slots.sh 的 mtime）。
  #   否则升级模块后，会命中旧逻辑算出来的缓存 —— 用户实测就踩到了：
  #   候选语义从"按开关过滤"改成"固定全读"，但缓存没失效，
  #   于是装新包后槽位从 78 变成 46（少了 [clock] 那批）。
  _ver="$(stat -c '%Y' "${MODDIR:-}/slots.sh" 2>/dev/null)"
  [ -n "$_kdl" ] && _kc="$_ver|$(stat -c '%n:%Y' $_kdl 2>/dev/null | tr '\n' '|')"
  _kd="${LIB}/.dirnames.cache"
  if [ -n "$_kc" ] && [ -s "$_kd" ]; then
    if [ "$(sed -n '1p' "$_kd" 2>/dev/null)" = "$_kc" ]; then
      sed -n '2,$p' "$_kd" 2>/dev/null
      return 0
    fi
  fi
  local _out
  _out=$(slot_dir_names_raw)
  if [ -n "$_out" ]; then
    if [ -n "$_kc" ]; then
      { printf '%s\n' "$_kc"; printf '%s\n' "$_out"; } > "$_kd.tmp.$$" 2>/dev/null \
        && mv -f "$_kd.tmp.$$" "$_kd" 2>/dev/null
    fi
  fi
  printf '%s\n' "$_out"
}

slot_dir_names_raw() {
  # ★ 2026-10-16 修（作者真机：界面显示"本机目录 0 个"）：
  #   **空结果不许当缓存** —— 这个函数在 customize.sh 很早就会被调用
  #   （detect_rom → _xm_exclusive_font），那一刻分区可能还没就绪，
  #   算出来是空，空缓存就把整场运行锁死了。
  if [ -n "${DIR_NAMES_CACHE+x}" ] && [ -n "$DIR_NAMES_CACHE" ]; then
    printf '%s\n' "$DIR_NAMES_CACHE" | grep -v '^[[:space:]]*$'
    return 0
  fi
  DIR_NAMES_CACHE=$(
    for d in $(slot_dirs); do
      [ -d "$FSROOT$d" ] || continue
      # ★ 只收 Android 的厂商分区路径。
      #   容器/沙箱环境里 slot_dirs 的"未知分区自动发现"会把宿主机的目录
      #   （/Windows/fonts、/Users/... 之类）也列进来 —— 那些不是 Android 槽位。
      #   真机上这条不会命中，但加上它：① 沙箱测试才准 ② 多一道防御。
      case "$d" in
        /system/*|/system_ext/*|/product/*|/vendor/*|/odm/*|/oem/*|/my_*/*|/mi_ext/*|\
        /hw_product/*|/prism/*|/optics/*|/oplus_*/*) ;;
        *) continue ;;
      esac
      # ★ 2026-10-17 提速（实测快 49 倍）：
      #   原来对每个文件跑 `wc -c < "$f"` —— 那会**把文件从头读到尾**，
      #   还要起一个进程。真机上 291 个字体文件 = 291 次完整读盘，就为了拿大小。
      #   现在用 `ls -ln` 一次把整个目录的大小都拿回来，过滤全在 awk 里做：
      #     · -n 强制数字 uid/gid → 字段位置固定（用户名带空格也不会错位）
      #     · 大小是第 5 个字段，文件名是最后一个（可能带空格，所以从尾部取）
      #   判断规则跟原来**一模一样**（大小 <32KB 跳过、按文件名排除特殊字体）。
      ls -ln "$FSROOT$d" 2>/dev/null | awk '
        {
          if ($1 ~ /^d/) next                      # 目录
          if ($1 ~ /^total$/) next                 # 有的 ls 会打 total
          if (NF < 9) next
          sz = $5 + 0
          if (sz < 32768) next                     # 占位/替身小文件 → 跳过
          name = $NF                               # 文件名（最后一段）
          if (name ~ /\*/) next                    # glob 残留
          low = tolower(name)
          if (low !~ /\.(ttf|otf)$/) next
          # \u8ddf _xml_family_ok 保持同一套准入标准
          if (low ~ /sans-serif/ || low ~ /sansserif/) { print name; next }
          if (low ~ /emoji/ || low ~ /symbol/ || low ~ /mono/ || low ~ /cursive/ || \
              low ~ /casual/ || low ~ /math/ || low ~ /music/ || low ~ /clock/ || \
              low ~ /serif/) next
          print name
        }'
      continue
      # ↓ 下面是原来的逐文件版本，已被上面的批量版本取代（保留注释说明，不再执行）
      : <<'OLD_LOOP'
      for f in "$FSROOT$d"/*.ttf "$FSROOT$d"/*.otf "$FSROOT$d"/*.TTF "$FSROOT$d"/*.OTF; do
        :
      done
OLD_LOOP
    done | sort -u
  )
  printf '%s\n' "$DIR_NAMES_CACHE" | grep -v '^[[:space:]]*$'
}
# ★ 2026-10-17（作者要求）：**不再给 slot_candidates 套缓存层**。
#
#   原来这层缓存的 key 里带 boot_id —— 重启后必然失效，等于每次开机第一次
#   都要重算一遍，行为还难以预料（用户的原话："缓存在重启之后根本保留不住，
#   我只相信本地存储"）。
#
#   而现在真正的"本地存储"是安装时扫出来的 $LIB/scanned/slots.list，
#   读它本身就只有几毫秒 —— 中间再套一层缓存纯属多余。
slot_candidates() {
  slot_candidates_raw "$@"
}


slot_candidates_raw() {
  # $2/$3/$4 = keep_lock / keep_lang / keep_special
  # 传给 slot_static_names —— 让 targets 的分区能按开关决定读不读，
  # 这样"切换开关"不需要重新扫描（作者 2026-10-17 定的方向）。
  local moddir="$1" _kl="${2:-0}" _klang="${3:-0}" _kspec="${4:-0}"
  local t name l d dirs
  t="${TMPDIR:-/data/local/tmp}/.cand.$$"
  mkdir -p "${t%/*}" 2>/dev/null
  # ★ 第四层：目录里实际存在的字体文件名（通用，不依赖 ROM 清单）
  #   加在最后，靠 sort -u 去重；角色判定仍在下游统一做
  # ★ 2026-10-16：四路**分别**落盘并打上来源标记，再合并。
  #   以前是一起管道进 sort -u —— 那一步把"这个名字是从哪来的"丢掉了，
  #   于是界面只能显示一个总数（作者看着"170 多个槽位"不知道为什么）。
  _mj="$t.mark"
  : > "$_mj"
  # ★ 2026-10-17（作者定的架构）：**有设备清单就直接用，什么都不扫**。
  #
  #   作者原话：「扫描是在什么时候，就是安装的时候那一次扫描，
  #             把扫描到的东西全部加进文件里永久保存，除非卸载模块」
  #
  #   清单（$LIB/scanned/slots.list）里的格式是 `role dir name`，
  #   跟本函数的输出格式**完全一致**，所以可以直接原样输出 ——
  #   连角色判定、目录查找都省了。
  #
  #   marks（给界面做来源统计）同时写一份：全部记成 s（机组清单）。
  #
  #   清单不存在时 slot_device_fonts 会现场扫一次并生成，之后就一直是快的。
  local _scandir="${LIB:-/data/adb/custom_font_lib}/scanned"
  local _uselist="$_scandir/slots.list"
  if [ ! -s "$_uselist" ]; then
    slot_build_slots "$moddir" >/dev/null 2>&1
  fi
  if [ -s "$_uselist" ]; then
    awk '$3 != "" { print "s " $3 }' "$_uselist" > "$_mj" 2>/dev/null
    awk 'NF >= 3 && ($3 !~ /\.ttc$/) { print }' "$_uselist" 2>/dev/null
    cp -f "$_mj" "$moddir/.marks.$$" 2>/dev/null
    # .ttc 合集槽位（三星这类机器）仍然要在清单之外单独探一下：
    # 那些是合集、不是单文件，扫描时按名字收进清单没有意义。
    if ttc_enabled; then
      for d in $(slot_dirs); do
        for f in "$FSROOT$d"/*.ttc "$FSROOT$d"/*.TTC; do
          [ -f "$f" ] || continue
          printf 'ttc %s %s\n' "$d" "${f##*/}"
        done
      done
    fi
    rm -f "$_mj" 2>/dev/null
    return 0
  fi
  slot_device_fonts "$moddir" 2>/dev/null | sed 's/^/s /' >> "$_mj"
  TARGETS_ONLY=1
  export TARGETS_ONLY
  # ★ 2026-10-17（性能）：适配过的机型**跳过目录扫描**（最慢的一步）。
    #   判定见 slot_can_skip_scan：有清单 + 清单命中率>50% + scope=all。
    #   跳过后要是发现漏了字体，诊断报告第 5 节仍会全量扫（报告要真相不要速度）。
    # ★ 只信 targets 的模式下，目录扫描**一律跳过**（这是最快的一刀）
    if [ "${TARGETS_ONLY:-0}" = 1 ] || slot_can_skip_scan "$moddir" all; then
      SKIP_DIR_SCAN=1
      export SKIP_DIR_SCAN
    else
      SKIP_DIR_SCAN=0
      export SKIP_DIR_SCAN
      slot_dir_names            | sed 's/^/d /' >> "$_mj"
    fi
  # ★ 按**优先级**去重，不靠字母序：
  #   一个名字可能同时来自配置和目录 —— 谁更"有依据"就记谁
  #   （x 配置 > s 机型清单 > o 厂商规则 > d 目录扫描）。
  #   若用 sort -u -k2,2，字母序 d < o < s < x 会让"目录扫描"永远赢，
  #   把配置的功劳吃掉（真机表现：「系统配置里引用的」显示成 0）。
  awk '
    {
      src = substr($0, 1, 1); nm = substr($0, 3)
      if (nm == "") next
      rank = (src == "x") ? 1 : (src == "s") ? 2 : (src == "o") ? 3 : 4
      if (!(nm in R) || rank < R[nm]) { R[nm] = rank; L[nm] = $0 }
    }
    END { for (nm in L) print L[nm] }
  ' "$_mj" | sort -k2,2 > "$t.marks"
  sed 's/^[xsod] //' "$t.marks" | grep -v '^[[:space:]]*$' | sort -u > "$t"
  tr '[:upper:]' '[:lower:]' < "$t" > "$t.l"
  dirs=$(slot_dirs)
  exec 3< "$t"; exec 4< "$t.l"
  while IFS= read -r name <&3 && IFS= read -r l <&4; do
    case "$l" in *.ttf|*.otf) ;; *) continue ;; esac
    _role_set "$l"
    for d in $dirs; do
      [ -f "$FSROOT$d/$name" ] && printf '%s %s %s\n' "$ROLE" "$d" "$name"
    done
  done
  exec 3<&- 4<&-
  # 标记表留给 slot_plan 统计用（按名字查来源）。
  # ★ 用**固定路径**、不能靠变量传递 —— slot_candidates 是被 $(...) 调用的，
  #   跑在子 shell 里，里面设的变量传不到调用方。
  # ★ 写到模块目录（跟 slots.map 同一个地方）：以前写 /data/local/tmp，
  #   真机上那个文件被系统清掉了，界面就读到陈旧的统计。
  # ★ 且**按进程隔离**（.marks.$$）：slot_candidates 会在好几处被调用
  #   （计划、诊断、扫描…），直接覆盖正式文件会让"标记表"跟"计划"不同源。
  #   只有 slot_plan 在计划生成成功后才把它提交成 slots.marks。
  cp -f "$t.marks" "$moddir/.marks.$$" 2>/dev/null
  rm -f "$t" "$t.l" "$t.marks" "$t.mark" 2>/dev/null

  # .ttc 合集槽位（三星这类机器的中文，见 common.sh 的 ttc_enabled）：
  # 三星简中来自 .ttc 合集，单文件字体顶不了 —— 由 fontctl 把用户的字体包成
  # "同样 face 数"的 TTC 再挂上去（见 ttcwrap.sh）。
  # 默认 auto：三星自动开；其它机器不开（可在界面「替换范围（高级）」里手动打开）。
  if ttc_enabled; then
    for d in $dirs; do
      for f in "$FSROOT$d"/*.ttc "$FSROOT$d"/*.TTC; do
        [ -f "$f" ] || continue
        case "${f##*/}" in *'*') continue ;; esac      # glob 没匹配到会原样留着
        printf 'ttc %s %s\n' "$d" "${f##*/}"
      done
    done
  fi
}


# ---------------------------------------------------------------------------
# 生成槽位计划
# ---------------------------------------------------------------------------
# 主题字体槽位（MIUI / HyperOS / 三星）：
#   小米把"设置 → 显示 → 字体大小和样式"里选的字体放在 /data/system/theme/fonts/，
#   **同名文件优先级高于 /system/fonts** —— 于是那几个名字（MiuiEx-*.ttf、Roboto-*.ttf）
#   永远是主题字体，模块换了系统目录也看不到变化，报告只能让用户"切回默认再重启"。
#   三星是同一个机制，目录不同：/data/overlays/font/（在"设置 → 字体大小和样式"里
#   选了字体包/flipfont 之后，落点就在这里）。
#   这里把这几个也纳入计划：只挑「名字和本次计划里已有槽位完全相同」的，
#   覆盖范围跟用户的选择一致，不多碰主题自带的其他文件。
#   注意：/data 上的文件在"交给管理器挂载"模式下挂不了（魔法挂载只覆盖系统分区），那种模式直接跳过。
#
# ★ 默认**不做**这件事（theme_fonts=0）★ —— 有真机教训：
#   MIUI/HyperOS 把"设置 → 字体样式"里选的字体放在 data/system/theme/fonts，
#   而且**整目录都是一个真实文件 + 一堆符号链接**（实测 18 个文件全指向 Roboto-Regular.ttf）。
#   我们去替换它，就等于把用户在设置里做的选择盖掉：
#     · 用户选「小米兰亭 Pro」是为了用它的**可变字重轴**调粗细 —— 被换成单字重字体后，
#       「字体粗细」直接调不动了（真机反馈："小米兰亭pro 已经字体都不生效了"）
#     · 挂载落在**符号链接**上本身也不可靠（同一台机器上"实际生效"校验会少一个）
#   所以改成可选：界面上的「也替换设置里选的字体」开关，默认关。
# 某个目录里有没有"可变字体"（带 fvar 轴的表）—— 小米那台用于调「字体粗细」的就是它。
# 只看文件头部的表目录（前 4KB），不做全文件扫描：够用且快。
_has_varfont() {
  local d="$1" f
  for f in "$FSROOT$d"/*.ttf "$FSROOT$d"/*.otf "$FSROOT$d"/*.TTF "$FSROOT$d"/*.OTF; do
    [ -f "$f" ] || continue
    case "${f##*/}" in *'*') continue ;; esac
    if head -c 4096 "$f" 2>/dev/null | grep -qa 'fvar'; then return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1.0.8：主题字体目录（"设置里选的那个字体"）要不要一起替换 —— **自动判，不要用户操心**
#
# 为什么删掉那个开关：实测那个开关是"静默空转" —— theme_slots 只挑「名字和系统槽位完全相同」
#   的文件，而各家目录里常常是 flymeFont.ttf、MiuiEx-*.ttf 这类对不上的名字，开关开着也什么都不做，
#   用户还以为"多挂了一个目录"。改成按机型/按事实自动判，判不出来就**不动**（保守）。
#
# 判据（全部来自真机报告，见 跨项目同步表 10.41 / 1.0.8-设计稿 第六节）：
#   flyme    /data/customizecenter/font  → 无条件的"主题字体"，一起换（魅族那台已验证）
#   hyperos  /data/system/theme/fonts    → ★ 先看有没有**可变字体**：
#                                          有 → 那是用户拿来调「字体粗细」的，**不碰**（真机教训）
#                                          没有 → 一起换
#   samsung  /data/overlays/font         → 一起换
#   originos /data/vfonts                → 一起换（VivoFont.ttf 是指向它的符号链接，会挂真身）
#   其它/判不出                            → **不动**
# ---------------------------------------------------------------------------
_theme_auto_ok() {
  local rom d
  rom=$(_rom_cached)
  case "$rom" in
    flyme)
      [ -d "$FSROOT/data/customizecenter/font" ] && return 0
      return 1 ;;
    hyperos)
      # 同 theme_slots：小米可能把主题字体放在 theme_webview 里
      d=/data/system/theme/fonts
      if [ ! -d "$FSROOT$d" ]; then
        d=/data/system/fonts/theme_webview
        [ -d "$FSROOT$d" ] || return 1
      fi
      _has_varfont "$d" && return 1      # 有可变字体 → 尊重用户在设置里调的粗细，不动
      return 0 ;;
    samsung)
      [ -d "$FSROOT/data/overlays/font" ] && return 0
      return 1 ;;
    originos)
      [ -d "$FSROOT/data/vfonts" ] && return 0
      return 1 ;;
  esac
  return 1
}

theme_slots() {
  local base="$1" names d tdir f n real
  # ★ 2026-10-19：**不再因为"元模块挂载"就整体跳过**。
  #   元模块（HybridMount/NoMount…）只覆盖 system/product/vendor/system_ext 这些
  #   能 overlay 的分区；而主题字体在 **/data** 上（魅族 /data/customizecenter/font、
  #   MIUI /data/system/theme/fonts…），元模块管不到 —— 必须由本模块自己物理替换。
  #   原来是 `[ mode = manager ] && return 0`，于是元模块用户"主题商店里选的字体"
  #   永远不变（真机反馈：魅族那台主题字体一点没动，别处都换了）。
  # 1.0.8：不再要用户点开关 —— 按机型**自动判**。三条路：
  #   theme_fonts=1 / 0  ：用户在界面上手动指定过，照办
  #   未设置（默认）      ：自动 —— 见下面 _theme_auto_ok
  # ★ 2026-10-18：支持"强制生成"模式 —— 刷入时预生成「含主题字体」那份清单要用。
  #   否则那一份是在开关关着的时候生成的，theme_slots 直接 return，
  #   生成的清单跟不含主题的一模一样 → 用户点开关看不到任何变化（真机反馈过）。
  case "${CFS_FORCE_THEME:-0}" in
    1) ;;                                   # 强制：不管开关，都扫主题字体
    *)
      case "$(cfg_get theme_fonts auto)" in
        1) ;;
        0) return 0 ;;
        *) _theme_auto_ok || return 0 ;;
      esac
      ;;
  esac
  names=$(printf '%s\n' "$base" | while read -r _r _p; do
            [ -n "$_p" ] || continue
            printf '%s\n' "${_p##*/}"
          done | sort -u)
  [ -n "$names" ] || return 0
  # 各家"在设置里选的字体"落点都看；.ttc 也在内（apply 的合集分支会按目标 face 数合成）
  #   data/system/theme/fonts  MIUI / HyperOS
  #   data/overlays/font       三星
  #   data/vfonts              vivo —— /system/fonts/VivoFont.ttf 就是指向这里的**符号链接**
  #   data/customizecenter/font  魅族 Flyme —— ★ 这一家是**不按名字匹配**的，见下面 datafont_any
  # ★ 2026-10-18（修「主题字体开关没反应」，真机证据）：
  #   作者设备上 /system/fonts/MiSansVF_Overlay.ttf 是指向
  #     /data/system/fonts/theme_webview/Roboto-Regular.ttf
  #   的符号链接 —— 也就是说这台小米机器把"主题里选的字体"放在 theme_webview 里，
  #   而原来只扫下面三个目录，这个目录完全没扫到，
  #   于是开关开了也加不进任何槽位 → 用户看到的就是"开了关了都没反应"。
  for d in data/system/theme/fonts \
           data/system/fonts/theme_webview \
           data/miui/theme/fonts \
           data/system/theme_font \
           data/overlays/font \
           data/vfonts; do
    tdir="$FSROOT/$d"
    [ -d "$tdir" ] || continue
    for f in "$tdir"/*.ttf "$tdir"/*.TTF "$tdir"/*.otf "$tdir"/*.OTF "$tdir"/*.ttc "$tdir"/*.TTC; do
      [ -f "$f" ] || continue
      n=${f##*/}
      case "$n" in *'*') continue ;; esac        # glob 没匹配到会原样留着
      printf '%s\n' "$names" | grep -qxF "$n" || continue
      # 目录里常见"一堆符号链接指向同一个真实文件"（MIUI 实测：18 个文件全指向 Roboto-Regular.ttf）。
      # 这时只替换那个**真实文件** —— 既不去挂符号链接本身（挂上去不可靠，真机上校验都对不上），
      # 也不会把同一份文件挂十几遍（同名的整行会被 slot_plan 去重）。
      real=""
      if command -v readlink >/dev/null 2>&1; then
        real=$(readlink -f "$FSROOT$d/$n" 2>/dev/null)
        case "$real" in [A-Za-z]:/*) real=${real#?:} ;; esac   # 沙箱（Windows）会带盘符前缀
        case "$real" in "$FSROOT"/*) real=${real#"$FSROOT"} ;; esac
        # 注意：FSROOT 在真机上是空的，上面那步不会去掉开头的斜杠 —— 必须单独再剥一次，
        # 否则解析结果永远不等于 "$d/$n"，会把每个普通文件都误判成符号链接（测试抓到过）。
        case "$real" in /*) real=${real#/} ;; esac
        case "$real" in *..*) real="" ;; esac                  # 保守：带 .. 的直接不动
        [ "$real" = "$d/$n" ] && real=""                       # 解析结果就是它自己 = 不是符号链接
      fi
      case "$real" in
        "") printf 'theme %s %s\n' "$d" "$n" ;;                # 普通文件：原样（3 列，跟其它槽位一致）
        */fonts/*)   # 真身在某个字体目录里 → 挂真身\n
          # ★ 必须拆成 3 列：slot_plan 的 awk 只认 "role dir name"。
          #   原来输出 2 列（role 完整路径），会被 NF>=3 直接跳过 —— 主题槽位全丢。\n
          printf 'theme %s %s\n' "${real%/*}" "${real##*/}" ;;
        *) : ;;                                               # 真身跑到别处 → 不动它，避免误伤
      esac
    done
  done
  # ---------------------------------------------------------------------------
  # 魅族 Flyme：/data/customizecenter/font/ —— **不按名字匹配**
  #
  # 为什么单独写一段：用户报告里这个文件叫 flymeFont.ttf（18 位十六进制前缀的
  # f1791638786.ttf 那种名字根本对不上），而且系统字体目录里**没有**任何同名槽位，
  # 上面那套"名字要相同"的规则在这里永远不会命中。
  # 真机依据（Redmi M098FE / Flyme 12.6 / Android 16，2026-10-12 报告）：
  #   · 用户在主题商店下了免费主题（设置里 using_font_name=静静字体）→ 这个文件就出现了；
  #   · 同一时刻 /system/fonts 里 FlymeSansVF.ttf、Roboto-Regular.ttf 等 7 个主字体
  #     全都变成**同样大小 17143856 字节 / 同样 mtime** —— 就是这份字体被主题机制铺进去的。
  #   所以这个文件**至少**是"用户选过的字体"的落点，替换它 = 让主题商店/个性字体链路也走用户的字体。
  # ⚠️ 老实说清楚：**它到底会不会盖过 /system/fonts，我们没在真机上验过**
  #   （那份报告里 dumpsys 显示框架读的是 /system/fonts/FlymeSansVF.ttf，配置里也没有指向这里的引用）。
  #   所以这条**只跟着用户手动打开的开关走**，默认关；关着的时候一个字都不碰。
  # ---------------------------------------------------------------------------
  if [ -d "$FSROOT/data/customizecenter/font" ]; then
    for f in "$FSROOT"/data/customizecenter/font/*.ttf  "$FSROOT"/data/customizecenter/font/*.TTF \
             "$FSROOT"/data/customizecenter/font/*.otf  "$FSROOT"/data/customizecenter/font/*.OTF; do
      [ -f "$f" ] || continue
      n=${f##*/}
      case "$n" in *'*') continue ;; esac          # glob 没匹配到会原样留着
      printf 'theme data/customizecenter/font %s\n' "$n"
    done
  fi

  # ---------------------------------------------------------------------------
  # 各家"设置里选的字体"的其他落点（受「也替换主题里选的字体」开关控制）
  #
  #   data/format_unclear/font   ColorOS/OPPO 的字体桥接目录
  #   data/oplus/uxres/theme     ColorOS 主题资源
  #   data/bbkcore/theme         vivo/BBK 核心主题
  #   data/skin/fonts            vivo 皮肤字体
  #   data/theme/fonts          通用主题字体
  #   data/themes               通用主题根
  #
  # 刻意**不含**：
  #   data/system/theme_magic/fonts  荣耀 MagicOS —— 主字体被替换后可能与
  #        「字体和图标粗细」冲突导致 SystemUI 异常，只探测不替换
  #   data/fonts/**                  AOSP 可更新字体 —— 属于谷歌字体链路，另一套处理
  #
  # ⚠️ 只处理**普通文件**，符号链接跳过：
  #    链接指向 /system/fonts/X 的，我们替换 X 时已经覆盖；
  #    去替换链接会把链接变成实体文件，永久改变厂商语义（备份也会被污染成实体内容）。
  # ---------------------------------------------------------------------------
  # ⚠️ 这 6 家**只认显式开关**（theme_fonts=1），或安装时预生成清单（CFS_FORCE_THEME=1）：
  #    auto 模式按机型自动判，只覆盖原有那几家（MIUI / 三星 / vivo vfonts / 魅族）——
  #    不能让新目录跟着 auto 一起自动生效，否则等于没经用户同意就去动 /data 里的文件。
  case "${CFS_FORCE_THEME:-0}:$(cfg_get theme_fonts 0)" in
    1:*|*:1) ;;
    *) return 0 ;;
  esac
  for d in data/format_unclear/font data/oplus/uxres/theme data/bbkcore/theme \
           data/skin/fonts data/theme/fonts data/themes; do
    tdir="$FSROOT/$d"
    [ -d "$tdir" ] || continue
    for f in "$tdir"/*.ttf "$tdir"/*.TTF "$tdir"/*.otf "$tdir"/*.OTF "$tdir"/*.ttc "$tdir"/*.TTC; do
      [ -f "$f" ] || continue
      [ -L "$f" ] && continue          # 链接：系统字体已覆盖，别动链接本身
      n=${f##*/}
      case "$n" in *'*') continue ;; esac
      printf 'theme %s %s\n' "$d" "$n"
    done
  done
}

# 生成计划到 stdout（每行 "角色 相对路径"）
#
# ★ 2026-10-17（作者：前提准备，后续完全无脑）：
#   刷入时已经把 4 种开关组合的槽位清单都生成好了：
#       slots.list            kl=0 th=0
#       slots.kl1.list        kl=1 th=0
#       slots.th1.list        kl=0 th=1
#       slots.kl1th1.list     kl=1 th=1
#   所以这里**不做任何过滤**，按开关直接选文件即可。
#   唯一还要算的是 scope（all/latin/cjk）—— 它来自字体自己的 meta，
#   跟着导入的字体变，没法预生成，用一次 awk 处理。
slot_plan() {   # $1=moddir $2=scope $3=keep_lang $4=keep_special $5=keep_lock
  local moddir="$1" scope="${2:-all}" keep_lang="${3:-0}" keep_special="${4:-0}" keep_lock="${5:-0}"
  local _sd="${LIB:-/data/adb/custom_font_lib}/scanned"
  local _srclist _th

  # theme_fonts 决定用不用"带主题字体"的那一份
  case "$(cfg_get theme_fonts 0 2>/dev/null)" in
    1) _th=1 ;;
    *) _th=0 ;;
  esac

  # 按开关选文件（选不到就退回全量那份）
  if [ "$keep_lock" = 1 ]; then
    [ "$_th" = 1 ] && _srclist="$_sd/slots.kl1th1.list" || _srclist="$_sd/slots.kl1.list"
  else
    [ "$_th" = 1 ] && _srclist="$_sd/slots.th1.list" || _srclist="$_sd/slots.list"
  fi
  [ -s "$_srclist" ] || _srclist="$_sd/slots.list"
  if [ ! -s "$_srclist" ]; then
    # 清单不存在（老用户第一次升级）→ 现场建一次
    slot_build_slots "$moddir" >/dev/null 2>&1
    [ -s "$_srclist" ] || _srclist="$_sd/slots.list"
  fi
  [ -s "$_srclist" ] || return 0

  # marks（来源统计用）：全部记成 s（机组清单）
  awk '$3 != "" { print "s " $3 }' "$_srclist" > "$moddir/.marks.$$" 2>/dev/null

  # scope 过滤（唯一还需要算的一步）+ 按目标路径去重
  awk -v scope="$scope" '
    NF >= 3 {
      role = $1; dir = $2; name = $3
      if (role == "" || name == "") next
      if (role == "sym" || role == "vadj") next
      if (scope == "latin" && (role == "cjk" || role == "kana" || role == "hangul" || role == "hant")) next
      if (scope == "cjk" && role != "cjk") next
      dd = (substr(dir, 1, 1) == "/") ? substr(dir, 2) : dir
      line = role " " dd "/" name
      if (!(line in seen)) { seen[line] = 1; print line }
    }' "$_srclist" 2>/dev/null

  # ★ 2026-10-19 修（真机 SM-S9380：中文一直是系统原字体）：**合集槽位要在这里补上**。
  #   2026-10-17 把"生成计划"改成只读预扫清单（scanned/slots.list）之后，.ttc 合集就漏了：
  #   清单里只有单文件字体（扫描按文件名收，合集不在其中），
  #   而合集槽位原来是在 slot_candidates 里现探的 —— 那个函数现在只给诊断报告用。
  #   后果：三星这类「中文只从合集里取」的机器，计划里一个合集都没有，
  #   于是 ttc.log 只有表头、字体库里没有任何合成文件、中文永远是系统原字体。
  #   （诊断报告第 4 节仍然会列出 ttc 候选，所以看报告很容易以为"模块认识到了"。）
  case "$scope" in
    latin) : ;;          # 只替换拉丁 → 不碰合集
    *)
      # 字体自己没有中文字形时绝对不能碰合集 —— 否则把中文换成本字体 = 满屏方块，
      # 用户连 WebUI 都看不清、没法换回来（CJK_GUARD 由 make_plan 设好并导出）。
      if [ "${CJK_GUARD:-0}" != "1" ] && ttc_enabled; then
        for d in $(slot_dirs); do
          for f in "$FSROOT$d"/*.ttc "$FSROOT$d"/*.TTC; do
            [ -f "$f" ] || continue
            case "${f##*/}" in *'*') continue ;; esac      # glob 没匹配到会原样留着
            # 清单里已经有同名文件（极少数机型会重复）→ 不再重复加
            if awk -v n="${f##*/}" '$3 == n { found = 1 } END { exit !found }' \
                 "$_srclist" 2>/dev/null; then
              continue
            fi
            printf 'ttc %s/%s\n' "${d#/}" "${f##*/}"
          done
        done
      fi
      ;;
  esac
  return 0
}



# 诊断：按角色统计设备上"候选且存在"的槽位数量
slot_report() {
  local moddir="$1" role d name
  local c_latin=0 c_cjk=0 c_main=0 c_lang=0 c_sym=0 c_italic=0 c_serif=0 c_mono=0 c_clock=0 c_display=0 c_ttc=0
  local tmp="${TMPDIR:-/data/local/tmp}/.slotrep.$$"
  mkdir -p "${tmp%/*}" 2>/dev/null
  # 诊断要的是**全量**（不管开关），所以三个开关都传 0
  slot_candidates "$moddir" 0 0 0 > "$tmp"
  while read -r role d name; do
    case "$role" in
      latin) c_latin=$((c_latin+1)) ;; cjk) c_cjk=$((c_cjk+1)) ;; main) c_main=$((c_main+1)) ;;
      lang) c_lang=$((c_lang+1)) ;; sym) c_sym=$((c_sym+1)) ;; italic) c_italic=$((c_italic+1)) ;;
      serif) c_serif=$((c_serif+1)) ;; mono) c_mono=$((c_mono+1)) ;; clock) c_clock=$((c_clock+1)) ;;
      display) c_display=$((c_display+1)) ;; ttc) c_ttc=$((c_ttc+1)) ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  echo "latin=$c_latin cjk=$c_cjk main=$c_main ttc=$c_ttc | 保留：lang=$c_lang sym=$c_sym italic=$c_italic serif=$c_serif mono=$c_mono clock=$c_clock display=$c_display"
}


slot_sources_report() {
  # ★ 2026-10-17（新架构）：来源统计直接从安装时生成的 scanned/slots.meta 读。
  #   语义：
  #     x = 机型清单（targets）独有的（扫描没覆盖的）
  #     s = 本机扫描补的（targets 没覆盖、这台设备特有的）
  #     T = 总槽位
  #   targets 里的名字通常也会出现在扫描结果里，所以 x 往往是 0 —— 这是正常的。
  local _sd="${LIB:-/data/adb/custom_font_lib}/scanned"
  local _mt="$_sd/slots.meta"
  local t=0 n=0
  [ -s "$_mt" ] && t=$(sed -n 's/^targets=//p' "$_mt" 2>/dev/null)
  [ -s "$_mt" ] && n=$(sed -n 's/^total=//p' "$_mt" 2>/dev/null)
  case "${t:-0}" in ''|*[!0-9]*) t=0 ;; esac
  case "${n:-0}" in ''|*[!0-9]*) n=0 ;; esac
  local _s=$(( n - t ))
  [ "$_s" -lt 0 ] && _s=0
  printf 'T=%s\n' "$n"
  printf 'x=%s\n' "$t"
  printf 's=%s\n' "$_s"
  printf 'o=0\n'
  printf 'd=0\n'
  printf 'u=0\n'
}



# ---------------------------------------------------------------------------
# ★ 2026-10-17：「模块额外补的」这个数字怎么算
#
#   slot_sources_report 给的 x/s/o/d 是**优先级去重后**的归属
#   （x 配置 > s 清单 > o 厂商 > d 目录）。真机上目录扫描扫到 215 个名字，
#   其中 212 个配置也提到了 → 全被配置赢走 → d 显示 0。
#   但"扫描真正多补了几个"是用户关心的，显示 0 会以为扫描坏了。
#
#   ⚠️ 为什么这里**自己直接扫目录**、不调 slot_dir_names / slot_dirs：
#     那两个函数有进程内缓存，而本函数可能在更早的时机被调用过
#     （拿到空结果）→ 跟着显示 0（真机踩过）。
#     自己扫的判据跟扫描层保持一致（>32KB + 排除符号/等宽/时钟/衬线）。
#
#   输出：
#     extra   = 目录里存在、而配置/清单/厂商都没提到的名字数（扫描的净贡献）
#     symskip = 目录里存在、但因符号/emoji 规则刻意不换的名字数
# ---------------------------------------------------------------------------
slot_extra_report() {
  local moddir="${1:-${MODDIR:-}}" xf df n_extra n_sym d f b bl sz
  # ★ 2026-10-17 提速：**加重结果缓存**。
  #   这个函数每次进界面都会被 status 调用（界面要显示"模块额外补了 N 个"），
  #   而它要扫十几个字体目录才能算出来 —— 界面每次刷新都白扫一遍。
  #   结果只在三种情况下会变：换开机 / 槽位计划变 / 字体目录里的文件变，
  #   所以拿这三样当 key，命中就直接读缓存（跟 payload_verify 同一套思路）。
  local _ck _cnow
  local _ver
  # ★ 2026-10-17 修：key 里必须带**脚本版本**（slots.sh 的 mtime）。
  #   否则升级模块后，会命中旧逻辑算出来的缓存 —— 用户实测就踩到了：
  #   候选语义从"按开关过滤"改成"固定全读"，但缓存没失效，
  #   于是装新包后槽位从 78 变成 46（少了 [clock] 那批）。
  _ver="$(stat -c '%Y' "${MODDIR:-}/slots.sh" 2>/dev/null)"
  _cnow="$_ver|$(boot_id 2>/dev/null)"
  _cnow="$_cnow|$(stat -c '%Y-%s' "$moddir/slots.map" 2>/dev/null)"
  for _d in /system/fonts /system_ext/fonts /product/fonts /vendor/fonts /odm/fonts \
            /oem/fonts /mi_ext/fonts /my_product/fonts /my_heytap/fonts \
            /hw_product/fonts /prism/fonts /optics/fonts /oplus_product/fonts; do
    [ -d "${FSROOT:-}$_d" ] && _cnow="$_cnow|$_d:$(stat -c '%Y-%s' "${FSROOT:-}$_d" 2>/dev/null)"
  done
  if [ -s "$LIB/.extra.cache" ]; then
    if [ "$(sed -n '1p' "$LIB/.extra.cache" 2>/dev/null)" = "$_cnow" ]; then
      # 第 1 行是 key，第 2 行起才是结果（两行：extra=… / symskip=…）
      # ⚠️ 必须原样输出两行 —— 跟不走缓存时格式完全一致。
      sed -n '2,$p' "$LIB/.extra.cache" 2>/dev/null
      return 0
    fi
  fi

  xf="${TMPDIR:-/data/local/tmp}/.xr.$$"
  df="${TMPDIR:-/data/local/tmp}/.dr.$$"
  : > "$xf"; : > "$df"

  slot_xml_names 2>/dev/null | grep -v '^[[:space:]]*$' | sort -u > "$xf"
  if [ -n "$moddir" ]; then
    slot_static_names "$moddir" 2>/dev/null | grep -v '^[[:space:]]*$' >> "$xf"
    slot_oem_names "$moddir" 2>/dev/null | grep -v '^[[:space:]]*$' >> "$xf"
  fi
  sort -u -o "$xf" "$xf"

  n_sym=0
  # ★ 2026-10-17 提速（进 UI 读状态的主要开销就在这）：
  #   这段跟 slot_dir_names 是**两份独立代码**，之前只优化了那边。
  #   原来是每个文件 `wc -c` —— 把整个字体文件读一遍来量大小，
  #   291 个字体文件就是 291 次完整读盘，而界面每次刷新都会走到这里。
  #   现在用 `ls -ln` 一次把目录里所有文件的大小拿回来（只读元数据）。
  #   判断规则一个字没改：小文件跳过、emoji/符号计数、mono/serif 等排除。
  for d in /system/fonts /system_ext/fonts /product/fonts /vendor/fonts \
           /odm/fonts /oem/fonts /mi_ext/fonts /my_product/fonts /my_heytap/fonts \
           /hw_product/fonts /prism/fonts /optics/fonts /oplus_product/fonts; do
    [ -d "$FSROOT$d" ] || continue
    ls -ln "$FSROOT$d" 2>/dev/null | awk -v df="$df" -v sym="$LIB/.symcnt.$$" '
      {
        if ($1 ~ /^d/) next
        if ($1 ~ /^total$/) next
        if (NF < 9) next
        sz = $5 + 0
        if (sz < 32768) next
        name = $NF
        if (name ~ /\*/) next
        low = tolower(name)
        if (low !~ /\.(ttf|otf)$/) next
        if (low ~ /sans-serif/ || low ~ /sansserif/) { print name >> df; next }
        if (low ~ /emoji/ || low ~ /symbol/ || low ~ /dingbat/ || low ~ /braille/) {
          print 1 >> sym; next
        }
        if (low ~ /mono/ || low ~ /cursive/ || low ~ /casual/ || low ~ /math/ || \
            low ~ /music/ || low ~ /clock/ || low ~ /serif/) next
        print name >> df
      }'
    if [ -s "${LIB}/.symcnt.$$" ]; then
      # symskip 是"计数"不是"名字"，awk 里写成一行一个 1，这里数行数加进总数
      _add=$(wc -l < "${LIB}/.symcnt.$$" 2>/dev/null | tr -d ' ')
      n_sym=$(( n_sym + ${_add:-0} ))
      rm -f "${LIB}/.symcnt.$$" 2>/dev/null
    fi
  done
  sort -u -o "$df" "$df"

  n_extra=$(grep -Fxvf "$xf" "$df" 2>/dev/null | grep -c .)
  _scanned=$(wc -l < "$df" 2>/dev/null | tr -d ' ')

  rm -f "$xf" "$df" 2>/dev/null
  # 写缓存（第一行 key、后面是结果）
  # ★ 2026-10-17 防呆：这个函数在开机很早（post-fs-data）也会被调用，那一刻
  #   字体目录可能还没挂载好 → 扫出来是 0。如果把这个 0 缓存下来，
  #   界面之后就会永远显示"额外补 0 个"（跟以前修过的"空缓存锁死"同一类坑）。
  #   判据：扫到的字体数太少（< 10）说明环境没就绪 → 这次不写缓存，下次重算。
  if [ "${_scanned:-0}" -ge 10 ] 2>/dev/null; then
    { printf '%s\n' "$_cnow"
      printf 'extra=%d\nsymskip=%d\n' "${n_extra:-0}" "${n_sym:-0}"
    } > "$LIB/.extra.cache.tmp.$$" 2>/dev/null && \
      mv -f "$LIB/.extra.cache.tmp.$$" "$LIB/.extra.cache" 2>/dev/null
  fi
  printf 'extra=%d\nsymskip=%d\n' "${n_extra:-0}" "${n_sym:-0}"
}
