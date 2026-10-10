#!/system/bin/sh
# mount.sh - 模块自带挂载（不依赖元模块，覆盖 my_product / mi_ext 等厂商分区）
#
# 原理：开机时把字体库里的字体文件直接 bind mount 到每个真实字体槽上，
#       不在模块目录生成任何副本（一份字体，零额外占用，也不受模块目录是镜像分区的影响）；
#       模块带 skip_mount，管理器不会重复挂载。
#   Magisk          -> post-fs-data 阶段挂载（Magisk 没有 post-mount 阶段）
#   KernelSU/APatch -> post-mount 阶段挂载（在元模块等挂载之后，避免被目录级挂载盖住）
#
# slots.map 每行 "<字体id> <目标路径>"，目标路径相对 /，如 f1700000000 system/fonts/Roboto-Regular.ttf
#
# 用法（source 后调用；需先 source common.sh）：
#   payload_mount <模块目录> <阶段名>   挂载，结果写入 mount.state
#   payload_verify <模块目录>          检查当前可见的系统字体是否就是本模块的文件，输出 "生效数 总数"

# 带超时执行：没有 timeout、或者 timeout 用不了（个别 ROM 上会返回 127）就直接执行。
# 目的只有一个 —— 任何一次 mount 都不允许把阻塞的 post-fs-data 阶段卡死。
_to() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 "$@"; _to_rc=$?
    [ "$_to_rc" = 127 ] || return $_to_rc
  fi
  "$@"
}

payload_mount() {
  local moddir="$1" id rel src dst err ok=0 fail=0 skip=0 same=0
  local map="$moddir/slots.map"
  [ -s "$map" ] || return 0
  while read -r id rel src || [ -n "$rel" ]; do
    rel=$(printf '%s' "$rel" | tr -d '\r')
    case "$id" in ""|*[!A-Za-z0-9_]*) continue ;; esac
    case "$rel" in ""|/*|*..*) continue ;; esac
    # 第三个字段 = 这个槽位挂哪个文件（.ttc 槽位挂的是包好的"多 face TTC"）；
    # 老格式只有两个字段，那就用字体库里的 $id.ttf
    [ -n "$src" ] || src="$LIB/$id.ttf"
    src=$(printf '%s' "$src" | tr -d '\r')
    dst="/$rel"
    if [ ! -f "$src" ] || [ ! -f "$dst" ]; then
      skip=$((skip+1)); continue
    fi
    # 幂等：已经指向我们的文件了就别再叠一层
    # （post-fs-data 和 post-mount 万一都跑到，或者被重复调用，会叠出多层挂载且再也数不清）
    if [ "$(stat -L -c '%d:%i' "$src" 2>/dev/null)" = "$(stat -L -c '%d:%i' "$dst" 2>/dev/null)" ]; then
      same=$((same+1)); continue
    fi
    # 每个挂载加超时：万一某个槽位卡住，绝不能让整个开机阶段跟着卡死（post-fs-data 是阻塞阶段）
    # 成败看退出码，不看有没有输出 —— mount 成功时也可能打好几行警告
    err=$(_to mount -o bind "$src" "$dst" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then
      _to mount -o remount,bind,ro "$dst" 2>/dev/null
      ok=$((ok+1))
    else
      fail=$((fail+1))
      echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 绑定失败 $src -> $dst : ${err:-未知错误}" >> "$LIB/mount.log" 2>/dev/null
    fi
  done < "$map"
  echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 阶段=${2:-unknown} 成功=$ok 失败=$fail 跳过=$skip 已就位=$same" >> "$LIB/mount.log" 2>/dev/null
  if [ -f "$LIB/mount.log" ]; then
    tail -n 100 "$LIB/mount.log" > "$LIB/mount.log.tmp.$$" 2>/dev/null && mv -f "$LIB/mount.log.tmp.$$" "$LIB/mount.log" 2>/dev/null
  fi
  if command -v beat >/dev/null 2>&1; then
    beat mount "phase=${2:-unknown} ok=$ok fail=$fail skip=$skip same=$same"
  fi
  {
    echo "boot=$(boot_id)"
    echo "ok=$ok"
    echo "fail=$fail"
    echo "skip=$skip"
    echo "same=$same"
    echo "stage=${2:-unknown}"
    echo "time=$(date +%s)"
  } > "$moddir/mount.state"
}

payload_verify() {
  local moddir="$1" id rel a b n=0 hit=0 mode
  mode=$(tr -d '[:space:]' 2>/dev/null < "$moddir/payload.mode")
  [ -s "$moddir/slots.map" ] || { echo "0 0"; return 0; }
  while read -r id rel src || [ -n "$rel" ]; do
    rel=$(printf '%s' "$rel" | tr -d '\r')
    case "$rel" in ""|/*|*..*) continue ;; esac
    # 第三个字段才是真正挂上去的文件（.ttc 槽位挂的是包好的多 face TTC）
    [ -n "$src" ] || src="$LIB/$id.ttf"
    src=$(printf '%s' "$src" | tr -d '\r')
    n=$((n+1))
    if [ "$mode" = manager ]; then
      # 管理器挂载会经过 overlay/tmpfs，inode 不同，只能比较大小
      a=$(stat -L -c '%s' "$moddir/$(mgr_path "$rel")" 2>/dev/null)
      b=$(stat -L -c '%s' "/$rel" 2>/dev/null)
    else
      # bind mount 后两边的 设备号:inode 完全一致
      a=$(stat -L -c '%d:%i' "$src" 2>/dev/null)
      b=$(stat -L -c '%d:%i' "/$rel" 2>/dev/null)
    fi
    [ -n "$a" ] && [ "$a" = "$b" ] && hit=$((hit+1))
  done < "$moddir/slots.map"
  echo "$hit $n"
}
