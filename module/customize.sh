#!/system/bin/sh
# 保时捷字体（内置配色版）- 安装脚本（Magisk / KernelSU / APatch 通用）
#
# ⚠️ 两个目录别搞混（这个模块踩过坑）：
#     $MODPATH  安装时的**暂存**目录（/data/adb/modules_update/<id>），zip 解到这里；
#               zip 里不带 pending_font / active_font 等状态文件，别在这儿读旧状态。
#     $OLD      **已安装**的模块目录（/data/adb/modules/<id>），用户上次的选择在这里。

LIB=/data/adb/custom_font_lib
MODID=$(sed -n 's/^id=//p' "$MODPATH/module.prop" | head -n1 | tr -d '\r')
OLD="/data/adb/modules/$MODID"

ui_print "*****************************************"
ui_print "  保时捷字体（内置配色版） $(sed -n 's/^version=//p' "$MODPATH/module.prop")"
ui_print "  内置配色 · 素装(无色) / 一点红 / 烈焰"
ui_print "*****************************************"

. "$MODPATH/common.sh"
mkdir -p "$LIB"

# ---------------------------------------------------------------------------
# 内置字体：把模块自带的配色注入字体库（硬链接，同一分区不额外占空间），
# 并把其它保时捷模块标记为重启后卸载（4 个包 id 各不相同，同时装会互相抢字体）
# ---------------------------------------------------------------------------
MODDIR="$MODPATH"                      # 注意：这是暂存目录！已安装目录是 $OLD
if [ -f "$MODPATH/builtin.sh" ]; then
  . "$MODPATH/builtin.sh"
  builtin_sibling_cleanup "$MODID"
  builtin_import
  # 清掉字体库里没人用的旧字体（在用的会保留；$OLD/$LIB 都参与"在用"判断）
  builtin_clean_legacy
fi

ROM_ID=$(detect_rom)
ROM_NAME=$(rom_name "$ROM_ID")
RM=$(root_manager)
echo "$ROM_ID" > "$MODPATH/current_rom"

# 旧版设置在模块目录里，迁移到字体库目录（以后更新不会丢）
[ -f "$SETTINGS" ] || { [ -f "$OLD/settings.conf" ] && cp -f "$OLD/settings.conf" "$SETTINGS"; }

# 上次的选择：优先字体库记录，其次已安装模块的待生效记录
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
      # 第 4 段（可选）= 计划里"设备上不存在"因而被跳过的槽位数，正常是 0
      _SK=$(echo "$OUT" | cut -d: -f5)
      case "$_SK" in ""|0) _SKTXT="" ;; *) _SKTXT="，跳过 $_SK 个不存在的槽位" ;; esac
      ui_print "  已恢复：$(echo "$OUT" | cut -d: -f2)（$(echo "$OUT" | cut -d: -f3) 个槽位$_SKTXT）"
      ;;
    *)
      ui_print "  恢复失败：${OUT#ERROR:}"
      ui_print "  已改为「无字体」，请开机后在 WebUI 重新选择"
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 选初始配色（音量键；只有一个配色时自动选中）
#
# ⚠️ 必须在写 pending_font **之前**调用：
#    builtin_menu 靠"已安装目录里 pending_font 是否为空"判断要不要打扰用户
#    （重刷同一版本时应该直接沿用原选择、不弹菜单）。如果先写了 none，那个判断
#    永远为假 → 每次更新都弹菜单，老用户随手按一下音量[上]就把配色静默换成第一项。
# ---------------------------------------------------------------------------
if command -v builtin_menu >/dev/null 2>&1; then
  builtin_menu
fi

# ---------------------------------------------------------------------------
# 装完自检：选了配色就必须留下挂载计划（slots.map）
#
# 为什么要有这一段：真机上出过一次"选了配色、也报了 OK，但 slots.map 没落盘"，
# 结果开机后一个槽位都挂不上，界面上只写「本次开机未挂载」，用户完全不知道哪一步坏了。
# 这类失败必须在**刷入时**就喊出来，而不是等到开机后让用户猜。
# ---------------------------------------------------------------------------
PEND=$(tr -d '[:space:]' 2>/dev/null < "$MODPATH/pending_font")
case "$PEND" in
  ""|none) : ;;
  *)
    if [ ! -s "$MODPATH/slots.map" ]; then
      ui_print " "
      ui_print "⚠ 挂载计划没有生成（slots.map 为空）"
      ui_print "  字体库:$(ls "$LIB"/builtin_*.ttf 2>/dev/null | wc -l | tr -d ' ') 个自带配色"
      ui_print "  修复尝试：重新生成一次…"
      OUT2=$(sh "$MODPATH/fontctl.sh" apply "$PEND" 2>&1 | tail -n1)
      if [ -s "$MODPATH/slots.map" ]; then
        ui_print "  ✓ 已修复：$(echo "$OUT2" | cut -d: -f3) 个槽位"
      else
        ui_print "  ✗ 仍然失败：${OUT2#ERROR:}"
        ui_print "  开机后在 WebUI 里点「查看诊断报告」，把报告发给作者"
      fi
      ui_print " "
      # 把这次的现场记到诊断报告里，供作者定位"第一次 apply 为什么没落盘"
      {
        echo "=== 安装时的挂载计划自检（$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)）==="
        echo "MODPATH=$MODPATH"
        echo "LIB=$LIB  自带配色=$(ls "$LIB"/builtin_*.ttf 2>/dev/null | wc -l | tr -d ' ') 个"
        echo "current_rom=[$(cat "$MODPATH/current_rom" 2>/dev/null | tr -d '[:space:]')]  payload.mode=[$(cat "$MODPATH/payload.mode" 2>/dev/null | tr -d '[:space:]')]"
        echo "settings.conf: $(tr '\n' ' ' < "$LIB/settings.conf" 2>/dev/null)"
        echo "目标字体现存: $(ls -1 /system/fonts 2>/dev/null | wc -l | tr -d ' ') 个（/system/fonts）"
        echo "第一次 apply 的输出: ${OUT2:-（空）}"
        echo "重试后 slots.map: $(wc -l < "$MODPATH/slots.map" 2>/dev/null | tr -d ' ') 行"
        echo "重试后 slots.applied: $(wc -l < "$MODPATH/slots.applied" 2>/dev/null | tr -d ' ') 行"
      } > "$LIB/install-selfcheck.log" 2>/dev/null
    fi
    ;;
esac

# 当前实际生效的字体（升级前的状态），用于界面显示"当前 / 待生效"。
# ⚠️ 这里**不写 pending_font**：它由上面的 builtin_menu 写（新装/首次选配色），
#    或者由 fontctl.sh apply 写（恢复上次选择）。以前这里无条件写 none，
#    结果菜单的"已有选择就别打扰"判断永远失效，而且把用户的恢复意图也抹掉了。
A=$(tr -d '[:space:]' 2>/dev/null < "$OLD/active_font")
[ -n "$A" ] || A=none
echo "$A" > "$MODPATH/active_font"
sh "$MODPATH/fontctl.sh" prop >/dev/null 2>&1

# 只数本模块自带的配色（别把用户/姊妹项目导入的 f<时间戳> 字体也算进来）
LIB_COUNT=$(lib_font_ids 2>/dev/null | grep -c '^builtin_')
CONFLICTS=$(sh "$MODPATH/fontctl.sh" conflicts 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')

ui_print " "
ui_print "===================================="
ui_print "内置配色：$LIB_COUNT 个（可直接在 WebUI 切换）"
ui_print "更新模块不会丢失字体库；卸载模块会一并删除"
ui_print "===================================="
ui_print "使用方法：在模块管理器打开【WebUI】"
ui_print "  1. 打开 WebUI 切换配色（素装 / 一点红 / 烈焰）"
ui_print "  2. 重启生效；选「无字体」即恢复系统默认"
ui_print "  （本版为内置配色版，不支持导入外部字体）"
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
ui_print "若选的配色导致没能开机，下次开机会自动"
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
