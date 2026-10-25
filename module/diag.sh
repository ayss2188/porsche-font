#!/system/bin/sh
# 诊断脚本构建戳（报告头部会写出来，便于分辨装的是哪一版）
DIAG_BUILD="2026-10-23.19"
# diag.sh - 一键体检
#
# 目的：把「重启了也不生效 / 字体没变化」的可能原因一次跑完，并给出大白话结论。
# 特点：
#   1. 结论在最上面，用户截图或保存后发出来即可；
#   2. 不依赖开机脚本是否执行（安装那一刻就能跑）；
#   3. 覆盖厂商字体来源（字体包 / flipfont、/data/fonts 可更新字体、主题 overlay、
#      floating_feature.xml）、fonts*.xml 全量 family 映射、字体目录完整清单、.ttc 合集；
#   4. 会做一次真实的「槽位 bind 挂载 → 校验 → 立刻卸载」，当场证明能不能挂。
#
# 用法：
#   sh diag.sh brief     只打印结论（「操作」按钮 / 速查用）
#   sh diag.sh full      打印完整报告（11 节，含原始配置与哈希清单）
#   sh diag.sh install   生成完整报告并写入 Download，同时打印结论（「操作」按钮用）
#   sh diag.sh save      生成完整报告并写入 Download，只输出 OK:<路径>
#   sh diag.sh bg [force]         后台生成（WebUI 用；force = 强制重来）
# ★ 1.0.9 起**只有一种口径 = 完整报告**：「快速体检」已删除（作者只有小米机器，
#   适配别的机型完全靠别人发的报告，半份报告不够定位问题）。
#   sh diag.sh state     输出状态文件内容（写着 running 但进程已死/心跳停了会明确报出来）
#   sh diag.sh text      输出上一次生成好的报告正文（小文件用）
#   sh diag.sh textpage <offset> <len>  只取正文的一段（界面"看更多"用，避免大字符串过桥）
#   sh diag.sh partinfo  生成中：回报已写字节数 + 阶段（不起采集）
#   sh diag.sh cancel    中止正在进行的生成（立刻写状态，杀进程放后台）
#   sh diag.sh savenow   立刻把现在的内容存到 Download（生成中 = 存已写好的部分）
#   sh diag.sh estimate  预估本机耗时（只数文件，不读内容）
#   sh diag.sh clean     清理后台残留 + 卸掉上次被强杀留下的挂载测试层
#   sh diag.sh build     真正干活的那个（由 bg 在后台调用，一般不用手动跑）
#
# 性能约定（界面卡不卡就靠这条）：state / text / textpage / partinfo / cancel / bg /
#   clean / estimate / savenow 这些"界面按钮"用的模式绝不做采集（不进 collect()），
#   毫秒级返回；只有 brief / full / build / save / install 才采集（且只采集一次）。
#   WebUI 平时靠 fetch webroot/diag/state.txt 读进度，连 shell 都不用起。
#
# 本脚本永远返回 0，避免影响安装流程。

MODDIR=${0%/*}
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/custom_font_switcher
# ★ 2026-10-15：`sh diag.sh`（相对路径、不带目录）时 `${0%/*}` 会得到字面量 `.`，
#   报告里那行"运行位置: ."看着莫名其妙，而且后面拼 "$MODDIR/common.sh" 也是 "./common.sh"。
#   这里把 `.` / 空 都归一化成真正的绝对路径。
case "$MODDIR" in
  .|"") MODDIR=$(pwd 2>/dev/null || echo /data/adb/modules/custom_font_switcher) ;;
esac
# ⚠ 别写成 `. "$MODDIR/x.sh" 2>/dev/null`：`.` 是特殊内建，**打不开文件会直接结束整个脚本**
#   （`2>/dev/null` 只藏报错信息，挡不住它退出；实测退出码 2）。缺一个必需文件时，
#   宁可给一句能看懂的话，也不要"报告打不开、用户不知道为什么"。
for _df in common.sh slots.sh mount.sh; do
  [ -f "$MODDIR/$_df" ] || { echo "ERROR:模块文件缺失（$_df）—— 报告无法生成，请重新安装模块"; exit 0; }
  . "$MODDIR/$_df"
done
unset _df
# ttcwrap.sh 是可选的（只影响 .ttc 合集那一块）；缺了不能把整个诊断带走
[ -f "$MODDIR/ttcwrap.sh" ] && . "$MODDIR/ttcwrap.sh"

LIB=${LIB:-/data/adb/custom_font_lib}
SETTINGS=${SETTINGS:-$LIB/settings.conf}

ID=$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
[ -n "$ID" ] || ID=custom_font_switcher
M="/data/adb/modules/$ID"
[ -d "$M" ] || M="$MODDIR"
UPD="/data/adb/modules_update/$ID"
IN_INSTALL=0
case "$MODDIR" in
  /data/adb/modules_update/*) IN_INSTALL=1 ;;
esac

GP=/system/bin/getprop;     [ -x "$GP" ] || GP=getprop
CMD=/system/bin/cmd;        [ -x "$CMD" ] || CMD=cmd
MO=/system/bin/mount;       [ -x "$MO" ] || MO=mount
UMO=/system/bin/umount;     [ -x "$UMO" ] || UMO=umount
PM=/system/bin/pm;          [ -x "$PM" ] || PM=pm
SETBIN=/system/bin/settings; [ -x "$SETBIN" ] || SETBIN=settings

MODE=${1:-full}
# 1.0.9.2：新增「速度」参数（界面在点报告后当场选）：
#   full   = 全速（不降优先级，最快；CPU 满负荷，可能发热/变卡）
#   gentle = 慢慢生成（自动让路给系统，慢一些但不打扰）
# 报告内容**完全一样**，只是快慢不同。默认 gentle（省电、不打扰）。
# 用法：diag.sh bg force full        ← 全速
#       diag.sh bg force gentle      ← 慢慢（或省略第 2 个参数）
DIAG_SPEED=gentle
for _sp in "$@"; do
  case "$_sp" in
    full|fast) DIAG_SPEED=full ;;
    gentle|slow|nice) DIAG_SPEED=gentle ;;
  esac
done
# 环境变量优先（旧的 CFS_DIAG_FULLSPEED=1 也继续认，兼容手工调用）
[ "${CFS_DIAG_FULLSPEED:-0}" = 1 ] && DIAG_SPEED=full
export DIAG_SPEED
# 1.0.9：**只有一种口径 = 完整报告**。"快速体检"已删除 ——
#   作者只有小米机器，适配别的机型完全靠别人发的报告，半份报告不够定位问题。
# 指纹（1.0.9.2）：改用**稀疏指纹** —— 大小 + 修改时间 + 头尾各 64KB 的 sha256。
#   目的只是判断"这个槽位的字体有没有被换过"（内容变没变），不是加密校验。
#   1.0.9.1 的全量 sha256 在真机上让第 6 步花了 391 秒（字体目录约 700MB），现在降到十几秒。
#   快的地方在于"同一份文件只真正算一次" + 批量 + 降优先级，而不是少读数据。
FAST=0
BG_FAST=${BG_FAST:-0}
DL=/data/media/0/Download
# 1.0.9：只有一份报告（完整）。文件名固定「完整体检报告.txt」，不再有"快速体检报告"。
# 固定备用名 font_diag.txt 始终等于"最近生成的那一份"。
# 注意：写入是"接力"的 —— 口径文件写不进去（存储满 / 个别文件系统不吃某个名字）就退到
# font_diag.txt，再退到模块库目录，绝不让"报告生成好了却一个文件都没有"
OUTFILE_FAST="$DL/完整体检报告.txt"     # 兼容旧调用点，都指向同一份
OUTFILE_FULL="$DL/完整体检报告.txt"
# 1.0.9：不再产 font_diag.txt 备用名（同内容两份只会让人困惑）
# 1.0.9：不再产"未完成的体检报告.txt"（生成中直接覆盖下面那一份）
XMLS="/system/etc/fonts.xml /system/etc/font_fallback.xml /system/etc/fonts_additional.xml /system/etc/fonts_customization.xml"
# 界面直接 fetch 的目录（在 webroot 里，读它不用起 shell，不会卡住 WebUI）
# 每次写状态 / 每个阶段结束时顺手镜像一份到这里，WebUI 用 fetch 读：
# 不起 shell 进程 = 点按钮不会卡、轮询不吃 CPU（这是"按了立刻有反应"的关键）
WEB="$MODDIR/webroot/diag"
WEB_STATE="$WEB/state.txt"      # 状态镜像（fetch 用，非隐藏文件名，避免被 web 服务器挡掉）
WEB_PART="$WEB/part.txt"        # 正在生成的内容（只镜像开头一段，够界面边生成边看）
WEB_HEAD="$WEB/head.txt"        # 生成完成后报告的预览（只镜像开头一段）
WEB_META="$WEB/meta.txt"        # 报告体积等信息
PART_MIRROR_BYTES=40000         # 镜像/预览只取开头这么多字节（textarea 塞太多会卡死 WebView）
MT_LOCK="$LIB/.mt.lock"
TIMING="$LIB/.diag.timing"

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
NOW=$(date +%s 2>/dev/null); NOW=${NOW:-0}
UP=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1); UP=${UP:-0}
BOOTEPOCH=$((NOW - UP))

mtime() { stat -c %Y "$1" 2>/dev/null; }
mstamp() { date -r "$1" '+%m-%d %H:%M' 2>/dev/null || mtime "$1"; }
newer_boot() { local t; t=$(mtime "$1"); [ -n "$t" ] && [ "$t" -ge "$BOOTEPOCH" ]; }
older_boot() { local t; t=$(mtime "$1"); [ -n "$t" ] && [ "$t" -lt "$BOOTEPOCH" ]; }
since_txt() {
  if newer_boot "$1"; then printf '本次开机之后'
  elif older_boot "$1"; then printf '本次开机之前'
  else printf '?'; fi
}
hr() { printf '  ------------------------------------------------------------\n'; }
# 表信息（sfnt 标签）只对"配置引用到的 + TTC"算 —— 每个文件要读好几处，是最费 CPU 的一步；
# 其余文件只记 4 字节魔数（够判断是不是真字体）。这样"完整报告"也不会卡在最后一步。
want_tags() {
  case "$1" in *.ttc|*.TTC) return 0 ;; esac
  case "$XMLNAMES_STR" in *" $1 "*) return 0 ;; esac
  return 1
}


# 给可能卡住的系统命令加超时（没有 timeout 就直接跑），避免体检/安装被某个命令挂住
tmo() {
  # 给可能卡住的系统命令加超时。三层，从最可靠到最保守：
  #   ① CFS_TMO_BIN（外部指定）
  #   ② 系统自带 timeout（Android 7+ 的 toybox 基本都有）
  #   ③ 纯 shell 看门狗（只有①②都没有时才用）
  # ★ 看门狗的关键细节（1.0.9.2，踩过两次）：
  #   · 只 kill 主进程是不够的 —— `dumpsys` 这类命令卡在内核里时不响应 TERM，
  #     它 fork 出来的子进程还在，管道另一端（grep/head）就一直等，等于没超时。
  #   · 但**无条件** `kill -TERM -$pid`（杀进程组）更危险：busybox 的 setsid 在
  #     "当前进程已是组长"时会失败，后台命令就与脚本同组 → 杀组 = **把调用方自己杀掉**
  #     （真机症状：报告正文生成了，最后写文件那一步却是空的）。
  #   · 所以：**先看 setsid 有没有真的成功**；成功才杀组，失败只杀单个 pid。
  local t="$1"; shift
  if [ -n "$CFS_TMO_BIN" ] && [ -x "$CFS_TMO_BIN" ]; then "$CFS_TMO_BIN" "$t" "$@"; return $?; fi
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; return $?; fi
  # ---- 以下只在"没有 timeout"时执行 ----
  local o pid wd rc own=0
  o="${LIB:-/data/local/tmp}/.tmo.out"
  mkdir -p "${o%/*}" 2>/dev/null
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$o" 2>/dev/null &
    pid=$!
    # 新会话的组长 pid 就等于它自己；用它当"能不能杀组"的判据
    [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ] && own=1
  else
    "$@" >"$o" 2>/dev/null &
    pid=$!
  fi
  (
    _i=0
    while [ "$_i" -lt "$t" ]; do
      sleep 1
      kill -0 "$pid" 2>/dev/null || exit 0
      _i=$((_i + 1))
    done
    if [ "$own" = 1 ]; then
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    else
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill -TERM "$wd" 2>/dev/null
  cat "$o" 2>/dev/null
  rm -f "$o" 2>/dev/null
  [ "$rc" = 143 ] || [ "$rc" = 137 ] && rc=124
  return "$rc"
}
tag() { sed -n 's/^version=//p' "$1/module.prop" 2>/dev/null | head -n1 | tr -d '\r'; }
# XML 规范化：把标签拆成一行一个，方便 grep 上下文
# ★ 2026-10-18（诊断提速）：原来是 `tr | sed` 两个子进程，改成单个 awk。
#   输出已用真机形态的 fonts.xml 逐字节验证过完全一致（换行/制表/相邻标签都对）。
#   这个函数在完整报告里要被调几十次，省一半进程。
xmlnorm() { awk 'BEGIN { RS = "" } { gsub(/[\r\n\t]/, " "); gsub(/></, ">\n<"); print }' "$1" 2>/dev/null; }
# XML 拆成 <family / <font / </font 各一行，便于提取 family -> 文件 的对应关系
xmlfam() {
  tr '\n\r\t' '   ' < "$1" 2>/dev/null \
    | sed -e 's/<family/\n<family/g' -e 's#</family>#\n#g' \
          -e 's/<font/\n<font/g' -e 's#</font>#\n#g'
}
# 一次性列出 8 进制大小
size_kb() { local s; s=$(stat -c %s "$1" 2>/dev/null); [ -n "$s" ] && echo "$((s / 1024)) KB" || echo "?"; }
# 字体文件里的 sfnt 表标签（判断是否可变字体、有没有 glyf/CFF）
# 只起 head + tr 两个进程，标签匹配用纯 shell（以前是 head|tr|grep|sort|tr 五个进程，
# 每个"被配置引用的字体"都要付一次，字体多的机器上很可观）
SFNT_KNOWN="cmap glyf loca head hhea hmtx maxp name OS/2 post fvar gvar avar STAT HVAR MVAR CFF CFF2 GPOS GSUB kern DSIG"

sfnt_tags() {
  _ST_RAW=$(head -c 3072 "$1" 2>/dev/null | tr -c 'A-Za-z0-9/ ' '\n')
  [ -n "$_ST_RAW" ] || return 0
  _ST_OUT=""
  for _ST_T in $SFNT_KNOWN; do
    case "
$_ST_RAW
" in
      *"
$_ST_T
"*) _ST_OUT="$_ST_OUT$_ST_T " ;;
    esac
  done
  printf '%s' "$_ST_OUT"
}
# TTC 合集头：'ttcf' + 主版本 + 次版本 + numFonts(偏移 8，4 字节**大端**)
# ⚠ 不能直接用 `od -tu4`：那是按本机字节序读的，字节会颠倒 —— face 数 5 会显示成 83886080
#   （真机报告里就是这么错的），按大端自己算才对。
ttc_faces() {
  local b
  b=$(od -An -tu1 -j8 -N4 "$1" 2>/dev/null)
  set -- $b
  [ $# -ge 4 ] || { echo "?"; return 0; }
  echo $(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
}
ttc_tag() { head -c 4 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'; }

# ---------------------------------------------------------------------------
# 读一个 .ttc（或单文件字体）里第 N 号 face 的 PostScript 名（nameID=6；没有就退回家族名 nameID=1）
#
# 用途：诊断里把"原合集"和"我们生成的合集"每号 face 的名字并排打出来 ——
# 真机反馈"中文没变"时，一眼就能看出是我们合成的合集结构不对，还是系统不认它。
# 纯 shell + od（不起 Python），单文件字体当成只有 0 号 face。
# ---------------------------------------------------------------------------
ttc_face_name() {
  local f="$1" i="${2:-0}" fo nt at tag off len b p so cnt rec nid plid slen soff
  local tbh tb bytes j c out="" want=0 pick=0 want_plid=0 fb_off="" fb_len=0 fb_plid=0
  [ -f "$f" ] || { echo "?"; return 0; }
  fo=0
  if [ "$(head -c 4 "$f" 2>/dev/null)" = ttcf ]; then
    b=$(od -An -tu1 -j$(( 12 + 4 * i )) -N4 "$f" 2>/dev/null); set -- $b
    [ $# -ge 4 ] || { echo "?"; return 0; }
    fo=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
    [ "$fo" -ge 12 ] 2>/dev/null || { echo "?"; return 0; }
  fi
  b=$(od -An -tu1 -j$(( fo + 4 )) -N2 "$f" 2>/dev/null); set -- $b
  [ $# -ge 2 ] || { echo "?"; return 0; }
  nt=$(( $1 * 256 + $2 ))
  [ "$nt" -ge 1 ] && [ "$nt" -le 512 ] 2>/dev/null || { echo "?"; return 0; }
  # 一次把整个表目录读出来，在 shell 里找 tag = "name"（6e 61 6d 65）的那条
  bytes=$(od -An -tu1 -j"$fo" -N$(( 12 + 16 * nt )) "$f" 2>/dev/null | tr -s ' \n' ' ')
  set -- $bytes
  # 跳过 face 头 12 字节
  j=0; while [ "$j" -lt 12 ] && [ $# -gt 0 ]; do shift; j=$((j+1)); done
  tag=""; off=""; len=""
  c=0
  while [ "$c" -lt "$nt" ] && [ $# -ge 16 ]; do
    if [ "$1" = 110 ] && [ "$2" = 97 ] && [ "$3" = 109 ] && [ "$4" = 101 ]; then
      shift 8
      off=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); shift 4
      len=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); shift 4
      tag=name
      break
    fi
    j=0; while [ "$j" -lt 16 ] && [ $# -gt 0 ]; do shift; j=$((j+1)); done
    c=$((c+1))
  done
  [ "$tag" = name ] || { echo "?"; return 0; }
  # name 表头：format(2) count(2) stringOffset(2)
  b=$(od -An -tu1 -j"$off" -N6 "$f" 2>/dev/null); set -- $b
  [ $# -ge 6 ] || { echo "?"; return 0; }
  cnt=$(( $3 * 256 + $4 ))
  so=$(( $5 * 256 + $6 ))
  [ "$cnt" -ge 1 ] && [ "$cnt" -le 400 ] 2>/dev/null || { echo "?"; return 0; }
  tb=$(od -An -tu1 -j$(( off + 6 )) -N$(( 12 * cnt )) "$f" 2>/dev/null | tr -s ' \n' ' ')
  # 一条 name 记录 12 字节：platformID(2) encodingID(2) languageID(2) nameID(2) length(2) offset(2)
  # 只要 nameID=6（PostScript 名）；优先 Windows(3) / Unicode(0) 平台 —— 这两个都是 UTF-16BE
  set -- $tb
  c=0
  while [ "$c" -lt "$cnt" ] && [ $# -ge 12 ]; do
    plid=$(( $1 * 256 + $2 ))
    nid=$(( $7 * 256 + $8 ))
    slen=$(( $9 * 256 + ${10} ))
    # 注意：位置参数 ≥10 必须写 ${11} —— 写成 $11 会被当成 ${1} 后面跟一个字面量 1（踩过）
    soff=$(( ${11} * 256 + ${12} ))
    if [ "$nid" = 6 ]; then
      case "$plid" in
        3|0) pick=$(( off + so + soff )); want=$slen; want_plid=$plid; break ;;
        *) [ -z "$fb_off" ] && { fb_off=$(( off + so + soff )); fb_len=$slen; fb_plid=$plid; } ;;
      esac
    fi
    j=0; while [ "$j" -lt 12 ] && [ $# -gt 0 ]; do shift; j=$((j+1)); done
    c=$((c+1))
  done
  if [ -z "$pick" ] && [ -n "$fb_off" ]; then pick=$fb_off; want=$fb_len; want_plid=$fb_plid; fi
  [ -n "$pick" ] && [ "${want:-0}" -gt 0 ] 2>/dev/null || { echo "?"; return 0; }
  [ "$want" -le 128 ] 2>/dev/null || want=128
  b=$(od -An -tu1 -j"$pick" -N"$want" "$f" 2>/dev/null)
  # platformID 3 / 0 都是 UTF-16BE：ASCII 字符是 (0, 码) 成对，跳过高字节；
  # 非 ASCII 用 ? 代替。八进制转义用纯 shell 算（每个字符起一个 printf 进程太慢）。
  j=0
  for v in $b; do
    case "$want_plid" in
      3|0)
        j=$((j+1))
        [ $(( j % 2 )) = 1 ] && continue ;;
    esac
    if [ "$v" -ge 32 ] && [ "$v" -lt 127 ]; then
      if [ "$v" = 37 ]; then out="$out%%"; else out="$out\\$(( v / 64 ))$(( (v / 8) % 8 ))$(( v % 8 ))"; fi
    else
      out="$out?"
    fi
  done
  [ -n "$out" ] || out="?"
  printf "$out"
}
# 文件首 4 字节（十六进制）：一个 od 进程，空格用 shell 去掉（以前是 head|od|tr 三个进程）
magic4() { local m; m=$(od -An -tx1 -N4 "$1" 2>/dev/null); set -- $m; printf '%s' "$1$2$3$4"; }

# ---------------------------------------------------------------------------
# 批量取大小 / 批量哈希（"最后一步特别慢"的主要来源就在这里）
#   以前：每个文件各起一次 stat + sha256sum + head|od|tr —— 几百个文件就是几千个进程，
#         每个进程都要 fork/exec 一个动态链接的可执行文件，CPU 直接被 fork 风暴打满。
#   现在：一个目录一次 stat；哈希一批文件一次 sha256sum；魔数一个目录一次 head+od。
# ---------------------------------------------------------------------------
SIZE_MAP=""
# load_sizes <目录>：一次 stat 建好"路径 -> 大小"表（纯 shell 查表，不再起进程）
load_sizes() {
  SIZE_MAP=""
  _LS_RAW=$(stat -c '%s %n' "$1"/* 2>/dev/null)
  [ -n "$_LS_RAW" ] || return 0
  while IFS= read -r _LS_LN; do
    [ -n "$_LS_LN" ] || continue
    _LS_S=${_LS_LN%% *}
    _LS_P=${_LS_LN#* }
    isnum "$_LS_S" || continue
    SIZE_MAP="$SIZE_MAP|$_LS_P=$_LS_S"
  done <<EOF
$_LS_RAW
EOF
  return 0
}
size_of() {
  case "$SIZE_MAP" in
    *"|$1="*) _SO_V=${SIZE_MAP#*"|$1="}; printf '%s' "${_SO_V%%|*}" ;;
    *)        printf '?' ;;
  esac
}
# ---------------------------------------------------------------------------
# ★ 2026-10-14：**批量 stat 建表**（大小 / 修改时间）
#
# 为什么加：真机报告实测 24~29 分钟，最贵的是"逐文件起进程"。
#   一加 218 个字体文件、三星 274 个（三星那份**总共 1.3 GB**，单个最大 78MB）。
#   fp_of() 原来每文件 2 次 stat（%s 和 %Y）→ 400~550 次 fork/exec。
#
#   现在：一个目录**一次** `stat -c '%s %Y %n' 目录/*` 就把两样都拿到，
#   之后查询是纯 shell 字符串匹配（零进程）。
#
# ⚠️⚠️ 但**不要**把 inode 去重也做成"大字符串查表" —— 这是本文件里踩过的坑，
#   教训就在下面第 2438 行附近（原文照抄）：
#       「我试过"整个目录一次 stat 建表 + 内存查表"，真机实测**更慢**：
#         每文件 stat：288 秒 → 批量建表 + 大字符串查表：**314 秒**
#         原因：case 匹配要在上万字符的表里逐个匹配，纯 shell 字符串匹配比起一次 stat 还贵。
#         教训：**"少起进程"不等于"更快"** —— 大字符串查表在 shell 里也是 O(n·m)。」
#   所以这里**只**建两张**定长前缀**表（路径→大小、路径→mtime），
#   查表用的是 `case "$MAP" in *"|$path="*)` 这种**单次前缀匹配**；
#   而 inode 去重那条路**保持原样**（逐文件 stat），别去动它。
#
# ⚠️ 兼容性：真机是 **toybox**（不是 GNU coreutils）。`-c` 加 `%s/%Y/%n`
#   在 toybox 上可用 —— 报告里 FONT_META 段的大小列就是这么来的。
#   查不到时**回退去 stat**，保证任何情况下结果都和以前一致（只是慢一点）。
# ---------------------------------------------------------------------------
SZ_MAP=""; MT_MAP=""
load_meta() {   # $1=目录
  local d="$1" raw ln sz mt path rest
  SZ_MAP=""; MT_MAP=""
  [ -d "$d" ] || return 0
  raw=$(stat -c '%s %Y %n' "$d"/* 2>/dev/null)
  [ -n "$raw" ] || return 0
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    sz=${ln%% *}
    rest=${ln#* }
    mt=${rest%% *}
    path=${rest#* }
    [ -n "$path" ] || continue
    isnum "$sz" || continue
    SZ_MAP="$SZ_MAP|$path=$sz"
    MT_MAP="$MT_MAP|$path=$mt"
  done <<EOF
$raw
EOF
  # load_meta 同时把"路径→大小"表也建好了，于是 size_of() 不用再单独 stat 一遍
  SIZE_MAP="$SZ_MAP"
  return 0
}
# 查表版：拿不到就回退去 stat（保证行为不变）
sz_lookup() {
  case "$SZ_MAP" in
    *"|$1="*) _SZ_V=${SZ_MAP#*"|$1="}; printf '%s' "${_SZ_V%%|*}" ;;
    *)        stat -c %s "$1" 2>/dev/null ;;
  esac
}
mt_lookup() {
  case "$MT_MAP" in
    *"|$1="*) _MT_V=${MT_MAP#*"|$1="}; printf '%s' "${_MT_V%%|*}" ;;
    *)        stat -c %Y "$1" 2>/dev/null ;;
  esac
}
# 指纹相关的累加器（每批用完后在 hash_flush 里清零）
HASH_BATCH=""; HASH_BN=0; HN=0
HASH_KEY=""; HASH_MAP=""

# 单个文件的指纹（1.0.9.2 起：**稀疏指纹**，不再全量读盘）
#
# 为什么改（真机实测数据）：
#   截至 1.0.9.1 这里用 `sha256sum` 全量读文件。作者机器上字体目录里躺着
#   63 个 44.8MB 的大文件（去重后仍有约 700MB），全量 sha256 让"第 6 步"花了 **391 秒**。
#   而这一步的**唯一目的**是回答"这个槽位的字体有没有被换过"——
#   也就是"内容有没有变"，不是做加密校验、也不是防碰撞。
#
#   所以改成 rsync/git 那类工具的常规做法：**大小 + 修改时间 + 头尾各 64KB**。
#   · 读盘量从 ~700MB 降到 ~37MB（293 个文件 × 128KB），快一两个数量级；
#   · 判"字体有没有被替换"完全够用：替换后大小/首尾数据必然变化；
#   · 唯一理论盲区：同大小、同 mtime、且首尾 64KB 都一样 —— 两个不同字体同时满足，
#     概率低到可以忽略（真有这种情况，第 5 节还有 dev:inode 与魔数可交叉验证）。
#
# 输出直接就是"哈希 大小 路径"里的哈希字段（大小/mtime 已混进去），所以调用方不用改。

# ---------------------------------------------------------------------------
# ★ 2026-10-22（提速）：指纹缓存
#   完整报告的大头是给几百个字体算稀疏指纹（每文件读头尾 64KB 再 sha256）。
#   但"字体有没有被换过"这个问题，同一台机器上绝大多数文件是长期不变的 ——
#   所以用「路径+大小+修改时间」作为键做缓存，命中就直接复用。
#   缓存是**可丢弃的加速层**：删掉它只会让下次慢一点，不影响任何结论。
# ---------------------------------------------------------------------------
FP_CACHE_FILE="$LIB/.fp.cache"
FP_CACHE=""
FP_CACHE_SP=""
FP_TAB='	'          # 直接写字面 Tab：$(printf '\\t') 在部分设备上会返回空

fp_cache_load() {
  FP_CACHE=""
  [ -s "$FP_CACHE_FILE" ] || return 0
  # 一行一条，转成用 | 分隔的串，方便纯 shell 做子串匹配（零进程）
  # ★ 2026-10-23（真机数据）：缓存行里的分隔符可能是**多个空格**，
  #   直接按 Tab 拼键永远匹配不上（1731 条缓存，命中 0 次）。
  #   这里一次性规范成「路径<TAB>大小<TAB>mtime<TAB>哈希」，之后所有比较都按 Tab 来。
  # 条数上限：只保留最后 6000 条，避免文件无限膨胀 + 变量过大
  _cl=$(wc -l < "$FP_CACHE_FILE" 2>/dev/null | tr -d ' ')
  case "$_cl" in ''|*[!0-9]*) _cl=0 ;; esac
  if [ "$_cl" -gt 6000 ]; then
    tail -n 6000 "$FP_CACHE_FILE" > "$FP_CACHE_FILE.tmp.$$" 2>/dev/null && mv -f "$FP_CACHE_FILE.tmp.$$" "$FP_CACHE_FILE" 2>/dev/null
  fi
  # ★ 2026-10-23 定稿：用 awk 的**默认分隔符**（连续空白）规范成 Tab 分隔。
  #   踩过的坑：
  #     · tr -s ' \t' '\t' —— 写进脚本后变成双反斜杠，tr 当成"反斜杠和字母 t"，没压缩
  #     · $(printf '\t')   —— Tab 在命令替换里会被吞掉，键里就没有分隔符
  #   awk 默认 FS 天然按"连续空白"切分，不写任何转义，最稳。
  FP_CACHE=$(awk 'NF >= 4 { print $1 "\t" $2 "\t" $3 "\t" $4 }' "$FP_CACHE_FILE" 2>/dev/null | tr '\n' '|')
  if [ -z "$FP_CACHE" ]; then
    FP_CACHE=$(tr '\n' '|' < "$FP_CACHE_FILE" 2>/dev/null)
  fi
  return 0
}

# 查缓存：$1=路径 $2=大小 $3=mtime → 命中则把 hash 放进 FP_HIT
fp_cache_hit() {
  local key v _mt3 _h _stored_mt _mf
  # ★ 2026-10-23：如果连续 miss 超过 30 次且一次都没命中，说明键/路径有未知差异，
  #   本次直接停用缓存（不再白花 CPU）。缓存只是加速层，停用它不影响任何结论。
  _mf="${FP_STAT_FILE:-}"
  if [ -n "$_mf" ] && [ "$FP_CACHE" != "" ]; then
    case "$(tail -c 40 "$_mf" 2>/dev/null)" in
      *HH*|*H*) : ;;                       # 已经命中过，正常使用
      *)
        if [ "$(tail -c 40 "$_mf" 2>/dev/null | tr -cd N | wc -c | tr -d ' ')" -gt 30 ] 2>/dev/null; then
          FP_CACHE=""; FP_CACHE_DISABLED=1
        fi
        ;;
    esac
  fi
  # 兜底：FP_TAB 若为空（极端环境），用一个从 IFS 取的 Tab
  if [ -z "${FP_TAB:-}" ]; then
    FP_TAB=$(printf '\t' 2>/dev/null; printf '\t' 2>/dev/null)
    [ -n "$FP_TAB" ] || FP_TAB=${IFS%" "}
    [ "$(printf '%s' "$FP_TAB" | wc -c | tr -d ' ')" = "1" ] || FP_TAB="	"
  fi
  [ -n "$FP_LOADED" ] || { FP_LOADED=1; fp_cache_load; }
  [ -n "$FP_CACHE" ] || return 1
  # ★ 2026-10-23（真机数据）：键只用「路径 + 大小」。
  #   mtime 以前也拼在键里，但它来自 load_meta 的临时表 —— 取不到时会变成 0，
  #   于是键跟缓存里存的真实 mtime 永远对不上（1731 条缓存，命中 0 次）。
  #   现在 mtime 命中后再比：不一致才当 miss，既可靠又不会漏。
  _mt3=${3:-}
  key="${1}${FP_TAB}${2}${FP_TAB}"
  case "$FP_CACHE" in
    *"$key"*)
      v=${FP_CACHE#*"$key"}
      v=${v%%|*}
      _stored_mt=${v%%${FP_TAB}*}
      _h=${v#*${FP_TAB}}
      if [ -n "$_h" ]; then
        if [ -n "$_mt3" ] && [ -n "$_stored_mt" ] && [ "$_stored_mt" != "$_mt3" ]; then
          :   # mtime 变了 → 继续尝试空格版（一般也会 miss）
        else
          FP_HIT=$_h
          return 0
        fi
      fi
      ;;
  esac
  return 1
}

fp_cache_put() {   # $1=路径 $2=大小 $3=mtime $4=hash
  local _mt3=${3:-0}; [ -n "$_mt3" ] || _mt3=0
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$_mt3" "$4" >> "$FP_CACHE_FILE" 2>/dev/null
  FP_CACHE="${FP_CACHE}${1}${FP_TAB}${2}${FP_TAB}${_mt3}${FP_TAB}${4}|"
  return 0
}

# 缓存行数过多时压缩（保留每个路径的最后一条）

# ---------------------------------------------------------------------------
# ★ 2026-10-22（准确性保险）：指纹缓存自检
#   缓存是加速层，但它**绝不能替我们下结论**。所以每次生成报告时：
#     · 随机挑最多 3 条"命中缓存"的记录
#     · 绕过缓存**重新真算一遍**
#     · 有任何一条对不上 → 清空缓存并写进报告（说明这次数据不可信）
#   统计口径也一起暴露：新算多少、复用多少。
# ---------------------------------------------------------------------------
FP_STAT_FILE="$LIB/.fp.stat.$$"
: > "$FP_STAT_FILE" 2>/dev/null
FP_STAT_NEW=0
FP_STAT_HIT=0
FP_STAT_BAD=0

# 原始计算（完全绕过缓存）——自检用
fp_raw() {
  local f="$1" sz mt
  sz=$(sz_lookup "$f"); mt=$(mt_lookup "$f")
  [ -n "$sz" ] || { printf '%s' "-"; return 0; }
  {
    printf 'sz=%s mt=%s\n' "$sz" "$mt"
    head -c 65536 "$f" 2>/dev/null
    tail -c 65536 "$f" 2>/dev/null
  } | sha256sum 2>/dev/null | { read -r _h _rest; printf '%s' "${_h}"; }
}

fp_cache_verify() {
  [ -s "$FP_CACHE_FILE" ] || { echo "  指纹缓存自检：没有缓存（首次生成，全部为新算）"; return 0; }
  local n=0 checked=0 bad=0 p sz mt h h2
  # 取前 3 条存在的记录做抽样
  while IFS="$FP_TAB" read -r p sz mt h; do
    [ -n "$p" ] || continue
    [ -f "$p" ] || continue
    checked=$((checked + 1))
    h2=$(fp_raw "$p")
    if [ "$h2" != "$h" ]; then
      bad=$((bad + 1))
    fi
    [ "$checked" -ge 3 ] && break
  done < "$FP_CACHE_FILE"
  FP_STAT_BAD=$bad
  if [ "$bad" -gt 0 ]; then
    rm -f "$FP_CACHE_FILE" 2>/dev/null
    FP_CACHE=""
    echo "  ★ 指纹缓存自检：抽查 $checked 条，其中 $bad 条对不上 → 已清空缓存，本次全部重新计算"
  elif [ "$checked" -gt 0 ]; then
    echo "  指纹缓存自检：抽查 $checked 条，全部一致 ✓"
  else
    echo "  指纹缓存自检：缓存里没有可用记录（本次全部重新计算）"
  fi
  _fsf="${FP_STAT_FILE:-}"
  if [ -n "$_fsf" ] && [ -s "$_fsf" ]; then
    _n_new=$(tr -cd 'N' < "$_fsf" 2>/dev/null | wc -c | tr -d ' ')
    _n_hit=$(tr -cd 'H' < "$_fsf" 2>/dev/null | wc -c | tr -d ' ')
  else
    _n_new=$FP_STAT_NEW; _n_hit=$FP_STAT_HIT
  fi
  echo "  指纹来源统计：新算 ${_n_new:-0} 个 / 复用缓存 ${_n_hit:-0} 个"
  if [ "${FP_CACHE_DISABLED:-0}" = 1 ]; then
    echo "  （缓存已自动停用：本次一次都没命中，为避免拖慢报告，剩余文件按逐文件计算）"
  fi
  # ★ 2026-10-23：设备上缓存一直 0 命中 —— 把真实数据打出来对账（本地同格式是能命中的）
  if [ -s "$FP_CACHE_FILE" ]; then
    # 显式在主 shell 里加载一次（不加载的话这里永远是 0 字符 —— 之前的报告就是这样误导的）
    [ -n "${FP_LOADED:-}" ] || { FP_LOADED=1; fp_cache_load; }
    _cl=$(wc -l < "$FP_CACHE_FILE" 2>/dev/null | tr -d ' ')
    echo "  缓存文件：${_cl:-?} 条，加载后 ${#FP_CACHE} 字符（文件 $(wc -c < "$FP_CACHE_FILE" 2>/dev/null | tr -d ' ') 字节）"
    _cf=$(head -n 1 "$FP_CACHE_FILE" 2>/dev/null | tr -s ' \t' '\t' | cut -f1-2)
    if [ -n "$_cf" ]; then
      _cp=${_cf%%"$FP_TAB"*}
      _cs=${_cf#*"$FP_TAB"}
      echo "  反查样本：路径=$(printf '%s' "$_cp" | tr '\t' '|')  大小=$_cs"
      case "$FP_CACHE" in
        *"$_cp"*) echo "  路径是否在缓存中：是" ;;
        *)        echo "  路径是否在缓存中：否 ★（说明扫描用的路径与缓存里不一致）" ;;
      esac
      if fp_cache_hit "$_cp" "$_cs" ""; then
        echo "  反查结果：命中 ✓（说明键是对的，问题在调用侧）"
      else
        echo "  反查结果：未命中 ★（看下面的字节级对照）"
        _k="${_cp}${FP_TAB}${_cs}${FP_TAB}"
        echo "  缓存首行（Tab 显示为 |）：$(head -n 1 "$FP_CACHE_FILE" 2>/dev/null | tr '\t' '|' | cut -c1-90)"
        echo "  样本路径字节：$(printf '%s' "$_cp" | od -An -c 2>/dev/null | head -n 2 | tr -s ' ')"
        echo "  拼出的键字节：$(printf '%s' "$_k" 2>/dev/null | od -An -c 2>/dev/null | head -n 2 | tr -s ' ')"
        echo "  缓存第1行字节：$(head -n 1 "$FP_CACHE_FILE" 2>/dev/null | od -An -c 2>/dev/null | head -n 3 | tr -s ' ')"
        echo "  加载片段：$(head -n 1 "$FP_CACHE_FILE" 2>/dev/null | tr '\t' '|' | cut -c1-100)"
      fi
    else
      echo "  反查样本：取不到（前几行字段不足 4 段？）"
      head -n 2 "$FP_CACHE_FILE" 2>/dev/null | tr '\t' '|' | sed 's/^/    /'
    fi
  fi
  return 0
}

fp_cache_compact_if_big() {
  [ -s "$FP_CACHE_FILE" ] || return 0
  local n
  n=$(wc -l < "$FP_CACHE_FILE" 2>/dev/null | tr -d ' ')
  case "${n:-0}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -le 5000 ] && return 0
  awk -F'\t' '{ a[$1] = $0 } END { for (k in a) print a[k] }' "$FP_CACHE_FILE" 2>/dev/null \
    > "$FP_CACHE_FILE.tmp.$$" 2>/dev/null && mv -f "$FP_CACHE_FILE.tmp.$$" "$FP_CACHE_FILE" 2>/dev/null
  fp_cache_load
  return 0
}

fp_of() {
  local f="$1" sz mt
  # ★ 2026-10-14：先查批量 stat 建好的表（load_meta），查不到再回退去 stat。
  #   原来这里每文件 2 次 stat（%s + %Y）—— 一加 218 个文件、三星 274 个，
  #   就是 400~550 次 fork/exec，而真机上每次 stat 都要动那个几十 MB 文件的目录项。
  #   调用方（第 6 步的两遍循环）现在会先 load_meta "$d"，
  #   所以这两个查询命中的是纯 shell 字符串匹配，零进程。
  sz=$(sz_lookup "$f"); mt=$(mt_lookup "$f")
  if [ -z "$sz" ]; then printf '%s' "-"; return 0; fi
  # ★ 先查指纹缓存：大小与修改时间都对得上 → 直接复用，不读盘
  if fp_cache_hit "$f" "$sz" "$mt"; then printf '%s' "$FP_HIT"; return 0; fi
  # tail -c 可能因 busybox 版本差异不支持，兜底只取头部（一样能判变化）
  # ★ 2026-10-18（提速）：取哈希首字段不再多起一个 cut 进程，改用 read 拆字段。
  #   这个函数每个字体都会跑一次（真机 300 个左右），省下来就是 300 个进程。
  {
    printf 'sz=%s mt=%s\n' "$sz" "$mt"
    head -c 65536 "$f" 2>/dev/null
    tail -c 65536 "$f" 2>/dev/null
  } | sha256sum 2>/dev/null | { read -r _h _rest; printf '%s' "${_h}"; }
}

# 带缓存的指纹（计算后写回缓存）—— 第 6 步统一走这个
fp_cached() {
  local f="$1" sz mt h
  sz=$(sz_lookup "$f"); mt=$(mt_lookup "$f")
  [ -n "$sz" ] || { printf '%s' "-"; return 0; }
  if fp_cache_hit "$f" "$sz" "$mt"; then
    printf 'H' >> "${FP_STAT_FILE:-/dev/null}" 2>/dev/null
    printf '%s' "$FP_HIT"; return 0
  fi
  printf 'N' >> "${FP_STAT_FILE:-/dev/null}" 2>/dev/null
  h=$(fp_of "$f")
  [ -n "$h" ] || h="-"
  fp_cache_put "$f" "$sz" "$mt" "$h"
  printf '%s' "$h"
}

hash_flush() {
  [ -n "$HASH_BATCH" ] || return 0
  # 1.0.9.2：不再把一批文件塞给同一个 sha256sum —— 稀疏指纹要按文件"跳读"，
  #   而 sha256sum 只能顺序读整个文件。进程数变化：以前 20 个文件 1 次 fork，
  #   现在每文件 1 次；但每次只读 128KB，总 I/O 降低约 20 倍，净收益很大。
  _hf_i=0
  for _hf_f in $HASH_BATCH; do
    _hf_v=$(fp_cached "$_hf_f")
    [ -n "$_hf_v" ] || _hf_v="-"
    _hf_i=$((_hf_i + 1))
    _hf_k=$(printf '%s\n' $HASH_KEY | sed -n "${_hf_i}p")
    [ -n "$_hf_k" ] && HASH_MAP="$HASH_MAP|$_hf_k=$_hf_v"
    HASH_DONE=$((HASH_DONE + 1))
  done
  HASH_BATCH=""; HASH_BN=0; HASH_KEY=""
  return 0
}
# 单个文件指纹（文件名带空格之类没法批量时用）
hash_one() {
  _HO_H=$(fp_cached "$1")
  [ -n "$_HO_H" ] || _HO_H="-"
  printf '%s  %s  %s\n' "$_HO_H" "$(size_of "$1")" "$1"
  HN=$((HN + 1))
  [ $((HN % 25)) -eq 0 ] && breathe "指纹 $HN/$ftotal" "$HN" "$ftotal" 2>/dev/null
  return 0
}
# 查表："|键=值|键=值|" 里取某个键的值，结果放 DMV（纯 shell：不起进程、不建临时文件）
_dm_get() {
  case "$1" in
    *"|$2="*) DMV=${1#*"|$2="}; DMV=${DMV%%|*} ;;
    *) DMV="" ;;
  esac
}

# 字体配置文件列表 + 配置里引用到的所有字体文件名（estimate 也要用，所以单独拿出来）
collect_xml() {
  local x
  XMLFOUND=""
  for x in $XMLS $(slot_xml_files 2>/dev/null) /apex/*/etc/*font*.xml /apex/*/*/etc/*font*.xml /system/etc/fonts*.xml; do
    [ -f "$x" ] || continue
    case " $XMLFOUND " in *" $x "*) continue ;; esac
    XMLFOUND="$XMLFOUND $x"
  done
  [ -n "$XMLFOUND" ] || XMLFOUND=" /system/etc/fonts.xml"
  XMLNAMES=""
  for x in $XMLFOUND; do
    XMLNAMES="$XMLNAMES$(xmlnorm "$x" 2>/dev/null | grep -o '>[^<>]*\.[tT][tT][cCfF]<' | sed 's/^>//; s/<$//; s/ *$//')
"
  done
  XMLNAMES=$(printf '%s\n' "$XMLNAMES" | grep -v '^[[:space:]]*$' | sort -u)
  XMLNAMES_STR=" $(printf '%s' "$XMLNAMES" | tr '\n' ' ') "
}

# 同一时间只允许一次挂载实测；锁目录里记着"目标 + 实测前叠了几层挂载"，
# 被强杀 / 中途关机时，下一次（或中止时）据此把多出来的那层卸掉，绝不留下泄漏的挂载。
mnt_layers() { grep -cF " $1 " /proc/self/mountinfo 2>/dev/null; }
mt_recover() {
  local tgt base i=0
  [ -d "$MT_LOCK" ] || return 0
  tgt=$(sed -n 's/^target=//p' "$MT_LOCK/info" 2>/dev/null)
  base=$(sed -n 's/^base=//p' "$MT_LOCK/info" 2>/dev/null)
  if [ -n "$tgt" ] && [ -n "$base" ]; then
    while [ "$(mnt_layers "$tgt")" -gt "$base" ] 2>/dev/null && [ "$i" -lt 5 ]; do
      "$UMO" "$tgt" 2>/dev/null || "$UMO" -l "$tgt" 2>/dev/null
      i=$((i + 1))
    done
  fi
  rm -rf "$MT_LOCK" 2>/dev/null
  return 0
}

# 手机正在关机 / 重启：后台任务立刻收工，别拖住关机
shutting_down() {
  [ -n "$($GP sys.powerctl 2>/dev/null)$($GP sys.shutdown.requested 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# 判据（一次采集）—— 只在真正生成报告时调用（brief/full/build/save/install），
# 界面按钮用的轻量模式（state/cancel/bg/...）绝不进来
# ---------------------------------------------------------------------------
collect() {
_ct0=$(now_s)    # 分段计时：C1 门禁/模块状态
subnote "检查模块状态"
G_DISABLE=0; [ -f "$M/disable" ] && G_DISABLE=1
G_REMOVE=0;  [ -f "$M/remove" ] && G_REMOVE=1
G_UPDATE=0
if [ "$IN_INSTALL" = 1 ]; then
  [ -f "$M/update" ] && G_UPDATE=1
else
  { [ -f "$M/update" ] || [ -d "$UPD" ]; } && G_UPDATE=1
fi
G_SAFE=0
case "$($GP persist.sys.safemode 2>/dev/null)$($GP ro.sys.safemode 2>/dev/null)" in
  *1*) G_SAFE=1 ;;
esac
G_MAGISK=0
MAGISK_LEFT=0
# Magisk 只有在「真的在跑」时才会让 KernelSU 跳过模块脚本：
#   能看到 magisk 命令（在 PATH 里），或者脚本环境里有 MAGISK_VER。
# 只看到 /data/adb/magisk 目录、magisk.db 属于卸载残留（KernelSU 用户很常见），
# 以前把它们也算成"检测到 Magisk"，会在完全正常的机器上报 ❌，纯属吓人。
if command -v magisk >/dev/null 2>&1 || [ -n "${MAGISK_VER:-}" ]; then
  G_MAGISK=1
elif [ -e /data/adb/magisk ] || [ -e /data/adb/magisk.db ]; then
  MAGISK_LEFT=1
fi
G_NMOD=0; G_NDIS=0
for d in /data/adb/modules/*/; do
  [ -d "$d" ] || continue
  G_NMOD=$((G_NMOD + 1))
  [ -f "$d/disable" ] && G_NDIS=$((G_NDIS + 1))
done

RM=$(root_manager 2>/dev/null)
# 报告专用：先用"只认实锤"的判定，认不出再兜底（并在第 1 节标明这是**推断**）
# 为什么不能直接用 root_manager()：它为了"装模块别装错"会在认不出时兜底成 magisk，
# 而换过管理器的机器上旧 Magisk 痕迹长期存在 → 报告会把 APatch 机器说成 magisk/KernelSU 生效。
RM_STRICT=$(root_manager_strict 2>/dev/null)
RM_PROBE=""
[ -n "$RM_STRICT" ] || {
  command -v apd >/dev/null 2>&1 && RM_PROBE="apd 命令存在"
  [ -n "$RM_PROBE" ] || { [ -d /data/adb/ap ] && RM_PROBE="/data/adb/ap 目录存在"; }
  [ -n "$RM_PROBE" ] || { command -v magisk >/dev/null 2>&1 && RM_PROBE="magisk 命令存在"; }
  [ -n "$RM_PROBE" ] || { [ -d /data/adb/magisk ] && RM_PROBE="/data/adb/magisk 目录存在"; }
timing_add 'C1 门禁/模块状态' "$_ct0"
}
RM_SRC="实锤（管理器自己留下的标记）"
[ -n "$RM_STRICT" ] || RM_SRC="推断（$RM_PROBE${RM_PROBE:+，}没有实锤标记）"
[ -n "$RM_STRICT" ] || RM="$([ -n "$RM_PROBE" ] && root_manager || echo unknown)"
KSU_BIN=""
[ -x /data/adb/ksud ] && KSU_BIN=/data/adb/ksud
[ -n "$KSU_BIN" ] || { [ -x /data/adb/ksu/bin/ksud ] && KSU_BIN=/data/adb/ksu/bin/ksud; }
KSVER="未找到 ksud"
[ -n "$KSU_BIN" ] && KSVER=$("$KSU_BIN" -V 2>/dev/null | head -n1)
BOOTID=$(boot_id 2>/dev/null)
BOOTCOMP=$($GP sys.boot_completed 2>/dev/null)
ROMID=$(tr -d '[:space:]' < "$M/current_rom" 2>/dev/null)
VER_MOD=$(tag "$M")
DIAG_VER=$(tag "$MODDIR")
PEND=$(tr -d '[:space:]' < "$M/pending_font" 2>/dev/null)
ACT=$(tr -d '[:space:]' < "$M/active_font" 2>/dev/null)
MS_BOOT=$(sed -n 's/^boot=//p' "$M/mount.state" 2>/dev/null)
MS_OK=$(sed -n 's/^ok=//p' "$M/mount.state" 2>/dev/null)
MS_FAIL=$(sed -n 's/^fail=//p' "$M/mount.state" 2>/dev/null)
MS_SKIP=$(sed -n 's/^skip=//p' "$M/mount.state" 2>/dev/null)
MS_SAME=$(sed -n 's/^same=//p' "$M/mount.state" 2>/dev/null)
MS_STAGE=$(sed -n 's/^stage=//p' "$M/mount.state" 2>/dev/null)
BEAT="$LIB/boot_events.log"
MODE_FILE=$(tr -d '[:space:]' < "$M/payload.mode" 2>/dev/null)

PFD_THIS=0
SVC_THIS=0
if [ -f "$BEAT" ]; then
  grep -q "boot=$BOOTID stage=post-fs-data" "$BEAT" 2>/dev/null && PFD_THIS=1
  grep -q "boot=$BOOTID stage=service" "$BEAT" 2>/dev/null && SVC_THIS=1
fi
if [ "$PFD_THIS" = 0 ]; then
  [ -n "$BOOTID" ] && [ "$MS_BOOT" = "$BOOTID" ] && PFD_THIS=2
  newer_boot "$M/.booting" && PFD_THIS=2
fi
if [ "$SVC_THIS" = 0 ]; then
  if [ "$ACT" = "$PEND" ] && [ -n "$PEND" ] && [ "$PEND" != none ] && older_boot "$M/pending_font"; then
    SVC_THIS=2
  fi
fi

_ct0=$(now_s)    # 分段计时：C2 校验槽位生效
subnote "校验槽位是否真的生效"
ptv 'P1 槽位校验(payload_verify)' payload_verify "$M"
VER="$PT_OUT"
[ -n "$VER" ] || VER="0 0"
VHIT=${VER%% *}
VTOT=${VER##* }
# 字体目录 / 配置文件（硬编码清单 + 全盘发现 + apex，全部合并，避免漏掉 product/vendor/odm 的配置）
ptv 'P0 字体目录(slot_dirs)' slot_dirs
FONTDIRS="$PT_OUT"
SYSDIR_REAL=$(readlink -f /system/fonts 2>/dev/null)
XMLFOUND=""
_addxml() {
  [ -f "$1" ] || return 0
  case " $XMLFOUND " in *" $1 "*) return 0 ;; esac
  XMLFOUND="$XMLFOUND $1"
}
# 分段计时收尾（放这里，别插进上面的函数体里 —— 之前自动注入时插错了位置）
timing_add 'C2 校验槽位生效' "$_ct0"
for x in $XMLS; do _addxml "$x"; done
for x in $(slot_xml_files 2>/dev/null); do _addxml "$x"; done
for x in /apex/*/etc/*font*.xml /apex/*/*/etc/*font*.xml /system/etc/fonts*.xml; do _addxml "$x"; done
[ -n "$XMLFOUND" ] || XMLFOUND=" /system/etc/fonts.xml"
SYSFONTS=$(ls -1 /system/fonts 2>/dev/null)
SYSFONT_N=$(printf '%s\n' "$SYSFONTS" | grep -c . )
TTC_LIST=$(printf '%s\n' "$SYSFONTS" | grep -i '\.ttc$')
TTCNUM=$(printf '%s\n' "$TTC_LIST" | grep -c . )
TTCFIRST=$(printf '%s\n' "$TTC_LIST" | head -n1)
# 合集替换当前是否生效（auto 时三星会自动开，见 common.sh 的 ttc_enabled）
TTC_ON=$(ttc_effective 2>/dev/null); [ -n "$TTC_ON" ] || TTC_ON=0
# ★ 2026-10-18（诊断提速）：判断"配置里有没有中文 TTC 合集"时
#   **不再逐个读 XML 全文** —— 那要为十几 MB 的 fonts.xml 跑一遍 xmlnorm。
#   刷入时已经把结论算好了：scanned/ttc.list 就是中文 TTC 的 (目录, 文件名) 清单。
#   有缓存就用缓存；没有（老版本装的、或清单缺失）才退回读 XML。
ZH_TTC=0
_TTL="${LIB:-/data/adb/custom_font_lib}/scanned/ttc.list"
if [ -f "$_TTL" ]; then
  # 文件存在就够了：ttc.list 只装"中文 TTC"，空文件表示这台设备没有
  [ -s "$_TTL" ] && ZH_TTC=1
else
  for x in $XMLFOUND; do
    xmlnorm "$x" | grep -i 'zh-Hans' | grep -qi '\.ttc' && { ZH_TTC=1; break; }
  done
fi

# 三星：字体包 / flipfont / 字体设置 / /data/fonts
# 性能：pm list packages -f 和 settings list 各要 1~3 秒，以前**加载时就跑**（连只看结论的
#       轻量模式也要付这个钱）。现在只做"便宜初判"给结论用，完整清单留到需要它的那一节再算。
PKG_FONT=""; PKG_DONE=0
S_FONT=""; SFONT_DONE=0
DFONT_LIST=""; DFONT_CFG=""; DFONT_DONE=0; G_DFONT_NAMES=""
G_FLIP=0
# 字体包（flipfont）住的目录：注意现在应用装成 /data/app/~~<hash>==/<包名>-<hash>==/，
# 只扫 /data/app/*font* 会漏掉（三星装字体包时全是这种路径）—— 所以多扫一层
for _fd in /data/app/*font* /data/app/*monotype* /data/app/*/*font* /data/app/*/*monotype*; do
  [ -d "$_fd" ] && { G_FLIP=1; break; }
done
# /data/fonts：空目录（只有 config / files 而里面没字体）不算，否则会误报"它会盖过系统字体"
G_DFONT=0
if [ -d /data/fonts ]; then
  for _df in /data/fonts/*.ttf /data/fonts/*.otf /data/fonts/*.ttc \
             /data/fonts/*/*.ttf /data/fonts/*/*.otf /data/fonts/*/*.ttc; do
    [ -f "$_df" ] && { G_DFONT=1; _bn=${_df##*/}; G_DFONT_NAMES="$G_DFONT_NAMES $_bn"; }
  done
fi

# 下面三个是"用到才算"的重活
ensure_pkgs() {
  [ "$PKG_DONE" = 1 ] && return 0
  PKG_DONE=1
  PKG_FONT=$(tmo 8 "$PM" list packages -f 2>/dev/null | grep -iE 'monotype|flipfont|font' | head -n 20)
  [ -n "$PKG_FONT" ] && printf '%s\n' "$PKG_FONT" | grep -q '/data/app' && G_FLIP=1
  return 0
}
ensure_settings_font() {
  [ "$SFONT_DONE" = 1 ] && return 0
  SFONT_DONE=1
  S_FONT=$( { tmo 6 "$SETBIN" list secure 2>/dev/null; tmo 6 "$SETBIN" list system 2>/dev/null; tmo 6 "$SETBIN" list global 2>/dev/null; } \
    | grep -iE 'font|typeface' | grep -viE 'scale|size' | head -n 10 )
  [ -n "$S_FONT" ] && G_FLIP=1
  return 0
}
ensure_datafonts() {
  [ "$DFONT_DONE" = 1 ] && return 0
  DFONT_DONE=1
  [ -d /data/fonts ] || return 0
  DFONT_LIST=$(ls -1R /data/fonts 2>/dev/null | head -n 40)
  [ -n "$DFONT_LIST" ] && G_DFONT=1
  [ -f /data/fonts/config/config.xml ] && DFONT_CFG=$(head -n 60 /data/fonts/config/config.xml 2>/dev/null)
  [ -n "$DFONT_CFG" ] && G_DFONT=1
  return 0
}

# 厂商"个性化字体"（放在 /data 上的固定路径，优先级高于 /system/fonts）
#   魅族 Flyme : /data/customizecenter/font/flymeFont.ttf
# 只要它在，屏幕上显示的就是它的字形 —— 只替换 /system/fonts 看不出任何变化，
# 这是"模块说生效了但字体没变"在魅族上最常见的原因，所以必须在结论里点出来。
DATAFONT_LIST=""
for _df in /data/customizecenter/font/flymeFont.ttf /data/customizecenter/font/*.ttf /data/customizecenter/font/*.otf; do
  [ -f "$_df" ] || continue
  case " $DATAFONT_LIST " in *" $_df "*) continue ;; esac
  DATAFONT_LIST="$DATAFONT_LIST $_df"
done
DATAFONT_N=0
[ -n "$DATAFONT_LIST" ] && DATAFONT_N=$(printf '%s\n' $DATAFONT_LIST | grep -c . )
[ -n "$DATAFONT_N" ] || DATAFONT_N=0

# ---------------------------------------------------------------------------
KL=$(cfg_get keep_lang 0); KS=$(cfg_get keep_special 0)
# 1.0.9：这两个开关已从界面删除（默认全替换）。这里仍读一次，只为兼容老配置文件。
# 极端保护必须与实际挂载用同一套判定：字体完全没有中文字形时中文槽位不动
# （否则整个界面会变方块，用户连 WebUI 都看不清）。正常字体不会命中。
CJK_GUARD=0
if [ -f "$LIB/$PEND.meta" ] && \
   [ "$(sed -n 's/^cjk=//p' "$LIB/$PEND.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')" = 0 ]; then
  CJK_GUARD=1
fi
SEL_FONT="$PEND"; export CJK_GUARD SEL_FONT
_ct0=$(now_s)    # 分段计时：C4 算槽位计划
subnote "计算槽位计划"
# ★ 2026-10-18（诊断报告提速，作者要求「既要详细又要快」）：
#   原来这里是 300 项 × 2 次的纯 shell 循环去调 _role_wanted，实测被调 **606 次**，
#   完整报告 19964 条命令里光这一项就占 600 条。
#   而且它甚至没看 keep_lockscreen（参数顺序把 kl 当 keep_lang 传了），
#   报告里的「计划槽位数」可能跟界面/实际挂载不一致。
#
#   现在直接走 `slot_plan`：它已经是「按开关选一份预生成清单 + 一次 awk 过滤 scope」，
#   实测 145ms，内部已包含「保留锁屏时钟」和「主题字体」的判定
#   —— 跟实际挂载完全同源，报告数据不会自相矛盾。
#   数据一点没少：该列的槽位清单、计划数全都还在。
plan_of() { # $1=scope   （后两个参数已是死参数，保留签名兼容调用点）
  local scope="$1" role d name base
  if command -v slot_plan >/dev/null 2>&1; then
    slot_plan "$M" "$scope" 0 "$(cfg_get keep_lockscreen 0)" 0 1 2>/dev/null
    timing_add 'C4 算槽位计划' "$_ct0"
    return 0
  fi
  # 兜底：slot_plan 不可用时退回逐条判定（会慢，但保证报告能出）
  base=$(printf '%s\n' "$CANDS" | while read -r role d name; do
    [ -n "$role" ] || continue
    _role_wanted "$role" "$scope" 0 0 "$name" "$(cfg_get keep_lockscreen 0)" || continue
    printf '%s %s/%s\n' "$role" "${d#/}" "$name"
  done | sort -u -k2,2)
  [ -n "$base" ] || return 0
  printf '%s\n' "$base"
  theme_slots "$base"
  timing_add 'C4 算槽位计划' "$_ct0"
}
PLAN_NOW=$(plan_of "$SCOPE" "$KL" "$KS")

# ---------------------------------------------------------------------------
# 锁屏 / 时钟字体专项（只读）
#
#   锁屏时钟换不掉时，原因只有三种，这一节就是用来区分它们的：
#     ① 字体被打包在 overlay APK 里（RRO 换字体）→ 改 /system/fonts 也读不到
#     ② 时钟是图形/矢量样式，根本不是文字 → 与字体无关
#     ③ 该换的文件没进替换计划 → 还能修
# ---------------------------------------------------------------------------
CLOCK_FONTS=""
for _cd in /system/fonts /product/fonts /system_ext/fonts /my_product/fonts /vendor/fonts; do
  [ -d "$_cd" ] || continue
  for _cf in "$_cd"/*.ttf "$_cd"/*.otf "$_cd"/*.ttc "$_cd"/*.TTF "$_cd"/*.OTF; do
    [ -f "$_cf" ] || continue
    _cb=${_cf##*/}
    _cl=$(printf '%s' "$_cb" | tr 'A-Z' 'a-z')
    case "$_cl" in
      *clock*|*time*|*digit*|*keyguard*) ;;
      *) continue ;;
    esac
    _in=否
    printf '%s\n' "$PLAN_NOW" 2>/dev/null | grep -qF "/$_cb" && _in=是
    _sz=$(stat -c '%s' "$_cf" 2>/dev/null | tr -dc '0-9'); [ -n "$_sz" ] || _sz=0
    CLOCK_FONTS="$CLOCK_FONTS
    $_cf  （$((_sz / 1024)) KB）  本次替换：$_in"
  done
done

# overlay / 主题 APK 里打包的字体（zip 的中央目录里文件名是明文，直接扫字符串即可）
CLOCK_APK=""
for _od in /product/overlay /system_ext/overlay /vendor/overlay /odm/overlay \
           /product/app /system_ext/app /system/app /data/app; do
  [ -d "$_od" ] || continue
  _apks=$(find "$_od" -maxdepth 2 -iname '*.apk' 2>/dev/null | grep -iE 'font|typeface|clock|theme' | head -n 6)
  [ -n "$_apks" ] || continue
  for _apk in $_apks; do
    _hit=$(grep -a -o -E '[A-Za-z0-9_./-]{3,40}\.(ttf|otf|ttc)' "$_apk" 2>/dev/null \
             | sort -u | head -n 5 | tr '\n' ' ')
    [ -n "$_hit" ] && CLOCK_APK="$CLOCK_APK
    $_apk
      → $_hit"
  done
done

# 时钟/字体相关的系统设置
CLOCK_SET=$(for _ns in system secure global; do
              settings list "$_ns" 2>/dev/null \
                | grep -iE 'clock|keyguard|typeface|font' \
                | sed "s/^/    [$_ns] /"
            done 2>/dev/null | head -n 20)

# 相关系统包（谁在画锁屏时钟）
CLOCK_PKG=$(pm list packages 2>/dev/null | sed 's/^package://' \
              | grep -iE 'systemui|keyguard|oplus.*theme|theme.*font|\.font' \
              | head -n 12 | tr '\n' ' ')

# ColorOS / OPPO 系的"主题字体桥接目录"：/data/format_unclear/font
#   里面是 oplusosui-* / colorosui-* 开头的字体条目。**两种形态意义完全不同**：
#     · 符号链接 → /system/fonts/X   ：主题只是引用系统字体，我们换系统字体就已覆盖
#     · 普通文件（真内容）           ：主题字体自成一份，盖在系统字体上 → 我们没碰过
#   所以这里只做**只读探测**，把形态和链接目标记进报告，供判断"要不要替换"。
#   绝不写这个目录（在没证据前动它可能弄坏厂商字体服务）。
# ---------------------------------------------------------------------------
OPS_BRIDGE="/data/format_unclear/font"
OPS_ENTRIES=0
OPS_LINKS=0
OPS_FILES=0
OPS_DETAIL=""
if [ -d "$OPS_BRIDGE" ]; then
  _oe="$(ls -1 "$OPS_BRIDGE" 2>/dev/null | head -n 64)"
  if [ -n "$_oe" ]; then
    while IFS= read -r _n; do
      [ -n "$_n" ] || continue
      _p="$OPS_BRIDGE/$_n"
      case "$_n" in
        *.ttf|*.TTF|*.otf|*.OTF|*.ttc|*.TTC) ;;
        *) continue ;;
      esac
      OPS_ENTRIES=$((OPS_ENTRIES + 1))
      if [ -L "$_p" ]; then
        OPS_LINKS=$((OPS_LINKS + 1))
        _t=$(readlink "$_p" 2>/dev/null)
        OPS_DETAIL="$OPS_DETAIL
    [链接] $_n → ${_t:-?}"
      elif [ -f "$_p" ]; then
        OPS_FILES=$((OPS_FILES + 1))
        _sz=$(wc -c < "$_p" 2>/dev/null | tr -d ' \t\r\n')
        case "${_sz:-}" in ''|*[!0-9]*) _sz=0 ;; esac
        OPS_DETAIL="$OPS_DETAIL
    [文件] $_n  $((_sz / 1024)) KB"
      fi
    done <<EOF_OPS
$_oe
EOF_OPS
  fi
fi
G_OPS=0
[ "$OPS_FILES" -gt 0 ] && G_OPS=1

# ---------------------------------------------------------------------------
# 厂商 / 主题字体目录统一探测（**只读**）
#
# 除了我们已经支持的那几个（MIUI、三星、vivo vfonts、魅族），各家还把
# "设置里选的字体"放在各自的目录里。列在这里的目录**只探测、不替换** ——
# 目的是让报告能回答"这台机器上到底有没有别的地方存着主题字体"。
#   · 符号链接 → /system/fonts ：我们换系统字体时已覆盖，不用额外做事
#   · 普通文件               ：独立副本，本模块没碰过（可能就是"部分界面没变"的原因）
# ---------------------------------------------------------------------------
VDIR_TABLE="
荣耀主题|/data/system/theme_magic/fonts
荣耀主题根|/data/system/theme_magic
ColorOS-uxres|/data/oplus/uxres/theme
ColorOS-桥接|/data/format_unclear/font
vivo-bbkcore|/data/bbkcore/theme
vivo-皮肤|/data/skin/fonts
通用主题字体|/data/theme/fonts
通用主题根|/data/themes
MIUI主题|/data/system/theme/fonts
MIUI-webview|/data/system/fonts/theme_webview
MIUI-其他|/data/miui/theme/fonts
三星字体包|/data/overlays/font
vivo-vfonts|/data/vfonts
魅族主题|/data/customizecenter/font
可更新字体|/data/fonts
可更新字体配置|/data/fonts/config
可更新字体文件|/data/fonts/files
"
# 已经在我们替换范围内的目录（这些不算"未覆盖"）
VDIR_HANDLED=" /data/system/theme/fonts /data/system/fonts/theme_webview /data/miui/theme/fonts /data/system/theme_font /data/overlays/font /data/vfonts /data/customizecenter/font "
# ---------------------------------------------------------------------------
# ★ 2026-10-20：**自动发现"未收录"的字体目录 / 字体名字**（只读）
#
#   云端报告样本少、靠人工猜目录永远有遗漏。这里用一次**限深 find + 超时**
#   把"机器上有字体、但不在我们已知清单里"的目录挖出来，跟 targets 名单比对
#   再列出"设备上有、名单里没有"的字体名 —— 以后不用再靠猜。
#   只读、限深、限超时；不读内容、不算哈希，只数文件名。
# ---------------------------------------------------------------------------
_DISC_KNOWN=" /system/fonts /system_ext/fonts /product/fonts /vendor/fonts /odm/fonts /oem/fonts \
 /my_product/fonts /my_region/fonts /my_company/fonts /my_carrier/fonts /my_stock/fonts \
 /my_heytap/fonts /my_manifest/fonts /my_bigball/fonts /mi_ext/fonts /hw_product/fonts \
 /prism/fonts /optics/fonts /product/vivo/fonts /system_ext/vivo/fonts /vendor/vivo/fonts \
 /oplus_product/fonts /oplus_engineering/fonts /oplus_version/fonts /oplus_region/fonts \
 /data/system/theme/fonts /data/system/theme_font /data/system/fonts/theme_webview \
 /data/miui/theme/fonts /data/overlays/font /data/vfonts /data/customizecenter/font \
 /data/format_unclear/font /data/oplus/uxres/theme /data/bbkcore/theme /data/skin/fonts \
 /data/theme/fonts /data/themes /data/fonts /data/fonts/config /data/fonts/files "
DISCOVERED=""
DISC_NEW_DIRS=0
if command -v timeout >/dev/null 2>&1; then
  _disc_dirs=$(timeout 8 find /data /product /system_ext /vendor /odm -maxdepth 4 \
                 \( -name fonts -o -name font -o -name typefaces \) -type d 2>/dev/null)
else
  _disc_dirs=$(find /data /product /system_ext /vendor /odm -maxdepth 4 \
                 \( -name fonts -o -name font -o -name typefaces \) -type d 2>/dev/null)
fi
_disc_dirs=$(printf '%s\n' "$_disc_dirs" 2>/dev/null \
  | grep -v -e '/data/data/' -e '/data/app/' -e '/data/media/' -e '/data/dalvik-cache/' \
             -e '/custom_font_lib' -e '/modules/' -e '/data/local/' -e '/data/misc/' \
  | grep -v '^$' | head -n 40)
for _dd in $_disc_dirs; do
  [ -d "$_dd" ] || continue
  case "$_DISC_KNOWN" in *" $_dd "*) continue ;; esac
  _fc=$(ls -1 "$_dd" 2>/dev/null | grep -Eic '\.(ttf|otf|ttc)$' 2>/dev/null)
  [ -n "$_fc" ] || _fc=0
  [ "$_fc" -gt 0 ] 2>/dev/null || continue
  _fn=$(ls -1 "$_dd" 2>/dev/null | grep -Ei '\.(ttf|otf|ttc)$' | head -n 6 | tr '\n' ' ')
  DISC_NEW_DIRS=$((DISC_NEW_DIRS + 1))
  DISCOVERED="$DISCOVERED
    $_dd  —— $_fc 个字体：$_fn"
done
# 名字维度：设备上有、但 targets 名单里没有
DISC_NEW_NAMES=""
if [ -d "$M/targets" ]; then
  _known=$(cat "$M"/targets/*.list 2>/dev/null | sed 's|.*/||' | sort -u)
  _dev=$(for _d3 in /system/fonts /product/fonts /system_ext/fonts; do
           ls -1 "$_d3" 2>/dev/null
         done | grep -Ei '\.(ttf|otf)$' | sort -u)
  DISC_NEW_NAMES=$(printf '%s\n' "$_dev" | while IFS= read -r _n; do
                     [ -n "$_n" ] || continue
                     printf '%s\n' "$_known" | grep -qxF "$_n" || printf '%s\n' "$_n"
                   done 2>/dev/null | head -n 20 | tr '\n' ' ')
fi

VDIR_REPORT=""
VDIR_UNCOVERED=0
printf '%s\n' "$VDIR_TABLE" | while IFS='|' read -r _lbl _dir; do
  [ -n "$_dir" ] || continue
  [ -d "$_dir" ] || continue
  _n=0; _ln=0; _rg=0
  for _f in "$_dir"/*.ttf "$_dir"/*.TTF "$_dir"/*.otf "$_dir"/*.OTF "$_dir"/*.ttc "$_dir"/*.TTC; do
    [ -e "$_f" ] || continue
    _n=$((_n + 1))
    if [ -L "$_f" ]; then _ln=$((_ln + 1)); else _rg=$((_rg + 1)); fi
  done
  [ "$_n" -gt 0 ] || continue
  case "$VDIR_HANDLED" in
    *"$_dir "*) _tag="已覆盖" ;;
    *)          _tag="未覆盖" ;;
  esac
  printf '%s\n' "    [$_tag] $_lbl  $_dir  —— $_n 个字体（普通文件 $_rg / 链接 $_ln）"
done > "$LIB/.vdir.tmp.$$" 2>/dev/null
if [ -s "$LIB/.vdir.tmp.$$" ]; then
  VDIR_REPORT=$(cat "$LIB/.vdir.tmp.$$" 2>/dev/null)
  VDIR_UNCOVERED=$(printf '%s\n' "$VDIR_REPORT" | grep -c '\[未覆盖\]' 2>/dev/null)
  [ -n "$VDIR_UNCOVERED" ] || VDIR_UNCOVERED=0
fi
rm -f "$LIB/.vdir.tmp.$$" 2>/dev/null

# MIUI / HyperOS 个性字体（主题字体）：由主题机制接管，优先级高于 /system/fonts，
# 同名文件会顶替系统字体 —— 这就是"旧版必须手动切一次字体才生效"的根源。
MIUI_DIRS=""
for td in /data/system/theme/fonts /data/system/theme_font /data/miui/theme/fonts /data/miui/theme; do
  [ -d "$td" ] && MIUI_DIRS="$MIUI_DIRS $td"
done
MIUI_FONTLIST=""
MIUI_FONT_N=0
for td in $MIUI_DIRS; do
  for f in "$td"/*.ttf "$td"/*.otf "$td"/*.ttc; do
    [ -f "$f" ] || continue
    MIUI_FONT_N=$((MIUI_FONT_N + 1))
    MIUI_FONTLIST="$MIUI_FONTLIST$f
"
  done
done
MIUI_SHADOW=""
if [ "$MIUI_FONT_N" -gt 0 ]; then
  _ct0=$(now_s)    # 分段计时：C3 扫主题字体
  subnote "扫描主题（个性）字体"
  MIUI_SHADOW=$(printf '%s\n' "$MIUI_FONTLIST" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    b=${f##*/}
    for d in $FONTDIRS; do
      [ -f "$d/$b" ] && { echo "$b"; break; }
    done
  done | sort -u | tr '\n' ' ')
fi
G_MIUI=0
[ "$MIUI_FONT_N" -gt 0 ] && G_MIUI=1

# ColorOS 主题字体桥接目录的结论（只读探测，见上面那段说明）
OPS_VERDICT=""
if [ -d "$OPS_BRIDGE" ]; then
  if [ "$OPS_FILES" -gt 0 ]; then
    OPS_VERDICT="⚠ 检测到 ColorOS 主题字体目录（$OPS_BRIDGE）：$OPS_ENTRIES 个条目，其中 $OPS_FILES 个是**普通文件**、$OPS_LINKS 个是符号链接。普通文件那部分本模块没有替换（设置里选的字体优先），这可能是「部分界面/锁屏时钟没变」的原因。"
  elif [ "$OPS_LINKS" -gt 0 ]; then
    OPS_VERDICT="ℹ 检测到 ColorOS 主题字体目录（$OPS_BRIDGE）：$OPS_LINKS 个条目全是符号链接 → 指向系统字体，本模块替换 /system/fonts 时已一并覆盖。"
  elif [ "$OPS_ENTRIES" -gt 0 ]; then
    OPS_VERDICT="ℹ 检测到 ColorOS 主题字体目录（$OPS_BRIDGE）：$OPS_ENTRIES 个条目，形态未识别。"
  fi
fi

# 槽位候选（一次算完，后面复用）
# 1.0.9：加上"自适应扫描"补的部分（设备自己配置引用到、模板没覆盖的角色）——
#   这样报告里看到的候选与实际挂载用的计划是同一套，不会一个多一个少。
ptv 'P2 候选枚举(slot_candidates)' slot_candidates "$M"
CANDS="$PT_OUT"
ptv 'P3 自适应扫描(slot_adaptive_extra)' slot_adaptive_extra "$CANDS"
CAND_EXTRA_D="$PT_OUT"
ADAPTIVE_N=$(printf '%s\n' "$CAND_EXTRA_D" | grep -c . 2>/dev/null)
[ -n "$ADAPTIVE_N" ] || ADAPTIVE_N=0
if [ "$ADAPTIVE_N" -gt 0 ]; then
  CANDS=$(printf '%s\n%s\n' "$CANDS" "$CAND_EXTRA_D" | grep -v '^[[:space:]]*$' | sort -u)
fi
CAND_N=$(printf '%s\n' "$CANDS" | grep -c . )
# 当前字体实际范围
eff_scope() {
  local sel="$1" sc latin cjk
  case "$sel" in *+*) echo combo; return ;; ""|none) echo all; return ;; esac
  sc=$(sed -n 's/^scope=//p' "$LIB/$sel.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')
  case "$sc" in all|latin|cjk) echo "$sc"; return ;; esac
  latin=$(sed -n 's/^latin=//p' "$LIB/$sel.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')
  cjk=$(sed -n 's/^cjk=//p' "$LIB/$sel.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')
  if [ -z "$latin$cjk" ]; then echo all; return; fi
  if [ "$cjk" = 1 ] && [ "$latin" = 1 ]; then echo all
  elif [ "$latin" = 1 ]; then echo latin
  elif [ "$cjk" = 1 ]; then echo cjk
  else echo latin; fi
  timing_add 'C3 扫主题字体' "$_ct0"
}
SCOPE=$(eff_scope "$PEND")
PLAN_MAX=$(plan_of all 0 0)
# 计划里有几个主题字体槽（/data/system/theme/fonts 里与已选槽位同名的那些）
MIUI_INPLAN=$(printf '%s\n' "$PLAN_NOW" | grep -c '^theme ' 2>/dev/null)
APPLIED_LIST=$(cat "$M/slots.applied" 2>/dev/null)
APPLIED_TTC=0
if [ -n "$APPLIED_LIST" ] && [ "$TTCNUM" -gt 0 ]; then
  printf '%s\n' "$TTC_LIST" | while IFS= read -r b; do
    [ -n "$b" ] || continue
    printf '%s\n' "$APPLIED_LIST" | grep -q "/$b\$" && echo x
  done > /data/local/tmp/.diag_ttc.$$ 2>/dev/null
  APPLIED_TTC=$(grep -c . /data/local/tmp/.diag_ttc.$$ 2>/dev/null)
  rm -f /data/local/tmp/.diag_ttc.$$ 2>/dev/null
fi
[ -n "$APPLIED_TTC" ] || APPLIED_TTC=0

# 字体库清单
# ★ 2026-10-24：内置配色（builtin_*.ttf）也算字体库 —— 以前只数 f*.ttf，
#   于是"字体库 0 个"却占 128MB（三套内置配色），报告自相矛盾。
LIB_FONTS=$(ls -1 "$LIB"/*.ttf 2>/dev/null)
LIB_N=$(printf '%s\n' "$LIB_FONTS" | grep -c . )

# ---------------------------------------------------------------------------
# 实际字体目录映射（第 5 节的核心数据，pack_extra 也会带走）
# 定义已挪到 ensure_dirmaps()（用到才算），见下方
# ---------------------------------------------------------------------------

# 配置里引用到的所有字体文件名（一处提取，多处复用）
# ★ 2026-10-18（诊断提速）：上面 pack_core/槽位校验那一段**已经算过同一个东西**，
#   这里再算一遍等于把十几 MB 的 fonts.xml 又读一遍。
#   有值就复用；没有（那段没走到）再自己算，行为不变。
if [ -z "${XMLNAMES:-}" ]; then
  for x in $XMLFOUND; do
    XMLNAMES="$XMLNAMES$(xmlnorm "$x" 2>/dev/null | grep -o '>[^<>]*\.[tT][tT][cCfF]<' | sed 's/^>//; s/<$//; s/ *$//')
"
  done
  XMLNAMES=$(printf '%s\n' "$XMLNAMES" | grep -v '^[[:space:]]*$' | sort -u)
fi

# 名字 -> 框架实际读取的路径 | 存在 | 独立副本
# 性能：目录的真实路径与 dev:ino 已经在 FONTDIR_MAP 里算过了，
#       这里改成纯 shell 查表，不再对每个字体名起 readlink/stat（省几百个进程）
# 而且整块改成"用到才算"（ensure_dirmaps）：只有第 5 节和导出数据包需要，
# 只想看结论时不必为它买单。
DIRMAP_DONE=0
# 从 FONTDIR_MAP 里查某目录的真实路径 / dev:ino（纯 shell，不起进程）
dir_real() {
  local want="$1" line
  while IFS= read -r line; do
    case "$line" in "$want|"*) printf '%s' "${line#*|}"; return 0 ;; esac
  done <<EOF
$FONTDIR_MAP
EOF
  printf '%s' "$want"
}
dir_ino() {
  local want="$1" line rest
  while IFS= read -r line; do
    case "$line" in
      "$want|"*)
        rest=${line#*|}; rest=${rest#*|}
        printf '%s' "${rest%%|*}"
        return 0 ;;
    esac
  done <<EOF
$FONTDIR_MAP
EOF
  return 1
}
ensure_dirmaps() {
  [ "$DIRMAP_DONE" = 1 ] && return 0
  DIRMAP_DONE=1
  FONTDIR_MAP=""
  for d in $FONTDIRS; do
    real=$(readlink -f "$d" 2>/dev/null); [ -n "$real" ] || real="$d"
    idn=$(stat -L -c '%d:%i' "$d" 2>/dev/null)
    cnt=$(ls -1 "$d" 2>/dev/null | grep -c .)
    szk=$(du -sk "$d" 2>/dev/null | cut -f1)
    same=""
    for e in $FONTDIRS; do
      [ "$e" = "$d" ] && continue
      er=$(readlink -f "$e" 2>/dev/null); [ -n "$er" ] || er="$e"
      [ "$er" = "$real" ] || continue
      same="$same $e"
    done
    FONTDIR_MAP="$FONTDIR_MAP$d|$real|$idn|$cnt|$szk|$same
"
  done
  NAMEMAP=$(printf '%s\n' "$XMLNAMES" | while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in /*) p="$n" ;; *) p="/system/fonts/$n" ;; esac
    base=${n##*/}
    par=${p%/*}; [ -n "$par" ] || par="/"
    par_real=$(dir_real "$par")
    real="$par_real/$base"
    if [ -f "$p" ]; then st="有"; else st="无"; fi
    pdid=$(dir_ino "$par")
    dup=""
    for d in $FONTDIRS; do
      dr=$(dir_real "$d")
      [ "$dr" = "$par_real" ] && continue
      [ -f "$d/$base" ] || continue
      did=$(dir_ino "$d")
      if [ -n "$did" ] && [ "$did" = "$pdid" ]; then dup="$dup $d(同一份)"; else dup="$dup $d(独立★)"; fi
    done
    echo "$n|$p|$real|$st|$dup"
    nm_n=$(( ${nm_n:-0} + 1 ))
    # ★ 1.0.9.2：原来这里每 25 条 `sleep 1`（NAMEMAP 有几百条 → 白等十几秒）。
    #   让路已由 lowprio_self（nice 10）负责，这里不必再"睡"。
  done)
  return 0
}

# 一句话小结：符号链接关系
dir_conclusion() {
  local d real out=""
  for d in $FONTDIRS; do
    real=$(readlink -f "$d" 2>/dev/null)
    [ -n "$real" ] && [ "$real" != "$d" ] && out="$out $d→$real"
  done
  printf '%s' "${out:-（各字体目录相互独立，没有符号链接）}"
}

# ---------------------------------------------------------------------------
# 应用侧可见性：模块的挂载在「App 自己的进程里」还看不看得到
#
# 为什么需要这一节（真机反馈）：报告一路显示 71/71 全部生效，用户却说「只有桌面 /
# 主界面变了，App 里没变」。原因是 KernelSU 系有个「卸载模块」机制：应用进程从 zygote
# 派生时会切进自己的挂载命名空间，把模块挂载摘掉；内核里的默认值就是"卸"
# （KernelSU 源码 policy/allowlist.c：default_non_root_profile.umount_modules = true），
# 只有管理器自己、授予过 root 权限的 App、以及 uid 1000 这类系统进程不受影响。
# 本脚本是 root 跑在全局命名空间里，看到的是全局真相 —— 所以**报告本身永远显示已生效**，
# 必须进到 App 的命名空间里数一数才能判断，下面就是这件事。
#
# 依据（以后有人怀疑这段结论时，照着核对）：
#   https://kernelsu.org/zh_CN/guide/app-profile.html      官方 App Profile 文档：默认卸载模块默认开
#   kernel/feature/kernel_umount.c  只对 zygote 派生出来的应用进程下手；
#                                   uid 1000/2000 这类不是 appuid，不卸；
#                                   隔离进程（WebView 渲染进程）无条件卸
#   kernel/policy/allowlist.c       default_non_root_profile.umount_modules = true；
#                                   授予过 root 的 App（allow_su）不卸
# ---------------------------------------------------------------------------
AS_MINE=""; AS_LIST=""; AS_READ=0; AS_RISK=0; AS_HIDDEN=0
AS_KREL=""; AS_FEATURE=""; AS_FEATURE_HINT=""; AS_DOTUM=""; AS_METAUM=""

# 关键文件完整性：缺哪个就列出来。
#   缺 common/slots/mount = 整个模块不可用（fontctl.sh 会明确报错退出）；
#   缺 ttcwrap.sh = 只是"合集替换"不可用 —— 但现象是"开关亮着、中文没变"，
#   所以必须在报告里点名，否则作者和用户都会往挂载上找。
# 用法：modfiles_check <目录>（输出"（齐全）"或" 缺xxx 缺yyy"）
modfiles_check() {
  local _d="$1" _f _miss=""
  for _f in common.sh slots.sh mount.sh fontctl.sh; do
    [ -f "$_d/$_f" ] || _miss="$_miss $_f"
  done
  [ -f "$_d/ttcwrap.sh" ] || _miss="$_miss ttcwrap.sh"
  printf '%s' "${_miss:-（齐全）}"
}

# 谷歌字体兼容开关的中文说法（报告和结论区共用；别把英文原词直接甩给用户）
gf_state_text() {
  case "$1" in
    on)      printf '已开启（本模块停用了 GMS 的下载字体组件）' ;;
    off)     printf '未开启' ;;
    foreign) printf '已被其它工具停用（不是本模块操作的，本模块不接管）' ;;
    nogms)   printf '未安装 Google Play 服务（无需开启）' ;;
    *)       printf '读取失败（未知）' ;;
  esac
}

# 数一份 mountinfo 里有多少条"我们挂上去的"：源都在字体库目录，凭路径就能认出来
# （.ttf 与 .ttc 合集槽位都算，源分别是 <id>.ttf / <id>.ttcN_x-y）
as_count() { grep -c 'custom_font_lib/' "$1" 2>/dev/null; }

app_side_probe() {
  local p bn uid cmd c n=0 _ask _asv _asr _asmaj _asmin _asdu _asiu _asf
  # 幂等：万一被调用两次（或同一个进程里重跑），不要累加上一轮的采样
  AS_LIST=""; AS_READ=0; AS_HIDDEN=0
  AS_MINE=$(as_count /proc/self/mountinfo)
  # 内核版本：KernelSU 只在 5.10 及以上内核里真的执行卸载（更低版本这个开关只是配置项）
  AS_KREL=$(uname -r 2>/dev/null | sed 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/')
  _asmaj=${AS_KREL%%.*}; _asmin=${AS_KREL#*.}
  case "$_asmaj" in ''|*[!0-9]*) _asmaj=0 ;; esac
  case "$_asmin" in ''|*[!0-9]*) _asmin=0 ;; esac
  if [ "$_asmaj" -gt 5 ] || { [ "$_asmaj" -eq 5 ] && [ "$_asmin" -ge 10 ]; }; then
    [ "$RM" = ksu ] && AS_RISK=1
  fi
  # 管理器侧"卸载模块"的现场：原样列出（不猜文件格式，作者一眼就能看懂）
  if [ -f /data/adb/ksu/.feature_config ]; then
    # ★ 2026-10-15：这个文件里那一行就是**全局一次搞定**的开关 ——
    #   `kernel_umount=0` 一写，所有 App 都不再被卸载模块（不用逐个 App 点）。
    #   所以：查到就把"怎么改"一起写出来，别只当现场信息列着。
    AS_FEATURE=$(grep -a -i 'umount' /data/adb/ksu/.feature_config 2>/dev/null | head -n1)
    if [ -n "$AS_FEATURE" ]; then
      case "$AS_FEATURE" in
        *umount=0*|*umount=false*|*umount=off*|*umount=no*) AS_FEATURE_HINT="（= 已关闭卸载，这是对的）" ;;
        *) AS_FEATURE_HINT="（= 开着卸载；改成 kernel_umount=0 可一次性对所有 App 生效）" ;;
      esac
    else
      AS_FEATURE="（文件在，但没有含 umount 的项）"
      AS_FEATURE_HINT="（默认就是卸载；加一行 kernel_umount=0 可一次性对所有 App 生效）"
    fi
  else
    AS_FEATURE="（没有 /data/adb/ksu/.feature_config）"
    # 没有这个文件 = 用的是内核默认值"卸载"，所以这里就是解法所在
    AS_FEATURE_HINT="（走内核默认值：会卸载；建这个文件并写一行 kernel_umount=0 即可对所有 App 生效）"
  fi
  if [ -f /data/adb/ksu/.umount ]; then
    AS_DOTUM=$(head -c 120 /data/adb/ksu/.umount 2>/dev/null | tr '\n' ' ')
    [ -n "$AS_DOTUM" ] || AS_DOTUM="（空文件）"
  else
    AS_DOTUM="（没有 /data/adb/ksu/.umount）"
  fi
  # 元模块（Hybrid Mount 这类）自己也有"卸载/隐藏"开关，配置里叫 disable_umount
  for _asf in /data/adb/hybrid-mount/config.toml /data/adb/hybrid_mount/config.toml \
               /data/adb/magic_mount/config.toml /data/adb/modules/mountify/config.toml \
               /data/adb/mountify/config.toml; do
    [ -f "$_asf" ] || continue
    _asdu=$(sed -n 's/^[[:space:]]*disable_umount[[:space:]]*=[[:space:]]*//p' "$_asf" 2>/dev/null | head -n1)
    _asiu=$(sed -n 's/^[[:space:]]*vfs_isolate_uids[[:space:]]*=[[:space:]]*//p' "$_asf" 2>/dev/null | head -n1)
    AS_METAUM="$_asf  disable_umount=${_asdu:-未写}  vfs_isolate_uids=${_asiu:-未写}"
    break
  done
  # 采样最多 3 个"普通 App"进程（uid 10000-19999）。
  # 隔离进程（90000+，WebView 渲染进程）故意不要 —— KernelSU 对它们是无条件卸载的，
  # 拿它们做对照会把"正常现象"误判成"模块没生效"。
  # 用 /proc/* 而不是 /proc/[0-9]*：文件名通配里的方括号不是所有 sh 都支持
  # （busybox-w32 就不支持，沙盒测试会走到字面量上），数字判断交给 case。
  # ★ 1.0.9.2 定稿：**加 12 秒硬上限 + 修一个统计 bug**。
  #   为什么又加上限：作者实测"第 1 步要 5 分钟"，而唯一"进程越多越慢"的地方就是这里 ——
  #   真机 /proc 有一两千个条目，要**逐个**读 status 才能找到 uid 10000~19999 的普通 App。
  #   而它的目的只是"抽样 3 个 App 看看能不能看到挂载"：抽 1 个和抽 3 个结论一样，
  #   **不值得为它等几分钟**。超时会写进报告开头的「完整性声明」，不会静默。
  #   （原来那句 `AS_TRIED=$_AS_TRIED` 还是个真 bug：变量名写错，统计被清零。）
  AS_BUDGET=${AS_BUDGET:-12}
  AS_TIMEOUT=0; AS_TRIED=0
  _AS_T0=$(now_s)
  for p in /proc/*; do
    bn=${p#/proc/}
    case "$bn" in ''|*[!0-9]*) continue ;; esac
    AS_TRIED=$((AS_TRIED + 1))
    # 每 40 个查一次时间（查时间要起进程，不能每次都查）
    if [ $((AS_TRIED % 40)) -eq 0 ]; then
      if [ $(( $(now_s) - _AS_T0 )) -ge "$AS_BUDGET" ]; then
        AS_TIMEOUT=1
        skip_note "第11节 App 侧抽样" "扫了 ${AS_BUDGET} 秒到上限（试了 $AS_TRIED 个进程）" "重跑一次，或用 AS_BUDGET=60 sh diag.sh save 放宽上限"
        break
      fi
    fi
    [ -r "$p/status" ] || continue
    uid=""
    # ★ 1.0.9.2 修正：**不要写 IFS=' '**！
    #   /proc/<pid>/status 里字段之间是**制表符**（`Uid:\t10123\t...`）。
    #   写成 `IFS=' ' read -r _ask _asv _asr` 会把整行当成第一个字段，
    #   _asv 永远是空 → uid 读不到 → **App 侧采样恒为 0**
    #   （真机报告表现为"App 侧抽样一个都没采到"；沙箱回归测试抓到）。
    #   不设 IFS 时 shell 默认按"空格+制表符"分词，tab 和空格都能吃。
    while read -r _ask _asv _asr; do
      case "$_ask" in Uid:) uid=$_asv; break ;; esac
    done < "$p/status" 2>/dev/null
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    [ "$uid" -ge 10000 ] && [ "$uid" -le 19999 ] || continue
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null); cmd=${cmd% }
    [ -n "$cmd" ] || continue
    c=$(as_count "/proc/$bn/mountinfo")
    [ -n "$c" ] || c="读不到"
    AS_LIST="$AS_LIST$bn|$uid|$cmd|$c
"
    [ "$c" = 0 ] && [ "$AS_MINE" -gt 0 ] 2>/dev/null && AS_HIDDEN=1
    n=$((n + 1))
    [ "$n" -ge 3 ] && break
  done
  AS_SEC=$(( $(now_s) - _AS_T0 ))
  [ "$n" -gt 0 ] && AS_READ=1
  return 0
}

# ---------------------------------------------------------------------------
# 实机挂载能力测试：挂一个真实槽位 -> 校验 -> 立刻卸载
# ---------------------------------------------------------------------------
MT_RESULT="未测试"
MT_DETAIL=""
MT_TARGET=""
MT_SRC=""
MT_LEFT=0
do_mount_test() {
  local line id rel before after err srcid now umount_err
  MT_TARGET=""; MT_SRC=""
  [ -s "$M/slots.map" ] || { MT_RESULT="跳过（没有槽位计划）"; skip_note "第3节 挂载实测" "没有槽位计划（slots.map 为空）" "先在界面里选一份字体并重启一次"; return 0; }
  # 先把"上次被强杀留下的测试挂载"卸干净（没有锁文件时这一步是空操作）
  mt_recover
  # 实测目标优先取 system 分区上的槽位：这才是"能不能挂进系统字体"的判据；
  # /data 上的个性化字体槽（魅族 flymeFont.ttf 这类）挂不上通常不是挂载时机的问题，
  # 只有实在没有系统槽位时才拿它来测。
  line=""
  _mt_id=""; _mt_rel=""
  while read -r _mt_id _mt_rel _mt_src; do
    [ -n "$_mt_rel" ] || continue
    case "$_mt_rel" in data/*) continue ;; esac
    line="$_mt_id $_mt_rel"
    break
  done < "$M/slots.map"
  [ -n "$line" ] || line=$(head -n1 "$M/slots.map" 2>/dev/null)
  id=${line%% *}; rel=${line#* }
  rel=$(printf '%s' "$rel" | tr -d '\r')
  case "$id" in ""|*[!A-Za-z0-9_]*) MT_RESULT="跳过（slots.map 格式异常）"; return 0 ;; esac
  [ -n "$rel" ] || { MT_RESULT="跳过（slots.map 为空）"; return 0; }
  MT_SRC="$LIB/$id.ttf"; MT_TARGET="/$rel"
  [ -f "$MT_SRC" ] || { MT_RESULT="跳过（字体库文件不存在: $MT_SRC）"; skip_note "第3节 挂载实测" "字体库文件不存在：$MT_SRC" "重新导入一次字体"; return 0; }
  [ -f "$MT_TARGET" ] || { MT_RESULT="跳过（目标槽位不存在: $MT_TARGET）"; skip_note "第3节 挂载实测" "目标槽位在设备上不存在：$MT_TARGET" "通常说明这台设备没有这个槽位，可忽略"; return 0; }
  before=$(stat -L -c '%d:%i' "$MT_TARGET" 2>/dev/null)
  # 挂之前先立"锁"：记下目标 + 挂载前叠了几层。万一进程被强杀（kill -9 抓不住），
  # 下一次 mt_recover 就能凭这个文件把多出来的那层卸掉 —— 绝不留挂载泄漏（关机时 /data 卸不掉就麻烦了）
  mkdir -p "$MT_LOCK" 2>/dev/null
  printf 'target=%s\nbase=%s\ntime=%s\n' "$MT_TARGET" "$(mnt_layers "$MT_TARGET")" "$(now_s)" > "$MT_LOCK/info" 2>/dev/null
  err=$("$MO" -o bind "$MT_SRC" "$MT_TARGET" 2>&1)
  after=$(stat -L -c '%d:%i' "$MT_TARGET" 2>/dev/null)
  srcid=$(stat -L -c '%d:%i' "$MT_SRC" 2>/dev/null)
  if [ "$after" = "$srcid" ] && [ -n "$srcid" ]; then
    MT_RESULT="成功（bind 挂载可用）"
    MT_DETAIL="挂载后 dev:inode=$after，与字体库文件一致"
    umount_err=$("$UMO" "$MT_TARGET" 2>&1)
    now=$(stat -L -c '%d:%i' "$MT_TARGET" 2>/dev/null)
    if [ "$now" = "$before" ]; then
      MT_DETAIL="$MT_DETAIL；已成功卸载还原"
    else
      MT_RESULT="成功但卸载失败 ★（该槽位会保持被替换，重启后恢复）"
      MT_DETAIL="$MT_DETAIL；umount 报错: ${umount_err:-无输出}"
      MT_LEFT=1
    fi
  else
    MT_RESULT="失败 ★（$MT_TARGET 挂不上去）"
    MT_DETAIL="mount 报错: ${err:-无输出}；挂载后 dev:inode=$after（期望 $srcid）"
    "$UMO" "$MT_TARGET" 2>/dev/null      # 万一挂上去了但 inode 没对上，也先卸掉
  fi
  [ "$MT_LEFT" = 1 ] || rm -rf "$MT_LOCK" 2>/dev/null
  return 0
}
_ct0=$(now_s)    # 分段计时：C5 挂载实测
subnote "挂载实测（挂一个真实槽位再立刻卸载）"
do_mount_test
timing_add 'C5 挂载实测' "$_ct0"
_ct0=$(now_s)    # 分段计时：C6 应用侧可见性
subnote "应用侧可见性（App 里看不看得到，见第 11 节）"
app_side_probe
# ---------------------------------------------------------------------------
# 谷歌字体兼容：GMS 的"下载字体"（Google Sans / Product Sans 那类）不走 /system/fonts，
# 我们替换系统字体管不到它 —— 这一节把现场摊开，见第 7 节和结论区。
# 轻量口径（安装时）只读缓存状态，不跑 dumpsys（安装流程要快）。
# ★ 限时（1.0.9.2）：这两步都可能很慢（dumpsys / GMS 缓存目录里文件多），
#   所以各自限时、超时就退回缓存值或留空，**绝不拖住整份报告**。
# ---------------------------------------------------------------------------
GF_STATE=""; GF_OWNED=0; GF_RESET=0; GF_CACHED=0
if [ -f "$MODDIR/google_font.sh" ]; then
  timing_add 'C6 应用侧可见性' "$_ct0"
  _ct0=$(now_s)    # 分段计时：C7 谷歌字体兼容
  subnote "检查谷歌字体兼容状态"
  # ★★ 1.0.9.2：**这一节的重活全部删掉了**（作者实测"第一步的谷歌那里最慢"）。
  #   删掉了什么、为什么：
  #     · `google_font.sh status fresh` —— 内部跑 `dumpsys package com.google.android.gms`，
  #       在 Android 17 / HyperOS 上要**几分钟**（作者机器实测）。报告不需要实时值。
  #     · `google_font.sh diag` —— 要 find GMS 字体缓存目录并对每个文件查账本+挂载，
  #       商店下过字体时是几百次 I/O。
  #   这两个"现场明细"对**判断字体为什么没换**几乎没有帮助（字体没换的原因在第 0/6 节），
  #   却能把报告拖到半小时。所以报告里改成**只读一个本地小文件**（毫秒级、零进程）：
  #     $LIB/.gms_status   —— 由"开启/关闭兼容"和界面的「重新检测」按钮维护
  #   要看实时状态，界面上的「重新检测」按钮照旧走完整检测（那条路没动）。
  # 【1.0.9.2 定稿】内容与 1.0.9.1 完全一致，只是每一步都限时：
  #   实测这两条在你机器上各只要 0~1 秒，所以限时根本不影响结果 ——
  #   它只在"某台机器上 dumpsys 真的卡住"时才救场（那时报告会注明）。
  GF_DIAG=""; GF_SEC=0; GF_STATUS_SEC=0; GF_SLOW=0
  _gf_t0=$(now_s)
  # ① 状态：先试实时（限 8 秒），超时就用缓存值并在报告里注明
  GF_STATE=$(tmo 6 sh "$MODDIR/google_font.sh" status fresh 2>/dev/null | tr -d '[:space:]')
  case "$GF_STATE" in
    on|off|foreign|unknown|nogms) ;;
    *)  GF_STATE=$(tmo 4 sh "$MODDIR/google_font.sh" status 2>/dev/null | tr -d '[:space:]')
        GF_CACHED=1 ;;
  esac
  _gf_mid=$(now_s)
  # ② 现场明细：和 1.0.9.1 一样照收（限 20 秒，超时就留空并注明）
  GF_DIAG=$(tmo 10 sh "$MODDIR/google_font.sh" diag 2>/dev/null)
  GF_SEC=$(( $(now_s) - _gf_t0 ))
  GF_STATUS_SEC=$(( _gf_mid - _gf_t0 ))
  [ "${GF_CACHED:-0}" = 1 ] && skip_note "谷歌字体兼容状态" "实时检测超时（8 秒），显示的是缓存值" "在界面点「重新检测」看最新状态"
  [ -z "$GF_DIAG" ] && skip_note "谷歌字体兼容现场明细" "扫描超时（20 秒）或没取到" "稍后重新生成一次报告"
fi
case "$GF_STATE" in on|off|foreign|unknown|nogms) ;; *) GF_STATE=unknown ;; esac
[ -f "$LIB/.gms_journal.conf" ] && GF_OWNED=1
# 有我们的记录、但组件已经不是"停用"了 = 被 GMS 更新顶回去了（用户看到的就是"又变回谷歌字体"）
[ "$GF_OWNED" = 1 ] && [ "$GF_STATE" = off ] && GF_RESET=1
}    # collect() 到此结束：这些采集只允许在真正生成报告时跑（见 collect_once）

# ===========================================================================
# 【1.0.9.2 新增】批量采集 + 两节新报告内容
#
# 为什么加这个（作者要求）：
#   诊断报告只有一个用途 —— 用户说"没全局生效" → 他传一份报告 → 作者照它修/加适配。
#   所以报告必须能回答两件事：
#     ① 这台系统"靠什么生效"（哪种语言 → 哪个字体文件）
#     ② 哪些字体**没被适配清单覆盖**（作者据此加进 targets/*.list）
#
# 为什么快：
#   旧写法对每个文件起一次进程（stat/grep/awk），293 个文件就是上千个进程。
#   这里全部**批量**：一次 `ls -l` 拿全目录、一次 `awk` 算完、XML 只解析一次，
#   判断"在不在清单/计划里"走内存查表（两次短模式匹配，零进程）。
#
# 这一整段是**自包含**的：只定义变量和函数，不执行任何东西，
# 所以放在 diag.sh 里也不会影响原有流程。
# ===========================================================================

# ---- 批量采集（只做一次，结果落中间文件 + 内存表）----
D2_TMP=""
d2_init_tmp() {
  D2_TMP="${TMPDIR:-/data/local/tmp}/.diag2.$$"
  mkdir -p "$D2_TMP" 2>/dev/null || D2_TMP="$LIB/.diag2.$$"
  mkdir -p "$D2_TMP" 2>/dev/null
  return 0
}

# 字体文件总表：一次 ls -l 拿全目录，awk 拆列（不再 per-file stat）
d2_collect_fontfiles() {
  d2_init_tmp
  : > "$D2_TMP/fontfiles"
  for _d in $FONTDIRS; do
    [ -d "$FSROOT$_d" ] || continue
    ls -l "$FSROOT$_d" 2>/dev/null | awk -v D="$_d" '
      NF >= 9 && $1 !~ /^d/ {
        sz = $5; name = $9
        for (i = 10; i <= NF; i++) name = name " " $i
        if (name ~ /\.(ttf|otf|ttc|TTF|OTF|TTC)$/) printf "%s\t%s\t%s\n", name, sz, D
      }' >> "$D2_TMP/fontfiles"
  done
  D2_NFILES=$(grep -c . "$D2_TMP/fontfiles" 2>/dev/null); isnum "$D2_NFILES" || D2_NFILES=0
}

# 字体配置：**只规范一次**，落成"一行一个标签"的中间文件
d2_collect_xml() {
  d2_init_tmp
  : > "$D2_TMP/xml.flat"
  D2_NXML=0
  for _x in $XMLFOUND; do
    [ -f "$FSROOT$_x" ] || continue
    echo "@@X $_x" >> "$D2_TMP/xml.flat"
    # ★ 关键：tr 把缩进变成空格后，标签之间是 ">   <"，必须匹配 ">[空格]<" 才能拆开。
    #   （旧写法 s/></>\n</g 只匹配紧挨着的 "><"，带缩进的真实配置拆不开 —— 实测踩过。）
    tr '\n\r\t' '   ' < "$FSROOT$_x" 2>/dev/null | sed 's/>[ 	]*</>\n</g' >> "$D2_TMP/xml.flat"
    echo >> "$D2_TMP/xml.flat"
    D2_NXML=$((D2_NXML + 1))
  done
}

# 语言 → 字体文件（报告【4】【5】的数据源）
# 同时建 famfile：文件名 → 它所属的 family 标识（给【5】判断"是不是时钟/符号这类刻意不换的"）
d2_collect_langmap() {
  d2_init_tmp
  # ★ 1.0.9.2：family 标识 = family 的 name=/lang= 属性 + 这个 family 块里出现的所有
  #   postScriptName=（真机上 `miclock-dela-gothic-one` 就只在 customization 的
  #   postScriptName 里出现，family 的 name 属性是空的）。
  #   两条输出写进**同一个 awk**，避免再解析一遍 XML（省一次全量扫描）。
  awk '
    /^@@X / { next }
    /<family/ {
      fam = $0; lang = ""; name = ""
      if (match(fam, /lang="[^"]*"/)) { lang = substr(fam, RSTART+6, RLENGTH-7) }
      if (match(fam, /name="[^"]*"/)) { name = substr(fam, RSTART+6, RLENGTH-7) }
      # customization 块里还有 name= / postScriptName=，一并收进来当 family 标识
      cur_lang = lang; cur_name = name; cur_ids = name " " lang
      if (match(fam, /postScriptName="[^"]*"/)) { cur_ids = cur_ids " " substr(fam, RSTART+16, RLENGTH-17) }
      infam = 1; next
    }
    /<\/family>/ {
      # 一个 family 结束：把它引用过的每个文件都记一条 famfile
      if (infam) {
        n = split(cur_files, arr, " ")
        for (i = 1; i <= n; i++) if (arr[i] != "") printf "FM\t%s\t%s\n", arr[i], cur_ids
      }
      infam = 0; cur_files = ""; next
    }
    {
      if (!infam) next
      line = $0
      # family 块里出现的额外标识（postScriptName / name / customizationType 的名字）
      if (match(line, /postScriptName="[^"]*"/)) { cur_ids = cur_ids " " substr(line, RSTART+16, RLENGTH-17) }
      if (match(line, /name="[^"]*"/))          { cur_ids = cur_ids " " substr(line, RSTART+6,  RLENGTH-7) }
      while (match(line, /[A-Za-z0-9_.\-]+\.(ttf|otf|TTF|OTF|ttc|TTC)/)) {
        fn = substr(line, RSTART, RLENGTH)
        printf "%s\t%s\n", (cur_lang == "" ? "und" : cur_lang), fn
        cur_files = cur_files " " fn
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$D2_TMP/xml.flat" 2>/dev/null > "$D2_TMP/lm.raw"
  grep -v '^FM	' "$D2_TMP/lm.raw" 2>/dev/null | sort -u > "$D2_TMP/langmap"
  grep '^FM	' "$D2_TMP/lm.raw" 2>/dev/null | cut -f2,3 | sort -u | tr '\t' '|' > "$D2_TMP/famfile"
  rm -f "$D2_TMP/lm.raw" 2>/dev/null
  D2_NLANG=$(grep -c . "$D2_TMP/langmap" 2>/dev/null); isnum "$D2_NLANG" || D2_NLANG=0
}

# 三张内存查表：计划里的文件名 / 适配清单 / 设备上存在的文件
# 有了它们，第 4/5 节判断"在不在"就是两次短模式匹配，**零进程**。
d2_build_lookup() {
  d2_init_tmp
  D2_PLAN_NAMES=$(
    printf '%s\n' "$PLAN_NOW" | while IFS= read -r _pl; do
      [ -n "$_pl" ] || continue
      _pn=${_pl##*/}
      [ -n "$_pn" ] && printf '|%s|' "$_pn"
    done
  )
  D2_TARGET_NAMES=""
  _rom=$(tr -d '[:space:]' < "$M/current_rom" 2>/dev/null)
  for _l in "$M/targets/$_rom.list" "$M/targets/aosp.list"; do
    [ -f "$_l" ] || continue
    _names=$(grep -v '^[[:space:]]*#' "$_l" 2>/dev/null | tr -d '\r' | sed 's#.*/##' | grep -v '^[[:space:]]*$')
    printf '%s\n' "$_names" | while IFS= read -r _t; do
      [ -n "$_t" ] && printf '|%s|' "$_t"
    done > "$D2_TMP/tn.$$" 2>/dev/null
    D2_TARGET_NAMES="$D2_TARGET_NAMES$(cat "$D2_TMP/tn.$$" 2>/dev/null)"
    rm -f "$D2_TMP/tn.$$" 2>/dev/null
  done
  D2_EXIST_NAMES=$(
    awk -F'\t' '{ printf "|%s|", $1 }' "$D2_TMP/fontfiles" 2>/dev/null
  )
  # ★★ 1.0.9.2 真机修（作者机器报告："设备上字体 24 个 / 查了 0 个"）：
  #   「设备上存在的字体」这张表是**直接从字体目录 glob 出来**的，不用 fontfiles 那张表 ——
  #   因为 fontfiles 是解析 `ls -l` 出来的，在真机上只装进了一部分（作者机器 293 个里只进 24 个），
  #   导致后面所有比对都落空、【5】输出"查了 0 个"。
  #   直接 glob 既准确又便宜（每个目录一次 ls），而且**和 fontfiles 那个环节解耦** ——
  #   以后 fontfiles 就算出问题，也不会再把【5】整节带塌。
  _ex2=""
  for _xd in $FONTDIRS; do
    [ -d "$FSROOT$_xd" ] || continue
    _ex2="$_ex2$(ls -1 "$FSROOT$_xd" 2>/dev/null | awk '{ printf "|%s|", $0 }')"
  done
  _n2=$(printf '%s' "$_ex2" | tr '|' '\n' | grep -c . 2>/dev/null); isnum "$_n2" || _n2=0
  if [ "$_n2" -gt "${D2_NFILES:-0}" ] 2>/dev/null; then
    D2_EXIST_NAMES="$_ex2"
    D2_NFILES=$_n2
  fi
  # 清单条数（给报告显示）
  D2_NTARGET=$(printf '%s' "$D2_TARGET_NAMES" | tr '|' '\n' | grep -c . 2>/dev/null)
  isnum "$D2_NTARGET" || D2_NTARGET=0
}

# 一次性采集（在 collect() 之后调用；此时 FONTDIRS / XMLFOUND / PLAN_NOW 都已经算好）
d2_collect_all() {
  [ -n "${D2_DONE:-}" ] && return 0
  D2_DONE=1
  d2_collect_fontfiles
  d2_collect_xml
  d2_collect_langmap
  d2_build_lookup
  return 0
}

# 内存查表：表形如 "|名|名|"
d2_in() {
  case "$1" in
    *"|$2|"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 【4】语言 → 字体文件：这台系统靠什么生效
# ---------------------------------------------------------------------------
sec_adapted() {
  echo
  echo "【摘要4】★ 语言 → 字体文件：这台系统靠什么生效"
  hr
  echo "  说明：每一行都从**你这台机器自己的字体配置**里读出来（不是按机型猜）。"
  echo "        「本次」= 这个文件在不在当前的替换计划里。"
  echo
  printf '  %-14s %-44s %-8s\n' "语言" "配置里引用的字体文件" "本次"
  printf '  %-14s %-44s %-8s\n' "--------------" "--------------------------------------------" "--------"
  if [ "${D2_NLANG:-0}" = 0 ] || [ ! -f "${D2_TMP:-/nonexistent}/langmap" ]; then
    echo "  （没读到任何「语言→字体」映射 —— 配置格式可能特殊，或这台机器没有字体配置）"
  else
    while IFS='	' read -r _lg _fl; do
      [ -n "$_fl" ] || continue
      case "$_lg" in
        zh-hans|zh-hans-cn) _lb="中文(简)" ;;
        zh-hant|zh-hant-tw|zh-hant-hk|zh-bopo) _lb="中文(繁)" ;;
        ja) _lb="日文" ;;
        ko) _lb="韩文" ;;
        und|"") _lb="通用" ;;
        *) _lb="$_lg" ;;
      esac
      if d2_in "$D2_PLAN_NAMES" "$_fl"; then _r="✅ 会换"; else _r="❌ 不换"; fi
      printf '  %-14s %-44s %-8s\n' "$_lg" "$_fl" "$_r"
    done < "$D2_TMP/langmap"
    echo
    echo "  共 $D2_NLANG 条「语言→字体」对应关系（含同名字体在不同语言下的重复，已去重）"
  fi
  hr
}

# ---------------------------------------------------------------------------
# 【5】★ 没适配的字体 —— 作者据此修适配
#
# 判据为什么这样定（1.0.9.2 真机报告后修正）：
#   第一版判据是"在不在 targets/*.list 里"，结果在真机上输出"没有没适配的" ——
#   但同一份报告的【0】节明明列着 Lobster-Regular.ttf / NotoSerifHentaigana.ttf 等
#   "配置引用了、却没被替换"的字体。原因是：**清单里有 != 会被替换**，
#   真正的门槛是"角色判定 + 计划"。
#
#   所以现在按"真正会不会被换"分类，并且把**本该换却没进计划**的单独标出来 ——
#   那才是作者要修的东西。其它文字的字体（阿拉伯文/梵文/楔形文字…）被排除是**正确行为**，
#   不能混进来当"没适配"，否则这份清单会被几百个无关字体淹没。
# ---------------------------------------------------------------------------
sec_unadapted() {
  echo
  echo "【摘要5】★ 没被替换的字体（配置引用了，但本次不会换）"
  hr
  echo "  给作者看的：这台设备上**真实存在、且被字体配置引用**、但**本次计划里没有**的字体。"
  echo "  已按「该不该换」分成两类，看第一类就行："
  echo "    [★要修]   = 本该参与替换（主字体/拉丁/中文/日韩），却没进计划 → **作者要修的**"
  echo "    [正常排除] = 其它文字体系（阿拉伯文、梵文、楔形文字…）或符号/emoji → 换了反而出问题"
  echo
  [ -d "${D2_TMP:-/nonexistent}" ] || { echo "  （临时目录不可用，跳过这一节 —— 不影响其它节）"; hr; return 0; }
  : > "$D2_TMP/unadapted" 2>/dev/null
  : > "$D2_TMP/normalexcl" 2>/dev/null
  if [ "${D2_NLANG:-0}" = 0 ] || [ ! -s "$D2_TMP/langmap" ]; then
    echo "  （没有「语言→字体」映射，无法判断 —— 见第 4 节）"
    hr
    return 0
  fi
  # 计数变量放在这里初始化。
  # ★ 1.0.9.2 教训：原来只在最后用 `grep -c` 去数临时文件，真机上出现过
  #   "确实分类了、但两行统计都没打印"（内容没丢，只是统计行没出来，看着像没检查）。
  #   改成**循环里直接计数**，不再依赖临时文件读回来 —— 少一个可能失效的环节。
  #
  # ★ 另一个真机踩坑（"查了 0 个"）：判据第一句是
  #     `d2_in "$D2_EXIST_NAMES" "$_fl" || continue`
  #   —— **只要那张"设备上存在的文件"表是空的，所有行都被 continue 掉，结果就是"查了 0 个"**。
  #   表为空不影响"该不该换"的判断（那只看语言标签 + 计划），所以表为空时**不该整节作废**，
  #   只是没法做"设备上真的有这个文件吗"这一层过滤而已。
  _have_exist=1
  [ -n "${D2_EXIST_NAMES:-}" ] || _have_exist=0
  if [ "$_have_exist" = 1 ]; then
    echo "  （本机比对基数：设备上字体 ${D2_NFILES:-0} 个，语言映射 ${D2_NLANG:-0} 条）"
  else
    echo "  （本机比对基数：设备上字体 ${D2_NFILES:-0} 个，语言映射 ${D2_NLANG:-0} 条）"
    echo "   ⚠ 字体清单为空 —— 本节只按配置判断，不做「设备上真有这个文件吗」这一层过滤。"
  fi
  _un=0; _nx=0; _nref=0; _nplan=0
  while IFS='	' read -r _lg _fl; do
    [ -n "$_fl" ] || continue
    # 这一层是"设备上真有这个文件吗"的**辅助过滤**（作者机器上就是这里导致"查了 0 个"）。
    # 为了不再被任何一张表带塌，这里做成**三级兜底**：
    #   ① 查内存表；② 表里没有就直接问文件系统（几个候选目录试一遍）；③ 都没有才跳过。
    # 注意：第 ② 步只在"表里没查到"时才起进程，正常情况下不增加开销。
    if [ "$_have_exist" = 1 ]; then
      if ! d2_in "$D2_EXIST_NAMES" "$_fl"; then
        _found=0
        for _fd in $FONTDIRS; do
          if [ -e "$FSROOT$_fd/$_fl" ]; then _found=1; break; fi
        done
        [ "$_found" = 1 ] || continue
      fi
    fi
    _nref=$((_nref + 1))
    if d2_in "$D2_PLAN_NAMES" "$_fl"; then
      _nplan=$((_nplan + 1))
      continue                                       # 已在计划里 = 会换，跳过
    fi
    # 没进计划：判断"该不该换"
    #   该换的：语言标签是 und/zh/ja/ko/en（主字体与常用文字），且文件名看着不像符号/其它文字
    case "$_lg" in
      und|"")  _should=1 ;;
      zh*|ja|ko|en*) _should=1 ;;
      *) _should=0 ;;                                # und-Arab / und-Deva / und-Xsux … = 其它文字
    esac
    if [ "$_should" = 1 ]; then
      # 文件名里带 emoji/symbol/mono/clock 这类"刻意不换"的，也算正常排除
      _lf=$(printf '%s' "$_fl" | tr 'A-Z' 'a-z')
      case "$_lf" in
        *emoji*|*symbol*|*dingbat*|*braille*|*clock*|*mono*|*italic*|*oblique*|*serif*)
          _should=0 ;;
      esac
    fi
    # ★ 1.0.9.2 真机补：**还要看"它属于哪个 family"**。
    #   作者机器上的 DelaGothicOne.otf / DelaGothicOne-HZ.otf 文件名里没有 clock 字样，
    #   但它们在配置里属于 `miclock-dela-gothic-one` —— 那是**锁屏时钟**的专属字体，
    #   模块刻意不换（换了锁屏时钟会出问题）。只看文件名会把它们误报成"★要修"。
    #   D2_FAMFILE 由 d2_collect_langmap 建好："文件名|所在 family 名（含 <> 里的名字）"。
    if [ "$_should" = 1 ] && [ -f "${D2_TMP:-/nonexistent}/famfile" ]; then
      _fams=$(sed -n "s/^$(printf '%s' "$_fl" | sed 's/[.[\*^$]/\\&/g')|//p" "$D2_TMP/famfile" 2>/dev/null | tr 'A-Z' 'a-z')
      case "$_fams" in
        *clock*|*watch*|*lockscreen*|*widget*|*emoji*|*symbol*|*logo*|*brand*)
          _should=0 ;;
      esac
    fi
    # ★ 2026-10-15 真机补：**再问一次 `_xml_family_ok`** ——
    #   它是"哪些族本来就被排除"的唯一权威（EMOJI/SYMBOL/MONO/CURSIVE/CASUAL/
    #   MATH/MUSIC/CLOCK，以及 SERIF）。
    #   魅族真机报告（完整体检报告(2)(2).txt）里 ComingSoon.ttf / DancingScript-Regular.ttf
    #   被标成 [★要修]，但它们的族名就是 `casual` / `cursive` —— 属于装饰字体，
    #   `_xml_family_ok` 明确排除，没进计划是**正确**的。按文件名看不出来
    #   （文件名里没有那些词）；上面那条只覆盖 clock/emoji 这类，覆盖不到 casual/cursive。
    #   保守：只有确实查到族名、且判定为不该要时才降级；查不到就保持原判断，
    #   免得把真问题掩盖掉。
    if [ "$_should" = 1 ] && [ -f "${D2_TMP:-/nonexistent}/famfile" ] &&
       command -v _xml_family_ok >/dev/null 2>&1; then
      _fid=$(sed -n "s/^$(printf '%s' "$_fl" | sed 's/[.[\*^$]/\\&/g')|//p" "$D2_TMP/famfile" 2>/dev/null | head -n1)
      if [ -n "$_fid" ]; then
        for _one in $_fid; do
          if ! _xml_family_ok "$_one" ""; then _should=0; break; fi
        done
      fi
    fi
    # ★ 2026-10-24（魅族真机报告）：protect.list / 「粗细调节」族里的字体是**刻意不动**的，
    #   以前这里不查跳过名单，于是 RobotoFlex-Regular.ttf 被误报成 [★要修]。
    if [ "$_should" = 1 ]; then
      _lf2=$(printf '%s' "$_fl" | tr 'A-Z' 'a-z')
      _skl="${LIB:-/data/adb/custom_font_lib}/scanned/skip.list"
      if [ -s "$_skl" ] && grep -qx "$_lf2" "$_skl" 2>/dev/null; then
        _should=0
      fi
    fi
    if [ "$_should" = 1 ]; then
      _un=$((_un + 1))
      printf '  [★要修]   %-44s (语言 %s)\n' "$_fl" "$_lg"
      printf '%s\n' "$_fl" >> "$D2_TMP/unadapted"
    else
      _nx=$((_nx + 1))
      printf '%s\n' "$_fl" >> "$D2_TMP/normalexcl"
    fi
  done < "$D2_TMP/langmap"
  echo
  # 先给一句"查了多少"，这样即使结果为 0 也能看出这一节**真的跑了**（不是漏了）
  echo "  查了 $_nref 个「设备上真实存在、且被配置引用」的字体：$_nplan 个已在计划里，$((_un + _nx)) 个没进计划。"
  echo
  if [ "$_un" = 0 ]; then
    echo "  ✅ 上面这 $((_un + _nx)) 个里面，没有「本该换却没进计划」的。"
  else
    echo "  ★ 共 $_un 个字体**本该参与替换、却没进计划**（作者据此修适配）："
    sed 's/^/     /' "$D2_TMP/unadapted" 2>/dev/null
  fi
  if [ "$_nx" -gt 0 ] 2>/dev/null; then
    echo "  （另有 $_nx 个是其它文字体系/符号字体，被排除是正确的，未列出）"
  fi
  hr
d2_suggest_targets() {
  local n=0 nm role
  [ -n "${D2_EXIST_NAMES:-}" ] || return 0
  [ -n "${D2_PLAN_NAMES:-}" ] || return 0
  echo
  echo "  【建议补进清单的字体】"
  echo "    判据：目录里有 + 角色放行 + 不在当前计划 → 被文件名过滤挡住的"
  echo "    怎么用：这些补进 targets/<rom>.list 后就会参与替换。"
  echo "            「是不是机型级」由你判断 —— 别的同 ROM 机器也有 → 补；只这台有 → 不用补。"
  echo
  printf '    %-42s %-10s %s\n' "字体文件" "角色" "说明"
  printf '    %-42s %-10s %s\n' "------------------------------------------" "----------" "----------------------"
  for nm in $D2_EXIST_NAMES; do
    [ -n "$nm" ] || continue
    # ① 在计划里 → 已经会换，跳过
    d2_in "$D2_PLAN_NAMES" "$nm" && continue
    # ② 角色判定放行吗（放行 = 换了是安全的）
    _role_set "$(_lc "$nm")" 2>/dev/null
    role="$ROLE"
    _role_wanted "$role" all 0 0 "$nm" 0 2>/dev/null || continue
    # ③ 排除"本来就是符号类、且永远不换"的（sym 会被 _role_wanted 挡掉，这里兜一层）
    case "$role" in sym) continue ;; esac
    n=$((n + 1))
    _why="被文件名过滤挡住"
    _l=$(printf '%s' "$nm" | tr 'A-Z' 'a-z')
    # ⚠️ 顺序有讲究：MiClockMono 同时含 clock 和 mono，
    #   先判 clock 才不会被说成"等宽"（真机上这类名字很多）
    case "$_l" in
      *clock*)  _why="时钟（扫描按名字跳过）" ;;
      *serif*)  _why="衬线（扫描按名字跳过）" ;;
      *mono*)   _why="等宽（扫描按名字跳过）" ;;
      *emoji*|*symbol*) _why="符号（扫描按名字跳过）" ;;
    esac
    printf '    %-42s %-10s %s\n' "$nm" "$role" "$_why"
  done
  if [ "$n" = 0 ]; then
    echo "    （没有 —— 目录里的候选都已在计划里，或都被角色规则正确排除）"
  else
    echo
    echo "    共 $n 个候选。"
  fi
  echo
}

  d2_suggest_targets   # ★ 2026-10-16：建议补进清单的字体（作者看）
}


# 只在生成报告时采集一次（界面按钮用的 state/cancel/bg/estimate/text/savenow 绝不调用）
COLLECTED=0
collect_once() {
  [ "$COLLECTED" = 1 ] && return 0
  COLLECTED=1
  collect
  # ★ 1.0.9.2：采集完之后再建"批量查表"（报告第 4/5 节要用；此时 FONTDIRS/XMLFOUND/PLAN_NOW 都已算好）
  d2_collect_all
  return 0
  timing_add 'C7 谷歌字体兼容' "$_ct0"
}

# ---------------------------------------------------------------------------
# 结论
# ---------------------------------------------------------------------------
conclusion() {
  echo "===== 一键体检（结论）====="
  echo "体检脚本: ${DIAG_VER:-?}   正在生效的模块: ${VER_MOD:-?}"
  echo "运行位置: $MODDIR"
  echo "设备: $($GP ro.product.brand 2>/dev/null) $($GP ro.product.model 2>/dev/null)   Android $($GP ro.build.version.release 2>/dev/null)   构建号: $($GP ro.build.display.id 2>/dev/null)"
  echo "系统识别: $(rom_name "$ROMID" 2>/dev/null)   已开机 $((UP / 60)) 分钟   boot_completed=$BOOTCOMP"
  hr
  # ★ 报告完整性声明：有任何一节没采到，必须写在最前面（"没问题"和"没检查"必须分得清）
  print_skip_notice
  [ -n "$DIAG_SKIPS" ] && hr
  if [ "$G_DISABLE" = 1 ]; then
    echo "❌ 结论：模块处于「已禁用」状态。"
    echo "   KernelSU 不会执行被禁用模块的任何开机脚本，重启多少次都不会生效。"
    echo "   → 到管理器里把模块启用，然后重启。"
  elif [ "$G_REMOVE" = 1 ]; then
    echo "❌ 结论：模块被标记为「待卸载」，同样不会执行任何脚本。"
    echo "   → 到管理器里取消卸载标记，或重新安装一次模块。"
  elif [ "$G_UPDATE" = 1 ]; then
    echo "❌ 结论：模块内容从未被「激活」（活动目录上有 update 标记 / 内容还在 modules_update）。"
    echo "   只有开机的 post-fs-data 阶段会做这件激活的事；没激活 = 那个阶段从来没执行过。"
    echo "   这就是「重启好几次也没用」的直接原因。"
  elif [ "$G_SAFE" = 1 ]; then
    echo "❌ 结论：系统当前处于安全模式（safemode=1）。"
    echo "   KernelSU 在安全模式下会跳过所有模块脚本，还会把全部模块禁用。"
    echo "   → 重启一次（开机时别按音量键），然后到管理器里重新启用模块。"
  elif [ "$G_MAGISK" = 1 ] && [ "$PFD_THIS" = 0 ] && [ -z "$MS_BOOT" ]; then
    echo "❌ 结论：机器上还检测到 Magisk。"
    echo "   很多 Root 管理器（KernelSU / APatch）一旦发现 Magisk 在跑，就会跳过全部模块脚本"
    echo "   （post-fs-data / post-mount / service 都不跑）—— 请先卸载 Magisk 或二选一，再重启。"
  elif [ "$G_MAGISK" = 1 ] && [ -n "$RM_STRICT" ]; then
    # 有 Magisk 的痕迹，但本模块脚本确实跑了，而且**认得出真正在生效的管理器** → 说明 Magisk 没在拦
    echo "⚠ 结论：检测到 Magisk 的痕迹，但本次开机的模块脚本确实执行了 ——"
    echo "   说明当前生效的是 $(root_manager_name "$RM_STRICT")，Magisk 没有在拦模块脚本（见第 1 节）。"
  elif [ "$G_MAGISK" = 1 ]; then
    # ★ 2026-10-12 修：以前这里写死"说明当前生效的是 KernelSU"，害得一台 APatch 机器被说成 KernelSU。
    #   脚本跑成功了 = 事实上没有冲突，这本身就是好消息；**至于谁在生效，认不出就不替用户下结论**。
    echo "⚠ 结论：检测到 Magisk 的痕迹，但本次开机的模块脚本确实执行了 ——"
    echo "   ⇒ 不管是谁在生效，**它没有拦住本模块**，字体替换是正常的（本次实测生效数见上面）。"
    echo "   ⇒ 报告**没能认出**正在生效的 Root 管理器（第 1 节写了判据），所以不替你猜是哪一个。"
    echo "      想弄清楚的话：第 1 节的 APATCH / KSU / MAGISK_VER 三个环境变量是不是都是空的 ——"
    echo "      都空且没有 ksud/apd，说明这个管理器没给我们留下可识别的标记（换过管理器的机器很常见）。"
  elif [ "$MT_LEFT" = 1 ]; then
    echo "⚠ 结论：挂载测试成功，但测试用的挂载点卸载失败（已记录，重启后可恢复）。"
  elif [ "$PFD_THIS" = 0 ] && [ "$SVC_THIS" = 0 ]; then
    echo "❌ 结论：没有任何一次开机留下「脚本执行过」的痕迹。"
    if [ -f "$M/mount_missed" ]; then
      echo "   但存在 mount_missed（$(mstamp "$M/mount_missed")，$(since_txt "$M/mount_missed")）："
      echo "   说明某次开机脚本跑过，但「挂载」没有执行 —— 最常见的原因是 Root 管理器在开机时"
      echo "   没有运行模块脚本（例如临时 root：重启后需要重新激活的那种），其次才是模块被停用。"
    else
      echo "   连 mount_missed 都没有 → 模块脚本从来没被执行过（不是挂载失败）。"
    fi
    echo "   第 1 节的门禁都没命中时，看第 10 节的 ksud 日志、版本和 dmesg。"
  elif [ "$PFD_THIS" != 0 ] && [ -z "$MS_BOOT" ] && [ -n "$PEND" ] && [ "$PEND" != none ] && \
       [ "$ACT" != "$PEND" ] && newer_boot "$M/pending_font"; then
    # 关键：本次开机时还没选字体（pending 是空的），是开机之后才选的 —— 这不是故障，重启一次就行。
    # 以前这种情况会走到下面那条，报"❌ 挂载阶段没留下记录 / 需要改用其它挂载时机"，把人吓一跳。
    echo "⏳ 结论：字体已经选好了，但「本次开机的时候还没选」，所以这次开机什么都没做。"
    echo "   → 重启一次就生效（重启后什么都不用点，字体就该变了）。"
    echo "   → 如果重启后还是没变，再看第 3 节（挂载是否成功）和第 6 节（中文是不是 .ttc）。"
  elif [ "$MODE_FILE" = manager ] && [ -n "$PEND" ] && [ "$PEND" != none ]; then
    # ★ 2026-10-19：**管理器挂载模式要单独判**。
    #   这个模式下本模块不自己挂（把文件放进模块目录就交出去），所以
    #   mount.state 没有本次开机记录是**正常的**，不该判成"挂载阶段没记录"。
    #   真机实测（Xiaomi + hybrid_mount）：元模块一条都没挂上，而报告只会说
    #   "有挂载记录但不是本次开机的"，用户完全看不出该改什么。
    if [ "${VTOT:-0}" -gt 0 ] 2>/dev/null && [ "$VHIT" = "$VTOT" ]; then
      echo "✅ 结论：管理器 / 元模块已经把字体挂上了（$VHIT/$VTOT 逐个核对通过）。"
      echo "   「交给管理器挂载」模式下本模块不自己挂，mount.state 没有本次开机记录是正常的。"
    else
      echo "❌ 结论：选择的是「交给管理器挂载」，但管理器 / 元模块这一轮没把字体挂上去（${VHIT:-0}/${VTOT:-0}）。"
      echo "   这个模式下本模块只负责把文件放进模块目录，真正挂载由管理器 / 元模块负责 ——"
      echo "   它没挂，本模块替代不了（第 3 节能看到 /system/fonts 里没有任何本模块的挂载）。"
      echo "   → 到 WebUI 把挂载方式改回「自带挂载」，重启一次即可（实测这条能生效）。"
    fi
  elif [ "$PFD_THIS" != 0 ] && [ -z "$MS_BOOT" ]; then
    echo "❌ 结论：开机脚本跑了，但「挂载阶段」没有留下任何记录。"
    echo "   结合第 3 节的实测结果一起看（实测${MT_RESULT}）。"
    echo "   → 需要模块改用其它挂载时机，请把报告发给作者。"
  elif [ -n "$MS_BOOT" ] && [ "$MS_BOOT" != "$BOOTID" ]; then
    echo "⚠ 结论：有挂载记录，但不是本次开机的（也就是本次开机没挂上）。"
    echo "   → 重启一次，重启后什么都别点，再看这份报告。"
  elif [ -n "$MS_FAIL" ] && [ "$MS_FAIL" != 0 ]; then
    echo "❌ 结论：挂载失败 $MS_FAIL 个（成功 $MS_OK 个）。第 3 节有真实报错。"
  elif [ -n "$MS_BOOT" ] && [ "$MS_BOOT" = "$BOOTID" ] && [ "$VTOT" != 0 ] && [ "$VHIT" = "$VTOT" ]; then
    echo "✅ 结论：字体已成功挂载并生效（$VHIT/$VTOT）。"
  elif [ -n "$MS_BOOT" ] && [ "$MS_BOOT" = "$BOOTID" ]; then
    echo "⚠ 结论：有本次开机的挂载记录，但实际校验只有 $VHIT/$VTOT 生效。见第 3 节。"
  else
    echo "⚠ 结论：没找到明确的失败点。请看第 2 节执行痕迹、第 4 节候选槽位和第 10 节日志。"
  fi
  # 简中的"兜底字体"是 .ttc 合集。默认（三星）会把它替换掉，用户也可以在设置里关掉。
  # 但注意别说成"中文一定不变"：只要主字体家族（sans-serif / MiSansVF 这类）在替换列表里、
  # 且你的字体自带中文字形，中文照样会变 —— .ttc 只在主字体缺字形、系统回落到它时才起作用。
  if [ "$ZH_TTC" = 1 ] && [ "$APPLIED_TTC" = 0 ] && [ -n "$PEND" ] && [ "$PEND" != none ]; then
    echo "ℹ 中文说明：本机简中的「兜底字体」是 .ttc 合集（${TTCFIRST:-?}），本次没有替换它。"
    [ "$TTC_ON" = 1 ] || echo "   → 想让中文也用你的字体：到「替换范围（高级）」里打开「替换 .ttc 合集」，重启一次即可。"
    echo "   只要替换列表里的主字体自带中文字形，中文一般也会跟着变；"
    echo "   只有主字体缺字形、系统回落到这个合集时，那一部分中文不会变。第 6 节有明细。"
  fi
  # 「只有桌面/系统界面生效、App 里没变」——最常见的解释不是挂载失败，而是管理器默认
  # 就对应用「卸载模块」（KernelSU 系内核里的默认值就是"卸"）。第 11 节有实测对比。
  if [ "$AS_HIDDEN" = 1 ]; then
    echo "⚠ 重点：实测到「App 侧看不到本模块的挂载」（第 11 节）。"
    echo "   管理器把模块从应用进程里卸载了 —— 桌面 / 系统界面这类不受影响，"
    echo "   所以现象看着像「只有桌面生效、App 里没变」。"
    echo "   → 到管理器里关掉「默认卸载模块」（或只给那个 App 关掉「卸载模块」），重启后再看。"
    echo "   这不是模块故障，也不是挂载失败。"
  elif [ "$AS_RISK" = 1 ] && [ -n "$PEND" ] && [ "$PEND" != none ]; then
    echo "ℹ 提示：本机（$RM，内核 ${AS_KREL:-?}）具备「对应用卸载模块」的机制。"
    echo "   如果现象是「桌面 / 系统界面正常、App 里没变」，先看第 11 节 ——"
    echo "   这种情况挂载全成功、报告也看不出问题，按第 11 节的 ① 关掉「默认卸载模块」再试。"
  fi
  # 包不完整（缺 ttcwrap.sh = 合集生成器）：现象是"开关亮着、中文没变"，
  # 报告里如果只字不提，用户和作者都会往挂载上找。这里直接点名 + 给动作。
  _mfmiss=$(modfiles_check "$M")
  case "$_mfmiss" in
    *ttcwrap.sh*)
      if [ "$TTC_ON" = 1 ]; then
        echo "⚠ 注意：模块文件不完整（缺：$_mfmiss）——"
        echo "   缺 ttcwrap.sh 就等于「合集生成器不在」：合集替换不会生效、中文可能不变，"
        echo "   而且不会有任何报错。→ 到管理器里把这个包**重新安装一次**即可（不是只更新）。"
      fi ;;
  esac
  # 谷歌字体兼容被 GMS 更新顶回去了（有我们的记录、但组件已经不是"停用"状态）
  if [ "$GF_RESET" = 1 ]; then
    echo "⚠ 注意：谷歌字体兼容被系统重置了（Play 服务更新会这样）——"
    echo "   现象就是「英文数字过一阵又变回谷歌默认」。本版每次开机（service 阶段）会自动补一次；"
    echo "   想立刻生效：在界面点一下「开启兼容」，或直接重启一次。第 7 节有现场。"
  fi
  hr
  echo "本次开机: post-fs-data $([ "$PFD_THIS" = 0 ] && echo '未执行' || echo '已执行')   service $([ "$SVC_THIS" = 0 ] && echo '未执行' || echo '已执行')   实际生效 $VHIT/$VTOT"
  echo "扫描范围: $(printf '%s\n' "$FONTDIRS" | grep -c . ) 个字体目录、$(printf '%s\n' "$XMLFOUND" | grep -c . ) 份字体配置（含厂商分区与 apex）"
        echo "本次口径: 完整报告（唯一口径）"
        echo "本次指纹: 稀疏指纹（大小+修改时间+头尾各 64KB 的 sha256）—— 用于判断字体有没有被替换；同一份文件只算一次"
  echo "挂载实测: $MT_RESULT"
  echo "待生效: ${PEND:-none}    当前生效: ${ACT:-none}"
  echo "（两个不一致 = 这次的选择还没被任何一次开机处理过）"
  echo "字体库: ${LIB_N:-0} 个，占用 $(du -sk "$LIB" 2>/dev/null | cut -f1) KB   挂载方式: ${MODE_FILE:-?}"
  echo "设置: keep_lang=$KL keep_special=$KS   替换范围: ${SCOPE:-?}   槽位计划: $(printf '%s\n' "$PLAN_NOW" | grep -c . ) 个"
  echo "实际字体目录: /system/fonts → ${SYSDIR_REAL:-?}（设备上共 $(printf '%s\n' "$FONTDIRS" | grep -c . ) 个字体目录，详见第 5 节）"
  echo "谷歌字体兼容: $(gf_state_text "${GF_STATE:-unknown}")   冲突模块: $(sh "$MODDIR/fontctl.sh" conflicts 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')"
  if [ "$G_FLIP" = 1 ]; then
    echo "⚠ 另外：检测到「字体包 / 字体设置」相关项（见第 7 节）。"
    echo "   如果你在 设置→显示→字体大小和样式 里选了非默认字体，系统会走字体包，"
    echo "   这种情况下替换 /system/fonts 是无效的，需要先选回「默认」（或系统自带字体）再重启。"
  fi
  if [ "$G_DFONT" = 1 ]; then
    # ★ 2026-10-15 真机订正：以前这里写"**会**盖过 /system/fonts"（确定语气），
  #   但第 7 节和脚注都写"各机型不一样，本报告不替你下结论" —— 自相矛盾。
  #   而 realme RMX5010 的报告证明那句说满了：/data/fonts 里有 SysSans-En-Regular.ttf，
  #   框架读的却是 /system/fonts/SysSans-En-Regular.ttf，这次并没有被盖过。
  #   现在改成**用我们自己的计划对照**：列出"名字重叠、有被盖风险"的那几个，
  #   具体、可核对；不再下绝对结论。
  # 对照对象用 $M/slots.map（本次实际会替换的槽位清单）。
  # ⚠ 不是 ${APPLIED}：报告里那个变量叫 APPLIED_LIST（读的是 slots.applied）。
  #   比对用 shell 内建 case，不起 grep（报告里这种小循环很多，省进程）。
  _df_hit=""
  if [ -n "${G_DFONT_NAMES:-}" ] && [ -s "${M:-/nonexistent}/slots.map" ]; then
    _df_all=$(cat "${M}/slots.map" 2>/dev/null)
    for _dn in $G_DFONT_NAMES; do
      case "$_df_all" in
        *"/$_dn "*) _df_hit="$_df_hit $_dn" ;;
      esac
    done
  fi
  if [ -n "$_df_hit" ]; then
    echo "⚠ 另外：存在 /data/fonts（Android 可更新字体），其中有 ${_df_hit# }"
    echo "     这几个名字**也在本次替换计划里** —— 若系统优先读 /data/fonts，"
    echo "     这几处就轮不到我们（见第 7 节；是否真优先，各机型不同）。"
  else
    echo "ℹ 另外：存在 /data/fonts（Android 可更新字体），但与本次替换计划**没有同名文件**，"
    echo "     不影响我们（详见第 7 节）。"
  fi
  fi
  if [ -n "${OPS_VERDICT:-}" ]; then
    printf '%s\n' "$OPS_VERDICT"
  fi
  if [ "$G_MIUI" = 1 ]; then
    echo "⚠ 另外：检测到 MIUI / HyperOS 个性字体（主题字体）：$MIUI_DIRS"
    echo "   共 $MIUI_FONT_N 个字体文件$([ -n "$MIUI_SHADOW" ] && echo "，其中与系统同名的：$MIUI_SHADOW")"
    if [ "${MIUI_INPLAN:-0}" -gt 0 ] 2>/dev/null; then
      echo "   ✅ 与本次槽位同名的那 $MIUI_INPLAN 个已纳入替换（计划里的 theme 槽位）——"
      echo "      这些名字不会再被主题字体盖住，不需要再去 设置 里切回默认。"
      echo "      ⚠ 但注意：这样一来你在 设置 里选的那个字体（如「小米兰亭 Pro」）也失效了，"
      echo "        如果它本来是用来调「字体粗细」的，粗细会跟着失效（普通字体没有字重轴）。"
    else
      echo "   本模块**默认不替换**这里（设置里的选择优先）——「也替换设置里选的字体」开关是关的。"
      echo "   · 如果你在 设置 里选过字体（尤其「小米兰亭 Pro」这种用来调粗细的可变字体），这样正好："
      echo "     你选的字体照常生效、粗细照常能调，本模块只负责系统目录里的那些槽位。"
      echo "   · 如果你希望模块连这里一起接管（省得去 设置 里切回默认），把那个开关打开即可 ——"
      echo "     代价是设置里选的字体会失效。"
    fi
  fi
  # ---------------------------------------------------------------------------
  # 「字体粗细」相关的关键警告：本机原字体是可变字体（带字重轴），而用户字体是单字重
  #  —— 这是真机上"以前能调粗细、现在调不动了"的根本原因，必须在结论区直接说清楚。
  #  系统实现粗细靠的是可变字体的 wght 轴；换成普通单字重字体后那个轴就不存在了。
  # ---------------------------------------------------------------------------
  _vfn=0; _vflist=""
  if [ -s "$MODDIR/slots.map" ]; then
    while IFS= read -r _a _rel _c; do
      [ -n "$_rel" ] || continue
      case "$_rel" in ""|/*|*..*) continue ;; esac
      [ -f "/$_rel" ] || continue
      case "$(sfnt_tags "/$_rel" 2>/dev/null)" in
        *fvar*)
          _vfn=$((_vfn + 1))
          [ "$_vfn" -le 4 ] && _vflist="$_vflist ${_rel##*/}"
          ;;
      esac
      [ "$_vfn" -ge 30 ] && break
    done < "$MODDIR/slots.map"
  fi
  _myvf=""
  _myp=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")
  case "$_myp" in ""|none) ;; *) _myvf=$(sed -n 's/^vf=//p' "$LIB/$_myp.meta" 2>/dev/null | tail -n1) ;; esac
  if [ "$_vfn" -gt 0 ] 2>/dev/null && [ "$_myvf" != 1 ]; then
    echo "⚠ 重点：本机有 $_vfn 个槽位原本是【可变字体】（带字重轴）:$_vflist"
    echo "   而当前字体是单字重 —— 替换后系统设置里的「字体粗细」调节会失效："
    echo "   系统实现粗细靠的就是可变字体的字重轴，普通字体没有这个轴。"
    echo "   · 想继续能调粗细：导入一个可变字体（文件名常带 VF / Variable，界面会标「可变」）"
    echo "   · 只是想让「加粗」真的变粗：把同族的 Bold 一起导入（本版支持多字重配对）"
  fi
  if [ "$DATAFONT_N" -gt 0 ]; then
    echo "⚠ 另外：检测到「个性化字体」（厂商放在 /data 上、优先级可能高于 /system/fonts）："
printf '%s\n' $DATAFONT_LIST | while IFS= read -r _df; do
      [ -n "$_df" ] || continue
      _dfrel=${_df#"$FSROOT"}; _dfrel=${_dfrel#/}
      _dfin=否; printf '%s\n' "$PLAN_NOW" | grep -qF "$_dfrel" && _dfin=是
      echo "     $_df   $(size_kb "$_df")   修改时间 $(mstamp "$_df")   本次是否替换：$_dfin"
    done
    # ★ 2026-10-12 改：以前这里写"只要这个文件在，屏幕上显示的就一定是它的字形 / 只替换
    #   /system/fonts 完全看不出变化"——真机报告证明这话说满了：
    #   魅族那台 dumpsys 显示框架读的是 /system/fonts/FlymeSansVF.ttf（我们已替换）、
    #   字体配置里也没有任何指向 customizecenter 的引用 → 实际是"部分界面才用它"。
    #   不能拿没验证过的判断去下结论，改成"它是什么 + 我们做没做 + 怎么自己验"。
    echo "   这是什么：魅族这类机器上，你在主题商店下主题 / 在设置里选个性字体时，"
    echo "   厂商会把那份字体写到这个目录（真机例子：Flyme 的 using_font_name=静静字体 → flymeFont.ttf）。"
    echo "   它到底会不会盖过 /system/fonts —— **各机型不一样，本报告不替你下结论**；"
    echo "   想自己确认：看第 3 节的「框架读取的路径」是不是 /system/fonts 里的文件（是 → 我们已生效）。"
    # 1.0.8：魅族这类目录已改成**自动接管**（不再要用户点开关）。报告要说清"这次到底接没接"。
    _tf_on=否
    [ "$(cfg_get theme_fonts auto)" = 0 ] || {
      case "$(cfg_get theme_fonts auto)" in
        1) _tf_on=是 ;;
        *) _theme_auto_ok 2>/dev/null && _tf_on=是 ;;
      esac
    }
    if [ "$_tf_on" = 是 ]; then
      echo "   ✅ 本次会替换它（自动）：这个目录里的字体也会换成你的字体 ——"
      echo "      你在主题商店下免费主题生成的那份 flymeFont.ttf，也会跟着变成你的字体，"
      echo "      不用再自己改名覆盖、也不用额外刷一次。"
      echo "      上面「被保留的槽位」里如果没有它，就说明已经接上了。"
    else
      echo "   ℹ 本次【不动它】。原因可能是："
      echo "      · 你把「模块自带挂载」关了（交给管理器挂载时，/data 上的文件挂不了）；或"
      echo "      · 你在设置里手动关过「设置里选的字体」那一项；或"
      echo "      · 本机没检出这个目录。"
      echo "      想让它接管：界面里把「设置里选的字体没被换掉？」打开，重启一次。"
    fi
  fi

  # ---- 以下是只读探测结果（不依赖上面是否检测到个性化字体）----
    if [ "${DISC_NEW_DIRS:-0}" -gt 0 ] 2>/dev/null; then
  echo "  ★ 自动发现：${DISC_NEW_DIRS} 个目录有字体、但不在已知清单里"
  printf '%s\n' "$DISCOVERED"
  echo "    （请把这段连同报告一起发作者 —— 这就是"该补哪些目录"的直接依据）"
fi
if [ -n "${DISC_NEW_NAMES:-}" ]; then
  echo "  ★ 设备上有、targets 名单里没有的字体名："
  echo "    $DISC_NEW_NAMES"
fi
    # PID 1 视角（只在自挂载模式下有意义：元模块接管时挂载不是我们做的）
  if [ "$(mount_mode 2>/dev/null)" != manager ]; then
    _p1=$(pid1_visible "$M" 2>/dev/null)
    case "$_p1" in
      PID1*)
        _p1v=$(printf '%s\n' "$_p1" | sed 's/^PID1 \([0-9]*\) \([0-9]*\).*/\1/')
        _p1m=$(printf '%s\n' "$_p1" | sed 's/^PID1 \([0-9]*\) \([0-9]*\).*/\2/')
        _p1s=$(printf '%s\n' "$_p1" | sed 's/^PID1 [0-9]* [0-9]*//')
        echo "  PID 1 视角校验：计划里 $((_p1v + _p1m)) 个槽位中，$((_p1v)) 个在 PID 1 的挂载表里可见，$((_p1m)) 个看不到"
        if [ "${_p1m:-0}" -gt 0 ] 2>/dev/null; then
          echo "    看不到的（框架可能读不到我们的字体）：$_p1s"
          echo "    → 若同时有条目显示「生效」，就说明挂载对当前 shell 可见、对框架不可见。"
        fi
        ;;
    esac
  fi

if [ -n "${VDIR_REPORT:-}" ]; then
echo "  厂商/主题字体目录实况（只读探测）："
  printf '%s\n' "$VDIR_REPORT"
  if [ "${VDIR_UNCOVERED:-0}" -gt 0 ] 2>/dev/null; then
    echo "  ⚠ 上面标「未覆盖」的目录里有字体，而本模块**没有**替换它们 ——"
    echo "    如果现象是「部分界面 / 锁屏时钟没变」，很可能就是这些目录在起作用（详见 changelog 说明）。"
  fi
fi
if [ -d "${OPS_BRIDGE:-}" ]; then
  echo "  ── 锁屏 / 时钟字体专项 ──"
  if [ -n "${CLOCK_FONTS:-}" ]; then
    echo "   ① 名字带 clock/time/digit/keyguard 的字体（在不在计划里）："
    printf '%s\n' "$CLOCK_FONTS"
  else
    echo "   ① 没找到名字带 clock/time/digit 的字体（可能时钟并非用文字渲染）"
  fi
  if [ -n "${CLOCK_APK:-}" ]; then
    echo "   ② overlay / 主题 APK 里打包了字体（这类字体改 /system/fonts 无效）："
    printf '%s\n' "$CLOCK_APK"
  else
    echo "   ② 没发现 overlay / 主题 APK 里打包字体"
  fi
  if [ -n "${CLOCK_SET:-}" ]; then
    echo "   ③ 时钟/字体相关设置："
    printf '%s\n' "$CLOCK_SET"
  fi
  if [ -n "${CLOCK_PKG:-}" ]; then
    echo "   ④ 相关系统包：$CLOCK_PKG"
  fi
  echo "  ColorOS 主题字体桥接目录: $OPS_BRIDGE（$OPS_ENTRIES 个字体条目：普通文件 $OPS_FILES / 符号链接 $OPS_LINKS）"
  if [ -n "${OPS_DETAIL:-}" ]; then
    printf '%s\n' "$OPS_DETAIL"
  fi
  echo "  说明: 符号链接指向 /system/fonts 的，本模块替换系统字体时已覆盖；"
  echo "        普通文件是独立副本，本模块**没有**替换（设置里选的字体优先）。"
fi
  echo "===== 结论结束，下面是原始数据（给作者看）====="
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 【0】这台系统的字体靠什么生效（1.0.9 新增，报告里最该先看的一段）
#
# 为什么放最前面：作者只有小米机器，适配别的机型**完全靠别人发来的这份报告**。
#   所以报告第一件要说清的事就是"你这台系统的字体是怎么生效的" ——
#   哪种语言用哪个字体文件、那个文件我们这次到底换没换、没换是因为什么。
#   以前这些信息散在第 5/6 节的原始 XML 里，得人肉读；现在直接列成表。
# 数据来源：设备**自己的字体配置**（fonts.xml 等）里的 lang 标签 —— 这是实锤。
#   不看文件名猜：真机上中文主字体常叫 SysSans-Hans-Regular.ttf / VivoFont.ttf /
#   SECCJK-Regular.ttc，文件名里根本看不出语言。
# ---------------------------------------------------------------------------
sec0() {
  local planall n
  echo
  echo "【0】这台系统的字体靠什么生效（先看这一节）"
  hr
  echo "  说明：下面每一行 = 「某种语言」在系统配置里指向的字体文件。"
  echo "        这是从你这台机器**自己的字体配置**里读出来的（不是按机型猜的）。"
  echo
  echo "  语言标签  语言          配置里引用的字体文件                        本次   没换的原因"
  echo "  --------  ------------  ------------------------------------------  ------  ------------------"
  # 计划整体用来判断"在不在计划里"；scope/keep_lang/keep_special 用来解释"为什么没换"
  planall=$(printf '%s\n' "$PLAN_NOW")
  # ★ 1.0.9.2：这两步单独计时 —— 真机反馈"第 1 步几分钟"，而 collect() 只要 32 秒，
  #   所以慢的必然在这几节里。分开计时才能一次定位，不用再猜。
  _Z0=$(now_s)
  slot_scan_report "$planall" "$SCOPE" "$KL" "$KS" | sed 's/^/  /'
  timing_add 'Y1 sec0/slot_scan_report' "$_Z0"
  _Z0=$(now_s)
  n=$(slot_scan_names 2>/dev/null | grep -c . )
  timing_add 'Y2 sec0/slot_scan_names' "$_Z0"
  echo
  if [ "$n" = 0 ]; then
    echo "  （没能从字体配置里读到任何引用 —— 可能这份配置格式特殊，见第 6 节的原文）"
  else
    echo "  共读到 $n 条语言→字体 的对应关系。"
  fi
  # 自适应扫描有没有真的帮上忙
  if [ "${ADAPTIVE_N:-0}" -gt 0 ] 2>/dev/null; then
    echo "  ★ 本机有 $ADAPTIVE_N 个槽位是**自适应扫描**补出来的（模板没覆盖到，靠你自己的配置认出来的）："
    printf '%s\n' "$CAND_EXTRA_D" | sed 's/^/      /'
  else
    echo "  自适应扫描：模板已覆盖本机需要的角色，无需补充（这不影响结论）。"
  fi
  echo
  echo "  本次替换计划：$(printf '%s\n' "$PLAN_NOW" | grep -c . ) 个槽位；"
  echo "  其中 TTC 合集：$(printf '%s\n' "$PLAN_NOW" | grep -c '^ttc ' 2>/dev/null) 个（合集替换见第 6 节）"
  echo "  实际生效校验：见第 3 节（那里才是「到底换上了没有」的实测）"
  hr
}

sec1() {
  echo
  echo "【1】门禁：可能导致「脚本完全不执行」的开关"
  hr
  echo "  模块目录        : $M"
  echo "  活动模块版本    : ${VER_MOD:-?}   体检脚本版本: ${DIAG_VER:-?}"
  echo "  disable（禁用）  : $([ "$G_DISABLE" = 1 ] && echo '有 ★' || echo 无)"
  echo "  remove（待卸载） : $([ "$G_REMOVE" = 1 ] && echo '有 ★' || echo 无)"
  echo "  update（未激活） : $([ "$G_UPDATE" = 1 ] && echo '有 ★' || echo 无)"
  echo "  modules_update  : $([ -d "$UPD" ] && echo "存在  $UPD" || echo 不存在)$([ "$IN_INSTALL" = 1 ] && echo ' （本次正在安装，必然存在，不作为依据）' || echo '')"
  echo "  Android 安全模式 : persist.sys.safemode=$($GP persist.sys.safemode 2>/dev/null)  ro.sys.safemode=$($GP ro.sys.safemode 2>/dev/null)"
  echo "  本模块运行时的环境变量（识别 Root 管理器的关键）:"
  echo "      APATCH=[${APATCH:-}]  KSU=[${KSU:-}]  MAGISK_VER=[${MAGISK_VER:-}]  MAGISK_VER_CODE=[${MAGISK_VER_CODE:-}]"
  echo "  Magisk 共存     : command -v magisk = $(command -v magisk 2>/dev/null || echo 无)   /data/adb/magisk = $([ -e /data/adb/magisk ] && echo 有 || echo 无)   magisk.db = $([ -e /data/adb/magisk.db ] && echo 有 || echo 无)"
  echo "                    判定: $([ "$G_MAGISK" = 1 ] && { [ -n "${MAGISK_VER:-}${MAGISK_VER_CODE:-}" ] && echo '★ Magisk 的环境变量在（会和部分 Root 管理器冲突）' || echo '☆ 只看到 magisk 命令/目录（很多 APatch 版本会提供 /system/bin/magisk 做兼容，这未必是 Magisk 在跑）'; } || { [ "$MAGISK_LEFT" = 1 ] && echo '只是卸载残留（Magisk 没在运行，不影响本模块）' || echo '没有 Magisk'; })"
  echo "  Root 管理器     : $RM   [$RM_SRC]"
  echo "  ksud            : $KSU_BIN  版本: $KSVER"
  echo "  late-load 模式  : KSU_LATE_LOAD=$KSU_LATE_LOAD   KSU_RUNTIME_MODE=$KSU_RUNTIME_MODE"
  echo "  模块总数        : $G_NMOD 个，其中被禁用 $G_NDIS 个"
  if [ "$G_NMOD" -gt 0 ] && [ "$G_NDIS" = "$G_NMOD" ]; then
    echo "  ★ 所有模块都被禁用了 —— KernelSU 进过安全模式的典型特征（它会禁用全部模块）"
  fi
  echo "  元模块          : $([ -e /data/adb/metamodule ] && readlink /data/adb/metamodule 2>/dev/null || echo 无)"
  echo "  其它模块状态    :"
  for d in /data/adb/modules/*/; do
    [ -d "$d" ] || continue
    echo "      $(basename "$d")  disable=$([ -f "$d/disable" ] && echo 1 || echo 0) update=$([ -f "$d/update" ] && echo 1 || echo 0) webroot=$([ -d "$d/webroot" ] && echo 1 || echo 0)"
  done
  echo "  本模块目录内容  :"
  ls -la "$M" 2>/dev/null | head -n 30 | while IFS= read -r L; do echo "      $L"; done
  echo "  本模块 module.prop:"
  sed -n 'p' "$M/module.prop" 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  echo "  本模块 system 残留: $([ -d "$M/system" ] && echo "有 ($(du -sk "$M/system" 2>/dev/null | cut -f1) KB)" || echo 无)"
  # 关键文件完整性：缺文件不是"少个功能"，fontctl.sh 会直接报错退出（界面报废）；
  # 缺 ttcwrap.sh 则是"合集替换静默不生效"。放在门禁这一节，一眼能看到。
  if [ "$MODDIR" = "$M" ]; then
    echo "  关键文件完整性  : $(modfiles_check "$M")"
  else
    echo "  关键文件完整性  : 运行副本 $MODDIR: $(modfiles_check "$MODDIR")"
    echo "                    活动目录 $M: $(modfiles_check "$M")"
  fi
  echo "  modules_update 目录:"
  ls -la /data/adb/modules_update/ 2>/dev/null | head -n 15 | while IFS= read -r L; do echo "      $L"; done
}

# ---------------------------------------------------------------------------
sec2() {
  echo
  echo "【2】开机脚本痕迹与时间线"
  hr
  echo "  本次 boot_id   : ${BOOTID:-?}"
  echo "  心跳日志       : $BEAT  $([ -f "$BEAT" ] && echo '(存在)' || echo '(没有)')"
  if [ -f "$BEAT" ]; then
    echo "  最近心跳记录   :"
    tail -n 10 "$BEAT" 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  fi
  echo "  mount.state    : $([ -f "$M/mount.state" ] && echo "有   写入于 $(mstamp "$M/mount.state")（$(since_txt "$M/mount.state")）" || echo 没有)"
  if [ -f "$M/mount.state" ]; then
    echo "                   内容: boot=$MS_BOOT ok=$MS_OK fail=$MS_FAIL skip=$MS_SKIP same=$MS_SAME stage=$MS_STAGE"
    echo "                   是否本次开机: $([ "$MS_BOOT" = "$BOOTID" ] && echo 是 || echo 否)"
    echo "                   怎么读: ok=真挂上去的；same=检查时已经指向本模块文件、不用重复挂；"
    echo "                           skip=文件当时不在；fail=挂载失败。"
    echo "                           ok+same 才是「实际覆盖到的槽位」，所以 ok 比槽位总数少是正常的。"
  fi
  echo "  mount_missed   : $([ -f "$M/mount_missed" ] && echo "有 ★ 写入于 $(mstamp "$M/mount_missed")（$(since_txt "$M/mount_missed")）" || echo 没有)"
  echo "                   （若它存在且是「本次开机之前」写的 → 本次开机的 post-fs-data 没跑："
  echo "                     因为 post-fs-data 一执行就会先删掉它）"
  echo "  .booting       : $([ -f "$M/.booting" ] && echo "有   写入于 $(mstamp "$M/.booting")（$(since_txt "$M/.booting")）" || echo 没有)"
  echo "  rescued        : $([ -f "$M/rescued" ] && echo '有（上次开机没完成，已自动恢复成无字体）' || echo 没有)"
  echo "  pending_font   : ${PEND:-none}   写入于 $(mstamp "$M/pending_font")（$(since_txt "$M/pending_font")）"
  echo "  active_font    : ${ACT:-none}   写入于 $(mstamp "$M/active_font")（$(since_txt "$M/active_font")）"
  echo "  payload.mode   : ${MODE_FILE:-?}"
  echo "  slots.applied  : $(printf '%s\n' "$APPLIED_LIST" | grep -c . ) 行   写入于 $(mstamp "$M/slots.applied")（$(since_txt "$M/slots.applied")）"
  echo "  设置 settings.conf:"
  sed -n 'p' "$SETTINGS" 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  echo "  关键文件时间线（旧→新）:"
  for f in "$M/disable" "$M/update" "$M/pending_font" "$M/slots.applied" "$M/payload.mode" "$M/.booting" "$M/mount.state" "$M/mount_missed" "$M/active_font" "$M/rescued" "$LIB/last_selection" "$BEAT" "$LIB/mount.log"; do
    [ -f "$f" ] || continue
    echo "      $(mstamp "$f")  $(since_txt "$f")  ${f#/data/adb/}"
  done
  hr
  echo "  判定: post-fs-data $([ "$PFD_THIS" = 0 ] && echo '未执行 ★' || echo '已执行')    service $([ "$SVC_THIS" = 0 ] && echo '未执行 ★' || echo '已执行')"
}

# ---------------------------------------------------------------------------
# 列出"盖在字体文件上面的挂载"（判断有没有生效、有没有别的模块在压我们）
#
# 老写法是 `mount | grep -c '/system/fonts/'`，会严重低估，两个原因都踩过：
#   1) 只数了 /system/fonts —— 真机上还有 /product/fonts 这些厂商目录。
#      真机实例：24 个槽位全挂上了，这里只显示 6（那 6 个刚好都在 /system/fonts）。
#   2) Magisk 上 /system 常是 /system_root/system 的**符号链接**，挂载表里写的是展开后的路径。
# 所以这里：任意字体目录都算（*/fonts/*），匹配不上再把挂载点展开符号链接判一次。
# 只看文件名是字体扩展名的挂载点，免得把几百条无关挂载都拉进来。
# ---------------------------------------------------------------------------
# 判断一个挂载点/路径是不是"字体目录里的字体文件"
# ★ 2026-10-12：以前只认 */fonts/*（复数）。魅族个性化字体在 /data/customizecenter/**font**/
#   （单数），照旧写法它**明明挂上了也不会被数进来** → 报告会显示"实际生效 N/N"但"上层挂载点 N-1"，
#   看起来像少挂了一个（数字对不上，最容易让人误判）。所以单数 font/ 也要认。
font_path() {
  case "$1" in
    */fonts/*|*/font/*) return 0 ;;
    */fonts|*/font) return 0 ;;
  esac
  return 1
}

font_overlay_list() {
  local mnt r
  "$MO" 2>/dev/null | while IFS= read -r L; do
    case "$L" in *' on '*' type '*) ;; *) continue ;; esac
    mnt=$(printf '%s' "$L" | sed 's/^.* on //; s/ type .*$//')
    case "${mnt##*/}" in
      *.ttf|*.TTF|*.otf|*.OTF|*.ttc|*.TTC) ;;
      *) continue ;;
    esac
    if font_path "$mnt"; then printf '%s\n' "$L"; continue; fi
    r=$(readlink -f "$mnt" 2>/dev/null)
    if font_path "$r"; then printf '%s\n' "$L"; fi
  done
}

sec3() {
  echo
  echo "【3】挂载现状 + 实机挂载能力实测"
  hr
  echo "  字体文件被上层挂载覆盖的条数: $(font_overlay_list | grep -c . )"
  font_overlay_list | head -n 8 | while IFS= read -r L; do echo "      $L"; done
  echo "  （口径：所有字体目录都算，且把挂载点展开符号链接后再判）"
  echo "  （老写法只数 /system/fonts，遇到 /product/fonts 或 /system 是符号链接时会严重低估）"
  echo "  实际生效校验   : $VHIT / $VTOT"
  echo "  实测：$MT_RESULT"
  [ -n "$MT_SRC" ] && echo "      源文件   : $MT_SRC  ($(size_kb "$MT_SRC"))"
  [ -n "$MT_TARGET" ] && echo "      目标槽位 : $MT_TARGET  ($(size_kb "$MT_TARGET"))"
  [ -n "$MT_DETAIL" ] && echo "      详情     : $MT_DETAIL"
  echo "  SELinux 当前模式: $(getenforce 2>/dev/null)"
  echo "  挂载日志 $LIB/mount.log:"
  if [ -f "$LIB/mount.log" ]; then
    tail -n 25 "$LIB/mount.log" 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  else
    echo "      (没有：挂载从没被尝试过)"
  fi
  echo "  slots.map（前 20 行）:"
  head -n 20 "$M/slots.map" 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  echo "  关键挂载/文件系统:"
  "$MO" 2>/dev/null | grep -E ' /system | /system_ext | /product | /vendor | /odm | /prism | /optics | /data ' | head -n 12 | while IFS= read -r L; do echo "      $L"; done
  echo "  overlay / KernelSU / Magisk 挂载（判断有没有元模块接管 /system）:"
  "$MO" 2>/dev/null | grep -E 'overlay|KSU|kernelsu|magisk|/data/adb' | head -n 12 | while IFS= read -r L; do echo "      $L"; done
  echo "  /system 目录属性: $(ls -ld /system 2>/dev/null)"
  echo "  /system/fonts 属性: $(ls -ld /system/fonts 2>/dev/null)"
}

# ---------------------------------------------------------------------------
sec4() {
  echo
  echo "【4】槽位发现详情"
  hr
  echo "  字体目录(真实存在): $(printf '%s' "$FONTDIRS" | tr '\n' ' ')"
  echo "  字体配置 XML: $XMLFOUND"
  echo "  XML 指纹:"
  for x in $XMLFOUND; do
    echo "      $x  $(size_kb "$x")  md5=$(md5sum "$x" 2>/dev/null | cut -d' ' -f1)  mtime=$(mstamp "$x")"
  done
  echo "  候选总数: $CAND_N   当前范围(scope)=$SCOPE  keep_lang=$KL keep_special=$KS"
  echo "  候选明细（角色 目录/文件名）:"
  printf '%s\n' "$CANDS" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  echo "  当前设置下的替换计划 PLAN_NOW: $(printf '%s\n' "$PLAN_NOW" | grep -c . ) 个"
  printf '%s\n' "$PLAN_NOW" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  echo "  全部关闭「保留」后的计划 PLAN_MAX: $(printf '%s\n' "$PLAN_MAX" | grep -c . ) 个"
  echo "  被保留(不会替换)的槽位 = PLAN_MAX - PLAN_NOW:"
  printf '%s\n' "$PLAN_MAX" | while IFS= read -r L; do
    [ -n "$L" ] || continue
    printf '%s\n' "$PLAN_NOW" | grep -qxF "$L" || echo "      $L"
  done
  # 1.0.8：说清"为什么没换"。最常见的两种：
  #   ① 自动让路 —— 字体里没有那一类字形（韩文/日文/繁体），留下系统字体是为了不出方块；
  #   ② 用户自己关过开关，或范围选得小。
  #   ★ 用户看不懂内部名词，所以这里只写"哪一类文字/哪个地方"+"你的字体里没有"。
  if [ "${SLOT_AUTO_RESERVE:-1}" = 1 ] && [ -n "${SEL_FONT:-}" ]; then
    note=""
    # 这里不用 meta_get（它定义在 fontctl.sh，诊断脚本不加载那个）：直接自己读 meta 文件，
    # 少一层依赖，报告这一节也不会因为"少了某个文件"而塌掉。
    _mh() { [ -n "${LIB:-}" ] && [ -f "$LIB/$SEL_FONT.meta" ] && \
            [ "$(sed -n "s/^$1=//p" "$LIB/$SEL_FONT.meta" 2>/dev/null | tail -n1 | tr -d '\r\n')" = 1 ]; }
    _mh hangul || note="${note}韩文 "
    _mh kana   || note="${note}日文 "
    _mh hant   || note="${note}繁体 "
    _mh cjk    || note="${note}中文 "
    if [ -n "$note" ]; then
      echo "  为什么有些没换：你的字体里没有这些字形 → ${note}"
      echo "      （这是自动的：缺哪一类就只留哪一类，其余照常换。想连缺字的也强行替换，"
      echo "        可打开界面里「日文 / 韩文 / 繁体出现方块？」那个开关）"
    fi
  fi
  echo "  实际写入 slots.applied 的槽位:"
  printf '%s\n' "$APPLIED_LIST" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  echo "  已应用槽位里是否包含 .ttc 合集: $APPLIED_TTC 个（设备上共 $TTCNUM 个 .ttc）"
}

# ---------------------------------------------------------------------------
# 【5】实际生效的字体目录与文件 —— 精准适配靠这一节
#   Android 解析规则：XML 里写绝对路径的按绝对路径读；只写文件名的按 /system/fonts/名字 读。
#   这里把符号链接展开、比较目录 dev:ino，区分"同一份目录"与"独立副本"。
# ---------------------------------------------------------------------------
sec5() {
  echo
  echo "【5】实际生效的字体目录与文件（最重要：精准适配靠这一节）"
  hr
  ensure_dirmaps      # 这一节才需要目录映射与名字映射（前面几节不必为 it 买单）
  echo "  Android 规则：XML 里写绝对路径的按绝对路径读；只写文件名的按 /system/fonts/文件名 读。"
  echo
  echo "  1) 本机字体目录（符号链接已展开；dev:ino 相同 = 同一份目录，只需替换一次）"
  echo "     目录                     真实路径                    dev:ino        文件数  占用      与之相同的目录"
  printf '%s\n' "$FONTDIR_MAP" | while IFS='|' read -r d real idn cnt szk same; do
    [ -n "$d" ] || continue
    [ "$real" = "$d" ] && real="（自身）"
    printf '     %-24s %-26s %-14s %-7s %-9s %s\n' "$d" "$real" "$idn" "$cnt" "${szk}KB" "${same:-—}"
  done
  echo
  echo "  2) 配置里引用的字体 → 框架实际会读的路径"
  echo "     （★ 表示还存在一份独立副本；只替换一份的话，个别应用可能读到旧字体）"
  echo "     名字                                   框架实际读取的路径                           存在  副本"
  printf '%s\n' "$NAMEMAP" | while IFS='|' read -r n p real st dup; do
    [ -n "$n" ] || continue
    printf '     %-38s %-44s %-4s %s\n' "$n" "$real" "$st" "${dup:-—}"
  done
  echo
  echo "  3) 当前替换计划落在哪些目录（对照第 1 步，看有没有「白挂」在没人读的目录上）"
  printf '%s\n' "$PLAN_NOW" | while IFS=' ' read -r role rel; do
    [ -n "$rel" ] || continue
    echo "${rel%/*}"
  done | sort | uniq -c | while read -r c dd; do
    real=$(readlink -f "/$dd" 2>/dev/null); [ -n "$real" ] || real="/$dd"
    printf '     %-4s 个 → /%-22s %s\n' "$c" "$dd" "$([ "$real" != "/$dd" ] && echo "(→ $real)")"
  done
  echo
  echo "  4) 这些目录当前是否被挂载覆盖："
  "$MO" 2>/dev/null | grep -E '/system/fonts|/product/fonts|/system_ext/fonts|/vendor/fonts|/odm/fonts' | head -n 8 | while IFS= read -r L; do echo "      $L"; done
  hr
  echo "  小结：$(dir_conclusion)"
  echo "  （把这一节连同第 6 节一起看：第 6 节说明中文/主字体指向哪个文件，本节说明那个文件到底在哪个目录里被读）"
}

# ---------------------------------------------------------------------------
sec6() {
  echo
  echo "【6】字体配置：中文与主字体指向哪个文件、引用的文件是否存在"
  hr
  echo "  /system/fonts 文件总数: $SYSFONT_N"
  echo "  .ttc 合集清单（$([ "$TTC_ON" = 1 ] && echo '本模块会替换：把你的字体包成同 face 数的合集顶上' || echo '本次未启用替换')）:"
  printf '%s\n' "$TTC_LIST" | while IFS= read -r L; do
    [ -n "$L" ] || continue
    # TTC 一般有几十 MB：这里只读前 1 MB（h: 头哈希）就够标识，诊断靠 faces/size，不靠全量哈希
    echo "      $L  $(size_kb "/system/fonts/$L")  faces=$(ttc_faces "/system/fonts/$L")  h=$(head -c 1048576 "/system/fonts/$L" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)"
  done
  [ "$TTCNUM" = 0 ] && echo "      （无）"
  echo "  简中 zh-Hans 是否指向 .ttc: $([ "$ZH_TTC" = 1 ] && echo "是 ★ 这是它的兜底字体（$([ "$TTC_ON" = 1 ] && echo '本模块会把你的字体包成同 face 数的合集替换它，中文也会变' || echo '当前未启用合集替换：主字体家族被替换且含中文字形时中文仍会变')）" || echo 否)"
  # ---- 把每号 face 的 PostScript 名连成一行（最多 6 号，够看清结构）----
  face_names_line() {
    local f="$1" n="${2:-0}" i=0 o=""
    [ "$n" -ge 1 ] 2>/dev/null || { printf '?'; return 0; }
    [ "$n" -gt 6 ] 2>/dev/null && n=6
    while [ "$i" -lt "$n" ]; do
      o="$o$(ttc_face_name "$f" "$i")"
      i=$((i+1))
      [ "$i" -lt "$n" ] && o="$o | "
    done
    printf '%s' "$o"
  }
  # 模块自己判的合集替换方案（换了哪几号 face、凭什么）。上面那份 fonts.xml 在报告里被截断过，
  # 光看它看不出判断结果 —— 这一段是"现场结论"，出问题先看这里。
  if [ -f "$LIB/ttc.log" ]; then
    echo "  ---- 合集替换决策（模块实际怎么判的）----"
    sed 's/^/      /' "$LIB/ttc.log" 2>/dev/null | head -n 20
    echo "      （via=xml = 按字体配置判的；via=fallback = 配置里没找到中文引用、按惯例兜底）"
  fi
  # ---- 原合集 vs 我们生成的：每号 face 的 PostScript 名 ----
  # 真机说"中文没变"时，这里一眼能看出是【结构不对】还是【我们造的名字系统不认】：
  # 换掉的那几号会带着"用户字体自己的名字"，保留的那几号还是原合集的（如 NotoSansCJKjp-Regular）。
  if [ -s "$M/slots.map" ] && grep -q '\.ttc' "$M/slots.map" 2>/dev/null; then
    echo "  ---- 合集 face 名单：原样 vs 我们生成的（每号最多列 6 个）----"
    grep '\.ttc' "$M/slots.map" 2>/dev/null | head -n 3 | while read -r _id rel src; do
      [ -f "/$rel" ] || continue
      _n=$(ttc_faces "/$rel" 2>/dev/null)
      echo "      原   ${rel##*/}（${_n} face）"
      echo "           $(face_names_line "/$rel" "$_n")"
      if [ -n "$src" ] && [ -f "$src" ]; then
        _n2=$(ttc_faces "$src" 2>/dev/null)
        echo "      我们 ${src##*/}（${_n2} face）"
        echo "           $(face_names_line "$src" "$_n2")"
      fi
    done
  fi
  for x in $XMLFOUND; do
    echo "  ---- ${x##*/} 里的 zh 相关 family ----"
    xmlnorm "$x" | grep -i -A 14 '<family[^>]*lang="zh' | head -n 60 | while IFS= read -r L; do echo "      $L"; done
    echo "  ---- ${x##*/} 里的 sans-serif family ----"
    xmlnorm "$x" | grep -i -A 20 '<family[^>]*name="sans-serif"' | head -n 45 | while IFS= read -r L; do echo "      $L"; done
  done
  echo "  配置里引用到的字体文件名 → 设备上是否存在（完整映射见第 5 节）:"
  printf '%s\n' "$XMLNAMES" | while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in */*) continue ;; esac
    if [ -f "/system/fonts/$n" ]; then
      echo "      ✅ $n"
    else
      hit=$(for d in $FONTDIRS; do [ -f "$d/$n" ] && echo "$d/$n"; done | head -n1)
      if [ -n "$hit" ]; then echo "      ✅ $n  ($hit)"
      else echo "      ❌ 配置引用了但设备上找不到: $n"; fi
    fi
  done
        echo "  运行时字体列表（部分机型支持 cmd font dump）:"
        tmo 6 "$CMD" font dump sans-serif 2>/dev/null | head -n 30 | while IFS= read -r L; do echo "      $L"; done
        tmo 6 "$CMD" font dump 2>/dev/null | head -n 15 | while IFS= read -r L; do echo "      [dump] $L"; done
        tmo 6 dumpsys font 2>/dev/null | head -n 15 | while IFS= read -r L; do echo "      [dumpsys] $L"; done
}

# ---------------------------------------------------------------------------
sec7() {
  echo
  echo "【7】字体来源排查：系统上「真正生效的字体」有没有被别的东西接管"
  hr
  # 这一节才需要这三个重活（各 1~3 秒），前面几节不再为它们买单
  ensure_settings_font
  ensure_pkgs
  ensure_datafonts
  echo "  字体相关设置项(settings):"
  printf '%s\n' "$S_FONT" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  [ -z "$S_FONT" ] && echo "      （无）"
  echo "  已安装的字体包（monotype / flipfont / font）:"
  printf '%s\n' "$PKG_FONT" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  [ -z "$PKG_FONT" ] && echo "      （无）"
  echo "  /data/app 下的字体包目录:"
  ls -d /data/app/*font* /data/app/*monotype* 2>/dev/null | head -n 10 | while IFS= read -r L; do echo "      $L"; done
  echo "  Android 可更新字体 /data/fonts:"
  printf '%s\n' "$DFONT_LIST" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  [ -z "$DFONT_LIST" ] && echo "      （不存在）"
  if [ -n "$DFONT_CFG" ]; then
    echo "  /data/fonts/config/config.xml:"
    printf '%s\n' "$DFONT_CFG" | while IFS= read -r L; do echo "      $L"; done
  fi
  echo "  三星主题/字体 overlay 目录:"
  ls -la /data/overlays 2>/dev/null | head -n 12 | while IFS= read -r L; do echo "      $L"; done
  ls -d /data/overlays/*font* /data/overlays/*/*font* 2>/dev/null | head -n 10 | while IFS= read -r L; do echo "      $L"; done
  [ -d /data/overlays ] || echo "      （不存在）"
  echo "  Samsung floating_feature.xml 里与字体相关:"
  grep -i 'font' /system/etc/floating_feature.xml 2>/dev/null | head -n 15 | while IFS= read -r L; do echo "      $L"; done
  echo "  属性里与字体/OneUI 相关:"
  "$GP" 2>/dev/null | grep -iE 'font|oneui|ro\.sem|knox' | head -n 20 | while IFS= read -r L; do echo "      $L"; done
  echo "  属性里与 KernelSU/校验 相关:"
  "$GP" 2>/dev/null | grep -iE 'ksu|kernelsu|verity|warranty|bootloader|selinux|secure' | head -n 20 | while IFS= read -r L; do echo "      $L"; done
  echo "  APEX 里与字体相关:"
  ls -1 /apex 2>/dev/null | grep -i font | while IFS= read -r L; do echo "      $L"; done
  echo "  MIUI / HyperOS 个性字体（主题字体）—— 会接管系统字体:"
  if [ "$MIUI_FONT_N" -gt 0 ]; then
    echo "      目录: $MIUI_DIRS"
    printf '%s\n' "$MIUI_FONTLIST" | while IFS= read -r L; do
      [ -n "$L" ] || continue
      echo "      $L  $(size_kb "$L")  mtime=$(mstamp "$L")"
    done
    echo "      与系统字体同名的（会顶替系统字体）: ${MIUI_SHADOW:-无}"
    if [ "${MIUI_INPLAN:-0}" -gt 0 ] 2>/dev/null; then
      echo "      其中已纳入本模块替换的: $MIUI_INPLAN 个（见计划里的 theme 行）"
      echo "      说明: 这几个文件会被本模块一并替换，主题字体不再盖住它们。"
    else
      echo "      说明: 与本次槽位同名的会被本模块一并替换（要打开「也替换设置里选的字体」）；不同名的不动。"
      echo "            如当前列表一个都没覆盖到，说明主题用的名字和系统槽位都不一样。"
    fi
  else
    echo "      （未检测到个性字体，系统字体走 /system/fonts 等系统目录）"
  fi
  echo "  厂商个性化字体（厂商写在 /data 上的固定路径；会不会盖过 /system/fonts 各机型不同）:"
  if [ "$DATAFONT_N" -gt 0 ]; then
    printf '%s\n' $DATAFONT_LIST | while IFS= read -r L; do
      [ -n "$L" ] || continue
      echo "      $L  $(size_kb "$L")  mtime=$(mstamp "$L")"
      echo "          前 4 字节: $(magic4 "$L")   表信息: $(sfnt_tags "$L")"
    done
    # 在不在"本次计划"里 —— 这一条比解释更有用（以前只写"本模块不会动它"）
    printf '%s\n' $DATAFONT_LIST | while IFS= read -r L; do
      [ -n "$L" ] || continue
      Lrel=${L#"$FSROOT"}; Lrel=${Lrel#/}
      if printf '%s\n' "$PLAN_NOW" | grep -qF "$Lrel"; then
        echo "      ✅ 在本次替换计划里：$Lrel"
      else
        echo "      —  不在本次替换计划里：$Lrel   （想要就打开「也替换设置里选的字体」再重启）"
      fi
    done
    echo "      · 手动换法（不依赖模块）：用文件管理器把自己的字体改名成 flymeFont.ttf 覆盖它，重启即可"
    echo "      · 会不会盖过 /system/fonts：看第 3 节的「框架读取的路径」，是 /system/fonts 里的文件就说明我们已生效"
  else
    echo "      （未检测到；魅族机器上看 /data/customizecenter/font/flymeFont.ttf）"
  fi
  echo "  MIUI / 主题 相关目录:"
  for td in /data/system/theme /data/miui/theme /data/miui/themes /data/system/theme_font; do
    [ -e "$td" ] && echo "      $td  $(ls -1 "$td" 2>/dev/null | head -n 8 | tr '\n' ' ')"
  done
  echo "  属性/设置里与 MIUI 字体相关:"
  "$GP" 2>/dev/null | grep -iE 'miui|hyperos|mi\.os|theme' | head -n 15 | while IFS= read -r L; do echo "      [prop] $L"; done
  { "$SETBIN" list system 2>/dev/null; "$SETBIN" list secure 2>/dev/null; } | grep -iE 'theme|font' | grep -viE 'scale|size' | head -n 10 | while IFS= read -r L; do echo "      [setting] $L"; done

  # ---- 谷歌字体（GMS 下载字体）：另一条"绕开 /system/fonts"的路 ----
  # Google 系应用（Play 商店 / Chrome 等）会向 Play 服务要"下载字体"，那些文件在 GMS 的
  # 私有缓存里，不经过系统字体目录 —— 所以只替换系统字体时，英数会"过一阵又变回谷歌默认"。
  # 现场全部列出来（只读，不改任何东西），结论写在结论区。
  echo "  ---- 谷歌字体（GMS 下载字体）与「谷歌字体兼容」开关 ----"
  echo "     开关当前状态: $(gf_state_text "${GF_STATE:-unknown}")$( [ "${GF_CACHED:-0}" = 1 ] && echo '（实时检测超时，这是缓存值；点界面「重新检测」看最新）')"
  [ "${GF_SEC:-0}" -ge 3 ] 2>/dev/null && echo "     本节耗时: ${GF_SEC} 秒"
  if [ -n "$GF_DIAG" ]; then
    printf '%s\n' "$GF_DIAG" | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  else
    echo "     （现场明细这次没取到 —— 已在报告开头「完整性声明」里注明）"
  fi
  echo "     说明：本功能只停用「下载字体」这一个组件；不停用整个 Play 服务、不删字体缓存、"
  echo "           不改系统字体配置。应用自带字体、网页字体不受影响。"
}

# ---------------------------------------------------------------------------
sec8() {
  echo
  echo "【8】/system/fonts 完整清单与权限标签"
  hr
  echo "  /system/fonts 内容（名称 大小 权限 标签）:"
  ls -lZ /system/fonts 2>/dev/null | head -n 250 | while IFS= read -r L; do echo "      $L"; done
  echo "  /system/fonts 总占用: $(du -sk /system/fonts 2>/dev/null | cut -f1) KB"
  echo "  字体库文件（$(printf '%s\n' "$LIB_FONTS" | grep -c . ) 个）:"
  ls -lZ "$LIB"/f*.ttf 2>/dev/null | head -n 30 | while IFS= read -r L; do echo "      $L"; done
  echo "  字体库名称/元数据:"
  for f in $LIB_FONTS; do
    i=${f##*/}; i=${i%.ttf}
    echo "      $i  name=$(cat "$LIB/$i.name" 2>/dev/null | tr -d '\r\n')  meta=$(tr '\n' ',' < "$LIB/$i.meta" 2>/dev/null | sed 's/,$//')"
  done
  echo "  字体库文件首 4 字节与表标签:"
  for f in $LIB_FONTS; do
    echo "      ${f##*/}  $(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')  标签: $(sfnt_tags "$f")"
  done
  if [ -n "$TTCFIRST" ]; then
    echo "  系统中文合集 $TTCFIRST: faces=$(ttc_faces "/system/fonts/$TTCFIRST")  头=$(ttc_tag "/system/fonts/$TTCFIRST")  标签: $(sfnt_tags "/system/fonts/$TTCFIRST")"
  fi
  echo "  磁盘: /data 剩余 $(df -k /data 2>/dev/null | tail -n1 | tr -s ' ' | cut -d' ' -f4) KB   模块目录占用 $(du -sk "$M" 2>/dev/null | cut -f1) KB"
}

# ---------------------------------------------------------------------------
sec9() {
  echo
  echo "【9】其它可能冲突的模块 / 字体相关文件"
  hr
  echo "  判定规则：只把「会挂到系统分区上的字体」算冲突（system/**/fonts 或根级厂商分区）；"
  echo "  webroot/webui 等界面目录里自带的字体不算（早期版本会误报，例子：ReZygisk）。"
  echo "  当前被判为字体冲突的模块（fontctl.sh conflicts）:"
  sh "$MODDIR/fontctl.sh" conflicts 2>/dev/null | while IFS= read -r L; do [ -n "$L" ] && echo "      $L"; done
  echo "  各模块的系统字体目录:"
  for d in /data/adb/modules/*/; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "$ID" ] && continue
    for sub in system/fonts system/product/fonts system/system_ext/fonts system/vendor/fonts \
               system/odm/fonts vendor/fonts product/fonts system_ext/fonts odm/fonts \
               my_product/fonts mi_ext/fonts prism/fonts optics/fonts; do
      [ -d "$d$sub" ] || continue
      echo "      ${d#/data/adb/modules/}$sub :"
      ls -1 "$d$sub" 2>/dev/null | head -n 10 | while IFS= read -r L; do echo "          $L"; done
    done
  done
  echo "  其它模块里的 fonts*.xml:"
  ls -1 /data/adb/modules/*/system/etc/font*.xml 2>/dev/null | head -n 10 | while IFS= read -r L; do echo "      $L"; done
  echo "  界面目录里自带的字体（不算冲突，仅记录）:"
  ls -1 /data/adb/modules/*/webroot/fonts/* /data/adb/modules/*/webui/fonts/* 2>/dev/null | head -n 10 | while IFS= read -r L; do echo "      $L"; done
  echo "  本模块 skip_mount: $([ -f "$M/skip_mount" ] && echo 有 || echo 无)"
}

# ---------------------------------------------------------------------------
sec10() {
  echo
  echo "【10】管理器日志与系统信息"
  hr
  echo "  内核: $(uname -a 2>/dev/null)"
  echo "  内核版本: $(cat /proc/version 2>/dev/null)"
  echo "  cmdline: $(cat /proc/cmdline 2>/dev/null | head -c 300)"
  echo "  uapi: ksud=$KSVER"
  echo "  /data/adb 目录:"
  ls -la /data/adb/ 2>/dev/null | head -n 20 | while IFS= read -r L; do echo "      $L"; done
  echo "  /data/adb/ksu/ 目录:"
  ls -la /data/adb/ksu/ 2>/dev/null | head -n 12 | while IFS= read -r L; do echo "      $L"; done
  echo "  /data/adb/ksu/log/:"
  ls -la /data/adb/ksu/log/ 2>/dev/null | head -n 12 | while IFS= read -r L; do echo "      $L"; done
  echo "  关键行（skip / safe mode / Magisk / post-fs-data / post-mount / exec）:"
  grep -a -E 'skip|safe mode|Magisk detected|post-fs-data|post-mount|exec /data/adb/modules' /data/adb/ksu/log/*.log 2>/dev/null | tail -n 30 | while IFS= read -r L; do echo "      $L"; done
  echo "  dmesg 中的 KernelSU 信息:"
  tmo 6 dmesg 2>/dev/null | grep -i -E 'kernelsu|ksud|ksu_' | tail -n 10 | while IFS= read -r L; do echo "      $L"; done
  echo "  电池/内存/存储:"
  echo "      MemTotal=$(sed -n 's/^MemTotal: *//p' /proc/meminfo 2>/dev/null)  MemAvailable=$(sed -n 's/^MemAvailable: *//p' /proc/meminfo 2>/dev/null)"
  df -k /data /cache /metadata 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  echo "  校验相关属性:"
  for p in ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.veritymode ro.security.vaultkeeper.feature ro.crypto.state ro.boot.warranty_bit ro.boot.bootloader ro.build.version.oneui ro.build.version.sem ro.build.version.security_patch; do
    echo "      $p=$($GP "$p" 2>/dev/null)"
  done
}

# ---------------------------------------------------------------------------
# 【11】应用侧是否看得到这些挂载
#   「只有桌面 / 主界面生效，App 里没变」不是挂载失败（那会全都不变），而是管理器
#   在每个应用进程里把模块挂载卸掉了。这一节把现场证据摊开，并给出下一步动作。
# ---------------------------------------------------------------------------
sec11() {
  echo
  echo "【11】应用侧是否看得到这些挂载（「只有桌面 / 主界面生效」就查这里）"
  hr
  echo "  报告是 root 权限在**全局**挂载命名空间里跑的，看到的是全局真相；"
  echo "  而「卸载模块」是在**每个 App 自己的进程里**把模块挂载摘掉 —— 所以："
  echo "  「挂载成功」不等于「每个 App 都看得到」，这一节专门查这件事。"
  echo
  echo "  1) 本机有没有这个机制（管理器 + 内核）"
  echo "     Root 管理器      : $RM（$(root_manager_name "$RM" 2>/dev/null)）   元模块: $([ -e /data/adb/metamodule ] && readlink /data/adb/metamodule 2>/dev/null || echo 无)"
  echo "     内核版本         : ${AS_KREL:-?}"
  if [ "$AS_RISK" = 1 ]; then
    echo "     → 5.10 及以上：KernelSU 系内核会**真的执行**「卸载模块」（不是只当配置项）"
  else
    echo "     → 按内核 / 管理器判断：这一节描述的机制在本机（$RM）不一定生效，仅供参考"
  fi
  echo "     内核里的默认值就是「卸」：不受影响的只有管理器自己、授予过 root 权限的 App、"
  echo "     以及 uid 1000（SystemUI 等）这类系统进程 —— 这正是「系统界面正常、App 没变」的原因。"
  echo
  echo "  2) 实测：同一个 App 进程里能不能看到我们的挂载"
  echo "     我们自己的命名空间 : ${AS_MINE:-?} 条（源在 $LIB 的绑定挂载）"
  [ "${AS_SEC:-0}" -ge 3 ] 2>/dev/null && \
    echo "     （本节耗时 ${AS_SEC} 秒，试了 ${AS_TRIED:-?} 个进程$( [ "${AS_TIMEOUT:-0}" = 1 ] && echo '，到时间上限就停了' )）"
  if [ "$AS_READ" = 1 ]; then
    printf '%s' "$AS_LIST" | while IFS='|' read -r _p _u _c _n; do
      [ -n "$_p" ] || continue
      echo "     App pid=$_p uid=$_u → 看到 ${_n} 条   ${_c}"
    done
    [ "${AS_TIMEOUT:-0}" = 1 ] && \
      echo "     （抽样到时间上限就停了 —— 上面这几个样本足够判断，不必等它扫完）"
  else
    if [ "${AS_TIMEOUT:-0}" = 1 ]; then
      echo "     （扫了 ${AS_SEC} 秒到上限，还没抽到普通 App 进程 —— /proc 里进程太多）"
      echo "       这不影响结论：第 3 节已经证明挂载本身是成功的。"
    else
      echo "     （没找到可对照的普通 App 进程：应用都没在跑，或 /proc 读不到）"
      echo "      让用户先打开任意一个普通 App，再重新生成一次报告，就能对照了。"
    fi
  fi
  if [ "$AS_HIDDEN" = 1 ]; then
    echo "     ★ 判定：App 侧看到 0 条，而我们自己看到 ${AS_MINE} 条 ——"
    echo "       管理器已经把模块从应用进程里卸载了。不是挂载失败，也不需要改模块。"
  elif [ "$AS_READ" = 1 ]; then
    echo "     （两边都能看到，或抽到的这个 App 恰好被授予过 root）"
    echo "      ℹ 授予了 root 权限的 App **不会**被卸载，所以它看到「有」不代表别的 App 也有。"
  fi
  echo
  echo "  3) 管理器侧的现场（原样列出，不做格式猜测）"
  echo "     kernel_umount（.feature_config）: $AS_FEATURE"
  echo "        ${AS_FEATURE_HINT:-}"
  echo "     /data/adb/ksu/.umount           : $AS_DOTUM"
  echo "     元模块配置                       : ${AS_METAUM:-（没找到 config.toml）}"
  echo "     （找不到这些文件不代表没这个机制：名单也可能只在管理器内部或内核里）"
  echo
  echo "  4) 怎么办（按顺序试，一次只改一个，改完重启再看同一个 App）"
  echo "     ⓪ 最省事：给 KernelSU 加一个全局开关（一次对所有 App 生效，不用逐个点）"
  echo "        /data/adb/ksu/.feature_config  里加一行：kernel_umount=0"
  echo "        （文件不存在就新建，只写这一行也行；改完重启。）"
  echo "     ① 或者：管理器 → 设置 → 关掉「默认卸载模块」"
  echo "        （= 黑名单模式：以后只有你手动开的 App 才卸）"
  echo "     ② 或者只给那一个 App 关：管理器的「应用配置 / App Profile」里把它的「卸载模块」关掉"
  echo "     ③ 装了元模块（Hybrid Mount 等）的：把它的「禁用卸载 / disable_umount」改成 true"
  echo "     改了还是没变 → 就不是这条原因，回到第 5 / 6 节找（槽位没进计划、中文走 .ttc 等）。"
  echo "  ℹ 另外：网页 / 小程序 / 内置浏览器属于 WebView，它的渲染进程是「隔离进程」——"
  echo "     KernelSU 系对隔离进程是**无条件**卸载的，这类内容里的字体不受本模块影响（正常现象）。"
  hr
}

# ---------------------------------------------------------------------------
# 字体扒包：把「能离线重建槽位清单」的原始数据全部吐出来
#   - 所有 font*.xml 的完整原文
#   - 每个字体文件的 sha256 + 大小（哈希清单，用于核对 ROM 版本）
#   - 每个字体文件的首 4 字节与 sfnt 表标签（判断可变字体 / TTC）
#   - family -> 文件 -> 属性 的对应关系
#   - 所有字体目录的完整清单
# 沙盒端用 tools/gen_targets.py 解析本段，生成 targets/<rom>.list
# ---------------------------------------------------------------------------
pack_extra() {
  # ★ 1.0.9.2：第 6 步分段计时（PZ1~PZ12）。真机上这一步占总耗时约八成，
  #   但原来只有一段总时间，看不出是哪个小段慢。计时器挂在每个 subnote 之前。
  _PZ_T=$(now_s)
  echo
  ensure_dirmaps      # 导出数据包要带上目录映射与名字映射
  echo "@@SECTION:META"
  echo "time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  # 哈希口径：head1mb = 只读前 1 MB（轻量模式，对闪存友好）；full = 全文件
      echo "hash_mode=sparse"   # 1.0.9.2：稀疏指纹（大小+mtime+头尾 64KB），不再全量读盘
      echo "fast=0"   # 1.0.9：不再有快速口径（字段保留，兼容旧界面）
  echo "brand=$($GP ro.product.brand 2>/dev/null)"
  echo "model=$($GP ro.product.model 2>/dev/null)"
  echo "device=$($GP ro.product.device 2>/dev/null)"
  echo "android=$($GP ro.build.version.release 2>/dev/null)"
  echo "sdk=$($GP ro.build.version.sdk 2>/dev/null)"
  echo "build=$($GP ro.build.display.id 2>/dev/null)"
  echo "oneui=$($GP ro.build.version.oneui 2>/dev/null)"
  echo "sem=$($GP ro.build.version.sem 2>/dev/null)"
  echo "kernel=$(uname -r 2>/dev/null)"
  echo "ksud=$KSVER"
  echo "manager=$RM"
  echo "module=${VER_MOD:-?}"
  echo "diag=${DIAG_VER:-?}"
  echo "rom=$(rom_name "$ROMID" 2>/dev/null)"
  echo "boot_id=$BOOTID"
  echo "uptime=$UP"
  echo "@@SECTION:FONTDIRS"
  printf '%s\n' "$FONTDIRS"
  echo "@@SECTION:FONTDIRMAP"
  echo "# 目录|真实路径|dev:ino|文件数|占用KB|与之相同的目录"
  printf '%s\n' "$FONTDIR_MAP"
  echo "@@SECTION:NAMEMAP"
  echo "# 名字|框架解析路径|真实路径|是否存在|同名副本"
  printf '%s\n' "$NAMEMAP"
  echo "@@SECTION:FONTS_SHA256"
      echo "# hash_mode=sparse（大小 + 修改时间 + 头尾各 64KB 的 sha256；同一份内容只算一次、重复路径复用同一指纹）
# ★ 2026-10-18：取哈希值时不再多起一个 cut 进程，改用 `read` 拆字段（300 个字体省 300 个进程）。"
  echo "# note=同一个字体目录被多个路径指到时只算一次（以前会重复哈希好几遍，这是最后一步特别慢的主因）"
  XMLNAMES_STR=" $(printf '%s' "$XMLNAMES" | tr '\n' ' ')"
  HDIRS=$(uniq_fontdirs)
  # 先数一下总数（只数个数，很便宜），用来显示"哈希 120/312"
  ftotal=0
  for d in $HDIRS; do
    ftotal=$((ftotal + $(ls -1 "$d" 2>/dev/null | wc -l)))
  done
  n=0; HN=0
  # 指纹（1.0.9.2：**稀疏指纹**，口径见本文件开头 fp_of 的说明）
  #   · 每个字体文件取"大小 + 修改时间 + 头尾各 64KB"，不再全量 sha256 ——
  #     1.0.9.1 的全量读盘让真机第 6 步花了 391 秒（字体目录约 700MB），现在降到十几秒。
  #     ★ 1.0.9 当时写过"绝不为了快改成只读头部（怕漏掉尾部被改）"，
  #       1.0.9.2 改成**头尾都取样**：既省 20 倍 I/O，又保住了"尾部改动也能发现"。
  #   · 去重：同一份文件只真正算一次。字体目录里大量文件是指向同一份的
  #     硬链接/符号链接（真机实测过 18 个文件指向同一个），以前同一份内容被反复读好几遍。
  #     做法是两遍式：第一遍按 dev:inode 去重后算出指纹，第二遍每个路径各输出一行（复用指纹）。
  # ★ 2026-10-22（提速，带自证）：门牌号（dev:inode）快判。
  #   仍保留原指纹逻辑；只有"抽样核对通过"时才启用快判。
  OUR_INO=""; FP_FAST=0; FP_FAST_N=0; FP_SAMPLE_OK=0; FP_SAMPLE_BAD=0
  _mk_ours() {
    SMAP=$(slots_map_path)
    local _s _id _ino
    for _s in "$LIB"/*.ttf; do
      [ -e "$_s" ] || continue
      _id=${_s##*/}; _id=${_id%.ttf}
      _ino=$(stat -L -c '%d:%i' "$_s" 2>/dev/null)
      [ -n "$_ino" ] || continue
      case "$OUR_INO" in *"|$_ino="*) ;; *) OUR_INO="$OUR_INO|$_ino=$_id" ;; esac
    done
    if [ -s "$SMAP" ]; then
      awk -v lib="$LIB" 'NF >= 2 { print ($3 != "" ? $3 : lib "/" $1 ".ttf") }' "$SMAP" 2>/dev/null | tr -d '\r' | sort -u | \
      while IFS= read -r _s; do
        [ -e "$_s" ] || continue
        _ino=$(stat -L -c '%d:%i' "$_s" 2>/dev/null)
        [ -n "$_ino" ] || continue
        printf '%s\n' "$_ino"
      done > "$LIB/.ours.ino.$$" 2>/dev/null
      if [ -s "$LIB/.ours.ino.$$" ]; then
        OUR_INO="$OUR_INO$(sed 's/^/|/;s/$/=map/' "$LIB/.ours.ino.$$" 2>/dev/null)"
      fi
      rm -f "$LIB/.ours.ino.$$" 2>/dev/null
    fi
  }
  # 抽样核对：源文件与目标槽位的 inode 必须一致（bind 挂载语义）
  _fp_sample() {
    SMAP=$(slots_map_path)
    local _rel _src _dst _a _b _n=0 _line _seen=0
    [ -s "$SMAP" ] || return 0
    while IFS= read -r _line; do
      _line=${_line%$'\r'}
      [ -n "$_line" ] || continue
      _seen=$((_seen + 1))
      [ "$_seen" -gt 30 ] && break          # 最多看 30 行，避免大文件白跑
      FP_SCAN=$_seen
      # shellcheck disable=SC2086
      set -- $_line
      [ $# -ge 2 ] || continue
      _rel="$2"; _src="$3"
      # ★ 第三列是可选的（mount.sh：<id> <目标> [挂哪个文件]），缺省就是 $LIB/<id>.ttf
      [ -n "$_src" ] || _src="$LIB/$1.ttf"
      case "$_rel" in
        /*) _dst="${CFS_DST_ROOT:-}$_rel" ;;
        *)  _dst="${CFS_DST_ROOT:-}/$_rel" ;;
      esac
      # 源文件容错：原样不存在就试试字体库里的同名文件
      if [ ! -e "$_src" ]; then
        case "$_src" in
          */*) _src="$LIB/${_src##*/}" ;;
        esac
      fi
      [ -e "$_dst" ] || continue
      [ -e "$_src" ] || continue
      _a=$(stat -L -c '%d:%i' "$_src" 2>/dev/null)
      _b=$(stat -L -c '%d:%i' "$_dst" 2>/dev/null)
      [ -n "$_a" ] && [ -n "$_b" ] || continue
      _n=$((_n + 1))
      if [ "$_a" = "$_b" ]; then
        echo "OK $_dst  <- $_src"
      else
        echo "BAD $_dst  (目标 $_b / 源 $_a)"
      fi
      [ "$_n" -ge 2 ] && break
    done < "$SMAP" 2>/dev/null
    # ★ 扫描行数由函数自己打印（它跑在子 shell 里，变量传不回去）
    echo "SCAN $_seen"
  }
  _mk_ours
  _smp=$( _fp_sample )
  # 从输出里取扫描行数（子 shell 里设的变量回不来）
  FP_SCAN=$(printf '%s\n' "$_smp" | sed -n 's/^SCAN //p' | head -n1)
  case "$FP_SCAN" in ''|*[!0-9]*) FP_SCAN=0 ;; esac
  # 明细里去掉 SCAN 行，只留 OK/BAD 样本
  FP_SAMPLE_DETAIL=$(printf '%s\n' "$_smp" | grep -E '^(OK|BAD) ' 2>/dev/null)
  _smp=$(printf '%s' "$FP_SAMPLE_DETAIL")
  case "$_smp" in
    *BAD*) FP_FAST=0; FP_SAMPLE_BAD=$(printf '%s' "$_smp" | grep -c BAD) ;;
    "")    FP_FAST=0 ;;
    *)     FP_FAST=1; FP_SAMPLE_OK=$(printf '%s' "$_smp" | grep -c OK) ;;
  esac
  echo "@@FPFAST fast=$FP_FAST ok=$FP_SAMPLE_OK bad=$FP_SAMPLE_BAD" >> "$LIB/.perf.log" 2>/dev/null

  HASH_MAP=""          # "|dev:inode=指纹|..."（去重后的唯一文件）
  HASH_KEY=""; HASH_SEEN=""; HASH_DONE=0; HASH_TOTAL=0
  HASH_BATCH=""; HASH_BN=0
  # 第一遍：算出所有**唯一文件**的指纹
  # ★★ 1.0.9.2 定稿：**就用每文件一次 stat**（原版写法）。
  #   我试过"整个目录一次 stat 建表 + 内存查表"，真机实测**更慢**：
  #     每文件 stat：288 秒   →   批量建表 + 大字符串查表：**314 秒**
  #   原因：`case "$INODE_MAP" in *";$f|"*` 要在**上万字符**的表里逐个匹配，
  #   293 个文件 × 表越来越长，纯 shell 的字符串匹配比直接起一次 `stat` 还贵。
  #   教训：**"少起进程"不等于"更快"** —— 大字符串查表在 shell 里也是 O(n·m)。
  #   要提速得换思路（批量 sha256sum 之类），不能靠"把进程换成字符串匹配"。
  for d in $HDIRS; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      _hk=$(stat -c '%d:%i' "$f" 2>/dev/null)
      if [ -n "$_hk" ]; then
        case "$HASH_SEEN" in *"|$_hk|"*) continue ;; esac    # 这份内容算过了
        HASH_SEEN="$HASH_SEEN|$_hk|"
      fi
      HASH_TOTAL=$((HASH_TOTAL + 1))
      # ★ 门牌号快判：这个文件就是我们挂上去的那份 → 不用读盘算指纹
      if [ "$FP_FAST" = 1 ] && [ -n "$_hk" ]; then
        case "$OUR_INO" in
          *"|$_hk="*)
            _oid=${OUR_INO#*"|$_hk="}; _oid=${_oid%%|*}
            HASH_MAP="$HASH_MAP|$_hk=o:$_oid"
            HASH_DONE=$((HASH_DONE + 1))
            FP_FAST_N=$((FP_FAST_N + 1))
            continue ;;
        esac
      fi
      case "$f" in
        *" "*)
          hash_flush
          # 文件名带空格：单独算，并且立刻记进表（hash_one 自己会打印一行，这里改用只算不打印）
          _h1=$(sha256sum "$f" 2>/dev/null); _h1=${_h1%% *}
          [ -n "$_h1" ] || _h1="-"
          [ -n "$_hk" ] && HASH_MAP="$HASH_MAP|$_hk=$_h1"
          HASH_DONE=$((HASH_DONE + 1))
          continue ;;
      esac
      HASH_KEY="$HASH_KEY $_hk"      # 与 HASH_BATCH 位置一一对应
      HASH_BATCH="$HASH_BATCH $f"
      HASH_BN=$((HASH_BN + 1))
      [ "$HASH_BN" -ge 20 ] && hash_flush
    done
    hash_flush
  done
  # 第二遍：每个路径各输出一行（重复的复用指纹），这样报告里路径一行不少
  HN=0
  for d in $HDIRS; do
    [ -d "$d" ] || continue
    # ★ load_meta（不是 load_sizes）：它一次 stat 同时建好"大小"和"mtime"两张表。
    #   下一遍算指纹时 fp_of() 要用 mtime，没有这张表就得每个文件再起一次 stat。
    load_meta "$d"
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      _hk=$(stat -c '%d:%i' "$f" 2>/dev/null)
      _hv="-"
      if [ -n "$_hk" ]; then
        case "$HASH_MAP" in
          *"|$_hk="*) _hv=${HASH_MAP#*"|$_hk="}; _hv=${_hv%%|*} ;;
        esac
      fi
      printf '%s  %s  %s\n' "$_hv" "$(size_of "$f")" "$f"
      HN=$((HN + 1))
      [ $((HN % 25)) -eq 0 ] && breathe "指纹 $HN/$ftotal" "$HN" "$ftotal" 2>/dev/null
    done
  done
  echo "@@SECTION:FONT_META"
  n=0
  for d in $HDIRS; do
    [ -d "$d" ] || continue
    # ★ 同样换成 load_meta：这一遍后面要用 size_of() 判"文件够不够 4 字节取魔数"，
    #   用 load_meta 建的表即可（它顺手把 SIZE_MAP 也填了），不必再单独 stat 一遍。
    load_meta "$d"
    # 前 4 字节（魔数）：一次 head 读出整目录（每文件 4 字节）+ 一次 od 转十六进制，
    # 纯 shell 按 8 个字符一段切开 —— 以前是每个文件起 head+od+tr 三个进程
    _MFILES=""; _MCOUNT=0; _MSHORT=0
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      _MFILES="$_MFILES $f"
      _MCOUNT=$((_MCOUNT + 1))
      _msz=$(size_of "$f")
      isnum "$msz" && [ "$msz" -lt 4 ] && _MSHORT=1
    done
    _MRAW=""
    if [ "$_MCOUNT" -gt 0 ] && [ "$_MSHORT" = 0 ]; then
      _MRAW=$(head -q -c 4 $_MFILES 2>/dev/null | od -An -tx1 -v 2>/dev/null | tr -d ' \n')
      [ "${#_MRAW}" = "$((_MCOUNT * 8))" ] || _MRAW=""
    fi
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      b=${f##*/}
      if want_tags "$b"; then
        tags=$(sfnt_tags "$f")
      else
        tags="-"
      fi
      if [ -n "$_MRAW" ]; then
        _m8=${_MRAW%"${_MRAW#????????}"}
        _MRAW=${_MRAW#????????}
      else
        _m8=$(magic4 "$f")
      fi
      printf '%s\t%s\t%s\n' "$f" "${_m8:--}" "$tags"
      n=$((n + 1))
      [ $((n % 25)) -eq 0 ] && breathe "表信息 $n/$ftotal" "$n" "$ftotal"
    done
  done
  echo "@@SECTION:PROCS"
  # 当前和本模块相关的进程（让"有没有偷偷跑东西"一目了然）
  ps -A -o pid,ppid,args 2>/dev/null | grep -E 'diag\.sh|fontctl\.sh|update\.sh|custom_font' | grep -v grep | head -n 20
  # ★ 2026-10-14 修**测量 bug**：原来 timing_add 'PZ1 TTC头信息' 写在这里，
  #   而 TTC 那段在它**后面**（下一个 subnote 之后）—— 所以 PZ1 记的是
  #   「FONT_META 表信息 + PROCS」的耗时，**TTC 头信息压根没被测到**。
  #   真机报告里"PZ1 TTC头信息 223 秒"其实是表信息那一段，找错方向会白费功夫。
  #   现在把这条改名为它真正测的东西，TTC 那段另起一条 PZ1b。
  timing_add 'PZ0 表信息(魔数+sfnt标签)' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "TTC 合集头信息"
  echo "@@SECTION:TTCHEAD"
  for d in $FONTDIRS; do
    for f in "$d"/*.ttc; do
      [ -f "$f" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$f" "$(ttc_tag "$f")" "$(ttc_faces "$f")" "$(size_of "$f")"
    done
  done
  timing_add 'PZ1b TTC头信息' "$_PZ_T"; _PZ_T=$(now_s)
  timing_add 'PZ2 配置原文' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "导出字体配置原文"
  echo "@@SECTION:XMLCONTENT"
  for x in $XMLFOUND; do
    echo "@@FILE:BEGIN $x"
    cat "$x" 2>/dev/null
    echo
    echo "@@FILE:END"
  done
  timing_add 'PZ3 family' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "导出配置里的 family"
  echo "@@SECTION:XMLFAMILY"
  for x in $XMLFOUND; do
    xmlfam "$x" | while IFS= read -r L; do
      case "$L" in
        '<family'*)
          FAM=$(printf '%s' "$L" | sed 's/>.*//; s/^<family *//')
          ;;
        '<font'*)
          FATT=$(printf '%s' "$L" | sed 's/>.*//; s/^<font *//')
          FNAME=$(printf '%s' "$L" | sed 's/.*>//' | tr -d '\r' | sed 's/^ *//; s/ *$//')
          [ -n "$FNAME" ] && printf '%s\t%s\t%s\n' "$FNAME" "$FAM" "$FATT"
          ;;
      esac
    done
  done
  timing_add 'PZ4 目录清单' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "导出字体目录清单"
  echo "@@SECTION:DIRLIST"
  for d in $FONTDIRS; do
    echo "--- $d"
    ls -l "$d" 2>/dev/null
  done
  timing_add 'PZ5 模块快照' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "导出模块目录快照"
  echo "@@SECTION:MODULEDIR"
  ls -la "$M" 2>/dev/null
  echo "--- module.prop"
  cat "$M/module.prop" 2>/dev/null
  echo "--- settings.conf"
  cat "$SETTINGS" 2>/dev/null
  echo "--- pending/active"
  echo "pending=$PEND"
  echo "active=$ACT"
  echo "@@SECTION:MODULEUPDATE"
  ls -la /data/adb/modules_update/ 2>/dev/null
  echo "--- 本模块在 modules_update 里的内容"
  ls -la "$UPD" 2>/dev/null | head -n 30
  timing_add 'PZ6 挂载表' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "导出挂载表"
  echo "@@SECTION:MOUNTS"
  "$MO" 2>/dev/null | head -n 80
  timing_add 'PZ7 库指纹' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "导出字体库指纹"
  echo "@@SECTION:LIBFONTS"
  ls -l "$LIB" 2>/dev/null
  for f in $LIB_FONTS; do
    # 字体库文件也在闪存上：轻量模式同样只读前 1 MB（自己的字体常有几十 MB，全读太伤盘）
    # 1.0.9.2：字体库文件走同一个稀疏指纹口径（和字体目录保持一致，便于互相比对），
    # 用于判断“库里这个文件有没有被动过”；不再需要轻量分支。
    printf '%s  %s  %s\n' "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" "$(stat -c %s "$f" 2>/dev/null)" "$f"
  done
  for f in $LIB_FONTS; do
    i=${f##*/}; i=${i%.ttf}
    echo "--- $i  name=$(cat "$LIB/$i.name" 2>/dev/null | tr -d '\r\n')"
    cat "$LIB/$i.meta" 2>/dev/null
  done
  timing_add 'PZ8 data fonts' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "导出 /data/fonts"
  echo "@@SECTION:DATAFONTS"
  ls -lR /data/fonts 2>/dev/null | head -n 60
  [ -f /data/fonts/config/config.xml ] && cat /data/fonts/config/config.xml 2>/dev/null
  timing_add 'PZ9 主题字体' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "导出主题字体"
  echo "@@SECTION:MIUIFONT"
  echo "# 目录: $MIUI_DIRS"
  echo "# 与系统同名(会被接管): $MIUI_SHADOW"
  printf '%s\n' "$MIUI_FONTLIST"
  for td in $MIUI_DIRS; do
    echo "--- $td"
    ls -lZ "$td" 2>/dev/null | head -n 30
  done
  timing_add 'PZ10 个性化' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "导出个性化字体"
  echo "@@SECTION:PERSONALFONT"
  echo "# 厂商个性化字体（/data 上的固定路径，优先级高于 /system/fonts）"
  echo "# 时钟字体专项："
printf '%s\n' "  时钟类字体：${CLOCK_FONTS:-（无）}"
printf '%s\n' "  APK 内字体：${CLOCK_APK:-（无）}"
printf '%s\n' "  相关设置：${CLOCK_SET:-（无）}"
printf '%s\n' "  相关包：${CLOCK_PKG:-（无）}"
echo "# 自动发现的新目录（$DISC_NEW_DIRS 个）："
printf '%s\n' "${DISCOVERED:-（无）}"
echo "# 设备上有、targets 没有的字体名：${DISC_NEW_NAMES:-（无）}"
echo "# 厂商/主题字体目录（未覆盖 $VDIR_UNCOVERED 个）："
printf '%s\n' "${VDIR_REPORT:-（无）}"
echo "# ColorOS 桥接目录: ${OPS_BRIDGE:-无} 条目=$OPS_ENTRIES 普通文件=$OPS_FILES 链接=$OPS_LINKS"
[ -n "${OPS_DETAIL:-}" ] && printf '%s\n' "$OPS_DETAIL"
echo "# 检测到的: ${DATAFONT_LIST:-无}"
  if [ "$DATAFONT_N" -gt 0 ]; then
    printf '%s\n' $DATAFONT_LIST | while IFS= read -r L; do
      [ -n "$L" ] || continue
      echo "$L"
      echo "  size=$(stat -c %s "$L" 2>/dev/null)  mtime=$(mstamp "$L")  magic=$(magic4 "$L")"
      echo "  tags=$(sfnt_tags "$L")"
      echo "  sha256=$(sha256sum "$L" 2>/dev/null | cut -d' ' -f1)"
    done
  fi
  echo "## slots.map 里有没有它（有 = 会被模块一起替换）"
  grep -F 'customizecenter' "$M/slots.map" 2>/dev/null || echo "（没有）"
  echo "@@SECTION:SETTINGSFONT"
  ensure_settings_font
  printf '%s\n' "$S_FONT"
  echo "@@SECTION:PACKAGES"
  ensure_pkgs
  printf '%s\n' "$PKG_FONT"
  timing_add 'PZ11 槽位计划' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "导出槽位计划"
  echo "@@SECTION:SLOTS"
  echo "## slots.applied"
  printf '%s\n' "$APPLIED_LIST"
  echo "## slots.map"
  cat "$M/slots.map" 2>/dev/null
  echo "## PLAN_NOW（当前设置）"
  printf '%s\n' "$PLAN_NOW"
  echo "## PLAN_MAX（关闭所有保留）"
  printf '%s\n' "$PLAN_MAX"
  timing_add 'PZ12 收尾' "$_PZ_T"; _PZ_T=$(now_s)
  subnote "收尾"
  echo "@@SECTION:END"
}

# ---------------------------------------------------------------------------



# ---------------------------------------------------------------------------
sec12() {
  echo
  echo "【12】字体结构 / 合成字体（排查方框、同族用）"
  hr
  mget() {
    sed -n "s/^$2=//p" "$LIB/$1.meta" 2>/dev/null | tail -n 1 | tr -d '\r'
  }
  mname() {
    n_=$(cat "$LIB/$1.name" 2>/dev/null | tr -d '\r\n')
    [ -n "$n_" ] || n_="$1"
    printf '%s' "$n_"
  }

  echo "  ---- 字体库总览 ----"
  echo "  id      名称                     体积KB   轮廓   字形数   合成"
  echo "  ------  -----------------------  -------  -----  -------  ----"
  cnt=0
  for f in "$LIB"/f*.ttf; do
    [ -e "$f" ] || continue
    cnt=$((cnt + 1))
    fid=${f##*/}
    fid=${fid%.ttf}
    fkb=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    [ -n "$fkb" ] || fkb=0
    fkb=$((fkb / 1024))
    fol=$(mget "$fid" outline); [ -n "$fol" ] || fol="?"
    fng=$(mget "$fid" glyphs);  [ -n "$fng" ] || fng="?"
    fmg=$(mget "$fid" merge);   [ -n "$fmg" ] || fmg="-"
    fname=$(mname "$fid")
    printf '  %-6s  %-23s  %7s  %-5s  %-7s  %s\n' \
      "$fid" "$(printf '%s' "$fname" | cut -c1-23)" "$fkb" "$fol" "$fng" "$fmg"
  done
  [ "$cnt" = 0 ] && echo "      （字体库为空）"

  echo
  echo "  ---- 合成字体明细 ----"
  found=0
  for f in "$LIB"/f*.ttf; do
    [ -e "$f" ] || continue
    sid=${f##*/}
    sid=${sid%.ttf}
    smg=$(mget "$sid" merge)
    [ "$smg" = 1 ] || continue
    found=$((found + 1))
    sname=$(mname "$sid")
    echo "    $sid  $sname"
    echo "        基座      : $(mget "$sid" base)"
    echo "        分区素材  : $(mget "$sid" zones)"
    echo "        内部族名  : $(mget "$sid" family)"
    echo "        说明：族的判据是字体内部 name 表，合成字体应带「合成」后缀"
    echo "        轮廓/字形 : $(mget "$sid" outline) / $(mget "$sid" glyphs)"
    echo "        危险表    : hdmx=$(mget "$sid" t_hdmx) LTSH=$(mget "$sid" t_ltsh) VDMX=$(mget "$sid" t_vdmx) gvar=$(mget "$sid" t_gvar)"
    echo "        说明：hdmx/LTSH/VDMX 必须为 0（按字形索引，合并后没扩展会越界）"
  done
  [ "$found" = 0 ] && echo "      （没有合成字体）"

  echo
  echo "  ---- 当前生效字体 ----"
  aid=$(cur_active 2>/dev/null | tr -d '\r\n')
  if [ -z "$aid" ] || [ "$aid" = "none" ]; then
    echo "      当前无字体（系统默认）"
  else
    aname=$(mname "$aid")
    echo "      生效 id   : $aid  $aname"
    echo "      轮廓/字形 : $(mget "$aid" outline) / $(mget "$aid" glyphs)"
    echo "      内部族名  : $(mget "$aid" family)"
    echo "      覆盖      : 中文汉字=$(mget "$aid" rate_hanzi)%  拉丁=$(mget "$aid" rate_latin)%"
  fi

  echo
  echo "  ---- 字体结构清单（.fdata，导入/合成时自动生成）----"
  if [ -n "$aid" ] && [ "$aid" != "none" ] && [ -f "$LIB/$aid.fdata" ]; then
    echo "      当前生效 $aid 的完整结构："
    sed 's/^/        /' "$LIB/$aid.fdata" 2>/dev/null | head -n 32
  else
    echo "      （当前字体没有 .fdata：1.4.5 之前导入的字体没有这份记录）"
  fi

  echo
  echo "  ---- 库内字体结构摘要（横向对比谁缺东西）----"
  for f in "$LIB"/f*.ttf; do
    [ -e "$f" ] || continue
    qid=${f##*/}
    qid=${qid%.ttf}
    qname=$(mname "$qid")
    if [ -f "$LIB/$qid.fdata" ]; then
      qol=$(sed -n 's/^outline=//p' "$LIB/$qid.fdata" | head -n 1)
      qng=$(sed -n 's/^numGlyphs=//p' "$LIB/$qid.fdata" | head -n 1)
      qly=$(sed -n 's/^layout=//p' "$LIB/$qid.fdata" | head -n 1)
      qvr=$(sed -n 's/^variable=//p' "$LIB/$qid.fdata" | head -n 1)
      qcm=$(sed -n 's/^cmap_subtables=//p' "$LIB/$qid.fdata" | head -n 1)
      echo "      $qid $qname"
      echo "          轮廓=$qol 字形=$qng 可变=[$qvr] 排版=[$qly]"
      echo "          cmap: $qcm"
    else
      echo "      $qid $qname （无 .fdata）"
    fi
  done
  hr
  echo "  说明：本节只读 .meta / .fdata 小文件，不读字体本体、不解析 cmap，几乎不耗时。"
}


sec13() {
  echo
  echo "【13】TTC/OTC 合集与产物校验（排查三星类闪退）"
  hr
  echo "  ---- 系统里的合集文件 ----"
  _n=0
  for _d in /system/fonts /product/fonts /system_ext/fonts /my_product/fonts \
            /my_stock/fonts /vendor/fonts /odm/fonts; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/*.ttc "$_d"/*.otc; do
      [ -e "$_f" ] || continue
      _n=$(( _n + 1 ))
      _sz=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
      _nf=$(od -An -tu1 -j 8 -N 4 "$_f" 2>/dev/null | awk 'NF>=4{printf "%.0f",(($1*256+$2)*256+$3)*256+$4}')
      echo "    $_f  ${_sz}字节  faces=${_nf:-?}"
    done
  done
  [ "$_n" = 0 ] && echo "    （没有合集文件）"

  echo "  ---- 我们生成的合集产物 ----"
  _m=0
  for _f in "$LIB"/*.ttc[0-9]*; do
    [ -e "$_f" ] || continue
    _m=$(( _m + 1 ))
    _sz=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
    _nf=$(od -An -tu1 -j 8 -N 4 "$_f" 2>/dev/null | awk 'NF>=4{printf "%.0f",(($1*256+$2)*256+$3)*256+$4}')
    if command -v ttc_verify >/dev/null 2>&1; then
      _vv=$(ttc_verify "$_f" "" 2>&1) && _ok=通过 || _ok="不合格：$_vv"
    else
      _ok="（没有校验函数）"
    fi
    echo "    ${_f##*/}  ${_sz}字节  faces=${_nf:-?}  结构校验=${_ok}"
  done
  [ "$_m" = 0 ] && echo "    （本机没有生成过合集产物）"

  echo "  ---- ttc.log 最近记录 ----"
  if [ -s "$LIB/ttc.log" ]; then
    tail -n 12 "$LIB/ttc.log" 2>/dev/null | sed 's/^/    /'
  else
    echo "    （没有 ttc.log）"
  fi
  hr
  echo "  说明：三星的系统字体多为合集（一个文件装多字重）。若产物 faces 数与原厂不一致，"
  echo "        或结构校验不合格，应用按 face 取字形时就会崩溃 —— 模块会跳过该槽位保留原厂。"
}

sec14() {
  echo
  echo "【14】中文字形覆盖率与跳过原因（排查方块）"
  hr
  _sel=$(tr -d '[:space:]' < "$LIB/last_selection" 2>/dev/null)
  echo "  当前选择：${_sel:-none}"
  if [ -n "$_sel" ] && [ -f "$LIB/$_sel.meta" ]; then
    for _k in rate_latin rate_cjk rate_hant rate_kana rate_hangul rate_punct rate_symbols; do
      _v=$(sed -n "s/^$_k=//p" "$LIB/$_sel.meta" 2>/dev/null | tail -n1 | tr -d '\r')
      printf '    %-14s %s\n' "$_k" "${_v:-未记录}"
    done
    _cjk=$(sed -n 's/^rate_cjk=//p' "$LIB/$_sel.meta" 2>/dev/null | tail -n1 | tr -d '\r')
    case "$_cjk" in
      ''|*[!0-9]*) echo "    门槛判断：无覆盖率数据，按旧逻辑（cjk 标记）" ;;
      *) if [ "$_cjk" -lt 98 ]; then
           echo "    门槛判断：★ 覆盖率 ${_cjk}% < 98% → 中文槽位保持原厂（避免方块）"
         else
           echo "    门槛判断：覆盖率 ${_cjk}% ≥ 98% → 中文槽位正常替换"
         fi ;;
    esac
  else
    echo "    （没有当前字体的档案）"
  fi

  echo "  ---- 计划里的槽位统计 ----"
  _plan="$LIB/.plan.latest"
  if [ -s "$_plan" ]; then
    _tot=$(grep -c . "$_plan" 2>/dev/null)
    _cjk=$(awk '$1=="cjk"' "$_plan" 2>/dev/null | grep -c .)
    echo "    计划槽位总数 $_tot（其中中文类 $_cjk）"
  else
    echo "    （没有留存的计划文件）"
  fi
  if [ -s "$LIB/scanned/skip.list" ]; then
    echo "    跳过清单条数：$(grep -c . "$LIB/scanned/skip.list" 2>/dev/null)"
  fi
  hr
  echo "  说明：方块 = 被替换的字体里缺这些字。覆盖率不足 98% 时模块不再替换中文槽位，"
  echo "        所以「换了但某处仍显示原字体」是保护生效，不是失败。"
}

sec15() {
  echo
  echo "【15】崩溃日志摘要（字体相关，排查闪退）"
  hr
  _lg=""
  if command -v logcat >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      _lg=$(timeout 12 logcat -b crash -d 2>/dev/null | grep -i -E 'font|typeface|ttc|otf' | tail -n 12)
    else
      _lg=$(logcat -b crash -d 2>/dev/null | head -n 400 | grep -i -E 'font|typeface|ttc|otf' | tail -n 12)
    fi
  fi
  if [ -n "$_lg" ]; then
    printf '%s\n' "$_lg" | sed 's/^/    /'
  else
    echo "    （崩溃缓存里没有字体相关记录；也可能是刚重启过、缓存已清）"
  fi
  hr
  echo "  说明：若某应用「打开就闪退」而别的应用正常，多半是它读的某个字体文件结构有问题。"
  echo "        把这份报告发给作者，配合【13】的合集校验结果即可定位。"
  echo
}


sec16() {
    SMAP=$(slots_map_path)
  echo
  echo "【16】字重组应用情况（哪个槽位用了组里哪一档）"
  hr
  local sel grp members id w src tgt wtg
  sel=$(tr -d '[:space:]' < "$LIB/last_selection" 2>/dev/null)
  [ -n "$sel" ] || sel=$(tr -d '[:space:]' < "$LIB/active_font" 2>/dev/null)
  echo "  当前选择：${sel:-none}"

  grp=""
  if [ -n "$sel" ] && [ -f "$LIB/$sel.meta" ]; then
    grp=$(sed -n 's/^group=//p' "$LIB/$sel.meta" 2>/dev/null | tail -n1 | tr -d '\r')
  fi

  if [ -z "$grp" ]; then
    echo "  这个字体没有加入字重组（单独一份字体，字重只由它自己决定）。"
  else
    echo "  所属字重组：组长 $grp"
    echo "  ---- 组内成员 ----"
    members=0
    for id in $(lib_font_ids 2>/dev/null); do
      [ -n "$id" ] || continue
      [ -f "$LIB/$id.meta" ] || continue
      [ "$(sed -n 's/^group=//p' "$LIB/$id.meta" 2>/dev/null | tail -n1 | tr -d '\r')" = "$grp" ] || continue
      members=$((members + 1))
      w=$(sed -n 's/^wght=//p' "$LIB/$id.meta" 2>/dev/null | tail -n1 | tr -d '\r')
      printf '    %-16s 字重 %-5s %s\n' "$id" "${w:-?}" \
        "$([ "$id" = "$grp" ] && echo '← 组长' || echo '')"
    done
    [ "$members" -gt 0 ] || echo "    （没找到组内成员档案）"
  fi

  echo "  ---- 槽位 → 实际使用的文件 ----"
  if [ -s "$SMAP" ]; then
    # slots.map 每行： <选择的id> <目标槽位> <源文件>
    awk '{
      src = $3; sub(/^.*\//, "", src); sub(/\.ttf$/, "", src);
      print $2 "\t" src;
    }' "$SMAP" 2>/dev/null | sort | \
    awk -F'\t' '
      { cnt[$2]++; if (!(($1) in seen)) { seen[$1] = 1; sample[$2] = sample[$2] "\n      " $1 } }
      END {
        for (k in cnt) printf "    %-18s → %d 个槽位%s\n", k, cnt[k], sample[k];
      }' 2>/dev/null
    echo "    （按来源统计；每个来源下面缩进的是它覆盖的槽位示例）"
    echo "  ---- 中文字重相关槽位明细（前 12 条）----"
    grep -iE 'cjk|han|sc|tc|jp|kr|Sans' "$SMAP" 2>/dev/null | \
      awk '{ k = $2 "\t" $3; if (!(k in seen)) { seen[k] = 1; print } }' | head -n 12 | \
      while IFS= read -r _l; do
        _t=$(printf '%s' "$_l" | awk '{print $2}')
        _s=$(printf '%s' "$_l" | awk '{print $3}' | sed 's#.*/##;s#\.ttf$##')
        _w=$(sed -n 's/^wght=//p' "$LIB/$_s.meta" 2>/dev/null | tail -n1 | tr -d '\r')
        printf '    %-52s → %-16s 字重 %s\n' "${_t##*/}" "$_s" "${_w:-?}"
      done
  else
    echo "    （没有 slots.map：本机可能还没应用过字体，或挂载记录被清掉了）"
  fi

  echo "  ---- 被跳过的槽位（合集/结构校验）----"
  if [ -s "$LIB/ttc.log" ]; then
    grep -E 'ttcbad|跳过' "$LIB/ttc.log" 2>/dev/null | tail -n 8 | sed 's/^/    /'
  else
    echo "    （没有跳过记录）"
  fi
  hr
  echo "  说明：如果某个槽位本该吃 Bold 却显示用了常规字重，或整段没有中文槽位，"
  echo "        就是这里的映射问题；把这份报告发给作者即可定位。"
  echo
}


sec17() {
  echo
  echo "【17】模块账本快照（.index）—— 模块自己认为的状态"
  hr
  if [ -s "$LIB/.index" ]; then
    sed -n '1,60p' "$LIB/.index" 2>/dev/null | sed 's/^/  /'
    _ln=$(wc -l < "$LIB/.index" 2>/dev/null | tr -d ' ')
    case "${_ln:-0}" in ''|*[!0-9]*) _ln=0 ;; esac
    [ "$_ln" -gt 60 ] && echo "  …（共 $_ln 行，其余略）"
  else
    echo "  （没有 .index：还没建立过索引，或已被清理）"
  fi
  hr
  echo "  说明：这一节是模块**自己记录的**结果；若与下面几节的实测不一致，"
  echo "        说明索引过期或有外部改动 —— 把报告发作者，按这个对照即可定位。"
  echo
}

sec18() {
    SMAP=$(slots_map_path)
  echo
  echo "【18】每个槽位的决策记录（换成了什么 / 为什么没换）"
  hr
  if [ -s "$SMAP" ]; then
    echo "  ---- 槽位 → 源文件（前 20 条）----"
    awk 'NR <= 20 {
      src = $3; sub(/^.*\//, "", src);
      printf "    %-46s ← %s\n", $2, (src == "" ? "（同 id.ttf）" : src);
    }' "$SMAP" 2>/dev/null
    _n=$(grep -c . "$SMAP" 2>/dev/null)
    echo "  （共 ${_n:-0} 条）"
    echo
    echo "  ---- 按源文件汇总 ----"
    awk '{
      s = $3; if (s == "") s = $1;
      sub(/^.*\//, "", s);
      c[s]++;
    } END { for (k in c) printf "    %-24s %d 个槽位\n", k, c[k]; }' "$SMAP" 2>/dev/null
  else
    echo "  （没有 slots.map：还没应用过字体，或记录被清掉了）"
  fi

  echo
  echo "  ---- 未替换 / 跳过记录 ----"
  if [ -s "$LIB/ttc.log" ]; then
    echo "  合集相关（最近 8 条）："
    grep -E 'via=|跳过' "$LIB/ttc.log" 2>/dev/null | tail -n 8 | sed 's/^/    /'
  fi
  if [ -s "$LIB/mount.log" ]; then
    echo "  挂载相关（最近 8 条）："
    grep -E '失败|跳过|异常' "$LIB/mount.log" 2>/dev/null | tail -n 8 | sed 's/^/    /'
  fi
  [ -s "$LIB/ttc.log" ] || [ -s "$LIB/mount.log" ] || echo "    （没有跳过/失败记录）"

  echo
  echo "  ---- 门牌号核对（前 12 个槽位：目标 inode 是否等于源文件）----"
  if [ -s "$SMAP" ]; then
    awk 'NR <= 12 { print $2 "\t" $3 }' "$SMAP" 2>/dev/null | \
    while IFS="$(printf '\t')" read -r _rel _src; do
      [ -n "$_rel" ] || continue
      [ -n "$_src" ] || _src=""
      _dst="/$_rel"
      [ -e "$_dst" ] || { printf '    %-46s ← 目标不存在\n' "$_rel"; continue; }
      [ -n "$_src" ] && [ -e "$_src" ] || { printf '    %-46s ← 源文件缺失\n' "$_rel"; continue; }
      _a=$(stat -L -c '%d:%i' "$_src" 2>/dev/null)
      _b=$(stat -L -c '%d:%i' "$_dst" 2>/dev/null)
      if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then
        printf '    %-46s ✓ 是模块字体（inode 一致 %s）\n' "$_rel" "$_a"
      else
        printf '    %-46s ✗ 不是（目标 %s / 源 %s）\n' "$_rel" "${_b:-?}" "${_a:-?}"
      fi
    done
    echo "    （这项与上面的指纹结论应当一致；不一致说明有外部改动或挂载异常）"
  else
    echo "    （没有 slots.map，跳过）"
  fi
  hr
  echo "  说明：若某个槽位本该替换却出现在\"跳过\"里，原因就在上面这些行里。"
  echo
}


# 毫秒级计时（date +%s 只有 1 秒精度，很多节都显示 0s，看不出真正的耗时）
now_ms() {
  local _v _i _f
  # ① 纳秒时钟（最可靠；Android 的 toybox date 支持）
  _v=$(date +%s%N 2>/dev/null)
  case "$_v" in
    *[!0-9]*) _v="" ;;
  esac
  if [ -n "$_v" ] && [ ${#_v} -ge 16 ]; then
    printf '%s' "$(( _v / 1000000 ))"
    return 0
  fi
  # ② /proc/uptime（有些环境里是假文件，恒为一个常数 —— 所以放第二）
  _v=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
  case "$_v" in
    ''|*[!0-9.]*|*.*.*) _v="" ;;
  esac
  if [ -n "$_v" ]; then
    case "$_v" in
      *.*)
        _i=${_v%%.*}
        _f=${_v#*.}
        _f=$(printf '%-3s' "$_f" | tr ' ' '0' | cut -c1-3)
        ;;
      *) _i=$_v; _f=000 ;;
    esac
    case "$_i" in ''|*[!0-9]*) _i=0 ;; esac
    printf '%s' "$(( _i * 1000 + 10#$_f ))"
    return 0
  fi
  # ③ 最差情况：秒级
  _v=$(date +%s 2>/dev/null)
  case "$_v" in ''|*[!0-9]*) _v=0 ;; esac
  printf '%s' "$(( _v * 1000 ))"
}

# slots.map 的真实位置是**模块目录**（fontctl: mv -f "$stage.map" "$MODDIR/slots.map"）；
# 历史版本里可能残留在字体库目录，所以两个都看。
slots_map_path() {
  if [ -n "${MODDIR:-}" ] && [ -s "$MODDIR/slots.map" ]; then
    printf '%s' "$MODDIR/slots.map"
  elif [ -s "$LIB/slots.map" ]; then
    printf '%s' "$LIB/slots.map"
  else
    printf '%s' "$LIB/slots.map"
  fi
}

report_full() {
  echo "== 自定义字体切换模块 · 一键体检报告 =="
  echo "诊断脚本构建: ${DIAG_BUILD:-?}   节数: 0-18（含 12~18 为新增）"
  collect_once
  conclusion
  # ★ 逐节执行并记录耗时（用数据回答"报告慢在哪"，而不是靠猜）
  _secs="sec0 sec1 sec2 sec3 sec4 sec5 sec6 sec7 sec8 sec9 sec10 sec11 sec12 sec13 sec14 sec15 sec16 sec17 sec18"
  _perf=""
  for _fn in $_secs; do
    command -v "$_fn" >/dev/null 2>&1 || continue
    _t0=$(now_ms)
    "$_fn"
    _t1=$(now_ms)
    _ms=$((_t1 - _t0))
    [ "$_ms" -lt 0 ] && _ms=0
    if [ "$_ms" -lt 100 ]; then
      _perf="${_perf}  ${_fn}  <0.1s\n"
    else
      _perf="${_perf}  ${_fn}  $((_ms / 1000)).$(( (_ms % 1000) / 100 ))s\n"
    fi
  done
  echo
  echo "【耗时】各节用时"
  hr
  printf '%b' "$_perf"
  hr
  printf '%b' "$_perf" > "$LIB/.perf.log" 2>/dev/null
  echo "  字体指纹一节有缓存（.fp.cache）：同一台机器第二次生成会明显更快。"
  echo
  echo "【加速说明】门牌号快判（dev:inode 相同 ⇒ 就是模块挂上去的那份文件）"
  hr
  if [ "${FP_FAST:-0}" = 1 ]; then
    echo "  本次启用：用门牌号跳过 $FP_FAST_N 个文件的读盘计算"
    echo "  抽样核对：$FP_SAMPLE_OK 对一致（源文件与目标槽位 inode 相同）"
  else
    if [ "${FP_SAMPLE_BAD:-0}" -gt 0 ] 2>/dev/null; then
      echo "  ★ 抽样核对发现 $FP_SAMPLE_BAD 对不一致 → **本次未启用**门牌号快判（已退回逐文件计算）"
      echo "    这通常意味着挂载没生效、或有别的模块在替换同一批文件。"
    else
      echo "  本次未启用（没有可核对的槽位，或记录为空）—— 按逐文件计算处理"
    fi
  fi
  echo "  说明：这是**加速手段**，不影响任何结论；不一致时会自动退回慢速但可靠的路径。"

  echo
  echo "【数据可信度】指纹缓存自检（抽样重算比对）"
  hr
  fp_cache_verify
  echo
  echo "== 报告结束 =="
}

# 本次该写哪个文件名（1.0.9：只有完整报告一种，这个函数保留只为兼容旧调用点）
OUT_NOW=""
set_out_now() {
  # 1.0.9：只有一份报告（完整）。OUTFILE_FAST 现在是同一路径的别名。
  OUT_NOW="$OUTFILE_FULL"
}

# 把完整报告（结论 + 11 节 + 原始配置与哈希清单）写到 Download，成功时 SAVED=路径
# ★ 1.0.9：**只产出 1 个文件**（以前每次生成会冒出 3 个，作者反馈"很奇怪"）：
#   · /sdcard/Download/完整体检报告.txt   ← 唯一对外的那份
#   · 以前的 font_diag.txt 备用名、未完成的体检报告.txt、/data/local/tmp 那份，全部取消
#   生成过程中也直接覆盖这一个文件（内容是"已写好的部分"），所以不会再有"未完成"另开一份。
# ---------------------------------------------------------------------------
# 【报告完整性声明】（1.0.9.2 新增）
#
# 为什么需要它：作者担心"改来改去，最后检测少东西、分析不了"。这个担心完全合理 ——
#   为了把"半小时"压下来，我给几处加了时间上限/跳过了重活。但**如果报告不主动说明
#   "哪一节没做、为什么"，看报告的人（包括作者自己）就分不清"没问题"和"没检查"** ——
#   那才是最危险的（比慢得多危险）。
#
# 所以：任何一节被**超时、跳过、取不到**，都必须在这里记一笔，并写在报告最前面。
#   规则：宁可难看，不许静默。
# ---------------------------------------------------------------------------
DIAG_SKIPS=""
skip_note() {   # skip_note <小节名> <为什么> [怎么补回来]
  DIAG_SKIPS="$DIAG_SKIPS$1|$2|${3:-}
"
}
print_skip_notice() {
  [ -n "$DIAG_SKIPS" ] || return 0
  echo "  ⚠ 本次报告有 $(_skip_count) 处**没能完整采集**（下面逐一说明，不是"没问题"，是"没测到"）："
  printf '%s' "$DIAG_SKIPS" | while IFS='|' read -r _sn _why _how; do
    [ -n "$_sn" ] || continue
    echo "     · $_sn —— $_why"
    [ -n "$_how" ] && echo "       补回来：$_how"
  done
}
_skip_count() { printf '%s' "$DIAG_SKIPS" | grep -c . 2>/dev/null; }

write_kit() {
  local tmpf="$1"
  SAVED=""
  [ -s "$tmpf" ] || return 0
  mkdir -p "$DL" "$LIB" 2>/dev/null
  # 落盘顺序（只为"报告生成好了却一个文件都没有"兜底，但**不再产生第二个对外文件**）：
  #   ① 希望的位置（Download/完整体检报告.txt）
  #   ② 模块库目录（界面会把真实路径显示出来）
  # 注：$OUTFILE2（font_diag.txt）这个"备用名"已取消 —— 同内容存两份只会让人困惑。
  if cp -f "$tmpf" "$OUTFILE_FULL" 2>/dev/null; then
    chmod 666 "$OUTFILE_FULL" 2>/dev/null
    chown media_rw:media_rw "$OUTFILE_FULL" 2>/dev/null
    SAVED="$OUTFILE_FULL"
  fi
  cp -f "$tmpf" "$LIB/font_diag.txt" 2>/dev/null
  [ -n "$SAVED" ] || SAVED="$LIB/font_diag.txt"
  return 0
}

# 统一的进度状态写入（BG_* 由 build 设置）
# state_write <state> <phase> <sub> [额外行...]
# 一次写入两个文件：$LIB/.diag.state（脚本自己读）+ webroot 镜像（界面 fetch 直接读，不起进程）
# 数值字符串拼接后一次 redirect，除了 date 之外不多起进程
state_write() {
  # 「已中止」是终态：正在收尾的 build 不允许再用 running 把它盖掉
  # （不然中止后马上再看，状态会变回 running + 一个已经死掉的 pid，界面就误报"进程已退出"）
  if [ "$1" = "running" ] && [ -f "$LIB/.diag.cancel" ]; then return 0; fi
  _SW_T=$(date +%s 2>/dev/null)
  _SW_BODY="state=$1
phase=$2
pid=${BG_PID:-}
pgid=${BG_PGID:-0}
start=${BG_START:-0}
time=${_SW_T:-0}
fast=${BG_FAST:-0}
speed=${DIAG_SPEED:-gentle}
sub=${3:-}"
  shift 3
  for _l in "$@"; do
    _SW_BODY="$_SW_BODY
$_l"
  done
  mkdir -p "$LIB" 2>/dev/null
  printf '%s\n' "$_SW_BODY" > "$LIB/.diag.state" 2>/dev/null
  [ -d "$WEB" ] && printf '%s\n' "$_SW_BODY" > "$WEB_STATE" 2>/dev/null
  return 0
}

# 纯 shell 小工具（不起进程）
isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
now_s() { _NS_D=$(date +%s 2>/dev/null); isnum "$_NS_D" && printf '%s' "$_NS_D" || printf '0'; }

# ---------------------------------------------------------------------------
# 计时工具（★ 必须定义在 collect() 之前 —— collect 里要用；以前放在文件后段，
#   结果 `sh diag.sh perf` 的分段计时全是 0。2026-10-12 修。）
# ---------------------------------------------------------------------------
TIMING_LIST=""
timing_add() {   # timing_add <名称> <开始秒>
  local _n _d
  _n=$(now_s)
  _d=$(( _n - ${2:-$_n} ))
  [ "$_d" -lt 0 ] && _d=0
  TIMING_LIST="${TIMING_LIST}$1|${_d}s
"
  [ "${BG_STATE:-0}" = 1 ] && printf '%s|%s\n' "$1" "$_d" >> "$LIB/.diag.timing" 2>/dev/null
  return 0
}

# 给任意函数计时：pt <标签> <函数> [参数...]   —— 输出走 stdout# 为什么需要它：真机反馈"整份报告 30 分钟"，而「每一步耗时」只到 6 个大步 ——
#   第 1 步把整个 collect() 包住了（1371 秒），看不出是哪一段。
#   collect() 里几个可疑点（候选枚举、自适应扫描、XML 解析…）用这个一量就知道。
#   `sh diag.sh perf` 会把所有 P*/C* 行单独打出来。
pt() {
  _PT_L="$1"; shift
  _PT_T=$(now_s)
  "$@"
  _PT_R=$?
  timing_add "$_PT_L" "$_PT_T"
  return $_PT_R
}
# 同上，但**捕获输出**到 PT_OUT（给 `VAR=$(函数)` 那种调用用，避免污染报告正文）
ptv() {
  _PT_L="$1"; shift
  _PT_T=$(now_s)
  PT_OUT=$("$@" 2>/dev/null)
  timing_add "$_PT_L" "$_PT_T"
  return 0
}

# 进度百分比：各阶段"分量"不一样（第 6 步打包/哈希占大头），按权重算才诚实。
# 结果放全局 CP_P（不 echo、不起子 shell —— 这个函数每个阶段/每批文件都会调用）
_pct_weight_of() {   # 参数 = 阶段号，结果放 _PW
  case "$1" in
    1) _PW=7 ;;
    2) _PW=6 ;;
    3) _PW=7 ;;
    4) _PW=9 ;;
    5) _PW=9 ;;
    6) _PW=62 ;;
    *) _PW=0 ;;
  esac
}
CP_P=0
calc_pct() {
  _CP_S=${1:-0}; _CP_D=${3:-}; _CP_N=${4:-}
  isnum "$_CP_S" || _CP_S=0
  _CP_I=1; _CP_BASE=0
  while [ "$_CP_I" -lt "$_CP_S" ]; do
    _pct_weight_of "$_CP_I"
    _CP_BASE=$(( _CP_BASE + _PW ))
    _CP_I=$(( _CP_I + 1 ))
  done
  _pct_weight_of "$_CP_S"
  CP_P=$(( _CP_BASE + _PW / 2 ))          # 阶段刚开始：给这个阶段算一半
  if isnum "$_CP_D" && isnum "$_CP_N" && [ "$_CP_N" -gt 0 ]; then
    CP_P=$(( _CP_BASE + _PW * _CP_D / _CP_N ))
  fi
  [ "$CP_P" -lt 0 ] && CP_P=0
  [ "$CP_P" -gt 99 ] && CP_P=99
  return 0
}
# 预计剩余秒数：进度过了 8% 就用"已用时间 ÷ 已完成比例"推（最贴近真实），
# 太早期没有参考价值，就用静态预估（BG_ETA0）。结果放全局 CE_ETA
CE_ETA=0
calc_eta_pct() {
  isnum "${1:-}" || { CE_ETA=0; return 0; }
  _CE_EL=$(( $(now_s) - ${BG_START:-0} ))
  [ "$_CE_EL" -lt 0 ] && _CE_EL=0
  _CE_ETA=${BG_ETA0:-0}
  isnum "$_CE_ETA" || _CE_ETA=0
  _CE_ETA=$(( _CE_ETA - _CE_EL ))
  if [ "$1" -ge 8 ]; then
    _CE_ETA=$(( _CE_EL * (100 - $1) / $1 ))
  fi
  [ "$_CE_ETA" -lt 0 ] && _CE_ETA=0
  [ "$_CE_ETA" -gt 7200 ] && _CE_ETA=7200
  CE_ETA=$_CE_ETA
  return 0
}

# 时间到了：先把"已经写好的部分"存下来再退出 —— 绝不让用户白等一场
# （以前超时直接写成 error、什么都不留，这正是"跑不完也导不出东西"的原因）
ABORTED=0
abort_now() {   # abort_now <原因>
  ABORTED=1
  if [ "$BG_STATE" = 1 ] && [ -s "$LIB/font_diag.part" ]; then
    cp -f "$LIB/font_diag.part" "$LIB/font_diag.txt" 2>/dev/null
cp -f "$LIB/font_diag.part" "$OUTFILE_FULL" 2>/dev/null
chmod 666 "$OUTFILE_FULL" 2>/dev/null
chown media_rw:media_rw "$OUTFILE_FULL" 2>/dev/null
    SAVED=""
    write_kit "$LIB/font_diag.part"
    mirror_result
  fi
  state_write "partial" "已保存（未完成）" "" \
    "partial=1" "pct=100" "saved=${SAVED:-}" "msg=${1:-生成被中断，已保存已完成的部分}"
  exit 0
}

# 让路检查：取消 / 关机 / 超时。放在每个阶段和每个长循环里
# 取消标记是纯 shell 判断（很便宜，每次都查）；关机和超时要起进程，隔几次查一次就够灵敏
_CK_N=0
_ck() {
  [ -f "$LIB/.diag.cancel" ] && exit 0
  _CK_N=$(( _CK_N + 1 ))
  if [ $(( _CK_N % 15 )) -eq 1 ]; then
    if shutting_down; then
      state_write "cancelled" "已因关机停止" "" "msg=检测到正在关机/重启，任务已停下"
      exit 0
    fi
  fi
  if [ "$BG_STATE" = 1 ] && [ -n "${BG_START:-}" ] && [ $(( _CK_N % 5 )) -eq 1 ]; then
    # 上限给足（默认 45 分钟），超了也只保存已完成的部分，绝不丢成果
    if [ $(( $(now_s) - BG_START )) -gt ${BG_MAX_SEC:-2700} ]; then
      abort_now "生成时间超过 $(( ${BG_MAX_SEC:-2700} / 60 )) 分钟，已自动停止并保存已完成的部分"
    fi
  fi
  return 0
}

# 把"正在生成的内容"开头一段镜像进 webroot：界面 fetch 就能边生成边看，不用起 shell
mirror_part() {
  [ -d "$WEB" ] || return 0
  [ -s "$LIB/font_diag.part" ] || return 0
  head -c "$PART_MIRROR_BYTES" "$LIB/font_diag.part" 2>/dev/null > "$WEB_PART" 2>/dev/null
  return 0
}

# 生成完成后镜像"报告预览 + 体积信息"
mirror_result() {
  [ -d "$WEB" ] || mkdir -p "$WEB" 2>/dev/null
  [ -s "$LIB/font_diag.txt" ] || return 0
  head -c 60000 "$LIB/font_diag.txt" 2>/dev/null > "$WEB_HEAD" 2>/dev/null
  _MR_SZ=$(wc -c < "$LIB/font_diag.txt" 2>/dev/null | tr -d ' ')
  isnum "$_MR_SZ" || _MR_SZ=0
  _MR_LN=$(wc -l < "$LIB/font_diag.txt" 2>/dev/null | tr -d ' ')
  isnum "$_MR_LN" || _MR_LN=0
  { printf 'size=%s\nlines=%s\nsaved=%s\n' "$_MR_SZ" "$_MR_LN" "${SAVED:-}"; } > "$WEB_META" 2>/dev/null
  return 0
}

# 进度提示：既打印出来（安装界面 / 「操作」控制台可见），
# 在后台生成时（BG_STATE=1）还会写进状态文件，WebUI 就能显示"正在做哪一步、已用多少秒、还剩多少"
# 每一阶段都会检查取消 / 关机 / 超时：用户点了「中止生成」立刻停，绝不多跑
dphase() {
  _ck
  printf '  体检进度：%s\n' "$1"
  if [ "$BG_STATE" = 1 ]; then
    BG_PHASE="$1"
    _DP_S=${1%%/*}; isnum "$_DP_S" || _DP_S=0
    _DP_T=${1#*/}; _DP_T=${_DP_T%% *}; isnum "$_DP_T" || _DP_T=7
    BG_STEP=$_DP_S; BG_STEPS=$_DP_T
    calc_pct "$BG_STEP" "$BG_STEPS"
    calc_eta_pct "$CP_P"
    state_write running "$1" "" "step=$BG_STEP" "steps=$BG_STEPS" \
      "pct=$CP_P" "eta=$CE_ETA"
    mirror_part
    sleep 1        # 让出 CPU/IO，别把系统界面挤死
  fi
  return 0
}

# 长循环里定期"喘口气 + 刷新心跳"：既避免界面以为卡死，也不让 CPU 一直被占满
# breathe <子进度文字，如 "哈希 120/293"> [已完成数] [总数]
breathe() {
  [ "$BG_STATE" = 1 ] || return 0
  _ck
  _BR_D=${2:-}; _BR_T=${3:-}
  calc_pct "${BG_STEP:-0}" "${BG_STEPS:-7}" "$_BR_D" "$_BR_T"
  calc_eta_pct "$CP_P"
  state_write running "${BG_PHASE:-处理中}" "${1:-}" \
    "step=${BG_STEP:-0}" "steps=${BG_STEPS:-7}" \
    "pct=$CP_P" "done=$_BR_D" "total=$_BR_T" "eta=$CE_ETA"
  # ★ 1.0.9.2：原来这里 `sleep 1`（每 25 个文件睡一次）。
  #   作者机器上字体目录 293 个文件 → 至少 12 秒白等；而且 breathe 在别处也被叫。
  #   让路的目的已经由 lowprio_self 用 nice 达成了，这里不必用"睡"来实现。
  return 0
}

# 只更新"正在做什么"这一行（不睡，用在打包各小节开头：界面就不会看着停住）
subnote() {
  [ "$BG_STATE" = 1 ] || return 0
  _ck
  calc_pct "${BG_STEP:-0}" "${BG_STEPS:-7}"
  calc_eta_pct "$CP_P"
  state_write running "${BG_PHASE:-处理中}" "${1:-}" \
    "step=${BG_STEP:-0}" "steps=${BG_STEPS:-7}" \
    "pct=$CP_P" "eta=$CE_ETA"
  return 0
}

# 让路给系统（但要**有限度**）
#
# ★ 1.0.9.2 重要修正（真机实测）：
#   1.0.9 这里用的是 `ionice -c 3`（I/O **空闲类**）+ `renice 19`（最低 CPU 优先级）。
#   实测后果是灾难性的：作者机器上 `diag.sh perf` 跑采集只要 **32 秒**，
#   而**同一条采集**在正式报告流程里花了 **6 分多钟**（第 1 步），整份报告半小时以上。
#   原因：本脚本会起**几千个短命进程**（stat/grep/od/echo/sha256sum…），
#     · `ionice -c 3` = "只要有别人要用磁盘就让路" → 手机上系统一直在读写，我们几乎排不上队；
#     · `renice 19` = 最小 CPU 时间片 → 每个短命进程都要**排队等 CPU**，进程越多亏得越多。
#   两者叠加，在"屏幕开着、系统有后台活动"时能把整体拖慢十几倍。
#
#   现在改成**有节制的让路**：
#     · nice 10（中等偏低）—— 界面依然优先，但我们不会被饿死；
#     · 不再动 ionice（保持默认 best-effort）。
#   作者的原意是"别把系统挤死、别让手机觉得卡"，nice 10 完全够用；
#   而"报告要跑半小时"本身就是更严重的问题。
lowprio_self() {
  # ★ 1.0.9.2：速度由**命令行/环境变量**决定（界面在点"全速生成 / 慢慢生成"时传进来）：
  #     DIAG_SPEED=full   → 不降优先级，最快（CPU 满负荷，手机可能发热/变卡）
  #     DIAG_SPEED=gentle → 让路给系统（默认，慢一些但不打扰用手机）
  #   为什么不做成"设置里的开关"：那是全局状态，用户点报告时根本不会去设置里找；
  #   而且"全速/慢慢"只是一次性的选择，问一次就够了。
  if [ "${DIAG_SPEED:-gentle}" = full ]; then
    return 0        # 全速：什么都不改
  fi
  if command -v renice >/dev/null 2>&1; then
    renice 10 -p $$ >/dev/null 2>&1
  elif command -v nice >/dev/null 2>&1; then
    nice -n 10 -p $$ >/dev/null 2>&1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 分阶段计时：报告里会附带"每一步花了多少秒"
#   给用户看：知道卡在哪一步、还要多久；
#   给作者看：一眼看出哪一步是性能瓶颈（以前只能靠猜）
# ★ 定义已经**移到文件前段**（collect() 之前）—— 否则 collect 里调用时函数还不存在。
#   这里只留一句说明，不要再重复定义。
# ---------------------------------------------------------------------------

# 生成完整报告包（体检 + 原始配置 + 哈希清单）
# 流程优化：
#   1) 后台模式直接增量写到 $LIB/font_diag.part —— 界面可以边生成边看；
#   2) 每个阶段结束都把已完成的部分导出一次（Download/未完成的体检报告.txt），
#      所以就算中途被中止/超时/关机，也已经有一份能发出来的文件（不再"白跑一场"）；
#   3) 全局先降到最低优先级（不只后台模式），并且每个阶段都检查取消 / 关机 / 超时。
kit_report() {
  local tmpf
  lowprio_self
  tmpf=""
  if [ "$BG_STATE" = 1 ]; then
    tmpf="$LIB/font_diag.part"
  else
    # 前台模式先写临时文件，跑完再一次性搬走。
    # /data/local/tmp 在个别机器/容器里可能不存在或不可写 —— 建不出来就退回字体库目录，
    # 绝不因为一个目录不存在就让整份报告写不出来
    mkdir -p /data/local/tmp 2>/dev/null
    tmpf="/data/local/tmp/.font_diag.$$"
    : > "$tmpf" 2>/dev/null || tmpf=""
    if [ -z "$tmpf" ]; then
      mkdir -p "$LIB" 2>/dev/null
      tmpf="$LIB/.font_diag.$$"
    fi
  fi
  mkdir -p "$LIB" 2>/dev/null
  : > "$tmpf" 2>/dev/null
  if [ ! -w "$tmpf" ] 2>/dev/null; then
    tmpf="$LIB/.font_diag.$$"
    : > "$tmpf" 2>/dev/null
  fi
  TIMING_LIST=""
  _KR_T0=$(now_s)
  { echo "诊断脚本构建: ${DIAG_BUILD:-?}   小节: 0~18"; } >> "$tmpf" 2>&1
  [ "$BG_STATE" = 1 ] && : > "$LIB/.diag.timing" 2>/dev/null
  # ★ 1.0.9：阶段从 6 步改成 7 步，把"写报告文件"单独作为最后一步。
  #   以前"6/6 打包哈希清单"是最重的一步（要算全量指纹），而报告正文打印和写盘
  #   都发生在它之后 —— 界面停在 6/6 不动，看着就像"卡住了/还在偷偷干活"。
  #   现在：6/7 收集指纹 → 7/7 写文件，最后一步一到就是真的完了。
  _PH_T0=$(now_s)
  dphase '1/7 结论与门禁检查'
  # ★ 1.0.9.2：第 1 步内部再分段计时。
  #   真机实测（`diag.sh perf`）：collect_once 只要 32 秒，但第 1 步总耗时 1371 秒 ——
  #   也就是说 1339 秒花在下面这四件事上。不细分就只能继续猜。
  _S1_T0=$(now_s)
  collect_once
  timing_add 'S1 collect_once' "$_S1_T0"
  # ★ 1.0.9.2：collect 里的最后一个 subnote 会一直挂在界面「正在执行」那一行上，
  #   后面 conclusion/sec0/sec1 全程不动 —— 用户看到的就像"卡在谷歌字体兼容"（真机反馈过）。
  #   所以从 collect 出来立刻换标签，后面每一块也都换。
  subnote "采集完成，正在生成结论"
  # 静态预估：给界面一个"一开始就能显示的预计耗时"（很便宜：只数个数）
  _S1_T0=$(now_s)
  BG_ETA0=$(static_eta)
  isnum "$BG_ETA0" || BG_ETA0=0
  export BG_ETA0
  timing_add 'S2 static_eta' "$_S1_T0"
  _S1_T0=$(now_s); { conclusion; } >> "$tmpf" 2>&1; timing_add 'S3 conclusion 结论' "$_S1_T0"
  subnote "正在分析：这台系统靠什么生效"
  _S1_T0=$(now_s); { sec0; } >> "$tmpf" 2>&1;       timing_add 'S4 sec0 第0节' "$_S1_T0"
  subnote "正在整理：语言→字体 映射"
  _S1_T0=$(now_s); { sec_adapted; } >> "$tmpf" 2>&1;   timing_add 'S4b 第4节 语言映射' "$_S1_T0"
  subnote "正在比对：哪些字体没适配"
  _S1_T0=$(now_s); { sec_unadapted; } >> "$tmpf" 2>&1; timing_add 'S4c 第5节 没适配' "$_S1_T0"
  subnote "正在检查：门禁与关键文件"
  _S1_T0=$(now_s); { sec1; } >> "$tmpf" 2>&1;       timing_add 'S5 sec1 第1节' "$_S1_T0"
  timing_add '1 结论与门禁检查' "$_PH_T0"
  export_part "$tmpf"
  _PH_T0=$(now_s)
  dphase '2/7 开机痕迹与挂载实测'
  _TT=$(now_s); { sec2; } >> "$tmpf" 2>&1; timing_add 'Z sec2' "$_TT"
  _TT=$(now_s); { sec3; } >> "$tmpf" 2>&1; timing_add 'Z sec3' "$_TT"
  timing_add '2 开机痕迹与挂载实测' "$_PH_T0"
  export_part "$tmpf"
  _PH_T0=$(now_s)
  dphase '3/7 槽位与字体目录映射'
  _TT=$(now_s); { sec4; } >> "$tmpf" 2>&1; timing_add 'Z sec4' "$_TT"
  _TT=$(now_s); { sec5; } >> "$tmpf" 2>&1; timing_add 'Z sec5' "$_TT"
  timing_add '3 槽位与字体目录映射' "$_PH_T0"
  export_part "$tmpf"
  _PH_T0=$(now_s)
  dphase '4/7 字体配置与字体来源'
  _TT=$(now_s); { sec6; } >> "$tmpf" 2>&1; timing_add 'Z sec6' "$_TT"
  _TT=$(now_s); { sec7; } >> "$tmpf" 2>&1; timing_add 'Z sec7' "$_TT"
  timing_add '4 字体配置与字体来源' "$_PH_T0"
  export_part "$tmpf"
  _PH_T0=$(now_s)
  dphase '5/7 清单 / 冲突 / 日志 / App 可见性'
  _TT=$(now_s); { sec8; } >> "$tmpf" 2>&1; timing_add 'Z sec8' "$_TT"
  _TT=$(now_s); { sec9; } >> "$tmpf" 2>&1; timing_add 'Z sec9' "$_TT"
  _TT=$(now_s); { sec10; } >> "$tmpf" 2>&1; timing_add 'Z sec10' "$_TT"
  _TT=$(now_s); { sec11; } >> "$tmpf" 2>&1; timing_add 'Z sec11' "$_TT"
  timing_add '5 清单 / 冲突 / 日志 / App 可见性' "$_PH_T0"
  # ★ 2026-10-23（修正）：12~18 节以前只写在 report_full() 里，而界面实际用的是
  #   kit_report() —— 所以这几节从来没出现在报告里。现在接在这里。
  subnote "正在检查：字体结构 / 合集 / 覆盖率"
  _TT=$(now_s); { sec12; } >> "$tmpf" 2>&1; timing_add 'Y sec12 字体结构' "$_TT"
  _TT=$(now_s); { sec13; } >> "$tmpf" 2>&1; timing_add 'Y sec13 合集校验' "$_TT"
  _TT=$(now_s); { sec14; } >> "$tmpf" 2>&1; timing_add 'Y sec14 覆盖率' "$_TT"
  subnote "正在整理：崩溃摘要 / 字重组 / 账本 / 决策"
  _TT=$(now_s); { sec15; } >> "$tmpf" 2>&1; timing_add 'Y sec15 崩溃摘要' "$_TT"
  _TT=$(now_s); { sec16; } >> "$tmpf" 2>&1; timing_add 'Y sec16 字重组' "$_TT"
  _TT=$(now_s); { sec17; } >> "$tmpf" 2>&1; timing_add 'Y sec17 账本快照' "$_TT"
  _TT=$(now_s); { sec18; } >> "$tmpf" 2>&1; timing_add 'Y sec18 决策记录' "$_TT"
  export_part "$tmpf"
  _PH_T0=$(now_s)
  dphase '6/7 逐文件指纹（稀疏：大小+mtime+头尾 64KB，同一份只算一次）'
  pack_extra >> "$tmpf" 2>&1
  timing_add '6 打包原始配置与哈希清单' "$_PH_T0"
  {
    echo
    echo "@@SECTION:TIMING"
    echo "## 每一步耗时（秒）—— 慢在哪一步看这里（反馈问题时请连这一段一起发）"
    printf '%s' "$TIMING_LIST"
    echo "合计|$(( $(now_s) - ${_KR_T0:-$(now_s)} ))"
    echo
    echo "【数据可信度】指纹缓存自检（抽样重算比对）"
    fp_cache_verify 2>&1
    echo
    echo "【加速说明】门牌号快判（dev:inode 相同 ⇒ 就是模块挂上去的那份文件）"
    echo "  抽样扫描：读了 ${FP_SCAN:-0} 行 slots.map，取到 ${FP_SAMPLE_OK:-0} 对一致样本"
    if [ -n "${FP_SAMPLE_DETAIL:-}" ]; then
      printf '%s\n' "$FP_SAMPLE_DETAIL" | sed 's/^/    /'
    else
      echo "    （没有取到任何样本：slots.map 可能为空，或槽位文件/源文件不存在）"
    fi
    if [ "${FP_FAST:-0}" = 1 ]; then
      echo "  本次启用：用门牌号跳过 ${FP_FAST_N:-0} 个文件的读盘计算"
    elif [ "${FP_SAMPLE_BAD:-0}" -gt 0 ] 2>/dev/null; then
      echo "  ★ 抽样核对发现 ${FP_SAMPLE_BAD} 对不一致 → 本次未启用快判（已退回逐文件计算）"
    else
      echo "  本次未启用（没有可核对的槽位，或记录为空）—— 按逐文件计算处理"
    fi
  } >> "$tmpf" 2>&1
  printf '== 报告结束 ==\n' >> "$tmpf"
  _PH_T0=$(now_s)
  dphase '7/7 写入报告文件'
  write_kit "$tmpf"
  timing_add '7 写入报告文件' "$_PH_T0"
  mirror_result
  rm -f "$tmpf" 2>/dev/null
  return 0
}

# 阶段结束时的"增量导出"：让"未完成"的文件一直是可用的
# 只在后台模式下做（前台 save/install 由 write_kit 一次写完，不重复写盘）
export_part() {
  [ "$BG_STATE" = 1 ] || return 0
  [ -s "$1" ] || return 0
  # ★ 1.0.9.2：**不再每阶段整份复制报告到 Download**。
  #   原来这里是 `cp -f "$1" "$OUTFILE_FULL"` —— 7 个阶段就把整份报告
  #   （作者机器上 1.9MB）复制 7 遍，而最后 write_kit 本来就会写一份完整的。
  #   在"慢速存储 + I/O 让路"的情况下，这些多余复制本身就很可观。
  #   现在只更新界面用的预览镜像（60KB，很便宜），真正的落盘交给最后的 write_kit。
  mirror_part
  return 0
}

# 便宜的静态预估（秒）：只数文件个数，不读内容。给界面显示"预计耗时"用
static_eta() {
  _SE_A=0; _SE_R=0
  for d in $(uniq_fontdirs); do
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      _SE_A=$((_SE_A + 1))
    done
  done
  _SE_R=$(printf '%s\n' "$XMLNAMES" | grep -c . )
  isnum "$_SE_R" || _SE_R=0
  # 1.0.9：统一按“按需全量”估 —— 只有计划内/引用到的字体才全量读，其余只读 1MB，
  # 所以耗时不再随字体总数线性增长（这就是速度提升的来源）。
  printf '%s' $(( 30 + _SE_A * 30 / 100 ))
}

# 去重后的字体目录清单。
# 关键：FONTDIRS 里的多个路径经常指向同一份目录（符号链接 / 同一分区的不同挂载点），
# 于是"每个文件哈希一遍"的循环会把同一批文件重复算 N 遍 —— 这就是最后一步慢到超时的主因。
# 用 dev:inode 判定"真的是同一份"，只留第一个。
uniq_fontdirs() {
  _UF_SEEN=""
  for _uf_d in $FONTDIRS; do
    _UF_K=$(stat -L -c '%d:%i' "$_uf_d" 2>/dev/null)
    [ -n "$_UF_K" ] || _UF_K="path:$_uf_d"
    case "$_UF_SEEN" in
      *" $_UF_K "*) continue ;;
    esac
    _UF_SEEN="$_UF_SEEN $_UF_K "
    printf '%s\n' "$_uf_d"
  done
}

# 这个 pid 能不能安全 kill？不能是 0/1、不能是我自己、不能是我的祖先
# （祖先可能是调用方的 su / WebUI 包装进程，杀它 = 把发起方一起干掉）
_safe_to_kill() {
  _sk_p=${1:-}
  case "$_sk_p" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_sk_p" -gt 1 ] 2>/dev/null || return 1
  [ "$_sk_p" = "$$" ] && return 1
  _sk_i=0
  while [ "$_sk_p" -gt 1 ] 2>/dev/null && [ "$_sk_i" -lt 15 ]; do
    _sk_s=$(cat "/proc/$_sk_p/stat" 2>/dev/null)
    [ -n "$_sk_s" ] || return 1          # 进程已经没了：不用杀（/proc 里没有 = 不存在）
    _sk_s=${_sk_s##*\)}
    set -- $_sk_s
    _sk_p=${2:-}
    [ "$_sk_p" = "$$" ] && return 1      # 走到自己了 = 它是我的祖先
    _sk_i=$((_sk_i + 1))
  done
  return 0
}

# 干掉正在跑的 build。
# 要点：
#   1) build 会把自己的真实 pid/pgid 写进状态文件（父进程记的 $! 可能是 setsid 的 pid，不准）；
#   2) 先按进程组杀，这样 sha256sum 之类的子进程也一起清掉（只杀父进程它们会继续跑满 CPU）；
#   3) pid/pgid 来自"可写的普通文件"，必须先严格校验：pgid=0 会让 kill -9 -0 杀掉调用者
#      整个进程组，pgid=1 会杀光所有能杀的进程 —— 这种值一概不接受；
#   4) 绝不用 pkill -f 这种按命令行子串匹配的兜底（会误伤带同样字样的父级包装进程），
#      改成"逐个候选 pid 检查祖先链"。
kill_build() {
  local p pid pgid me mypg
  me=$$
  mypg=$(awk '{print $5}' "/proc/$$/stat" 2>/dev/null | tr -d '[:space:]')
  pid=$(sed -n 's/^pid=//p' "$LIB/.diag.state" 2>/dev/null | head -n1 | tr -d '[:space:]')
  pgid=$(sed -n 's/^pgid=//p' "$LIB/.diag.state" 2>/dev/null | head -n1 | tr -d '[:space:]')
  case "$pgid" in ''|*[!0-9]*) pgid="" ;; esac
  case "$pid"  in ''|*[!0-9]*) pid=""  ;; esac
  if [ -n "$pgid" ] && [ "$pgid" -gt 1 ] 2>/dev/null && [ "$pgid" != "$me" ] && [ "$pgid" != "$mypg" ]; then
    kill -9 "-$pgid" 2>/dev/null
  fi
  if [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$pid" != "$me" ]; then
    kill -9 "$pid" 2>/dev/null
  fi
  # 兜底：命令行里带 "diag.sh build" 的进程（逐个判祖先，避免误伤调用方）
  for p in $(ps -A -o pid,args 2>/dev/null | grep -F 'diag.sh build' | grep -v grep | awk '{print $1}'); do
    _safe_to_kill "$p" && kill -9 "$p" 2>/dev/null
  done
  sleep 1
  # 再清一遍：刚才那一瞬间可能又派生了子进程
  if [ -n "$pgid" ] && [ "$pgid" -gt 1 ] 2>/dev/null && [ "$pgid" != "$me" ] && [ "$pgid" != "$mypg" ]; then
    kill -9 "-$pgid" 2>/dev/null
  fi
  return 0
}

# 现在还有没有 build 在跑（"中止"后用它确认真的清干净了）
build_alive() {
  local p
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f 'diag.sh build' >/dev/null 2>&1 && return 0
  else
    for p in $(ps -A -o pid,args 2>/dev/null | grep -F 'diag.sh build' | grep -v grep | awk '{print $1}'); do
      [ -n "$p" ] && return 0
    done
  fi
  return 1
}

case "$MODE" in
  brief)
    collect_once
    conclusion
    ;;
  perf)
    # 【隐藏模式，给作者/维护者用】只跑采集并打印各段耗时，不生成报告、不写 Download。
    # 为什么需要它：真机反馈过"整份报告要半小时"，而报告末尾的「每一步耗时」
    # 只能看到 6 个大步（第 1 步把采集全包住了）。这个模式把 collect() 里的
    # C1~C7 分段耗时直接打出来 —— 在真机上 `sh diag.sh perf` 一条命令就能定位。
    echo "===== 分段耗时实测（不生成报告）====="
    _p0=$(now_s)
    collect_once
    _p1=$(now_s)
    echo "collect() 总计: $(( _p1 - _p0 )) 秒"
    echo
    echo "各段明细（C*=采集大段，P*=采集内部细节，按耗时从大到小）："
    if [ -n "$TIMING_LIST" ]; then
      printf '%s' "$TIMING_LIST" | sed '/^$/d' | sort -t'|' -k2 -rn | while IFS= read -r _l; do
        case "$_l" in C*|P*|S*|Y*|Z*) printf '  %-42s %s 秒\n' "${_l%%|*}" "${_l##*|}" ;; esac
      done
    else
      echo "  （没有分段记录）"
    fi
    echo
    echo "规模参考："
    echo "  候选槽位: $(slot_candidates "$M" 2>/dev/null | grep -c .) 个"
    echo "  语言映射: $(slot_scan_names 2>/dev/null | grep -c .) 条"
    echo "  字体目录: $(slot_dirs 2>/dev/null | tr '\n' ' ')"
    ;;
  bg)
    # 后台生成（立刻返回，WebUI 的 JS 不会被长命令卡住；生成期间窗口可随时关闭）
    # 本模式只做"读状态 + 启动"，绝不采集 —— 这是"点一下立刻有反应"的前提
    #   bg              已有正在跑的/刚生成好的，就直接复用（别重算）
    #   bg force        强制重新生成（先把正在跑的干掉）
    #   bg fast         轻量模式：只算必要字体的指纹，跳过 cmd font dump / dumpsys（不影响主要结论）
    #   （1.0.9 起不再有 fast：只有完整报告一种口径；传了 fast 也会被忽略）
    mkdir -p "$LIB" "$WEB" 2>/dev/null
    force=0; fast=0
    for a in "$2" "$3"; do
      [ "$a" = force ] && force=1
      [ "$a" = fast ] && fast=0   # 1.0.9：快速口径已删，忽略该参数
    done
    st=""; age=999999
    if [ -f "$LIB/.diag.state" ]; then
      st=$(sed -n 's/^state=//p' "$LIB/.diag.state" 2>/dev/null | head -n1 | tr -d '[:space:]')
      age=$(( $(now_s) - $(stat -c %Y "$LIB/.diag.state" 2>/dev/null || echo 0) ))
    fi
    if [ "$force" = 0 ]; then
      # 判断"是不是真的在跑"：看心跳新鲜度（状态文件里有 time=），不只看 pid。
      # 只看 pid 会误判：父进程写下的 pid 是第一秒的猜测（setsid 可能 fork），
      # 误判成"没在跑"就会再起一个 —— 变成两份同时写同一个报告（看起来像"跑了两遍/被重置"）。
      if [ "$st" = "running" ] && [ "$age" -lt 120 ] 2>/dev/null; then
        echo "OK:running"; exit 0        # 心跳很新 = 正在跑，直接接着看
      fi
      if [ "$st" = "running" ] && [ "$age" -lt 1200 ] 2>/dev/null; then
        rpid=$(sed -n 's/^pid=//p' "$LIB/.diag.state" 2>/dev/null | head -n1 | tr -d '[:space:]')
        if [ -z "$rpid" ] || kill -0 "$rpid" 2>/dev/null; then
          echo "OK:running"; exit 0
        fi
        # 心跳旧 + 进程确实没了：往下走重新生成
      fi
      if [ "$st" = "done" ] && [ "$age" -lt 86400 ] 2>/dev/null && [ -s "$LIB/font_diag.txt" ]; then
        echo "OK:done"; exit 0           # 已经生成好了：直接看现成的（不再管它是哪种口径，绝不白重算）
      fi
      if [ "$st" = "partial" ] && [ "$age" -lt 86400 ] 2>/dev/null && [ -s "$LIB/font_diag.txt" ]; then
        echo "OK:done"; exit 0           # 上次只跑出一半：也先拿出来看，界面上会标明"未完成"
      fi
    else
      # 强制重来：只有在"心跳已经旧了"的时候才允许重起，避免把正在跑的那份打断成两份
      if [ "$st" = "running" ] && [ "$age" -ge 120 ] 2>/dev/null; then
        kill_build
      elif [ "$st" = "running" ]; then
        echo "OK:running"; exit 0
      fi
    fi
    rm -f "$LIB/.diag.cancel" 2>/dev/null
    # 新的一轮开始：把上一轮的镜像清掉，免得界面把旧内容当成"正在生成的新内容"显示
    : > "$WEB_PART" 2>/dev/null
    : > "$WEB_HEAD" 2>/dev/null
    rm -f "$WEB_META" 2>/dev/null
    BG_START=$(now_s)
    BG_FAST=$fast
    export BG_START BG_FAST DIAG_SPEED
    # ★ 1.0.9.2：**必须把速度传给 build**。
    #   build 是一个**新进程**（`diag.sh build`），它会重新解析 argv ——
    #   只写 `diag.sh build` 的话，它拿到的 argv 里没有 full/gentle，
    #   于是 DIAG_SPEED 退回默认的 gentle，**界面选了"全速"也没用**（真机实测抓到）。
    #   所以这里显式把当前速度作为参数带上。
    if command -v setsid >/dev/null 2>&1; then
      setsid sh "$MODDIR/diag.sh" build "$DIAG_SPEED" >/dev/null 2>&1 &
    else
      sh "$MODDIR/diag.sh" build "$DIAG_SPEED" >/dev/null 2>&1 &
    fi
    bpid=$!
    # 父进程先写一份（pid 可能不准），build 一开始就会用自己的真实 pid/pgid 覆盖
    _SW_BODY="state=running
phase=准备中
pid=$bpid
pgid=$bpid
start=$BG_START
time=$BG_START
fast=$fast
sub=正在启动生成任务…
pct=1
step=0
steps=7
eta=0
done=
total="
    printf '%s\n' "$_SW_BODY" > "$LIB/.diag.state" 2>/dev/null
    [ -d "$WEB" ] && printf '%s\n' "$_SW_BODY" > "$WEB_STATE" 2>/dev/null
    echo "OK:running"
    ;;
  cancel)
    # 强行结束生成：界面要"点了立刻有反应"，所以这里写完状态就返回，
    # 真正的杀进程放到后台去做（kill 要 ps/sleep，一秒钟以上，不能让它挡着）。
    # 顺手把"已经写好的部分"存一份：中止不等于白跑（界面也能马上看到这部分）
    mkdir -p "$LIB" "$WEB" 2>/dev/null
    : > "$LIB/.diag.cancel"
    _CA_PARTIAL=0; _CA_SZ=0
    if [ -s "$LIB/font_diag.part" ]; then
      _CA_SZ=$(wc -c < "$LIB/font_diag.part" 2>/dev/null | tr -d ' ')
      isnum "$_CA_SZ" || _CA_SZ=0
      if [ "$_CA_SZ" -gt 0 ]; then
        _CA_PARTIAL=1
cp -f "$LIB/font_diag.part" "$OUTFILE_FULL" 2>/dev/null
chmod 666 "$OUTFILE_FULL" 2>/dev/null
chown media_rw:media_rw "$OUTFILE_FULL" 2>/dev/null
        head -c 60000 "$LIB/font_diag.part" 2>/dev/null > "$WEB_HEAD" 2>/dev/null
{ printf 'size=%s\nlines=0\nsaved=%s\n' "$_CA_SZ" "$OUTFILE_FULL"; } > "$WEB_META" 2>/dev/null
      fi
    fi
    _SW_BODY="state=cancelled
phase=已中止
time=$(now_s)
pct=100
partial=$_CA_PARTIAL
size=$_CA_SZ
saved=$OUTFILE_FULL
msg=已按你的要求停止"
    printf '%s\n' "$_SW_BODY" > "$LIB/.diag.state" 2>/dev/null
    [ -d "$WEB" ] && printf '%s\n' "$_SW_BODY" > "$WEB_STATE" 2>/dev/null
    ( kill_build ) >/dev/null 2>&1 &
    echo "OK:cancelled"
    ;;
  build)
    BG_STATE=1
    mkdir -p "$LIB" "$WEB" 2>/dev/null
    # 自己就是被 kill 的目标：pid/pgid 由自己记录（父进程记的 $! 可能是 setsid 的 pid，不准）
    BG_PID=$$
    BG_PGID=$(awk '{print $5}' "/proc/$$/stat" 2>/dev/null | tr -d '[:space:]')
    [ -n "$BG_PGID" ] || BG_PGID=$BG_PID
    BG_START=${BG_START:-$(now_s)}
    BG_FAST=${BG_FAST:-0}
    export BG_PID BG_PGID BG_START BG_FAST
    # 关键：把自己降到最低优先级 + 磁盘 idle 类，别和系统界面抢资源
    lowprio_self
    FAST=0   # 1.0.9：快速口径已删（保留这行是为了让旧参数不报错）
    kit_report
    if [ -f "$LIB/.diag.cancel" ]; then
      # 中止：把已经写好的部分留一份"未完成"文件，方便用户/作者拿去用
      if [ -s "$LIB/font_diag.part" ]; then
cp -f "$LIB/font_diag.part" "$OUTFILE_FULL" 2>/dev/null
chmod 666 "$OUTFILE_FULL" 2>/dev/null
chown media_rw:media_rw "$OUTFILE_FULL" 2>/dev/null
        # 界面也要能看到这部分（镜像一份开头进 webroot，fetch 直接读）
        [ -d "$WEB" ] || mkdir -p "$WEB" 2>/dev/null
        PART_SZ=$(wc -c < "$LIB/font_diag.part" 2>/dev/null | tr -d ' ')
        isnum "$PART_SZ" || PART_SZ=0
        head -c 60000 "$LIB/font_diag.part" 2>/dev/null > "$WEB_HEAD" 2>/dev/null
{ printf 'size=%s\nlines=0\nsaved=%s\n' "$PART_SZ" "$OUTFILE_FULL"; } > "$WEB_META" 2>/dev/null
        state_write "cancelled" "已中止" "" "partial=1" "pct=100" "size=$PART_SZ" \
"saved=$OUTFILE_FULL" "msg=已按你的要求停止；已完成的部分已保存"
      else
        state_write "cancelled" "已中止" "" "msg=已按你的要求停止（还没写出内容）" "pct=100"
      fi
      rm -f "$LIB/.diag.cancel" 2>/dev/null
    elif [ "$ABORTED" = 1 ]; then
      :    # 超时/让路：abort_now 已经把状态和文件都处理好了，别覆盖
    elif [ -s "$LIB/font_diag.txt" ] && \
         [ "$(stat -c %Y "$LIB/font_diag.txt" 2>/dev/null || echo 0)" -ge "$BG_START" ]; then
      _BSZ=$(wc -c < "$LIB/font_diag.txt" 2>/dev/null | tr -d ' ')
      isnum "$_BSZ" || _BSZ=0
      state_write "done" "完成" "" "pct=100" "step=7" "steps=7" "eta=0" \
        "size=$_BSZ" "saved=${SAVED:-}" "msg=报告已生成并保存"
      mirror_result
    else
      state_write error 生成失败 "" "msg=无法写入报告文件" "pct=0"
    fi
    ;;
  clean)
    # 清理后台残留：生成任务 + 下载任务 + 半成品文件（界面的「清理后台」按钮用它）
    kill_build
    for p in $(ps -A -o pid,args 2>/dev/null | grep -F 'update.sh install' | grep -v grep | awk '{print $1}'); do
      _safe_to_kill "$p" && kill -9 "$p" 2>/dev/null
    done
    # 顺手把"上次被强杀留下的挂载测试层"卸掉（挂载测试有锁文件记录，这里据此还原）
    mt_recover
    rm -f "$LIB/font_diag.part" "$LIB/.diag.cancel" 2>/dev/null
    : > "$WEB_PART" 2>/dev/null
    : > "$WEB_HEAD" 2>/dev/null
    rm -f "$WEB_META" 2>/dev/null
    if [ -f "$LIB/.diag.state" ]; then
      st=$(sed -n 's/^state=//p' "$LIB/.diag.state" 2>/dev/null | head -n1 | tr -d '[:space:]')
      if [ "$st" = "running" ]; then
        printf 'state=cancelled\nphase=已清理\ntime=%s\nmsg=已清理后台任务\n' "$(now_s)" > "$LIB/.diag.state" 2>/dev/null
        [ -d "$WEB" ] && printf 'state=cancelled\nphase=已清理\ntime=%s\nmsg=已清理后台任务\n' "$(now_s)" > "$WEB_STATE" 2>/dev/null
      fi
    fi
    echo "@@PROCS"
    ps -A -o pid,ppid,args 2>/dev/null | grep -E 'diag\.sh|fontctl\.sh|update\.sh' | grep -v grep | head -n 20
    if build_alive; then
      echo "OK:partial"
      echo "还有进程没清掉（可能刚派生了新的）：可以再点一次，或重启手机"
    else
      echo "OK:clean"
      echo "已清理：后台生成任务、残留下载、半成品文件；当前没有本模块相关进程"
    fi
    ;;
  state)
    # 读状态（界面按钮用，必须毫秒级返回、绝不采集）。
    # 顺手做一次"零成本自检"：如果没有挂载测试锁文件，mt_recover 立刻返回——
    # 万一上次被强杀留下了测试挂载，这里能自动卸掉（防止关机时 /data 卸不掉）。
    mt_recover
    # 如果写着 running 但心跳已经很久没更新、进程也没了（被系统回收等），直接报错，别让界面白等
    if [ -f "$LIB/.diag.state" ]; then
      st=$(sed -n 's/^state=//p' "$LIB/.diag.state" 2>/dev/null | head -n1 | tr -d '[:space:]')
      if [ "$st" = "running" ]; then
        rpid=$(sed -n 's/^pid=//p' "$LIB/.diag.state" 2>/dev/null | head -n1 | tr -d '[:space:]')
        rt=$(sed -n 's/^time=//p' "$LIB/.diag.state" 2>/dev/null | head -n1 | tr -d '[:space:]')
        if [ -f "$LIB/.diag.cancel" ]; then
          # 已经点过中止：这是"正在退出"，不是"跑着"
          printf 'state=cancelled\nphase=正在退出\nmsg=已按你的要求停止，后台进程正在退出\n'
          exit 0
        fi
        dead=0
        [ -n "$rpid" ] && ! kill -0 "$rpid" 2>/dev/null && dead=1
        if [ "$dead" = 1 ]; then
          printf 'state=error\nphase=已停止\nmsg=生成进程已退出（可能被系统回收），请点「重新生成」\n'
          exit 0
        fi
        # 心跳超过 15 分钟没动 = 基本卡死了，但仍然保留"部分成果"的出口
        if isnum "$rt" && [ $(( $(now_s) - rt )) -gt 900 ]; then
          printf 'state=running\nphase=无响应\nstale=1\nmsg=任务很久没有进展（可能卡住了），可以点「中止生成」再重来\n'
          exit 0
        fi
      fi
      cat "$LIB/.diag.state" 2>/dev/null
    else
      echo "state=none"
    fi
    ;;
  text)
    # 整份正文（界面别直接用它抓大文件：几百 KB 过桥会让 WebView 卡住）
    cat "$LIB/font_diag.txt" 2>/dev/null
    ;;
  textpage)
    # textpage <字节偏移> <长度>：只取一段正文。界面"看更多"用它，避免一次搬运几百 KB
    _TP_OFF=${2:-0}; _TP_LEN=${3:-60000}
    isnum "$_TP_OFF" || _TP_OFF=0
    isnum "$_TP_LEN" || _TP_LEN=60000
    [ "$_TP_LEN" -gt 200000 ] && _TP_LEN=200000
    if [ -s "$LIB/font_diag.txt" ]; then
      _TP_ALL=$(wc -c < "$LIB/font_diag.txt" 2>/dev/null | tr -d ' ')
      isnum "$_TP_ALL" || _TP_ALL=0
      _TP_BODY=$(tail -c +$(( _TP_OFF + 1 )) "$LIB/font_diag.txt" 2>/dev/null | head -c "$_TP_LEN")
      _TP_GOT=$(printf '%s' "$_TP_BODY" | wc -c 2>/dev/null | tr -d ' ')
      isnum "$_TP_GOT" || _TP_GOT=0
      echo "@@OFFSET:$_TP_OFF"
      echo "@@TOTAL:$_TP_ALL"
      echo "@@NEXT:$(( _TP_OFF + _TP_GOT ))"
      echo "@@TEXT"
      printf '%s' "$_TP_BODY"
    else
      echo "@@OFFSET:0"
      echo "@@TOTAL:0"
      echo "@@NEXT:0"
      echo "@@TEXT"
    fi
    ;;
  partinfo)
    # 生成中：只回报"已经写了多少字节 / 当前阶段"，让界面显示进度而不用搬运正文
    _PI_SZ=0
    [ -s "$LIB/font_diag.part" ] && _PI_SZ=$(wc -c < "$LIB/font_diag.part" 2>/dev/null | tr -d ' ')
    isnum "$_PI_SZ" || _PI_SZ=0
    echo "part_size=$_PI_SZ"
    if [ -s "$LIB/.diag.state" ]; then
      sed -n 's/^\(state\|phase\|sub\|pct\|done\|total\|eta\|step\|fast\)=/&/p' "$LIB/.diag.state" 2>/dev/null
    fi
    ;;
  savenow)
    # 立刻把"现在已有的内容"存到 Download —— 毫秒级返回。
    # 正常流程其实会自动保存（完成时写口径文件、生成中写"未完成"文件），
    # 这个模式是给"想马上拿到手上这一份"用的（界面按钮已去掉，保留给控制台/脚本调用）
    mkdir -p "$LIB" "$DL" 2>/dev/null
    _SN_SRC=""; _SN_NOTE=""; _SN_OUT=""
    if [ -s "$LIB/font_diag.txt" ]; then
      _SN_SRC="$LIB/font_diag.txt"
      _SN_FAST=$(sed -n 's/^fast=//p' "$LIB/.diag.state" 2>/dev/null | head -n1 | tr -d '[:space:]')
      _SN_OUT="$OUTFILE_FULL"; _SN_NOTE="完整报告"   # 1.0.9：只有这一种
    elif [ -s "$LIB/font_diag.part" ]; then
      _SN_SRC="$LIB/font_diag.part"
_SN_OUT="$OUTFILE_FULL"   # 1.0.9：生成中也覆盖同一个文件
      _SN_NOTE="未完成（只包含已经生成好的部分）"
    fi
    if [ -z "$_SN_SRC" ]; then
      echo "ERROR:现在还没有内容可以保存（报告还没开始生成）"
      exit 0
    fi
    if cp -f "$_SN_SRC" "$_SN_OUT" 2>/dev/null; then
      chmod 666 "$_SN_OUT" 2>/dev/null
      chown media_rw:media_rw "$_SN_OUT" 2>/dev/null
      SAVED="$_SN_OUT"
elif cp -f "$_SN_SRC" "$LIB/font_diag.txt" 2>/dev/null; then


SAVED="$LIB/font_diag.txt"
    else
      SAVED=""
    fi
    if [ -n "$SAVED" ]; then
      echo "OK:$SAVED|$_SN_NOTE"
    else
      echo "ERROR:写入失败（检查存储空间后重试）"
    fi
    ;;
  estimate)
    # 本机工作量与预计耗时（很便宜：只数文件个数，不读内容）
    # 注意：estimate 不采集（绝不进 collect），所以这里自己拿"字体目录 + 配置引用清单"
    FONTDIRS=$(slot_dirs 2>/dev/null)
    [ -n "$FONTDIRS" ] || FONTDIRS=/system/fonts
    collect_xml
    n_all=0; n_ref=0
    for d in $(uniq_fontdirs); do
      for f in "$d"/*; do
        [ -f "$f" ] || continue
        n_all=$((n_all + 1))
      done
    done
    n_ref=$(printf '%s\n' "$XMLNAMES" | grep -c . )
    n_slot=$(cat "$M/slots.map" 2>/dev/null | grep -c . )
    # 读盘量（MB）：轻量模式只读"引用字体的前 1 MB"，完整模式要全量读所有字体
    size_all=0
    for d in $(uniq_fontdirs); do
      _k=$(du -sk "$d" 2>/dev/null | cut -f1)
      [ -n "$_k" ] && size_all=$((size_all + _k / 1024))
    done
    size_ref=0
    for _n in $XMLNAMES; do
      [ -n "$_n" ] || continue
      case "$_n" in /*) _p="$_n" ;; *) _p="/system/fonts/$_n" ;; esac
      _s=$(stat -c %s "$_p" 2>/dev/null)
      [ -n "$_s" ] && size_ref=$((size_ref + _s / 1048576))
    done
    read_fast=$size_ref
    [ "$n_ref" -lt "$read_fast" ] && read_fast=$n_ref
    [ "$read_fast" -lt 1 ] && read_fast=1
    [ "$n_all" -lt 1 ] && n_all=0
    fast=$(( 25 + n_ref * 35 / 100 + n_all * 6 / 100 ))
    full=$(( 30 + n_all * 30 / 100 ))
    echo "files_all=$n_all"
    echo "files_ref=$n_ref"
    echo "slots=$n_slot"
    echo "size_all_mb=$size_all"
    echo "read_fast_mb=$read_fast"
    echo "fast_sec=$fast"
    echo "full_sec=$full"
    ;;
  save)
    kit_report
    if [ -n "$SAVED" ]; then
      echo "OK:$SAVED"
    else
      echo "ERROR:写入失败（检查存储空间后重试）"
    fi
    ;;
  install)
    kit_report
    conclusion
    sec0
    echo
    if [ -n "$SAVED" ]; then
      echo "报告已保存到: $SAVED"
      echo "（另有一份同内容的 font_diag.txt 备用；"
      echo "  文件管理 → 内部存储 → Download → 把这一个 txt 发回给作者即可，"
      echo "  里面已经包含结论、槽位、系统字体配置原文、每个字体的 sha256 与目录映射）"
    else
      echo "报告保存失败，请把上面这段截图发回给作者。"
    fi
    ;;
  *)
    report_full
    ;;
esac
exit 0

# ---------------------------------------------------------------------------
# ★ 2026-10-16 新增（作者要求）：**建议补进清单的字体**
#
#   背景：`targets/<rom>.list` 是"每个 ROM 手工核过的额外要换的白名单"。
#   它的特殊价值在于**绕过 slot_dir_names 的文件名过滤** ——
#   mono / serif / clock 这类名字，扫描会跳过，但清单点名就会换
#   （实测量过：带清单 293 个槽位、清空清单 279 个，差的 14 个全是这类）。
#
#   问题：以前报告看不出"哪些该补进清单" —— 因为报告的 `_should` 判据把
#   mono/serif/clock 一律归成"正常排除"，跟清单的判据不是一套标准。
#
#   这一节用**差集**把候选挑出来：
#     目录里有 + 角色放行 + 不在计划里
#     → 只可能是被文件名过滤挡住的 → 补进清单就能换
#   然后由作者判断"是不是机型级"（别的同 ROM 机器也有 → 补；只这台有 → 不补）。
# ---------------------------------------------------------------------------
