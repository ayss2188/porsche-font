#!/system/bin/sh
# 开机完成后：撤掉开机保护标记，把 pending_font 确认为 active_font，并检查挂载是否执行
#
# 【这里有一条最关键的规则】只有在真的「开机完成」时才撤掉 .booting 保护标记：
#   标记还在 = 下一次 post-fs-data 会触发救援（撤掉字体、恢复成"无字体"），
#   这是"换了字体开不了机"时唯一的自动救命手段。
#   以前这里无条件删除（哪怕等了 10 分钟也没 boot_completed），救援就永远等不到机会，
#   同一个坏字体每次开机都再挂一次 = 永久开不了机。所以：只有 boot_completed=1 才删。

MODDIR=${0%/*}
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

# 等开机完成，最多等 10 分钟（避免极端情况下这个循环永远挂着，心跳也就永远不写）
# 10 秒查一次就够：别让 getprop/sleep 一直在后台刷（有人看进程列表会觉得莫名其妙）
i=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  shutting_down && exit 0          # 正在关机/重启：立刻收工，别拖住关机流程
  sleep 10
  i=$((i+10))
  [ "$i" -ge 600 ] && break
done
shutting_down && exit 0

rm -f "$MODDIR/mount_missed"
[ "$(getprop sys.boot_completed)" = "1" ] && rm -f "$MODDIR/.booting"
# 开机真的完成了 -> 把"连续失败"计数清零：说明这个字体在这台机器上是能用的。
# （计数只在 post-fs-data 的救援分支里加，两次就会写 disable 停用模块，宁可保守。）
[ "$(getprop sys.boot_completed)" = "1" ] && rm -f "$LIB/rescue_count" 2>/dev/null

# ---------------------------------------------------------------------------
# 开机完成后补一次完整计划（含 .ttc 合集合成）。
# 为什么放这儿、不放 post-fs-data：post-fs-data 是**阻塞**阶段，合成几十 MB 的合集
# 会把老设备的开机动画卡住（真机反馈过）。这里开机已经起来了，慢一点没人受影响。
# 只补"确实没有计划"的情况：正常情况下计划在 apply 时就写好了，这里什么都不做。
# ---------------------------------------------------------------------------
if [ -f "$MODDIR/fontctl.sh" ] && [ ! -s "$MODDIR/slots.map" ]; then
  _p2=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")
  case "$_p2" in
    ""|none) ;;
    *)
      if [ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" != manager ]; then
        beat service "计划为空，开机后补做完整计划（含合集）"
        sh "$MODDIR/fontctl.sh" apply "$_p2" >/dev/null 2>&1
        beat service "补做结果：计划 $(grep -c . "$MODDIR/slots.map" 2>/dev/null) 个槽位（下次开机生效）"
      fi
      ;;
  esac
fi

# 自带挂载模式下选了字体，但本次开机没有挂载记录 -> 提示用户
# （主挂载在 post-fs-data，所以这一般意味着"Root 管理器开机时没运行模块脚本"：
#   临时 root / 需要手动再激活一次的 root / 模块被禁用 / 安全模式）
P=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")
# 心跳：证明 service 阶段确实被执行了（诊断用）
beat service "pending=$P boot_completed=$(getprop sys.boot_completed 2>/dev/null)"
case "$P" in
  ""|none) ;;
  *)
    if [ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" != manager ] && \
       [ "$(sed -n 's/^boot=//p' "$MODDIR/mount.state" 2>/dev/null)" != "$(boot_id)" ]; then
      touch "$MODDIR/mount_missed"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 清理"设备上已不存在"的槽位记录
#
# 为什么会有失效记录：计划是按**当时那台设备**的字体目录生成的。之后换了 ROM、
# 系统更新删掉了某些字体文件，或者装过实验版留下了别的格式，slots.applied /
# slots.map 里就会留着指向**已经不存在的文件**的条目。这些条目永远不会生效，
# 留着只有坏处：
#   · 界面「已替换槽位」虚高 —— 用户以为替换了一大堆，其中一部分根本不存在；
#   · 挂载时这些槽位只能记成"跳过"，看着像出错。
# 所以开机完成后清掉。
#
# 放在 service 阶段（开机已完成）：post-fs-data 是阻塞阶段，不在那里写文件。
# 用临时文件 + mv 替换，避免写一半被打断留下残缺清单。
# 只在"自带挂载"模式做：管理器模式下 slots.applied 是模块内副本的清单，判据不同。
# ---------------------------------------------------------------------------
prune_dead_slots() {
  local f tmp n_before n_after line rel
  [ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" = manager ] && return 0
  for f in "$MODDIR/slots.applied" "$MODDIR/slots.map"; do
    [ -s "$f" ] || continue
    n_before=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    tmp="$f.prune.$$"
    : > "$tmp" 2>/dev/null || continue
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      if [ "$f" = "$MODDIR/slots.map" ]; then
        # map 一行是 "<字体id> <目标路径> [源文件]"：目标路径**永远是第 2 个字段**。
        # 第 3 个字段是 .ttc 实验版留下的"这个槽位挂哪个文件"，不是路径 ——
        # 拿它当路径会把那台机器上的 .ttc 槽位当成失效记录删掉。
        # 用参数展开取字段（不用 set -- / cut），避免路径里的 * 被当通配符展开、也少开进程。
        rel=${line#* }
        rel=${rel%% *}
      else
        # applied 一行就是一个目标路径
        rel="$line"
      fi
      rel=$(printf '%s' "$rel" | tr -d '\r')
      case "$rel" in ""|/*|*..*) continue ;; esac
      [ -f "/$rel" ] && printf '%s\n' "$line" >> "$tmp"
    done < "$f"
    n_after=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')
    if [ "$n_after" != "$n_before" ]; then
      mv -f "$tmp" "$f" 2>/dev/null
      beat service "清理失效槽位：${f##*/} $n_before → $n_after 行"
    else
      rm -f "$tmp" 2>/dev/null
    fi
  done
}
prune_dead_slots

# 关机中就别再动模块目录了（sync/relink 会写文件，正好撞上 init 卸载 /data）
shutting_down && exit 0
sh "$MODDIR/fontctl.sh" sync
shutting_down && exit 0
sh "$MODDIR/fontctl.sh" relink >/dev/null 2>&1
MISSED=0
[ -f "$MODDIR/mount_missed" ] && MISSED=1
beat service "finish active=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/active_font") missed=$MISSED"
