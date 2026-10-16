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
slot_xml_files() {
  local x
  for x in "$FSROOT"/system/etc/*font*.xml "$FSROOT"/system_ext/etc/*font*.xml \
           "$FSROOT"/product/etc/*font*.xml "$FSROOT"/vendor/etc/*font*.xml \
           "$FSROOT"/odm/etc/*font*.xml "$FSROOT"/*/etc/*font*.xml; do
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
  if [ -z "${TTC_PAIRS_CACHE+x}" ]; then
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
slot_xml_names() {
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
  local moddir="$1" rom list
  rom=$(tr -d '[:space:]' 2>/dev/null < "$moddir/current_rom")
  for list in "$moddir/targets/$rom.list" "$moddir/targets/aosp.list"; do
    [ -f "$list" ] || continue
    grep -v '^#' "$list" | tr -d '\r' | sed 's#.*/##' | grep -v '^[[:space:]]*$'
  done | sort -u
}

# OEM 命名规则：扫描真实目录，匹配厂商主字体命名
slot_oem_names() {
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
      if _lang_is "$lang" ko || { [ -z "$lang" ] && case "$l" in *korean*|*hangul*|*kore[-_.]*) true ;; *) false ;; esac; }; then
        ROLE=hangul; return
      fi
      if _lang_is "$lang" ja || { [ -z "$lang" ] && case "$l" in *japanese*|*kana*|*japan[-_.]*) true ;; *) false ;; esac; }; then
        ROLE=kana; return
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
  local x k=""
  for x in $(slot_xml_files 2>/dev/null); do
    [ -f "$x" ] || continue
    k="$k$x:$(stat -c '%s-%Y' "$x" 2>/dev/null | tr -d ' ')"
  done
  printf '%s' "$k"
}

_lk_load() {   # 命中就 set LOCKSCREEN_CACHE 并返回 0
  local d="$LIB/.scan" f cur
  f="$d/lockscreen.txt"
  [ -s "$f" ] || return 1
  [ -s "$d/lockscreen.key" ] || return 1
  cur=$(_lk_key)
  [ "$cur" = "$(cat "$d/lockscreen.key" 2>/dev/null)" ] || return 1
  LOCKSCREEN_CACHE=$(cat "$f" 2>/dev/null)
  # ⚠️ 必须和函数里那份保持同一种格式：_is_lockscreen 用 `*" $1 "*` 匹配**空格分隔**的串。
  #    第一版我写成管道分隔 `|a|b|` → 格式不一致 → 锁屏字体一个都认不出来。
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

_lk_save() {   # $1=名单内容
  local d="$LIB/.scan"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$d/lockscreen.txt.tmp.$$" 2>/dev/null && \
    mv -f "$d/lockscreen.txt.tmp.$$" "$d/lockscreen.txt" 2>/dev/null
  _lk_key > "$d/lockscreen.key.tmp.$$" 2>/dev/null && \
    mv -f "$d/lockscreen.key.tmp.$$" "$d/lockscreen.key" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
_LOCK_FAM_RE='clock|lock|keyguard|watch'
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
  [ -n "${_LOCK_LIST_SPACED+x}" ] || slot_lockscreen_files >/dev/null 2>&1
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
  if [ "$keep_lock" = 1 ] && _is_lockscreen "$name"; then
    return 1
  fi
  case "$role" in
    # ttc = .ttc 合集槽位（三星简中这类）。合集里同时装着 ja/ko/zh 好几套字形，
    # 只有用户选的是"中英文/全覆盖"字体时替换才合理，所以限定 scope=all。
    ttc)
      [ "$scope" = all ] || return 1
      return 0 ;;
    sym) return 1 ;;
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
  local x k=""
  for x in $(slot_xml_files 2>/dev/null); do
    [ -f "$x" ] || continue
    k="$k$x:$(stat -c '%s-%Y' "$x" 2>/dev/null | tr -d ' ')"
  done
  for x in "$MODDIR"/targets/*.list; do
    [ -f "$x" ] || continue
    k="$k|$x:$(stat -c '%s-%Y' "$x" 2>/dev/null | tr -d ' ')"
  done
  for x in $(slot_dirs 2>/dev/null); do
    [ -d "$x" ] || continue
    k="$k|$x:$(ls "$x" 2>/dev/null | wc -l | tr -d ' ')"
  done
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
    if [ "$ROLE" = sym ]; then continue; fi
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
        sym) _rw=0 ;;                                   # 符号/emoji 刻意不动
        ttc|lang) [ "$scope" = all ] || _rw=0 ;;
      esac
      case "$scope" in
        latin) case "$role" in latin|italic|serif|mono|clock|display) ;; *) _rw=0 ;; esac ;;
        cjk)   [ "$role" = cjk ] || _rw=0 ;;
      esac
      if [ "$_rw" = 0 ]; then
        case "$role" in
          sym)   why="刻意不动：符号/表情字体换了会显示异常" ;;
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
slot_dir_names() {
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
      for f in "$FSROOT$d"/*.ttf "$FSROOT$d"/*.otf "$FSROOT$d"/*.TTF "$FSROOT$d"/*.OTF; do
        [ -f "$f" ] || continue
        b=${f##*/}
        case "$b" in *'*') continue ;; esac          # glob 没匹配到会原样留着
        # ★ 跳过"占位/替身"性质的小文件（犬神志那批 RobotoFake 是 1.7~3.2 KB）：
        #   把用户的大字体挂到那种位置上，可能盖掉 ROM 特意放的兜底字体。
        sz=$(wc -c < "$f" 2>/dev/null | tr -dc '0-9')
        [ -n "$sz" ] || continue
        [ "$sz" -lt 32768 ] && continue
        # ★ 与 `_xml_family_ok` 保持同一套准入标准。
        #   配置驱动那条路会主动排除 emoji/符号/等宽/手写/休闲/数学/音乐/时钟，
        #   以及 **serif（Sans-Serif 除外）**。新层是从目录枚举的，不经过那道判断 ——
        #   这里按文件名补上等价的排除，免得"换条路就多出槽位"。
        #   （weighttest 抓到：夹具里 serif 族的 WT-Serif.ttf 被新层收了，而配置那条路会排除它。）
        bl=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
        case "$bl" in
          *sans-serif*|*sansserif*) ;;                  # Sans-Serif 例外 → 收
          *emoji*|*symbol*|*mono*|*cursive*|*casual*|*math*|*music*|*clock*|*serif*)
            continue ;;                                 # 与配置那条路一致 → 排除
        esac
        printf '%s\n' "$b"
      done
    done | sort -u
  )
  printf '%s\n' "$DIR_NAMES_CACHE" | grep -v '^[[:space:]]*$'
}

# ---------------------------------------------------------------------------
slot_candidates() {
  local moddir="$1" t name l d dirs
  t="${TMPDIR:-/data/local/tmp}/.cand.$$"
  mkdir -p "${t%/*}" 2>/dev/null
  # ★ 第四层：目录里实际存在的字体文件名（通用，不依赖 ROM 清单）
  #   加在最后，靠 sort -u 去重；角色判定仍在下游统一做
  # ★ 2026-10-16：四路**分别**落盘并打上来源标记，再合并。
  #   以前是一起管道进 sort -u —— 那一步把"这个名字是从哪来的"丢掉了，
  #   于是界面只能显示一个总数（作者看着"170 多个槽位"不知道为什么）。
  _mj="$t.mark"
  : > "$_mj"
  slot_xml_names              | sed 's/^/x /' >> "$_mj"
  slot_static_names "$moddir" | sed 's/^/s /' >> "$_mj"
  slot_oem_names "$moddir"    | sed 's/^/o /' >> "$_mj"
  slot_dir_names              | sed 's/^/d /' >> "$_mj"
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
      d=/data/system/theme/fonts
      [ -d "$FSROOT$d" ] || return 1
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
  [ "$(mount_mode 2>/dev/null)" = manager ] && return 0
  # 1.0.8：不再要用户点开关 —— 按机型**自动判**。三条路：
  #   theme_fonts=1 / 0  ：用户在界面上手动指定过，照办
  #   未设置（默认）      ：自动 —— 见下面 _theme_auto_ok
  case "$(cfg_get theme_fonts auto)" in
    1) ;;
    0) return 0 ;;
    *) _theme_auto_ok || return 0 ;;
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
  for d in data/system/theme/fonts data/overlays/font data/vfonts; do
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
        "") printf 'theme %s/%s\n' "$d" "$n" ;;                # 普通文件：原样
        */fonts/*) printf 'theme %s\n' "$real" ;;              # 真身在某个字体目录里 → 挂真身
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
      printf 'theme data/customizecenter/font/%s\n' "$n"
    done
  fi
}

slot_plan() {
  # 1.0.9：默认（也是唯一）口径 = **全替换**。日韩繁体、时钟/斜体/衬线都换，
  #   不再有"保留 XX"开关、也不再按字形自动让路（作者定的：不给开关，省心）。
  #   参数 scope/keep_lang/keep_special 保留只为兼容旧调用方（fontctl / diag）。
  local moddir="$1" scope="${2:-all}" keep_lang="${3:-0}" keep_special="${4:-0}" keep_lock="${5:-0}"
  local role d name base _sp
  # 计划输出文件路径（固定在此，尾部要按大小判断"是否真的产出了计划"）
  _sp="${TMPDIR:-/data/local/tmp}/.slotplan.$$"
  #------------------------------------------------------------------------
  # 唯一的**极端保护**：字体里完全没有中文字形时，中文槽位一个都不动。
  #   为什么留这一条：那种情况下替换会把整个界面（含 WebUI 自己）变成方块，
  #   用户连"换回无字体"都点不到 —— 属于"会把人卡死"的情况，必须挡。
  #   正常字体（有中文字形）一律全替换，不做任何其它保留。
  #------------------------------------------------------------------------
  # （极端保护的实现放在 _role_wanted 里：所有调用方共享同一套判定，
  #   诊断报告解释"为什么没换"时口径也一致。）
  #------------------------------------------------------------------------
  # ★ 1.0.9 自适应扫描 ★
  #   先按老规矩（XML 主文字族 + 模板 + OEM 规则）枚举候选；**再补上"设备自己的字体配置
  #   里引用到、但模板一路没覆盖到的角色"** —— 这样没适配过的 ROM 也能本地自适应，
  #   不用等我们加 targets/*.list。补的规则在 slot_adaptive_extra 里（只补空缺角色）。
  CAND_RAW=$(slot_candidates "$moddir")
  CAND_EXTRA=$(slot_adaptive_extra "$CAND_RAW")
  if [ -n "$CAND_EXTRA" ]; then
    CAND_RAW=$(printf '%s\n%s\n' "$CAND_RAW" "$CAND_EXTRA" | grep -v '^[[:space:]]*$' | sort -u)
  fi
  # 让诊断报告/界面能看到"这次有没有靠自适应补的、补了几个"（供报告展示）
  ADAPTIVE_N=$(printf '%s\n' "$CAND_EXTRA" | grep -c . 2>/dev/null)
  [ -n "$ADAPTIVE_N" ] || ADAPTIVE_N=0
  export ADAPTIVE_N
  base=$(printf '%s\n' "$CAND_RAW" | while read -r role d name; do
           _role_wanted "$role" "$scope" "$keep_lang" "$keep_special" "$name" "$keep_lock" || continue
           printf '%s %s/%s\n' "$role" "${d#/}" "$name"
         done | sort -u -k2,2)
  [ -n "$base" ] || return 0
  # 最后按**整行**（= 完整目标路径）再兜一次去重。
  # base 上面已经按"目录/文件名"去过重，而主题字体那批是**追加**的、不参与那一步，
  # 所以这里对整体再来一次，保证计划生成端不会出现同一个目标路径两遍
  # （否则「已替换槽位」会虚高，挂载日志里也会多出重复的"跳过"）。
  # 注意：不能用文件名去重 —— /product/fonts/X 与 /system/fonts/X 是两条合法槽位，
  # 按文件名去重会把它们误删（真机报告里 same=N 那批正是这种成对槽位）。
  # ★ 计划同时写 $_sp（本函数内部用来判断"是否真的产出了"）和 stdout
  #   —— 调用方是 `slot_plan ... > slots.map`，只写 $_sp 的话它会拿到空文件。
  { printf '%s\n' "$base"; theme_slots "$base"; } | awk '!seen[$0]++' | tee "$_sp"
  # ★ 计划成功产出了 → 才把这次运行的标记表提交成正式文件。
  #   这样 slots.marks 与 slots.map **必然是同一次运行的产物**，
  #   统计不会出现"计划是这次、标记表是另一次"的错位。
  [ -s "$_sp" ] && [ -f "$moddir/.marks.$$" ] && mv -f "$moddir/.marks.$$" "$moddir/slots.marks" 2>/dev/null
  # ★ 统计写盘：四路各多少（界面读这个，不用自己再算一遍）
  #   优先用**本次运行**的标记表（保证跟刚生成的计划同源）。
  [ -f "$moddir/.marks.$$" ] && mv -f "$moddir/.marks.$$" "$moddir/slots.marks" 2>/dev/null
  if [ -f "$moddir/slots.marks" ] && [ -s "$_sp" ]; then
    awk -v map="$moddir/slots.marks" -v out="$moddir/slots.sources" '
      BEGIN {
        while ((getline line < map) > 0) {
          i = index(line, " "); if (i < 2) continue
          src = substr(line, 1, i - 1); nm = substr(line, i + 1)
          if (!(nm in S)) S[nm] = src
        }
        close(map)
      }
      {
        # 计划行格式：<角色> <目录>/<文件名> 或 <字体id> <目录>/<文件名> <字体库来源>
        # → 文件名在**第 2 个字段**里（以前取 $NF 会拿到字体库文件名，全匹配不上）
        p = $2
        if (p == "") p = $1
        n = split(p, a, "/"); nm = a[n]
        s2 = (nm in S) ? S[nm] : "?"
        if (s2 == "x") X++
        else if (s2 == "s") SS++
        else if (s2 == "o") OO++
        else if (s2 == "d") DD++
        else U++
        T++
      }
      END {
        printf "T=%d\nx=%d\ns=%d\no=%d\nd=%d\nu=%d\n",
             T + 0, X + 0, SS + 0, OO + 0, DD + 0, U + 0 > out
      }' "$_sp" 2>/dev/null
  fi
}

# 诊断：按角色统计设备上"候选且存在"的槽位数量
slot_report() {
  local moddir="$1" role d name
  local c_latin=0 c_cjk=0 c_main=0 c_lang=0 c_sym=0 c_italic=0 c_serif=0 c_mono=0 c_clock=0 c_display=0 c_ttc=0
  local tmp="${TMPDIR:-/data/local/tmp}/.slotrep.$$"
  mkdir -p "${tmp%/*}" 2>/dev/null
  slot_candidates "$moddir" > "$tmp"
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


# ---------------------------------------------------------------------------
# ★ 2026-10-16：槽位来源分四路统计（界面读这个）
#
#   x = 系统字体配置里引用的（slot_xml_names）
#   s = 本模块内置的机型清单（targets/<rom>.list）
#   o = 按厂商命名规则补的（只对 coloros / originos / flyme 有效）
#   d = 本机字体目录里扫出来的（不依赖 ROM 清单 —— "通用适配"那套）
#   u = 来源不明的（不该有；有说明标记表缺行）
#
#   为什么**实时算**而不是读计划时的存档：
#     存档（slots.sources）是"计划生成那一刻"的快照，真机上它常比
#     slots.marks 旧（比如重装模块后计划重算、而存档没跟上），
#     界面就会显示成"系统配置里引用的 0 个"这种自相矛盾的值。
#   实时算的口径跟"计划"完全一致：读 slots.map（计划）+ slots.marks（来源）。
# ---------------------------------------------------------------------------
slot_sources_report() {
  local moddir="${1:-${MODDIR:-}}"
  local map="$moddir/slots.map" marks="$moddir/slots.marks"
  [ -s "$map" ] || { printf 'T=0\nx=0\ns=0\no=0\nd=0\nu=0\n'; return 0; }
  awk -v mk="$marks" '
    BEGIN {
      if ((getline _probe < mk) > 0) {
        close(mk)
        while ((getline line < mk) > 0) {
          i = index(line, " "); if (i < 2) continue
          src = substr(line, 1, i - 1); nm = substr(line, i + 1)
          if (!(nm in S)) S[nm] = src
        }
        close(mk)
      }
    }
    {
      # 计划行：文件名在**第 2 个字段**里（$NF 会拿到字体库文件名，全匹配不上）
      p = $2
      if (p == "") p = $1
      n = split(p, a, "/"); nm = a[n]
      s2 = (nm in S) ? S[nm] : "?"
      if (s2 == "x") X++
      else if (s2 == "s") SS++
      else if (s2 == "o") OO++
      else if (s2 == "d") DD++
      else U++
      T++
    }
    END {
      printf "T=%d\nx=%d\ns=%d\no=%d\nd=%d\nu=%d\n",
           T + 0, X + 0, SS + 0, OO + 0, DD + 0, U + 0
    }' "$map" 2>/dev/null
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
  for d in /system/fonts /system_ext/fonts /product/fonts /vendor/fonts \
           /odm/fonts /oem/fonts /mi_ext/fonts /my_product/fonts /my_heytap/fonts \
           /hw_product/fonts /prism/fonts /optics/fonts /oplus_product/fonts; do
    [ -d "$FSROOT$d" ] || continue
    for f in "$FSROOT$d"/*.ttf "$FSROOT$d"/*.otf "$FSROOT$d"/*.TTF "$FSROOT$d"/*.OTF; do
      [ -f "$f" ] || continue
      b=${f##*/}
      case "$b" in *'*') continue ;; esac
      sz=$(wc -c < "$f" 2>/dev/null | tr -dc '0-9')
      [ -n "$sz" ] || continue
      [ "$sz" -lt 32768 ] && continue
      bl=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
      case "$bl" in
        *sans-serif*|*sansserif*) : ;;          # Sans-Serif 例外 → 收
        *emoji*|*symbol*|*dingbat*|*braille*)
          n_sym=$((n_sym + 1)); continue ;;     # 刻意不换的（符号/emoji）
        *mono*|*cursive*|*casual*|*math*|*music*|*clock*|*serif*)
          continue ;;                           # 扫描层同样排除
      esac
      printf '%s\n' "$b" >> "$df"
    done
  done
  sort -u -o "$df" "$df"

  n_extra=$(grep -Fxvf "$xf" "$df" 2>/dev/null | grep -c .)

  rm -f "$xf" "$df" 2>/dev/null
  printf 'extra=%d\nsymskip=%d\n' "${n_extra:-0}" "${n_sym:-0}"
}
