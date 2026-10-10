#!/system/bin/sh
# 卸载模块时：恢复本模块停用过的谷歌字体组件，并删除字体库和设置（/data/adb/custom_font_lib）。
# 注意：更新 / 覆盖安装模块不会执行本脚本，字体库会保留；只有在管理器里点「卸载」才会清理。
#
# 卸载脚本在开机早期执行，此时包管理器还没启动，所以谷歌组件放到后台等开机完成再恢复；
# 模块目录随后会被删除，因此这里不引用模块内的其他文件。

LIB=/data/adb/custom_font_lib
OWNED="$LIB/.gms_owned"

# 判断"字体库是不是还有别的保时捷配色包在用"：
# 4 个配色包共用同一个字体库 /data/adb/custom_font_lib，卸载其中一个时不能直接把它删掉，
# 否则会把还装着的那个包的字体一起干掉（表现为另一个配色突然变成方块/默认字体）。
# 注意：原来这里写死的是主项目的 id（custom_font_switcher），改 id 换皮后永远命中不了 → 见下方 porsche_font_*。
other_module_alive() {
  local d
  # ⚠️ modules_update 也要扫：用户可能刚刷了另一个配色包、还没重启，
  #    那个包已经在暂存目录里、字体也已经注入共用字体库了。只扫 modules 会漏判成
  #    "没有包活着" → rm -rf 掉字体库 → 重启后那个包的字体全没了。
  for d in /data/adb/modules/porsche_font_* /data/adb/modules_update/porsche_font_*; do
    [ -d "$d" ] || continue
    [ -f "$d/remove" ] && continue      # 它自己也在等待被卸载，不算"还活着"
    return 0
  done
  return 1
}

if [ -f "$OWNED" ]; then
  # 只有"本模块确实停用过 GMS 字体组件"时才会走到这里（.gms_owned 由 google_font.sh 在
  # 成功停用时创建），所以这里恢复组件是有意义的。
  (
    i=0
    # 等开机完成；关机中就退出（不然这个后台任务会一直活到关机窗口里，还会去调 pm 和 rm -rf）
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 600 ]; do
      [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
      sleep 2; i=$((i+1))
    done
    [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
    # 模块又装回来了（用户取消了卸载 / 重新安装），或还有别的配色包装着：绝对不能删字体库
    other_module_alive && exit 0
    sleep 5
    [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && exit 0
    other_module_alive && exit 0
    C="com.google.android.gms/com.google.android.gms.fonts.provider.FontsProvider"
    /system/bin/pm enable --user 0 "$C" >/dev/null 2>&1 || /system/bin/pm default-state --user 0 "$C" >/dev/null 2>&1
    rm -rf "$LIB"
  ) >/dev/null 2>&1 &
else
  # 没有 .gms_owned ⇒ 本模块从没停用过那个组件 ⇒ 这里**绝不能**去 pm enable，
  # 那会把用户自己（或别的工具）停用的 GMS 字体组件偷偷打开。
  # 只需要处理字体库：还有别的配色包在用就留着，否则清掉。
  if ! other_module_alive; then
    rm -rf "$LIB"
  fi
fi

exit 0
