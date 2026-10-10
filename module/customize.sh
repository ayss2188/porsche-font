#!/system/bin/sh
# 自定义字体切换模块 - 安装脚本（Magisk / KernelSU / APatch 通用）
# 刷机包里的文件已由管理器解压到 $MODPATH

LIB=/data/adb/custom_font_lib
MODID=$(sed -n 's/^id=//p' "$MODPATH/module.prop" | head -n1 | tr -d '\r')
OLD="/data/adb/modules/$MODID"

ui_print "*****************************************"
ui_print "  保时捷字体（内置配色版） $(sed -n 's/^version=//p' "$MODPATH/module.prop")"
ui_print "  内置三套配色 · 素装(无色) / 一点红 / 烈焰"
ui_print "*****************************************"

. "$MODPATH/common.sh"
mkdir -p "$LIB"

# ---------------------------------------------------------------------------
# 内置字体：把模块自带的配色注入字体库（硬链接，同一分区不额外占空间），
# 并把其它保时捷模块标记为重启后卸载（4 个配色包共用同一批 id 之外还各有 id）
# ---------------------------------------------------------------------------
MODDIR="$MODPATH"                      # builtin.sh 里用的是 $MODDIR
if [ -f "$MODPATH/builtin.sh" ]; then
  . "$MODPATH/builtin.sh"
  builtin_sibling_cleanup "$MODID"
  builtin_import
fi

ROM_ID=$(detect_rom)
ROM_NAME=$(rom_name "$ROM_ID")
RM=$(root_manager)
echo "$ROM_ID" > "$MODPATH/current_rom"

# 旧版设置在模块目录里，迁移到字体库目录（以后更新不会丢）
[ -f "$SETTINGS" ] || { [ -f "$OLD/settings.conf" ] && cp -f "$OLD/settings.conf" "$SETTINGS"; }

# 当前实际生效的字体（升级前的状态），用于界面显示"当前 / 待生效"
A=$(tr -d '[:space:]' 2>/dev/null < "$OLD/active_font")
[ -n "$A" ] || A=none
echo "$A" > "$MODPATH/active_font"
echo none > "$MODPATH/pending_font"

# 上次的选择：优先字体库记录，其次旧模块的待生效记录
LAST=$(tr -d '[:space:]' 2>/dev/null < "$LIB/last_selection")
[ -n "$LAST" ] || LAST=$(tr -d '[:space:]' 2>/dev/null < "$OLD/pending_font")
[ -n "$LAST" ] || LAST=none

for f in common.sh slots.sh mount.sh fontctl.sh update.sh google_font.sh action.sh \
         diag.sh post-fs-data.sh post-mount.sh service.sh uninstall.sh; do
  chmod 755 "$MODPATH/$f" 2>/dev/null
done
rm -f "$MODPATH/customize.sh.bak" 2>/dev/null

ui_print " "
ui_print "- 识别到系统：$ROM_NAME"
ui_print "- Root 管理器：$(root_manager_name "$RM")"
ui_print "- 挂载方式：$([ "$(mount_mode)" = manager ] && echo 交给管理器/元模块 || echo 模块自带挂载（无需元模块）)"

RESTORED=0
if [ "$LAST" != none ]; then
  ui_print "- 正在恢复上次的字体选择..."
  OUT=$(sh "$MODPATH/fontctl.sh" apply "$LAST" 2>&1 | tail -n1)
  case "$OUT" in
    OK:*)
      RESTORED=1
      ui_print "  已恢复：$(echo "$OUT" | cut -d: -f2)（$(echo "$OUT" | cut -d: -f3) 个槽位）"
      ;;
    *)
      ui_print "  恢复失败：${OUT#ERROR:}"
      ui_print "  已改为「无字体」，请开机后在 WebUI 重新选择"
      ;;
  esac
fi
[ "$RESTORED" = 1 ] || sh "$MODPATH/fontctl.sh" apply none >/dev/null 2>&1

# 首次安装：用音量键选初始配色（只有一个配色时会自动选中，不打扰用户）
if command -v builtin_menu >/dev/null 2>&1; then
  builtin_menu
fi
sh "$MODPATH/fontctl.sh" prop >/dev/null 2>&1

LIB_COUNT=$(ls "$LIB"/*.ttf 2>/dev/null | wc -l)
CONFLICTS=$(sh "$MODPATH/fontctl.sh" conflicts 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')

ui_print " "
ui_print "===================================="
ui_print "内置配色：$LIB_COUNT 个（可直接在 WebUI 切换）"
ui_print "更新模块不会丢失字体库；卸载模块会一并删除"
ui_print "===================================="
ui_print "使用方法：在模块管理器打开【WebUI】"
ui_print "  1. 打开 WebUI 切换配色（素装 / 一点红 / 烈焰）"
ui_print "  2. 也可以导入自己的 TTF/OTF 字体（可多选）"
ui_print "  3. 重启生效；选「无字体」即恢复默认"
if [ "$RM" = magisk ]; then
  ui_print " "
  ui_print "Magisk 没有 WebUI 入口：请安装 KsuWebUI"
  ui_print "后点模块卡片上的「操作」按钮打开。"
fi
if [ -n "$CONFLICTS" ]; then
  ui_print " "
  ui_print "⚠ 检测到其他字体模块：$CONFLICTS"
  ui_print "  建议先停用它们，避免互相覆盖。"
fi
ui_print " "
ui_print "若选字体后没能开机，下次开机会自动"
ui_print "恢复为「无字体」。"

# ---------------------------------------------------------------------------
# 安装阶段不做任何耗时收集（避免刷入卡住）
#   这里只做几个文件判断 + getprop，毫秒级完成；完整诊断报告由用户手动触发：
#     · WebUI 里点「查看诊断报告」或「保存到 Download」（后台生成，界面不卡）
#     · 或点模块卡片的「操作」按钮
# ---------------------------------------------------------------------------
GD="无"; [ -f "$OLD/disable" ] && GD="有"
GU="无"; [ -f "$OLD/update" ] && GU="有（上一次安装没被激活）"
GS="无"; case "$(getprop persist.sys.safemode)$(getprop ro.sys.safemode)" in *1*) GS="有" ;; esac
GM="无"; { command -v magisk >/dev/null 2>&1 || [ -e /data/adb/magisk ]; } && GM="有"
ui_print " "
ui_print "- 设备：$(getprop ro.product.brand) $(getprop ro.product.model) / Android $(getprop ro.build.version.release)"
ui_print "- 门禁速查：已禁用=$GD  待激活=$GU  安全模式=$GS  Magisk共存=$GM"
ui_print "- 需要诊断报告时（一分钟内出结果）：在 WebUI 里点「查看诊断报告」，"
ui_print "  或点模块卡片上的「操作」按钮（不用再手动保存，生成完会自动落到 Download）；"
ui_print "  快速体检写到 Download/快速体检报告.txt，完整报告写到 完整体检报告.txt"
if [ -f "$MODPATH/diag.sh" ]; then
  cp -f "$MODPATH/diag.sh" /data/local/tmp/font_diag.sh 2>/dev/null
  chmod 755 /data/local/tmp/font_diag.sh 2>/dev/null
fi
ui_print "===================================="
ui_print "- 完成"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in common.sh slots.sh mount.sh fontctl.sh update.sh google_font.sh action.sh \
         diag.sh post-fs-data.sh post-mount.sh service.sh uninstall.sh; do
  set_perm "$MODPATH/$f" 0 0 0755
done
