#!/system/bin/sh
# 自定义字体切换模块 - 字体库管理 / 应用脚本（供 WebUI、安装脚本调用）
# 用法：
#   sh fontctl.sh status                      输出 A=<生效> P=<待生效> R=<系统> 等状态
#   sh fontctl.sh list                        列出字体库：id|名称|字节数|元数据
#   sh fontctl.sh ls <base64(目录)>           列出手机存储目录（文件夹 + ttf/otf）
#   sh fontctl.sh import <路径> [名称]         从手机存储导入字体（直接 cp，速度快）
#   sh fontctl.sh upload-start                开始分块上传（WebUI 文件选择器用）
#   sh fontctl.sh upload-finish <大小> [名称]  结束分块上传并入库
#   sh fontctl.sh rename <id> <新名称>
#   sh fontctl.sh delete <id> [id...]         删除（可多个；使用中的会跳过）
#   sh fontctl.sh apply <选择>                切换字体。选择：none | <id> | <中文id>+<英文id>
#   sh fontctl.sh reapply                     按当前待生效的选择重新生成（改设置后用）
#   sh fontctl.sh plan <选择>                 预览：将替换多少个槽位（不改动任何文件）
#   sh fontctl.sh setmeta <id> k=v [k=v...]   写入字体元数据（覆盖范围、scope 等）
#   sh fontctl.sh settings [get|set <k> <v>]  全局设置
#   sh fontctl.sh verify                      检查已替换的槽位当前是否真的生效
#   sh fontctl.sh relink                      修复断开的硬链接（节省空间，开机自动执行）
#   sh fontctl.sh conflicts                   列出其他同样修改系统字体的模块
#   sh fontctl.sh report [save]               诊断报告（save 则写到 Download 目录）
#   sh fontctl.sh diag <brief|full|install|save|bg [force] [fast]|state|text|textpage <off> <len>|partinfo|savenow|cancel|clean|estimate>  一键体检（原样转发给 diag.sh）
#   sh fontctl.sh sync                        开机后确认 pending -> active
#   sh fontctl.sh prop                        刷新 module.prop 描述
#   sh fontctl.sh ack                         清除"已自动恢复"提示
#
# 切换采用"先生成、再校验、最后提交"：新字体文件全部就绪才替换旧的，中途失败保留原来的字体。

MODDIR=$(cd "$(dirname "$0")" && pwd)
LIB=/data/adb/custom_font_lib
PART="$LIB/.upload.part"
# 直接读 /data/media/0 比走 /sdcard(FUSE) 快得多
STORAGE=${STORAGE:-/data/media/0}
[ -d "$STORAGE" ] || STORAGE=/storage/emulated/0

# ⚠ 这里的 `.` 不能写成 `. "$MODDIR/x.sh" 2>/dev/null`：
#   POSIX 里 `.` 是**特殊内建**，打不开文件是**致命错误** —— `2>/dev/null` 只是把报错信息
#   藏起来，挡不住它把整个脚本带走（实测 busybox sh：`. /不存在的文件 2>/dev/null` 之后
#   后面的命令一行都不执行，退出码 2）。
#   后果不是"少个功能"：fontctl.sh 是界面的唯一入口，它当场退出 = 卡片空白、切不了字体、
#   诊断打不开、所有开关失效，而且用户拿不到任何线索。
#   （2026-10-11 姊妹项目同步 v1.0.5 时抓到的，原来是 `. ... 2>/dev/null`）
for _mf in common.sh slots.sh mount.sh; do
  [ -f "$MODDIR/$_mf" ] || { echo "ERROR:模块文件缺失（$_mf）—— 请重新安装模块"; exit 3; }
  . "$MODDIR/$_mf"
done
unset _mf
# ttcwrap.sh（.ttc 合集生成器）是**可选**的：老包/不完整包里可能没有。
# 缺了只是"合集替换"这条功能不可用，绝不能让整个 fontctl 退出 ——
# apply 里会为这种槽位记一笔 via=no-generator（见下面的 .ttc 分支）。
[ -f "$MODDIR/ttcwrap.sh" ] && . "$MODDIR/ttcwrap.sh"
mkdir -p "$LIB" 2>/dev/null
export TMPDIR="$LIB"

APPLIED="$MODDIR/slots.applied"
MODID=$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
# ★ 2026-10-19 保时捷版改动：id 不能写死主项目的。
#   本项目 4 个包 id 是 porsche_font_multi / _718 / _911 / _gt3。
if [ -z "$MODID" ]; then
  for _d in /data/adb/modules/porsche_font_*; do
    [ -f "$_d/module.prop" ] || continue
    MODID=${_d##*/}
    break
  done
fi
[ -n "$MODID" ] || MODID=porsche_font_multi

# 旧版把设置放在模块目录（升级会被覆盖），迁移到字体库目录
[ -f "$SETTINGS" ] || { [ -f "$MODDIR/settings.conf" ] && cp -f "$MODDIR/settings.conf" "$SETTINGS" 2>/dev/null; }

# ---- 字体元数据：$LIB/<id>.meta，每行 key=value ----
meta_get() { sed -n "s/^$2=//p" "$LIB/$1.meta" 2>/dev/null | tail -n1 | tr -d '\r\n'; }
meta_set() {
  local tmp="$LIB/$1.meta.tmp.$$"
  case "$2" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
  case "$3" in *[!A-Za-z0-9_.-]*) return 1 ;; esac
  { grep -v "^$2=" "$LIB/$1.meta" 2>/dev/null; echo "$2=$3"; } > "$tmp" && mv -f "$tmp" "$LIB/$1.meta"
}
meta_compact() { tr '\n' ',' 2>/dev/null < "$LIB/$1.meta" | sed 's/,$//'; }

# 该字体实际使用的替换范围：用户指定 > 按覆盖范围自动判断
# 结果同时写进全局 EFF_SCOPE，"凭什么这么判"写进 SCOPE_VIA（诊断报告的决策记录要用）。
# 注意：想拿到 SCOPE_VIA 就直接调 _eff_scope，别用 $(...) 包 —— 那会开子 shell 把变量丢掉。
_eff_scope() {
  local sc latin cjk
  case "$1" in
    *+*) EFF_SCOPE=combo; SCOPE_VIA=组合字体; return ;;
    ""|none) EFF_SCOPE=all; SCOPE_VIA=未选择字体; return ;;
  esac
  sc=$(meta_get "$1" scope)
  case "$sc" in
    all|latin|cjk) EFF_SCOPE="$sc"; SCOPE_VIA="字体元数据 scope=$sc（导入时指定）"; return ;;
  esac
  latin=$(meta_get "$1" latin); cjk=$(meta_get "$1" cjk)
  if [ -z "$latin$cjk" ]; then
    EFF_SCOPE=all
    SCOPE_VIA="没有覆盖范围记录（老字体）→ 按中英文都替换"
    return
  fi
  if [ "$cjk" = 1 ] && [ "$latin" = 1 ]; then EFF_SCOPE=all;   SCOPE_VIA="探针：英文有 中文有 → 全换"
  elif [ "$latin" = 1 ]; then              EFF_SCOPE=latin; SCOPE_VIA="探针：英文有 中文没有 → 只换拉丁"
  elif [ "$cjk" = 1 ]; then                EFF_SCOPE=cjk;   SCOPE_VIA="探针：中文有 英文没有 → 只换中文"
  else                                     EFF_SCOPE=latin; SCOPE_VIA="探针：两边都不全 → 只换拉丁"
  fi
}
effective_scope() { _eff_scope "$1"; printf '%s\n' "$EFF_SCOPE"; }

clean_name() { printf '%s' "$1" | tr -d '|\\\r\n'; }

# 路径里不允许出现 .. 段或换行
bad_path() {
  case "$1" in
    ..|../*|*/..|*/../*) return 0 ;;
    *'
'*) return 0 ;;
  esac
  return 1
}

# 显示路径(/storage/emulated/0、/sdcard) -> 真实路径
to_real() {
  case "$1" in
    /storage/emulated/0)   echo "$STORAGE" ;;
    /storage/emulated/0/*) echo "$STORAGE${1#/storage/emulated/0}" ;;
    /sdcard)               echo "$STORAGE" ;;
    /sdcard/*)             echo "$STORAGE${1#/sdcard}" ;;
    *)                     echo "$1" ;;
  esac
}

name_of() {
  local n
  n=$(cat "$LIB/$1.name" 2>/dev/null | tr -d '\r\n')
  echo "${n:-$1}"
}

# ---- 选择：none | <id> | <中文id>+<英文id> ----
sel_cjk() { echo "${1%%+*}"; }
sel_lat() { echo "${1##*+}"; }
sel_ids() {
  case "$1" in
    ""|none) ;;
    *+*) echo "$(sel_cjk "$1")"; echo "$(sel_lat "$1")" ;;
    *) echo "$1" ;;
  esac
}

label_of() {
  case "$1" in
    ""|none) echo "无字体（系统默认）" ;;
    *+*) echo "中文 $(name_of "$(sel_cjk "$1")") + 英文 $(name_of "$(sel_lat "$1")")" ;;
    *) name_of "$1" ;;
  esac
}

cur_active()  { local v; v=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/active_font"); echo "${v:-none}"; }
cur_pending() { local v; v=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font"); echo "${v:-$(cur_active)}"; }

# 只接受 TTF / OTF（TTC 合集不能直接替换单文件槽位）
# ⚠ 光看魔数不够：**截断/损坏的文件魔数也是对的**，而把坏字体挂到系统字体槽上，
#   轻则文字显示异常，重则开机后系统字体加载失败（真机反馈过"卡开机后黑屏"）。
#   所以这里把表目录也验一遍：
#     · 表数量合理、目录长度落在文件内
#     · 每条表的 偏移+长度 都落在文件内（截断文件必然过不了这一关）
#     · 必需的几张表都在（cmap/head/hhea/hmtx/maxp + glyf/loca 或 CFF）
valid_font() {
  local f="$1" m sz b num tot bytes v c tag off ln
  local has_cmap=0 has_head=0 has_hhea=0 has_hmtx=0 has_maxp=0 has_glyf=0 has_cff=0
  [ -f "$f" ] || return 1
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  case "$sz" in ''|*[!0-9]*) return 1 ;; esac
  [ "$sz" -ge 512 ] 2>/dev/null || return 1
  m=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$m" in
    00010000|4f54544f|74727565) ;;
    *) return 1 ;;
  esac
  b=$(od -An -tu1 -j4 -N2 "$f" 2>/dev/null); set -- $b
  [ $# -ge 2 ] || return 1
  num=$(( $1 * 256 + $2 ))
  [ "$num" -ge 5 ] 2>/dev/null || return 1
  [ "$num" -le 512 ] 2>/dev/null || return 1
  tot=$(( 12 + 16 * num ))
  [ "$tot" -le "$sz" ] 2>/dev/null || return 1
  bytes=$(od -An -tu1 -j0 -N"$tot" "$f" 2>/dev/null | tr -s ' \n' ' ')
  set -- $bytes
  [ $# -ge "$tot" ] || return 1
  v=0; while [ "$v" -lt 12 ]; do shift; v=$((v+1)); done
  v=0
  while [ "$v" -lt "$num" ]; do
    [ $# -ge 16 ] || return 1
    tag=""
    # 只认要用的那几张表，省掉字符串比较
    [ "$1" = 99 ]  && [ "$2" = 109 ] && [ "$3" = 97 ]  && [ "$4" = 112 ] && tag=cmap
    [ "$1" = 104 ] && [ "$2" = 101 ] && [ "$3" = 97 ]  && [ "$4" = 100 ] && tag=head
    [ "$1" = 104 ] && [ "$2" = 104 ] && [ "$3" = 101 ] && [ "$4" = 97 ]  && tag=hhea
    [ "$1" = 104 ] && [ "$2" = 109 ] && [ "$3" = 116 ] && [ "$4" = 120 ] && tag=hmtx
    [ "$1" = 109 ] && [ "$2" = 97 ]  && [ "$3" = 120 ] && [ "$4" = 112 ] && tag=maxp
    [ "$1" = 103 ] && [ "$2" = 108 ] && [ "$3" = 121 ] && [ "$4" = 102 ] && tag=glyf
    [ "$1" = 67 ]  && [ "$2" = 70 ]  && [ "$3" = 70 ]  && [ "$4" = 32 ]  && tag=cff
    shift 8
    off=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); shift 4
    ln=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); shift 4
    # 截断文件在这里必然露馅
    [ $(( off + ln )) -le "$sz" ] 2>/dev/null || return 1
    case "$tag" in
      cmap) has_cmap=1 ;; head) has_head=1 ;; hhea) has_hhea=1 ;;
      hmtx) has_hmtx=1 ;; maxp) has_maxp=1 ;; glyf) has_glyf=1 ;; cff) has_cff=1 ;;
    esac
    v=$((v+1))
  done
  [ "$has_cmap" = 1 ] && [ "$has_head" = 1 ] && [ "$has_hhea" = 1 ] && \
  [ "$has_hmtx" = 1 ] && [ "$has_maxp" = 1 ] || return 1
  # 轮廓数据：TrueType 用 glyf，OpenType/CFF 用 CFF —— 两个都没有就是空壳
  [ "$has_glyf" = 1 ] || [ "$has_cff" = 1 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# ★ 2026-10-14：**只要"有没有轮廓表"这一个答案**（给"应用前复查"用）
#
# 为什么不复用 valid_font：valid_font 要求 cmap/head/hhea/hmtx/maxp **全都在**，
#   而有些真机字体（尤其手机厂商的 CJK 子集、CFF2 变量字体）表集合不完全一样 ——
#   拿 valid_font 去当"应用前的闸门"会**误伤好字体**。
#   这里只查最要命、且各格式通用的一条：**必须有轮廓数据**。
#     TrueType → glyf     OpenType/CFF → CFF␣ 或 CFF2     矢量备用 → SVG␣
#   一个都没有 = 空壳，挂上去满屏方框（真机 realme RMX6699 就是这个）。
#
# 输出：0 = 有轮廓（可以用）；1 = 没有轮廓（别挂）
# 读法：一次 od 读前 3072 字节（表目录远小于这个），纯 shell 判，零额外进程。
# ---------------------------------------------------------------------------
has_outline() {
  local f="$1" num tot bytes v b4 id mv sv sz
  [ -f "$f" ] || return 1
  id=${f##*/}; id=${id%.ttf}
  # ★ 2026-10-15（作者的建议）：**检测只做一次，结果记住** —— 以后切换不再读字体文件。
  #   ⚠️ 性能教训：第一版用 `sed|tail|tr|wc` 分别去读 meta，**每条都是一次进程创建**，
  #      5 个进程的开销把"省下一次读文件"吃掉了（实测命中缓存 395ms/次，读文件 730ms/次，
  #      只快一倍）。改成 **cat 一次读进变量 + 纯 shell 字符串匹配** → 零额外进程。
  _HO_META=""
  [ -f "$LIB/$id.meta" ] && _HO_META=$(cat "$LIB/$id.meta" 2>/dev/null)
  if [ -n "$_HO_META" ]; then
    # 用固定分隔符匹配，避免 meta 里别的值恰好叫 outline
    case "$_HO_META" in
      *"outline=1"*) sv=1 ;;
      *"outline=0"*) sv=0 ;;
      *) sv="" ;;
    esac
    case "$_HO_META" in
      *"outline_sz="*)
        mv=${_HO_META##*outline_sz=}; mv=${mv%%[!0-9]*} ;;
      *) mv="" ;;
    esac
    # ★ 2026-10-17（作者意见）：meta 里已有结论就直接用，**连 stat 都不做**。
    #
    #   为什么可以不校验大小：字体文件只会通过 store_font 写进字体库，
    #   而 store_font 每次都会重写 outline= / outline_sz= 这两行 ——
    #   所以"meta 里有 outline=" 本身就等于"这个文件已被 store_font 验过并记下"。
    #   外部替换文件那种情况，meta 也会一起过期，比大小同样救不回来。
    if [ -n "$sv" ]; then
      [ "$sv" = 1 ] && return 0
      return 1
    fi
    if [ -n "$mv" ]; then
      # 只有 outline_sz 没有 outline 的老格式，才补一次大小校验兜底
      sz=$(stat -c '%s' "$f" 2>/dev/null)
      if [ -n "$sz" ] && [ "$sz" = "$mv" ]; then return 1; fi
    fi
  fi
  # ---- 下面才是"真去读一遍"：新字体第一次、或文件被换过时才会走到 ----
  # ⚠️⚠️ 别用"tr 洗成词 + grep 精确匹配"那种写法 —— 这里踩过，是**真 bug**：
  #   `tr -c 'A-Za-z0-9' '\n'` 会把**字母数字的二进制字节**也保留，
  #   而表目录里 tag 后面紧跟的就是 checksum（4 字节二进制）——
  #   那 4 字节里恰好有字母数字时，tag 就和它**粘成一个词**（实测洗出来是 `glyfY`），
  #   于是 `grep -qx glyf` 永远不中，**有 glyf 的好字体被判成空壳**。
  #   正确做法：**按 16 字节一条读表目录**，只取每条第 0..3 字节当 tag 比较。
  num=$(od -An -tu1 -j4 -N2 "$f" 2>/dev/null); set -- $num
  [ $# -ge 2 ] || return 1
  num=$(( $1 * 256 + $2 ))
  [ "$num" -ge 1 ] 2>/dev/null || return 1
  [ "$num" -le 512 ] 2>/dev/null || return 1
  tot=$(( 16 * num ))
  bytes=$(od -An -tu1 -j12 -N"$tot" "$f" 2>/dev/null | tr -s ' \n' ' ')
  set -- $bytes
  [ $# -ge "$tot" ] || return 1
  v=0
  _HO_HIT=0
  while [ "$v" -lt "$num" ]; do
    b4="$1 $2 $3 $4"
    case "$b4" in
      "103 108 121 102") _HO_HIT=1; break ;;   # g l y f
      "67 70 70 50")     _HO_HIT=1; break ;;   # C F F 2
      "67 70 70 32")     _HO_HIT=1; break ;;   # C F F␣
      "83 86 71 32")     _HO_HIT=1; break ;;   # S V G␣
    esac
    shift 16
    v=$((v + 1))
  done
  # 把结论补记进 .meta（只写一次，之后都走上面的快路）
  if [ -s "$LIB/$id.meta" ]; then
    _hosz=$(wc -c < "$f" 2>/dev/null | tr -d ' \t\r')
    _hotmp="$LIB/$id.meta.tmp.$$"
    { grep -v '^outline=\|^outline_sz=' "$LIB/$id.meta" 2>/dev/null
      echo "outline=$_HO_HIT"
      echo "outline_sz=$_hosz"
    } > "$_hotmp" 2>/dev/null && mv -f "$_hotmp" "$LIB/$id.meta" 2>/dev/null
  fi
  [ "$_HO_HIT" = 1 ] && return 0
  return 1
}

# 可用空间（KB）。取不到（路径不存在、df 输出格式不同）就返回空 —— 调用方按"查不到就不拦"处理
free_kb() {
  local v
  v=$(df -k "$1" 2>/dev/null | tail -n1 | tr -s ' ' | cut -d' ' -f4 | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$v"
}

new_id() {
  local t i id
  t=$(date +%s); i=0; id="f$t"
  while [ -e "$LIB/$id.ttf" ] && [ "$i" -lt 1000 ]; do
    i=$((i+1)); id="f${t}_$i"
  done
  echo "$id"
}

id_ok() {
  case "$1" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
  [ -f "$LIB/$1.ttf" ]
}

check_id() {
  case "$1" in
    ""|*[!A-Za-z0-9_]*) echo "ERROR:非法的字体 ID"; exit 1 ;;
  esac
  [ -f "$LIB/$1.ttf" ] || { echo "ERROR:字体不存在"; exit 1; }
}

# 校验并规范化选择；非法时直接退出
check_sel() {
  local id
  case "$1" in
    ""|none) echo none; return 0 ;;
    *+*+*) echo "ERROR:选择格式不正确"; exit 1 ;;
  esac
  for id in $(sel_ids "$1"); do
    id_ok "$id" || { echo "ERROR:字体不存在或 ID 非法：$id"; exit 1; }
  done
  # 中英文选了同一个字体 = 普通单字体
  case "$1" in *+*) [ "$(sel_cjk "$1")" = "$(sel_lat "$1")" ] && { sel_cjk "$1"; return 0; } ;; esac
  echo "$1"
}

in_use() {
  local id
  for id in $(sel_ids "$(cur_active)") $(sel_ids "$(cur_pending)"); do
    [ "$id" = "$1" ] && return 0
  done
  return 1
}

# 入库：store_font <源文件> <名称> <cp|mv>
store_font() {
  local src="$1" name="$2" mode="$3" id dst sz need free
  if ! valid_font "$src"; then
    rm -f "$PART"
    echo "ERROR:这份字体无法使用：内部结构不完整（可能已损坏/被截断/少了字形轮廓表）。TTC 合集请先在电脑上用 tools/optimize_font.py --face 拆出单个字体再导入"
    return 1
  fi
  # 空间检查：字体本身 + 换成 .ttc 合集时要再合成几份（每份≈原合集+本字体），
  # 写满 /data 会让系统起不来（真机反馈过"强制重启后黑屏、进不去桌面"）。
  # ★ 2026-10-17 提速：`wc -c < 文件` 会把整个字体从头读一遍（几十 MB）
  #   来量大小，而 `stat -c %s` 只读元数据。导入一个字体要量 3~4 次。
  sz=$(stat -c '%s' "$src" 2>/dev/null)
  if [ -n "$sz" ] && [ "$sz" -gt 0 ] 2>/dev/null; then
    need=$(( sz / 1024 * 4 + 20480 ))          # 字体×4 + 20MB 余量
    free=$(free_kb "$LIB")
    if [ -n "$free" ] && [ "$free" -lt "$need" ] 2>/dev/null; then
      echo "ERROR:存储空间不足（字体 $(( sz / 1048576 ))MB，算上合集大约需要 $(( need / 1024 ))MB，/data 只剩 $(( free / 1024 ))MB）"
      return 1
    fi
  fi
  id=$(new_id); dst="$LIB/$id.ttf"
  if [ "$mode" = mv ]; then
    mv -f "$src" "$dst" 2>/dev/null || cp -f "$src" "$dst"
  else
    cp -f "$src" "$dst"
  fi
  if [ ! -s "$dst" ]; then
    rm -f "$dst"
    echo "ERROR:写入字体库失败（存储空间不足？）"
    return 1
  fi
  if [ "$mode" != mv ] && [ "$(stat -c '%s' "$src" 2>/dev/null)" != "$(stat -c '%s' "$dst" 2>/dev/null)" ]; then
    rm -f "$dst"
    echo "ERROR:复制不完整（存储空间不足？）"
    return 1
  fi
  chmod 644 "$dst" 2>/dev/null
  # 字体最终会被硬链接进模块目录，必须是 system_file 标签，否则 zygote 读不了
  chcon u:object_r:system_file:s0 "$dst" 2>/dev/null
  [ -n "$name" ] || name=$(basename "$src" | sed 's/\.[^.]*$//')
  printf '%s' "$(clean_name "$name")" > "$LIB/$id.name"
  # ★ 2026-10-15（作者的建议）：**导入时就把"有没有轮廓"验一次并记进 meta**。
  #   这样以后每次切换直接读记录，不用再读字体文件（切换更快）。
  #   在 store_font 里做最合适：valid_font 刚刚已经完整验过一遍，这里只是把结论落盘。
  _sf_sz=$(stat -c '%s' "$dst" 2>/dev/null)
  if valid_font "$dst"; then _sf_ho=1; else _sf_ho=0; fi
  if [ -s "$LIB/$id.meta" ]; then
    _sf_tmp="$LIB/$id.meta.tmp.$$"
    { grep -v '^outline=\|^outline_sz=' "$LIB/$id.meta" 2>/dev/null
      echo "outline=$_sf_ho"
      echo "outline_sz=$_sf_sz"
    } > "$_sf_tmp" 2>/dev/null && mv -f "$_sf_tmp" "$LIB/$id.meta" 2>/dev/null
  else
    printf 'outline=%s\noutline_sz=%s\n' "$_sf_ho" "$_sf_sz" > "$LIB/$id.meta" 2>/dev/null
  fi
  echo "OK:$id"
}

# 目录里是否存在真实字体文件（必须是文件；未匹配的通配符串会被 [ -f ] 挡掉）
_conf_fonts_in() {
  local f
  [ -d "$1" ] || return 1
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.[tT][tT][fFcC]|*.[oO][tT][fF]) return 0 ;; esac
  done
  return 1
}

# ---- 冲突检测：其他启用中、且会把字体挂到系统分区上的模块 ----
# 只认 system/ 下的 fonts 目录 + 根级的厂商分区（vendor/product/system_ext/odm/my_*…），
# 并排除 webroot/webui/web/assets/tools 这类界面/资源目录 —— 否则自带字体的 WebUI 模块
# （例如 ReZygisk 之类）会被误判成"其他字体模块"。
# ★ 2026-10-17 提速：界面每次刷新都会调 list_conflicts（要遍历所有模块的 fonts 目录）。
#   这里包一层结果缓存：模块目录的 mtime 没变就直接读缓存，原逻辑一字不改
#   （真算的那部分在 _list_conflicts_raw 里，跟以前完全一样）。
list_conflicts() {
  local _ck _cf="$LIB/.conflicts.cache"
  _ck=$(stat -c '%Y-%s' /data/adb/modules 2>/dev/null)
  if [ -s "$_cf" ] && [ "$(sed -n '1p' "$_cf" 2>/dev/null)" = "$_ck" ]; then
    sed -n '2,$p' "$_cf" 2>/dev/null
    return 0
  fi
  { printf '%s\n' "$_ck"; _list_conflicts_raw "$@"; } > "$_cf.tmp.$$" 2>/dev/null && \
    mv -f "$_cf.tmp.$$" "$_cf" 2>/dev/null
  sed -n '2,$p' "$_cf" 2>/dev/null
}

_list_conflicts_raw() {
  local m id d f hit name rel
  for m in /data/adb/modules/*; do
    [ -d "$m" ] || continue
    id=${m##*/}
    [ "$id" = "$MODID" ] && continue
    { [ -f "$m/disable" ] || [ -f "$m/remove" ]; } && continue
    hit=0
    for d in "$m"/system/fonts "$m"/system/*/fonts "$m"/system/*/*/fonts; do
      [ -d "$d" ] || continue
      _conf_fonts_in "$d" && { hit=1; break; }
    done
    if [ "$hit" = 0 ]; then
      for d in "$m"/*/fonts; do
        [ -d "$d" ] || continue
        rel=${d#"$m"/}
        case "$rel" in
          webroot/*|webui/*|WebUI/*|web/*|assets/*|docs/*|tools/*|lib/*|lib64/*) continue ;;
        esac
        _conf_fonts_in "$d" && { hit=1; break; }
      done
    fi
    if [ "$hit" = 0 ]; then
      for f in "$m"/system/etc/fonts.xml "$m"/system/etc/font_fallback.xml "$m"/system/etc/fonts_additional.xml; do
        [ -f "$f" ] && { hit=1; break; }
      done
    fi
    [ "$hit" = 1 ] || continue
    name=$(sed -n 's/^name=//p' "$m/module.prop" 2>/dev/null | head -n1 | tr -d '\r|')
    echo "$id|${name:-$id}"
  done
}

# 本次开机的挂载结果："ok fail stage"；不是本次开机写的则为空
mount_result() {
  local f="$MODDIR/mount.state"
  [ -f "$f" ] || return 0
  # ★ 2026-10-17 提速：原来 7 个子 shell（1 次 boot 比对 + 5 次 sed 取字段），
  #   现在一个 awk 全取完 = 2 个子 shell。输出格式不变：ok fail stage same skip
  #   （same/skip 一定要带上，否则界面上"成功 18"看着像丢了 6 个槽位）
  awk -v bid="$(boot_id)" '
    /^boot=/  { boot  = substr($0, 6) }
    /^ok=/    { ok    = substr($0, 4) }
    /^fail=/  { fail  = substr($0, 6) }
    /^stage=/ { stage = substr($0, 7) }
    /^same=/  { same  = substr($0, 6) }
    /^skip=/  { skip  = substr($0, 6) }
    END {
      if (boot != bid) exit
      print ok, fail, stage, same, skip
    }' "$f" 2>/dev/null
}

refresh_prop() {
  local A P ROM_NAME D PROP_FILE warn=""
  A=$(cur_active); P=$(cur_pending)
  ROM_NAME=$(rom_name "$(cat "$MODDIR/current_rom" 2>/dev/null | tr -d '[:space:]')")
  # ★ 2026-10-17（作者要求：apply 要快）：这里不再查冲突模块。
  #   界面的「冲突模块」那一栏会单独显示（status 里查），
  #   apply 路径上没必要为了一句警告去扫一遍模块目录。
  if [ "$A" = "$P" ]; then
    D="[系统：$ROM_NAME | 当前生效：$(label_of "$A")] 在 WebUI 导入自己的字体并切换，默认不替换任何字体。$warn"
  else
    D="[系统：$ROM_NAME | 当前生效：$(label_of "$A")，待重启后生效：$(label_of "$P")] 在 WebUI 导入自己的字体并切换，默认不替换任何字体。$warn"
  fi
  PROP_FILE="$MODDIR/module.prop"
  [ -f "$PROP_FILE" ] || return 0
  awk -v new="description=$D" '{ if ($0 ~ /^description=/) print new; else print $0 }' \
    "$PROP_FILE" > "$PROP_FILE.tmp" && mv "$PROP_FILE.tmp" "$PROP_FILE"
}

# 刷新 ROM 识别（OTA 后可能变化）
refresh_rom() {
  detect_rom > "$MODDIR/current_rom" 2>/dev/null
}

# 生成计划到文件（每行 "角色 目标路径"）；输出 scope
make_plan() {
  local sel="$1" out="$2" scope kl ks
  _eff_scope "$sel"          # 不用 $(...)：SCOPE_VIA 要留在当前 shell 里给决策记录用
  scope="$EFF_SCOPE"
  kl=$(cfg_get keep_lang 0); ks=$(cfg_get keep_special 0)
  # ★ 2026-10-14：新增「保留锁屏字体」开关（cfg 键 keep_lockscreen，默认 0 = 照旧全替换）。
  #   为什么单独给它一个开关、而不是复用 keep_special：
  #     keep_special 是"保留 clock/mono/italic/serif/display **一锅端**" ——
  #     真机上不开替换 20 个槽位、开了 70 个，多出来的 50 个里真正跟锁屏有关的只有几个，
  #     用户体感就是"替换不全"；而把它关掉又让想自定义锁屏的人用不了。
  #     精确判据在 slots.sh 的 slot_lockscreen_files（看 family 名带不带 clock），
  #     实测一台小米机认出 34 个锁屏文件，正正好好。
  #   keep_lang / keep_special 仍然保留读取只为兼容老配置文件。
  klk=$(cfg_get keep_lockscreen 0)
  KLLAST="kl=$klk"      # 给 do_apply 的返回值用（诊断用，看模块实际读到几）
  # 1.0.9：界面已删掉那两个开关（默认全替换）；保留读取只为兼容老配置文件。
  SEL_FONT="$sel"            # 给 slot_plan/_meta_have 用：拿这个字体的 meta 判字形覆盖
  # 极端保护：字体完全没有中文字形 → 中文槽位一个都不动
  # （否则整个界面会变方块，用户连 WebUI 都看不清、没法换回来）。正常字体不会命中。
  CJK_GUARD=0
  if [ -f "$LIB/$sel.meta" ] && \
     [ "$(sed -n 's/^cjk=//p' "$LIB/$sel.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')" = 0 ]; then
    CJK_GUARD=1
  fi
  export CJK_GUARD
  if [ "$scope" = combo ]; then
    slot_plan "$MODDIR" all "$kl" "$ks" "$klk" > "$out"
  else
    slot_plan "$MODDIR" "$scope" "$kl" "$ks" "$klk" > "$out"
  fi
  # 除了 echo，还留一份到全局变量：调用方常用 $(...) 取返回值，那会开子 shell，
  # 而 SCOPE_VIA（判定依据）是在子 shell 里设的，外面拿不到 —— 所以调用方直接读 PLAN_SCOPE。
  PLAN_SCOPE="$scope"
  echo "$scope"
}

# 某个角色的槽位用哪个字体：组合模式下中文/混合主槽用中文字体，其余用英文字体
font_for_role() {
  case "$1" in
    *+*)
      case "$2" in
        cjk|main|lang|ttc) sel_cjk "$1" ;;
        *) sel_lat "$1" ;;
      esac ;;
    *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# 多字重配对（复刻 MTZ 主题包的做法）
#
# 问题：系统里"加粗"是去同一族里找 weight=700 那份**文件**（MiSans-Bold / SourceSansPro-Bold…）。
#       我们以前一个字体铺满所有槽位 —— 系统要 700，拿到的还是 Regular，所以看不出加粗。
# 做法：同一族的多个字重（靠导入时记下的 fam 分组）在 apply 时各就各位：
#       看槽位要哪个字重（从文件名推断），从族里挑最接近的那一份。
# 代价：族里只有一份文件时什么都不做（零开销），这是绝大多数人的情况。
# ---------------------------------------------------------------------------

# 从槽位文件名推断系统想要的字重。顺序要紧：extrabold 必须先于 bold、
# extralight 必须先于 light，否则会被短关键词先匹配走。
slot_weight() {
  # ★ 2026-10-17 提速：原来用 `tr` 转小写 —— 每个槽位起一个进程。
  #   现在直接在 case 里匹配（纯 shell，零进程）。
  #   ⚠️ 每个字母都要双写 `[Tt]hin` 这种形式 —— 只写首字母的话
  #      "THIN" / "BOLD" 这种全大写文件名会匹配不上（踩过一次）。
  #   判定顺序不能改：semibold/extrabold 必须在 bold 前面，
  #   否则 "SemiBold" 会先命中 bold 变成 700。
  case "$1" in
    *[Tt][Hh][Ii][Nn]*)
      echo 100 ;;
    *[Ee][Xx][Tt][Rr][Aa][Ll][Ii][Gg][Hh][Tt]*|*[Uu][Ll][Tt][Rr][Aa][Ll][Ii][Gg][Hh][Tt]*)
      echo 200 ;;
    *[Ll][Ii][Gg][Hh][Tt]*)
      echo 300 ;;
    *[Mm][Ee][Dd][Ii][Uu][Mm]*)
      echo 500 ;;
    *[Ss][Ee][Mm][Ii][Bb][Oo][Ll][Dd]*|*[Dd][Ee][Mm][Ii][Bb][Oo][Ll][Dd]*)
      echo 600 ;;
    *[Ee][Xx][Tt][Rr][Aa][Bb][Oo][Ll][Dd]*|*[Uu][Ll][Tt][Rr][Aa][Bb][Oo][Ll][Dd]*)
      echo 800 ;;
    *[Bb][Ll][Aa][Cc][Kk]*|*[Hh][Ee][Aa][Vv][Yy]*)
      echo 900 ;;
    *[Bb][Oo][Ll][Dd]*)
      echo 700 ;;
    *)
      echo 400 ;;
  esac
}

# 把某个字体所在族的全部字重读进来（一次 apply 最多两次：组合模式下中英各一次）
# 结果放 GRP_PAIRS="id:字重 id:字重 …"，没配对时只有它自己
grp_load() {
  local leader="$1" fam m id fam2 w
  local pairs="$leader:$(meta_get "$leader" wght)"
  GRP_PAIRS="$pairs"
  fam=$(meta_get "$leader" fam)
  case "$fam" in ""|none) return 0 ;; esac
  # 统一用 lib_font_ids（各项目这个函数各写各的规则：
  #   主项目只认 f*，子项目还认 builtin_*）—— 这样函数体在两边一模一样。
  for id in $(lib_font_ids); do
    [ "$id" = "$leader" ] && continue
    [ -f "$LIB/$id.meta" ] || continue
    fam2=$(meta_get "$id" fam)
    [ "$fam2" = "$fam" ] || continue
    w=$(meta_get "$id" wght)
    pairs="$pairs $id:$w"
  done
  GRP_PAIRS="$pairs"
}

# 从族里挑字重最接近 want 的那一份；族里只有一份就直接返回它
grp_pick() {
  local want="$1" p id w d best="" bestd=""
  case "$GRP_PAIRS" in ""|*" "*) ;; *) printf '%s' "${GRP_PAIRS%%:*}"; return 0 ;; esac
  for p in $GRP_PAIRS; do
    id=${p%%:*}; w=${p##*:}
    case "$w" in ''|*[!0-9]*) w=400 ;; esac
    d=$(( w - want )); [ "$d" -lt 0 ] && d=$(( 0 - d ))
    if [ -z "$bestd" ] || [ "$d" -lt "$bestd" ]; then bestd="$d"; best="$id"; fi
  done
  GRP_WID="${best:-${GRP_PAIRS%%:*}}"
}

# ★ 2026-10-17 提速：结果写进 GRP_WID，不再 printf 到 stdout。
#   原来调用方是 `wid=$(grp_pick_for ...)` —— 每个槽位一个子 shell，
#   420 个槽位就是 420 次 fork。改成写变量后循环里一次都不 fork。
grp_pick_for() {   # $1=槽位文件名 → 结果写 GRP_WID
  local want p id w d best="" bestd=""
  # 内联 slot_weight（同样的判据，省掉一次子 shell）
  case "$1" in
    *[Tt][Hh][Ii][Nn]*)
      want=100 ;;
    *[Ee][Xx][Tt][Rr][Aa][Ll][Ii][Gg][Hh][Tt]*|*[Uu][Ll][Tt][Rr][Aa][Ll][Ii][Gg][Hh][Tt]*)
      want=200 ;;
    *[Ll][Ii][Gg][Hh][Tt]*)
      want=300 ;;
    *[Mm][Ee][Dd][Ii][Uu][Mm]*)
      want=500 ;;
    *[Ss][Ee][Mm][Ii][Bb][Oo][Ll][Dd]*|*[Dd][Ee][Mm][Ii][Bb][Oo][Ll][Dd]*)
      want=600 ;;
    *[Ee][Xx][Tt][Rr][Aa][Bb][Oo][Ll][Dd]*|*[Uu][Ll][Tt][Rr][Aa][Bb][Oo][Ll][Dd]*)
      want=800 ;;
    *[Bb][Ll][Aa][Cc][Kk]*|*[Hh][Ee][Aa][Vv][Yy]*)
      want=900 ;;
    *[Bb][Oo][Ll][Dd]*)
      want=700 ;;
    *)
      want=400 ;;
  esac
  case "$GRP_PAIRS" in
    ""|*" "*) ;;                                    # 空 或 多个 → 走下面的循环
    *) GRP_WID="${GRP_PAIRS%%:*}"; return 0 ;;      # 只有一个配对 → 直接用它
  esac
  for p in $GRP_PAIRS; do
    id=${p%%:*}; w=${p##*:}
    case "$w" in ''|*[!0-9]*) w=400 ;; esac
    d=$(( w - want )); [ "$d" -lt 0 ] && d=$(( 0 - d ))
    if [ -z "$bestd" ] || [ "$d" -lt "$bestd" ]; then bestd="$d"; best="$id"; fi
  done
  GRP_WID="${best:-${GRP_PAIRS%%:*}}"
}

# ★ 2026-10-17 提速：`grp_pick "$(slot_weight ...)"` 是两层子 shell（2 次 fork）。
#   合成一个函数，内部先算字重再挑最接近的那份 —— 只 1 次 fork。
#   判据跟原来完全一致：先 slot_weight 算出目标字重，再在族里找差值最小的。
# 删掉旧的"管理器挂载"文件（按 slots.applied 记录）
remove_manager_files() {
  local rel p
  [ -f "$APPLIED" ] || return 0
  while IFS= read -r rel || [ -n "$rel" ]; do
    rel=$(printf '%s' "$rel" | tr -d '\r')
    case "$rel" in ""|/*|*..*) continue ;; esac
    p=$(mgr_path "$rel")
    rm -f "$MODDIR/$p" 2>/dev/null
    ( cd "$MODDIR" && rmdir -p "${p%/*}" 2>/dev/null )
  done < "$APPLIED"
}

# 提交：用已生成好的 stage 替换旧的字体文件 / 槽位记录
commit_payload() {
  local stage="$1" mode="$2" old_mode f
  old_mode=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")
  # 管理器模式的旧文件，以及旧版遗留的直接放在模块根目录的旧链接
  [ "$old_mode" = self ] || remove_manager_files
  rm -rf "$MODDIR/payload" 2>/dev/null

  if [ "$mode" = manager ]; then
    if [ -d "$stage" ]; then
      # ★ 2026-10-17 提速：原来每个文件都 `mkdir -p` 一次 ——
      #   286 个槽位就 286 次 mkdir，而目标目录其实只有 2-3 个
      #   （system/fonts、product/fonts…）。改成先按目录去重建好、再逐个 mv。
      #   ⚠️ mv 必须保留：stage 和 MODDIR 在同一文件系统，mv 等于 rename
      #     （瞬时、不复制数据）。换成 cp 会把几十 MB 的字体真的复制 286 遍。
      ( cd "$stage" && find . -type d ) 2>/dev/null | while IFS= read -r _dd; do
        _dd=${_dd#./}
        [ -n "$_dd" ] || continue
        mkdir -p "$MODDIR/$_dd" 2>/dev/null
      done
      ( cd "$stage" && find . -type f ) 2>/dev/null | while IFS= read -r f; do
        f=${f#./}
        mv -f "$stage/$f" "$MODDIR/$f" 2>/dev/null
      done
    fi
    rm -f "$MODDIR/skip_mount"
  else
    # 自带挂载开机时直接挂字体库里的文件，模块目录里不需要任何副本
    touch "$MODDIR/skip_mount"
  fi
  rm -rf "$stage" 2>/dev/null

  if [ -f "$stage.list" ]; then mv -f "$stage.list" "$APPLIED"; else : > "$APPLIED"; fi
  # ★ 2026-10-19 修复「切保留时钟开关后软重启不生效」：
    #   覆盖之前先把上一份计划备份到 slots.map.prev。
    #   因为切开关会让计划变少（151 → 119，少掉的 32 个正是时钟槽位），
    #   而软重启的 do_unmount 只按现场挂载清单 $MNT_LIST 卸 ——
    #   开机时挂的那些不在清单里，卸不到 → 时钟仍然被替换 → 看起来「没生效」。
    #   有了 slots.map.prev，软重启就能把旧计划里的槽位全部卸掉。
    if [ -s "$MODDIR/slots.map" ]; then
      cp -f "$MODDIR/slots.map" "$MODDIR/slots.map.prev" 2>/dev/null
    fi
    if [ -f "$stage.map" ]; then mv -f "$stage.map" "$MODDIR/slots.map"; else : > "$MODDIR/slots.map"; fi
  echo "$mode" > "$MODDIR/payload.mode"
}

# ---------------------------------------------------------------------------
# 清掉"不再被引用"的合集文件
#
# 为什么需要：每个 .ttc 槽位都会在字体库里留一份合成好的合集（如 f1791634021.ttc5），
# 一份就是二三十 MB。换了字体、关掉「替换 .ttc 合集」、或者系统合集 face 数变了之后，
# 旧的那份就没人引用了 —— 不清的话会一直躺在 /data 里。
# 判据很保守：只删 $LIB 下形如 <id>.ttc<face数> 的文件，而且**必须不在当前的 slots.map 里**
# （slots.map 的第 3 个字段就是它）。删掉正在被 bind 挂载的文件是安全的 ——
# 挂载持有的是 inode，文件名消失不影响本次开机已经挂好的东西，重启后会按新计划挂。
# ---------------------------------------------------------------------------
prune_wrapped_ttc() {
  local f
  # ★ 2026-10-16 加一道保险（真机出过"产物不见了"）：
  #   计划文件不存在 / 为空 / 一行有效内容都没有时，**什么都不删**。
  #   原来的写法在那种情况下会走到 rm —— 把刚生成好的产物也删了，
  #   而 slots.map 还指着它 ⇒ 之后每次挂载都报
  #   "mount: '...ttc5_2-3'->'...': No such file or directory"。
  #   宁可少清理，也不能删掉正在用的东西。
  [ -s "$MODDIR/slots.map" ] || return 0
  if ! awk 'NF >= 2 { ok = 1 } END { exit !ok }' "$MODDIR/slots.map" 2>/dev/null; then
    return 0
  fi
  # ★ 2026-10-17 提速：原来每个 ttc 产物都跑一次 awk 读整份 slots.map（O(产物数×计划行数)）。
  #   现在先用一个 awk 把"计划里用到的文件"导出来，循环里只做字符串匹配。
  _ptused=" $(awk 'NF >= 3 { print $NF }' "$MODDIR/slots.map" 2>/dev/null | tr '\n' ' ') "
  for f in "$LIB"/*.ttc[0-9]* ; do
    [ -f "$f" ] || continue
    case "$_ptused" in
      *" $f "*) continue ;;
    esac
    rm -f "$f" 2>/dev/null
  done
  return 0
}

do_apply() {
  local sel scope plan role rel id src dest stage mode COUNT=0 fail=0 wid
  GRP_LAST=""; GRP_PAIRS=""     # 多字重配对的缓存（见 grp_load）
  sel=$(check_sel "$1") || { echo "$sel"; exit 1; }

  # ★★ 2026-10-14：**应用前再验一遍轮廓表**（不只是导入时验）。
  #
  # 为什么必须在这里也验：`valid_font` 只在**导入那一刻**跑。
  #   真机反馈（realme RMX6699 / ColorOS 17 / v1.1.0）：用户字体里**没有 glyf / CFF / CFF2**
  #   （只有 cmap loca head maxp post DSIG），却已经躺在字体库里，于是：
  #     桌面、设置 —— **所有中文都渲染成「口」**，英文数字正常（那部分字形另有来源）。
  #   用户那份是**旧版模块**导入的（那时 valid_font 还没这道检查），
  #   而应用时没人再验一遍 → 坏字体一路挂到系统上。
  #
  # 判据（与 valid_font 同源，但这里只查最要命的一条）：**必须有一张轮廓表**。
  #   TrueType → `glyf`；OpenType/CFF → `CFF `(尾随空格) 或 `CFF2`；还有 `SVG ` 也算有轮廓来源。
  #   一个都没有 = 空壳，挂上去只会满屏方框 —— 宁可不动、也不要给用户造这个。
  # ★ 2026-10-19 提速：has_outline 会把整个字体读一遍（内置配色 42MB），
    #   而导入时已经在 .meta 里记过 outline=1 了 —— 有记录就直接信，不再重复读。
    _ho_known=""
    if [ -f "$LIB/$sel.meta" ]; then
      case "$(sed -n 's/^outline=//p' "$LIB/$sel.meta" 2>/dev/null | head -n1 | tr -d '\r\n')" in
        1) _ho_known=1 ;;
      esac
    fi
    if [ -f "$LIB/$sel.ttf" ] && [ -z "$_ho_known" ] && ! has_outline "$LIB/$sel.ttf"; then
    printf '%s %s %s\n' "$sel" "系统槽位" "scope=blocked via=nooutline detail=字体没有轮廓表(glyf/CFF)，挂上去只会显示方框" \
      >> "$LIB/ttc.log" 2>/dev/null
    echo "ERROR:这份字体里没有任何字形轮廓（缺 glyf/CFF）—— 挂上去会让中文全变成方框。请删掉它重新导入一份正常的字体"
    exit 1
  fi

  # ★ 2026-10-18（真机 17 秒的真凶）：**apply 里不再重新识别机型**。
  #
  #   `refresh_rom` → `detect_rom`，而 detect_rom 要读 20 多个系统属性
  #   （ro.product.brand / ro.mi.os.version.name / …），每个属性都是一次
  #   `getprop` —— 真机上那是 binder IPC + 起进程，每次几十到几百毫秒，
  #   20 多次累计就是十几秒。而这十几秒**全是白花的**：机型在运行期间不会变。
  #
  #   什么时候真正需要重算：安装模块时（customize.sh）、OTA 之后
  #   （post-fs-data.sh 里已经有一步会重算）。
  #   所以这里只在 current_rom 缺失/为空时才补算一次。
  if [ ! -s "$MODDIR/current_rom" ]; then
    refresh_rom
  fi
  mode=$(mount_mode)
  # 记下这次实际用的 keep_lockscreen（取自 make_plan，见下面一行之后）
  KLLAST=""
  plan="$LIB/.plan.$$"
  stage="$MODDIR/.stage.$$"
  rm -rf "$MODDIR"/.stage.* 2>/dev/null
  scope=none
  GRP_LAST=""; GRP_PAIRS=""     # 多字重配对的缓存（见 grp_load）
  # .ttc 合集替换 + 替换范围的"决策记录"（诊断报告会原样打印）。
  # 为什么要有它：报告里 dump 的 fonts.xml 每行被截断到 2000 字，光看报告看不出
  # 模块到底判了哪几号 face、范围是怎么定出来的；用户发一份报告就能从源头看出对不对。
  # 真正的内容在下面 make_plan 之后写（那时才知道计划数和判定依据），这里先占位。
  : > "$LIB/ttc.log" 2>/dev/null

  if [ "$sel" != none ]; then
    # 不用 $(...)：那会开子 shell，make_plan 里设的 SCOPE_VIA（判定依据）就拿不到了
    make_plan "$sel" "$plan" >/dev/null
    scope="$PLAN_SCOPE"
    {
      echo "time=$(date '+%m-%d %H:%M:%S' 2>/dev/null) rom=$(_rom_cached) ttc=$(ttc_effective) mode=$mode sel=$sel"
      echo "plan=$(grep -c . "$plan" 2>/dev/null) scope=$scope 判定依据=${SCOPE_VIA:-?} keep_lang=$(cfg_get keep_lang 0) keep_special=$(cfg_get keep_special 0)"
    } > "$LIB/ttc.log" 2>/dev/null
    if [ ! -s "$plan" ]; then
      rm -f "$plan"
      echo "ERROR:没有找到可替换的槽位（范围：$scope）。可到设置里关闭「保留…」选项，或查看诊断报告"
      exit 1
    fi
    # ★ 2026-10-17（作者：切换必须快）：**这里不再逐个 chmod/chcon 字体文件**。
    #   字体被写进字体库时（store_font）已经设过权限和 SELinux 上下文，
    #   而 apply 只是"记录哪套字体对应哪个槽位"，根本不改字体文件本身。
    #   原来每次 apply 都要对字体跑一遍 chmod + chcon ——
    #   大字体上 chcon 要读文件属性、还可能触发 SELinux 重算，纯属浪费。

    # 1. 生成：自带挂载只需记录 槽位 -> 字体；管理器挂载要在模块里放文件（硬链接不额外占空间）
    mkdir -p "$stage"
    : > "$stage.list"
    : > "$stage.map"
    # ★ 2026-10-17：单字体时"角色 → 字体 id"是恒定映射，循环外算一次就够。
    #   组合字体（cjk+lat）才需要按角色分别取 —— 那种情况很少，走原来的路。
    if [ "${sel#*+}" = "$sel" ]; then
      _SEL_FIXED="$sel"
    else
      _SEL_FIXED=""
    fi
    while read -r role rel; do
      [ -n "$rel" ] || continue
      # ★ 单字体（不带 +）时 id 恒等于 $sel，循环外已经算好，这里直接取
      if [ -n "${_SEL_FIXED:-}" ]; then
        id="$_SEL_FIXED"
      else
        id=$(font_for_role "$sel" "$role")
      fi
      # ★ 2026-10-18（真机 20 秒 → 目标 1 秒）：**字重提到循环外算**。
      #
      #   真机实测 `apply` 20.18 秒，其中 user 19.17s、sys 只有 0.76s ——
      #   纯 CPU 时间，说明不是 I/O、不是进程开销，而是 shell 字符串计算。
      #   元凶就是下面这行 `grp_pick_for`：它每次调用要先跑 8 个字符类 case
      #   匹配（*[Tt][Hh][Ii][Nn]* 这种），而 mksh 的 glob 匹配比 bash 慢很多；
      #   151 个槽位 × 8 个模式 ≈ 1200 次匹配，累计就是十几秒。
      #
      #   关键：grp_pick_for 内部本来就有这个分支 ——
      #       case "$GRP_PAIRS" in
      #         ""|*" "*) ;;                                # 空/多个 → 走循环
      #         *) GRP_WID="${GRP_PAIRS%%:*}"; return 0 ;;   # 只有一个 → 直接用它
      #       esac
      #   也就是说"只有一个字重配对"时结果跟文件名无关。但它**仍然先算了 want**。
      #   所以这里在 grp_load 之后立刻判一次：只有一个配对 → wid 恒定，循环里零成本。
      #   （多字重字体仍然逐槽位调 grp_pick_for，行为完全不变。）
      if [ "$id" != "$GRP_LAST" ]; then
        grp_load "$id"
        GRP_LAST="$id"
        case "$GRP_PAIRS" in
          ""|*" "*) _WID_FIXED="" ;;                     # 空 或 多个 → 逐槽位算
          *) _WID_FIXED="${GRP_PAIRS%%:*}" ;;            # 只有一个 → 恒定
        esac
      fi
      if [ -n "${_WID_FIXED:-}" ]; then
        wid="$_WID_FIXED"
      else
        grp_pick_for "${rel##*/}"; wid="$GRP_WID"
      fi
      [ -n "$wid" ] && [ -f "$LIB/$wid.ttf" ] && id="$wid"
      src="$LIB/$id.ttf"
      # .ttc 合集槽位（三星简中这类，见 common.sh 的 ttc_enabled）：
      # 把用户的字体包成"和目标合集一样多 face"的 TTC 再顶替 —— 系统配置里的 index 依然有效，
      # 不用改任何系统配置。（实测 SM-S9280 / Android 16：中文能跟着变，Minikin 认 index 就够。）
      # 生成失败就跳过这个槽位、保持系统原样 —— 绝不挂一个坏文件上去。
      case "$rel" in
        *.ttc|*.TTC)
          # 生成器不在（包不完整 / 老包）→ **明确记一笔再跳过**。
          # 不这么写的话，用户看到的是"开关亮着、中文一点没变"，而报告里也看不出为什么
          # （ttc_faces_of / isnum 都在 ttcwrap.sh 里，没它连 faces 都读不出来）。
          if ! command -v ttc_wrap_mix >/dev/null 2>&1; then
            printf '%s %s via=no-generator detail=缺少 ttcwrap.sh（包不完整，请重新安装模块）\n' \
              "$id" "$rel" >> "$LIB/ttc.log" 2>/dev/null
            continue
          fi
          nf=$(ttc_faces_of "/$rel" 2>/dev/null)
          isnum "$nf" || continue
          [ "$nf" -ge 1 ] 2>/dev/null || continue
          # 合集里装着好几种字（三星：0=日 1=韩 2=简中 3=繁中），**只换中文那几号**，
          # 日/韩保留原字形 —— 否则用户的中文字体没有假名/谚文字形，日韩就变方块。
          # 注意用重定向而不是 $(...)：那会开子 shell，TTC_CN_SRC / TTC_CN_DETAIL 就丢了。
          ttc_cn_indices "${rel##*/}" "$nf" > "$LIB/.ttccn.$$" 2>/dev/null
          cn=$(tr '\n' ' ' < "$LIB/.ttccn.$$" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')
          cn_src="$TTC_CN_SRC"; cn_detail="$TTC_CN_DETAIL"
          rm -f "$LIB/.ttccn.$$" 2>/dev/null
          # 决策记录：报告里那份 fonts.xml 是被截断的，看不出代码到底怎么判的，
          # 所以这里把"换了哪几号、凭什么"写进 ttc.log，诊断报告会原样打印。
          printf '%s %s faces=%s replace=%s via=%s detail=%s\n' \
            "$id" "$rel" "$nf" "$(printf '%s' "$cn" | tr ' ' ',')" "$cn_src" "${cn_detail:-无}" \
            >> "$LIB/ttc.log" 2>/dev/null
          [ -n "$cn" ] || continue
          tag=$(printf '%s' "$cn" | tr ' ' '-')
          # ★ 2026-10-19 修（三星必踩）：产物名必须带上**源合集**的标识。
          #   原来只有 <字体id>.ttc<face数>_<序号>：
          #   NotoSansCJK-Regular.ttc 和 NotoSerifCJK-Regular.ttc 都是 5 face、
          #   中文都是 2/3 号 → 名字一模一样 → 第二份会被下面的 `-ot` 判成
          #   "已经是最新"直接复用 → 两个槽位挂的是同一份内容（宋体拿到黑体的
          #   日/韩字形，反之亦然）。沙箱里四个源合集全部指向同一个产物就是它。
          _csrc=$(printf '%s' "${rel##*/}" | sed 's/\.[^.]*$//; s/[^A-Za-z0-9]//g')
          cand="$LIB/$id.ttc${nf}_${tag}_${_csrc:-ttc}"
          # 源字体或**系统合集**比产物新，就重新生成（系统更新换了合集内容时必须重做）
          if [ ! -s "$cand" ] || [ "$cand" -ot "$src" ] 2>/dev/null || [ "$cand" -ot "/$rel" ] 2>/dev/null; then
            # 先算空间：这次要合成 = 原合集大小 + 用户字体大小。宁可这一个槽位不换，
            # 也不能把 /data 写满 —— 写满之后系统会起不来（真机反馈过强制重启后黑屏）。
            _osz=$(wc -c < "/$rel" 2>/dev/null | tr -d ' ')
            _usz=$(wc -c < "$src" 2>/dev/null | tr -d ' ')
            _free=$(free_kb "$LIB")
            if [ -n "$_osz" ] && [ -n "$_usz" ] && [ -n "$_free" ]; then
              _need=$(( (_osz + _usz) / 1024 + 8192 ))
              if [ "$_free" -lt "$_need" ] 2>/dev/null; then
                printf '%s %s faces=%s replace=空间不足跳过 via=space detail=需要%sMB只剩%sMB\n' \
                  "$id" "$rel" "$nf" "$(( _need / 1024 ))" "$(( _free / 1024 ))" >> "$LIB/ttc.log" 2>/dev/null
                echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 空间不足，跳过合集 $rel（需要约 $(( _need / 1024 ))MB，只剩 $(( _free / 1024 ))MB）" >> "$LIB/mount.log" 2>/dev/null
                continue
              fi
            fi
            # ★ 2026-10-16：**别再吞报错**。真机上"合集没生成"导致挂载一直失败，
            #   而 ttc.log 里一个字都没有 —— 因为这里原来是 2>/dev/null || cand=""，
            #   失败原因彻底丢失。现在把 stderr 第一行 + 产物大小 + 剩余空间都记下来。
            _twerr=$(ttc_wrap_mix "$src" "$nf" "$cand" "/$rel" "$cn" 2>&1)
            _twrc=$?
            [ "$_twrc" = 0 ] || cand=""
            if [ -z "$cand" ] || [ ! -s "$cand" ]; then
              _twsz=$(wc -c < "$cand" 2>/dev/null | tr -d ' ')
              _twfree=$(free_kb "$LIB")
              printf '%s %s faces=%s replace=%s via=wrapfail detail=包装器rc=%s 产物=%s字节 剩余=%sKB err=%s\n' \
                "$id" "$rel" "$nf" "$(printf '%s' "$cn" | tr ' ' ',')" \
                "${_twrc:-?}" "${_twsz:-无}" "${_twfree:-?}" \
                "$(printf '%s' "$_twerr" | head -n1 | cut -c1-80)" \
                >> "$LIB/ttc.log" 2>/dev/null
              cand=""
            fi
            # 合成后核对：文件必须真的写全（空间在合成途中被占满会留下半截文件）
            if [ -s "$cand" ] && [ -n "$_osz" ] && [ -n "$_usz" ]; then
              _got=$(wc -c < "$cand" 2>/dev/null | tr -d ' ')
              [ -n "$_got" ] && [ "$_got" -gt "$_usz" ] 2>/dev/null || cand=""
            fi
            # ★ 2026-10-14：**尺寸兜底** —— 上面那道校验只在 _osz/_usz 都非空时才生效，
            #   而 `[ -s "$cand" ]` 只要求"非空"，**16 字节也算非空**。
            #   真机上就出过这个：一加 Ace 3 Pro 的字体库里留下一个
            #   `builtin_flair.ttc5_2-3` = **16 字节**（只有 TTC 头、没有字体数据），
            #   它被当成"合成好的合集"反复拿去挂载、每次都被判"无效字体"跳过，
            #   用户看到的是"刷了不生效、切回无字体、一直转圈"。
            #   这里加一条与实现无关的硬底线：产物至少要有 1KB（真正的合集都是 MB 级），
            #   不够就是坏的 —— **删掉它**，让下次重新合成，而不是一直带着这个坏文件跑。
            if [ -n "$cand" ]; then
              _csz=$(wc -c < "$cand" 2>/dev/null | tr -d ' ')
              if ! isnum "$_csz" || [ "$_csz" -lt 1024 ] 2>/dev/null; then
                printf '%s %s faces=%s replace=%s via=toosmall detail=产物只有%s字节，已删除并跳过\n' \
                  "$id" "$rel" "$nf" "$(printf '%s' "$cn" | tr ' ' ',')" "${_csz:-?}" \
                  >> "$LIB/ttc.log" 2>/dev/null
                echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 合集产物异常（只有 ${_csz:-?} 字节，已删除）：$cand" >> "$LIB/mount.log" 2>/dev/null
                rm -f "$cand" 2>/dev/null
                cand=""
              fi
            fi
          fi
          [ -s "$cand" ] || continue
          chmod 644 "$cand" 2>/dev/null
          chcon u:object_r:system_file:s0 "$cand" 2>/dev/null
          src="$cand"
          ;;
      esac
      if [ "$mode" = manager ]; then
        # ★ 2026-10-19：/data 上的主题字体**不进 payload** ——
        #   元模块只 overlay system/product/vendor/system_ext，
        #   把 /data/... 塞进模块目录没人会挂它。这类槽位由 post-fs-data 里的
        #   datafont_apply 做物理替换（整份复制，主题服务按 inode/mtime 认）。
        case "$rel" in
          data/*) ;;
          *)
        dest="$stage/$(mgr_path "$rel")"
        mkdir -p "${dest%/*}" 2>/dev/null
        if ! ln -f "$src" "$dest" 2>/dev/null; then
          # 2. 校验：复制出来的文件必须完整
          # ★ 2026-10-19 提速：目标已存在且大小与源相同时跳过复制。
#   （内置配色 42MB，每次 apply 都重拷一遍会明显拖慢；内容没变就没必要重拷）
    _need_cp=1
    if [ -f "$dest" ] && [ -f "$src" ]; then
      if [ "$(wc -c < "$dest" 2>/dev/null | tr -d ' ')" = "$(wc -c < "$src" 2>/dev/null | tr -d ' ')" ]; then
        _need_cp=0
      fi
    fi
    if [ "$_need_cp" = "1" ] && { ! cp -f "$src" "$dest" 2>/dev/null || [ "$(wc -c < "$dest" 2>/dev/null)" != "$(wc -c < "$src" 2>/dev/null)" ]; }; then
            fail=1; break
          fi
          chmod 644 "$dest" 2>/dev/null
          chcon u:object_r:system_file:s0 "$dest" 2>/dev/null
        fi
            ;;
        esac
      fi
      echo "$rel" >> "$stage.list"
      # 第三个字段 = 这个槽位实际挂哪个文件（.ttc 槽位挂的是包好的合集；老格式只有两个字段）
      echo "$id $rel $src" >> "$stage.map"
      COUNT=$((COUNT+1))
    done < "$plan"
    rm -f "$plan"

    if [ "$fail" = 1 ] || [ "$COUNT" = 0 ]; then
      rm -rf "$stage" "$stage.list" "$stage.map"
      echo "ERROR:生成字体文件失败（存储空间不足？），已保留原来的字体"
      exit 1
    fi
  else
    # 没选字体（none）：也留一行，报告里能看出"这次是什么都没选"，而不是"记录没写"
    echo "time=$(date '+%m-%d %H:%M:%S' 2>/dev/null) rom=$(_rom_cached) ttc=$(ttc_effective) mode=$mode sel=none（未选择字体，不需要替换）" > "$LIB/ttc.log" 2>/dev/null
  fi

  # 3. 提交
  commit_payload "$stage" "$mode"
  prune_wrapped_ttc
  echo "$sel" > "$MODDIR/pending_font"
  echo "$sel" > "$LIB/last_selection"
  # ★ 2026-10-20：记下"这次应用字体时的系统构建指纹"。
  #   系统 OTA 后 /system/fonts 会被换成新版本，我们的挂载可能对不上新文件，
  #   表现就是"显示生效但字体不对"。指纹一变就在界面/报告里提示重新应用。
  getprop ro.build.fingerprint 2>/dev/null | tr -d '\r\n' > "$LIB/.fp.apply" 2>/dev/null
  [ -f "$MODDIR/active_font" ] || echo none > "$MODDIR/active_font"
  # ★ 2026-10-16（B1）：再记一份"最近一次真正生效过的字体"，放在**不会被 none 覆盖**的地方。
  #   为什么需要：升级时 customize.sh 的恢复链（last_selection → active_font → pending_font）
  #   全都可能读到 none —— 而"记录丢了"和"用户确实选了无字体"在旧代码里无法区分，
  #   于是用户的字体凭空消失（真机实测：v1.2.2 → v1.2.5 就这样）。
  #   规则：
  #     · 选的是真字体 → 写 .last_good（下次恢复时可以用它）
  #     · 选的是 none   → 删掉 .last_good（这是用户意图，不该在下次升级被"恢复"回来）
  if [ "$sel" = none ]; then
    rm -f "$LIB/.last_good" 2>/dev/null
  else
    printf '%s\n' "$sel" > "$LIB/.last_good" 2>/dev/null
  fi
  refresh_prop
  # ★ 2026-10-17：返回值后面带上"这次实际用的 keep_lockscreen"。
  #   用户反馈"切了开关没反应"时，这一项能直接分辨是"设置没写进去"还是"过滤没生效"。
  echo "OK:$(label_of "$sel"):$COUNT:$scope:$KLLAST"
}

do_report() {
  local A P id mr v
  A=$(cur_active); P=$(cur_pending)
  # 一键体检的结论放最前面（见 diag.sh）
  [ -f "$MODDIR/diag.sh" ] && sh "$MODDIR/diag.sh" brief 2>/dev/null
  echo "== 自定义字体切换模块 诊断报告 =="
  echo "模块版本: $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null) ($(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null))"
  echo "设备: $(getp ro.product.brand) $(getp ro.product.model) | Android $(getp ro.build.version.release) (SDK $(getp ro.build.version.sdk))"
  echo "系统: $(detect_rom) / $(rom_name "$(detect_rom)")"
  echo "构建号: $(getp ro.build.display.id)"
  echo "Root: $(root_manager_name "$(root_manager)")$(command -v magisk >/dev/null 2>&1 && echo " $(magisk -v 2>/dev/null)")"
  echo "内存: $(sed -n 's/^MemTotal: *//p' /proc/meminfo 2>/dev/null)  可用: $(sed -n 's/^MemAvailable: *//p' /proc/meminfo 2>/dev/null)"
  echo "---- 字体 ----"
  echo "当前生效: $(label_of "$A") ($A)"
  echo "待生效:   $(label_of "$P") ($P)"
  for id in $(sel_ids "$P"); do
    [ -f "$LIB/$id.ttf" ] || continue
    echo "  $(name_of "$id"): $(( $(wc -c < "$LIB/$id.ttf") / 1024 )) KB | 范围 $(effective_scope "$id") | 元数据 $(meta_compact "$id")"
  done
  echo "设置: keep_lang=$(cfg_get keep_lang 0) keep_special=$(cfg_get keep_special 0) mount_mode=$(mount_mode) keep_lockscreen=$(cfg_get keep_lockscreen 0)"
  echo "字体库: $(ls "$LIB"/f*.ttf 2>/dev/null | wc -l) 个，占用 $(du -sk "$LIB" 2>/dev/null | cut -f1) KB"
  echo "---- 槽位 ----"
  echo "字体目录: $(slot_dirs | tr '\n' ' ')"
  echo "字体配置: $(slot_xml_files | tr '\n' ' ')"
  echo "候选统计: $(slot_report "$MODDIR")"
  echo "已应用槽位: $(wc -l 2>/dev/null < "$APPLIED" | tr -d ' ')（方式：$(cat "$MODDIR/payload.mode" 2>/dev/null)）"
  echo "---- 挂载 ----"
  mr=$(mount_result)
  if [ -n "$mr" ]; then
    set -- $mr
    echo "本次开机自带挂载: 成功 $1 / 失败 $2（阶段 $3）"
  else
    echo "本次开机自带挂载: 未执行（无字体、管理器挂载模式，或尚未重启）"
  fi
  [ -f "$MODDIR/mount_missed" ] && echo "提示: 本次开机没有执行挂载。常见原因是 Root 管理器在开机时没有运行模块脚本（例如临时 root：重启后要重新激活的那种），也可能是模块被停用。可改用「交给管理器挂载」，或换用开机即生效的 root 方案"
  v=$(payload_verify "$MODDIR")
  echo "实际生效检测: ${v% *} / ${v#* }（待生效与当前生效不同时，重启前此项为旧状态）"
  echo "skip_mount: $([ -f "$MODDIR/skip_mount" ] && echo 有 || echo 无)"
  echo "冲突模块: $(list_conflicts | cut -d'|' -f2 | tr '\n' ' ')"
  echo "谷歌字体兼容: $(sh "$MODDIR/google_font.sh" status 2>/dev/null)"
  echo "模块目录占用: $(du -sk "$MODDIR" 2>/dev/null | cut -f1) KB"
  echo "/data 剩余: $(df -k /data 2>/dev/null | tail -n1 | tr -s ' ' | cut -d' ' -f4) KB"
  [ -f "$MODDIR/rescued" ] && echo "提示: 上次开机未完成，已触发自动恢复"
  return 0
}

case "${1:-}" in
  status)
    A=$(cur_active); P=$(cur_pending)
    echo "A=$A"
    echo "P=$P"
    echo "R=$(cat "$MODDIR/current_rom" 2>/dev/null | tr -d '[:space:]')"
    if [ -f "$MODDIR/rescued" ]; then echo "X=1"; else echo "X=0"; fi
    echo "N=$(wc -l 2>/dev/null < "$APPLIED" | tr -d ' ')"
    # ★ 2026-10-16：槽位来源拆分（界面显示「系统配置里引用的 / 本模块补充的」）
    #   由 slots.sh 的 slot_plan 在生成计划时写到 slots.sources —— 事后重建不可靠，
    #   因为"来源"只在合并候选那一刻知道。
    # ★ 2026-10-16：改成**实时算**（读 slots.map + slots.marks）。
    #   原来读 slots.sources，而那是"计划生成那一刻"的存档 —— 真机上它比
    #   slots.marks 旧，界面就显示成"系统配置里引用的 0 个"。
    if command -v slot_sources_report >/dev/null 2>&1; then
      _xss=$(slot_sources_report "$MODDIR" 2>/dev/null)
      # ★ 2026-10-17 提速：原来是 5 条 sed|head|tr 管道（15 个进程），
      #   合并成一次 awk —— 只 1 个进程，取的值完全一样。
      eval "$(printf '%s\n' "$_xss" | awk '
        /^[a-z]+=/ {
          k = substr($0, 1, index($0, "=") - 1)
          v = substr($0, index($0, "=") + 1)
          gsub(/[^0-9]/, "", v)
          if (v != "" && (k == "x" || k == "a" || k == "s" || k == "o" || k == "d"))
            printf "_%s=%s\n", (k == "s" ? "xss2" : "xs" k), v
        }')"
      if [ -n "$_xsx" ]; then
        # ★ 四路都输出（界面按这四路分别显示）
        # ★ 2026-10-16：再带上两个数（界面用它显示"模块额外补的"）
        _xextra=0; _xsym=0
        # ★ 2026-10-17 提速（作者实测 1分50秒）：
        #   **这里不再调 slot_extra_report** —— 它会扫 XML + targets + OEM 三路，
        #   只为了算"模块额外补了几个"。而界面现在显示的是「机型清单里的 / 本机扫描补的」，
        #   那两个数直接来自安装时生成的 scanned/slots.meta（见下面几行），读文件即可。
        #   保留 `extra`/`symskip` 两个字段是为了不破坏老界面的解析（值给 0 也无害）。
        # ★ 2026-10-17（新架构）：现在不再每次解析 XML，来源分成两类才有意义 ——
        #   tj = 机型清单（targets）提供的
        #   jb = 本机扫描补的（targets 没覆盖、这台设备特有的）
        _tjn=0; _tjt=0
        _mt="${LIB:-/data/adb/custom_font_lib}/scanned/slots.meta"
        [ -s "$_mt" ] && _tjn=$(sed -n 's/^targets=//p' "$_mt" 2>/dev/null)
        [ -s "$_mt" ] && _tjt=$(sed -n 's/^total=//p' "$_mt" 2>/dev/null)
        [ -n "$_tjn" ] || _tjn=0
        [ -n "$_tjt" ] || _tjt=0
        # 本机扫描补的数量直接读 extra=（安装时算好的，不用在这里做减法）
        _jbn=$(sed -n 's/^extra=//p' "$_mt" 2>/dev/null)
        case "${_jbn:-}" in ''|*[!0-9]*) _jbn=$(( ${_tjt:-0} - ${_tjn:-0} )) ;; esac
        [ "${_jbn:-0}" -lt 0 ] && _jbn=0
        echo "SP4=x=${_tjn:-0},s=${_jbn:-0},o=0,d=0,extra=${_xextra:-0},symskip=${_xsym:-0}"
        # ★ 2026-10-17：把「保留锁屏时钟」的当前值也返回给界面。
        #   界面靠它决定下次点击要写 0 还是 1；不回传的话，界面只能靠本地缓存，
        #   一旦某次没回写就会"交替失败"（用户实测过）。
        echo "KL=$(cfg_get keep_lockscreen 0)"
        echo "SP=x=${_xsx:-0},a=$(( ${_xss2:-0} + ${_xso:-0} + ${_xsd:-0} ))"
      else
        echo "SP="
        echo "SP4="
      fi
    else
      echo "SP="
    fi
    echo "S=$(effective_scope "$P" 2>/dev/null)"
    echo "M=$(mount_mode)"
    echo "PM=$(cat "$MODDIR/payload.mode" 2>/dev/null | tr -d '[:space:]')"
    echo "RM=$(root_manager)"
    echo "V=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
    # ★ 2026-10-19：把计划里的**中文合集槽位**数量也报给界面。
    #   合集槽位不在安装时扫描写下的 slots.meta 里（那份只统计单文件字体），
    #   所以「槽位总数」会比「已替换槽位」小 —— 真机上就是 151 vs 153，看着像算错。
    _ttcn=$(awk '$2 ~ /\.ttc$/ { c++ } END { print c + 0 }' "$MODDIR/slots.map" 2>/dev/null)
    case "${_ttcn:-}" in ''|*[!0-9]*) _ttcn=0 ;; esac
    echo "TT=$_ttcn"
    echo "MO=$(mount_result | tr ' ' ',')"
    echo "VF=$(payload_verify "$MODDIR" | tr ' ' ',')"
    if [ -f "$MODDIR/mount_missed" ]; then echo "MM=1"; else echo "MM=0"; fi
    # RS=1：模块因为"连续开机失败"被自动停用过（这次是用户重新启用后进来的）
    if [ -s "$LIB/rescue_stopped" ]; then echo "RS=1"; else echo "RS=0"; fi
    echo "CF=$(list_conflicts 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')"
    # FP：1 = 系统构建指纹与"上次应用字体时"不同（很可能 OTA 过）；0 = 一致；空 = 没记录
    _fpn=""
    if [ -s "$LIB/.fp.apply" ]; then
      _fpold=$(tr -d '[:space:]' 2>/dev/null < "$LIB/.fp.apply")
      _fpnow=$(getprop ro.build.fingerprint 2>/dev/null | tr -d '[:space:]')
      if [ -n "$_fpold" ] && [ -n "$_fpnow" ] && [ "$_fpold" != "$_fpnow" ]; then
        _fpn=1
      else
        _fpn=0
      fi
    fi
    echo "FP=$_fpn"
    ;;
  ack)
    rm -f "$MODDIR/rescued"
    echo "OK"
    ;;
  ack-stopped)
    rm -f "$LIB/rescue_stopped" 2>/dev/null
    echo "OK"
    ;;
  ls)
    d=$(printf '%s' "$2" | base64 -d 2>/dev/null)
    bad_path "$d" && { echo "ERROR:路径不允许"; exit 1; }
    r=$(to_real "$d")
    case "$r" in "$STORAGE"|"$STORAGE"/*) ;; *) echo "ERROR:路径不允许"; exit 1 ;; esac
    [ -d "$r" ] || { echo "ERROR:不是文件夹"; exit 1; }
    echo "P|$d"
    ls -1p "$r" 2>/dev/null | head -n 2000 | while IFS= read -r n; do
      case "$n" in ""|*'|'*) continue ;; esac
      case "$n" in
        */) echo "D|${n%/}" ;;
        *.[tT][tT][fF]|*.[oO][tT][fF]) echo "F|$n|$(stat -c %s "$r/$n" 2>/dev/null)" ;;
      esac
    done
    ;;
  list)
    # ★ 2026-10-19：**不 stat 字体文件、不启动外部命令**：
    #   尺寸取 .meta 里的 size= / outline_sz=（导入时写好的真实字节数），
    #   两个都没有就输出 0（界面显示「—」，安装时会一次性补齐）。
    #   原来用 `ls -ln` 读尺寸 —— 会对 $LIB 里每个文件 stat 一次，
    #   内置配色是 42MB 实体文件，一旦某个是失效的 bind mount 就会进 D 状态，
    #   命令永不返回 → 界面卡在「正在读取」。
    #
    # ★ 顺序（作者要求）：内置配色固定 **无色(718) → 一点红(911) → 烈焰(GT3)**，
    #   用户导入的字体排在内置配色后面。原来按文件名 glob，顺序是
    #   colon → flair → none（一点红/烈焰/无色），跟想要的正好反着。
    _emitf() {   # $1 = 字体 id
      local _id="$1" _nm="" _sz="" _mt="" _kv
      if [ -f "$LIB/$_id.name" ]; then
        IFS= read -r _nm < "$LIB/$_id.name" 2>/dev/null
      fi
      if [ -f "$LIB/$_id.meta" ]; then
        while IFS= read -r _kv; do
          [ -z "$_kv" ] && continue
          _mt="${_mt}${_mt:+,}${_kv}"
          case "$_kv" in
            size=*) _sz=${_kv#size=} ;;
            outline_sz=*) [ -z "$_sz" ] && _sz=${_kv#outline_sz=} ;;
          esac
        done < "$LIB/$_id.meta" 2>/dev/null
      fi
      case "${_sz:-}" in ''|*[!0-9]*) _sz=0 ;; esac
      _lout="${_lout}${_id}|${_nm:-$_id}|${_sz}|${_mt}
"
    }
    _lout=""
    # ① 内置配色：固定顺序
    for _bid in builtin_none builtin_colon builtin_flair; do
      [ -e "$LIB/$_bid.ttf" ] || continue
      _emitf "$_bid"
    done
    # ② 其余字体（用户导入的 f<数字>），跳过内置
    for _lf in "$LIB"/*.ttf; do
      [ -e "$_lf" ] || continue
      case "$_lf" in *'*'*) continue ;; esac
      _lid=${_lf##*/}
      case "$_lid" in
        builtin_*.ttf) continue ;;
        f[0-9]*.ttf) ;;
        *) continue ;;
      esac
      _emitf "${_lid%.ttf}"
    done
    printf '%s' "$_lout"
    ;;
  import)
    bad_path "$2" && { echo "ERROR:路径不允许"; exit 1; }
    src=$(to_real "$2")
    [ -f "$src" ] || src="$2"
    [ -f "$src" ] || { echo "ERROR:找不到文件：$2"; exit 1; }
    out=$(store_font "$src" "$3" cp); rc=$?
    echo "$out"; exit $rc
    ;;
  upload-start)
    mkdir -p "$LIB"; : > "$PART"
    echo "OK"
    ;;
  upload-finish)
    [ -f "$PART" ] || { echo "ERROR:没有待处理的上传"; exit 1; }
    if [ -n "$2" ] && [ "$(wc -c < "$PART" | tr -d ' ')" != "$2" ]; then
      rm -f "$PART"
      echo "ERROR:传输不完整，请重试（或改用「扫描」导入）"
      exit 1
    fi
    out=$(store_font "$PART" "$3" mv); rc=$?
    echo "$out"; exit $rc
    ;;
  rename)
    check_id "$2"
    [ -n "$3" ] || { echo "ERROR:名称不能为空"; exit 1; }
    printf '%s' "$(clean_name "$3")" > "$LIB/$2.name"
    refresh_prop
    echo "OK"
    ;;
  delete)
    shift
    DEL=0; SKIP=0
    for id in "$@"; do
      case "$id" in ""|*[!A-Za-z0-9_]*) continue ;; esac
      [ -f "$LIB/$id.ttf" ] || continue
      if in_use "$id"; then
        SKIP=$((SKIP+1)); continue
      fi
      rm -f "$LIB/$id.ttf" "$LIB/$id.name" "$LIB/$id.meta"
      DEL=$((DEL+1))
    done
    echo "OK:$DEL:$SKIP"
    ;;
  apply)
    do_apply "$2"
    ;;
  rescan)
    # ★ 2026-10-17：重新扫描本机字体并覆盖设备清单。
    #   什么时候用：换了系统大版本、装了新字体但界面没显示、或诊断建议你重扫。
    #   平时**不需要**跑 —— apply/reapply 只读清单，不扫描。
    if slot_build_slots "$MODDIR" 2>/dev/null; then
      _rn=$(sed -n 's/^total=//p' "$LIB/scanned/slots.meta" 2>/dev/null)
      _tn=$(sed -n 's/^targets=//p' "$LIB/scanned/slots.meta" 2>/dev/null)
      echo "OK:已重新扫描，${_rn:-?} 个字体槽位（机组清单 ${_tn:-?} + 本机补）"
    else
      echo "ERROR:扫描失败（可能是字体目录还没就绪，重启后再试）"
      exit 1
    fi
    ;;
  reapply)
    do_apply "$(cur_pending)"
    ;;
  plan)
    sel=$(check_sel "${2:-none}") || { echo "$sel"; exit 1; }
    # 同 do_apply：机型不会在运行中变化，只在缺失时补算（省十几次 getprop）
    [ -s "$MODDIR/current_rom" ] || refresh_rom
    p="$LIB/.plan.$$"
    if [ "$sel" = none ]; then : > "$p"; sc=none; else sc=$(make_plan "$sel" "$p"); fi
    echo "PLAN:$sc:$(wc -l < "$p" | tr -d ' ')"
    rm -f "$p"
    ;;
  setmeta)
    check_id "$2"
    id="$2"; shift 2
    for kv in "$@"; do
      case "$kv" in *=*) ;; *) echo "ERROR:元数据格式不正确：$kv"; exit 1 ;; esac
      meta_set "$id" "${kv%%=*}" "${kv#*=}" || { echo "ERROR:元数据格式不正确：$kv"; exit 1; }
    done
    echo "OK"
    ;;
  setmeta-many)
    # ★ 2026-10-17 新增（UI 首屏提速）：一次给多个字体写 meta。
    #   原来界面会给每个缺族键的字体单独调一次 `setmeta`，
    #   而 fontctl.sh 每次启动都要把 common.sh + slots.sh 全加载一遍 —
    #   20 个字体就是 20 次，界面卡好几秒。
    #   现在从 stdin 读多行 "id k=v k=v ..." 一次处理完。
    _n=0
    while read -r _id _kv || [ -n "$_id" ]; do
      [ -n "$_id" ] || continue
      case "$_id" in f[0-9]*|builtin_*) ;; *) continue ;; esac
      case "$_kv" in "") continue ;; esac
      for kv in $_kv; do
        case "$kv" in *=*) ;; *) continue ;; esac
        meta_set "$_id" "${kv%%=*}" "${kv#*=}" 2>/dev/null && _n=$((_n+1))
      done
    done
    echo "OK:$_n"
    ;;
  settings)
    case "$2" in
      set)
        # ★ 2026-10-17 修（用户实测：开关"交替成功"——开生效、关生效、再开不生效）：
        #   开关只影响"过滤"，而过滤的输入来自一堆缓存（候选、锁屏名单、
        #   跳过扫描判断、来源标记、extra 统计）。其中任一个停留在上一次开关的
        #   状态下被误认，过滤就会用错的输入 → 表现就是"这次切了没反应"。
        #   这里在**改开关时**把这些缓存全部清掉，强制下一次 reapply 干净重算。
        case "$3" in
          keep_lang|keep_special|keep_lockscreen)
            # ★ 2026-10-17 修（用户实测：开关"交替成功"——开生效、关生效、再开不生效）：
            #   开关只影响"过滤"，而过滤的输入来自一堆缓存（候选、锁屏名单、
            #   跳过扫描判断、来源标记、extra 统计）。其中任一个停留在上次开关的
            #   状态下被误认，过滤就会用错输入 → 表现成"这次切了没反应"。
            #   改开关时把这些缓存全清，强制下一次 reapply 干净重算。
            rm -f "$LIB/.cand.cache" "$LIB/.marks.cache" "$LIB/.skipscan.cache" \
                  "$LIB/.extra.cache" "$LIB/.xmlnames.cache" "$LIB/.dirnames.cache" \
                  "$LIB/.oemnames.cache" "$LIB/.verify.cache" 2>/dev/null
            rm -f "$LIB/.scan/lockscreen.txt" "$LIB/.scan/lockscreen.key" \
                  "$LIB/.scan/scan.cache" "$LIB/.scan/scan.key" 2>/dev/null
            rm -f "$MODDIR/slots.marks" 2>/dev/null
            # keep_lockscreen（v1.1.1 新增）：小米/红米/POCO 的锁屏时钟有专用字体，
            #   开了就保留它们（用户还能换锁屏时钟样式），其余槽位照旧全替换。
            #   判据是 family 名带 clock（见 slots.sh 的 slot_lockscreen_files），
            #   实测一台小米机认出 34 个、无一个误伤。
            case "$4" in 0|1) ;; *) echo "ERROR:取值只能是 0 或 1"; exit 1 ;; esac ;;
          theme_fonts)
            # 是否连"设置 → 字体样式"里选的字体（主题字体目录）也一起替换。
            # 默认 0：换掉它就等于盖掉用户在设置里的选择 —— 用户明确反馈过"我在设置里选的
            # 字体不该被动"。开着的好处是替换得更全（不用再去设置里切回「默认」）。
            case "$4" in 0|1) ;; *) echo "ERROR:取值只能是 0 或 1"; exit 1 ;; esac ;;
          ttc_replace)
            # auto = 交给自动判断（三星开、其它关）；界面上的开关写 0/1，写进去就是手动指定
            case "$4" in auto|0|1) ;; *) echo "ERROR:取值只能是 auto / 0 / 1"; exit 1 ;; esac ;;
          mount_mode)
            case "$4" in self|manager) ;; *) echo "ERROR:取值只能是 self 或 manager"; exit 1 ;; esac ;;
          *) echo "ERROR:未知设置项"; exit 1 ;;
        esac
        cfg_set "$3" "$4"; echo "OK"
        ;;
      *)
        # ttc_replace 回显的是**生效值**：这类机型即使没手动设过，界面开关也该是亮的
        echo "keep_lang=$(cfg_get keep_lang 0) keep_special=$(cfg_get keep_special 0) mount_mode=$(mount_mode) ttc_replace=$(ttc_effective) theme_fonts=$(cfg_get theme_fonts 0) keep_lockscreen=$(cfg_get keep_lockscreen 0) "
        ;;
    esac
    ;;
  verify)
    payload_verify "$MODDIR"
    ;;
  relink)
    # 管理器挂载模式：部分管理器更新模块时是"复制"而不是"移动"，硬链接会断开，每个槽位各占一份空间。
    # 这里把断开的重新链回字体库。自带挂载模式没有副本，不需要处理。
    n=0
    pm=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")
    [ "$pm" = manager ] && [ -s "$MODDIR/slots.map" ] || { echo "OK:0"; exit 0; }
    while read -r id rel src; do
      id_ok "$id" || continue
      case "$rel" in ""|/*|*..*) continue ;; esac
      [ -n "$src" ] || src="$LIB/$id.ttf"
      dst="$MODDIR/$(mgr_path "$rel")"
      [ -f "$dst" ] || continue
      [ "$(stat -c %i "$src" 2>/dev/null)" = "$(stat -c %i "$dst" 2>/dev/null)" ] && continue
      ln -f "$src" "$dst.tmp.$$" 2>/dev/null && mv -f "$dst.tmp.$$" "$dst" && n=$((n+1))
      rm -f "$dst.tmp.$$" 2>/dev/null
    done < "$MODDIR/slots.map"
    echo "OK:$n"
    ;;
  conflicts)
    list_conflicts
    ;;
  report)
    # 有 diag.sh 时，报告就是「一键体检」（结论在最上面 + 11 节明细）
    if [ -f "$MODDIR/diag.sh" ]; then
      if [ "$2" = save ]; then sh "$MODDIR/diag.sh" save; else sh "$MODDIR/diag.sh" full; fi
    elif [ "$2" = save ]; then
      out="/sdcard/Download/font_switcher_report.txt"
      mkdir -p /sdcard/Download 2>/dev/null
      do_report > "$out" 2>&1 && echo "OK:$out" || echo "ERROR:写入失败"
    else
      do_report
    fi
    ;;
  diag)
    if [ -f "$MODDIR/diag.sh" ]; then
      # 原样转发后面所有参数：diag bg force / diag textpage 60000 60000 / diag state ...
# （1.0.9 起不再有 fast 口径；万一旧界面传了 fast，diag.sh 会忽略它）
      shift
      [ -n "${1:-}" ] || set -- full
      sh "$MODDIR/diag.sh" "$@"
    else
      echo "ERROR:缺少 diag.sh"
    fi
    ;;
  sync)
    [ -f "$MODDIR/pending_font" ] && cp -f "$MODDIR/pending_font" "$MODDIR/active_font"
    cp -f "$MODDIR/active_font" "$LIB/last_selection" 2>/dev/null
    refresh_prop
    ;;
  prop)
    refresh_prop
    ;;
  *)
    echo "用法: sh fontctl.sh status|list|import|upload-start|upload-finish|ls|rename|delete|apply|reapply|plan|setmeta|settings|verify|relink|conflicts|report|diag|sync|prop|ack"
    exit 2
    ;;
esac
