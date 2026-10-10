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

# 自带挂载模式下选了字体，但本次开机没有挂载记录 -> 提示用户（多为管理器不支持 post-mount）
P=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")
# 心跳：证明 service 阶段确实被执行了（诊断用）
beat service "pending=$P boot_completed=$(getprop sys.boot_completed 2>/dev/null)"
case "$P" in
  ""|none) ;;
  *)
    # ---------------------------------------------------------------------
    # 自愈：选了配色、但**挂载计划是空的**（slots.map 没有内容）→ 重新生成一次。
    #
    # 真机上出过一次：刷入时 apply 报了 OK，但 slots.map 没落盘（原因未查明），
    # 于是开机时 payload_mount 第一行就返回（[ -s "$map" ] || return 0），
    # 一个槽位都挂不上，界面只显示"本次开机未挂载"，用户无从下手。
    # 这里补一次：本开机仍然是没挂上，但下次重启就会生效，用户只需多重启一次。
    # ---------------------------------------------------------------------
    if [ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" != manager ] && \
       [ ! -s "$MODDIR/slots.map" ]; then
      beat service "slots.map 是空的，尝试重新生成（$P）"
      sh "$MODDIR/fontctl.sh" apply "$P" >/dev/null 2>&1
      beat service "重新生成结果：slots.map $([ -s "$MODDIR/slots.map" ] && echo 已生成 || echo 仍为空)"
    fi
    if [ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" != manager ] && \
       [ "$(sed -n 's/^boot=//p' "$MODDIR/mount.state" 2>/dev/null)" != "$(boot_id)" ]; then
      touch "$MODDIR/mount_missed"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 清理"设备上已不存在"的槽位记录
#
# 真机踩到的：slots.applied 里有 62 行，其中 31 行指向的字体文件在本机根本不存在
# （是更早某次规划留下的残留）。后果：
#   · 界面上「已替换槽位」显示 62 —— 虚高一倍，用户以为成功了一半；
#   · 挂载时那 31 个槽位只能记成"跳过"，看着像出错。
# 这些条目永远不会生效，留着只有坏处，所以开机完成后清掉。
# 放在 service 阶段（开机已完成）：post-fs-data 是阻塞阶段，不在这里写文件。
# 用临时文件 + 替换，避免写一半被打断留下残缺清单。
# ---------------------------------------------------------------------------
prune_dead_slots() {
  local f tmp n_before n_after p rel id
  [ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" = manager ] && return 0
  for f in "$MODDIR/slots.applied" "$MODDIR/slots.map"; do
    [ -s "$f" ] || continue
    n_before=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    tmp="$f.prune.$$"
    : > "$tmp" 2>/dev/null || continue
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      set -- $line
      if [ "$f" = "$MODDIR/slots.map" ]; then
        # map 一行是 "id [角色] 路径"，路径是最后一个字段
        if [ "$#" -ge 3 ]; then rel="$3"; else rel="$2"; fi
      else
        # applied 一行就是路径
        rel="$1"
      fi
      rel=$(printf '%s' "$rel" | tr -d '\r')
      case "$rel" in ""|/*|*..*) continue ;; esac
      [ -f "/$rel" ] && printf '%s\n' "$line" >> "$tmp"
    done < "$f"
    n_after=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')
    if [ "$n_after" != "$n_before" ]; then
      mv -f "$tmp" "$f" 2>/dev/null
      beat service "清理失效槽位：$(basename "$f") $n_before → $n_after 行"
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
