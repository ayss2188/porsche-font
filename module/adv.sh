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
  _found=0
  for _d in /data/adb/modules/*; do
    [ -d "$_d" ] || continue
    _mid=${_d##*/}
    [ "$_mid" = "$_me" ] && continue
    [ -d "$_d/system/fonts" ] || continue
    _n=$(ls -1 "$_d/system/fonts" 2>/dev/null | grep -c .)
    echo "  模块 $_mid 里有 $_n 个字体文件"
    _found=1
  done
  [ "$_found" = 0 ] && echo "  （没有其它模块带 system/fonts）"
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

case "${1:-}" in
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
