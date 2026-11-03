#!/system/bin/sh
# adv.sh —— 高级设置（调试用）的后端：诊断 / 现场导出 / 一键恢复
#
# 所有命令都是"只读优先"，会改状态的那几个单独标了 DANGER。
#
#   sh adv.sh pack          导出最小复现包（zip/tar.gz → Download）     只读
#   sh adv.sh plan          打印 slots.map（前 60 行）                 只读
#   sh adv.sh mountlog      打印 mount.log（末 60 行）                 只读
#   sh adv.sh ttclog        打印 ttc.log（末 60 行）                   只读
#   sh adv.sh slots         逐槽位判定（OK/目标缺失/源缺失/未挂载）      只读
#   sh adv.sh status        实际挂载条数 + 计划条数 + 挂载方式           只读
#   sh adv.sh selinux       目标 vs 源的 SELinux 标签                  只读
#   sh adv.sh avc           avc denied 最近 20 条                      只读
#   sh adv.sh webview       WebView 相关进程 + 上下文                  只读
#   sh adv.sh dropbox       近 24h 崩溃记录                            只读
#   sh adv.sh boot          开机时间线（boot_events.log）              只读
#   sh adv.sh conflicts     其它模块里同名的 system/fonts 文件          只读
#   sh adv.sh theme         主题字体备份清单                           只读
#   sh adv.sh hash          关键脚本 sha256 + 版本一致性                只读
#   sh adv.sh ns            当前是否在 init 命名空间                    只读
#   sh adv.sh umount        DANGER 临时卸掉本模块挂载（不重启）         可恢复
#   sh adv.sh remount       DANGER 重新挂载（配合上一条做 A/B）         可恢复
#   sh adv.sh rescan        DANGER 清缓存并重扫槽位                     重扫
#   sh adv.sh replan        DANGER 重新生成挂载计划                     重算

MODDIR=${0%/*}
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"
LIB="${LIB:-/data/adb/custom_font_lib}"
MAP="$MODDIR/slots.map"
DL="/sdcard/Download"

_now() { date '+%Y%m%d-%H%M%S' 2>/dev/null; }
_hr() { echo "--------------------------------------------"; }

_pack() {
  _out="$DL/复现包_$(_now).tar.gz"
  _tmp="${TMPDIR:-/data/local/tmp}/.cfs_pack.$$"
  rm -rf "$_tmp"; mkdir -p "$_tmp" 2>/dev/null
  for f in slots.map slots.applied settings.conf payload.mode pending_font active_font \
           current_rom module.prop mount.state scanmarks.conf; do
    [ -f "$MODDIR/$f" ] && cp -f "$MODDIR/$f" "$_tmp/" 2>/dev/null
  done
  mkdir -p "$_tmp/lib" 2>/dev/null
  for f in mount.log ttc.log boot_events.log .scanmarks rescue_count; do
    [ -f "$LIB/$f" ] && cp -f "$LIB/$f" "$_tmp/lib/" 2>/dev/null
  done
  ls -l "$LIB" 2>/dev/null > "$_tmp/lib/list.txt"
  # 计划 vs 实际
  { echo "== 计划条数 =="; grep -c . "$MAP" 2>/dev/null
    echo "== 实际挂载 =="; grep -c 'custom_font_lib' /proc/mounts 2>/dev/null
    echo "== getenforce =="; getenforce 2>/dev/null
    echo "== 版本 =="; sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1
  } > "$_tmp/summary.txt" 2>/dev/null
  if tar -czf "$_out" -C "$_tmp" . 2>/dev/null || tar -cf "$_out" -C "$_tmp" . 2>/dev/null; then
    rm -rf "$_tmp"
    echo "已生成：$_out"
    echo "大小：$(wc -c < "$_out" 2>/dev/null) 字节"
  else
    rm -rf "$_tmp"
    echo "ERROR:打包失败（这台机器可能没有 tar）"
    return 1
  fi
}

_slots_check() {
  [ -s "$MAP" ] || { echo "没有 slots.map（还没应用过字体）"; return 1; }
  _ok=0; _miss_t=0; _miss_s=0; _nomount=0; _n=0
  # ★ 2026-10-24（真机踩到）：WebUI 跑在 App 命名空间里，看不到 init 挂的字体，
  #   直接数 /proc/mounts 会得到"0 条已挂载"的假结论。
  #   改成以 init 的挂载表为准（字段 5 = 挂载点），并把当前视角的条数也报出来。
  _mnt=$(awk '{print $5}' /proc/1/mountinfo 2>/dev/null | grep 'custom_font_lib' | tr '\n' ' ')
  _mnt_self=$(awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -c 'custom_font_lib' | tr -d ' ')
  echo "判定依据：init 命名空间（/proc/1/mountinfo）"
  echo "当前视角能看到 $_mnt_self 条；两边不一致属正常（App 被隔离了挂载）"
  echo ""
  echo "槽位判定（最多列 40 条异常）"
  _hr
  while read -r _id _rel _src; do
    [ -n "$_rel" ] || continue
    _n=$((_n + 1))
    case "$_rel" in /*) _t="$_rel" ;; *) _t="/$_rel" ;; esac
    [ -n "$_src" ] || _src="$LIB/$_id.ttf"
    if [ ! -f "$_t" ]; then
      _miss_t=$((_miss_t + 1))
      [ "$_miss_t" -le 40 ] && echo "  [目标缺失] $_t"
      continue
    fi
    if [ ! -f "$_src" ]; then
      _miss_s=$((_miss_s + 1))
      [ "$_miss_s" -le 40 ] && echo "  [源缺失]   $_t  ←  $_src"
      continue
    fi
    case "$_mnt" in
      *" $_t "*) _ok=$((_ok + 1)) ;;
      *) _nomount=$((_nomount + 1))
         [ "$_nomount" -le 40 ] && echo "  [未挂载]   $_t" ;;
    esac
  done < "$MAP"
  _hr
  echo "合计 $_n 个：已挂载 $_ok / 未挂载 $_nomount / 目标缺失 $_miss_t / 源缺失 $_miss_s"
}

_cnt_init() {   # init 命名空间里挂了多少条（App 视角可能看不到）
  grep -c 'custom_font_lib' /proc/1/mountinfo 2>/dev/null | tr -d ' '
}
_cnt_self() {   # 当前 shell 视角
  grep -c 'custom_font_lib' /proc/self/mountinfo 2>/dev/null | tr -d ' '
}

_status() {
  _ci=$(_cnt_init); _cs=$(_cnt_self)
  [ -n "$_ci" ] || _ci=0
  [ -n "$_cs" ] || _cs=0
  echo "计划条数   : $(grep -c . "$MAP" 2>/dev/null)"
  echo "实际挂载   : init 视角 ${_ci} 条 / 当前视角 ${_cs} 条"
  if [ "$_ci" != "$_cs" ]; then
    echo "             （两个数不一样：说明当前这个界面的「视角」看不到部分挂载；以 init 视角为准）"
  fi
  echo "挂载方式   : $(tr -d '[:space:]' < "$MODDIR/payload.mode" 2>/dev/null)"
  echo "字体       : $(tr -d '[:space:]' < "$MODDIR/pending_font" 2>/dev/null)"
  echo "当前生效   : $(tr -d '[:space:]' < "$MODDIR/active_font" 2>/dev/null)"
  echo "mount.state: $(tr -d '\r' < "$MODDIR/mount.state" 2>/dev/null | head -n1)"
  _rc=$(tr -d '[:space:]' < "$LIB/rescue_count" 2>/dev/null)
  echo "抢救计数   : ${_rc:-无（没有触发过）}"
  [ -e "$MODDIR/mount_missed" ] && echo "！本次开机没有执行自带挂载"
}

_selinux() {
  echo "getenforce : $(getenforce 2>/dev/null)"
  _hr
  _n=0
  if [ -s "$MAP" ]; then
    while read -r _id _rel _src; do
      [ -n "$_rel" ] || continue
      case "$_rel" in /*) _t="$_rel" ;; *) _t="/$_rel" ;; esac
      echo "目标: $(ls -Z "$_t" 2>/dev/null | head -n1)"
      [ -n "$_src" ] && echo "源  : $(ls -Z "$_src" 2>/dev/null | head -n1)"
      echo ""
      _n=$((_n + 1))
      [ "$_n" -ge 5 ] && break
    done < "$MAP"
  else
    ls -Z "$LIB"/*.ttf 2>/dev/null | head -n5
  fi
}

_avc() {
  _c=$(dmesg 2>/dev/null | grep -c 'avc: *denied')
  echo "avc denied 合计：${_c:-0}"
  _hr
  dmesg 2>/dev/null | grep 'avc: *denied' | tail -20
}

_webview() {
  echo "== WebView 相关进程 =="
  ps -Z 2>/dev/null | grep -iE 'webview|sandboxed_process' | head -n 8
  echo ""
  echo "== WebView 实现 =="
  dumpsys webviewupdate 2>/dev/null | grep -iE 'Current WebView package|versionName|Fallback' | head -n 6
}

_dropbox() {
  echo "== 近 24h 崩溃记录（dropbox） =="
  find /data/system/dropbox -name '*crash*' -newermt '-24 hours' 2>/dev/null | wc -l
  _hr
  ls -t /data/system/dropbox/*data_app_crash* /data/system/dropbox/*system_server_crash* 2>/dev/null | head -n 5
}

_boot() {
  [ -s "$LIB/boot_events.log" ] || { echo "没有 boot_events.log"; return 0; }
  echo "== 最近 20 条开机事件 =="
  tail -n 20 "$LIB/boot_events.log"
}

_conflicts() {
  _me=$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
  echo "== 别的模块会不会和本模块抢字体 =="
  _found=0
  for _d in /data/adb/modules/*; do
    [ -d "$_d" ] || continue
    _mid=${_d##*/}
    [ "$_mid" = "$_me" ] && continue
    [ -f "$_d/remove" ] && continue
    _name=$(sed -n 's/^name=//p' "$_d/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
    _desc=$(sed -n 's/^description=//p' "$_d/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
    _hit=""
    # 直接往 system/fonts 里塞文件的
    if [ -d "$_d/system/fonts" ]; then
      _n=$(ls -1 "$_d/system/fonts" 2>/dev/null | grep -c .)
      _hit="system/fonts 里有 $_n 个字体文件"
    else
      # 按名字/描述判断：字体、主题、zygisk 注入
      case "$_mid $_name $_desc" in
        *字体*|*[Ff]ont*|*FONT*|*主题*|*[Tt]heme*|*字库*|*字形*)
          _hit="名字/描述像字体或主题模块（${_name:-$_mid}）" ;;
      esac
      case "$_mid" in
        *zygisk*|*Zygisk*|*shamiko*|*Shamiko*) [ -n "$_hit" ] || _hit="zygisk 类（可能改字体挂载可见性）" ;;
      esac
    fi
    [ -n "$_hit" ] || continue
    echo "  · $_mid${_name:+（$_name）}"
    echo "      $_hit"
    echo "      → 两个模块同时改字体时，只留一个：管理器里停用/卸载另一个再重启"
    _found=1
  done
  [ "$_found" = 0 ] && echo "  ✓ 没发现别的字体/主题/zygisk 模块（只装了本模块）"
  echo
  echo "提示：本模块自身是 $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -1)"
}

_theme() {
  echo "== 主题字体物理替换备份（$LIB/.orig） =="
  ls -l "$LIB/.orig" 2>/dev/null | head -n 20
  echo ""
  echo "== 替换清单 =="
  cat "$LIB/.datafonts" 2>/dev/null | head -n 20
}

_hash() {
  echo "== 关键脚本 sha256（与包内对比用） =="
  for f in fontctl.sh slots.sh mount.sh post-fs-data.sh service.sh ttcwrap.sh logcatch.sh adv.sh; do
    [ -f "$MODDIR/$f" ] || continue
    _h=$(sha256sum "$MODDIR/$f" 2>/dev/null | cut -d' ' -f1)
    [ -n "$_h" ] || _h=$(md5sum "$MODDIR/$f" 2>/dev/null | cut -d' ' -f1)
    printf '  %-18s %s\n' "$f" "${_h:-取不到}"
  done
  echo ""
  echo "== 版本一致性 =="
  echo "  盘上 module.prop: $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1)"
  [ -f "/data/adb/modules_update/${MODDIR##*/}/module.prop" ] && \
    echo "  modules_update : $(sed -n 's/^version=//p' "/data/adb/modules_update/${MODDIR##*/}/module.prop" 2>/dev/null | head -n1)"
}

_ns() {
  _a=$(readlink /proc/1/ns/mnt 2>/dev/null)
  _b=$(readlink /proc/self/ns/mnt 2>/dev/null)
  echo "init ns : ${_a:-?}"
  echo "self ns : ${_b:-?}"
  [ "$_a" = "$_b" ] && echo "→ 同一个命名空间（可以直接挂载）" || echo "→ 不同命名空间（需要 nsenter）"
}

_umount() {
  _n=0
  _list=$(awk '{print $5}' /proc/1/mountinfo 2>/dev/null | grep 'custom_font_lib')
  for _mp in $_list; do
    umount "$_mp" 2>/dev/null && _n=$((_n + 1))
  done
  # 在当前命名空间里卸不掉 → 进 init 命名空间再卸
  if [ "$_n" = 0 ] && [ -n "$_list" ] && command -v nsenter >/dev/null 2>&1; then
    for _mp in $_list; do
      nsenter -t 1 -m umount "$_mp" 2>/dev/null && _n=$((_n + 1))
    done
  fi
  echo "已卸下 $_n 条本模块挂载（重启会恢复）"
  echo "现在去试：字体是不是立刻回到系统默认？崩不崩？"
}

_remount() {
  if [ -f "$MODDIR/mount.sh" ]; then
    ( . "$MODDIR/mount.sh"; payload_mount "$MODDIR" manual ) 2>&1 | tail -n 10
  else
    echo "ERROR:没有 mount.sh"
  fi
}

_rescan() {
  if [ -f "$MODDIR/fontctl.sh" ]; then
    rm -rf "$LIB/scanned" 2>/dev/null
    : > "$LIB/.force_rescan" 2>/dev/null
    sh "$MODDIR/fontctl.sh" rescan 2>&1 | tail -n 6
  fi
}

_replan() {
  [ -f "$MODDIR/fontctl.sh" ] || { echo "ERROR:没有 fontctl.sh"; return 1; }
  _p=$(tr -d '[:space:]' < "$MODDIR/pending_font" 2>/dev/null)
  case "$_p" in ""|none) echo "当前是「无字体」，不用生成计划"; return 0 ;; esac
  sh "$MODDIR/fontctl.sh" apply "$_p" 2>&1 | tail -n 6
}

# ★ 2026-10-31：手动预热全部字体的切换计划 + 中文合集产物（高级设置按钮用）
#   输出逐字体的进度行；产物落 $LIB/.ttc.cache 永久保存，做完之后切任何字体都是秒级。
_prewarm_all() {
  [ -f "$MODDIR/fontctl.sh" ] || { echo "ERROR:没有 fontctl.sh"; return 1; }
  echo "开始预生成（有中文合集的机型每字体要几十秒，请等它跑完）…"
  sh "$MODDIR/fontctl.sh" prewarm-all 2>&1
  echo ""
  echo "做完这些之后切任何字体都不用再现场合成 —— 第一次就是秒级。"
}


# ★ 2026-11-03：一键修「模块被隐藏，普通 App 看不到字体」
#   KernelSU 默认 kernel_umount=1 → 把模块挂载从普通应用里卸掉，只有 root 应用能看到；
#   APatch 的「排除修改」等价；Magisk 没这个机制。
_umount_fix() {
  local f bak _mgr=""
  [ -d /data/adb/ksu ] && _mgr=ksu
  [ -z "$_mgr" ] && [ -d /data/adb/ap ] && _mgr=apatch
  [ -z "$_mgr" ] && [ -d /data/adb/magisk ] && _mgr=magisk
  echo "== 让所有 App 都能看到字体 =="
  echo "识别到的 Root 管理器：${_mgr:-未知}"
  echo
  case "$_mgr" in
    ksu)
      f=/data/adb/ksu/.feature_config
      echo "配置文件：$f"
      if [ -f "$f" ]; then
        echo "--- 修改前 ---"
        grep -n 'kernel_umount' "$f" 2>/dev/null || echo "（没有 kernel_umount 这一行 = 当前隐藏模块，普通 App 看不到字体）"
      else
        echo "（文件不存在，将新建）"
      fi
      bak="$f.bak.$(date +%Y%m%d%H%M%S 2>/dev/null)"
      [ -f "$f" ] && cp -f "$f" "$bak" 2>/dev/null && echo "已备份：$bak"
      if [ -f "$f" ] && grep -q '^kernel_umount=' "$f" 2>/dev/null; then
        sed -i 's/^kernel_umount=.*/kernel_umount=0/' "$f" 2>/dev/null
      else
        printf 'kernel_umount=0\n' >> "$f" 2>/dev/null
      fi
      echo "--- 修改后 ---"
      grep -n 'kernel_umount' "$f" 2>/dev/null
      echo
      echo "✅ 已写入 kernel_umount=0。重启后「普通 App 也能看到字体」。"
      echo "   想恢复原样：把上面那个 .bak 文件覆盖回去，然后重启。"
      ;;
    apatch)
      echo "检测到 APatch："
      echo "  APatch 管理器 → 设置 → 关闭「排除修改 / Exclude modifications」→ 重启。"
      echo "  （APatch 没有可直接改写的配置文件，需要手动点这个开关）"
      ;;
    magisk)
      echo "检测到 Magisk：Magisk 没有「默认卸载模块」机制，普通 App 本来就能看到字体。"
      echo "如果只有部分 App 没变：多半是该 App 自带字体（需要「全覆盖」）或用了独立字体包。"
      ;;
    *)
      echo "没识别出 Root 管理器。"
      echo "如果管理器里有「默认卸载模块 / 排除修改 / 遵守排除列表」之类的开关，关掉再重启。"
      ;;
  esac
}


# ★ 2026-11-03：字体库备份 / 恢复（纯 shell，不依赖 python）
#   备份内容：字体库里的用户字体 + 元数据 + 设置 + 当前选择
#   输出：/sdcard/Download/fontlib-YYYYmmdd-HHMMSS.tar.gz
#   注意：字体动辄几十 MB，备份文件可能很大；界面会提示耗时。
_FB_DIR=/sdcard/Download
_FB_ITEM=''
_fb_pick() {   # 列出可备份的东西
  _FB_ITEM=""
  for _f in "$LIB"/f*.ttf "$LIB"/f*.otf "$LIB"/*.meta "$LIB"/*.name; do
    [ -f "$_f" ] && _FB_ITEM="$_FB_ITEM${_FB_ITEM:+ }${_f##*/}"
  done
  for _f in settings.conf last_selection pending_font; do
    [ -f "$LIB/$_f" ] && _FB_ITEM="$_FB_ITEM${_FB_ITEM:+ }$_f"
  done
}

_fontbackup() {
  echo "== 备份字体库 =="
  _fb_pick
  if [ -z "$_FB_ITEM" ]; then echo "字体库里没有可备份的内容（还没有导入过字体）"; return 1; fi
  mkdir -p "$_FB_DIR" 2>/dev/null
  _ts=$(date +%Y%m%d-%H%M%S 2>/dev/null)
  _out="$_FB_DIR/fontlib-$_ts.tar.gz"
  echo "正在打包（字体大时要几十秒，别退出）…"
  # shellcheck disable=SC2086
  ( cd "$LIB" && tar -czf "$_out" $_FB_ITEM ) 2>/dev/null
  if [ -s "$_out" ]; then
    _sz=$(du -h "$_out" 2>/dev/null | awk '{print $1}')
    echo "✅ 已备份：$_out（${_sz:-?}）"
    echo "   里面包含：$(printf '%s' "$_FB_ITEM" | tr ' ' '\n' | wc -l | tr -d ' ') 个文件"
    echo "   Download 里如果看不到，说明需要给文件管理器存储权限。"
  else
    echo "❌ 备份失败：写不进 $_FB_DIR（检查存储空间 / 权限）"
    return 1
  fi
}

_fontrestore() {
  echo "== 恢复字体库 =="
  mkdir -p "$_FB_DIR" 2>/dev/null
  _list=$(ls -1t "$_FB_DIR"/fontlib-*.tar.gz 2>/dev/null | head -n 8)
  if [ -z "$_list" ]; then echo "Download 里没有找到 fontlib-*.tar.gz 备份"; return 1; fi
  echo "可用的备份（新的在前）："
  printf '%s\n' "$_list" | sed 's|.*/||' | nl -ba | sed 's/^/  /'
  # 支持传序号或文件名：fontrestore 1
  _pick="${1:-1}"
  _sel=$(printf '%s\n' "$_list" | sed -n "${_pick}p")
  [ -n "$_sel" ] || { echo "没有第 $_pick 个备份"; return 1; }
  echo "选中：${_sel##*/}"
  _tmp="$LIB/.restore.$$"
  rm -rf "$_tmp"; mkdir -p "$_tmp" 2>/dev/null
  if ! tar -xzf "$_sel" -C "$_tmp" 2>/dev/null; then
    echo "❌ 解包失败：文件可能损坏"; rm -rf "$_tmp"; return 1
  fi
  # 先校验：字体头 + 大小
  _bad=0; _ok=0
  for _f in "$_tmp"/f*.ttf "$_tmp"/f*.otf; do
    [ -f "$_f" ] || continue
    _h=$(head -c 4 "$_f" 2>/dev/null)
    _s=$(wc -c < "$_f" 2>/dev/null | tr -dc '0-9')
    case "$_h" in
      $'\x00\x01\x00\x00'|OTTO|true|ttcf) ;;
      *) [ "${_s:-0}" -gt 1024 ] 2>/dev/null || { echo "  跳过损坏字体：${_f##*/}"; _bad=$((_bad+1)); continue; } ;;
    esac
    _ok=$((_ok + 1))
  done
  if [ "$_ok" -eq 0 ]; then echo "❌ 备份里没有可用字体（$ _bad 个损坏）"; rm -rf "$_tmp"; return 1; fi
  echo "校验通过：$_ok 个字体可用${_bad:+，跳过 $_bad 个损坏的}"
  # 落盘：字体与元数据覆盖，设置只在备份里有才覆盖
  for _f in "$_tmp"/*; do
    [ -f "$_f" ] || continue
    _b=${_f##*/}
    case "$_b" in
      settings.conf|last_selection|pending_font) cp -f "$_f" "$LIB/$_b" 2>/dev/null ;;
      *) cp -f "$_f" "$LIB/$_b" 2>/dev/null ;;
    esac
  done
  rm -rf "$_tmp"
  echo "✅ 已恢复 $_ok 个字体"
  echo "   下一步：回界面点「切换」应用一次，然后重启生效。"
}

_fontbackuplist() {
  echo "== Download 里的字体库备份 =="
  ls -1lt "$_FB_DIR"/fontlib-*.tar.gz 2>/dev/null | awk '{printf "  %-46s %8.1f MB  %s %s %s\n", $9, $5/1048576, $6, $7, $8}' \
    | sed 's|/sdcard/Download/||'
  [ -n "$(ls -1 "$_FB_DIR"/fontlib-*.tar.gz 2>/dev/null)" ] || echo "  （没有备份）"
}

_otareport() {
  echo "== 系统更新后的自动适配记录 =="
  if [ -s "$LIB/ota.log" ]; then tail -n 30 "$LIB/ota.log"; else echo "  （还没有触发过：要么没做过系统更新，要么系统版本没变）"; fi
  echo
  echo "当前系统：$(getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')"
  echo "上次记录：$(cat "$LIB/.sysfp" 2>/dev/null | tr -d '\r')"
}

case "${1:-}" in
  kernelumount) _umount_fix ;;
  fontbackup)   _fontbackup ;;
  fontrestore)  _fontrestore "${2:-1}" ;;
  backuplist)   _fontbackuplist ;;
  otareport)    _otareport ;;
  pack)      _pack ;;
  plan)      echo "== slots.map（前 60 行 / 共 $(grep -c . "$MAP" 2>/dev/null) 行） =="; head -n 60 "$MAP" 2>/dev/null ;;
  mountlog)  echo "== mount.log（末 60 行） =="; tail -n 60 "$LIB/mount.log" 2>/dev/null ;;
  ttclog)    echo "== ttc.log（末 60 行） =="; tail -n 60 "$LIB/ttc.log" 2>/dev/null ;;
  slots)     _slots_check ;;
  status)    _status ;;
  selinux)   _selinux ;;
  avc)       _avc ;;
  webview)   _webview ;;
  dropbox)   _dropbox ;;
  boot)      _boot ;;
  conflicts) _conflicts ;;
  theme)     _theme ;;
  hash)      _hash ;;
  ns)        _ns ;;
  umount)    _umount ;;
  remount)   _remount ;;
  rescan)    _rescan ;;
  replan)    _replan ;;
  prewarm-all) _prewarm_all ;;
  set-desc)
    _d=$2
    [ -n "$_d" ] || { echo "ERROR:描述为空"; exit 1; }
    if grep -q '^description=' "$MODDIR/module.prop" 2>/dev/null; then
      sed -i "s|^description=.*|description=$_d|" "$MODDIR/module.prop" 2>/dev/null
    else
      printf 'description=%s\n' "$_d" >> "$MODDIR/module.prop" 2>/dev/null
    fi
    echo "已写入：$_d"
    ;;
  theme-restore)
    if [ -f "$MODDIR/mount.sh" ]; then
      ( . "$MODDIR/mount.sh"; datafont_restore ) 2>&1 | tail -n 5
      echo "已尝试把主题字体还原成原件（重启后生效）"
    else
      echo "ERROR:没有 mount.sh"
    fi
    ;;
  targets-hits)
    _m="$LIB/scanned/slots.meta"
    if [ -s "$_m" ]; then
      echo "== 槽位来源统计 =="
      echo "  机型清单命中 : $(sed -n 's/^targets=//p' "$_m" | head -n1)"
      echo "  本机扫描补的 : $(sed -n 's/^extra=//p' "$_m" | head -n1)"
      echo "  合计         : $(sed -n 's/^total=//p' "$_m" | head -n1)"
    else
      echo "（没有 slots.meta —— 重新应用一次字体就有了）"
    fi
    echo ""
    echo "== 当前机型识别 =="
    echo "  $(tr -d '[:space:]' < "$MODDIR/current_rom" 2>/dev/null)"
    echo ""
    echo "== 机型清单文件 =="
    ls -1 "$MODDIR/targets" 2>/dev/null | head -n 12
    ;;
  lists-export)
    _o="$DL/字体名单_$(_now).txt"
    {
      echo "# 白名单（只换这些）："; cfg_get whitelist ""
      echo ""; echo "# 黑名单（这些不换）："; cfg_get blacklist ""
      echo ""; echo "# 排除目录："; cfg_get exclude_dirs ""
    } > "$_o" 2>/dev/null
    echo "已导出：$_o"
    ;;
  lists-check)
    _w=$(cfg_get whitelist ""); _b=$(cfg_get blacklist "")
    _d=$(ls -1 /system/fonts /product/fonts 2>/dev/null | tr 'A-Z' 'a-z')
    echo "== 白名单校验 =="
    if [ -z "$_w" ]; then echo "  （空）"; else
      for _x in $(printf '%s' "$_w" | tr ',;' '  '); do
        case "$_d" in *"$(printf '%s' "$_x" | tr 'A-Z' 'a-z')"*) echo "  ✓ $_x" ;; *) echo "  ✗ $_x（设备上找不到相似字体）" ;; esac
      done
    fi
    echo "== 黑名单校验 =="
    if [ -z "$_b" ]; then echo "  （空）"; else
      for _x in $(printf '%s' "$_b" | tr ',;' '  '); do
        case "$_d" in *"$(printf '%s' "$_x" | tr 'A-Z' 'a-z')"*) echo "  ✓ $_x" ;; *) echo "  ✗ $_x（设备上找不到相似字体）" ;; esac
      done
    fi
    ;;
  *) echo "用法: sh adv.sh <pack|plan|mountlog|ttclog|slots|status|selinux|avc|webview|dropbox|boot|conflicts|theme|hash|ns|umount|remount|rescan|replan>" ;;
esac
exit 0
