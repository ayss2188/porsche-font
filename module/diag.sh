#!/system/bin/sh
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
#   sh diag.sh full      打印完整报告（10 节，含原始配置与哈希清单）
#   sh diag.sh install   生成完整报告并写入 Download，同时打印结论（「操作」按钮用）
#   sh diag.sh save      生成完整报告并写入 Download，只输出 OK:<路径>
#   sh diag.sh bg [force] [fast]  后台生成（WebUI 用；force = 强制重来，fast = 轻量口径）
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
. "$MODDIR/common.sh" 2>/dev/null
. "$MODDIR/slots.sh" 2>/dev/null
. "$MODDIR/mount.sh" 2>/dev/null

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
# FAST=1（轻量模式）：只对「配置引用到的字体 + TTC + 字体库」做重活（哈希、sfnt 表信息），
# 其它文件只记大小/魔数；同时跳过 cmd font dump / dumpsys font 这类慢调用。
# 安装时的报告也给 FAST=1（够用且快），WebUI 里可以自己选轻量还是完整。
FAST=${FAST:-0}
[ "$MODE" = install ] && FAST=1
DL=/data/media/0/Download
# 文件名按口径分开：快速体检和完整报告各写一份，不会互相覆盖，看名字就知道是哪一种。
# 固定备用名 font_diag.txt 始终等于"最近生成的那一份"。
# 注意：写入是"接力"的 —— 口径文件写不进去（存储满 / 个别文件系统不吃某个名字）就退到
# font_diag.txt，再退到模块库目录，绝不让"报告生成好了却一个文件都没有"
OUTFILE_FAST="$DL/快速体检报告.txt"
OUTFILE_FULL="$DL/完整体检报告.txt"
OUTFILE2="$DL/font_diag.txt"
OUTPART="$DL/未完成的体检报告.txt"
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

# 轻量模式下只对"配置引用到的字体 + TTC"做重活（哈希 / sfnt 表信息）。
# 返回 0 = 需要详细处理。
want_detail() {
  [ "$FAST" = 1 ] || return 0
  case "$1" in *.ttc|*.TTC) return 0 ;; esac
  case "$XMLNAMES_STR" in *" $1 "*) return 0 ;; esac
  return 1
}
# 给可能卡住的系统命令加超时（没有 timeout 就直接跑），避免体检/安装被某个命令挂住
tmo() {
  local t="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; else "$@"; fi
}
tag() { sed -n 's/^version=//p' "$1/module.prop" 2>/dev/null | head -n1 | tr -d '\r'; }
# XML 规范化：把标签拆成一行一个，方便 grep 上下文
xmlnorm() { tr '\n\r\t' ' ' < "$1" 2>/dev/null | sed 's/></>\n</g'; }
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
# TTC 合集头：'ttcf' + version + numFonts(偏移 8，4 字节小端)
ttc_faces() {
  local n
  n=$(od -An -tu4 -j8 -N4 "$1" 2>/dev/null | tr -d ' \n')
  [ -n "$n" ] || n=$(od -An -tx1 -j8 -N4 "$1" 2>/dev/null | tr -d ' \n')
  echo "${n:-?}"
}
ttc_tag() { head -c 4 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'; }
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
# 完整哈希：一批文件交给同一个 sha256sum
HASH_BATCH=""; HASH_BN=0; HN=0
hash_flush() {
  [ -n "$HASH_BATCH" ] || return 0
  _HF_OUT=$(sha256sum $HASH_BATCH 2>/dev/null)
  while IFS= read -r _HF_LN; do
    [ -n "$_HF_LN" ] || continue
    _HF_H=${_HF_LN%% *}
    _HF_P=${_HF_LN#"$_HF_H"}
    _HF_P=${_HF_P# }
    _HF_P=${_HF_P# }
    [ -n "$_HF_H" ] || _HF_H="-"
    printf '%s  %s  %s\n' "$_HF_H" "$(size_of "$_HF_P")" "$_HF_P"
    HN=$((HN + 1))
    [ $((HN % 25)) -eq 0 ] && breathe "哈希 $HN/$ftotal" "$HN" "$ftotal" 2>/dev/null
  done <<EOF
$_HF_OUT
EOF
  HASH_BATCH=""; HASH_BN=0
  return 0
}
# 单个文件哈希（文件名带空格之类没法批量时用）
hash_one() {
  _HO_H=$(sha256sum "$1" 2>/dev/null)
  _HO_H=${_HO_H%% *}
  [ -n "$_HO_H" ] || _HO_H="-"
  printf '%s  %s  %s\n' "$_HO_H" "$(size_of "$1")" "$1"
  HN=$((HN + 1))
  [ $((HN % 25)) -eq 0 ] && breathe "哈希 $HN/$ftotal" "$HN" "$ftotal" 2>/dev/null
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

subnote "校验槽位是否真的生效"
VER=$(payload_verify "$M" 2>/dev/null)
[ -n "$VER" ] || VER="0 0"
VHIT=${VER%% *}
VTOT=${VER##* }
# 字体目录 / 配置文件（硬编码清单 + 全盘发现 + apex，全部合并，避免漏掉 product/vendor/odm 的配置）
FONTDIRS=$(slot_dirs 2>/dev/null)
SYSDIR_REAL=$(readlink -f /system/fonts 2>/dev/null)
XMLFOUND=""
_addxml() {
  [ -f "$1" ] || return 0
  case " $XMLFOUND " in *" $1 "*) return 0 ;; esac
  XMLFOUND="$XMLFOUND $1"
}
for x in $XMLS; do _addxml "$x"; done
for x in $(slot_xml_files 2>/dev/null); do _addxml "$x"; done
for x in /apex/*/etc/*font*.xml /apex/*/*/etc/*font*.xml /system/etc/fonts*.xml; do _addxml "$x"; done
[ -n "$XMLFOUND" ] || XMLFOUND=" /system/etc/fonts.xml"
SYSFONTS=$(ls -1 /system/fonts 2>/dev/null)
SYSFONT_N=$(printf '%s\n' "$SYSFONTS" | grep -c . )
TTC_LIST=$(printf '%s\n' "$SYSFONTS" | grep -i '\.ttc$')
TTCNUM=$(printf '%s\n' "$TTC_LIST" | grep -c . )
TTCFIRST=$(printf '%s\n' "$TTC_LIST" | head -n1)
ZH_TTC=0
for x in $XMLFOUND; do
  xmlnorm "$x" | grep -i 'zh-Hans' | grep -qi '\.ttc' && ZH_TTC=1
done

# 三星：字体包 / flipfont / 字体设置 / /data/fonts
# 性能：pm list packages -f 和 settings list 各要 1~3 秒，以前**加载时就跑**（连只看结论的
#       轻量模式也要付这个钱）。现在只做"便宜初判"给结论用，完整清单留到需要它的那一节再算。
PKG_FONT=""; PKG_DONE=0
S_FONT=""; SFONT_DONE=0
DFONT_LIST=""; DFONT_CFG=""; DFONT_DONE=0
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
    [ -f "$_df" ] && { G_DFONT=1; break; }
  done
fi

# 下面三个是"用到才算"的重活
ensure_pkgs() {
  [ "$PKG_DONE" = 1 ] && return 0
  PKG_DONE=1
  PKG_FONT=$(tmo 15 "$PM" list packages -f 2>/dev/null | grep -iE 'monotype|flipfont|font' | head -n 20)
  [ -n "$PKG_FONT" ] && printf '%s\n' "$PKG_FONT" | grep -q '/data/app' && G_FLIP=1
  return 0
}
ensure_settings_font() {
  [ "$SFONT_DONE" = 1 ] && return 0
  SFONT_DONE=1
  S_FONT=$( { tmo 10 "$SETBIN" list secure 2>/dev/null; tmo 10 "$SETBIN" list system 2>/dev/null; tmo 10 "$SETBIN" list global 2>/dev/null; } \
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

# 槽位候选（一次算完，后面复用）
CANDS=$(slot_candidates "$M" 2>/dev/null)
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
}
SCOPE=$(eff_scope "$PEND")
KL=$(cfg_get keep_lang 1); KS=$(cfg_get keep_special 1)
subnote "计算槽位计划"
plan_of() { # $1=scope $2=keep_lang $3=keep_special
  local scope="$1" kl="$2" ks="$3" role d name base
  base=$(printf '%s\n' "$CANDS" | while read -r role d name; do
    [ -n "$role" ] || continue
    _role_wanted "$role" "$scope" "$kl" "$ks" || continue
    printf '%s %s/%s\n' "$role" "${d#/}" "$name"
  done | sort -u -k2,2)
  [ -n "$base" ] || return 0
  printf '%s\n' "$base"
  # 主题字体槽（/data/system/theme/fonts 里与上面同名的）——必须和 slot_plan 保持一致，
  # 否则报告里的"计划槽位数"会比实际少几个。
  theme_slots "$base"
}
PLAN_NOW=$(plan_of "$SCOPE" "$KL" "$KS")
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
LIB_FONTS=$(ls -1 "$LIB"/f*.ttf 2>/dev/null)
LIB_N=$(printf '%s\n' "$LIB_FONTS" | grep -c . )

# ---------------------------------------------------------------------------
# 实际字体目录映射（第 5 节的核心数据，pack_extra 也会带走）
# 定义已挪到 ensure_dirmaps()（用到才算），见下方
# ---------------------------------------------------------------------------

# 配置里引用到的所有字体文件名（一处提取，多处复用）
XMLNAMES=""
for x in $XMLFOUND; do
  XMLNAMES="$XMLNAMES$(xmlnorm "$x" 2>/dev/null | grep -o '>[^<>]*\.[tT][tT][cCfF]<' | sed 's/^>//; s/<$//; s/ *$//')
"
done
XMLNAMES=$(printf '%s\n' "$XMLNAMES" | grep -v '^[[:space:]]*$' | sort -u)

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
    [ "$BG_STATE" = 1 ] && [ $((nm_n % 25)) -eq 0 ] && sleep 1
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
  [ -s "$M/slots.map" ] || { MT_RESULT="跳过（没有槽位计划）"; return 0; }
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
  [ -f "$MT_SRC" ] || { MT_RESULT="跳过（字体库文件不存在: $MT_SRC）"; return 0; }
  [ -f "$MT_TARGET" ] || { MT_RESULT="跳过（目标槽位不存在: $MT_TARGET）"; return 0; }
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
subnote "挂载实测（挂一个真实槽位再立刻卸载）"
do_mount_test
}    # collect() 到此结束：这些采集只允许在真正生成报告时跑（见 collect_once）

# 只在生成报告时采集一次（界面按钮用的 state/cancel/bg/estimate/text/savenow 绝不调用）
COLLECTED=0
collect_once() {
  [ "$COLLECTED" = 1 ] && return 0
  COLLECTED=1
  collect
  return 0
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
    echo "   KernelSU 一旦发现 Magisk，就会跳过全部模块脚本（post-fs-data / post-mount / service 都不跑）。"
  elif [ "$G_MAGISK" = 1 ]; then
    # 有 Magisk 的痕迹，但本模块脚本确实跑了 → 现在生效的是 KernelSU，不是冲突
    echo "⚠ 结论：检测到 Magisk 与 KernelSU 共存，但本次开机的模块脚本确实执行了 ——"
    echo "   说明当前生效的是 KernelSU，Magisk 只是残留，不影响字体替换（见第 1 节）。"
  elif [ "$MT_LEFT" = 1 ]; then
    echo "⚠ 结论：挂载测试成功，但测试用的挂载点卸载失败（已记录，重启后可恢复）。"
  elif [ "$PFD_THIS" = 0 ] && [ "$SVC_THIS" = 0 ]; then
    echo "❌ 结论：没有任何一次开机留下「脚本执行过」的痕迹。"
    if [ -f "$M/mount_missed" ]; then
      echo "   但存在 mount_missed（$(mstamp "$M/mount_missed")，$(since_txt "$M/mount_missed")）："
      echo "   说明某次开机脚本跑过，只是「挂载阶段」被跳过了（管理器没有 post-mount 阶段）。"
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
  # 简中的"兜底字体"是 .ttc 合集，模块不动它。但注意别说成"中文一定不变"：
  # 只要主字体家族（sans-serif / MiSansVF 这类）在替换列表里、且你的字体自带中文字形，
  # 中文照样会变 —— .ttc 只在主字体缺字形、系统回落到它时才起作用。
  if [ "$ZH_TTC" = 1 ] && [ "$APPLIED_TTC" = 0 ] && [ -n "$PEND" ] && [ "$PEND" != none ]; then
    echo "ℹ 中文说明：本机简中的「兜底字体」是 .ttc 合集（${TTCFIRST:-?}），本模块不替换 .ttc。"
    echo "   只要替换列表里的主字体自带中文字形，中文一般也会跟着变；"
    echo "   只有主字体缺字形、系统回落到这个合集时，那一部分中文不会变。第 6 节有明细。"
  fi
  hr
  echo "本次开机: post-fs-data $([ "$PFD_THIS" = 0 ] && echo '未执行' || echo '已执行')   service $([ "$SVC_THIS" = 0 ] && echo '未执行' || echo '已执行')   实际生效 $VHIT/$VTOT"
  echo "扫描范围: $(printf '%s\n' "$FONTDIRS" | grep -c . ) 个字体目录、$(printf '%s\n' "$XMLFOUND" | grep -c . ) 份字体配置（含厂商分区与 apex）"
  if [ "$FAST" = 1 ] || [ "$BG_FAST" = 1 ]; then
    echo "本次口径: 轻量 —— 引用到的字体只算前 1MB 指纹(h:)，其余只记大小/魔数；配置原文、TTC、表信息、目录映射不受影响"
  else
    echo "本次口径: 完整 —— 所有字体全量指纹（读盘更多，闪存可能发热）"
  fi
  echo "挂载实测: $MT_RESULT"
  echo "待生效: ${PEND:-none}    当前生效: ${ACT:-none}"
  echo "（两个不一致 = 这次的选择还没被任何一次开机处理过）"
  echo "字体库: ${LIB_N:-0} 个，占用 $(du -sk "$LIB" 2>/dev/null | cut -f1) KB   挂载方式: ${MODE_FILE:-?}"
  echo "设置: keep_lang=$KL keep_special=$KS   替换范围: ${SCOPE:-?}   槽位计划: $(printf '%s\n' "$PLAN_NOW" | grep -c . ) 个"
  echo "实际字体目录: /system/fonts → ${SYSDIR_REAL:-?}（设备上共 $(printf '%s\n' "$FONTDIRS" | grep -c . ) 个字体目录，详见第 5 节）"
  echo "谷歌字体兼容: $(sh "$MODDIR/google_font.sh" status 2>/dev/null)   冲突模块: $(sh "$MODDIR/fontctl.sh" conflicts 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')"
  if [ "$G_FLIP" = 1 ]; then
    echo "⚠ 另外：检测到「字体包 / 字体设置」相关项（见第 7 节）。"
    echo "   如果你在 设置→显示→字体大小和样式 里选了非默认字体，系统会走字体包，"
    echo "   这种情况下替换 /system/fonts 是无效的，需要先选回「默认」（或系统自带字体）再重启。"
  fi
  if [ "$G_DFONT" = 1 ]; then
    echo "⚠ 另外：存在 /data/fonts（Android 可更新字体），它会盖过 /system/fonts（见第 7 节）。"
  fi
  if [ "$G_MIUI" = 1 ]; then
    echo "⚠ 另外：检测到 MIUI / HyperOS 个性字体（主题字体）：$MIUI_DIRS"
    echo "   共 $MIUI_FONT_N 个字体文件$([ -n "$MIUI_SHADOW" ] && echo "，其中与系统同名的：$MIUI_SHADOW")"
    if [ "${MIUI_INPLAN:-0}" -gt 0 ] 2>/dev/null; then
      echo "   ✅ 与本次槽位同名的那 $MIUI_INPLAN 个已纳入替换（计划里的 theme 槽位）——"
      echo "      这些名字不会再被主题字体盖住，不需要再去 设置 里切回默认。"
    else
      echo "   个性字体由主题机制接管，优先级高于 /system/fonts —— 只替换系统目录不会全面生效。"
      echo "   → 设置 → 显示 → 字体大小和样式 切回「默认」（或小米兰亭Pro）后重启一次。"
    fi
  fi
  if [ "$DATAFONT_N" -gt 0 ]; then
    echo "⚠ 另外：检测到「个性化字体」（放在 /data 上，优先级高于 /system/fonts）："
    printf '%s\n' $DATAFONT_LIST | while IFS= read -r _df; do
      [ -n "$_df" ] || continue
      echo "     $_df   $(size_kb "$_df")   修改时间 $(mstamp "$_df")"
    done
    echo "   魅族 Flyme 就是这种机制：只要这个文件在，系统显示的就一定是它的字形，"
    echo "   只替换 /system/fonts 完全看不出变化（这也是很多人以为「模块没生效」的原因）。"
    echo "   ℹ 本模块目前【只检测、不接管】这个路径（真机上没验证过的东西不默认去改）："
    echo "     · 现在想换字体：用文件管理器把自己的字体改名成 flymeFont.ttf 覆盖它，重启即可"
    echo "     · 想让模块也接管：把这份报告发给作者，作者确认后再加适配"
  fi
  echo "===== 结论结束，下面是原始数据（给作者看）====="
}

# ---------------------------------------------------------------------------
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
  echo "  Magisk 共存     : command -v magisk = $(command -v magisk 2>/dev/null || echo 无)   /data/adb/magisk = $([ -e /data/adb/magisk ] && echo 有 || echo 无)   magisk.db = $([ -e /data/adb/magisk.db ] && echo 有 || echo 无)"
  echo "                    判定: $([ "$G_MAGISK" = 1 ] && echo '★ Magisk 正在运行（会和 KernelSU 冲突）' || { [ "$MAGISK_LEFT" = 1 ] && echo '只是卸载残留（Magisk 没在运行，不影响本模块）' || echo '没有 Magisk'; })"
  echo "  Root 管理器     : $RM   (KSU=$KSU APATCH=$APATCH MAGISK_VER=$MAGISK_VER)"
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
sec3() {
  echo
  echo "【3】挂载现状 + 实机挂载能力实测"
  hr
  echo "  /system/fonts 上层挂载点数量: $("$MO" 2>/dev/null | grep -c '/system/fonts/')"
  "$MO" 2>/dev/null | grep '/system/fonts/' | head -n 8 | while IFS= read -r L; do echo "      $L"; done
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
  echo "  .ttc 合集清单（本模块不支持替换）:"
  printf '%s\n' "$TTC_LIST" | while IFS= read -r L; do
    [ -n "$L" ] || continue
    # TTC 一般有几十 MB：这里只读前 1 MB（h: 头哈希）就够标识，诊断靠 faces/size，不靠全量哈希
    echo "      $L  $(size_kb "/system/fonts/$L")  faces=$(ttc_faces "/system/fonts/$L")  h=$(head -c 1048576 "/system/fonts/$L" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)"
  done
  [ "$TTCNUM" = 0 ] && echo "      （无）"
  echo "  简中 zh-Hans 是否指向 .ttc: $([ "$ZH_TTC" = 1 ] && echo '是 ★ 这是它的兜底字体（本模块不替换 .ttc；主字体家族被替换且含中文字形时，中文仍会变）' || echo 否)"
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
  if [ "$FAST" = 1 ]; then
    echo "      （轻量模式：跳过 cmd font dump / dumpsys font，这两个调用最慢）"
  else
    echo "  运行时字体列表（部分机型支持 cmd font dump）:"
    tmo 8 "$CMD" font dump sans-serif 2>/dev/null | head -n 30 | while IFS= read -r L; do echo "      $L"; done
    tmo 8 "$CMD" font dump 2>/dev/null | head -n 15 | while IFS= read -r L; do echo "      [dump] $L"; done
    tmo 8 dumpsys font 2>/dev/null | head -n 15 | while IFS= read -r L; do echo "      [dumpsys] $L"; done
  fi
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
      echo "      其中已纳入本模块替换的: $MIUI_INPLAN 个（名字与本次槽位相同，见计划里的 theme 行）"
      echo "      说明: 这几个文件会被本模块一并替换，主题字体不再盖住它们。"
    else
      echo "      说明: 与本次槽位同名的会被本模块一并替换；不同名的不动（主题自带的东西）。"
      echo "            如当前列表一个都没覆盖到，说明主题用的名字和系统槽位都不一样。"
    fi
  else
    echo "      （未检测到个性字体，系统字体走 /system/fonts 等系统目录）"
  fi
  echo "  厂商个性化字体（/data 上的固定路径，优先级高于 /system/fonts）:"
  if [ "$DATAFONT_N" -gt 0 ]; then
    printf '%s\n' $DATAFONT_LIST | while IFS= read -r L; do
      [ -n "$L" ] || continue
      echo "      $L  $(size_kb "$L")  mtime=$(mstamp "$L")"
      echo "          前 4 字节: $(magic4 "$L")   表信息: $(sfnt_tags "$L")"
    done
    echo "      ★ 这个路径上的文件会盖过 /system/fonts，而本模块【不会动它】："
    echo "        - 结果是：换字体后系统字体文件确实被替换了，但屏幕上一点变化都没有"
    echo "        - 想手动换：用文件管理器把自己的字体改名成 flymeFont.ttf 覆盖它，重启即可"
    echo "        - 想让模块也接管这个路径：把这份报告发给作者（已经在 Issue/群里）——"
    echo "          作者会先看这台机器的实际情况，确认安全后再加适配，不拿真机乱试。"
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
  tmo 10 dmesg 2>/dev/null | grep -i -E 'kernelsu|ksud|ksu_' | tail -n 10 | while IFS= read -r L; do echo "      $L"; done
  echo "  电池/内存/存储:"
  echo "      MemTotal=$(sed -n 's/^MemTotal: *//p' /proc/meminfo 2>/dev/null)  MemAvailable=$(sed -n 's/^MemAvailable: *//p' /proc/meminfo 2>/dev/null)"
  df -k /data /cache /metadata 2>/dev/null | while IFS= read -r L; do echo "      $L"; done
  echo "  校验相关属性:"
  for p in ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.veritymode ro.security.vaultkeeper.feature ro.crypto.state ro.boot.warranty_bit ro.boot.bootloader ro.build.version.oneui ro.build.version.sem ro.build.version.security_patch; do
    echo "      $p=$($GP "$p" 2>/dev/null)"
  done
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
  echo
  ensure_dirmaps      # 导出数据包要带上目录映射与名字映射
  echo "@@SECTION:META"
  echo "time=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  # 哈希口径：head1mb = 只读前 1 MB（轻量模式，对闪存友好）；full = 全文件
  if [ "$FAST" = 1 ] || [ "$BG_FAST" = 1 ]; then echo "hash_mode=head1mb"; else echo "hash_mode=full"; fi
  echo "fast=${FAST:-0}"
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
  echo "# hash_mode=$([ "$FAST" = 1 ] || [ "$BG_FAST" = 1 ] && echo head1mb || echo full)"
  echo "# note=同一个字体目录被多个路径指到时只算一次（以前会重复哈希好几遍，这是最后一步特别慢的主因）"
  XMLNAMES_STR=" $(printf '%s' "$XMLNAMES" | tr '\n' ' ')"
  HDIRS=$(uniq_fontdirs)
  # 先数一下总数（只数个数，很便宜），用来显示"哈希 120/312"
  ftotal=0
  for d in $HDIRS; do
    ftotal=$((ftotal + $(ls -1 "$d" 2>/dev/null | wc -l)))
  done
  n=0; HN=0
  for d in $HDIRS; do
    [ -d "$d" ] || continue
    load_sizes "$d"
    if [ "$FAST" = 1 ]; then
      # 轻量模式：只对"配置引用到的字体 + TTC"算头哈希（h:），每个文件两个进程就够
      for f in "$d"/*; do
        [ -f "$f" ] || continue
        b=${f##*/}
        if want_detail "$b"; then
          _h=$(head -c 1048576 "$f" 2>/dev/null | sha256sum 2>/dev/null)
          _h=${_h%% *}
          [ -n "$_h" ] && _h="h:$_h" || _h="-"
        else
          _h="-"
        fi
        printf '%s  %s  %s\n' "$_h" "$(size_of "$f")" "$f"
        HN=$((HN + 1))
        [ $((HN % 25)) -eq 0 ] && breathe "哈希 $HN/$ftotal" "$HN" "$ftotal" 2>/dev/null
      done
    else
      # 完整模式：一批文件交给同一个 sha256sum（一个进程读一批），
      # 不再"每个文件起一个 sha256sum" —— 进程数少一个数量级，CPU 也不会被 fork 风暴打满
      HASH_BATCH=""; HASH_BN=0
      for f in "$d"/*; do
        [ -f "$f" ] || continue
        case "$f" in
          *" "*)                      # 文件名带空格没法安全批量：先清空批次，再单独算
            hash_flush
            if want_detail "${f##*/}"; then hash_one "$f"; else
              printf '%s  %s  %s\n' "-" "$(size_of "$f")" "$f"
              HN=$((HN + 1))
              [ $((HN % 25)) -eq 0 ] && breathe "哈希 $HN/$ftotal" "$HN" "$ftotal" 2>/dev/null
            fi
            continue ;;
        esac
        if ! want_detail "${f##*/}"; then
          printf '%s  %s  %s\n' "-" "$(size_of "$f")" "$f"
          HN=$((HN + 1))
          [ $((HN % 25)) -eq 0 ] && breathe "哈希 $HN/$ftotal" "$HN" "$ftotal" 2>/dev/null
          continue
        fi
        HASH_BATCH="$HASH_BATCH $f"
        HASH_BN=$((HASH_BN + 1))
        [ "$HASH_BN" -ge 20 ] && hash_flush
      done
      hash_flush
    fi
  done
  echo "@@SECTION:FONT_META"
  n=0
  for d in $HDIRS; do
    [ -d "$d" ] || continue
    load_sizes "$d"
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
  subnote "TTC 合集头信息"
  echo "@@SECTION:TTCHEAD"
  for d in $FONTDIRS; do
    for f in "$d"/*.ttc; do
      [ -f "$f" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$f" "$(ttc_tag "$f")" "$(ttc_faces "$f")" "$(stat -c %s "$f" 2>/dev/null)"
    done
  done
  subnote "导出字体配置原文"
  echo "@@SECTION:XMLCONTENT"
  for x in $XMLFOUND; do
    echo "@@FILE:BEGIN $x"
    cat "$x" 2>/dev/null
    echo
    echo "@@FILE:END"
  done
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
  subnote "导出字体目录清单"
  echo "@@SECTION:DIRLIST"
  for d in $FONTDIRS; do
    echo "--- $d"
    ls -l "$d" 2>/dev/null
  done
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
  subnote "导出挂载表"
  echo "@@SECTION:MOUNTS"
  "$MO" 2>/dev/null | head -n 80
  subnote "导出字体库指纹"
  echo "@@SECTION:LIBFONTS"
  ls -l "$LIB" 2>/dev/null
  for f in $LIB_FONTS; do
    # 字体库文件也在闪存上：轻量模式同样只读前 1 MB（自己的字体常有几十 MB，全读太伤盘）
    if [ "$FAST" = 1 ] || [ "$BG_FAST" = 1 ]; then
      printf '%s  %s  %s\n' "h:$(head -c 1048576 "$f" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)" "$(stat -c %s "$f" 2>/dev/null)" "$f"
    else
      printf '%s  %s  %s\n' "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" "$(stat -c %s "$f" 2>/dev/null)" "$f"
    fi
  done
  for f in $LIB_FONTS; do
    i=${f##*/}; i=${i%.ttf}
    echo "--- $i  name=$(cat "$LIB/$i.name" 2>/dev/null | tr -d '\r\n')"
    cat "$LIB/$i.meta" 2>/dev/null
  done
  subnote "导出 /data/fonts"
  echo "@@SECTION:DATAFONTS"
  ls -lR /data/fonts 2>/dev/null | head -n 60
  [ -f /data/fonts/config/config.xml ] && cat /data/fonts/config/config.xml 2>/dev/null
  subnote "导出主题字体"
  echo "@@SECTION:MIUIFONT"
  echo "# 目录: $MIUI_DIRS"
  echo "# 与系统同名(会被接管): $MIUI_SHADOW"
  printf '%s\n' "$MIUI_FONTLIST"
  for td in $MIUI_DIRS; do
    echo "--- $td"
    ls -lZ "$td" 2>/dev/null | head -n 30
  done
  subnote "导出个性化字体"
  echo "@@SECTION:PERSONALFONT"
  echo "# 厂商个性化字体（/data 上的固定路径，优先级高于 /system/fonts）"
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
  subnote "收尾"
  echo "@@SECTION:END"
}

# ---------------------------------------------------------------------------
report_full() {
  echo "== 自定义字体切换模块 · 一键体检报告 =="
  collect_once
  conclusion
  sec1
  sec2
  sec3
  sec4
  sec5
  sec6
  sec7
  sec8
  sec9
  sec10
  echo
  echo "== 报告结束 =="
}

# 本次该写哪个文件名（快速体检 / 完整报告分开）
OUT_NOW=""
set_out_now() {
  if [ "$FAST" = 1 ] || [ "$BG_FAST" = 1 ]; then
    OUT_NOW="$OUTFILE_FAST"
  else
    OUT_NOW="$OUTFILE_FULL"
  fi
}

# 把完整报告（结论 + 10 节 + 原始配置与哈希清单）写到 Download，成功时 SAVED=路径
# 只产出一个 txt（另有一份同内容的 font_diag.txt 备用名），不再生成附件文件夹
write_kit() {
  local tmpf="$1"
  SAVED=""
  [ -s "$tmpf" ] || return 0
  set_out_now
  mkdir -p "$DL" "$LIB" 2>/dev/null
  # 1) 先写"口径文件"（快速/完整分开）；2) 不行就退到固定名 font_diag.txt；
  # 3) 再不行至少把内容留在模块库里（界面会把真实路径显示出来）
  if cp -f "$tmpf" "$OUT_NOW" 2>/dev/null; then
    chmod 666 "$OUT_NOW" 2>/dev/null
    chown media_rw:media_rw "$OUT_NOW" 2>/dev/null
    SAVED="$OUT_NOW"
    if cp -f "$tmpf" "$OUTFILE2" 2>/dev/null; then
      chmod 666 "$OUTFILE2" 2>/dev/null
      chown media_rw:media_rw "$OUTFILE2" 2>/dev/null
    fi
  elif cp -f "$tmpf" "$OUTFILE2" 2>/dev/null; then
    chmod 666 "$OUTFILE2" 2>/dev/null
    chown media_rw:media_rw "$OUTFILE2" 2>/dev/null
    SAVED="$OUTFILE2"
  fi
  cp -f "$tmpf" "$LIB/font_diag.txt" 2>/dev/null
  [ -n "$SAVED" ] || SAVED="$LIB/font_diag.txt"
  cp -f "$tmpf" /data/local/tmp/font_diag.txt 2>/dev/null
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
    cp -f "$LIB/font_diag.part" "$OUTPART" 2>/dev/null
    chmod 666 "$OUTPART" 2>/dev/null
    chown media_rw:media_rw "$OUTPART" 2>/dev/null
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
    _DP_T=${1#*/}; _DP_T=${_DP_T%% *}; isnum "$_DP_T" || _DP_T=6
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
  calc_pct "${BG_STEP:-0}" "${BG_STEPS:-6}" "$_BR_D" "$_BR_T"
  calc_eta_pct "$CP_P"
  state_write running "${BG_PHASE:-处理中}" "${1:-}" \
    "step=${BG_STEP:-0}" "steps=${BG_STEPS:-6}" \
    "pct=$CP_P" "done=$_BR_D" "total=$_BR_T" "eta=$CE_ETA"
  sleep 1
  return 0
}

# 只更新"正在做什么"这一行（不睡，用在打包各小节开头：界面就不会看着停住）
subnote() {
  [ "$BG_STATE" = 1 ] || return 0
  _ck
  calc_pct "${BG_STEP:-0}" "${BG_STEPS:-6}"
  calc_eta_pct "$CP_P"
  state_write running "${BG_PHASE:-处理中}" "${1:-}" \
    "step=${BG_STEP:-0}" "steps=${BG_STEPS:-6}" \
    "pct=$CP_P" "eta=$CE_ETA"
  return 0
}

# 把自己降到最低优先级（CPU nice 19 + 磁盘 idle 类），子进程会继承
# 没有 nice/renice/ionice 就跳过，不影响功能
lowprio_self() {
  command -v ionice >/dev/null 2>&1 && ionice -c 3 -p $$ 2>/dev/null
  if command -v renice >/dev/null 2>&1; then
    renice 19 -p $$ >/dev/null 2>&1
  elif command -v nice >/dev/null 2>&1; then
    nice -n 19 -p $$ >/dev/null 2>&1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 分阶段计时：报告里会附带"每一步花了多少秒"
#   给用户看：知道卡在哪一步、还要多久；
#   给作者看：一眼看出哪一步是性能瓶颈（以前只能靠猜）
# ---------------------------------------------------------------------------
TIMING_LIST=""
timing_add() {   # timing_add <名称> <开始秒>
  _TA_N=$(now_s)
  _TA_D=$(( _TA_N - ${2:-$_TA_N} ))
  [ "$_TA_D" -lt 0 ] && _TA_D=0
  TIMING_LIST="$TIMING_LIST$1|$_TA_D
"
  [ "$BG_STATE" = 1 ] && printf '%s|%s\n' "$1" "$_TA_D" >> "$LIB/.diag.timing" 2>/dev/null
  return 0
}

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
  [ "$BG_STATE" = 1 ] && : > "$LIB/.diag.timing" 2>/dev/null
  _PH_T0=$(now_s)
  dphase '1/6 结论与门禁检查'
  collect_once
  # 静态预估：给界面一个"一开始就能显示的预计耗时"（很便宜：只数个数）
  BG_ETA0=$(static_eta)
  isnum "$BG_ETA0" || BG_ETA0=0
  export BG_ETA0
  { conclusion; sec1; } >> "$tmpf" 2>&1
  timing_add '1 结论与门禁检查' "$_PH_T0"
  export_part "$tmpf"
  _PH_T0=$(now_s)
  dphase '2/6 开机痕迹与挂载实测'
  { sec2; sec3; } >> "$tmpf" 2>&1
  timing_add '2 开机痕迹与挂载实测' "$_PH_T0"
  export_part "$tmpf"
  _PH_T0=$(now_s)
  dphase '3/6 槽位与字体目录映射'
  { sec4; sec5; } >> "$tmpf" 2>&1
  timing_add '3 槽位与字体目录映射' "$_PH_T0"
  export_part "$tmpf"
  _PH_T0=$(now_s)
  dphase '4/6 字体配置与字体来源'
  { sec6; sec7; } >> "$tmpf" 2>&1
  timing_add '4 字体配置与字体来源' "$_PH_T0"
  export_part "$tmpf"
  _PH_T0=$(now_s)
  dphase '5/6 清单 / 冲突 / 日志'
  { sec8; sec9; sec10; } >> "$tmpf" 2>&1
  timing_add '5 清单 / 冲突 / 日志' "$_PH_T0"
  export_part "$tmpf"
  _PH_T0=$(now_s)
  dphase '6/6 打包原始配置与哈希清单'
  pack_extra >> "$tmpf" 2>&1
  timing_add '6 打包原始配置与哈希清单' "$_PH_T0"
  {
    echo
    echo "@@SECTION:TIMING"
    echo "## 每一步耗时（秒）—— 慢在哪一步看这里（反馈问题时请连这一段一起发）"
    printf '%s' "$TIMING_LIST"
    echo "合计|$(( $(now_s) - ${_KR_T0:-$(now_s)} ))"
  } >> "$tmpf" 2>&1
  printf '== 报告结束 ==\n' >> "$tmpf"
  write_kit "$tmpf"
  mirror_result
  rm -f "$tmpf" 2>/dev/null
  return 0
}

# 阶段结束时的"增量导出"：让"未完成"的文件一直是可用的
# 只在后台模式下做（前台 save/install 由 write_kit 一次写完，不重复写盘）
export_part() {
  [ "$BG_STATE" = 1 ] || return 0
  [ -s "$1" ] || return 0
  cp -f "$1" "$OUTPART" 2>/dev/null
  chmod 666 "$OUTPART" 2>/dev/null
  chown media_rw:media_rw "$OUTPART" 2>/dev/null
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
  if [ "$BG_FAST" = 1 ] || [ "$FAST" = 1 ]; then
    printf '%s' $(( 25 + _SE_R * 35 / 100 + _SE_A * 6 / 100 ))
  else
    printf '%s' $(( 30 + _SE_A * 30 / 100 ))
  fi
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
  bg)
    # 后台生成（立刻返回，WebUI 的 JS 不会被长命令卡住；生成期间窗口可随时关闭）
    # 本模式只做"读状态 + 启动"，绝不采集 —— 这是"点一下立刻有反应"的前提
    #   bg              已有正在跑的/刚生成好的，就直接复用（别重算）
    #   bg force        强制重新生成（先把正在跑的干掉）
    #   bg fast         轻量模式：只算必要字体的指纹，跳过 cmd font dump / dumpsys（不影响主要结论）
    #   bg force fast   组合使用
    mkdir -p "$LIB" "$WEB" 2>/dev/null
    force=0; fast=0
    for a in "$2" "$3"; do
      [ "$a" = force ] && force=1
      [ "$a" = fast ] && fast=1
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
    export BG_START BG_FAST
    if command -v setsid >/dev/null 2>&1; then
      setsid sh "$MODDIR/diag.sh" build >/dev/null 2>&1 &
    else
      sh "$MODDIR/diag.sh" build >/dev/null 2>&1 &
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
steps=6
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
        cp -f "$LIB/font_diag.part" "$OUTPART" 2>/dev/null
        chmod 666 "$OUTPART" 2>/dev/null
        chown media_rw:media_rw "$OUTPART" 2>/dev/null
        head -c 60000 "$LIB/font_diag.part" 2>/dev/null > "$WEB_HEAD" 2>/dev/null
        { printf 'size=%s\nlines=0\nsaved=%s\n' "$_CA_SZ" "$OUTPART"; } > "$WEB_META" 2>/dev/null
      fi
    fi
    _SW_BODY="state=cancelled
phase=已中止
time=$(now_s)
pct=100
partial=$_CA_PARTIAL
size=$_CA_SZ
saved=$OUTPART
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
    if [ "$BG_FAST" = 1 ]; then
      FAST=1          # 轻量模式：只算必要字体的指纹，跳过 cmd font dump / dumpsys
    fi
    kit_report
    if [ -f "$LIB/.diag.cancel" ]; then
      # 中止：把已经写好的部分留一份"未完成"文件，方便用户/作者拿去用
      if [ -s "$LIB/font_diag.part" ]; then
        cp -f "$LIB/font_diag.part" "$OUTPART" 2>/dev/null
        chmod 666 "$OUTPART" 2>/dev/null
        chown media_rw:media_rw "$OUTPART" 2>/dev/null
        # 界面也要能看到这部分（镜像一份开头进 webroot，fetch 直接读）
        [ -d "$WEB" ] || mkdir -p "$WEB" 2>/dev/null
        PART_SZ=$(wc -c < "$LIB/font_diag.part" 2>/dev/null | tr -d ' ')
        isnum "$PART_SZ" || PART_SZ=0
        head -c 60000 "$LIB/font_diag.part" 2>/dev/null > "$WEB_HEAD" 2>/dev/null
        { printf 'size=%s\nlines=0\nsaved=%s\n' "$PART_SZ" "$OUTPART"; } > "$WEB_META" 2>/dev/null
        state_write "cancelled" "已中止" "" "partial=1" "pct=100" "size=$PART_SZ" \
          "saved=$OUTPART" "msg=已按你的要求停止；已完成的部分已保存"
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
      state_write "done" "完成" "" "pct=100" "step=6" "steps=6" "eta=0" \
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
      if [ "$_SN_FAST" = "1" ]; then _SN_OUT="$OUTFILE_FAST"; _SN_NOTE="快速体检";
      else _SN_OUT="$OUTFILE_FULL"; _SN_NOTE="完整报告"; fi
    elif [ -s "$LIB/font_diag.part" ]; then
      _SN_SRC="$LIB/font_diag.part"
      _SN_OUT="$OUTPART"
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
    elif cp -f "$_SN_SRC" "$OUTFILE2" 2>/dev/null; then
      chmod 666 "$OUTFILE2" 2>/dev/null
      chown media_rw:media_rw "$OUTFILE2" 2>/dev/null
      SAVED="$OUTFILE2"
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
