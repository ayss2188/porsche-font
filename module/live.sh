#!/system/bin/sh
# ===========================================================================
# 立即生效（临时 root / 不重启就用上新字体）
#
# ── 为什么需要它 ────────────────────────────────────────────────────────────
# 我们的正常流程是：界面选字体 → fontctl.sh apply 写好挂载计划(slots.map)
# → **等下次开机**由 post-fs-data / post-mount 真正挂上去。
# 所以"换字体必须重启"一直是这个模块最大的体验问题。
#
# 这个脚本补上"不重启也能挂"的那一步。
#
# ── 技术上真正的难点（不是"挂不上去"，是"挂了没人看得见"）───────────────
# KernelSU / APatch 的 `su` 会话通常不在 init 的挂载命名空间里，
# 而 system_server（真正加载字体的进程）看的是 **init 命名空间**。
# 直接在 su 会话里 mount → 挂载只存在于自己的命名空间 → 字体一点没变。
# 所以必须用 `nsenter -t 1 -m` 进 PID 1 的命名空间再挂。
#
# ── 另外三个容易踩的坑（都处理了）────────────────────────────────────────
#   ① /system/fonts 里很多槽位是**指向 /product/fonts 的符号链接** ——
#      必须解析真实路径再挂，否则挂在链接本身上等于没挂。
#      同时要**去重**：链接和实体是同一个真实路径，挂两次会叠层。
#   ② 检测"有没有生效"必须用 `stat -L`（跟随链接），
#      否则符号链接槽位永远显示"还是原字体"。
#   ③ 挂载前把 SELinux 上下文设成 system_file:s0，
#      否则 system_server 读不到（Enforcing 下就是静默不生效）。
#
# 用法：
#   sh live.sh mount      立即挂载（把 pending 的字体用上）
#   sh live.sh unmount    撤销本次现场挂载（回到开机后的状态）
#   sh live.sh status     看现在挂了几条、生效了几条
#   sh live.sh reboot     软重启框架（让 system_server 重新读字体）
#   sh live.sh free       一步到位：挂载 + 软重启
# ===========================================================================

MODDIR=${0%/*}

# ---------------------------------------------------------------------------
# boot_id —— 跟 common.sh 里那份实现保持一致。
#   ★ 2026-10-16：live.sh 是**独立脚本**（不 source common.sh），
#     而下面写 mount.state 时要用它记"这是哪次开机写的"。
#     之前直接调 boot_id → 命令不存在 → 写成空 `boot=` →
#     mount_result 比对失败 → 界面显示"本次开机未挂载"（真机反馈）。
#     所以这里自带一份；以后就算 source 了 common.sh，command -v 也不会重复定义。
# ---------------------------------------------------------------------------
command -v boot_id >/dev/null 2>&1 || boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r\n'; }


[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/custom_font_switcher
case "$MODDIR" in .|"") MODDIR=$(pwd 2>/dev/null || echo /data/adb/modules/custom_font_switcher) ;; esac
LIB=/data/adb/custom_font_lib

# 现场挂载的清单（unmount 靠它撤干净）
MNT_LIST="$LIB/.live.mounted"

# ★ 默认**不做事**，只打印用法。
#   别把默认设成 status —— 那样打错子命令（比如 `live.sh moun`）会静默显示状态，
#   看起来"跑了但没反应"，排查时很误导人。
CMD="${1:-}"

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
# stat 要 -L：/system/fonts 下很多是符号链接，不跟随的话拿到的是链接自身的信息
_sz()  { stat -L -c '%s'   "$1" 2>/dev/null; }
_ino() { stat -L -c '%d:%i' "$1" 2>/dev/null; }

# 命名空间前缀：只有在"su 会话 ≠ init"时才需要 nsenter
NS=""
setup_ns() {
  local a b
  a=$(readlink /proc/self/ns/mnt 2>/dev/null)
  b=$(readlink /proc/1/ns/mnt 2>/dev/null)
  NS=""
  [ -n "$a" ] && [ -n "$b" ] || return 0
  [ "$a" = "$b" ] && return 0
  # 已经挂过了？那说明之前挂成功过，沿用同样的方式
  if command -v nsenter >/dev/null 2>&1; then
    NS="nsenter -t 1 -m --"
  fi
}

# 带超时的 mount（现场挂载不能卡住界面）
# ★ 用绝对路径 /system/bin/mount：`timeout` 起子进程时用的是**受限 PATH**，
#   只写 `mount` 在部分环境（busybox-w32 / 精简 PATH）里会 "can't execute 'mount'"。
#   真机上 /system/bin 一定在，沙箱里没有这个路径就退回直接用命令名。
_MOUNT_BIN=/system/bin/mount
[ -x "$_MOUNT_BIN" ] || _MOUNT_BIN=$(command -v mount 2>/dev/null || echo mount)
_UMOUNT_BIN=/system/bin/umount
[ -x "$_UMOUNT_BIN" ] || _UMOUNT_BIN=$(command -v umount 2>/dev/null || echo umount)

_to() {
  if command -v timeout >/dev/null 2>&1; then timeout 8 "$@"; else "$@"; fi
}
_mount()  { $NS _to "$_MOUNT_BIN" -o bind "$1" "$2"; }
_umount() { $NS _to "$_UMOUNT_BIN" "$1" 2>/dev/null || $NS _to "$_UMOUNT_BIN" -l "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 从 slots.map 读挂载计划
#   格式：<字体id> <相对路径> <源文件>      （第三个字段可能是空的，老格式）
# ---------------------------------------------------------------------------
MAP="$MODDIR/slots.map"

count_planned() { [ -s "$MAP" ] && grep -c . "$MAP" 2>/dev/null || echo 0; }

# 现在真实生效了几个（跟随符号链接比对 inode，跟开机流程一个判据）
count_applied() {
  local n=0 id rel src dst
  [ -s "$MAP" ] || { echo 0; return; }
  while read -r id rel src; do
    [ -n "$rel" ] || continue
    [ -n "$src" ] || src="$LIB/$id.ttf"
    dst="/$rel"
    [ -f "$dst" ] || continue
    [ "$(_ino "$src")" = "$(_ino "$dst")" ] && n=$((n + 1))
  done < "$MAP"
  echo "$n"
}

# ---------------------------------------------------------------------------
# 立即挂载
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 清掉"指向已删除文件的旧挂载"（★ 2026-10-16，真机排查出来的）
#
# 现象：目标槽位上压着一层旧挂载，而那一层的源文件已经被删了 ——
#       mountinfo 里表现为源路径后面多一个 `//deleted`：
#         ... /adb/custom_font_lib/f1792102696.ttc5_2-3//deleted /system/fonts/NotoSansCJK-Regular.ttc ...
#       此时再往同一个目标 bind 新文件会报
#         mount: '<新文件>'->'<目标>': No such file or directory
#       报错完全指错方向（两个文件都在！），很容易查半天。
#
# 为什么会出现：bind 钉住的是 inode —— 原文件名被删掉不影响已经挂上的东西，
#   所以"重新生成合集 → 旧产物被清掉"之后，旧挂载会一直留着。
#
# 判据：mountinfo 里源路径含本模块字体库 + 带 `//deleted` 标记 → 卸掉它。
# ---------------------------------------------------------------------------
do_clear_deleted_mounts() {
  local mp n=0
  # 字段 5 = 挂载点；源路径在第 10 个字段之后（挂载选项之后的那段）
  # mountinfo 字段：[1]id [2]父 [3]设备 [4]根路径 [5]挂载点 [6]选项 ...
  #   ① 「已删除」标记跟在**根路径**后面：[4] = /xxx/f1792102696.ttc5_2-3//deleted
  #      所以扫 4~6 这段（4 是根路径、5 是挂载点），别从后面找。
  #   ② ★ 判据只能用**目录名**，不能用写死的绝对路径 ——
  #      真机上 init 命名空间里 /data 是挂在根上的，根路径记成了
  #      `/adb/custom_font_lib/...`（少了 /data 前缀），
  #      用 "/data/adb/custom_font_lib/" 去匹配永远是 0。
  #   ③ 读 /proc/self/mountinfo —— 这个函数是在 do_mount 里、
  #      已经 setup_ns 之后调的，self 就是"要挂进去的那个命名空间"。
  _libname=$(printf '%s' "${LIB##*/}/")
  mps=$(awk -v nm="$_libname" '
    {
      for (i = 4; i <= 6 && i <= NF; i++) {
        if (index($i, "//deleted") > 0 && index($i, nm) > 0) { print $5; break }
      }
    }' /proc/self/mountinfo 2>/dev/null | sort -u)

  [ -n "$mps" ] || return 0
  for mp in $mps; do
    if _umount "$mp"; then
      n=$((n + 1))
    fi
  done
  [ "$n" -gt 0 ] && echo "   清掉 $n 个「指向已删除文件」的旧挂载（否则新文件挂不上去）"
  return 0
}


do_mount() {
  [ -s "$MAP" ] || { echo "ERROR:还没有挂载计划 —— 先在界面里选好字体（或点一次应用）"; exit 1; }
  setup_ns
  [ -n "$NS" ] && echo "   su 会话与 init 命名空间不同 → 用 nsenter 挂进 init"

  # ★ 先把"指向已删除文件"的旧挂载清掉 —— 否则新文件会被它挡住，
  #   而且报错是误导性的 "No such file or directory"（见上面那段说明）
  do_clear_deleted_mounts

  local id rel src dst real n=0 fail=0 skip=0 same=0 gone=0 seen="" first_fail="" first_gone=""
  : > "$MNT_LIST"

  # ★ 2026-10-16：顺手把"源文件不存在"的条目从计划里摘掉。
  #   真机暴露：slots.map 里指着一个已经不在的合集产物
  #   （/data/adb/custom_font_lib/f1792102696.ttc5_2-3），
  #   于是每次开机白挂、报告里"生效 170/172"永远差这两个。
  #   摘掉之后数字才是真的。
  MAP_CLEAN="$LIB/.slots.map.clean.$$"
  : > "$MAP_CLEAN"

  while read -r id rel src; do
    case "$rel" in ""|/*|*..*) continue ;; esac
    [ -n "$src" ] || src="$LIB/$id.ttf"
    src=$(printf '%s' "$src" | tr -d '\r')
    dst="/$rel"
    if [ ! -f "$src" ]; then
      # 源文件没了 —— 这跟"挂载失败"是两回事，单独计数并说明
      gone=$((gone + 1))
      [ -n "$first_gone" ] || first_gone="$src"
      continue
    fi
    [ -e "$dst" ] || { skip=$((skip + 1)); continue; }
    printf '%s %s %s\n' "$id" "$rel" "$src" >> "$MAP_CLEAN"
    # 解析符号链接（槽位常常是链接）；拿不到真实路径就用原路径
    real=$(readlink -f "$dst" 2>/dev/null)
    [ -n "$real" ] && [ -e "$real" ] || real="$dst"
    # 去重：同一个真实路径只挂一次（链接 + 实体是同一个文件）
    case "
$seen
" in *"
$real
"*) skip=$((skip + 1)); continue ;; esac
    seen="$seen
$real"
    # 幂等：已经指向我们的文件了就别再叠一层
    if [ "$(_ino "$src")" = "$(_ino "$real")" ]; then
      printf '%s\n' "$real" >> "$MNT_LIST"
      same=$((same + 1))
      continue
    fi
    # SELinux：不改上下文的话 system_server 在 Enforcing 下读不到
    chcon u:object_r:system_file:s0 "$src" 2>/dev/null
    if _mount "$src" "$real"; then
      _to mount -o remount,bind,ro "$real" 2>/dev/null
      printf '%s\n' "$real" >> "$MNT_LIST"
      n=$((n + 1))
    else
      fail=$((fail + 1))
      [ -n "$first_fail" ] || first_fail="$src -> $real"
    fi
  done < "$MAP"

  echo "   新挂上 $n 个，本来就在位 $same 个，跳过 $skip 个，失败 $fail 个"
  if [ "$gone" -gt 0 ]; then
    echo "   计划里有 $gone 个槽位的源文件不存在（首个：$first_gone）"
    echo "     —— 这是合集产物（.ttc 包装出来的那份）丢了，不是挂载失败。"
    echo "     —— 已从计划里摘掉（否则每次开机都白挂）。"
    echo "     —— 想换回来：在界面里重新选一次这个字体并「应用」，"
    echo "        它会重新生成合集产物，然后再点「免重启应用」。"
    # 计划文件生效：把摘掉的写回去，让数字变真
    if [ -s "$MAP_CLEAN" ]; then
      cp -f "$MAP_CLEAN" "$MAP" 2>/dev/null || cat "$MAP_CLEAN" > "$MAP" 2>/dev/null
      echo "     —— 计划已更新为 $(grep -c . "$MAP" 2>/dev/null) 个槽位"
    fi
  fi
  rm -f "$MAP_CLEAN" 2>/dev/null
  [ -n "$first_fail" ] && echo "   首个失败：$first_fail"
  echo "   现在生效：$(count_applied)/$(count_planned)"
  # ★ 把"当前生效"跟上 —— 不能等 service.sh（软重启不会跑它）。
  #   无条件调用：这件事本身幂等（pending=active 时它什么都不改），
  #   而"本来就在位 / 全部跳过"这两种情况也同样该把状态对齐 ——
  #   它们说明"挂载早已生效，只是状态没同步"。
  do_sync_state
  [ "$fail" = 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 撤销现场挂载
#
# ★ 2026-10-16 修一个真 bug：**不能按"源属于字体库"来撤**。
#   实测开机挂载（mount.sh）用的源**也是** $LIB/xxx.ttf —— 和现场挂载同一个源。
#   按源撤 = 把开机挂的 28 个槽位也一起撤掉 →
#     计划里变成"生效 0/N"，而框架不会重新读（umount 不改内存里的字体）→
#     用户看到"撤销成功"但字还是新的，彻底懵。
#
#   正确做法：**只撤我们这次真正挂过的那些目标路径** —— 就是 do_mount 写下的
#   $MNT_LIST。它记的是解析过符号链接的**真实目标路径**，精确、不会误伤。
# ---------------------------------------------------------------------------
do_unmount() {
  setup_ns
  local n=0 pass=0 mp mps
  if [ ! -s "$MNT_LIST" ]; then
    echo "   没有现场挂载可撤（或用的是旧版本，清单已丢）"
    echo "   现在生效：$(count_applied)/$(count_planned)"
    return 0
  fi
  while [ "$pass" -lt 8 ]; do
    mps=$(sort -u "$MNT_LIST" 2>/dev/null)
    [ -n "$mps" ] || break
    local did=0
    for mp in $mps; do
      [ -n "$mp" ] || continue
      # 只在"确实挂着我们东西"时才撤（避免撤掉用户自己/别的模块的挂载）
      if _umount "$mp"; then n=$((n + 1)); did=1; fi
    done
    [ "$did" = 1 ] || break
    pass=$((pass + 1))
  done
  rm -f "$MNT_LIST" 2>/dev/null
  echo "   已撤销 $n 个现场挂载"
  echo "   现在生效：$(count_applied)/$(count_planned)（开机挂的那些没动）"
  do_sync_state
  echo "   ⚠️ 屏幕上的字不会立刻变回去 —— 框架已经把字体读进内存了，"
  echo "      要再软重启一次才会看到旧字体（用下面的「撤销并生效」一步做完）"
}


# ---------------------------------------------------------------------------
# 让"当前生效"跟上（★ 2026-10-16 修一个真机问题）
#
# 背景：模块里"待生效 → 当前生效"的迁移是 `fontctl.sh sync` 做的，
#   而它只在 **service.sh（开机完成）** 里被调用一次。
#   软重启只重启 zygote，service.sh 不会再跑 ——
#   于是：字体已经挂上了、界面也重读了，可 `active_font` 还是旧值，
#   界面就显示"当前实际生效 = 旧字体 / 待生效 = 新字体"，
#   用户以为没换成功（真机反馈过）。
#
# 所以：挂载（或撤销）**成功之后**，就地做一次迁移，不依赖开机流程。
# 只改两个文件 + 模块描述，很快也不危险。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 重算挂载统计（★ 2026-10-16 修「免重启后数字不对」）
#
# 为什么需要：`mount.state` 是 mount.sh **开机时**写的快照
#   （ok= fail= stage= same= skip=），而 `mount_result()` 只校验 boot_id ——
#   软重启不改 boot_id，所以这份快照一直「有效」，
#   界面上的「实际挂载」就永远停在开机那一刻。
#   真机反馈：字体明明已经生效，却显示「本次开机未改动（已就位 141，跳过 2）」，
#   而「实际生效」是 0/143（也是缓存里的旧结果）。
#
# 这里按**当前真实情况**重算一遍：逐条比对 inode（跟 payload_verify 同一判据）。
#   same = 源与目标同 inode（已经挂好了）
#   skip = 源不存在、或目标不存在的数目
# 顺手把 verify 缓存删掉，让「实际生效」立刻重新数。
# ---------------------------------------------------------------------------
do_recount_mount_state() {
  local map="$MODDIR/slots.map"
  [ -s "$map" ] || return 0
  local id rel src a b hit=0 skip=0
  while read -r id rel src || [ -n "$rel" ]; do
    rel=$(printf '%s' "$rel" | tr -d '\r')
    case "$rel" in ""|/*|*..*) continue ;; esac
    [ -n "$src" ] || src="$LIB/$id.ttf"
    src=$(printf '%s' "$src" | tr -d '\r')
    [ -f "$src" ] || { skip=$((skip + 1)); continue; }
    [ -f "/$rel" ] || { skip=$((skip + 1)); continue; }
    a=$(stat -L -c '%d:%i' "$src" 2>/dev/null)
    b=$(stat -L -c '%d:%i' "/$rel" 2>/dev/null)
    [ -n "$a" ] && [ "$a" = "$b" ] && hit=$((hit + 1))
  done < "$map"

  {
    echo "boot=$(boot_id 2>/dev/null)"
    echo "ok=0"
    echo "fail=0"
    echo "stage=live"
    echo "same=$hit"
    echo "skip=$skip"
  } > "$MODDIR/mount.state" 2>/dev/null
  rm -f "$LIB/.verify.cache" 2>/dev/null
  echo "   现在真实生效：$hit 个（跳过 $skip 个）"
}


do_sync_state() {
  # 先把挂载统计刷成现在的事实，再迁移状态
  # （否则界面读的还是 mount.sh 开机时写的快照）
  do_recount_mount_state
  if [ -x "$MODDIR/fontctl.sh" ] || [ -f "$MODDIR/fontctl.sh" ]; then
    _s=$(sh "$MODDIR/fontctl.sh" sync 2>&1)
    if [ -n "$_s" ]; then echo "   状态已更新（$(printf '%s' "$_s" | tr '\n' ' ' | cut -c1-60)）"
    else echo "   状态已更新（当前生效 = 待生效）"; fi
  else
    # 退路：fontctl.sh 不在就自己动手（跟它 sync 分支做的事一致）
    if [ -f "$MODDIR/pending_font" ]; then
      cp -f "$MODDIR/pending_font" "$MODDIR/active_font" 2>/dev/null
      cp -f "$MODDIR/active_font" "$LIB/last_selection" 2>/dev/null
      echo "   状态已更新（当前生效 = 待生效）"
    fi
  fi
}


# ---------------------------------------------------------------------------
# 软重启框架：让 system_server 重新读字体
#   注意：这不是"重启"，内核没动、进程都还在，几秒到几十秒就回来
# ---------------------------------------------------------------------------
do_softreboot() {
  # 两条路，按"温和程度"排：
  #   ① setprop ctl.restart zygote —— 让 init 重启 zygote（绝大多数机器够用）
  #   ② killall system_server     —— 少数机型上 ① 不生效时的兜底
  #      它是 Android 上重启框架的标准手段，但有极少数机型会卡住不回来，
  #      那种情况长按电源键强制重启即可（挂载不写系统分区，字体回原样）。
  # 之所以保留 ②：没有兜底的话，① 失效时用户只能自己去重启 —— 比有兜底差。
  if setprop ctl.restart zygote 2>/dev/null; then
    echo "   已通知框架重启（zygote）—— 温和的那种"
    echo "   屏幕会黑一下，约 30~60 秒后回到锁屏。这期间别乱点。"
    echo "   如果超过 2 分钟没回来：长按电源键强制重启（字体回原样，不会坏）。"
  elif killall system_server 2>/dev/null; then
    echo "   已重启框架（killall system_server）—— 你的机型上 zygote 那条不生效，走了兜底"
    echo "   屏幕会黑一下，约 30~60 秒后回到锁屏。"
    echo "   如果超过 2 分钟没回来：长按电源键强制重启（字体回原样，不会坏）。"
  else
    echo "ERROR:两条路都不通（setprop / killall 都失败）"
    echo "       请手动重启手机 —— 重启后字体会按计划生效，不会出问题。"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
do_status() {
  setup_ns
  local n_live=0
  [ -s "$MNT_LIST" ] && n_live=$(grep -c . "$MNT_LIST" 2>/dev/null)
  echo "   挂载计划：$(count_planned) 个槽位"
  echo "   已经生效：$(count_applied) 个"
  echo "   现场挂载：${n_live:-0} 个（本次"不重启生效"挂的，可单独撤销）"
  echo "   命名空间：$( [ -n "$NS" ] && echo '需要 nsenter（su ≠ init）' || echo '与 init 相同' )"
}

case "$CMD" in
  mount)     do_mount ;;
  unmount)   do_unmount ;;
  reboot)    do_softreboot ;;
  free)
    do_mount || { echo "❌ 挂载失败，已终止（没有软重启）"; exit 1; }
    do_softreboot
    ;;
  unfree)
    # 撤销 + 让框架重读（一步回到旧字体）—— 撤销后**必须**重读才看得到变化
    do_unmount || { echo "❌ 撤销有问题，已终止（没有软重启）"; exit 1; }
    do_softreboot
    ;;
  status)    do_status ;;
  *)
    echo "用法: sh live.sh <子命令>"
    echo "  mount     立即挂载（把当前计划里的字体挂上去，可随时撤销）"
    echo "  unmount   撤销现场挂载（只撤本次挂的，不动开机挂的那些）"
    echo "  reboot    软重启框架（让系统重新读字体；屏幕会黑一下）"
    echo "  free      一步到位：挂载 + 软重启"
    echo "  unfree    一步到位：撤销 + 软重启（变回原字体）"
    echo "  status    看计划数 / 生效数 / 现场挂载数"
    [ -n "$CMD" ] && { echo ""; echo "  ⚠️ 不认识的子命令：$CMD"; exit 1; }
    ;;
esac
