#!/system/bin/sh
# post-fs-data：开机保护 + Magisk 下的自带挂载
#
# 开机保护：如果上次选了字体后没能开机成功（没走到 boot_completed），
# 这次自动撤掉所有字体文件并恢复为「无字体」，避免一直卡开机。
#
# 判定"上次是不是真的没开机成功"用的是 boot_events.log：
#   post-fs-data 会把本次 boot_id 写进 .booting；
#   service.sh 只有等到 boot_completed=1 才会删掉 .booting，并写下 "info=finish" 心跳。
#   所以：看到 .booting，但日志里有对应 boot_id 的 finish 记录 = 上次其实开机成功了
#   （只是标记没删掉），这种情况绝不能误清用户的字体。

MODDIR=${0%/*}
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"
[ -f "$MODDIR/mount.sh" ] && . "$MODDIR/mount.sh"

rm -f "$MODDIR/mount_missed"

# 心跳：证明 post-fs-data 阶段确实被执行了（诊断用）
beat post-fs-data "pending=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font") root=$(root_manager) mode=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode") u=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)"

if [ -f "$MODDIR/.booting" ]; then
  # 上次开机留下的保护标记：先确认上次到底有没有开机成功
  _BID=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/.booting")
  _OKBOOT=0
  if [ -n "$_BID" ] && [ -f "$LIB/boot_events.log" ]; then
    grep -q "boot=$_BID stage=service info=finish" "$LIB/boot_events.log" 2>/dev/null && _OKBOOT=1
  fi
  if [ "$_OKBOOT" = 1 ]; then
    # 上次开机其实成功了，只是标记没来得及删：不是卡开机，别动用户的字体
    rm -f "$MODDIR/.booting"
  else
    # 救援：撤掉所有字体文件，恢复成「无字体」。
    # 注意：这里不依赖 payload.mode —— 那个文件可能缺失/为空/被截断，
    # 一旦因此跳过删除，坏字体下次还会被管理器挂上去，而"要删哪些文件"的清单
    # 又已经被清空，就再也救不回来了。所以两种落盘方式都删，删完才清空清单。
    if [ -f "$MODDIR/slots.applied" ]; then
      while IFS= read -r rel || [ -n "$rel" ]; do
        rel=$(printf '%s' "$rel" | tr -d '\r')
        case "$rel" in ""|/*|*..*) continue ;; esac
        rm -f "$MODDIR/$rel" 2>/dev/null
        if command -v mgr_path >/dev/null 2>&1; then
          rm -f "$MODDIR/$(mgr_path "$rel")" 2>/dev/null
        fi
      done < "$MODDIR/slots.applied"
    fi
    rm -rf "$MODDIR/payload"
    mkdir -p "$MODDIR/payload"
    : > "$MODDIR/slots.applied"
    : > "$MODDIR/slots.map"
    echo none > "$MODDIR/pending_font"
    echo none > "$MODDIR/active_font"
    echo none > "$LIB/last_selection" 2>/dev/null
    touch "$MODDIR/rescued"
    rm -f "$MODDIR/.booting"
    exit 0
  fi
fi

# 只有真的应用了字体才需要看守
P=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")
case "$P" in ""|none) exit 0 ;; esac
# 正在关机/重启：别挂载，直接走
shutting_down && exit 0
# 记下"这次开机挂过字体"（带上 boot_id，供下次判断是否需要救援）
boot_id > "$MODDIR/.booting" 2>/dev/null
[ -s "$MODDIR/.booting" ] || touch "$MODDIR/.booting"

# 自带挂载：这里就是主挂载点，**所有管理器都在这里挂**。
#
# 为什么不再"KSU 让位给 post-mount"：post-mount 不是所有管理器都有。
# 实测 KernelSU Ultra 就不执行 post-mount 阶段（用户的机器上 post-fs-data 和 service
# 都跑了、唯独没人挂载），结果字体一个槽位都没替换。post-fs-data 是唯一保证会跑的
# 阶段（Magisk / KernelSU / APatch / 各种分支都有），所以把它作为权威挂载点。
# post-mount.sh 仍然保留，作用是「二次修补」：如果元模块的目录级挂载盖住了我们的
# per-file 挂载，那一遍会（靠 inode 比对发现的）补回来；它幂等，不会叠挂载。
[ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" = manager ] && exit 0
payload_mount "$MODDIR" post-fs-data
