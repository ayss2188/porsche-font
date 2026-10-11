#!/system/bin/sh
# post-fs-data：开机保护 + 自带挂载（所有管理器的**主挂载点**）
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
    # -------------------------------------------------------------------------
    # 连续两次都救不回来 → 说明这台机器 + 这个字体就是开不了机。
    # 这时候**必须让用户先能正常用手机**：直接写 disable 文件把模块停用，
    # 管理器下次开机就不会执行本模块（字体自然恢复系统默认）。
    # 只在"第二次"才停用，是为了不误伤偶发一次的开机异常（比如用户自己中途断电）。
    # -------------------------------------------------------------------------
    _rn=$(tr -d '[:space:]' 2>/dev/null < "$LIB/rescue_count")
    case "$_rn" in ''|*[!0-9]*) _rn=0 ;; esac
    _rn=$((_rn + 1))
    printf '%s' "$_rn" > "$LIB/rescue_count" 2>/dev/null
    if [ "$_rn" -ge 2 ] 2>/dev/null; then
      touch "$MODDIR/disable" 2>/dev/null
      {
        echo "连续 ${_rn} 次开机没有正常完成，已自动停用本模块。"
        echo "手机现在可以正常开机了（字体回到系统默认）。"
        echo "请到 Root 管理器里重新启用本模块，并**先换一个字体**或把「替换范围」调小再试。"
      } > "$LIB/rescue_stopped" 2>/dev/null
      # 模块被停用后脚本不会再跑，提示只能靠 module.prop 的描述带出去
      if command -v refresh_prop >/dev/null 2>&1; then
        refresh_prop 2>/dev/null
      else
        sed -i 's/^description=.*/description=⚠ 已自动停用（连续开机失败，请换字体后再启用）/' "$MODDIR/module.prop" 2>/dev/null
      fi
      beat post-fs-data "连续 ${_rn} 次开机失败，已自动停用本模块（写 disable），手机可正常开机"
    else
      beat post-fs-data "开机未完成，已撤掉全部字体文件（第 ${_rn} 次）；再失败一次会自动停用本模块"
    fi
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
# 为什么不再"KernelSU / APatch 让位给 post-mount"：post-mount 不是所有管理器都执行
# （真机上遇到过：post-fs-data 和 service 都跑了、唯独没人挂载，结果字体一个槽位都没换，
# 界面只说"本次开机未挂载"，用户无从下手）。post-fs-data 是唯一保证会跑的阶段
# （Magisk / KernelSU / APatch 及各种分支都有），所以把它作为权威挂载点。
# post-mount.sh 仍然保留，作用是「二次修补」：如果元模块的目录级挂载排在后面、
# 把我们挂上去的文件盖住了，那一遍会靠 inode 比对发现并补回来（幂等，不会叠出两层）。
[ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" = manager ] && exit 0
payload_mount "$MODDIR" post-fs-data
