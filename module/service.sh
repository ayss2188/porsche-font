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
    if [ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" != manager ] && \
       [ "$(sed -n 's/^boot=//p' "$MODDIR/mount.state" 2>/dev/null)" != "$(boot_id)" ]; then
      touch "$MODDIR/mount_missed"
    fi
    ;;
esac

# 关机中就别再动模块目录了（sync/relink 会写文件，正好撞上 init 卸载 /data）
shutting_down && exit 0
sh "$MODDIR/fontctl.sh" sync
shutting_down && exit 0
sh "$MODDIR/fontctl.sh" relink >/dev/null 2>&1
MISSED=0
[ -f "$MODDIR/mount_missed" ] && MISSED=1
beat service "finish active=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/active_font") missed=$MISSED"
