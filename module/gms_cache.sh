#!/system/bin/sh
# 谷歌字体缓存桥接 —— 让 Play 商店也生效
#
# 为什么需要它：真机实测（Xiaomi / HyperOS / Android 17）——
#   · /data/fonts/files（公共下载字体缓存）是**空的**；
#   · 商店要的 Google Sans 全在 **GMS 私有目录**：
#       /data/data/com.google.android.gms/files/fonts/opentype/
#         Google_Sans-400/500/700-…、Google_Sans_Text-…、Google_Sans_Flex-…、
#         Google_Sans_Code-…（★编程字体，不能换）、Noto_COLR_Emoji_Compat（★emoji，不能换）
#   · 商店自己目录里 **一个 .ttf 都没有** → 它不内置字体，是**从 GMS 那儿拿**的。
# 所以：把上面那些 Google Sans 文件用我们当前生效的字体 bind 顶替掉，商店就该跟着变。
#
#   · 认目标**靠字体自己的 name 表**（nameID 1/16 的 family 名），**不看文件名**。
#   · 挂载记在账本里（$LIB/.gms_bridge.list），关闭/卸载时按账本 umount 还原。
#   · 只挂 .ttf/.otf，**不碰 .ttc 合集**（合集要按 face 处理，这里不做）。
#   · ★ **必须在 zygote 起来之前挂**（post-fs-data 阶段）：应用的挂载命名空间是从 zygote
#     复制出来的快照，后挂的挂载**已经在跑的应用看不到**。想在开机后立刻生效，
#     得 nsenter 进 zygote 的命名空间再挂（见 bridge_into_zygote）。
#
# 用法：sh gms_cache.sh on | off | status | diag | families <文件>
LIB=${LIB:-/data/adb/custom_font_lib}
MODDIR=${MODDIR:-${0%/*}}
# 目标目录（可覆盖）：GMS 私有下载字体目录 + 公共下载字体目录
CACHE_DIRS=${GMS_CACHE_DIRS:-"/data/data/com.google.android.gms/files/fonts/opentype /data/fonts/files"}
[ -n "$GMS_CACHE_DIR" ] && CACHE_DIRS="$GMS_CACHE_DIR"
MOUNTS_FILE=${CFS_MOUNTS_FILE:-/proc/mounts}
JOURNAL="$LIB/.gms_bridge.list"
LOG="$LIB/.gms_bridge.log"
FAM_LIST=${FAM_LIST:-"googlesans googlesanstext googlesansdisplay googlesansflex productsans"}

MNT=${MNT:-/system/bin/mount}; [ -x "$MNT" ] || MNT="$(command -v mount 2>/dev/null)"
UMNT=${UMNT:-/system/bin/umount}; [ -x "$UMNT" ] || UMNT="$(command -v umount 2>/dev/null)"

mkdir -p "$LIB" 2>/dev/null
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
blog() { printf '%s %s\n' "$(date '+%m-%d %H:%M' 2>/dev/null)" "$*" >> "$LOG" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 读字体 name 表里的 family 名（归一化成小写字母数字，每行一个）
#   纯 shell + od + awk，不要 Python / fontTools。
#   **两步走**：① 只读文件前 4KB 定位 name 表（表目录就在开头）；
#              ② 按算出的偏移再读那张表。
#   （大字体里 name 表可能在几百 KB 之外 —— 一次灌前 256KB 会因为表在范围外读到垃圾：
#     实测把偏移读成 17812700，这个坑真踩过）
#   platformID=3（Windows）是 UTF-16BE（隔一取一），=1（Mac）是单字节；只留 ASCII。
# ---------------------------------------------------------------------------
font_families() {
  local f="$1" _hdr _off _len
  [ -f "$f" ] || return 1
  _hdr=$(od -An -tu1 -v -N 4096 "$f" 2>/dev/null | awk '
    { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }
    function u16(p) { return b[p] * 256 + b[p+1] }
    function u32(p) { return ((b[p] * 256 + b[p+1]) * 256 + b[p+2]) * 256 + b[p+3] }
    function chr(c) { return (c >= 32 && c < 127) ? sprintf("%c", c) : "" }
    END {
      if (n < 12) exit
      num = u16(4)
      for (t = 0; t < num; t++) {
        p = 12 + t * 16
        if (p + 15 >= n) break
        if (chr(b[p]) chr(b[p+1]) chr(b[p+2]) chr(b[p+3]) == "name") {
          printf "%d %d\n", u32(p + 8), u32(p + 12); exit
        }
      }
    }')
  [ -n "$_hdr" ] || return 1
  set -- $_hdr; _off=$1; _len=$2
  [ "$_off" -gt 0 ] 2>/dev/null || return 1
  [ "$_len" -gt 6 ] 2>/dev/null || return 1
  od -An -tu1 -v -j "$_off" -N "$_len" "$f" 2>/dev/null | awk '
    { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }
    function u16(p) { return b[p] * 256 + b[p+1] }
    function chr(c) { return (c >= 32 && c < 127) ? sprintf("%c", c) : "" }
    END {
      if (n < 6) exit
      cnt = u16(2); so = u16(4)
      for (i = 0; i < cnt; i++) {
        r = 6 + i * 12
        if (r + 11 >= n) break
        pid = u16(r); nid = u16(r + 6); len = u16(r + 8); off = u16(r + 10)
        if (nid != 1 && nid != 16) continue
        sp = so + off
        if (len <= 0 || sp + len > n) continue
        s = ""
        if (pid == 3) { for (k = 0; k + 1 < len; k += 2) s = s chr(b[sp+k] * 256 + b[sp+k+1]) }
        else          { for (k = 0; k < len; k++)      s = s chr(b[sp+k]) }
        gsub(/[^A-Za-z0-9]/, "", s)
        if (s != "") print tolower(s)
      }
    }'
}
font_norm_file() { font_families "$1"; }

# 是不是 Google Sans / Product Sans 系列（排除 Google Sans Code 和 emoji：那两个绝对不能换）
is_google_family() {
  local f
  for f in $(font_families "$1" 2>/dev/null); do
    case "$f" in googlesanscode*|*emoji*) return 1 ;; esac
    case " $FAM_LIST " in *" $f "*) return 0 ;; esac
    case "$f" in googlesans*|productsans*) return 0 ;; esac
  done
  return 1
}

# 我们当前生效的字体文件（优先用户选的那个，其次模块里已生成的）
source_font() {
  local id f
  id=$(tr -d '[:space:]' < "$LIB/last_selection" 2>/dev/null)
  if [ -n "$id" ] && [ -f "$LIB/$id.ttf" ]; then printf '%s' "$LIB/$id.ttf"; return 0; fi
  for f in "$MODDIR"/system/fonts/*.ttf; do
    [ -f "$f" ] || continue
    [ "$(wc -c < "$f" 2>/dev/null || echo 0)" -gt 4096 ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

mounted_now() { grep -qs "$1" "$MOUNTS_FILE" 2>/dev/null; }
in_journal()   { [ -f "$JOURNAL" ] && grep -qs "^$1|" "$JOURNAL"; }

# 扫出"该被顶替"的字体文件（所有目标目录）
scan_targets() {
  local d
  for d in $CACHE_DIRS; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 3 -type f \( -name '*.ttf' -o -name '*.otf' \) 2>/dev/null | while IFS= read -r t; do
      is_google_family "$t" && printf '%s\n' "$t"
    done
  done
}

do_on() {
  local src list n=0 t any=0 d
  src=$(source_font) || { echo "没有可用的字体文件，跳过（缓存桥接）"; return 0; }
  [ -n "$MNT" ] || { echo "ERROR:找不到 mount 命令"; return 1; }
  for d in $CACHE_DIRS; do [ -d "$d" ] && any=1; done
  [ "$any" = 1 ] || { echo "这台机器没有下载字体目录（商店没下载过字体），跳过"; return 0; }
  list="$LIB/.gms_bridge.scan.$$"
  scan_targets > "$list" 2>/dev/null
  while IFS= read -r t; do
    [ -n "$t" ] || continue
# ★ 以【真实挂载状态 + 大小】为准，不信账本 ——
    #   账本跨重启保留、挂载不保留，信账本会导致"每次开机都以为挂过、直接跳过"（真机实测过）
    if mounted_now "$t" && [ "$(wc -c < "$t" 2>/dev/null)" = "$(wc -c < "$src" 2>/dev/null)" ]; then
      n=$((n + 1)); continue
    fi
    # ★ 挂【同名克隆】而不是原件：GMS 会核对字体身份（家族名），挂原件会被无视 →
    #   克隆 = 我们的字形 + 目标的 name 表（"自称 Google Sans"），按家族缓存复用。
    fam=$(font_families "$t" 2>/dev/null | head -n1)
    case "$fam" in ''|*[!a-z0-9]*) fam=unknown ;; esac
    cl="$LIB/.clone.$fam.ttf"
    if [ ! -s "$cl" ] && [ -f "$MODDIR/nameclone.sh" ]; then
      tmo 120 sh "$MODDIR/nameclone.sh" clone "$src" "$t" "$cl" >/dev/null 2>&1
    fi
    src_m="$src"
    [ -s "$cl" ] && src_m="$cl"
    if tmo 10 "$MNT" --bind "$src_m" "$t" 2>/dev/null; then
      printf '%s|%s\n' "$t" "$src_m" >> "$JOURNAL" 2>/dev/null
      n=$((n + 1))
      blog "桥接：$t ← $src_m"
    else
      blog "桥接失败：$t"
    fi
  done < "$list"
  rm -f "$list" 2>/dev/null
  printf 'OK：谷歌系字体已顶替 %s 个文件（用 %s）\n' "$n" "${src##*/}"
  return 0
}

do_off() {
  local n=0 t s rev="$LIB/.gms_bridge.rev.$$" keep="$LIB/.gms_bridge.keep.$$"
  [ -f "$JOURNAL" ] || { echo "没有需要还原的缓存挂载"; return 0; }
  [ -n "$UMNT" ] || { echo "ERROR:找不到 umount 命令"; return 1; }
  sed '1!G;h;$!d' "$JOURNAL" > "$rev" 2>/dev/null || cp "$JOURNAL" "$rev" 2>/dev/null
  : > "$keep" 2>/dev/null
  while IFS='|' read -r t s; do
    [ -n "$t" ] || continue
    if tmo 10 "$UMNT" "$t" 2>/dev/null; then
      n=$((n + 1)); blog "还原：$t"
    else
      printf '%s|%s\n' "$t" "$s" >> "$keep" 2>/dev/null
      blog "还原失败：$t"
    fi
  done < "$rev"
  rm -f "$rev" 2>/dev/null
  # 账本 = 只留"没卸掉"的那些（一次重写，别逐行删 —— 那样容易留下半截账本）
  if [ -s "$keep" ]; then mv -f "$keep" "$JOURNAL" 2>/dev/null; else rm -f "$keep" "$JOURNAL" 2>/dev/null; fi
  printf 'OK：已还原 %s 个挂载\n' "$n"
  return 0
}

# 不重启也想立刻生效：把挂载做进 zygote 的命名空间（之后 fork 的应用都继承）
bridge_into_zygote() {
  local src t pid zpid
  src=$(source_font) || return 0
  command -v nsenter >/dev/null 2>&1 || return 1
  zpid=$(pidof zygote64 2>/dev/null || pidof zygote 2>/dev/null)
  [ -n "$zpid" ] || return 1
  for pid in $zpid; do
    scan_targets 2>/dev/null | while IFS= read -r t; do
      tmo 10 nsenter -t "$pid" -m -- "$MNT" --bind "$src" "$t" >/dev/null 2>&1
    done
  done
  return 0
}

do_status() {
  local found mnt
  found=$(scan_targets 2>/dev/null | grep -c . 2>/dev/null); found=${found:-0}
  mnt=0
  [ -f "$JOURNAL" ] && { mnt=$(grep -c . "$JOURNAL" 2>/dev/null); mnt=${mnt:-0}; }
  printf 'found=%s mounted=%s\n' "$found" "$mnt"
}

do_diag() {
  local t src d n total
  # ★ 1.0.9.2：**大改，为了不等它**。
  #   以前这里会 `scan_targets`（对缓存目录里**每个** ttf/otf 跑一次
  #   is_google_family → font_families 解析字体名），命中的再逐个查账本 + 查挂载。
  #   商店下载过很多字体时就是**几百次字体解析 + 几百次 grep** —— 报告卡在这一步很久（真机反馈过）。
  #
  #   现在只收"判断兼容有没有生效"真正需要的几个数字，不再逐个文件列清单：
  #     · 缓存目录在不在、里面有多少 ttf/otf（只数个数，**不解析字体**）
  #     · 账本里记了多少条（= 我们挂上去的）
  #     · 当前实际挂着多少条、有没有对不上的
  #   想看逐个文件清单？那是"排障"级别的事，需要时再单独做，不该拖住整份报告。
  for d in $CACHE_DIRS; do
    n=0
    [ -d "$d" ] && n=$(find "$d" -maxdepth 3 -type f \( -name '*.ttf' -o -name '*.otf' \) 2>/dev/null | grep -c .)
    echo "缓存目录=$d（$([ -d "$d" ] && echo 在 || echo 不存在)，字体文件 ${n:-0} 个）"
  done
  src=$(source_font) && echo "用的字体=$src" || echo "用的字体=没有（还没导入字体？）"
  total=0
  [ -f "$JOURNAL" ] && { total=$(grep -c . "$JOURNAL" 2>/dev/null); total=${total:-0}; }
  # 行首保持 "账本="：回归测试断言用的是 grep -c '^账本='，
  # 写成"账本里记着 N 条"会让断言假失败（内容一样，格式要对齐）。
  echo "账本=$total 条（= 本模块顶替过的下载字体数量）"
  echo "本次实测：$(do_status)"
  echo "边界：只顶替 .ttf/.otf（排除 Google Sans Code / emoji）；.ttc 不碰；关闭兼容或卸载会还原"
}

case "${1:-status}" in
  families) font_norm_file "$2" ;;
  on)     do_on; _rc=$?; bridge_into_zygote; exit $_rc ;;
  off)    do_off ;;
  status) do_status ;;
  diag)   do_diag ;;
  *) echo "用法: sh gms_cache.sh on|off|status|diag|families <字体文件>"; exit 2 ;;
esac
