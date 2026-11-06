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
# ★★ 2026-10-31（性能·第二轮）：**按命令分级加载**
#   一次 ksuExec 的固定开销 = 解析这些脚本；slots.sh 约 11 万字符、mount.sh 约 3 万。
#   之前除 settings 外所有命令都要把三份全解析 —— 现在按实际需要加载：
#     · 只需 common.sh：quick / list / index / ls / settings / group / import /
#       upload-* / delete / rename / setmeta* / conflicts / ack* / prop / sync /
#       relink / panic / diag（diag.sh 子进程自己加载）
#     · common + mount：status / verify（payload_verify 在 mount.sh）
#     · common + slots：plan / rescan；report 两个都要
#     · apply / reapply：common + mount，**slots 懒加载** —— 计划缓存命中时整条
#       切换路径都不解析 slots.sh（见 _ensure_slots），这是"秒切"的一部分
#   ⚠ 给函数搬家时注意：某条命令用到的函数，其所在文件必须在对应的加载名单里
#     （2026-10-31 status 分支已改为直读 slots.meta，不再依赖 slots.sh 的函数；
#       apply 的 slots.sh 走 _ensure_slots 懒加载）。
_LOAD_SLOTS=""; _LOAD_MOUNT=""
case "${1:-}" in
  plan|rescan)            _LOAD_SLOTS=1 ;;
  report)                 _LOAD_SLOTS=1; _LOAD_MOUNT=1 ;;
  status|verify|apply|reapply) _LOAD_MOUNT=1 ;;
esac
[ -f "$MODDIR/common.sh" ] || { echo "ERROR:模块文件缺失（common.sh）—— 请重新安装模块"; exit 3; }
. "$MODDIR/common.sh"
if [ -n "$_LOAD_SLOTS" ]; then
  [ -f "$MODDIR/slots.sh" ] || { echo "ERROR:模块文件缺失（slots.sh）—— 请重新安装模块"; exit 3; }
  . "$MODDIR/slots.sh"
fi
if [ -n "$_LOAD_MOUNT" ]; then
  [ -f "$MODDIR/mount.sh" ] || { echo "ERROR:模块文件缺失（mount.sh）—— 请重新安装模块"; exit 3; }
  . "$MODDIR/mount.sh"
fi
unset _mf _LOAD_SLOTS _LOAD_MOUNT
# ttcwrap.sh（.ttc 合集生成器）是**可选**的：老包/不完整包里可能没有。
# 缺了只是"合集替换"这条功能不可用，绝不能让整个 fontctl 退出 ——
# apply 里会为这种槽位记一笔 via=no-generator（见下面的 .ttc 分支）。
[ -f "$MODDIR/ttcwrap.sh" ] && . "$MODDIR/ttcwrap.sh"
mkdir -p "$LIB" 2>/dev/null
export TMPDIR="$LIB"

APPLIED="$MODDIR/slots.applied"
MODID=$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
[ -n "$MODID" ] || MODID=custom_font_switcher

# 旧版把设置放在模块目录（升级会被覆盖），迁移到字体库目录
[ -f "$SETTINGS" ] || { [ -f "$MODDIR/settings.conf" ] && cp -f "$MODDIR/settings.conf" "$SETTINGS" 2>/dev/null; }

# ---- 字体元数据：$LIB/<id>.meta，每行 key=value ----
meta_get() { sed -n "s/^$2=//p" "$LIB/$1.meta" 2>/dev/null | tail -n1 | tr -d '\r\n'; }
meta_set() {
  local tmp="$LIB/$1.meta.tmp.$$"
  case "$2" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
  # ★ 2026-10-21 修：原来值只允许 [A-Za-z0-9_.-]，于是 family="方正悠黑 Google VF"
  #   这种带空格/中文的值**静默写不进去** → 字组校验读不到族名原文，等于没校验。
  #   现在只挡控制字符（换行/制表等）和超长，其余可打印字符都允许。
  case "$3" in *[![:print:]]*) return 1 ;; esac
  [ ${#3} -le 120 ] || return 1
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
  # ★ 2026-10-31：stat 只读元数据（原来 wc -c 把整个字体读一遍只为量大小）
  sz=$(stat -c %s "$f" 2>/dev/null | tr -d ' ')
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
    # ★ 2026-11-03：CFF2（可变 CFF，OTTO 容器）—— 之前只认 "CFF "，CFF2 会被误判"没有轮廓表"
    [ "$1" = 67 ]  && [ "$2" = 70 ]  && [ "$3" = 70 ]  && [ "$4" = 50 ]  && tag=cff
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
      # ★ 2026-10-21 修：这里原来在"大小相同"时直接 return 1（判成没有轮廓），
      #   一旦 meta 里的 outline 被别的写入方改成了非 0/1 的值（例如 "glyf"），
      #   就会把**好字体**判成空壳，应用时报「没有任何字形轮廓」。
      #   现在大小一致就让它落下去真读一遍表目录（权威结论），
      #   读到的结果会重新写回 outline=0/1。
      :
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
    _hosz=$(stat -c %s "$f" 2>/dev/null | tr -d ' \t\r')
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
  # ★ 2026-10-31（性能）：不再对 dst 再跑一遍 valid_font ——
  #   函数开头已经验过 src（不通过早返回了），而 dst 是刚复制/改名出来的同一份
  #   （cp 模式在上面已核对过字节数一致）。结论必然相同，直接复用：
  #   导入省一整遍字体表校验。
  _sf_ho=1
  if [ -s "$LIB/$id.meta" ]; then
    _sf_tmp="$LIB/$id.meta.tmp.$$"
    { grep -v '^outline=\|^outline_sz=' "$LIB/$id.meta" 2>/dev/null
      echo "outline=$_sf_ho"
      echo "outline_sz=$_sf_sz"
    } > "$_sf_tmp" 2>/dev/null && mv -f "$_sf_tmp" "$LIB/$id.meta" 2>/dev/null
  else
    # ★ 2026-10-18：顺便把文件大小也记进 meta —— list 直接读，不用再 stat
    _sf_bytes=$(stat -c '%s' "$LIB/$id.ttf" 2>/dev/null | tr -dc '0-9')
    { printf 'size=%s\n' "${_sf_bytes:-0}"
      printf 'outline=%s\noutline_sz=%s\n' "$_sf_ho" "$_sf_sz"
    } > "$LIB/$id.meta" 2>/dev/null
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
  klk=$(keep_lockscreen_val)
  KLLAST="kl=$klk"      # 给 do_apply 的返回值用（诊断用，看模块实际读到几）
  # 1.0.9：界面已删掉那两个开关（默认全替换）；保留读取只为兼容老配置文件。
  SEL_FONT="$sel"            # 给 slot_plan/_meta_have 用：拿这个字体的 meta 判字形覆盖
  # 极端保护：字体完全没有中文字形 → 中文槽位一个都不动
  # （否则整个界面会变方块，用户连 WebUI 都看不清、没法换回来）。正常字体不会命中。
  CJK_GUARD=0
  if [ -f "$LIB/$sel.meta" ]; then
    _cjk_flag=$(sed -n 's/^cjk=//p' "$LIB/$sel.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')
    _cjk_rate=$(sed -n 's/^rate_cjk=//p' "$LIB/$sel.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')
    case "$_cjk_rate" in ''|*[!0-9]*) _cjk_rate="" ;; esac
    if [ "$_cjk_flag" = 0 ]; then
      CJK_GUARD=1
    elif [ -n "$_cjk_rate" ] && [ "$_cjk_rate" -lt 98 ]; then
      # ★ 2026-10-21：中文字形覆盖率不足 98% 时**不动中文槽位**。
      #   原来只要求 cjk=1（≥90%），剩下那几个百分点到了某些 App 里就是「口口口」方块
      #   （真机反馈：Play 商店中文出现方块）。宁可少换几个槽位，也不能让系统里出现方块。
      CJK_GUARD=1
      SCOPE_NOTE="中文字形覆盖率 ${_cjk_rate}% < 98%，中文槽位保持原厂（避免方块）"
    fi
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
#
# ★ 2026-10-21（作者要求：怕混挂不同字体导致缺字 / 开不了机）：
#   同族配对**默认关闭**（cfg pair_family=0）。每份字体各自独立，不自动组族。
#   想用的人需要在设置里显式打开；打开后依然逐份校验，只配"确实像同一套字体的不同字重"：
#     · 轮廓可用（outline=1）
#     · 同一 upem
#     · 语种覆盖类别一致（cjk / latin 标记相同）
#     · 字形数量相差不超过 20%（防止把"只有拉丁的粗体"配进中文族）
#   任何一条不满足 → 跳过该成员并写日志，绝不硬配。
grp_load() {
  local leader="$1" id w
  GRP_PAIRS="$leader:$(meta_get "$leader" wght)"
  # ★ 2026-10-22：只认**手动字重组**（meta 里有 group=）。
  #   原来还有一个"按族名自动配对"的分支（cfg pair_family），已删除：
  #   族名相同的字体不一定是同一套，混挂会缺字/方块，甚至开不了机；
  #   而字重组是用户明确勾选 + 五道校验，安全得多。
  _grp=$(meta_get "$leader" group)
  [ -n "$_grp" ] || return 0
  case "$_grp" in ""|none) return 0 ;; esac
  for id in $(lib_font_ids); do
    [ "$id" = "$leader" ] && continue
    [ -f "$LIB/$id.meta" ] || continue
    [ "$(meta_get "$id" group)" = "$_grp" ] || continue
    w=$(meta_get "$id" wght)
    GRP_PAIRS="$GRP_PAIRS $id:$w"
  done
  return 0
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

# ---------------------------------------------------------------------------
# ★ 2026-10-31（manager 专用·单点翻转）：**符号链接 payload + .active 间接层**
#   目标：manager 挂载下切换字体从「154 次硬链接」降到「1~3 次翻转」。
#   结构：
#     模块目录槽位文件 = 符号链接 → $LIB/.active/<n>（稳定名，n = 计划内
#                        该源首次出现的序号，跨字体稳定）
#     $LIB/.active/<n> = 指向当前字体的硬链接
#   切字体：对每个 n，若 .active/<n> 的 inode ≠ 新计划的 src → ln -f 翻转
#   （单字体计划 = 1 次翻转）。payload 符号链接**从不重建**（布局签名一致时零操作）。
#   风险与回退：依赖管理器挂载跟随符号链接（bind mount 会解析路径）；
#   若重启后字体没变，高级设置 → 挂载方式 → 关闭「符号链接 payload」再应用一次即回旧行为。
# ---------------------------------------------------------------------------
_symlink_on() {
  # ★ 2026-10-31（真机结论）：默认**关** —— 符号链接 payload 在用户的
  #   Hybrid Mount 链路上卡开机 2 屏（挂载器早期暂存不跟随符号链接，
  #   悬空链接 → 框架读字体失败）。代码保留作实验开关，默认走 v18 硬链接。
  [ "$(cfg_get symlink_payload 0 2>/dev/null)" = 1 ]
}

_mgr_symlink_apply() {   # $1=map 文件（id rel src）→ 0=成功
  local _mapf="$1" _cls _newsig _sig
  [ -s "$_mapf" ] || return 0
  mkdir -p "$LIB/.active" 2>/dev/null
  _cls="${TMPDIR:-/data/local/tmp}/.pw.cls.$$"
  # class 表：src 在 map 顺序里首次出现 → 编号；并生成 payload 布局签名
  awk '{ if (!($3 in S)) { S[$3] = ++N } print $1 "|" $2 "|" $3 "|" S[$3] }' "$_mapf" \
    > "$_cls" 2>/dev/null || { rm -f "$_cls"; return 1; }
  _newsig=$(awk -F'|' '{ print $2 "|" $4 }' "$_cls" 2>/dev/null | md5sum 2>/dev/null | awk '{ print $1 }')
  _sig=$(cat "$MODDIR/.payload_links" 2>/dev/null)
  # ② 翻转间接文件：每个 class 的 .active/<n> → 该 class 的 src（内容变了才动，1~3 次）
  awk -F'|' '{ print $4, $3 }' "$_cls" 2>/dev/null | sort -u -k1,1 | while read -r _n _src; do
    [ -n "$_n" ] && [ -n "$_src" ] || continue
    if [ "$(stat -c %i "$LIB/.active/$_n" 2>/dev/null)" != "$(stat -c %i "$_src" 2>/dev/null)" ]; then
      ln -f "$_src" "$LIB/.active/$_n" 2>/dev/null || cp -f "$_src" "$LIB/.active/$_n" 2>/dev/null
    fi
  done
  # ③ payload 符号链接：布局签名一致 → 全部已就位（零操作）
  if [ "$_sig" = "$_newsig" ] && [ -s "$MODDIR/.payload_links" ]; then
    rm -f "$_cls"
    return 0
  fi
  # 布局变了 / 首次 → 逐槽位建符号链接（每个布局只发生一次）
  while IFS='|' read -r _id _rel _src _n; do
    [ -n "${_rel:-}" ] || continue
    case "$_rel" in data/*) continue ;; esac
    _dest="$MODDIR/$(mgr_path "$_rel")"
    _want="$LIB/.active/$_n"
    mkdir -p "${_dest%/*}" 2>/dev/null
    [ "$(readlink "$_dest" 2>/dev/null)" = "$_want" ] && continue
    if ! ln -sfn "$_want" "$_dest" 2>/dev/null; then
      echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 符号链接失败 $_dest -> $_want" \
        >> "$LIB/ttc.log" 2>/dev/null
      rm -f "$_cls"
      return 1
    fi
  done < "$_cls"
  printf '%s' "$_newsig" > "$MODDIR/.payload_links" 2>/dev/null
  rm -f "$_cls"
  return 0
}

# 提交：用已生成好的 stage 替换旧的字体文件 / 槽位记录
# ---------------------------------------------------------------------------
# ★ 2026-11-01（第二轮提速）：批量并行物化硬链接
#   为什么：每槽位一次 ln = 154 个串行 fork ≈ 5 秒（fork 本身 25~40ms）。
#   _ACC_LN 里每行是一条 `ln -f '源' '目标' || echo 目标 >> 失败记录`，
#   每 10 条插一个 wait 控制同时存活的进程数（154 个全并行是 fork 风暴），
#   整个批次用一个 `sh 脚本` 跑完 —— 154 个槽位从 ~5 秒降到 ~1 秒。
#   调用前：调用方已 `: > 失败记录文件`，并把文件路径烤进每行命令里。
#   结果：_LN_FAILN = 失败条数（调用方据此 fail=1 并记日志）。
# ---------------------------------------------------------------------------
_ln_batch_run() {   # _ln_batch_run <失败记录文件>
  _LN_FAILN=0
  [ -n "${_ACC_LN:-}" ] || return 0
  printf '%s' "${_ACC_LN}wait
" > "$LIB/.lnbatch.$$" 2>/dev/null
  sh "$LIB/.lnbatch.$$" 2>/dev/null
  _LN_FAILN=$(wc -l 2>/dev/null < "$1" | tr -d ' ')
  case "${_LN_FAILN:-}" in ''|*[!0-9]*) _LN_FAILN=0 ;; esac
  rm -f "$LIB/.lnbatch.$$" 2>/dev/null
  return 0
}

commit_payload() {
  local stage="$1" mode="$2" old_mode f
  old_mode=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")
  # 管理器模式的旧文件，以及旧版遗留的直接放在模块根目录的旧链接
  # ★ 2026-10-31：MANAGER_INPLACE=1 = 物化已直接写进模块目录（且已按差集清理过
  #   旧副本）→ 跳过 remove_manager_files，否则会把刚物化的文件删掉
  [ "$old_mode" = self ] || [ "${MANAGER_INPLACE:-0}" = 1 ] || remove_manager_files
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
  # ★ 2026-10-19：覆盖前备份上一份计划。
    #   切「保留锁屏时钟」会让计划变少（151 → 119），少掉的正是时钟槽位；
    #   软重启时按差集撤掉这些槽位，才不会"显示成功但时钟还是被换掉"。
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


# ---------------------------------------------------------------------------
# ★ 2026-10-21：TTC 产物结构校验
#   为什么：合集的每个 face 都要能被应用按 index 取到。生成器出过"文件大小够、
#   但某个 face 的偏移/表目录不合法"的情况 —— 应用一读就崩（真机表现为
#   Google 系应用打开即闪退，普通应用却正常）。
#   这里做最低限度的硬校验：ttcf 魔数、face 数、每个 face 的偏移与 sfntVersion。
#   **校验不过就跳过该槽位**（保留原厂合集），宁可少换也不让应用崩。
# ---------------------------------------------------------------------------
_ttc_u32() {   # _ttc_u32 <file> <offset> → 十进制
  od -An -tu1 -j "$2" -N 4 "$1" 2>/dev/null | tr -s ' \n' ' ' | sed 's/^ //;s/ $//' |
  awk '{ if (NF >= 4) printf "%.0f", (($1*256+$2)*256+$3)*256+$4; else print "" }'
}

_ttc_hex() {   # _ttc_hex <file> <offset> → 8 位十六进制（比十进制魔数不容易算错）
  od -An -tu1 -j "$2" -N 4 "$1" 2>/dev/null | tr -s ' \n' ' ' | sed 's/^ //;s/ $//' |
  awk '{ if (NF >= 4) printf "%02x%02x%02x%02x", $1, $2, $3, $4; else print "" }'
}

ttc_verify() {   # ttc_verify <file> <expected_faces>
  local f="$1" want="$2" magic cnt sz i off ver bad=0
  [ -s "$f" ] || return 1
  # ★ 2026-10-31：stat 只读元数据（原来 wc -c 把整个合集从头到尾读一遍）
  sz=$(stat -c %s "$f" 2>/dev/null)
  [ -n "$sz" ] || return 1
  magic=$(_ttc_hex "$f" 0)
  # "ttcf" = 0x74746366
  [ "$magic" = "74746366" ] || return 1
  cnt=$(_ttc_u32 "$f" 8)
  case "$cnt" in ''|*[!0-9]*) return 1 ;; esac
  [ "$cnt" -ge 1 ] || return 1
  # face 数量必须与原厂一致（少一个都说明生成不完整）
  if [ -n "$want" ] && [ "$want" -gt 0 ] 2>/dev/null && [ "$cnt" -ne "$want" ]; then
    echo "faces=$cnt≠原厂$want"
    return 1
  fi
  i=0
  while [ "$i" -lt "$cnt" ]; do
    off=$(_ttc_u32 "$f" $(( 12 + i * 4 )))
    case "$off" in ''|*[!0-9]*) bad=1; break ;; esac
    # 偏移必须落在文件内、且留够 12 字节表头
    if [ "$off" -lt 12 ] || [ $(( off + 12 )) -gt "$sz" ]; then bad=1; break; fi
    ver=$(_ttc_hex "$f" "$off")
    # 00010000（TrueType）/ 4f54544f（OTTO）/ 74727565（true）
    case "$ver" in 00010000|4f54544f|74727565) ;; *) bad=1; break ;; esac
    i=$(( i + 1 ))
  done
  [ "$bad" = 1 ] && { echo "face$i 偏移或版本非法"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# ★ 2026-10-30（性能）：**计划缓存** —— 同一字体 + 同一组开关的切换直接读上次的计划
#
#   背景：刷入时已经把"槽位清单"预生成好（scanned/slots.*.list），但每次 apply
#   仍要现场做 scope 过滤 + 逐行过滤 + 写 stage.map（真机 150~400 行）。
#   而绝大多数用户的实际情况是：字体不变、开关不变，每次结果都一样。
#   把"最终计划"按 (字体 × 设置指纹 × 清单指纹) 缓存下来，命中就直接用 —— 切换才能秒级。
#
#   失效是**全自动**的（key 里含全部指纹，任何一项变了就等于换了一把钥匙）：
#     · settings.conf 内容（cksum）        → 改任何开关都换 key
#     · slots.list / slots.kl1/th1 清单    → 重扫 / 升级后换 key
#     · $LIB/*.meta 全体（含 sel 自己）    → setmeta / 删除字体 / 重新探测后换 key
#     · slots.sh 的 mtime                  → 升级模块（扫描逻辑变了）换 key
#     · $CFS_NO_TTC                        → 开机自愈的"轻量 apply"单独一把钥匙，
#                                            不会污染正常 apply 的缓存
#     · 挂载模式                           → manager 模式要实体文件，直接不参与缓存
#
#   安全底线：命中后逐行核对计划引用的每个源文件还在（test -f 是内建，零进程）；
#   .ttc 产物被 prune 清掉过、或文件被外部动过 → 任一缺失就回退完整生成路径。
# ---------------------------------------------------------------------------
# ★ 2026-10-31：apply 的 slots.sh 懒加载 —— 计划缓存命中时用不到它，别提前解析
#   （11 万字符的解析开销，真机上每次都要花掉零点几秒）
#   ttcwrap.sh（.ttc 合集生成器，可选）也在这里一起懒加载：
#   只有"缓存未命中且计划里有 .ttc 槽位"时才真正用到它；
#   包不完整缺它时 apply 会按 via=no-generator 跳过合集槽位（原有行为，不变）。
_ensure_slots() {
  command -v slot_plan >/dev/null 2>&1 && return 0
  [ -f "$MODDIR/slots.sh" ] || { echo "ERROR:模块文件缺失（slots.sh）—— 请重新安装模块"; exit 3; }
  . "$MODDIR/slots.sh"
  [ -f "$MODDIR/ttcwrap.sh" ] && . "$MODDIR/ttcwrap.sh"
  return 0
}

plan_cache_key() {   # $1=sel（调用方须已算好 $EFF_SCOPE）
  # ★ 2026-10-31 重写：**不再依赖 cksum** —— 部分系统的 toybox/toolbox 没有它，
  #   之前那种情况下 key 永远算不出来 → 缓存**静默永不命中**（真机"切 A 再切 A 还是慢"
  #   的头号嫌疑）。现在全部用 stat（哪里都有）+ 纯 shell 求和，key 是一行短文本。
  # ① meta 指纹：**只算「影响计划」的字段**（scope/latin/cjk/rate_cjk/hant/group）——
  #    计划依赖的就是这几项；族名/upem/子族名/其它覆盖率是展示性数据，
  #    UI 的 backfillFam/探测每个会话都会补写 → 旧版整份 meta 做指纹
  #    → 每个会话钥匙必变（真机 ttc.log 实锤：28bf4571 → 700e1cb5）。
  #    组字重时成员的 wght/vf 也参与判定 → 一并算入。
  _pc_mf=$(sed -n -e 's/^scope=//p' -e 's/^latin=//p' -e 's/^cjk=//p' \
                -e 's/^rate_cjk=//p' -e 's/^hant=//p' -e 's/^group=//p' \
                "$LIB/$1.meta" 2>/dev/null | md5sum 2>/dev/null | awk '{ printf "%s", substr($1, 1, 8) }')
  _pc_grp=$(sed -n 's/^group=//p' "$LIB/$1.meta" 2>/dev/null | tail -n1 | tr -d '\r')
  if [ -n "$_pc_grp" ]; then
    for _pmf in "$LIB"/*.meta; do
      [ -f "$_pmf" ] || continue
      grep -q "^group=$_pc_grp" "$_pmf" 2>/dev/null || continue
      _pc_mf="$_pc_mf$(sed -n -e 's/^wght=//p' -e 's/^vf=//p' "$_pmf" 2>/dev/null | md5sum 2>/dev/null | awk '{ printf "%s", substr($1, 1, 8) }')"
    done
  fi
  case "${_pc_mf:-}" in
    '') _pc_mf="nometa" ;;   # meta 不存在 / 无 md5sum → 常量（与老字体行为一致）
  esac
  # ② 设置指纹：**按「影响计划的开关值」算，不按文件内容算** ——
  #    旧版两版都在这翻车：mtime 版（每拨一次开关重写文件 → 钥匙必变）
  #    和内容 md5 版 —— cfg_set 重写文件会把键**挪到文件末尾**，
  #    拨开→关→开之后"值全一样但文件内容回不去" → 所有字体的钥匙永久换锁
  #    （真机实锤：开关 A→B→A 一次之后，切字体 3 秒 → 8 秒）。
  #    现在只取计划真正依赖的那几个开关的**值**，格式/顺序怎么变都无所谓；
  #    这些键全走 cfg_get 的内存缓存（本进程首次读盘一次，之后零进程）。
  _pc_ssv="$(cfg_get keep_lang 0),$(cfg_get keep_special 0),$(keep_lockscreen_val),$(cfg_get keep_samsung 0),$(cfg_get skip_product 0),$(cfg_get skip_vf 0),$(cfg_get theme_fonts 0),$(cfg_get ttc_replace 0),$(cfg_get ttc_no_mix 0),$(cfg_get ttc_all_faces 0),$(cfg_get main_only 0)"
  _pc_ss=$(printf '%s' "$_pc_ssv" | md5sum 2>/dev/null | awk '{ printf "%s", substr($1, 1, 8) }')
  case "${_pc_ss:-}" in '') _pc_ss="nosettings" ;; esac
  # ③ 槽位清单（**内容哈希进 key**）+ 脚本版本。
  #    ★ 2026-10-31：slots.sh 只取**大小**不取 mtime —— 模块目录每次刷入都是新的，
  #    mtime 必变，会把缓存钥匙搅乱；大小在同版本内是稳定的，脚本真改了大小才会变。
  #    ★ 清单用 **md5 内容哈希** 而不是 mtime —— 刷入/重扫会"删了重建"这些文件，
  #    mtime 必变但内容不变；哈希只认内容：内容一样 = 钥匙一样 = 缓存跨刷入命中。
  _pc_sl=$(stat -c '%s' "$MODDIR/slots.sh" 2>/dev/null)
  _pc_sl2=$(md5sum "$LIB/scanned/slots.list" "$LIB/scanned/slots.kl1.list" \
                 "$LIB/scanned/slots.th1.list" "$LIB/scanned/slots.kl1th1.list" 2>/dev/null \
            | awk '{ printf "%s", substr($1, 1, 8) }')
  case "${_pc_sl2:-}" in
    '') # md5sum 不可用（极老系统）→ 退回 mtime（老行为）
      _pc_sl2=$(stat -c '%Y' "$LIB/scanned/slots.list" \
                    "$LIB/scanned/slots.kl1.list" "$LIB/scanned/slots.th1.list" \
                    "$LIB/scanned/slots.kl1th1.list" 2>/dev/null | tr '\n' '+') ;;
  esac
  _pc_sl="${_pc_sl%+}"
  # ④ 拼成 key（sel/scope/轻量apply标志/挂载模式 都是语义维度，直接进 key）
  printf 'p%s.%s.%s.%s.%s.%s.%s.%s' \
    "$1" "${EFF_SCOPE:-}" "${CFS_NO_TTC:-0}" "$(mount_mode 2>/dev/null)" \
    "${_pc_ss// /-}" "$_pc_sl" "${_pc_sl2%+}" "$_pc_mf"
}

plan_cache_lookup() {   # $1=sel $2=stage.map $3=stage.list → 命中置 PC_* 并 return 0
  PC_SCOPE=""; PC_COUNT=""; PC_KLLAST=""; PC_HIT=0
  # ★ 2026-10-31：manager 挂载也参与缓存 —— 计划本身与挂载方式无关；
  #   manager 命中后只做轻量物化（硬链接副本），重算计划/合成合集全省掉。
  case "$(mount_mode 2>/dev/null)" in self|manager) ;; *) return 1 ;; esac
  local _d _k _map _hdr _miss=0 _pid _rel _src
  _d="$LIB/.plancache"
  _k=$(plan_cache_key "$1")
  [ -n "$_k" ] || return 1
  _map="$_d/$_k.map"; _hdr="$_d/$_k.hdr"
  # ★ 2026-10-31：钥匙留痕（ttc.log）——save/lookup 各记一行，
  #   两次钥匙一对比，哪个分量变了直接看得到（sel/设置/清单/档案逐段可读）
  printf 'plancache lookup sel=%s key=%s\n' "$1" "$_k" >> "$LIB/ttc.log" 2>/dev/null
  [ -s "$_map" ] && [ -s "$_hdr" ] || return 1
  # 逐行核对源文件还在（while + 内建 test，零进程）
  while read -r _pid _rel _src; do
    [ -n "${_rel:-}" ] || continue
    [ -n "${_src:-}" ] || _src="$LIB/$_pid.ttf"
    [ -f "$_src" ] || { _miss=1; break; }
  done < "$_map"
  [ "$_miss" = 0 ] || return 1
  # ★ 2026-10-31：头文件解析改零进程（原来 3 条 sed 管道 = 6 个进程）
  while IFS='=' read -r _hk _hv; do
    case "${_hk:-}" in
      scope)  PC_SCOPE="$_hv" ;;
      count)  PC_COUNT="$_hv" ;;
      kllast) PC_KLLAST="$_hv" ;;
    esac
  done < "$_hdr" 2>/dev/null
  case "$PC_SCOPE" in all|latin|cjk|combo) ;; *) return 1 ;; esac
  case "$PC_COUNT" in ''|*[!0-9]*) return 1 ;; esac
  # ★ 2026-10-31：临时文件 + mv 原子落位（预热和 apply 可能并发写同一个目标）
  cp -f "$_map" "$2.tmp.$$" 2>/dev/null && mv -f "$2.tmp.$$" "$2" 2>/dev/null || \
    { rm -f "$2.tmp.$$" 2>/dev/null; return 1; }
  cp -f "$_d/$_k.list" "$3.tmp.$$" 2>/dev/null && mv -f "$3.tmp.$$" "$3" 2>/dev/null || \
    { rm -f "$3.tmp.$$" 2>/dev/null; return 1; }
  [ -s "$2" ] && [ -s "$3" ] || return 1
  PC_HIT=1
  return 0
}

plan_cache_save() {   # $1=sel $2=stage.map $3=stage.list $4=scope $5=kllast $6=count
  # ★ 2026-10-31：manager 挂载也存（计划与挂载方式无关，见 lookup 的说明）
  case "$(mount_mode 2>/dev/null)" in self|manager) ;; *) return 0 ;; esac
  [ -s "$2" ] && [ -s "$3" ] || return 0
  local _d _k
  _d="$LIB/.plancache"
  _k=$(plan_cache_key "$1")
  [ -n "$_k" ] || return 0
  mkdir -p "$_d" 2>/dev/null || return 0
  printf 'plancache save sel=%s key=%s\n' "$1" "$_k" >> "$LIB/ttc.log" 2>/dev/null
  # ★ 2026-10-31：全部 tmp + mv 原子写（两个进程同时保存同一 key 时不会写坏）
  cp -f "$2" "$_d/$_k.map.tmp.$$" 2>/dev/null && \
    mv -f "$_d/$_k.map.tmp.$$" "$_d/$_k.map" 2>/dev/null || \
    { rm -f "$_d/$_k.map.tmp.$$" 2>/dev/null; return 0; }
  cp -f "$3" "$_d/$_k.list.tmp.$$" 2>/dev/null && \
    mv -f "$_d/$_k.list.tmp.$$" "$_d/$_k.list" 2>/dev/null || \
    { rm -f "$_d/$_k.list.tmp.$$" 2>/dev/null; return 0; }
  { printf 'scope=%s\nkllast=%s\ncount=%s\nsel=%s\n' "$4" "$5" "$6" "$1"; } \
    > "$_d/$_k.hdr.tmp.$$" 2>/dev/null && \
    mv -f "$_d/$_k.hdr.tmp.$$" "$_d/$_k.hdr" 2>/dev/null
  # 只留最近 12 份，防止换字体频繁时占空间（一份就几十 KB）
  ls -1t "$_d"/*.map 2>/dev/null | tail -n +13 | while IFS= read -r _old; do
    [ -n "$_old" ] || continue
    rm -f "${_old%.map}.map" "${_old%.map}.list" "${_old%.map}.hdr" 2>/dev/null
  done
  return 0
}

do_apply() {
  # ★ 2026-11-06：记录切换历史（诊断报告【22】会显示）
  printf '%s %s%s\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "${1:-?}" "${CFS_PREWARM:+ (prewarm)}" >> "${LIB:-/data/adb/custom_font_lib}/switch.log" 2>/dev/null
  local sel scope plan role rel id src dest stage mode COUNT=0 fail=0 wid
  GRP_LAST=""; GRP_PAIRS=""     # 多字重配对的缓存（见 grp_load）
  sel=$(check_sel "$1") || { echo "$sel"; exit 1; }
  # ★ 2026-10-31 计时基准（/proc/uptime，10ms 精度；结果写进 ttc.log 和 OK 返回行，
  #   用户切完字立刻能在提示里看到「应用耗时 X 秒」—— 慢不慢用数据说话）
  _cfs_t0=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | tr -d ' ')

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
  if [ -f "$LIB/$sel.ttf" ] && ! has_outline "$LIB/$sel.ttf"; then
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
  # ★ 2026-11-06（真机：开关主题字体时报 can't open .stage.<pid>.map）：
  #   打开/关闭开关会同时拉起 rescan / apply / prewarm 多个 fontctl，
  #   原来的 `rm -rf $MODDIR/.stage.*` 会把**别的进程正在用的** stage 一起删掉。
  #   现在只清理「对应 pid 已经不在了」的旧 stage。
  mkdir -p "$stage" 2>/dev/null
  for _sd in "$MODDIR"/.stage.*; do
    [ -e "$_sd" ] || continue
    [ "$_sd" = "$stage" ] && continue
    _spid=${_sd##*/.stage.}
    case "$_spid" in ''|*[!0-9]*) rm -rf "$_sd" 2>/dev/null; continue ;; esac
    kill -0 "$_spid" 2>/dev/null || rm -rf "$_sd" 2>/dev/null
  done
  scope=none
  GRP_LAST=""; GRP_PAIRS=""     # 多字重配对的缓存（见 grp_load）
  # .ttc 合集替换 + 替换范围的"决策记录"（诊断报告会原样打印）。
  # 为什么要有它：报告里 dump 的 fonts.xml 每行被截断到 2000 字，光看报告看不出
  # 模块到底判了哪几号 face、范围是怎么定出来的；用户发一份报告就能从源头看出对不对。
  # 真正的内容在下面 make_plan 之后写（那时才知道计划数和判定依据），这里先占位。
  # ★ 2026-10-31：预热模式不清空 ttc.log —— 那是"上次真正 apply"的诊断记录，
  #   预热只是后台补缓存，别把证据洗掉（预热自己的行带 tag=prewarm）。
  [ "${CFS_PREWARM:-0}" = 1 ] || : > "$LIB/ttc.log" 2>/dev/null

  if [ "$sel" != none ]; then
    # ★ 2026-10-30（性能）：先查计划缓存 —— 同一字体 + 同一组开关直接复用上次结果
    _eff_scope "$sel"
    scope="$EFF_SCOPE"
    if plan_cache_lookup "$sel" "$stage.map" "$stage.list"; then
      scope="$PC_SCOPE"
      COUNT="$PC_COUNT"
      KLLAST="$PC_KLLAST"
      SCOPE_VIA="计划缓存命中（同字体同开关，直接复用上次结果）"
      {
        echo "time=$(date '+%m-%d %H:%M:%S' 2>/dev/null) rom=$(_rom_cached) ttc=$(ttc_effective) mode=$mode sel=$sel${CFS_PREWARM:+ tag=prewarm}"
        echo "plan=$COUNT scope=$scope 判定依据=${SCOPE_VIA:-?} keep_lang=$(cfg_get keep_lang 0) keep_special=$(cfg_get keep_special 0)"
      } >> "$LIB/ttc.log" 2>/dev/null
      # ★ 2026-10-31：manager 挂载命中缓存后**仍要物化模块目录副本**——
      #   缓存省掉的是"重算计划 + 合成合集"，物化这步必须做（元模块挂的是这些文件）。
      #   data/ 槽位不物化（由 datafont_apply 在开机时处理，与原逻辑一致）。
      #   ★ 直接写进模块目录（跳过 stage → commit 逐个 mv，少一半 fork）：
      #     · 目录按计划去重一次建好
      #     · 计划缩水时先清掉"新清单里没有"的旧副本（按 slots.applied 差集）
      #     · 硬链接与源同 inode（源已是 644+system_file）→ 成功时不需 chmod/chcon
      #     · 每槽位只剩 1 次 ln fork；commit_payload 收到 MANAGER_INPLACE=1
      #       会跳过 remove_manager_files（避免删掉刚物化的文件）
      if [ "$mode" = manager ] && [ "${CFS_PREWARM:-0}" != 1 ]; then
        # ★ 2026-10-31：符号链接模式（单点翻转）——payload 全是符号链接，
        #   切字体 = 翻转 .active/N（1~3 次操作），154 个槽位零重建
        if _symlink_on; then
          if _mgr_symlink_apply "$stage.map"; then
            cp -f "$stage.list" "$APPLIED" 2>/dev/null
            MANAGER_INPLACE=1
          else
            fail=1
          fi
        else
          rm -f "$MODDIR/.payload_links" 2>/dev/null
        _cm_dirs=" $(awk 'NF >= 2 { p = $2; sub(/^\//, "", p); sub(/\/[^\/]*$/, "", p); if (p != "") print p }' "$stage.map" 2>/dev/null | sort -u | tr '\n' ' ') "
        for _cm_d in $_cm_dirs; do
          [ -n "$_cm_d" ] && mkdir -p "$MODDIR/$(mgr_path "$_cm_d")" 2>/dev/null
        done
        # ★ 2026-11-01：差集比对改纯 shell（原来每个旧槽位一次 grep -qxF =
        #   154 个 fork ≈ 4 秒；现在新清单读进变量，case 匹配零 fork）
        _NEWLIST=""
        [ -s "$stage.list" ] && _NEWLIST=$(cat "$stage.list" 2>/dev/null)
        if [ -s "$APPLIED" ]; then
          while IFS= read -r _oldr; do
            [ -n "$_oldr" ] || continue
            case "$_oldr" in data/*) continue ;; esac
            case "
${_NEWLIST}" in *"
${_oldr}
"*) continue ;; esac
            rm -f "$MODDIR/$(mgr_path "$_oldr")" 2>/dev/null
          done < "$APPLIED"
        fi
        unset _NEWLIST
        # ★ 2026-11-01（第三轮提速）：命中物化也走批量并行（同生成路径）
        _LF_ERR="$LIB/.lnfail.$$"
        : > "$_LF_ERR" 2>/dev/null
        _LN_N=0; _ACC_LN=""
        while read -r _cmid _cmrel _cmsrc; do
          [ -n "${_cmrel:-}" ] || continue
          case "$_cmrel" in data/*) continue ;; esac
          [ -n "${_cmsrc:-}" ] || _cmsrc="$LIB/$_cmid.ttf"
          _cmdest="$MODDIR/$(mgr_path "$_cmrel")"
          _ACC_LN="${_ACC_LN}ln -f '${_cmsrc}' '${_cmdest}' || echo '${_cmdest}' >> '${_LF_ERR}'
"
          _LN_N=$((_LN_N + 1))
          case ${_LN_N} in *0) _ACC_LN="${_ACC_LN}wait
" ;; esac
        done < "$stage.map"
        _ln_batch_run "$_LF_ERR"
        if [ "${_LN_FAILN:-0}" -gt 0 ]; then
          echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 命中物化失败 ${_LN_FAILN} 个，首个：$(head -n1 "$_LF_ERR" 2>/dev/null)（/data 剩余 $(df -k /data 2>/dev/null | tail -n1 | tr -s ' ' | cut -d' ' -f4) KB）" \
            >> "$LIB/ttc.log" 2>/dev/null
          fail=1
        fi
        rm -f "$_LF_ERR" 2>/dev/null
        unset _ACC_LN _LN_N _cmdest
        cp -f "$stage.list" "$APPLIED" 2>/dev/null
        MANAGER_INPLACE=1
        unset _cm_dirs _cm_d
        fi   # _symlink_on else（符号链接关 → v18 硬链接物化）
      fi
    else
    # ★ 2026-10-31：走到这里说明缓存未命中，才需要 slots.sh（懒加载，见函数注释）
    _ensure_slots
    _GEN_NEW=1
    # 不用 $(...)：那会开子 shell，make_plan 里设的 SCOPE_VIA（判定依据）就拿不到了
    make_plan "$sel" "$plan" >/dev/null
    scope="$PLAN_SCOPE"
    {
      echo "time=$(date '+%m-%d %H:%M:%S' 2>/dev/null) rom=$(_rom_cached) ttc=$(ttc_effective) mode=$mode sel=$sel${CFS_PREWARM:+ tag=prewarm}"
      echo "plan=$(grep -c . "$plan" 2>/dev/null) scope=$scope 判定依据=${SCOPE_VIA:-?} keep_lang=$(cfg_get keep_lang 0) keep_special=$(cfg_get keep_special 0)"
    } >> "$LIB/ttc.log" 2>/dev/null
    # ★ 2026-10-27：清单为空时先自动重扫一次（升级后常见），再决定是否报错
    if [ ! -s "$plan" ] && [ ! -s "$LIB/scanned/slots.list" ]; then
      sh "${MODDIR:-$MODPATH}/fontctl.sh" rescan >/dev/null 2>&1
      make_plan "$sel" "$plan" >/dev/null
      scope="$PLAN_SCOPE"
    fi
    if [ ! -s "$plan" ]; then
      rm -f "$plan"
      echo "ERROR:没有找到可替换的槽位（范围：$scope）。已尝试自动重扫，仍为空的话请到「高级设置 → 通用 → 重新数一遍系统的字体」点一次，再切换"
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
    _ACC_LIST=""; _ACC_MAP=""
    # ★ 2026-11-01（fork 精简第二轮）：管理器挂载改「就地物化」——
    #   硬链接直接写进模块目录，不再"先进 stage、commit 再逐个 mv"。
    #   ★ 第三轮：循环里**连 ln 都不做**，只把命令攒进 _ACC_LN，
    #     循环结束一批并行执行（154 次串行 ln ≈ 5 秒 → 10 个一批并行 ≈ 1 秒）。
    _DIRWRITE=0
    _LF_ERR=""
    if [ "$mode" = manager ] && [ "${CFS_PREWARM:-0}" != 1 ] && ! _symlink_on; then
      _DIRWRITE=1
      _LF_ERR="$LIB/.lnfail.$$"
      : > "$_LF_ERR" 2>/dev/null
    fi
    _LN_N=0; _ACC_LN=""
    # ★ 2026-10-31（fork 精简）：目录按计划一次性建好（原来每槽位一次 mkdir -p，
    #   154 个槽位就是 154 次 fork）
    for _gd in $(awk 'NF >= 2 { p = $2; sub(/\/[^\/]*$/, "", p); if (p != "") print p }' "$plan" 2>/dev/null | sort -u); do
      mkdir -p "$stage/$(mgr_path "$_gd")" "$MODDIR/$(mgr_path "$_gd")" 2>/dev/null
    done
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
          # ★ 2026-10-24 B4：合集策略（默认 = 只换中文那几号）
          if [ "$(cfg_get ttc_no_mix 0 2>/dev/null)" = 1 ]; then
            printf '%s %s faces=%s via=skip detail=B4 不生成混合合集（高级设置）\n' \
              "$id" "$rel" "$nf" >> "$LIB/ttc.log" 2>/dev/null
            continue
          fi
          if [ "$(cfg_get ttc_all_faces 0 2>/dev/null)" = 1 ]; then
            cn=""
            _i=0
            while [ "$_i" -lt "$nf" ]; do cn="$cn $_i"; _i=$((_i + 1)); done
            cn=$(printf '%s' "$cn" | sed 's/^ //')
            cn_src="all-faces"; cn_detail="B4 全 face 替换（高级设置）"
          else
            ttc_cn_indices "${rel##*/}" "$nf" > "$LIB/.ttccn.$$" 2>/dev/null
            cn=$(tr '\n' ' ' < "$LIB/.ttccn.$$" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')
            cn_src="$TTC_CN_SRC"; cn_detail="$TTC_CN_DETAIL"
            rm -f "$LIB/.ttccn.$$" 2>/dev/null
          fi
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
          # ★ 2026-10-31（关键重构）：合成产物**直接落在永久缓存目录**，不再写字体库根目录。
          #   根目录产物会在切到别的字体时被 prune 判成"没人引用"删掉 →
          #   切回来时计划缓存失效、又要重新合成几十 MB（真机实测 B→A 又变 30 秒）。
          #   缓存路径稳定 ⇒ 计划缓存一次生成永久命中 ⇒ 合成一次永久保存（作者的设计）。
          #   新鲜度由下面的 -ot 门把守：字体或系统合集更新了才重做。
          TTC_CACHE="$LIB/.ttc.cache"
          cand="$TTC_CACHE/${id}.ttc${nf}_${tag}_${_csrc:-ttc}"
          if [ ! -s "$cand" ] || [ "$cand" -ot "$src" ] 2>/dev/null || [ "$cand" -ot "/$rel" ] 2>/dev/null; then
            # 先算空间：这次要合成 = 原合集大小 + 用户字体大小。宁可这一个槽位不换，
            # 也不能把 /data 写满 —— 写满之后系统会起不来（真机反馈过强制重启后黑屏）。
              # ★ 2026-10-31：wc -c 会把几十 MB 的合集整份读一遍，stat 只读元数据
              _osz=$(stat -c %s "/$rel" 2>/dev/null)
              _usz=$(stat -c %s "$src" 2>/dev/null)
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
            # ★ 2026-10-31（重构）：合成**直接写进永久缓存目录**（tmp → 全套校验 → mv 落位）。
            #   校验链一步不少：写全核对 / ttc_verify 结构校验 / 1KB 硬底线。
            #   产物路径 = cand（缓存目录里的可读名），一次合成永久保存 ——
            #   下次走到这里时上面的 -ot 门直接放行，零合成零拷贝。
            mkdir -p "$TTC_CACHE" 2>/dev/null
            cand_tmp="$cand.tmp.$$"
            # ★ 预热模式：向状态文件报告"正在合成哪个合集"（UI 轮询显示进度）
            if [ "${CFS_PREWARM:-0}" = 1 ]; then
              printf 'stage=ttc id=%s rel=%s\n' "$sel" "${rel##*/}" > "$LIB/.pw.$sel.state" 2>/dev/null
            fi
            _twerr=$(ttc_wrap_mix "$src" "$nf" "$cand_tmp" "/$rel" "$cn" 2>&1)
            _twrc=$?
            [ "$_twrc" = 0 ] || cand_tmp=""
            if [ -z "$cand_tmp" ] || [ ! -s "$cand_tmp" ]; then
              _twsz=$(stat -c %s "$cand_tmp" 2>/dev/null)
              _twfree=$(free_kb "$LIB")
              printf '%s %s faces=%s replace=%s via=wrapfail detail=包装器rc=%s 产物=%s字节 剩余=%sKB err=%s\n' \
                "$id" "$rel" "$nf" "$(printf '%s' "$cn" | tr ' ' ',')" \
                "${_twrc:-?}" "${_twsz:-无}" "${_twfree:-?}" \
                "$(printf '%s' "$_twerr" | head -n1 | cut -c1-80)" \
                >> "$LIB/ttc.log" 2>/dev/null
              rm -f "$cand_tmp" 2>/dev/null
              cand_tmp=""
            fi
            # 合成后核对：文件必须真的写全（空间在合成途中被占满会留下半截文件）
            if [ -s "$cand_tmp" ] && [ -n "$_osz" ] && [ -n "$_usz" ]; then
              _got=$(stat -c %s "$cand_tmp" 2>/dev/null)
              [ -n "$_got" ] && [ "$_got" -gt "$_usz" ] 2>/dev/null || cand_tmp=""
            fi
            # ★ 结构校验：不合格就删产物并跳过（避免应用按坏 face 渲染而崩溃）。
            #   （旧版"16 字节半截文件"的尺寸兜底由下面的 1KB 硬底线 + 写全核对覆盖）
            if [ -n "$cand_tmp" ] && [ -s "$cand_tmp" ]; then
              if ! _tv=$(ttc_verify "$cand_tmp" "$nf"); then
                printf '%s %s faces=%s replace=%s via=ttcbad detail=产物结构不合格（%s），已删除并跳过\n' \
                  "$id" "$rel" "$nf" "$(printf '%s' "$cn" | tr ' ' ',')" "${_tv:-unknown}" \
                  >> "$LIB/ttc.log" 2>/dev/null
                rm -f "$cand_tmp" 2>/dev/null
                cand_tmp=""
              fi
            fi
            if [ -n "$cand_tmp" ]; then
              _csz=$(stat -c %s "$cand_tmp" 2>/dev/null)
              if ! isnum "$_csz" || [ "$_csz" -lt 1024 ] 2>/dev/null; then
                printf '%s %s faces=%s replace=%s via=toosmall detail=产物只有%s字节，已删除并跳过\n' \
                  "$id" "$rel" "$nf" "$(printf '%s' "$cn" | tr ' ' ',')" "${_csz:-?}" \
                  >> "$LIB/ttc.log" 2>/dev/null
                echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 合集产物异常（只有 ${_csz:-?} 字节，已删除）：$cand_tmp" >> "$LIB/mount.log" 2>/dev/null
                rm -f "$cand_tmp" 2>/dev/null
                cand_tmp=""
              fi
            fi
            # 空间保护：剩余不足 300MB 就不落盘（宁可下次重合成，也不能把存储占满）
            if [ -n "$cand_tmp" ]; then
              _tc_free=$(free_kb "$LIB" 2>/dev/null)
              case "${_tc_free:-}" in ''|*[!0-9]*) _tc_free=0 ;; esac
              if [ "$_tc_free" -gt 0 ] && [ "$_tc_free" -lt 307200 ]; then
                printf '%s %s via=ttc-no-store detail=剩余空间不足(%sKB)，产物不保存\n' \
                  "$id" "$rel" "${_tc_free}" >> "$LIB/ttc.log" 2>/dev/null
                rm -f "$cand_tmp" 2>/dev/null
                cand_tmp=""
              fi
            fi
            if [ -n "$cand_tmp" ]; then
              chmod 644 "$cand_tmp" 2>/dev/null
              chcon u:object_r:system_file:s0 "$cand_tmp" 2>/dev/null
              # tmp+mv 原子落位：预热和 apply 并发合成同一产物也不会写坏
              if mv -f "$cand_tmp" "$cand" 2>/dev/null; then
                printf '%s %s faces=%s replace=%s via=ttc-synth(已入永久缓存)\n' \
                  "$id" "$rel" "$nf" "$(printf '%s' "$cn" | tr ' ' ',')" >> "$LIB/ttc.log" 2>/dev/null
                if [ "${CFS_PREWARM:-0}" = 1 ]; then
                  printf 'stage=ttcdone id=%s rel=%s\n' "$sel" "${rel##*/}" > "$LIB/.pw.$sel.state" 2>/dev/null
                fi
              else
                rm -f "$cand_tmp" 2>/dev/null
                cand=""
              fi
            else
              cand=""
            fi
            # 保留最近 12 份（3 字体 × 2 合集槽 = 6 份全装得下，不会被挤掉；
            # 多年换字体也不会无限膨胀。60MB 一份约 700MB 上限，
            # 且上面已有"剩余不足 300MB 不落盘"保护）
            ls -1t "$TTC_CACHE"/*.ttc 2>/dev/null | tail -n +13 | while IFS= read -r _old; do
              rm -f "$_old" 2>/dev/null
            done
            if [ -n "$cand" ]; then
              _csz=$(stat -c %s "$cand" 2>/dev/null)
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
      if [ "$_DIRWRITE" = 1 ]; then
        # ★ 2026-10-31：预热模式只生成计划（存缓存），不物化 payload 文件
        #    符号链接模式同样延后——计划完整后统一物化（见下方 _mgr_symlink_apply）
        # ★ 2026-10-19：/data 上的主题字体**不进 payload** ——
        #   元模块只 overlay system/product/vendor/system_ext，
        #   把 /data/... 塞进模块目录没人会挂它。这类槽位由 post-fs-data 里的
        #   datafont_apply 做物理替换（整份复制，主题服务按 inode/mtime 认）。
        # ★ 2026-11-01（第三轮提速）：这里不落盘，只把"该建哪个硬链接"攒进
        #   _ACC_LN（失败把目标路径记进 _LF_ERR，循环后批量并行执行）。
        #   字体文件的 644 + system_file 上下文在入库时已设好，硬链接同 inode 免设。
        case "$rel" in
          data/*) ;;
          *)
        _dw_dest="$MODDIR/$(mgr_path "$rel")"
        _ACC_LN="${_ACC_LN}ln -f '${src}' '${_dw_dest}' || echo '${_dw_dest}' >> '${_LF_ERR}'
"
        _LN_N=$((_LN_N + 1))
        # 每 10 条插一个 wait（个位数是 0 就攒一批），控制并行进程数
        case ${_LN_N} in *0) _ACC_LN="${_ACC_LN}wait
" ;; esac
            ;;
        esac
      fi
      # ★ 2026-11-01（fork 精简第二轮）：清单/映射**攒进变量，循环结束一次写盘**。
      #   原来每槽位两次 `echo >> 文件`，154 槽位 = 308 个进程 ≈ 8-12 秒 ——
      #   这就是"切一次要 10 几秒"的最大单一开销。
      _ACC_LIST="${_ACC_LIST}${rel}
"
      # 第三个字段 = 这个槽位实际挂哪个文件（.ttc 槽位挂的是包好的合集；老格式只有两个字段）
      _ACC_MAP="${_ACC_MAP}${id} ${rel} ${src}
"
      COUNT=$((COUNT+1))
    done < "$plan"
    rm -f "$plan"
    # ★ 2026-11-01：攒好的清单/映射一次写盘（替代原来每槽位 2 次 echo 追加）
    printf '%s' "$_ACC_LIST" > "$stage.list" 2>/dev/null
    printf '%s' "$_ACC_MAP" > "$stage.map" 2>/dev/null
    # ★ 2026-11-01（第三轮提速）：一批并行物化（详见 _ln_batch_run 注释）
    if [ "$_DIRWRITE" = 1 ]; then
      _ln_batch_run "$_LF_ERR"
      if [ "${_LN_FAILN:-0}" -gt 0 ]; then
        echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 批量物化失败 ${_LN_FAILN} 个，首个：$(head -n1 "$_LF_ERR" 2>/dev/null)（/data 剩余 $(df -k /data 2>/dev/null | tail -n1 | tr -s ' ' | cut -d' ' -f4) KB）" \
          >> "$LIB/ttc.log" 2>/dev/null
        fail=1
      fi
      rm -f "$_LF_ERR" 2>/dev/null
      unset _ACC_LN _LN_N _dw_dest
    fi
    # ★ 2026-11-01：就地物化收尾 ——
    #   ① 标记 commit_payload 跳过 remove_manager_files（别把刚写的文件删了）
    #   ② 计划缩水时（如关掉保留锁屏时钟）按差集删掉模块目录里多余的旧副本
    if [ "$_DIRWRITE" = 1 ] && [ "$fail" = 0 ]; then
      MANAGER_INPLACE=1
      if [ -s "$APPLIED" ]; then
        while IFS= read -r _oldr; do
          [ -n "$_oldr" ] || continue
          case "$_oldr" in data/*) continue ;; esac
          case "
${_ACC_LIST}" in *"
${_oldr}
"*) continue ;; esac
          rm -f "$MODDIR/$(mgr_path "$_oldr")" 2>/dev/null
        done < "$APPLIED"
      fi
    fi
    # ★ 计划生成成功 → 存进缓存，下次同字体同开关直接用
    [ "$fail" = 0 ] && [ "$COUNT" -gt 0 ] 2>/dev/null && \
      plan_cache_save "$sel" "$stage.map" "$stage.list" "$scope" "$KLLAST" "$COUNT"
    fi   # ★ 2026-10-30 计划缓存 else 分支收口

    # ★ 2026-10-31：符号链接模式 —— 计划完整后统一物化（管理器挂载专用）
    if [ "${_GEN_NEW:-0}" = 1 ] && [ "$mode" = manager ] && [ "${CFS_PREWARM:-0}" != 1 ] && _symlink_on; then
      if _mgr_symlink_apply "$stage.map"; then
        cp -f "$stage.list" "$APPLIED" 2>/dev/null
        MANAGER_INPLACE=1
      else
        fail=1
      fi
    fi

    if [ "$fail" = 1 ] || [ "$COUNT" = 0 ]; then
      _dfree=$(df -k /data 2>/dev/null | tail -n1 | tr -s ' ' | cut -d' ' -f4)
      echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 生成失败：fail=$fail 槽位=$COUNT · /data 剩余 ${_dfree:-?} KB（失败的那一对路径见上方"物化失败"行）" \
        >> "$LIB/ttc.log" 2>/dev/null
      rm -rf "$stage" "$stage.list" "$stage.map"
      if [ "${_DIRWRITE:-0}" = 1 ]; then
        echo "ERROR:生成字体文件失败（/data 剩余 ${_dfree:-?} KB——接近 0 就是真的没空间了，请先清理）。这次是就地更新，个别槽位可能已换成新字体——重新应用一次即可恢复一致"
      else
        echo "ERROR:生成字体文件失败（/data 剩余 ${_dfree:-?} KB——接近 0 就是真的没空间了，请先清理），已保留原来的字体"
      fi
      exit 1
    fi
    # ★ 2026-10-31：**预热模式到此为止** —— 计划已生成（或命中）并写入缓存，
    #   但**不提交**：不写 slots.map / pending_font / last_selection，当前选择分毫不动。
    if [ "${CFS_PREWARM:-0}" = 1 ]; then
      printf 'stage=done id=%s count=%s\n' "$sel" "$COUNT" > "$LIB/.pw.$sel.state" 2>/dev/null
      rm -rf "$stage" "$stage.list" "$stage.map" 2>/dev/null
      echo "OK:prewarm:$COUNT:$([ "${PC_HIT:-0}" = 1 ] && echo hit || echo miss)"
      exit 0
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
    # ★ 2026-10-23（ColorOS 真机反馈"恢复不了原字体，得卸载才恢复"）：
    #   主题字体（/data 下那几份）是**物理替换**上去的，原件备份在 $LIB/.orig。
    #   原来只有开机时（pending=none）才还原；用户选「无字体」当场不还原，
    #   看起来就像"没恢复"。这里立刻把原件盖回去 —— 不用等重启。
    if command -v datafont_restore >/dev/null 2>&1; then
      datafont_restore >/dev/null 2>&1
    fi
  else
    printf '%s\n' "$sel" > "$LIB/.last_good" 2>/dev/null
  fi
  refresh_prop
  # ★ 2026-10-31：计时收尾 —— 耗时写进 ttc.log（诊断报告会打印），
  #   并追加到 OK 返回行（界面解析 t= 字段显示给用户）
  _cfs_t1=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | tr -d ' ')
  _cfs_el=$(awk -v a="${_cfs_t0:-0}" -v b="${_cfs_t1:-0}" \
    'BEGIN { d = b - a; if (d < 0 || a == 0 || b == 0) d = 0; printf "%.2f", d }' 2>/dev/null)
  case "${_cfs_el:-}" in ''|*[!0-9.]*) _cfs_el="?" ;; esac
  {
    echo "apply耗时=${_cfs_el}s 缓存=$([ "${PC_HIT:-0}" = 1 ] && echo 命中 || echo 生成) 槽位=$COUNT"
  } >> "$LIB/ttc.log" 2>/dev/null
  # ★ 2026-10-17：返回值后面带上"这次实际用的 keep_lockscreen"。
  #   用户反馈"切了开关没反应"时，这一项能直接分辨是"设置没写进去"还是"过滤没生效"。
  echo "OK:$(label_of "$sel"):$COUNT:$scope:$KLLAST,t=${_cfs_el}s"
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
  echo "设置: keep_lang=$(cfg_get keep_lang 0) keep_special=$(cfg_get keep_special 0) mount_mode=$(mount_mode) keep_lockscreen=$(keep_lockscreen_val)"
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

# ---------------------------------------------------------------------------
# ★ 2026-10-22（底层优化）：**永久索引**
#   目的：把"当前真相"落盘一次，之后谁要用就直接读文件，不再现场 glob/解析。
#   谁维护：所有会改字体库的子命令在结束时调用 index_build（见各分支末尾）。
#   谁读取：界面（fastquery/index）、诊断报告、挂载脚本需要清单时。
#   格式：纯文本 key=value + 若干 font= 行，便于 shell/grep 直接取。
#   自愈：文件不存在或 schema 版本不符 → index_build 重建一次。
# ---------------------------------------------------------------------------
INDEX_SCHEMA=3


# ---------------------------------------------------------------------------
# ★ 2026-10-22（修「导入字体后界面不刷新」）：
#   原来是在各个分支**末尾**调用 index_build —— 但那些分支几乎都是
#   `echo "$out"; exit $rc` 的形式，exit 后面的代码永远不会执行，
#   于是索引一直是旧的，界面读旧索引 ⇒ 看不到刚导入的字体。
#
#   现在改成"脏标记 + 退出时统一重建"：
#     · 会改字体库的分支开头写 mark_dirty
#     · 不管从哪条路径退出（exit / 正常结束 / 出错），trap 都会重建一次
#     · 只读命令（status / list / quick / index …）不标记，不会多余重建
# ---------------------------------------------------------------------------
INDEX_DIRTY=0
mark_dirty() { INDEX_DIRTY=1; return 0; }

_index_on_exit() {
  [ "${INDEX_DIRTY:-0}" = 1 ] || return 0
  index_build 2>/dev/null
  return 0
}
trap '_index_on_exit' EXIT

index_path() { printf '%s/.index' "$LIB"; }

index_build() {
  local _p _tmp _id _lf _lnm _lsz _lmt _n
  _p=$(index_path)
  _tmp="$_p.tmp.$$"
  mkdir -p "$LIB" 2>/dev/null
  {
    printf '#CFS-INDEX %s\n' "$INDEX_SCHEMA"
    printf 'built=%s\n' "$(date +%s 2>/dev/null)"
    printf 'ver=%s\n' "$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')"
    printf 'active=%s\n' "$(cur_active 2>/dev/null)"
    printf 'pending=%s\n' "$(cur_pending 2>/dev/null)"
    printf 'rom=%s\n' "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/current_rom")"
    printf 'mode=%s\n' "$(mount_mode 2>/dev/null)"
    printf 'slots=%s\n' "$(grep -c . "$MODDIR/slots.map" 2>/dev/null)"
    _n=0
    for _lf in "$LIB"/*.ttf; do
      [ -e "$_lf" ] || continue
      case "$_lf" in *'*'*) continue ;; esac
      _id=${_lf##*/}
      case "$_id" in f[0-9]*.ttf|builtin_*.ttf) ;; *) continue ;; esac
      _id=${_id%.ttf}
      _lnm=""
      [ -f "$LIB/$_id.name" ] && IFS= read -r _lnm < "$LIB/$_id.name" 2>/dev/null
      _lsz=0
      _lmt=""
      if [ -f "$LIB/$_id.meta" ]; then
        while IFS= read -r _kv; do
          [ -z "$_kv" ] && continue
          case "$_kv" in \#*) continue ;; esac
          _lmt="${_lmt}${_lmt:+,}${_kv}"
          case "$_kv" in
            size=*) _lsz=${_kv#size=} ;;
            outline_sz=*) [ "$_lsz" = 0 ] && _lsz=${_kv#outline_sz=} ;;
          esac
        done < "$LIB/$_id.meta" 2>/dev/null
      fi
      case "${_lsz:-}" in ''|*[!0-9]*) _lsz=0 ;; esac
      printf 'font=%s|%s|%s|%s\n' "$_id" "${_lnm:-$_id}" "$_lsz" "$_lmt"
      _n=$((_n + 1))
    done
    printf 'fonts=%s\n' "$_n"
  } > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_p" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  return 0
}

index_ok() {
  local _p _s _newer
  _p=$(index_path)
  [ -s "$_p" ] || return 1
  _s=$(sed -n '1s/^#CFS-INDEX //p' "$_p" 2>/dev/null | tr -d '\r')
  [ "$_s" = "$INDEX_SCHEMA" ] || return 1
  # ★ 自愈：字体库里有比索引更新的字体文件（手工放进来的/外部改动）→ 视为过期
  _newer=$(find "$LIB" -maxdepth 1 -name '*.ttf' -newer "$_p" -print -quit 2>/dev/null)
  [ -z "$_newer" ] || return 1
  return 0
}

# 输出索引内容（缺失/过期就重建一次）
index_get() {
  index_ok || index_build
  cat "$(index_path)" 2>/dev/null
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
    # ★ 2026-10-31（性能）：直接读安装时算好的 slots.meta ——
    #   原来这里还要调 slot_sources_report（起子进程）+ awk 再解析一遍，
    #   而它给的字段本来就来自这个文件，全是重复劳动。现在零子进程。
    #   （status 已不再加载 slots.sh，这个依赖就此解除。）
    #   口径不变：
    #     x = 机型清单（targets）里、本机真实存在的名字数 = targets=
    #     s = 本机扫描补的 = extra=
    _mt="${LIB:-/data/adb/custom_font_lib}/scanned/slots.meta"
    _tjn=0; _tjt=0; _jbn=0
    if [ -s "$_mt" ]; then
      while IFS='=' read -r _mk _mv; do
        case "${_mk:-}" in
          targets) _tjn="${_mv:-0}" ;;
          total)   _tjt="${_mv:-0}" ;;
          extra)   _jbn="${_mv:-0}" ;;
        esac
      done < "$_mt"
      case "${_tjn:-}" in ''|*[!0-9]*) _tjn=0 ;; esac
      case "${_tjt:-}" in ''|*[!0-9]*) _tjt=0 ;; esac
      case "${_jbn:-}" in ''|*[!0-9]*) _jbn=0 ;; esac
      [ "${_jbn:-0}" -lt 0 ] 2>/dev/null && _jbn=0
      echo "SP4=x=${_tjn:-0},s=${_jbn:-0},o=0,d=0,extra=0,symskip=0"
      echo "SP=x=${_tjn:-0},a=${_jbn:-0}"
    else
      echo "SP="
      echo "SP4="
    fi
    # ★ 开关回显行不依赖 slots.meta，无论有没有清单都要输出（否则首次安装时
    #   界面开关拿不到当前值，只能靠本地缓存 —— 以前的老毛病"交替失败"会回来）
    # ★ 2026-10-17：把「保留锁屏时钟」的当前值也返回给界面。
    #   界面靠它决定下次点击要写 0 还是 1；不回传的话，界面只能靠本地缓存，
    #   一旦某次没回写就会"交替失败"（用户实测过）。
    echo "KL=$(keep_lockscreen_val)"
    # ★ 2026-10-24：把「中文合集替换」的**生效值**也给界面（1/0），
    #   界面新增的开关靠它回显；没有这一行，开关就只能靠猜。
    echo "TR=$(ttc_effective 2>/dev/null)"
    echo "SPF=$(cfg_get skip_product 0)"
    # 三个新开关默认都是 0（关），只能人为打开
    echo "KS=$(cfg_get keep_samsung 0)"
    echo "SVF=$(cfg_get skip_vf 0)"
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
    # ★ 2026-11-06：混合挂载状态（元模块挂系统分区 + 模块 bind 补挂 /data）
    _hy19=0
    if [ "$(mount_mode 2>/dev/null)" = manager ] && grep -qE '^[^ ]+ (/?data/)' "$MODDIR/slots.map" 2>/dev/null; then
      # 挂到的可能是符号链接的真实路径（/system/fonts/…），所以只看 .mounted 是否有记录
      [ -s "${LIB:-/data/adb/custom_font_lib}/.mounted" ] && _hy19=1
    fi
    echo "HY=$_hy19"

    # ★ 2026-11-01：PD=1 = 计划比本次开机新（改了开关/换了字体还没重启）
    #   ★ 2026-11-01（作者反馈"A切B再切A应该变回正常"）：mtime 新还不够 ——
    #     再比一次**内容**：与开机快照逐字节一致（A→B→A、开关开→关→开）= 实际
    #     没有变化，不算待生效，横幅不出。cmp 只在 mtime 更新时才跑（一次 fork）。
    _pd=0
    if [ -s "$MODDIR/slots.map" ] && [ -f "$LIB/.boot.mark" ]; then
      if [ "$MODDIR/slots.map" -nt "$LIB/.boot.mark" ] 2>/dev/null; then
        if [ ! -s "$MODDIR/slots.boot.map" ] || \
           ! cmp -s "$MODDIR/slots.map" "$MODDIR/slots.boot.map" 2>/dev/null; then
          _pd=1
        fi
      fi
    fi
    echo "PD=$_pd"
    # ★ 2026-11-01（作者要求）：「当前实际生效」的数字来源 = **开机快照**。
    #   service.sh 开机时把当时的 slots.map 存成 slots.boot.map —— 那是这次
    #   开机真正挂载的计划；之后的 apply 只改 slots.map 不动快照，
    #   所以"已生效"在重启前纹丝不动，不会跟着新计划一起变。
    _bn=$(wc -l 2>/dev/null < "$MODDIR/slots.boot.map" | tr -d ' ')
    case "${_bn:-}" in ''|*[!0-9]*) _bn="" ;; esac
    [ -n "$_bn" ] || _bn=$(wc -l 2>/dev/null < "$APPLIED" | tr -d ' ')
    echo "BN=${_bn:-0}"
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

  export)
    # ★ 2026-11-01：导出字体文件 —— 把字体库里的 ttf 复制一份到手机存储。
    #   界面走模块自带的文件浏览器选目标文件夹（和导入是同一套，反着用）。
    #   用法: export <id-b64> <目标目录-b64> <显示名-b64>
    #   返回: OK:<完整路径>|<字节数>   或   ERROR:<原因>
    #   安全边界：目标必须在手机存储（$STORAGE）里；重名自动加 (2) (3)；
    #   复制完核对字节数，不一致就删掉半截文件报错。
    _ex_id=$(printf '%s' "$2" | base64 -d 2>/dev/null)
    _ex_dir=$(printf '%s' "$3" | base64 -d 2>/dev/null)
    _ex_name=$(printf '%s' "$4" | base64 -d 2>/dev/null)
    case "$_ex_id" in
      f[0-9]*|builtin_*) [ -s "$LIB/$_ex_id.ttf" ] || { echo "ERROR:字体文件不存在（$_ex_id）"; exit 1; } ;;
      *) echo "ERROR:不是字体库里的字体"; exit 1 ;;
    esac
    [ -n "$_ex_dir" ] || _ex_dir="$STORAGE/Download"
    bad_path "$_ex_dir" && { echo "ERROR:路径不允许"; exit 1; }
    _ex_r=$(to_real "$_ex_dir")
    case "$_ex_r" in "$STORAGE"|"$STORAGE"/*) ;; *) echo "ERROR:只能导出到手机存储里"; exit 1 ;; esac
    mkdir -p "$_ex_r" 2>/dev/null
    [ -d "$_ex_r" ] || { echo "ERROR:目标文件夹建不了：$_ex_dir"; exit 1; }
    # 文件名去掉对 FAT/存储无意义的字符；显示名清空就退回用 id
    _ex_base=$(printf '%s' "$_ex_name" | sed 's/[\/:*?"<>|]/_/g; s/^\.+//; s/[[:space:]]*$//')
    [ -n "$_ex_base" ] || _ex_base="$_ex_id"
    _ex_out="$_ex_r/$_ex_base.ttf"
    _ex_n=1
    while [ -e "$_ex_out" ]; do
      _ex_n=$((_ex_n + 1))
      _ex_out="$_ex_r/$_ex_base ($_ex_n).ttf"
    done
    if ! cp -f "$LIB/$_ex_id.ttf" "$_ex_out" 2>/dev/null; then
      echo "ERROR:复制失败（存储空间不足，或目录是只读的）"; exit 1
    fi
    _ex_sz=$(stat -c %s "$_ex_out" 2>/dev/null)
    _ex_srcsz=$(stat -c %s "$LIB/$_ex_id.ttf" 2>/dev/null)
    if [ -z "$_ex_sz" ] || [ -z "$_ex_srcsz" ] || [ "$_ex_sz" != "$_ex_srcsz" ]; then
      rm -f "$_ex_out" 2>/dev/null
      echo "ERROR:复制不完整（$_ex_sz / $_ex_srcsz 字节），已删除半截文件"; exit 1
    fi
    chmod 644 "$_ex_out" 2>/dev/null
    echo "OK:$_ex_out|$_ex_sz"
    ;;



  index)
    # 直接吐索引（缺失就现场建一次）
    index_get
    ;;

  index-build)
    index_build && echo OK
    ;;

  quick)
    # ★ 2026-10-22（性能）：首屏一次性拿「状态 + 字体列表」。
    #   为什么不直接调 status + list：KernelSU 的 exec 是同步的，两次调用 = 两次
    #   shell 启动 + 两次解析（common.sh/slots.sh/mount.sh + fontctl 本身 ≈ 250KB）。
    #   这里还额外跳过 slot_sources_report（要跑外部进程，是 status 里最重的一步），
    #   SP/SP4 留空，界面那三行先隐藏，随后由后台 status 补齐。
    A=$(cur_active); P=$(cur_pending)
    echo "A=$A"
    echo "P=$P"
    echo "R=$(cat "$MODDIR/current_rom" 2>/dev/null | tr -d '[:space:]')"
    if [ -f "$MODDIR/rescued" ]; then echo "X=1"; else echo "X=0"; fi
    echo "N=$(wc -l 2>/dev/null < "$APPLIED" | tr -d ' ')"
    echo "S=$(effective_scope "$P" 2>/dev/null)"
    echo "M=$(mount_mode)"
    echo "PM=$(cat "$MODDIR/payload.mode" 2>/dev/null | tr -d '[:space:]')"
    echo "RM=$(root_manager)"
    echo "V=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
    echo "KL=$(keep_lockscreen_val)"
    _ttcn=$(awk '$2 ~ /\.ttc$/ { c++ } END { print c + 0 }' "$MODDIR/slots.map" 2>/dev/null)
    case "${_ttcn:-}" in ''|*[!0-9]*) _ttcn=0 ;; esac
    echo "TT=$_ttcn"
    # ★ 2026-11-01：PD=1 = 计划比本次开机新（改了开关/换了字体还没重启）
    #   ★ 内容与开机快照一致（A→B→A）→ 不算待生效（同 status 分支）
    _pd=0
    if [ -s "$MODDIR/slots.map" ] && [ -f "$LIB/.boot.mark" ]; then
      if [ "$MODDIR/slots.map" -nt "$LIB/.boot.mark" ] 2>/dev/null; then
        if [ ! -s "$MODDIR/slots.boot.map" ] || \
           ! cmp -s "$MODDIR/slots.map" "$MODDIR/slots.boot.map" 2>/dev/null; then
          _pd=1
        fi
      fi
    fi
    echo "PD=$_pd"
    # ★ 2026-11-01（作者要求）：「当前实际生效」= 开机快照（见 status 分支同注释）
    _bn=$(wc -l 2>/dev/null < "$MODDIR/slots.boot.map" | tr -d ' ')
    case "${_bn:-}" in ''|*[!0-9]*) _bn="" ;; esac
    [ -n "$_bn" ] || _bn=$(wc -l 2>/dev/null < "$APPLIED" | tr -d ' ')
    echo "BN=${_bn:-0}"
    echo "@@L@@"
    # ★ 2026-10-22（底层优化）：优先读永久索引 —— 单文件、单次读，不再现场 glob。
    #   索引不存在或 schema 不符 → 现场建一次（只发生一次）。
    if index_ok; then
      sed -n 's/^font=//p' "$(index_path)" 2>/dev/null
    else
      sed -n 's/^font=//p' "$(index_path)" 2>/dev/null
    fi

    ;;

  list)
    # ★★ 2026-10-18 重写（修「界面卡在 ① 发送 list」）：
    #   **不 stat 任何字体文件，不启动任何外部命令。**
    #
    #   上一版为了拿字体大小对 $LIB/<id>.ttf 做了 stat。
    #   子项目的 $LIB 里有 3 个 42MB 内置字体，只要其中一个是失效的 bind mount，
    #   stat 就会进入不可中断睡眠（D 状态），命令永不返回 →
    #   KernelSU 的回调超时 → 界面永远停在「① 发送 list」。
    #
    #   现在只用 shell 内建读 *.name / *.meta 这两个小文本，
    #   大小取 meta 里的 size= 或 outline_sz=，都没有就给 0（界面显示「—」）。
    _lout=""
    for _lf in "$LIB"/*.ttf; do
      [ -e "$_lf" ] || continue
      case "$_lf" in *'*'*) continue ;; esac
      _lid=${_lf##*/}
      case "$_lid" in
        f[0-9]*.ttf|builtin_*.ttf) ;;
        *) continue ;;
      esac
      _lid=${_lid%.ttf}
      _lnm=""
      if [ -f "$LIB/$_lid.name" ]; then
        IFS= read -r _lnm < "$LIB/$_lid.name" 2>/dev/null
      fi
      _lsz=""
      _lmt=""
      if [ -f "$LIB/$_lid.meta" ]; then
        while IFS= read -r _kv; do
          [ -z "$_kv" ] && continue
          _lmt="${_lmt}${_lmt:+,}${_kv}"
          case "$_kv" in
            size=*) _lsz=${_kv#size=} ;;
            outline_sz=*) [ -z "$_lsz" ] && _lsz=${_kv#outline_sz=} ;;
          esac
        done < "$LIB/$_lid.meta" 2>/dev/null
      fi
      # 只保留数字，避免脏数据
      case "${_lsz:-}" in ''|*[!0-9]*) _lsz=0 ;; esac
      _lout="${_lout}${_lid}|${_lnm:-$_lid}|${_lsz}|${_lmt}
"
    done
    printf '%s' "$_lout"
    ;;
  import)
    mark_dirty
    bad_path "$2" && { echo "ERROR:路径不允许"; exit 1; }
    src=$(to_real "$2")
    [ -f "$src" ] || src="$2"
    [ -f "$src" ] || { echo "ERROR:找不到文件：$2"; exit 1; }
    out=$(store_font "$src" "$3" cp); rc=$?
    # ★ 2026-10-31：预热改由调用方在「档案探测完成后」显式触发（prewarm-bg）——
    #   旧版在这里就后台开跑，会和 UI 的字体档案写入（fam/覆盖率）赛跑：
    #   计划按"半成品档案"生成，探测写完 meta 后钥匙又变 → 缓存白做。
    echo "$out"; exit $rc
    ;;
  upload-start)
    mkdir -p "$LIB"; : > "$PART"
    echo "OK"
    ;;
  upload-finish)
    mark_dirty
    [ -f "$PART" ] || { echo "ERROR:没有待处理的上传"; exit 1; }
    # ★ 2026-10-31：stat 只读元数据（原来 wc -c 把整份上传的字体读一遍）
    if [ -n "$2" ] && [ "$(stat -c %s "$PART" 2>/dev/null | tr -d ' ')" != "$2" ]; then
      rm -f "$PART"
      echo "ERROR:传输不完整，请重试（或改用「扫描」导入）"
      exit 1
    fi
    out=$(store_font "$PART" "$3" mv); rc=$?
    # ★ 2026-10-31：预热改由调用方显式触发（prewarm-bg，同 import 的说明）
    echo "$out"; exit $rc
    ;;
  rename)
    mark_dirty
    check_id "$2"
    [ -n "$3" ] || { echo "ERROR:名称不能为空"; exit 1; }
    printf '%s' "$(clean_name "$3")" > "$LIB/$2.name"
    refresh_prop
    echo "OK"
    ;;
  delete)
    mark_dirty
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
  prewarm)
    # -------------------------------------------------------------------
    # ★ 2026-10-31：**预热** —— 只把"这个字体的最终计划"生成好并写入缓存，
    #   不改任何当前状态（不写 pending/slots.map/last_selection）。
    #   调用方：导入字体后 / 改开关后（后台）。效果：下一次——也就是**第一次**——
    #   真正切换这个字体时直接命中计划缓存，秒级完成。
    # -------------------------------------------------------------------
    sel=$(check_sel "$2") || { echo "$sel"; exit 1; }
    [ "$sel" = none ] && { echo "OK:none"; exit 0; }
    # ★ 2026-10-31：manager 挂载也预热（计划缓存与挂载方式无关）
    CFS_PREWARM=1
    export CFS_PREWARM
    # ★ 状态文件：给 UI 轮询显示进度（stage=plan → ttc → done）
    printf 'stage=plan id=%s\n' "$sel" > "$LIB/.pw.$sel.state" 2>/dev/null
    do_apply "$sel"
    ;;
  prewarm-bg)
    # -------------------------------------------------------------------
    # ★ 2026-10-31：**后台预热（立即返回）** —— 给 UI 的导入流程用：
    #   导入 + 档案探测完成后调用。本命令把状态文件标成 queued 后立即返回
    #   （不阻塞 ksuExec），真正的预热在后台跑；
    #   UI 轮询 $LIB/.pw.<id>.state 显示「现在在干嘛」。
    # -------------------------------------------------------------------
    sel=$(check_sel "$2") || { echo "$sel"; exit 1; }
    [ "$sel" = none ] && { echo "OK:none"; exit 0; }
    printf 'stage=queued id=%s\n' "$sel" > "$LIB/.pw.$sel.state" 2>/dev/null
    ( sh "$MODDIR/fontctl.sh" prewarm "$sel" ) >/dev/null 2>&1 &
    echo "OK:prewarm-bg:$sel"
    ;;
  prewarm-all)
    # -------------------------------------------------------------------
    # ★ 2026-10-31：给字体库里**全部已有字体**预热计划缓存 + 合集产物。
    #   解决"字体是以前导入的，第一次切换永远未命中"的问题。
    #   逐字体输出进度（安装脚本会把这些行转成 ui_print 显示给用户）。
    # -------------------------------------------------------------------
    # 顺手清掉 v3 过渡期的哈希名缓存产物（现行命名可读且永久）
    rm -f "$LIB"/.ttc.cache/*_g1.ttc 2>/dev/null
    # ★ 2026-10-31：manager 挂载也预热（不再跳过）
    _pwn=0; _pwh=0
    for _pwf in "$LIB"/f*.ttf "$LIB"/builtin_*.ttf; do
      [ -f "$_pwf" ] || continue
      case "$_pwf" in *'*'*) continue ;; esac
      _pwid=${_pwf##*/}; _pwid=${_pwid%.ttf}
      _pwo=$(sh "$MODDIR/fontctl.sh" prewarm "$_pwid" 2>/dev/null); _pwr=$?
      if [ "$_pwr" != 0 ]; then
        echo "  $_pwid：跳过（没有可替换的槽位）"
        continue
      fi
      case "$_pwo" in
        *":hit")
          _pwh=$((_pwh + 1))
          echo "  $_pwid：计划已是最新（命中缓存，零耗时）" ;;
        OK:prewarm:*)
          _pwn=$((_pwn + 1))
          echo "  $_pwid：计划已生成并缓存（已有合集产物直接复用）" ;;
        *)
          echo "  $_pwid：$_pwo" ;;
      esac
    done
    echo "OK:prewarm-all 本次生成 $_pwn 份，已缓存 $_pwh 份"
    ;;
  apply)
    mark_dirty
    do_apply "$2"

  # ★ 2026-11-06：manager 模式 + 主题字体槽位 → 每次应用后立刻补挂 /data，
  #   不用等下一次开机（原来只在 post-fs-data 跑，用户切完开关看不到效果）。
  if [ "$(mount_mode 2>/dev/null)" = manager ] && [ -s "$MODDIR/slots.map" ]; then
    ( . "$MODDIR/mount.sh" 2>/dev/null; mount_data_slots_only ) >/dev/null 2>&1
  fi
    ;;
  rescan)
    mark_dirty
    # ★ 2026-10-17：重新扫描本机字体并覆盖设备清单。
    #   什么时候用：换了系统大版本、装了新字体但界面没显示、或诊断建议你重扫。
    #   平时**不需要**跑 —— apply/reapply 只读清单，不扫描。
    # ★ 2026-10-27（Flyme）：成功与否看"清单有没有内容"，不看退出码。
    #   某些 ROM 上装配过程会返回非 0，但 slots.list / slots.meta 已经写好了，
    #   以前会误报「扫描失败」，用户以为不能用了。
    slot_build_slots "$MODDIR" 2>/dev/null
    _rc=$?
    _rn=$(sed -n 's/^total=//p' "$LIB/scanned/slots.meta" 2>/dev/null)
    _tn=$(sed -n 's/^targets=//p' "$LIB/scanned/slots.meta" 2>/dev/null)
    _ln=$(grep -c . "$LIB/scanned/slots.list" 2>/dev/null | tr -dc '0-9')
    case "${_rn:-}" in ''|*[!0-9]*) _rn=0 ;; esac
    case "${_ln:-}" in ''|*[!0-9]*) _ln=0 ;; esac
    if [ "$_ln" -gt 0 ] || [ "$_rn" -gt 0 ]; then
      # 退出码不为 0 只记进日志，不再当失败
      [ "$_rc" != 0 ] && echo "[rescan] slot_build_slots rc=$_rc，但清单已生成（total=$_rn lines=$_ln）" >> "$LIB/ttc.log" 2>/dev/null
      [ "$_rn" -gt 0 ] || _rn=$_ln
      echo "OK:已重新扫描，${_rn} 个字体槽位（机组清单 ${_tn:-0} + 本机补）"
    else
      echo "ERROR:扫描失败（可能是字体目录还没就绪，重启后再试）"
      exit 1
    fi
    ;;
  reapply)
    mark_dirty
    do_apply "$(cur_pending)"
    ;;
  apply-bg)
    # -------------------------------------------------------------------
    # ★ 2026-11-02：**异步应用** —— 立即返回，结果落状态文件供界面轮询。
    #   为什么要有它：KernelSU 的 exec 是同步的，界面等一次 apply/reapply 的
    #   全过程里 JS 线程整个被冻住 —— 提示条挂着、点卡片没反应，"像被冻结"。
    #   改成后台跑：
    #     sh fontctl.sh apply-bg [字体id]   → 立刻回 OK:bg
    #     界面每 0.5 秒读 $LIB/.reapply.state，读到 OK:/ERROR: 开头即收工。
    #   $2 缺省 = 重应用当前待生效（等价 reapply）。
    # -------------------------------------------------------------------
    _rb="$LIB/.reapply.state"
    rm -f "$_rb" "$_rb.tmp" 2>/dev/null
    printf 'stage=running\n' > "$_rb" 2>/dev/null
    if [ -n "${2:-}" ]; then
      ( sh "$MODDIR/fontctl.sh" apply "$2" > "$_rb.tmp" 2>&1; mv -f "$_rb.tmp" "$_rb" ) >/dev/null 2>&1 &
    else
      ( sh "$MODDIR/fontctl.sh" reapply > "$_rb.tmp" 2>&1; mv -f "$_rb.tmp" "$_rb" ) >/dev/null 2>&1 &
    fi
    echo "OK:bg"
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
    mark_dirty
    check_id "$2"
    id="$2"; shift 2
    for kv in "$@"; do
      case "$kv" in *=*) ;; *) echo "ERROR:元数据格式不正确：$kv"; exit 1 ;; esac
      meta_set "$id" "${kv%%=*}" "${kv#*=}" || { echo "ERROR:元数据格式不正确：$kv"; exit 1; }
    done
    echo "OK"
    ;;
  setmeta-many)
    mark_dirty
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
      # ★ 2026-10-22 修：一行只放一个 k=v（值里允许空格）。
          #   原来按空格切分，`family=Source Han Sans TC` 会变成
          #   family=Source / Han / Sans / TC → 族名原文永远写不进去。
          case "$_kv" in *=*) ;; *) continue ;; esac
          meta_set "$_id" "${_kv%%=*}" "${_kv#*=}" 2>/dev/null && _n=$((_n+1))
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
            # ★ 2026-10-30：计划缓存也一并清掉（其实指纹变化会自动失效，这里顺手清干净）
            rm -rf "$LIB/.plancache" 2>/dev/null
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
          skip_vf)
            case "$4" in 0|1) ;; *) echo "ERROR:取值只能是 0 或 1"; exit 1 ;; esac ;;
          skip_product|keep_samsung)
            # ★ 2026-10-24 三星 One UI 专区（高级设置里，普通用户看不到）
            case "$4" in 0|1) ;; *) echo "ERROR:取值只能是 0 或 1"; exit 1 ;; esac ;;
          targets_only|skip_other_lang|keep_serif|keep_italic_mono|keep_bold|\
          only_system_fonts|system_and_product|skip_vendor_fonts|main_only|\
          ttc_cn_only|ttc_all_faces|ttc_no_mix|mount_system_only|mount_in_service|\
          dry_run|no_auto_disable|no_rescue|no_auto_reapply|no_boot_selfcheck)
            # ★ 2026-10-24 高级设置 B1/B2/B4/B5/B6：一律 0/1，默认关 = 行为不变
            case "$4" in 0|1) ;; *) echo "ERROR:取值只能是 0 或 1"; exit 1 ;; esac ;;
          skip_vendor_dirs|whitelist|blacklist|exclude_dirs|force_list)
            # 文本型：逗号/分号分隔；空串表示不生效
            ;;
          symlink_payload)
            case "$4" in 0|1) ;; *) echo "ERROR:取值只能是 0 或 1"; exit 1 ;; esac ;;
          mount_retry|mount_delay)
            case "$4" in ''|*[!0-9]*) echo "ERROR:取值必须是数字"; exit 1 ;; esac ;;
          keep_misans|keep_flyme|no_theme_phys|keep_mitype|keep_oppo|keep_vivo|keep_harmony|keep_roboto|flyme_core|chcon_fonts|flyme_scan|hotboot_watchdog|hotboot_kill|\
          allow_sym|allow_vadj|force_manager)
            case "$4" in 0|1) ;; *) echo "ERROR:取值只能是 0 或 1"; exit 1 ;; esac ;;
          mount_mode)
            case "$4" in self|manager) ;; *) echo "ERROR:取值只能是 self 或 manager"; exit 1 ;; esac ;;
          *) echo "ERROR:未知设置项"; exit 1 ;;
        esac
        cfg_set "$3" "$4"
        # ★ 2026-11-02（红魔用户实锤"黑名单填了无效"）：角色是**扫描时**烤进
        #   4 份清单的 —— 装好模块之后才改黑/白名单，清单里的角色还是旧的，
        #   设置看起来就"永远无效"。这几项一改就**当场重扫**（几秒），
        #   新名单立刻参与角色判定；紧接着下面的预热会用新清单重算计划。
        case "$3" in
          whitelist|blacklist|exclude_dirs|force_list)
            ( sh "$MODDIR/fontctl.sh" rescan ) >/dev/null 2>&1
            ;;
        esac
        # ★ 2026-10-31：开关变了 → 计划缓存全部失效 → 后台把当前待生效字体的计划
        #   重新预热好（下一次切换仍然"第一次就命中"）。不阻塞本次返回。
        _pwp=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font" 2>/dev/null)
        case "$_pwp" in ""|none) ;; *)
          ( sh "$MODDIR/fontctl.sh" prewarm "$_pwp" ) >/dev/null 2>&1 &
        ;; esac
        echo "OK"
        ;;
      dump)
        # ★ 2026-10-24：把高级设置里的所有开关一次性吐出来（界面回显用）
        for _k in ttc_replace skip_vf keep_samsung skip_product skip_vendor_dirs \
                  targets_only skip_other_lang keep_serif keep_italic_mono keep_bold \
                  only_system_fonts system_and_product skip_vendor_fonts main_only \
                  ttc_cn_only ttc_all_faces ttc_no_mix mount_system_only mount_in_service \
                  dry_run no_auto_disable no_rescue no_auto_reapply no_boot_selfcheck \
                  whitelist blacklist exclude_dirs force_list mount_retry mount_delay \
                  keep_misans keep_flyme no_theme_phys \
                  keep_mitype keep_oppo keep_vivo keep_harmony keep_roboto flyme_core chcon_fonts flyme_scan \
                  hotboot_watchdog hotboot_kill theme_phys keep_secnum \
                  allow_sym allow_vadj force_manager; do
          case "$_k" in
            # ★ 2026-10-25：回显不用「生效值」，避免 dump 去扫字体配置（手机上要几秒，
            #   会把整个界面卡住）。界面只显示用户设置过的值即可。
            ttc_replace) _v=$(cfg_get ttc_replace auto) ;;
            symlink_payload) _v=$(cfg_get "$_k" 0) ;;
            skip_vf|keep_samsung|skip_product) _v=$(cfg_get "$_k" 0) ;;
            skip_vendor_dirs|whitelist|blacklist|exclude_dirs) _v=$(cfg_get "$_k" "") ;;
            mount_retry) _v=$(cfg_get "$_k" 3) ;;
            mount_delay) _v=$(cfg_get "$_k" 0) ;;
            ttc_cn_only) _v=$(cfg_get "$_k" 1) ;;
            keep_lang|keep_special|theme_fonts|keep_lockscreen) _v=$(cfg_get "$_k" 0) ;;
            *) _v=$(cfg_get "$_k" 0) ;;
          esac
          echo "$_k=$_v"
        done
        ;;
      *)
        # ttc_replace 回显的是**生效值**：这类机型即使没手动设过，界面开关也该是亮的
        echo "keep_lang=$(cfg_get keep_lang 0) keep_special=$(cfg_get keep_special 0) mount_mode=$(mount_mode) ttc_replace=$(ttc_effective) theme_fonts=$(cfg_get theme_fonts 0) keep_lockscreen=$(keep_lockscreen_val) symlink_payload=$(cfg_get symlink_payload 0) "
        ;;
    esac
    ;;
  panic)
    # ---------------------------------------------------------------------
    # 紧急回滚（由 service.sh 的热重启看门狗调用）
    #   只做三件事：卸掉本模块挂载 / 置回「无字体」/ 记账。不做切换那套重活。
    # ---------------------------------------------------------------------
    _n=0
    if [ -s "$LIB/.mounted" ]; then
      while IFS= read -r _d; do
        [ -n "$_d" ] || continue
        umount -l "$_d" 2>/dev/null || umount "$_d" 2>/dev/null
        _n=$(( _n + 1 ))
      done < "$LIB/.mounted"
    fi
    : > "$LIB/.mounted" 2>/dev/null
    printf 'none\n' > "$LIB/active_font" 2>/dev/null
    printf 'time=%s umount=%s via=panic\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$_n" \
      >> "$LIB/.panic.log" 2>/dev/null
    echo "OK:$_n"
    ;;
  group)
    # ---------------------------------------------------------------------
    # 字重组：用户手动把「同一套字体的多个字重」合成一张卡片
    #   group create <id1> <id2> ...   → 校验后写 group=<组长id>
    #   group remove <组长id>          → 解散
    #   group list                     → 列出
    # 只有通过校验的成员才会入组；组长 = 第一个参数。
    # ---------------------------------------------------------------------
    _gact="${2:-}"
    case "$_gact" in
      create)
        shift 2
        _first=""
        for _id in "$@"; do [ -f "$LIB/$_id.meta" ] && { _first="$_id"; break; }; done
        [ -n "$_first" ] || { echo "ERROR:选中的字体都不存在"; exit 1; }
        _fam=$(meta_get "$_first" fam)
        case "$_fam" in ""|none) echo "ERROR:这份字体没有可用的族名，无法组合"; exit 1 ;; esac
        _famtext=$(meta_get "$_first" family)
        _sub_first=$(meta_get "$_first" subfamily)
        _r_latin=$(meta_get "$_first" rate_latin); _r_cjk=$(meta_get "$_first" rate_cjk)
        _r_punct=$(meta_get "$_first" rate_punct); _r_sym=$(meta_get "$_first" rate_symbols)
        _upem=$(meta_get "$_first" upem); _cjk=$(meta_get "$_first" cjk)
        _lat=$(meta_get "$_first" latin); _gly=$(meta_get "$_first" glyphs)
        _ok=0
        for _id in "$@"; do
          [ -f "$LIB/$_id.meta" ] || { printf '跳过 %s：不存在\n' "$_id"; continue; }
          [ "$(meta_get "$_id" outline)" = 1 ] || { printf '跳过 %s：没有可用轮廓\n' "$_id"; continue; }
          if [ "$(meta_get "$_id" merged)" = 1 ] || [ "$(meta_get "$_id" merge)" = 1 ]; then
            printf '跳过 %s：这是合成字体，不能组字重组\n' "$_id"; continue
          fi
          _m_fam=$(meta_get "$_id" fam)
          [ -n "$_m_fam" ] || { printf '跳过 %s：档案里没有族名（请刷新页面后重新导入该字体）\n' "$_id"; continue; }
          [ "$_m_fam" = "$_fam" ] || { printf '跳过 %s：族名不同（%s ≠ %s）\n' "$_id" "$_m_fam" "$_fam"; continue; }
          # 族名的**原文**也必须一致（归一化键可能撞车：pico 和 Roboto 被误判同族过）
          if [ -n "$_famtext" ]; then
            _f2=$(meta_get "$_id" family)
            if [ -n "$_f2" ] && [ "$_f2" != "$_famtext" ]; then
              printf '跳过 %s：族名原文不同（%s ≠ %s）\n' "$_id" "$_f2" "$_famtext"; continue
            fi
          fi
          _u2=$(meta_get "$_id" upem)
          if [ -n "$_upem" ] && [ -n "$_u2" ] && [ "$_upem" != "$_u2" ]; then
            printf '跳过 %s：upem %s ≠ %s\n' "$_id" "$_u2" "$_upem"; continue
          fi
          if [ "$(meta_get "$_id" cjk)" != "$_cjk" ] || [ "$(meta_get "$_id" latin)" != "$_lat" ]; then
            printf '跳过 %s：语种覆盖类别不同\n' "$_id"; continue
          fi
          # upem 必须相同（同一套字体不会换 upem）
          _u_l=$(meta_get "$_first" upem); _u_m=$(meta_get "$_id" upem)
          if [ -n "$_u_l" ] && [ -n "$_u_m" ] && [ "$_u_l" != "$_u_m" ]; then
            printf '跳过 %s：upem %s ≠ %s\n' "$_id" "$_u_m" "$_u_l"; continue
          fi
          # 覆盖率逐项相差 ≤ 2
          _bad=0
          for _k in rate_latin rate_cjk rate_punct rate_symbols; do
            _a=$(meta_get "$_first" "$_k"); _b=$(meta_get "$_id" "$_k")
            case "$_a" in ''|*[!0-9]*) continue ;; esac
            case "$_b" in ''|*[!0-9]*) continue ;; esac
            _d=$(( _a - _b )); [ "$_d" -lt 0 ] && _d=$(( -_d ))
            [ "$_d" -gt 2 ] && { _bad=1; printf '跳过 %s：覆盖率差异过大（%s %s%% vs %s%%）\n' "$_id" "$_k" "$_b" "$_a"; break; }
          done
          [ "$_bad" = 0 ] || continue
          # 子族名必须不同（同一字重的两份拷贝不该组成一组）
          _s1=$(meta_get "$_first" subfamily); _s2=$(meta_get "$_id" subfamily)
          if [ -n "$_s1" ] && [ -n "$_s2" ] && [ "$_s1" = "$_s2" ]; then
            printf '跳过 %s：字重标识与组长相同（%s）\n' "$_id" "$_s2"; continue
          fi
          case "$_gly:$(meta_get "$_id" glyphs)" in
            *[!0-9]*|*:|"") ;;
            *)
              _lo=$(( _gly * 97 / 100 )); _hi=$(( _gly * 103 / 100 ))
              _g2=$(meta_get "$_id" glyphs)
              if [ "$_g2" -lt "$_lo" ] || [ "$_g2" -gt "$_hi" ]; then
                printf '跳过 %s：字形数 %s 与组长 %s 相差过大\n' "$_id" "$_g2" "$_gly"; continue
              fi ;;
          esac
          setmeta_pair "$_id" group "$_first" 2>/dev/null || \
            { sed -i "/^group=/d" "$LIB/$_id.meta" 2>/dev/null; printf 'group=%s\n' "$_first" >> "$LIB/$_id.meta"; }
          _ok=$(( _ok + 1 ))
        done
        [ "$_ok" -ge 2 ] || { echo "ERROR:至少需要 2 份可组合的字体（现在 $_ok 份）"; exit 1; }
        echo "OK:已组合 $_ok 份字体为一个字重组（组长 $_first）"
        ;;
      remove)
        _g="${3:-}"
        [ -n "$_g" ] || { echo "ERROR:缺少组长 id"; exit 1; }
        _n=0
        for _f in "$LIB"/f*.meta "$LIB"/builtin_*.meta; do
          [ -e "$_f" ] || continue
          if [ "$(sed -n 's/^group=//p' "$_f" 2>/dev/null | tail -n1 | tr -d '\r')" = "$_g" ]; then
            sed -i '/^group=/d' "$_f" 2>/dev/null
            _n=$(( _n + 1 ))
          fi
        done
        echo "OK:已解散字重组（$_n 份）"
        ;;
      list)
        for _f in "$LIB"/f*.meta; do
          [ -e "$_f" ] || continue
          _g=$(sed -n 's/^group=//p' "$_f" 2>/dev/null | tail -n1 | tr -d '\r')
          [ -n "$_g" ] || continue
          _i=${_f##*/}; _i=${_i%.meta}
          printf '%s %s\n' "$_g" "$_i"
        done
        ;;
      *) echo "用法: group create|remove|list"; exit 2 ;;
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
    mark_dirty
    [ -f "$MODDIR/pending_font" ] && cp -f "$MODDIR/pending_font" "$MODDIR/active_font"
    cp -f "$MODDIR/active_font" "$LIB/last_selection" 2>/dev/null
    refresh_prop
    ;;
  prop)
    refresh_prop
    ;;
  *)
    echo "用法: sh fontctl.sh status|list|import|upload-start|upload-finish|ls|rename|delete|apply|reapply|plan|setmeta|settings|verify|relink|conflicts|report|diag|sync|prop|ack|prewarm|prewarm-bg|prewarm-all"
    exit 2
    ;;
esac
