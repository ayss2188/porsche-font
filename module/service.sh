#!/system/bin/sh
# 开机完成后：撤掉开机保护标记，把 pending_font 确认为 active_font，并检查挂载是否执行
#
# 【这里有一条最关键的规则】只有在真的「开机完成」时才撤掉 .booting 保护标记：
#   标记还在 = 下一次 post-fs-data 会触发救援（撤掉字体、恢复成"无字体"），
#   这是"换了字体开不了机"时唯一的自动救命手段。
#   以前这里无条件删除（哪怕等了 10 分钟也没 boot_completed），救援就永远等不到机会，
#   同一个坏字体每次开机都再挂一次 = 永久开不了机。所以：只有 boot_completed=1 才删。

MODDIR=${0%/*}

# ★ 2026-10-31：壁纸正本在 $LIB/bg.jpg（永久目录），模块更新会换掉 webroot ——
#   开机把副本补还原回去（跟 customize.sh 的还原互为兜底，幂等）。
if [ ! -s "$MODDIR/webroot/bg.jpg" ] && [ -s "/data/adb/custom_font_lib/bg.jpg" ]; then
  cp -f "/data/adb/custom_font_lib/bg.jpg" "$MODDIR/webroot/bg.jpg" 2>/dev/null
  chmod 644 "$MODDIR/webroot/bg.jpg" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# 自愈：扫描缓存被清过（或安装时 rescan 失败）→ 补建一次槽位清单
#   只在这个小文件缺失时才动手，正常开机零开销。
# ---------------------------------------------------------------------------
_LIB="${LIB:-/data/adb/custom_font_lib}"
if [ ! -s "$_LIB/scanned/slots.meta" ]; then
  sh "$MODDIR/fontctl.sh" rescan >/dev/null 2>&1
fi

# 自愈：字体结构字段（轮廓类型 / 是否可变 / 轴范围）缺失 → 开机补一次。
#   这些字段是"能不能合成"的判断依据，刷入时本该写好；
#   万一没写成（老版本装的字体、档案被清过），在这里补，比等界面探测早得多，
#   界面打开时就是现成的。只检查、只补缺的，正常开机零开销。
if [ -f "$MODDIR/metaprobe.sh" ]; then
  # ★ 2026-10-31（性能）：原来的检查是"每个字体 grep 一次"（20 个字体 = 20 个进程）。
  #   现在两步批量做完，判据一字不改：
  #     ① 纯 shell 检查每个 f*.ttf 都有 .meta（缺档 = 要补）
  #     ② 一次 grep -L 扫全部 meta，列出"没有 outline_type= 的"（有输出 = 要补）
  _miss=0
  for _f in "$_LIB"/f*.ttf; do
    [ -e "$_f" ] || continue
    [ -f "${_f%.ttf}.meta" ] || { _miss=1; break; }
  done
  if [ "$_miss" = 0 ]; then
    [ -n "$(grep -L '^outline_type=' "$_LIB"/f*.meta 2>/dev/null)" ] && _miss=1
  fi
  [ "$_miss" = 1 ] && LIB="$_LIB" sh "$MODDIR/metaprobe.sh" >/dev/null 2>&1
fi
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
# ★ 2026-11-01：**开机标记**（内容 = 本次 boot_id，mtime = 开机完成时刻）——
#   quick/status 用它和 slots.map 的 mtime 比对，判定"计划是否比本次开机新"：
#   新 = 用户改了开关/换了字体但还没重启 → 界面挂持久横幅「重启后生效」；
#   重启后本文件被重写（mtime 更新）→ 横幅自动消失，无需手动关。
printf '%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" > "$LIB/.boot.mark" 2>/dev/null
# ★ 2026-11-01（作者要求，与主项目同版）：**开机生效快照** ——
#   这次开机真正挂载的计划存一份；之后改开关/换字体只重写 slots.map 不动快照，
#   界面的「当前实际生效」（BN=）在重启前保持开机数字，不会跟着新计划一起变。
cp -f "$MODDIR/slots.map" "$MODDIR/slots.boot.map" 2>/dev/null
# 开机真的完成了 -> 把"连续失败"计数清零：说明这个字体在这台机器上是能用的。
# （计数只在 post-fs-data 的救援分支里加，两次就会写 disable 停用模块，宁可保守。）
[ "$(getprop sys.boot_completed)" = "1" ] && rm -f "$LIB/rescue_count" 2>/dev/null

# ---------------------------------------------------------------------------
# 开机完成后补一次完整计划（含 .ttc 合集合成）。
# 为什么放这儿、不放 post-fs-data：post-fs-data 是**阻塞**阶段，合成几十 MB 的合集
# 会把老设备的开机动画卡住（真机反馈过）。这里开机已经起来了，慢一点没人受影响。
# 只补"确实没有计划"的情况：正常情况下计划在 apply 时就写好了，这里什么都不做。
# ---------------------------------------------------------------------------
# ★ 2026-10-24 B5：把挂载延后到开机完成（service 阶段）再做
if [ "$(cfg_get mount_in_service 0 2>/dev/null)" = 1 ] && [ -f "$MODDIR/mount.sh" ]; then
  _p3=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")
  case "$_p3" in ""|none) ;; *)
    beat service "B5：改为开机完成后挂载（service 阶段）"
    ( . "$MODDIR/mount.sh"; payload_mount "$MODDIR" service ) >> "$LIB/mount.log" 2>&1
    ;;
  esac
fi

if [ -f "$MODDIR/fontctl.sh" ] && [ ! -s "$MODDIR/slots.map" ]; then
  _p2=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")
  case "$_p2" in
    ""|none) ;;
    *)
      if [ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" != manager ]; then
        beat service "计划为空，开机后补做完整计划（含合集）"
        # ★ 2026-10-24：留下 apply 的输出，失败时能看出原因（魅族真机 rc=1 却没有日志）
        _svc_ap="${TMPDIR:-/data/local/tmp}/.cfs_apply_svc.$$"
        sh "$MODDIR/fontctl.sh" apply "$_p2" > "$_svc_ap" 2>&1
        _svc_rc=$?
        _svc_n=$(grep -c . "$MODDIR/slots.map" 2>/dev/null)
        beat service "补做结果：计划 ${_svc_n:-0} 个槽位（退出码 ${_svc_rc}，下次开机生效）"
        if [ "${_svc_n:-0}" = 0 ]; then
          echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] service 补计划失败（rc=${_svc_rc}）：$(tail -n 3 "$_svc_ap" 2>/dev/null | tr '\n' ' ')" >> "$LIB/mount.log" 2>/dev/null
        fi
        rm -f "$_svc_ap" 2>/dev/null
      fi
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# ★ 2026-10-16：**升级后清掉陈旧的状态缓存**。
#   为什么需要：谷歌兼容的状态缓存（$LIB/.gms_status）有效期 6 小时，
#   旧版本写下的"已被其它工具停用（foreign）"会被新版本继续沿用，
#   用户升级后打开界面看到的还是错的，得点「重新检测」才刷新
#   （作者真机实测："开关一次就正常了" —— 正是那次开关把缓存覆盖了）。
#   这里比对模块版本，变了（= 刚升级/重装）就删掉缓存，让界面重算。
if [ -f "$MODDIR/module.prop" ]; then
  _MV=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r\n')
  _LV=$(cat "$LIB/.seen_version" 2>/dev/null | tr -d '\r\n')
  if [ -n "$_MV" ] && [ "$_MV" != "$_LV" ]; then
    rm -f "$LIB/.gms_status" "$LIB/.verify.cache" 2>/dev/null
    printf '%s' "$_MV" > "$LIB/.seen_version" 2>/dev/null
    printf '%s %s\n' "$(date '+%m-%d %H:%M' 2>/dev/null)" \
      "模块版本变化：${_LV:-（首次）} → $_MV，已清状态缓存（谷歌兼容/挂载校验）" \
      >> "$LIB/boot_events.log" 2>/dev/null
  fi
fi

# ★ 2026-10-16：**开机完成后再确认一次识别系统**。
#   为什么要有这一步：post-fs-data 跑得很早，那一刻分区未必都挂好、
#   getprop 也可能还没就绪 —— 真机实测在那里把澎湃OS 判成了 aosp，
#   而 current_rom 一旦写错，slots.sh 就会去读 targets/aosp.list（兜底清单），
#   覆盖范围跟着错（172 → 152）。
#   这里（service.sh）开机已完成、目录都在，重算一次最准；不一样就修正。
if [ -f "$MODDIR/common.sh" ] && [ -f "$MODDIR/current_rom" ]; then
  _R2=$( . "$MODDIR/common.sh" 2>/dev/null; detect_rom 2>/dev/null )
  _R1=$(tr -d '[:space:]' < "$MODDIR/current_rom" 2>/dev/null)
  if [ -n "$_R2" ] && [ "$_R2" != "$_R1" ]; then
    printf '%s' "$_R2" > "$MODDIR/current_rom" 2>/dev/null
    printf '%s %s\n' "$(date '+%m-%d %H:%M' 2>/dev/null)" \
      "识别系统已修正：$_R1 → $_R2（开机完成后复算）" >> "$LIB/boot_events.log" 2>/dev/null
    # 识别变了 → 替换计划要按新识别重建（否则还会用旧清单的槽位）
    rm -f "$LIB/.verify.cache" 2>/dev/null
  fi
fi

# 谷歌字体兼容：GMS（Play 服务）被更新后会把我们对"下载字体组件"的停用**重置**掉
# —— 表现就是用户反馈的"英数过一阵子又变回谷歌默认"。这里在开机完成后补一次。
#
# 为什么放在这儿、而且做得这么小心：
#   · 只有**我们自己有记录**时才查（没开过这个功能的用户，这里一行都不跑）；
#   · 只有"组件确实被顶回原状态 **且** GMS 的版本变大（或同版本但更新时间变新、安装路径变了）"
#     才重新停用 —— 用户自己手动关掉的，我们不去跟他抢；
#   · 让路：renice/ionice + 90 秒上限，绝不拖住开机（这个阶段开机已经完成了）。
# ---------------------------------------------------------------------------
if [ -f "$LIB/.gms_journal.conf" ] && [ -f "$MODDIR/google_font.sh" ]; then
  beat service "谷歌字体兼容：检查是否被 GMS 更新重置"
  command -v renice >/dev/null 2>&1 && renice 10 $$ >/dev/null 2>&1
  [ -x /system/bin/ionice ] && /system/bin/ionice -c2 -n7 $$ >/dev/null 2>&1
  if command -v timeout >/dev/null 2>&1; then
    timeout 90 sh "$MODDIR/google_font.sh" reconcile >/dev/null 2>&1
  else
    sh "$MODDIR/google_font.sh" reconcile >/dev/null 2>&1
  fi
fi

# ---------------------------------------------------------------------------
# ★ 2026-10-21：商店缓存桥接整段摘除。
#   原因：实测 Play 商店的字体打包在它自己的 APK 里（assets/ProductSans-*.ttf），
#        替换 GMS 缓存文件对它完全无效；而 Chrome/Gemini 走的是「停用提供器」那条路。
#        这条桥接既没用又会往 GMS 目录塞 44MB 克隆、force-stop GMS，
#        是部分 Google 应用（Gemini 等）异常的可能来源，故移除。
# ---------------------------------------------------------------------------

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
    # ★ 2026-10-17 提速：原来每行都 `printf | tr -d '\r'` —— 286 行的计划就是 286 个进程。
    #   现在循环外一次清洗好（只去 CR，语义不变），循环里直接读干净的行。
    _prc="$f.clean.$$"
    if tr -d '\r' < "$f" > "$_prc" 2>/dev/null && [ -s "$_prc" ]; then
      _prmap="$_prc"
    else
      _prmap="$f"
    fi
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
      case "$rel" in ""|/*|*..*) continue ;; esac
      [ -f "/$rel" ] && printf '%s\n' "$line" >> "$tmp"
    done < "$_prmap"
    rm -f "${_prc:-}" 2>/dev/null
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

# ---------------------------------------------------------------------------
# ★ 2026-10-31：后台**预热全部字体的计划缓存**（prewarm-all）
#   解决"字体是以前导入的，第一次切换永远未命中"：开机 30 秒后把字体库里每份
#   字体的最终计划都提前算好存进 $LIB/.plancache，之后**第一次**切换就是命中。
#   完全不和开机抢资源（开机完成 + 延迟 30 秒 + 降优先级）；失败无感，下次开机再试。
# ---------------------------------------------------------------------------
if [ -f "$MODDIR/fontctl.sh" ]; then
  (
    sleep 30
    renice 19 $$ >/dev/null 2>&1 || true
    [ -x /system/bin/ionice ] && /system/bin/ionice -c3 $$ >/dev/null 2>&1 || true
    sh "$MODDIR/fontctl.sh" prewarm-all
  ) >/dev/null 2>&1 &
fi
MISSED=0
[ -f "$MODDIR/mount_missed" ] && MISSED=1
beat service "finish active=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/active_font") missed=$MISSED"

# ---------------------------------------------------------------------------
# 热重启看门狗（2026-10-21，安全版）
#
#   为什么要它：换了字体但 framework 加载不了 → system_server 崩 → 热重启 → 再来一遍。
#              热重启**不会重跑开机脚本**，所以"等 boot_completed 超时"的救援等不到机会。
#
#   安全设计（防止自己变成新的死循环）：
#     · 最多 90 轮（约 15 分钟）→ 自己退出，不常驻
#     · 锁文件保证单实例；$LIB/.no_watchdog 存在则完全不跑
#     · 系统稳定 12 轮（约 3 分钟）→ 清零计数并退出
#     · killall system_server 全程**只执行一次**（标记文件守护）
#     · 循环里每条命令都 `|| true`，出错就安静退出，不自我重启
# ---------------------------------------------------------------------------
_wd_start() {
  # ★ 2026-10-25 默认关闭（真凶定位）：
  #   看门狗在「system_server 的 PID 变了两次」时会先 panic 回滚、再 killall system_server。
  #   任何原因的热重启都会命中 —— 一 kill，所有 App 的 WebView 渲染进程跟着死，
  #   crashpad 报「Render process crash wasn't handled」→ 宿主 App 直接 abort。
  #   现场就是「任何模块的 WebUI 一点就闪退」+ 几十个 tombstone。
  #   现在只有用户显式打开 hotboot_watchdog 才启用；开启时默认也是「干跑」。
  [ "$(cfg_get hotboot_watchdog 0 2>/dev/null)" = 1 ] || return 0
  [ -f "$_LIB/.no_watchdog" ] && return 0
  [ -s "$_LIB/active_font" ] || return 0
  [ "$(cat "$_LIB/active_font" 2>/dev/null)" = "none" ] && return 0
  [ -f "$MODDIR/fontctl.sh" ] || return 0
  # 单实例
  mkdir "$_LIB/.wd.lock" 2>/dev/null || return 0
  (
    _HB="$_LIB/.hotboot"
    _cnt=$(cat "$_HB" 2>/dev/null || echo 0)
    case "$_cnt" in ''|*[!0-9]*) _cnt=0 ;; esac
    # 已经反复失败过：这次开机不再尝试，让开机救援接手
    [ "$_cnt" -ge 6 ] && { rmdir "$_LIB/.wd.lock" 2>/dev/null; exit 0; }

    _last=$(pidof system_server 2>/dev/null || true)
    _stable=0
    _round=0
    while [ "$_round" -lt 90 ]; do
      _round=$(( _round + 1 ))
      sleep 10 2>/dev/null || break
      [ -f "$_LIB/.no_watchdog" ] && break
      _now=$(pidof system_server 2>/dev/null || true)
      if [ -n "$_now" ] && [ -n "$_last" ] && [ "$_now" != "$_last" ]; then
        _cnt=$(( _cnt + 1 ))
        echo "$_cnt" > "$_HB" 2>/dev/null || true
        printf 'time=%s hotboot=%s pid=%s\n' \
          "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$_cnt" "$_now" \
          >> "$_LIB/.panic.log" 2>/dev/null || true
        if [ "$_cnt" -ge 2 ]; then
          if [ -f "$_LIB/.wd_dry" ]; then
            # 干跑：只记日志，什么都不做（上真机先这样验一轮）
            printf 'dry would-panic hotboot=%s\n' "$_cnt" >> "$_LIB/.panic.log" 2>/dev/null || true
          else
            sh "$MODDIR/fontctl.sh" panic >/dev/null 2>&1 && _pan=1 || _pan=0
            # 只有真的卸掉了挂载，才允许让 system_server 重启一次
            # ★ 2026-10-25：默认只记录，不 kill（kill 会连带杀死所有 WebView 渲染进程）
            if [ "$(cfg_get hotboot_kill 0 2>/dev/null)" = 1 ] && \
               [ "$_pan" = 1 ] && [ "$_cnt" -lt 4 ] && [ ! -f "$_LIB/.reboot_fired" ]; then
              : > "$_LIB/.reboot_fired" 2>/dev/null || true
              killall system_server 2>/dev/null || true
            else
              printf 'would-kill hotboot=%s（hotboot_kill 未开启）\n' "$_cnt" >> "$_LIB/.panic.log" 2>/dev/null || true
            fi
          fi
        fi
        _last=$_now
        _stable=0
        # 已经回滚过就别再折腾：直接退出
        [ "$_cnt" -ge 2 ] && break
      fi
      if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
        _stable=$(( _stable + 1 ))
        if [ "$_stable" -ge 12 ]; then
          echo 0 > "$_HB" 2>/dev/null || true
          break
        fi
      fi
    done
    rmdir "$_LIB/.wd.lock" 2>/dev/null || true
  ) >/dev/null 2>&1 &          # ★ 必须重定向：否则子 shell 持有父进程的 stdout，
                                #   脚本"看起来"不结束（真机上会让开机阶段像卡住）
}

_wd_start

# ★ 2026-10-24：上次开着抓日志（开机前没来得及关）→ 这次开机自动续抓
if [ -f "${LIB:-/data/adb/custom_font_lib}/logs/.on" ] && [ -f "$MODDIR/logcatch.sh" ]; then
  sh "$MODDIR/logcatch.sh" resume >/dev/null 2>&1
fi

# ★ 2026-11-03：更新源自愈
#   worker（cfs-report...workers.dev）的 GitHub token 过期后，/update 一直返回旧版本
#   （v1.3.5），管理器就再也检测不到更新了。这里在开机时把 module.prop 的
#   updateJson 改写成 jsDelivr 直连（内容就是仓库里的 update.json），
#   老用户不用重装也能恢复「管理器里能检测到更新」。
_update_json_selfheal() {
  local mp want cur mid
  MODDIR="${MODDIR:-${0%/*}}"
  LIB="${LIB:-/data/adb/custom_font_lib}"
  mp="$MODDIR/module.prop"
  [ -f "$mp" ] || return 0
  mid=$(sed -n 's/^id=//p' "$mp" 2>/dev/null | head -n1 | tr -d '\r')
  case "$mid" in
    porsche_font_718) want="https://cdn.jsdelivr.net/gh/ayss2188/porsche-font@main/update-718.json" ;;
    porsche_font_911) want="https://cdn.jsdelivr.net/gh/ayss2188/porsche-font@main/update-911.json" ;;
    porsche_font_gt3) want="https://cdn.jsdelivr.net/gh/ayss2188/porsche-font@main/update-gt3.json" ;;
    porsche_font_*)   want="https://cdn.jsdelivr.net/gh/ayss2188/porsche-font@main/update.json" ;;
    *)                want="https://cdn.jsdelivr.net/gh/ayss2188/custom-font-switcher@main/update.json" ;;
  esac
  cur=$(sed -n 's/^updateJson=//p' "$mp" 2>/dev/null | head -n1 | tr -d '\r')
  [ "$cur" = "$want" ] && return 0
  case "$cur" in
    *workers.dev*|"") ;;
    *) return 0 ;;   # 用户自己改过更新源就不动
  esac
  sed -i "s|^updateJson=.*|updateJson=$want|" "$mp" 2>/dev/null \
    || { grep -q '^updateJson=' "$mp" && sed -i "/^updateJson=/d" "$mp"; echo "updateJson=$want" >> "$mp"; }
  printf '%s\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null) updateJson 已自愈 → $want" >> "$LIB/update.log" 2>/dev/null
}
_update_json_selfheal

# ★ 2026-11-03：系统 OTA 之后的自动适配
#   系统更新会换掉 /system 的字体重排（字体文件名/配置可能变），
#   旧扫描结果和旧计划就没用了。这里比对 ro.build.fingerprint：
#   变了 → 后台重扫槽位 + 按当前选择重新生成计划 + 记一笔（界面「通用」可查）。
_ota_guard() {
  MODDIR="${MODDIR:-${0%/*}}"
  LIB="${LIB:-/data/adb/custom_font_lib}"
  _fp=$(getprop ro.build.fingerprint 2>/dev/null | tr -d '\r\n')
  [ -n "$_fp" ] || return 0
  _old=$(cat "$LIB/.sysfp" 2>/dev/null | tr -d '\r\n')
  [ "$_fp" = "$_old" ] && return 0
  printf '%s' "$_fp" > "$LIB/.sysfp" 2>/dev/null
  # 第一次记录（老用户升级上来）不算系统更新
  [ -z "$_old" ] && return 0
  _pf=$(cat "$MODDIR/pending_font" 2>/dev/null | tr -d '[:space:]')
  [ -n "$_pf" ] || _pf=$(cat "$LIB/pending_font" 2>/dev/null | tr -d '[:space:]')
  [ -n "$_pf" ] || _pf=$(cat "$LIB/last_selection" 2>/dev/null | tr -d '[:space:]')
  case "$_pf" in ""|none) _pf="" ;; esac
  {
    printf '[%s] 系统更新：%s → %s\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$_old" "$_fp"
    rm -f "$MODDIR/current_rom" "$LIB/.plan.cache" "$LIB/.cand.cache" \
          "$LIB/.device_fonts" "$LIB/.xmlnames.cache" "$LIB/.skipscan.cache" 2>/dev/null
    if sh "$MODDIR/fontctl.sh" rescan >/dev/null 2>&1; then
      printf '  ✓ 槽位已重扫\n'
    else
      printf '  ! 槽位重扫失败（可在界面点「重新数一遍」）\n'
    fi
    if [ -n "$_pf" ]; then
      if sh "$MODDIR/fontctl.sh" apply "$_pf" >/dev/null 2>&1; then
        printf '  ✓ 已按当前选择重新生成计划（重启后生效）\n'
      else
        printf '  ! 重新应用失败（可在界面重新切一次）\n'
      fi
    fi
  } >> "$LIB/ota.log" 2>&1
  : > "$LIB/.ota.adapted" 2>/dev/null
}
# 后台跑，别拖慢开机
( _ota_guard ) >/dev/null 2>&1 &

# ★ 2026-11-06：service 阶段再补挂一次 /data 主题字体（防止 post-fs-data 时计划还没就绪）
if [ -s "$MODDIR/slots.map" ] && [ "$(mount_mode 2>/dev/null)" = manager ]; then
  ( . "$MODDIR/mount.sh" 2>/dev/null; mount_data_slots_only ) >/dev/null 2>&1 &
fi
