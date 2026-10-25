#!/system/bin/sh
# 开机完成后：撤掉开机保护标记，把 pending_font 确认为 active_font，并检查挂载是否执行
#
# 【这里有一条最关键的规则】只有在真的「开机完成」时才撤掉 .booting 保护标记：
#   标记还在 = 下一次 post-fs-data 会触发救援（撤掉字体、恢复成"无字体"），
#   这是"换了字体开不了机"时唯一的自动救命手段。
#   以前这里无条件删除（哪怕等了 10 分钟也没 boot_completed），救援就永远等不到机会，
#   同一个坏字体每次开机都再挂一次 = 永久开不了机。所以：只有 boot_completed=1 才删。

MODDIR=${0%/*}

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
  _miss=0
  for _f in "$_LIB"/f*.ttf; do
    [ -e "$_f" ] || continue
    _i=${_f##*/}; _i=${_i%.ttf}
    if [ -f "$_LIB/$_i.meta" ]; then
      grep -q '^outline_type=' "$_LIB/$_i.meta" 2>/dev/null || { _miss=1; break; }
    else
      _miss=1; break
    fi
  done
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
