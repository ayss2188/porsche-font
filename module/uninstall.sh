#!/system/bin/sh
# 卸载模块时：恢复本模块停用过的谷歌字体组件，并删除字体库和设置（/data/adb/custom_font_lib）。
# 注意：更新 / 覆盖安装模块不会执行本脚本，字体库会保留；只有在管理器里点「卸载」才会清理。
#
# 卸载脚本在开机早期执行，此时包管理器还没启动，所以谷歌组件放到后台等开机完成再恢复；
# 模块目录随后会被删除，因此这里不引用模块内的其他文件。

LIB=/data/adb/custom_font_lib
OWNED="$LIB/.gms_owned"

if [ -f "$OWNED" ]; then
  (
    i=0
    # 等开机完成；关机中就退出（不然这个后台任务会一直活到关机窗口里，还会去调 pm 和 rm -rf）
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 600 ]; do
      [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
      sleep 2; i=$((i+1))
    done
    [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
    # 模块又装回来了（用户取消了卸载 / 重新安装）：绝对不能删字体库
    [ -d /data/adb/modules/custom_font_switcher ] && exit 0
    sleep 5
    [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
    [ -d /data/adb/modules/custom_font_switcher ] && exit 0
    C="com.google.android.gms/com.google.android.gms.fonts.provider.FontsProvider"
    /system/bin/pm enable --user 0 "$C" >/dev/null 2>&1 || /system/bin/pm default-state --user 0 "$C" >/dev/null 2>&1
    rm -rf "$LIB"
  ) >/dev/null 2>&1 &
else
  rm -rf "$LIB"
fi

exit 0
