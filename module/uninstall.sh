#!/system/bin/sh
# 卸载时先把"商店缓存桥接"还原掉（否则那些缓存文件会一直显示我们的字体）
[ -f "$MODDIR/gms_cache.sh" ] && sh "$MODDIR/gms_cache.sh" off >/dev/null 2>&1
rm -f "$LIB/.gms_cache_on" 2>/dev/null
rm -f "$LIB/.seen_version" 2>/dev/null   # ★ 版本标记（下次重装当首次）   # ★ 清缓存桥接启用标志

# 卸载模块时：恢复本模块停用过的谷歌字体组件，然后删除字体库和设置（/data/adb/custom_font_lib）。
# 注意：更新 / 覆盖安装模块不会执行本脚本，字体库会保留；只有在管理器里点「卸载」才会清理。
#
# 为什么不直接调用模块里的 google_font.sh：卸载脚本在开机早期执行、模块目录随后就会被删掉，
# 所以这份逻辑必须**自包含**（不引用模块内其他文件）。
#
# 恢复规则（跟 google_font.sh 保持一致）：
#   · 按记录里的**用户**和**原状态**还原：原来是"默认"就 default-state、原来是"启用"就 enable
#     （一律 enable 会把"默认"改成"显式启用"，属于状态污染）
#   · 试 3 次，成功才删记录
#   · 3 次都没成功：**保留那份记录**（重装模块后会自动重试），并在 Download 写一份"怎么手动处理"的说明
#     —— 硬卡住卸载在这里做不到（管理器的卸载钩子无法阻止删除模块目录），所以做成"留痕 + 可自愈"。


# ---------------------------------------------------------------------------
# ★ 2026-10-19：**卸载前先把"被物理替换的主题字体"还原回去**
#
#   模块对「设置里选的字体」那几个目录（MIUI: /data/system/theme/fonts、
#   三星: /data/overlays/font）做的是**物理替换**（不是挂载），
#   原件备份在 $LIB/.orig/ 里，manifest.txt 记着每个原件路径。
#
#   而下面会
#   而且再也自动恢复不了（真机反馈：卸载后字体改不回去、系统卡顿、只能手动救）。
#
#   自包含实现：卸载脚本不能引用模块内其它文件（模块目录马上就没了）。
# ---------------------------------------------------------------------------
_restore_theme_fonts() {
  _man="$LIB/.orig/manifest.txt"
  if [ ! -s "$_man" ]; then
    echo "没有主题字体备份（.orig/manifest.txt 不存在）：" > /sdcard/Download/CFS-卸载提醒.txt 2>/dev/null
    echo "如果卸载后字体还不对，请到 设置→显示→字体 选回默认，或清一次主题应用数据。" >> /sdcard/Download/CFS-卸载提醒.txt 2>/dev/null
    return 0
  fi
  _n=0
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    _k=$(printf '%s' "$_p" | tr '/' '_' | tr -d ' ')
    _bak="$LIB/.orig/$_k"
    if [ ! -f "$_p" ] || [ ! -s "$_bak" ]; then
      # 目标不存在 / 没有备份 → 记失败，别静默跳过（否则备份会被误删）
      printf '%s\n' "$_p" >> "$LIB/.restore.failed" 2>/dev/null
      continue
    fi
    # ★ 2026-11-06：无条件拷回（原来只比大小，同大小但内容被换过就漏了）
    if cp -f "$_bak" "$_p" 2>/dev/null; then
      _n=$((_n + 1))
    else
      printf '%s\n' "$_p" >> "$LIB/.restore.failed" 2>/dev/null
    fi
  done < "$_man"
  if [ ! -s "$LIB/.restore.failed" ]; then
    # 全部还原成功 → 备份没用了，一起删（真正卸载干净）
    rm -rf "$LIB/.orig" 2>/dev/null
  fi
  if [ -s "$LIB/.restore.failed" ]; then
    {
      echo "以下主题字体没能还原（备份还在 $LIB/.orig/）："
      cat "$LIB/.restore.failed"
      echo
      echo "手动恢复：把 $LIB/.orig/ 里对应文件拷回上面的路径，或重装一次模块再卸载。"
      echo "更省事：运行 /sdcard/Download/CFS-restore-theme.sh（root 终端执行 sh 该文件）"
    } > /sdcard/Download/CFS-卸载残留提醒.txt 2>/dev/null

  if [ -s "$LIB/.restore.failed" ]; then
    # ★ 2026-11-06：给用户留一个「一键恢复」脚本（模块卸载后也能跑）
    _fx="$LIB/restore-theme.sh"
    {
      echo '#!/system/bin/sh'
      echo '# CFS restore-theme（模块已卸载也能用；需要 root）'
      echo 'LIB=/data/adb/custom_font_lib'
      echo 'MAN="$LIB/.orig/manifest.txt"'
      echo '[ -s "$MAN" ] || { echo "没有找到备份（$MAN）"; exit 1; }'
      echo 'n=0; f=0'
      echo 'while IFS= read -r p; do'
      echo '  [ -n "$p" ] || continue'
      echo '  k=$(printf "%s" "$p" | tr "/" "_" | tr -d " ")'
      echo '  b="$LIB/.orig/$k"'
      echo '  [ -s "$b" ] || continue'
      echo '  if cp -f "$b" "$p" 2>/dev/null; then n=$((n+1)); else f=$((f+1)); echo "失败: $p" >> /sdcard/Download/CFS-恢复结果.txt; fi'
      echo 'done < "$MAN"'
      echo 'echo "已恢复 $n 个，失败 $f 个"'
      echo 'echo "已恢复 $n 个，失败 $f 个" >> /sdcard/Download/CFS-恢复结果.txt'
      echo 'if [ "$f" = 0 ]; then'
      echo '  echo "全部恢复成功，正在清理备份与提示文件…"'
      echo '  rm -rf "$LIB/.orig" "$LIB/.restore.failed" "$LIB/restore-theme.sh" 2>/dev/null'
      echo '  rm -f /sdcard/Download/CFS-restore-theme.sh /sdcard/Download/CFS-卸载残留提醒.txt /sdcard/Download/CFS-卸载提醒.txt 2>/dev/null'
      echo '  rmdir "$LIB" 2>/dev/null'
      echo 'else'
      echo '  echo "还有 $f 个没恢复：备份和本脚本会保留，可以再跑一次。"'
      echo 'fi'
      echo 'echo "完成后重启手机生效。"'
    } > "$_fx" 2>/dev/null
    chmod 755 "$_fx" 2>/dev/null
    cp -f "$_fx" /sdcard/Download/CFS-restore-theme.sh 2>/dev/null
  fi
  fi
  return 0
}

# ★ 2026-10-26 卸载时物理删除壁纸（存在模块 webroot 里，不删就会跟着下次安装回来）
rm -f "$MODDIR/webroot/bg.jpg" "$MODDIR/webroot/bg.b64" 2>/dev/null

# ★ 2026-10-26 卸载：壁纸存在用户数据目录，无条件物理删除
rm -f "$LIB/bg.jpg" "$LIB/bg.b64" 2>/dev/null

LIB=/data/adb/custom_font_lib

# ★ 2026-11-06：卸载时**保留 .orig 备份**（主题字体原件），只清其它文件。
#   原因：用户卸载后想恢复主题字体，只能靠这份备份；以前整个 LIB 被删，
#   重装也救不回来。备份不大（只含被物理替换过的那几个主题字体）。
_clean_lib() {
  [ -d "$LIB" ] || return 0
  # 有还原失败 → 保留 .orig / 失败清单；全部成功 → 全删（不留任何残留）
  _keep_bak=0
  [ -s "$LIB/.restore.failed" ] && _keep_bak=1
  for _e in "$LIB"/* "$LIB"/.[!.]*; do
    [ -e "$_e" ] || continue
    if [ "$_keep_bak" = 1 ]; then
      case "${_e##*/}" in
        .orig|.restore.failed|CFS-卸载残留提醒.txt|restore-theme.sh) continue ;;
      esac
    fi
    rm -rf "$_e" 2>/dev/null
  done
  # 全部还原成功：连目录本身也删掉
  if [ "$_keep_bak" = 0 ]; then
    rmdir "$LIB" 2>/dev/null
  fi
  return 0
}


# ---------------------------------------------------------------------------
# ★ 2026-10-22：先把**自己的挂载**卸掉，再删字体库。
#   原来不卸挂载：用户卸载模块后不重启的话，/system/fonts 上仍然是我们的字体，
#   看起来像"卸载了没生效"，而且 rm -rf 会去删正在被挂载的源文件。
#   策略：先按账本逐个 umount -l（惰性），再扫 /proc/mounts 兜底；
#   失败也不阻塞卸载（重启后自然消失），但会写进日志。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ★ 2026-10-22：**别删别人的字体库**。
#   主项目（custom_font_switcher）与子项目（porsche_font_*）共用同一个字库目录。
#   同时装了两个模块的用户，卸载其中一个时如果直接 rm -rf，另一个的字体库和设置会一起消失。
#   规则：只要还有别的字体模块处于"已安装且未被卸载"状态，就保留字库。
# ---------------------------------------------------------------------------
_other_module_present() {
  for _d in /data/adb/modules/custom_font_switcher /data/adb/modules/porsche_font_multi \
            /data/adb/modules/porsche_font_718 /data/adb/modules/porsche_font_911 \
            /data/adb/modules/porsche_font_gt3 \
            /data/adb/modules_update/custom_font_switcher /data/adb/modules_update/porsche_font_multi \
            /data/adb/modules_update/porsche_font_718 /data/adb/modules_update/porsche_font_911 \
            /data/adb/modules_update/porsche_font_gt3; do
    [ -d "$_d" ] || continue
    [ -f "$_d/remove" ] && continue
    return 0
  done
  return 1
}

_umount_ours() {
  _n=0
  [ -f "$LIB/.mounted" ] && {
    while IFS= read -r _d; do
      [ -n "$_d" ] || continue
      umount -l "$_d" 2>/dev/null && _n=$((_n+1)) && continue
      umount "$_d" 2>/dev/null && _n=$((_n+1))
    done < "$LIB/.mounted"
  }
  # 兜底：把源在我们的字体库上的挂载全部摘掉（账本可能不全）
  if [ -r /proc/mounts ]; then
    while read -r _src _dst _rest; do
      case "$_src" in
        */custom_font_lib/*|*/.clone.*)
          umount -l "$_dst" 2>/dev/null && _n=$((_n+1)) ;;
      esac
    done < /proc/mounts
  fi
  # 顺便把物理替换过的 /data 主题字体还回去（下面还有一次，幂等）
  return 0
}

_clean_tmp() {
  # 挂载/扫描/比对过程用的临时文件（都在 /data/local/tmp）
  rm -f /data/local/tmp/.pv.* /data/local/tmp/.pv.ino.* /data/local/tmp/.pv.clean.* \
        /data/local/tmp/.slots.clean.* /data/local/tmp/.oem.* /data/local/tmp/.marks.* \
        /data/local/tmp/.slots.* 2>/dev/null
  # ★ 2026-10-31：本轮新增的临时文件兜底
  rm -f /data/local/tmp/.live.* /data/local/tmp/.xr.* /data/local/tmp/.dr.* \
        /data/local/tmp/.plan.src.* /data/local/tmp/.ttccn.* /data/local/tmp/.relive.* \
        /data/local/tmp/.cfs_apply.* 2>/dev/null
  # ★ 2026-10-31：新加的两个缓存目录（.plancache 计划缓存 / .ttc.cache 合集产物）。
  #   正常路径它们随 $LIB 整体删除（都在 $LIB 内）；这里是显式兜底。
  #   ⚠ 只在"没有其它字体模块共存"时才删 —— 兄弟模块（主/子项目）共用字库与缓存，
  #   卸载其中一个时绝不能把另一个的缓存端掉。
  _other_module_present || rm -rf "$LIB/.plancache" "$LIB/.ttc.cache" 2>/dev/null
  return 0
}




# 卸载自己的挂载（必须在删字体库之前）
_umount_ours

# ★ 卸载就是"模块要没了"，主题字体的原件该还回去（详见上面函数说明）
_restore_theme_fonts
JOURNAL="$LIB/.gms_journal.conf"
LEGACY="$LIB/.gms_owned"
C="com.google.android.gms/com.google.android.gms.fonts.provider.FontsProvider"
NOTE="/data/media/0/Download/谷歌兼容未恢复-请看这里.txt"

U=""; ORIG="1"
if [ -f "$JOURNAL" ]; then
  U=$(sed -n 's/^user=//p' "$JOURNAL" 2>/dev/null | head -n1)
  ORIG=$(sed -n 's/^original=//p' "$JOURNAL" 2>/dev/null | head -n1)
fi
case "$U" in ''|*[!0-9]*) U="" ;; esac
case "$ORIG" in 0|1) ;; *) ORIG=1 ;; esac

restore_one() {   # $1 = 用户号
  if [ "$ORIG" = 0 ]; then
    /system/bin/pm default-state --user "$1" "$C" >/dev/null 2>&1 || /system/bin/pm enable --user "$1" "$C" >/dev/null 2>&1
  else
    /system/bin/pm enable --user "$1" "$C" >/dev/null 2>&1 || /system/bin/pm default-state --user "$1" "$C" >/dev/null 2>&1
  fi
}

if [ -f "$JOURNAL" ] || [ -f "$LEGACY" ]; then
  (
    i=0
    # 等开机完成；关机中就退出（不然这个后台任务会一直活到关机窗口里，还会去调 pm 和 rm -rf）
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 600 ]; do
      [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
      sleep 2; i=$((i+1))
    done
    [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
    # 模块又装回来了（用户取消了卸载 / 重新安装）：绝对不能删字体库，交给模块自己恢复
    [ -d /data/adb/modules/custom_font_switcher ] && exit 0
    sleep 5
    [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
    [ -d /data/adb/modules/custom_font_switcher ] && exit 0

    u="$U"
    if [ -z "$u" ]; then
      u=$(/system/bin/am get-current-user 2>/dev/null | tr -d '[:space:]')
      case "$u" in ''|*[!0-9]*) u=0 ;; esac
    fi
    ok=0; n=0
    while [ "$n" -lt 3 ]; do
      n=$((n+1))
      restore_one "$u" && { ok=1; break; }
      sleep 2
    done

    if [ "$ok" = 1 ]; then
      rm -f "$JOURNAL" "$LEGACY" 2>/dev/null
      if _other_module_present; then echo "[cfs] 检测到还有其它字体模块，保留字库 $LIB" >> "$LIB/.uninstall.log" 2>/dev/null; else [ -f "$LIB/.restore.failed" ] || _clean_lib; fi
    else
      # 失败：把恢复记录单独留下（重装模块后会自动重试），其余字体库照常清掉
      mkdir -p "$LIB" 2>/dev/null
      _other_module_present || _clean_lib
      {
        echo "谷歌字体兼容：自动恢复没有成功（用户 $u，原状态 $ORIG）。"
        echo
        echo "影响：Google 系应用（Play 商店 / Chrome 等）的英文数字会继续用系统字体。"
        echo "不会影响推送、账号或任何系统功能 —— 只是「下载字体」这条路还关着。"
        echo
        echo "怎么处理（任选一个）："
        echo "  1) 重新安装本模块 → 开机会自动重试恢复（记录还在：$JOURNAL）"
        echo "  2) 或者自己执行一次（需要 root）："
        echo "       pm enable --user $u $C"
        echo "     如果上面那条报错，再试："
        echo "       pm default-state --user $u $C"
      } > "$NOTE" 2>/dev/null
      chmod 666 "$NOTE" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
else
  # ★ 2026-10-19：这条路径也要判断"模块是不是又装回来了"。
  #   卸载请求排队后、开机真正执行 uninstall.sh 之前，用户可能又把它装了回去；
  #   那时模块目录在、且没有 remove 标记 —— 这种情况绝对不能删字体库，
  #   否则刚装好的模块开机就成了"字体全没了"。
  #   （有谷歌记录的那条路径本来就有这个保护，这里补齐，行为一致。）
  _reinstalled=0
  if [ -d /data/adb/modules/custom_font_switcher ]      && [ ! -f /data/adb/modules/custom_font_switcher/remove ]; then
    _reinstalled=1
  fi
  if [ -d /data/adb/modules_update/custom_font_switcher ]      && [ ! -f /data/adb/modules_update/custom_font_switcher/remove ]; then
    _reinstalled=1
  fi
  [ "$_reinstalled" = "1" ] || if _other_module_present; then echo "[cfs] 检测到还有其它字体模块，保留字库 $LIB" >> "$LIB/.uninstall.log" 2>/dev/null; else [ -f "$LIB/.restore.failed" ] || _clean_lib; fi
fi

# ---------------------------------------------------------------------------
# 自检：确认字体库真的删干净了
#
# ★ 2026-10-18（作者问「多了几个目录，卸载删干净了吗」）：
#   这一版在 $LIB 下新增了这些（都随 `
#       scanned/       刷入时扫一次的清单（device.list / slots.*.list / ttc.list /
#                      lockscreen.list / env.list / slots.meta / device.all）
#       .verify.cache  逐个核对的缓存
#       各种 .log / .state / .cache
#   万一 $LIB 因为权限或占用没删掉，这里明确报出来 —— 免得用户卸载后还留一堆垃圾。
#
#   注意：$MODDIR 下的文件不用管，管理器卸载模块时会删掉整个目录。
# ---------------------------------------------------------------------------
# ★ 2026-10-19：这个自检只在"同步删除"的路径下做。
#   有谷歌恢复记录时删除在后台子 shell 里跑，这里立刻检查会误报
#   （写一份"卸载未清干净.txt"吓用户，其实后台正在删/已删）。
_need_check=1
[ -f "$JOURNAL" ] && _need_check=0
[ -f "$LEGACY" ] && _need_check=0
# ★ 2026-10-19：模块又装回来了（目录在、且没有 remove 标记）→ 库是新的，绝不能清
[ -d /data/adb/modules/custom_font_switcher ] \
  && [ ! -f /data/adb/modules/custom_font_switcher/remove ] && _need_check=0
[ -d /data/adb/modules_update/custom_font_switcher ] \
  && [ ! -f /data/adb/modules_update/custom_font_switcher/remove ] && _need_check=0
if [ "$_need_check" = "1" ] && [ -e "$LIB" ]; then
  _left=$(find "$LIB" -mindepth 1 2>/dev/null | head -n 20)
  if [ -n "$_left" ]; then
    if _other_module_present; then echo "[cfs] 检测到还有其它字体模块，保留字库 $LIB" >> "$LIB/.uninstall.log" 2>/dev/null; else [ -f "$LIB/.restore.failed" ] || _clean_lib; fi 2>/dev/null
  fi
fi
if [ "$_need_check" = "1" ] && [ -e "$LIB" ]; then
  # 真的删不掉（极少数情况：文件被占用 / 只读挂载）
  {
    echo "字体库目录没能完全删除：$LIB"
    echo "里面剩下的："
    find "$LIB" -mindepth 1 2>/dev/null | head -n 40
    echo
    echo "可以手动删：rm -rf $LIB"
  } > /data/media/0/Download/卸载未清干净.txt 2>/dev/null
  chmod 666 /data/media/0/Download/卸载未清干净.txt 2>/dev/null
fi

# 清掉临时文件（扫描/比对遗留）
_clean_tmp

exit 0
