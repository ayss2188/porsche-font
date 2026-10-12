#!/system/bin/sh
# 同名克隆：把【目标的 name 表】装到【我们的字体】上
#   = 字形是你的字体、对外自称是目标字体（例如 Google Sans）
#
# 为什么要它（真机结论）：GMS 会核对字体身份（家族名）。直接挂我们的原件，GMS 一看名字不对
#   就不认 / 自己再下一份 → 商店始终是 Google Sans。参考实现就是靠 "identity-compatible clone"
#   （copy_target_names）解决这一步的。
#
# 做法（极小改动，不重建整个字体）：
#   ① 取出目标字体的 name 表字节；
#   ② 追加到我们字体文件的末尾（4 字节对齐）；
#   ③ 只改我们字体【表目录】里 name 那一条的 offset/length（8 字节）→ 指向追加的那份。
#   字形 / hmtx / cmap 等全部照旧；原文件绝不修改；输出到你指定的路径。
#
# 用法：
#   sh nameclone.sh clone <我们的字体> <目标字体> <输出文件>
#   sh nameclone.sh families <字体>
#   sh nameclone.sh verify <克隆体> <目标字体>
LIB=${LIB:-/data/adb/custom_font_lib}
LOG="$LIB/.nameclone.log"
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

u16() { od -An -tu1 -j "$2" -N 2 "$1" 2>/dev/null | awk '{print $1*256+$2}'; }
u32() { od -An -tu1 -j "$2" -N 4 "$1" 2>/dev/null | awk '{print (($1*256+$2)*256+$3)*256+$4}'; }

# 8 个字节的大端 offset+length（用 awk 写二进制，避免嵌套 printf 的转义坑）
be_off_len() {
  awk -v o="$1" -v l="$2" 'BEGIN{
    printf "%c%c%c%c%c%c%c%c",
      int(o/16777216)%256, int(o/65536)%256, int(o/256)%256, o%256,
      int(l/16777216)%256, int(l/65536)%256, int(l/256)%256, l%256 }'
}

# 找 name 表：输出 "<表目录里该条目的偏移> <表偏移> <表长度>"
name_entry() {
  local f="$1" num t p hex
  num=$(u16 "$f" 4)
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  t=0
  while [ "$t" -lt "$num" ]; do
    p=$(( 12 + t * 16 ))
    hex=$(od -An -tx1 -j "$p" -N 4 "$f" 2>/dev/null | tr -d ' \n')
    if [ "$hex" = "6e616d65" ]; then
      printf '%s %s %s\n' "$p" "$(u32 "$f" $((p + 8)))" "$(u32 "$f" $((p + 12)))"
      return 0
    fi
    t=$((t + 1))
  done
  return 1
}

# 家族名（nameID 1/16，归一化后一行一个）
families() {
  local f="$1" e noff nlen
  e=$(name_entry "$f") || return 1
  set -- $e
  noff=$2
  nlen=$3
  [ "$nlen" -gt 6 ] 2>/dev/null || return 1
  od -An -tu1 -v -j "$noff" -N "$nlen" "$f" 2>/dev/null | awk '
    { for (i=1;i<=NF;i++) b[n++]=$i+0 }
    function u16(p){ return b[p]*256+b[p+1] }
    function chr(c){ return (c>=32 && c<127) ? sprintf("%c",c) : "" }
    END {
      cnt=u16(2); so=u16(4)
      for (i=0;i<cnt;i++) {
        r=6+i*12
        if (r+11>=n) break
        pid=u16(r); nid=u16(r+6); len=u16(r+8); off=u16(r+10)
        if (nid!=1 && nid!=16) continue
        sp=so+off
        if (len<=0 || sp+len>n) continue
        s=""
        if (pid==3) { for (k=0;k+1<len;k+=2) s=s chr(b[sp+k]*256+b[sp+k+1]) }
        else        { for (k=0;k<len;k++)      s=s chr(b[sp+k]) }
        gsub(/[^A-Za-z0-9]/,"",s)
        if (s!="") print tolower(s)
      }
    }'
}

do_clone() {
  local src="$1" tgt="$2" out="$3" se te sp soff slen toff tlen ssize pad newoff
  [ -f "$src" ] || { echo "ERROR:找不到源字体 $src"; return 1; }
  [ -f "$tgt" ] || { echo "ERROR:找不到目标字体 $tgt"; return 1; }
  se=$(name_entry "$src") || { echo "ERROR:源字体没有 name 表"; return 1; }
  te=$(name_entry "$tgt") || { echo "ERROR:目标字体没有 name 表"; return 1; }
  set -- $se; sp=$1; soff=$2; slen=$3
  set -- $te; toff=$2; tlen=$3
  [ "$tlen" -gt 6 ] 2>/dev/null || { echo "ERROR:目标 name 表长度异常"; return 1; }
  ssize=$(wc -c < "$src" 2>/dev/null)
  case "$ssize" in ''|*[!0-9]*) echo "ERROR:读不到源文件大小"; return 1 ;; esac
  pad=$(( (4 - (ssize % 4)) % 4 ))
  newoff=$(( ssize + pad ))
  tmo 60 dd if="$src" of="$out" bs=65536 2>/dev/null || return 1
  if [ "$pad" -gt 0 ]; then dd if=/dev/zero bs=1 count="$pad" >> "$out" 2>/dev/null; fi
  tmo 60 dd if="$tgt" bs=1 skip="$toff" count="$tlen" >> "$out" 2>/dev/null || return 1
  be_off_len "$newoff" "$tlen" | dd of="$out" bs=1 seek=$((sp + 8)) conv=notrunc 2>/dev/null || return 1
  [ "$(wc -c < "$out" 2>/dev/null)" -gt 1024 ] || { echo "ERROR:输出太小"; return 1; }
  chmod 644 "$out" 2>/dev/null
  blog "克隆：$src ← ${tgt##*/} 的 name 表 → $out"
  printf 'OK：同名克隆已生成（%s 字节）\n  字形 = 你的字体；身份 = %s\n' "$(wc -c < "$out" 2>/dev/null)" "$(families "$tgt" | head -n1)"
  return 0
}

case "${1:-}" in
  clone)    do_clone "$2" "$3" "$4" ;;
  families) families "$2" ;;
  verify)
    a=$(families "$2" | head -n1); b=$(families "$3" | head -n1)
    echo "克隆体身份：$(families "$2" | tr '\n' ' ')"
    echo "目标身份  ：$(families "$3" | tr '\n' ' ')"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "✅ 身份一致"; else echo "❌ 身份不一致"; fi
    ;;
  *) echo "用法: sh nameclone.sh clone <我们的字体> <目标字体> <输出> | families <字体> | verify <克隆体> <目标>"; exit 2 ;;
esac
