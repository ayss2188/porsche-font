#!/system/bin/sh
# 卸载时先把"商店缓存桥接"还原掉（否则那些缓存文件会一直显示我们的字体）
[ -f "$MODDIR/gms_cache.sh" ] && sh "$MODDIR/gms_cache.sh" off >/dev/null 2>&1

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

LIB=/data/adb/custom_font_lib
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
    #
    # ⚠️ 本项目差异（重放项 7）：这里**不能写死模块 id**。
    #    主项目只有一个 id（custom_font_switcher），保时捷这边有 4 个包、4 个 id
    #    （porsche_font_multi / _718 / _911 / _gt3），它们**共用同一个字体库**。
    #    只要还装着**任意一个**配色包，字体库就不能删 —— 写死某一个 id 的话，
    #    卸载另一个配色包时这里永远命中不了，会把还在用的字体库 rm -rf 掉。
    #    同时要扫 modules_update（刚刷了新包还没重启，模块在那边）。
    _sibling_alive() {
      local d
      for d in /data/adb/modules/porsche_font_* /data/adb/modules_update/porsche_font_*; do
        [ -d "$d" ] && return 0
      done
      return 1
    }
    _sibling_alive && exit 0
    sleep 5
    [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
    _sibling_alive && exit 0

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
      rm -rf "$LIB"
    else
      # 失败：把恢复记录单独留下（重装模块后会自动重试），其余字体库照常清掉
      mkdir -p "$LIB" 2>/dev/null
      find "$LIB" -mindepth 1 ! -name '.gms_journal.conf' -exec rm -rf {} + 2>/dev/null
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
  rm -rf "$LIB"
fi

exit 0
