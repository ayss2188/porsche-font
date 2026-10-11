#!/system/bin/sh
# mount.sh - 模块自带挂载（不依赖元模块，覆盖 my_product / mi_ext 等厂商分区）
#
# 原理：开机时把字体库里的字体文件直接 bind mount 到每个真实字体槽上，
#       不在模块目录生成任何副本（一份字体，零额外占用，也不受模块目录是镜像分区的影响）；
#       模块带 skip_mount，管理器不会重复挂载。
#   所有管理器      -> post-fs-data 阶段挂载（唯一保证会跑的阶段，主挂载点）
#   KernelSU/APatch -> 若支持 post-mount，那一步会再做一次幂等的「二次修补」
#
# slots.map 每行 "<字体id> <目标路径> [挂哪个文件]"：目标路径**永远是第 2 个字段**，
# 目标路径相对 /，如 f1700000000 system/fonts/Roboto-Regular.ttf
# 第 3 个字段只有 .ttc 合集槽位会写（挂的是包好的多 face TTC）；老格式只有两个字段。
# ⚠ 任何解析 slots.map 的地方都固定取第 2 个字段 —— 别按"字段数≥3 就取第 3 字段"，
#   那会把源文件路径当目标路径，把 .ttc 槽位误判成失效记录（真机上踩过）。
#
# 用法（source 后调用；需先 source common.sh）：
#   payload_mount <模块目录> <阶段名>   挂载，结果写入 mount.state
#   payload_verify <模块目录>          检查当前可见的系统字体是否就是本模块的文件，输出 "生效数 总数"

# 带超时执行：没有 timeout、或者 timeout 用不了（个别 ROM 上会返回 127）就直接执行。
# 目的只有一个 —— 任何一次 mount 都不允许把阻塞的 post-fs-data 阶段卡死。
# _to_s <秒数> <命令...>；_to 是"默认 5 秒"的简写。_to_n / _to_rc 是临时变量。
_to_s() {
  _to_n="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_to_n" "$@"; _to_rc=$?
    [ "$_to_rc" = 127 ] || return $_to_rc
  fi
  # 没有可用的 timeout：自己兜底 —— 后台跑 + 每秒看一眼，超时就 kill。
  # 这一步不能赌：post-fs-data 是**阻塞**阶段，一个卡住的命令会把开机拖死
  # （老设备上就是"卡开机动画"）。busybox 的 timeout 在个别 ROM 上会返回 127，
  # 原来的写法在这种情况下等于完全不设超时。
  "$@" &
  _to_pid=$!
  _to_i=0
  while [ "$_to_i" -lt "$_to_n" ]; do
    if ! kill -0 "$_to_pid" 2>/dev/null; then
      wait "$_to_pid" 2>/dev/null
      return $?
    fi
    sleep 1
    _to_i=$((_to_i + 1))
  done
  kill -9 "$_to_pid" 2>/dev/null
  wait "$_to_pid" 2>/dev/null
  return 124
}
_to() { _to_s 5 "$@"; }

payload_mount() {
  local moddir="$1" id rel src dst err ok=0 fail=0 skip=0 same=0
  local map="$moddir/slots.map"
  # 没有挂载计划时**不要静默 return** —— 那会一个槽位都不挂、日志里什么都没有，
  # 诊断报告只能写"本次开机未挂载"，用户无从下手。先在挂载前把计划补回来，
  # 让"更新后第一次重启"就直接生效，而不是要用户再重启一次。
  #
  # 边界（都要判）：
  #   · 只在"选了字体"时才补；pending_font 为空/none 就保持不动
  #   · manager 模式不补 —— 那是管理器挂载，slots.map 本来就不该有内容
  #   · 找不到 fontctl.sh 就不补（老版本模块没有这个文件）
  #   · 补计划这一步自己在阻塞的 post-fs-data 里跑，所以给它一个上限（20 秒）；
  #     真被掐掉的后果和"不补"完全一样（计划仍为空、本次不挂载），不会更糟。
  #   · **开机阶段只补"轻"的那部分**：CFS_NO_TTC=1 让这一次跳过 .ttc 合集的合成
  #     （那一步要读写几十 MB，老设备上能拖很久，正是"卡开机动画"的来源之一）。
  #     合集没换不影响这次开机：本来一个槽位都没挂上，现在至少把普通字体挂上；
  #     完整的一次（含合集）由 service 阶段在开机完成后补做。
  if [ ! -s "$map" ]; then
    local _p _pm
    _p=$(tr -d '[:space:]' 2>/dev/null < "$moddir/pending_font")
    case "$_p" in ""|none) return 0 ;; esac
    _pm=$(tr -d '[:space:]' 2>/dev/null < "$moddir/payload.mode")
    [ "$_pm" = manager ] && return 0
    [ -f "$moddir/fontctl.sh" ] || return 0
    echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 阶段=${2:-unknown} 没有挂载计划（slots.map 为空），尝试重新生成（只补轻量部分，跳过合集合成）" >> "$LIB/mount.log" 2>/dev/null
    CFS_NO_TTC=1 _to_s 20 sh "$moddir/fontctl.sh" apply "$_p" >/dev/null 2>&1
    _rc=$?
    if [ ! -s "$map" ]; then
      # 退出码 124 = 被上面那个 20 秒上限掐断了
      echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 阶段=${2:-unknown} 重新生成后仍然没有挂载计划（退出码 $_rc），本次不挂载（请把诊断报告发给作者）" >> "$LIB/mount.log" 2>/dev/null
      return 0
    fi
    echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 阶段=${2:-unknown} 已补上挂载计划（$(grep -c . "$map" 2>/dev/null) 个槽位），继续挂载" >> "$LIB/mount.log" 2>/dev/null
  fi
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
  local moddir="$1" id rel a b n=0 hit=0 mode key ck
  # ---------------------------------------------------------------------------
  # 结果缓存：界面每次刷新、诊断报告都会调它，而每个槽位要 1~2 次 stat ——
  # 24 个槽位就是几十个进程。结果只跟「哪次开机 + 计划文件 + 挂载记录」有关，
  # 所以拿这三样当 key（任一变了就重算）。命中时只要 3 个进程，快十倍左右。
  # 注意：手工在系统里改挂载、而这三个文件都没动的话，缓存会滞后到下次开机 —— 可以接受。
  # ---------------------------------------------------------------------------
  key="$(boot_id)_$(stat -c '%Y-%s' "$moddir/slots.map" 2>/dev/null)_$(stat -c '%Y' "$moddir/mount.state" 2>/dev/null)"
  if [ -s "$LIB/.verify.cache" ]; then
    ck=$(sed -n '1p' "$LIB/.verify.cache" 2>/dev/null)
    if [ -n "$key" ] && [ "$ck" = "$key" ]; then
      sed -n '2p' "$LIB/.verify.cache" 2>/dev/null
      return 0
    fi
  fi
  mode=$(tr -d '[:space:]' 2>/dev/null < "$moddir/payload.mode")
  [ -s "$moddir/slots.map" ] || { echo "0 0"; return 0; }
  while read -r id rel src || [ -n "$rel" ]; do
    rel=$(printf '%s' "$rel" | tr -d '\r')
    case "$rel" in ""|/*|*..*) continue ;; esac
    # 第三个字段才是真正挂上去的文件（.ttc 槽位挂的是包好的多 face TTC）
    [ -n "$src" ] || src="$LIB/$id.ttf"
    src=$(printf '%s' "$src" | tr -d '\r')
    # 目标在设备上不存在时不计数。
    # 否则"总数"里会混进一批这台设备上根本没有的槽位（换了 ROM、系统更新删了字体文件、
    # 或装过实验版留下的老计划），界面上就成了「实际生效 24 / 62」——
    # 看着像只成功了一半，其实这台设备上只有 24 个真实槽位。真机反馈过这个困惑点。
    [ -f "/$rel" ] || continue
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
  if [ -n "$key" ]; then
    { printf '%s\n' "$key"; printf '%s %s\n' "$hit" "$n"; } > "$LIB/.verify.cache" 2>/dev/null
  fi
}
