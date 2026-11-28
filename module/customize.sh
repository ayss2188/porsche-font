#!/system/bin/sh
# ★ 2026-10-31：壁纸的持久正本在 $LIBROOT/bg.jpg，webroot 里的副本在下面（LIB 赋值后）恢复。
#   （旧版这里是把 webroot/bg.jpg 删掉 —— 那正是"更新模块后壁纸消失、二级界面卡片重叠"的原因）
# 自定义字体切换模块 - 安装脚本（Magisk / KernelSU / APatch 通用）
# 刷机包里的文件已由管理器解压到 $MODPATH

LIBROOT="${LIBROOT:-/data/adb/custom_font_lib}"
LIB="$LIBROOT/fonts"
MODDIR="$MODPATH"
export MODDIR
[ -f "$MODPATH/common.sh" ] && . "$MODPATH/common.sh"
chmod 755 "$MODPATH/bin/cfs-verify" "$MODPATH/engine.sh" 2>/dev/null

# 字体包不是模块：在 Root 管理器里刷入时立刻说清楚并中止
if [ -f "$MODPATH/font.prop" ]; then
  ui_print "=================================================="
  ui_print "  This is a FONT PACK, not a module."
  ui_print "  这是一个【字体包】，不是独立模块。"
  ui_print ""
  ui_print "  Please open the font module WebUI:"
  ui_print "  请打开字体模块 WebUI："
  ui_print "  字体工具箱 -> 字体更新 -> 安装字体 -> 从本地导入"
  ui_print "=================================================="
  abort "Font pack cannot be installed from the root manager / 字体包不能从 Root 管理器安装"
fi

# 卸载后必须重启：同一 boot_id 内禁止重新安装
_PENDING_UN="/data/adb/cfs_uninstall_pending"
if [ -f "$_PENDING_UN" ]; then
  _UN_BOOT=$(sed -n 's/^[^|]*|//p' "$_PENDING_UN" 2>/dev/null | head -n1 | tr -d '[:space:]')
  _NOW_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '[:space:]')
  if [ -z "$_UN_BOOT" ] || [ "$_UN_BOOT" = "$_NOW_BOOT" ]; then
    # 卸载脚本如果是在本次开机才真正执行完，模块目录已经不存在，
    # 说明卸载已经完成，不再要求第二次重启。
    if [ -d /data/adb/modules/porsche_font_multi ] || \
       [ -d /data/adb/modules/porsche_font_718 ] || \
       [ -d /data/adb/modules/porsche_font_911 ] || \
       [ -d /data/adb/modules/porsche_font_gt3 ]; then
      ui_print "! 检测到模块刚卸载，尚未重启"
      ui_print "  请先重启手机，完成卸载后再安装"
      abort "请先重启完成卸载"
    fi
  fi
  rm -f "$_PENDING_UN" 2>/dev/null
fi

# porsche 与主模块互斥；卸载未重启时也拒绝安装
for _od in /data/adb/modules/custom_font_switcher /data/adb/modules_update/custom_font_switcher; do
  [ -d "$_od" ] || continue
  if [ -f "$_od/remove" ]; then
    ui_print "! 检测到主模块正在卸载，尚未重启"
    ui_print "  请先重启手机，完成卸载后再安装 porsche"
    abort "请先重启完成主模块卸载"
  fi
  ui_print "! 检测到已安装主模块：custom_font_switcher"
  ui_print "  主模块与 porsche 不能同时安装"
  ui_print "  请先在管理器里卸载主模块，重启后再安装 porsche"
  abort "请先卸载主模块并重启"
done

# ★ 2026-10-31：把用户壁纸从永久目录还原到 webroot（更新模块 = webroot 整个被换掉）
if [ -s "$LIBROOT/bg.jpg" ]; then
  cp -f "$LIBROOT/bg.jpg" "$MODPATH/webroot/bg.jpg" 2>/dev/null
  chmod 644 "$MODPATH/webroot/bg.jpg" 2>/dev/null
fi

# ★ 2026-10-31：**安装号只在首次安装生成**（覆盖安装 / 升级不变）。
#   WebUI 用它判断"是不是重装"来决定要不要重置界面设置 ——
#   旧版每次安装都重写，升级一次就把用户的壁纸/配色/高级解锁全清了（真机反馈）。
#   卸载时 $LIB 整体删除 → 重装会生成新号 → 那种情况照旧重置（语义正确）。
MODID=$(sed -n 's/^id=//p' "$MODPATH/module.prop" | head -n1 | tr -d '\r')
OLD="/data/adb/modules/$MODID"
if [ -d "$OLD" ] && [ ! -f "$OLD/remove" ]; then
  printf 'update\n' > "$STATEDIR/install_mode" 2>/dev/null
else
  printf 'fresh\n' > "$STATEDIR/install_mode" 2>/dev/null
fi
[ -s "$STATEDIR/install_id" ] || date +%s > "$STATEDIR/install_id" 2>/dev/null

# ---------------------------------------------------------------------------
# lite 更新包：不带 builtin 字体，只能覆盖 4.6.0+ 已经迁移过目录的安装。
# 4.5.x 必须先刷完整 4.6.0，不能靠 lite 跳过目录迁移。
# ---------------------------------------------------------------------------
_LITE_PKG=0
if [ ! -d "$MODPATH/builtin" ] || ! ls "$MODPATH"/builtin/*.ttf >/dev/null 2>&1; then
  _LITE_PKG=1
  _old_code=$(sed -n 's/^versionCode=//p' "$OLD/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
  _old_layout=$(cat "$LIBROOT/.layout_version" 2>/dev/null | tr -d '\r')
  case "$_old_code" in ''|*[!0-9]*) _old_code=0 ;; esac
  case "$_old_layout" in ''|*[!0-9]*) _old_layout=0 ;; esac
  if [ ! -d "$OLD" ] && [ ! -d "$MODPATH/builtin" ]; then
    ui_print "! 这是 lite 更新包，但设备上没有已安装的旧模块"
    ui_print "! 请先刷完整模块包（内含 builtin 字体）"
    abort "lite 更新包不能作为首次安装包；请先安装完整包"
  fi
  if [ "$_old_code" -lt 460000 ] || [ "$_old_layout" -lt 2 ]; then
    ui_print "! 检测到旧模块 versionCode=$_old_code，布局=$_old_layout"
    ui_print "! lite 更新包要求先升级到 4.6.0 完整包并完成目录迁移"
    abort "旧版本不能直接使用 lite 更新包；请先安装 4.6.0 完整包"
  fi
  if ! ls "$LIB"/builtin_*.ttf >/dev/null 2>&1; then
    ui_print "! 没有检测到已导入的内置字体"
    ui_print "! 请先安装一次 4.6.0 完整包，再使用 lite 更新包"
    abort "缺少内置字体；请先安装完整包"
  fi
  ui_print "- 检测到 lite 更新包：保留现有内置字体，只更新模块代码"
fi

ui_print "*********************************"
ui_print "  保时捷字体配色模块 $(sed -n 's/^version=//p' "$MODPATH/module.prop")"
ui_print "  默认不替换字体"
ui_print "  内置三套配色字体一键切换"
ui_print "*****************************"

if lib_layout_should_migrate; then
  ui_print "- 正在整理字体库目录（首次迁移会慢一点）..."
  ui_print "! 库内容：$(ls -la "$LIBROOT" 2>&1 | tr '\n' '|' | cut -c1-300)"
  ui_print "! 空间：$(df -h "$LIBROOT" 2>&1 | tail -n1)"
fi
if ! lib_layout_migrate; then
  ui_print "! 迁移失败：布局版本=$(cat "$LIBROOT/.layout_version" 2>/dev/null) 字体=$(ls "$LIBROOT/fonts"/f*.ttf 2>/dev/null | wc -l) 内置=$(ls "$LIBROOT/builtin"/builtin_*.ttf 2>/dev/null | wc -l) 时钟=$(ls "$LIBROOT/clock"/*.clock.*.ttf 2>/dev/null | wc -l)"
ui_print "! 清单=$(wc -l < "$LIBROOT/.layout_manifest" 2>/dev/null) 缺失=$(awk -F'|' '$1 && !system("test -f '"$1"'"){n++} END{print n+0}' "$LIBROOT/.layout_manifest" 2>/dev/null)"
ui_print "! 根目录：$(ls -ld "$LIBROOT" 2>&1 | tr -s ' ')"
ui_print "! 字体库迁移失败：未改动旧数据，已取消本次刷入"
  abort "字体库迁移失败，请重试"
lib_layout_legacy_state
fi
mkdir -p "$LIB"

# 1.0.9：识别机型要读全部系统属性、还要找厂商目录，会花一两秒。
#   特意把话说在前面，免得用户看管理器"卡在那儿不动"以为死机了。
#   这一阶段等一下完全没问题 —— 它不是开机流程，不影响开机时间。
ui_print "- 正在检测你的机型与字体配置，请稍等…"
ROM_ID=$(detect_rom)
ROM_NAME=$(rom_name "$ROM_ID")
RM=$(root_manager)
echo "$ROM_ID" > "$MODPATH/current_rom"
_rov_inst=$(cfg_get rom_override auto 2>/dev/null)
case "$_rov_inst" in auto|"") ;; *) ROM_NAME="$ROM_NAME（手动指定）" ;; esac
ui_print "- 已识别：$ROM_NAME"

# ★ 2026-10-17（开发者定的架构）：**扫描只在这里做一次，之后永远读文件**
#
# 开发者原话：「扫描是在什么时候，就是安装的时候那一次扫描，
#            把扫描到的东西全部加进文件里永久保存，除非卸载模块」
#
# 这一步把"这台设备上有哪些字体、各自什么角色、在哪个目录"全部写进
# $STATEDIR/device_fonts。之后 apply / reapply **只读这个文件** ——
# 不再解析 8 个字体配置 XML，也不再扫十几个字体目录。
#
# 什么时候需要重扫：
#   · 换了一整套系统字体（或系统大版本更新）
#   · 界面里字体少得不对劲
#   → 跑 `fontctl.sh rescan`（见模块目录的说明）
MODDIR="$MODPATH"
export MODDIR
. "$MODPATH/slots.sh" 2>/dev/null
# ★ 2026-10-19（设计）：**从旧版本升上来，一律重新扫描 + 重新合成**。
#   旧版留下的派生数据不能信：
#     · 1.3.5~1.3.7 的 scanned/ttc.list 写的时候被自己截断成空，
#       读取端把"空"当结论 → 中文合集永久不换（三星中文一直没变过）
#     · 旧的合成 .ttc 可能是在"只换 2 号"的兜底逻辑下造的，照用就是错的
#   所以版本号一变就整份作废，让 slot_build_slots 重新扫、让 apply 重新合成。
#   字体文件 / .name / .meta / settings.conf / last_selection 都不动（用户数据）。
# 扫描是否重做只看 scanmarks.conf（slot/font 版本），不看模块 versionCode。
# 这样 4.6.0 -> 4.6.1 这种只改功能、不改扫描逻辑的升级不会反复重扫。
# 旧版遗留的 scan/.scan_version 不再作为依据。

# ★ 2026-10-19：补齐缺失的字体大小记录。
#   界面显示字体大小读的是 meta 里的 size= / outline_sz=（都是导入时写好的真实字节数）。
#   极少数旧记录两个都没有，界面就会显示成「—」。这里一次性补上：
#   只在"两个都没有"时才追加，已有记录一个字不动。
for _mf in "$LIB"/*.meta; do
  [ -f "$_mf" ] || continue
  grep -q '^size=\|^outline_sz=' "$_mf" 2>/dev/null && continue
  _tf="${_mf%.meta}.ttf"
  [ -f "$_tf" ] || continue
  _bsz=$(stat -c '%s' "$_tf" 2>/dev/null | tr -dc '0-9')
  [ -n "$_bsz" ] || _bsz=$(wc -c < "$_tf" 2>/dev/null | tr -dc '0-9')
  [ -n "$_bsz" ] || continue
  printf 'size=%s\n' "$_bsz" >> "$_mf" 2>/dev/null
done


if command -v slot_build_slots >/dev/null 2>&1; then
  # ★ 2026-10-18：文案要如实 —— 首次安装才真扫描；升级时复用上次的扫描结果，
  #   只重新做"和 targets 的合并"，所以很快。别让用户以为每次都在扫。
  if [ -s "$STATEDIR/scan/device.list" ]; then
    ui_print "- 正在更新槽位清单（复用上次扫描结果，不用重扫）…"
  else
    ui_print "- 正在扫描本机字体并生成槽位清单（只这一次，以后切换都不再扫描）…"
  fi
  if slot_build_slots "$MODPATH" 2>/dev/null; then
    # 口径：机型清单里的 = targets 里且设备上真实存在的；本机扫描补的 = 其余
    _tn=$(sed -n 's/^targets=//p' "$STATEDIR/scan/slots.meta" 2>/dev/null)
    _en=$(sed -n 's/^extra=//p' "$STATEDIR/scan/slots.meta" 2>/dev/null)
    _an=$(sed -n 's/^total=//p' "$STATEDIR/scan/slots.meta" 2>/dev/null)
    ui_print "- 槽位总数 ${_an:-?} 个（机型清单 ${_tn:-0} 个 + 本机扫描补 ${_en:-0} 个）"
  else
    ui_print "- 清单生成未完成（第一次切换时会自动再试）"
  fi
fi

# 2026-10-28：安装环境扫不出槽位时（厂商分区没挂上），沿用升级前的清单
if [ ! -s "$STATEDIR/scan/slots.list" ] && [ -s "$STATEDIR/scan.old/slots.list" ]; then
  rm -rf "$STATEDIR/scan" 2>/dev/null
  mv -f "$STATEDIR/scan.old" "$STATEDIR/scan" 2>/dev/null
  ui_print "- 这次没扫到槽位，已沿用上次的清单（进界面可点「重新数一遍系统的字体」重扫）"
else
  rm -rf "$STATEDIR/scan.old" 2>/dev/null
fi

# ============================================================================
# 升级迁移（2026-10-18，v1.3.1 架构改动）
#
# 这一版把"每次切换都扫描"改成了"刷入时扫一次、之后只读清单"，
# 所以从旧版升级上来时要收拾一下旧残留，否则可能读到过时的东西。
#
# ⚠️ 原则：**只清"模块自己生成的中间文件"，绝对不碰用户的字体库**。
#    字体库 = $LIB/f*.ttf + *.meta + *.name + builtin_* ← 一个字都不动。
# ============================================================================
_OLDVER=$(sed -n 's/^version=//p' "$OLD/module.prop" 2>/dev/null | head -n1 | tr -d '\r\n')
_NEWVER=$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -n1 | tr -d '\r\n')
# ---------------------------------------------------------------------------
# 判断该不该"迁移"：**看实际状态，不看版本号**
#
#   scanned/device.list 存在 = 这台机器已经有扫描结果（新架构装过，或之前扫过）
#     → 只更新清单，**不迁移、不重扫**（哪怕版本号变了，v1.3.1 → v1.3.2 也走这条）
#   不存在 = 旧架构装过 / 全新安装
#     → 清掉旧架构的中间文件，然后扫一次（只有这一次）
#
# 为什么不用版本号判断：版本号每升一次都会变，但"要不要迁移"取决于
# **上次是不是旧架构的产物**，而不是版本号本身。
# ---------------------------------------------------------------------------
# 扫描结果的可信度检查：太小就当没扫过（半成品不能用）
_DCNT=$(grep -c . "$STATEDIR/scan/device.list" 2>/dev/null || echo 0)
case "${_DCNT:-0}" in ''|*[!0-9]*) _DCNT=0 ;; esac
if [ "${_DCNT}" -ge 10 ]; then
  # ★ 2026-10-19：刚才是"版本变了→强制重扫"，就不能再说"直接复用"（真机日志会自相矛盾）
  if [ "${_FORCED_RESCAN:-0}" = "1" ]; then
    [ -n "$_OLDVER" ] && [ "$_OLDVER" != "$_NEWVER" ] && ui_print "- 从 $_OLDVER 升级到 $_NEWVER：已重新扫描（$_DCNT 条）并重建中文合集"
  else
    [ -n "$_OLDVER" ] && [ "$_OLDVER" != "$_NEWVER" ] && ui_print "- 从 $_OLDVER 升级到 $_NEWVER（已有扫描结果 $_DCNT 条，直接复用）"
  fi
else
  [ "${_DCNT}" -gt 0 ] && ui_print "- 上次的扫描结果不完整（只有 $_DCNT 条），重新扫一次"
  if [ -n "$_OLDVER" ] && [ "$_OLDVER" != "$_NEWVER" ]; then
    ui_print "- 从 $_OLDVER 升级到 $_NEWVER：架构有变，需要重新扫描一次"
    # ① 旧架构的缓存文件（新版完全不用它们了）
    rm -f "$STATEDIR/cand.cache" "$STATEDIR/plan.cache" "$STATEDIR/plan.marks" \
          "$STATEDIR/skipscan.cache" "$STATEDIR/extra.cache" "$STATEDIR/xmlnames.cache" \
          "$STATEDIR/dirnames.cache" "$STATEDIR/oemnames.cache" "$STATEDIR/verify.cache" \
          "$STATEDIR/conflicts.cache" 2>/dev/null
    rm -rf "$STATEDIR/scan/.scan" 2>/dev/null
    # ② 旧版的挂载状态 / 计划（让新版按新清单重新生成）
    rm -f "$MODPATH/slots.map" "$MODPATH/slots.applied" "$MODPATH/slots.marks" \
          "$MODPATH/slots.sources" "$MODPATH/mount.state" 2>/dev/null
    # ③ 旧版把扫描结果存在过别的文件名里
    rm -f "$STATEDIR/device_fonts" 2>/dev/null
    ui_print "- 已清理旧版中间文件（字体库原样保留）"
  fi
fi

# 旧版设置在模块目录里，迁移到字体库目录（以后更新不会丢）
[ -f "$SETTINGS" ] || { [ -f "$OLD/settings.conf" ] && cp -f "$OLD/settings.conf" "$SETTINGS"; }

# 当前实际生效的字体（升级前的状态），用于界面显示"当前 / 待生效"
A=$(tr -d '[:space:]' 2>/dev/null < "$OLD/active_font")
[ -n "$A" ] || A=none
echo "$A" > "$MODPATH/active_font"
echo none > "$MODPATH/pending_font"

# 上次的选择：**尽量保住用户正在用的那套**（升级体验的关键）
#
# ⚠️ 原来这条链有两个毛病：
#   ① **`$OLD/active_font`（当前真正在用的）没被读** —— 它才是最该恢复的那个。
#      `pending_font` 只在"选完还没重启"时有意义；正常用着的时候它常常是 none。
#   ② `[ -n "$LAST" ] ||` 把 **"none" 也当成有效值** ——
#      于是 pending_font 里写着 none 时它挡住后面的来源，最后 apply none
#      → 用户升级完字体没了（真机反馈过"更新后变回默认"）。
#   现在：**跳过空值和 none**，一路找到第一个真正可用的来源。
#   顺序：字体库记录 → **当前生效** → 待生效
_pick() {   # $1=文件；echo 出值（空/none 视为无值）
  local v
  v=$(tr -d '[:space:]' 2>/dev/null < "$1")
  case "$v" in ""|none) return 0 ;; esac
  printf '%s' "$v"
}
LAST=$(_pick "$STATEDIR/last_selection")
[ -n "$LAST" ] || LAST=$(_pick "$OLD/active_font")     # ★ 当前真正在用的
[ -n "$LAST" ] || LAST=$(_pick "$OLD/pending_font")
# ★ 2026-10-16（B1）兜底一：.last_good —— 最近一次**真正生效过**的字体。
#   它刻意不被 apply none 覆盖，所以能区分"记录丢了"和"确实选了无字体"。
#   （用户真的选了无字体时它已被删掉，这里自然拿不到 → 保持 none，符合用户意图）
[ -n "$LAST" ] || LAST=$(_pick "$STATEDIR/last_good")
# 兜底二：三个来源都没有、但库里明明有字体 → 挑"最近用过的那个"，
#   而不是直接 apply none（旧行为会让用户的字体凭空消失，真机实测过）。
#   判据：有 .meta 的 f*.ttf 里 mtime 最新的 —— .meta 是"导入过"的标志。
if [ -z "$LAST" ]; then
  _cand=$(ls -t "$LIB"/f*.ttf 2>/dev/null | head -n 20 | while IFS= read -r _f; do
    _i=${_f##*/}; _i=${_i%.ttf}
    [ -f "$LIB/$_i.meta" ] || continue
    printf '%s' "$_i"; break
  done)
  if [ -n "$_cand" ]; then
    LAST="$_cand"
    ui_print "  ⚠ 没找到「上次用哪套」的记录"
    ui_print "     （可能是上一次切换失败留下的）"
    ui_print "     已按最近用过的恢复：$_cand"
  fi
fi
[ -n "$LAST" ] || LAST=none

for f in common.sh slots.sh mount.sh fontctl.sh update.sh google_font.sh gms_cache.sh nameclone.sh action.sh \
         metaprobe.sh fdata.sh diag.sh post-fs-data.sh post-mount.sh service.sh uninstall.sh logcatch.sh; do
  chmod 755 "$MODPATH/$f" 2>/dev/null
done
# Magisk 用户没有「操作」按钮：这几个文件放在模块目录里，点「执行」就能用
for _uf in "抓日志-开始.sh" "抓日志-停止导出.sh" "抓日志-状态.sh" "打开WebUI.sh"; do
  [ -f "$MODPATH/$_uf" ] && chmod 755 "$MODPATH/$_uf" 2>/dev/null
done
rm -f "$MODPATH/customize.sh.bak" 2>/dev/null

ui_print " "
ui_print "- 识别到系统：$ROM_NAME"
ui_print "- Root 管理器：$(root_manager_name "$RM")"
if [ "$(mount_mode)" = manager ]; then
  ui_print "- 挂载方式：交给管理器 / 元模块"
else
  ui_print "- 挂载方式：模块自带挂载（无需元模块）"
fi

# ★ 升级不是“重装”：新模块目录里可能还带着上一版的 slots.map / payload。
#   字体文件或布局一变，这些旧计划就可能指向已经不存在的 TTC / 时钟 / 槽位源，
#   表现就是“挂载脚本说成功，但框架用的是旧计划 / 根本挂不上”，卸载重装反而正常。
#   所以升级时先清掉旧挂载现场，再按 LAST 重新生成一份全新计划。
#   字体库、用户字体、设置、备份都不动。
if [ -f "$OLD/module.prop" ]; then
  ui_print "- 升级：清理旧挂载计划，重新生成"
  rm -f "$MODPATH/slots.map" "$MODPATH/slots.applied" "$MODPATH/slots.boot.map" \
        "$MODPATH/slots.map.prev" "$MODPATH/mount.state" "$MODPATH/mount_missed" 2>/dev/null
  rm -rf "$MODPATH/payload" 2>/dev/null
  mkdir -p "$MODPATH/payload" 2>/dev/null
fi

RESTORED=0
if [ "$LAST" != none ]; then
  ui_print "- 正在恢复上次的字体选择…"
  # ★ 2026-10-24（开发者真机反馈，打脸了上面那段注释）：
  #   实测 152 个槽位时，这一步能有好几分钟 —— 因为 apply 不只是写 map，
  #   还要逐槽位比对、必要时合成 .ttc 合集。原来写"很快"是错的。
  #   现在按实情说，并且**不给具体秒数**（给了就会被下一张截图打脸）。
  ui_print "  ⏳ 正在生成挂载计划（槽位多或设备慢时要几十秒到几分钟）"
  ui_print "     这段时间没有任何输出是正常的，请耐心等，别退出管理器"
  # ★ 用 sed 取最后一个非空行 —— tail -n1 遇到末尾空行会拿到空串，
  #   于是 OK:* 匹配不上，把一次成功的恢复误判成失败（会把用户字体清成 none）。
  CFS_SKIP_CLOCK=0; export CFS_SKIP_CLOCK
OUT=$(sh "$MODPATH/fontctl.sh" apply "$LAST" 2>&1 | sed '/^[[:space:]]*$/d' | tail -n1)
  case "$OUT" in
    OK:*)
      RESTORED=1
      ui_print "  已恢复：$(echo "$OUT" | cut -d: -f2)（$(echo "$OUT" | cut -d: -f3) 个槽位）"
      ;;
    *)
      ui_print "  恢复失败：${OUT#ERROR:}"
      ui_print "  已改为「无字体」"
      ui_print "  请开机后在 WebUI 重新选择"
      FALLBACK=0
      ;;
  esac
fi
# ★ 只有「恢复失败 **且** 兜底也没成功」时才清成 none。
#   这个 if 现在看起来是等价的（主项目没内置字体，兜底就是写 none），
#   但它是**给换皮/内置字体变体留的正确形状**：保时捷内置配色版的兜底会挑一套
#   可用配色（builtin_apply_first），而无条件的 `|| apply none` 会**紧接着把
#   它的结果覆盖回 none** → 用户重启后回到默认、必须重新选一次（真机踩到过）。
#   所以这里先算出 FALLBACK 再决定，别写死。
if [ "$RESTORED" = 1 ] || [ "${FALLBACK:-0}" = 1 ]; then
  :                                   # 已有可用选择，别动它
else
  sh "$MODPATH/fontctl.sh" apply none >/dev/null 2>&1
fi

# ★ 2026-10-26 补：导入内置配色并让用户用音量键选择（子项目多配色包必需）
#   之前 customize.sh 从未调用 builtin_import / builtin_menu，
#   所以安装时不弹选择、字体库里也没有内置字体。
if [ -f "$MODPATH/builtin.sh" ] && [ -d "$MODPATH/builtin" ]; then
  ui_print "- 正在写入内置配色…"
  MODDIR="$MODPATH"; export MODDIR
  . "$MODPATH/common.sh" 2>/dev/null
  . "$MODPATH/fontcheck.sh" 2>/dev/null
  . "$MODPATH/builtin.sh" 2>/dev/null
  if command -v builtin_import >/dev/null 2>&1; then
    builtin_import >/dev/null 2>&1
    _bc=$(builtin_count 2>/dev/null)
    ui_print "- 内置配色已写入：${_bc:-0} 套"
  fi

  # ★ 2026-10-27 OTA：内置字体换新（升级后必须真正替换旧字形）
  #   ① 强制刷新 .name / .meta（size、vf 跟着新文件走，界面不再显示旧体积）
  for _bf in "$MODPATH"/builtin/*.ttf "$MODPATH"/builtin/*.TTF; do
    [ -f "$_bf" ] || continue
    _bn=${_bf##*/}; _bn=${_bn%.*}
    _bi=$(builtin_id_of "$_bn" 2>/dev/null); _bi=${_bi%%|*}
    [ -n "$_bi" ] || continue
    _bnm=$(builtin_id_of "$_bn" 2>/dev/null); _bnm=${_bnm#*|}
    if [ -s "$LIB/$_bi.ttf" ]; then
      printf '%s' "$_bnm" > "$LIB/$_bi.name" 2>/dev/null
      _bsz=$(wc -c < "$LIB/$_bi.ttf" 2>/dev/null | tr -d ' \t\r\n')
      case "${_bsz:-}" in ''|*[!0-9]*) _bsz=0 ;; esac
      if builtin_is_vf "$_bf" 2>/dev/null; then _bvf=1; else _bvf=0; fi
      printf 'scope=all\nlatin=1\ncjk=1\nvf=%s\nsize=%s\n' "$_bvf" "$_bsz" > "$LIB/$_bi.meta" 2>/dev/null
      ui_print "- 内置配色已更新：$_bnm（$(awk "BEGIN{printf \"%.1f\", $_bsz/1048576}" 2>/dev/null) MB）"
    fi
  done

  #   ② 清掉「包内已经没有」的内置字体残留（旧版本多出来的配色）
  for _old in "$LIB"/builtin_*.ttf "$LIB"/builtin_*.TTF; do
    [ -f "$_old" ] || continue
    _obn=${_old##*/}; _obn=${_obn%.*}; _oid=${_obn#builtin_}
    if [ -n "$_oid" ] && [ ! -e "$MODPATH/builtin/$_oid.ttf" ] && [ ! -e "$MODPATH/builtin/$_oid.TTF" ]; then
      rm -f "$LIB/$_oid.ttf" "$LIB/$_oid.name" "$LIB/$_oid.meta" 2>/dev/null
      ui_print "- 已清理旧配色：$_oid"
    fi
  done

  #   ③ 当前用的是内置配色 → 重新 apply 一次，让 pending 指向新文件
  _act=$(cat "$MODDIR/active_font" 2>/dev/null | tr -d '[:space:]')
  _pen=$(cat "$MODPATH/pending_font" 2>/dev/null | tr -d '[:space:]')
  _useb=""
  case "$_act" in builtin_*) _useb=${_act#builtin_} ;; esac
  case "$_pen" in builtin_*) [ -z "$_useb" ] && _useb=${_pen#builtin_} ;; esac
  if [ -n "$_useb" ] && [ -s "$LIB/$_useb.ttf" ]; then
    _ra=$(sh "$MODPATH/fontctl.sh" apply "builtin_$_useb" 2>&1 | sed '/^[[:space:]]*$/d' | tail -n1)
    case "$_ra" in
      OK:*) ui_print "- 当前配色已按新素材重新应用（重启后生效）" ;;
      *)    ui_print "- 重新应用失败：${_ra#ERROR:}" ;;
    esac
  fi
  if command -v builtin_menu >/dev/null 2>&1; then
    builtin_menu
  fi
  _pf=$(cat "$MODPATH/pending_font" 2>/dev/null | tr -d '[:space:]')
  case "$_pf" in
    ""|none) ;;
    *)
      _out=$(sh "$MODPATH/fontctl.sh" apply "$_pf" 2>&1 | sed '/^[[:space:]]*$/d' | tail -n1)
      case "$_out" in
        OK:*) ui_print "- 已应用：$(echo "$_out" | cut -d: -f2)" ;;
        *)    ui_print "- 应用失败：${_out#ERROR:}" ;;
      esac
      ;;
  esac
fi

sh "$MODPATH/fontctl.sh" prop >/dev/null 2>&1

LIB_COUNT=$(ls "$LIB"/f*.ttf 2>/dev/null | wc -l)
# ★ 2026-10-18（文案跟上实情）：
#   原来写的是"也会扫一遍字体配置，稍等" —— 其实 list_conflicts 扫的是
#   **其它模块目录**（看谁也在改字体），而且从 2026-10-17 起带了缓存，
#   第二次起几乎是瞬时。这行字既不准、又让人以为要等很久。
ui_print "- 正在检查有没有其它字体模块…"
CONFLICTS=$(sh "$MODPATH/fontctl.sh" conflicts 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')

# ---------------------------------------------------------------------------
# 扫描印记：只在"需要重扫"时才扫（开发者 2026-10-21 定的规则）
#
#   模块自带 scanmarks.conf（要求版本表）：
#       slot=1406     ← 槽位扫描逻辑最后在 1.4.6 变过
#       font=1406     ← 字体结构扫描逻辑最后在 1.4.6 变过
#   设备上存 $STATEDIR/scan/.scanmarks（已扫到什么版本）：
#       slot=1406
#       font=1406
#
#   安装时逐个比：
#       设备记录 <  要求版本 → 扫（他是从更早的版本升上来的，没扫过新内容）
#       设备记录 == 要求版本 → 也扫（同版本覆盖安装也重扫，方便开发者自测）
#       设备记录 >  要求版本 → 不扫（之前已经扫过了）
#   扫完之后设备记录写成**当前模块版本**，于是后续版本自然"比要求高"，不再重扫。
#
#   槽位和字体分开记：只改字体相关逻辑时，槽位不用重扫，省时间。
# ---------------------------------------------------------------------------
LIBROOT="${LIBROOT:-/data/adb/custom_font_lib}"
LIB="$LIBROOT/fonts"
MARKS="$STATEDIR/scan/.scanmarks"
MCUR=$(sed -n 's/^versionCode=//p' "$MODPATH/module.prop" 2>/dev/null | head -1 | tr -d '\r')
case "$MCUR" in ''|*[!0-9]*) MCUR=0 ;; esac

mk_req() {   # mk_req <key> → 要求版本（没配置就输出空）
  [ -f "$MODPATH/scanmarks.conf" ] || return 1
  sed -n "s/^$1=//p" "$MODPATH/scanmarks.conf" 2>/dev/null | head -1 | tr -d '\r'
}

mk_cur() {   # mk_cur <key> → 设备已扫到的版本
  [ -f "$MARKS" ] || return 1
  sed -n "s/^$1=//p" "$MARKS" 2>/dev/null | head -1 | tr -d '\r'
}

mk_need() {  # mk_need <key> → 返回 0 表示需要扫
  _req=$(mk_req "$1")
  case "$_req" in ''|*[!0-9]*) return 1 ;; esac     # 没要求 → 不扫
  _cur=$(mk_cur "$1")
  case "$_cur" in '') return 0 ;; esac              # 没记录 → 扫
  case "$_cur" in *[!0-9]*) return 0 ;; esac        # 记录坏了 → 扫
  # 只认扫描逻辑版本：不同就扫一次；扫描后写入 req，后续功能版本升级不再触发。
  [ "$_cur" -ne "$_req" ] && return 0
  return 1
}

mk_set() {   # mk_set <key> <value>
  mkdir -p "$LIB" 2>/dev/null
  # ★ 2026-10-31：安装号改为"首次安装才写"（见文件开头），mk_set 不再每次碰它
  [ -f "$MARKS" ] || : > "$MARKS" 2>/dev/null
  grep -v "^$1=" "$MARKS" > "$MARKS.tmp" 2>/dev/null
  echo "$1=$2" >> "$MARKS.tmp"
  mv -f "$MARKS.tmp" "$MARKS" 2>/dev/null
}

# 手动强制重扫：碰一下这个文件，下次安装全部重扫
if [ -f "$STATEDIR/force_rescan" ]; then
  rm -f "$MARKS" 2>/dev/null
  rm -f "$STATEDIR/force_rescan" 2>/dev/null
  ui_print "- 检测到强制重扫标记，本次全部重扫"
fi


# ---------------------------------------------------------------------------
# 槽位扫描（贵，只在槽位逻辑变过时扫）
# ---------------------------------------------------------------------------
if mk_need slot; then
  # ★ 2026-10-31：只删 device.list + .schema（强制真重扫本机字体）。
  #   派生清单（slots.list 等）交给 slot_build_slots 重算后"内容一致就不替换"——
  #   旧版这里全删 → 每次刷入 mtime 全变 → 计划缓存必然失效（恢复选型慢的元凶）。
  rm -f "$STATEDIR/scan/device.list" "$STATEDIR/scan/.schema" 2>/dev/null
  if [ -f "$MODPATH/fontctl.sh" ]; then
    sh "$MODPATH/fontctl.sh" rescan >/dev/null 2>&1 && {
      mk_set slot "$(mk_req slot)"
      ui_print "- 已重建字体槽位清单（版本印记 slot=$MCUR）"
    }
  fi
else
  ui_print "- 槽位清单已是最新（无需重扫）"
fi


# ---------------------------------------------------------------------------
# 清空缓存后立刻重建（否则界面「槽位总数 / 机型清单 / 本机扫描」会显示为空）
#   这一次扫描就发生在安装时，开机和应用路径上仍然是读缓存，速度不受影响。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 字体结构扫描（只扫字体库，比槽位快；同样只在"需要"时扫）
#   fdata.sh    → 每份字体的结构清单 .fdata
#   metaprobe.sh→ 写进 .meta：轮廓类型 / 是否可变 / 字重轴范围 / 轴标签
# ---------------------------------------------------------------------------
if mk_need font; then
  if [ -f "$MODPATH/fdata.sh" ]; then
    sh "$MODPATH/fdata.sh" 2>/dev/null | sed 's/^/  /' >/dev/null 2>&1
    ui_print "- 已为已有字体补充结构档案"
  fi
  
# ---------------------------------------------------------------------------
# 清理旧版"GMS 缓存桥接"的残留（1.4.6 及更早已移除该功能）
#   老用户可能还挂着 44MB 的克隆、留着启用标志 → 升级时顺手清干净
# ---------------------------------------------------------------------------
if [ -f "$LIB/gms_cache.sh" ]; then
  LIB="$LIB" sh "$LIB/gms_cache.sh" off >/dev/null 2>&1 || true
fi
rm -f "$LIB"/.clone.*.ttf "$STATEDIR/gms_cache_on" 2>/dev/null
for _p in com.google.android.gms com.google.android.gsf com.android.vending; do
  umount -l "/data/data/$_p/files/fonts/opentype" 2>/dev/null || true
done
rm -f "$LIB"/.gms_bridge.list "$LIB"/.gms_bridge.log 2>/dev/null

if [ -f "$MODPATH/metaprobe.sh" ]; then
    LIB="$LIB" sh "$MODPATH/metaprobe.sh" 2>/dev/null | sed 's/^/  /' >/dev/null 2>&1
    ui_print "- 已写入字体合成所需信息（轮廓类型 / 可变轴）"
  fi
  mk_set font "$(mk_req font)"
else
  ui_print "- 字体档案已是最新（无需重扫）"
fi

# ---------------------------------------------------------------------------
# 只检查“当前字体 / 待生效字体”的 TTC 合集：
# 有就命中缓存，没有就现场生成这一份，不再扫全部字体、不再预生成全库。
# ---------------------------------------------------------------------------
ui_print "- 正在检查当前字体的计划与 TTC 合集（只检查这一套）…"
if [ -f "$MODPATH/fontctl.sh" ] && [ "${LAST:-none}" != "none" ]; then
  _pw1=$(CFS_PREWARM_TTC=1 sh "$MODPATH/fontctl.sh" prewarm "$LAST" 2>/dev/null | tail -n1)
  case "$_pw1" in
    *":hit") ui_print "  计划和 TTC 已存在，跳过" ;;
    OK:prewarm:*) ui_print "  当前字体计划和 TTC 已就绪" ;;
    *) ui_print "  当前字体检查：${_pw1#ERROR:}" ;;
  esac
fi
_pen_check=$(tr -d '[:space:]' < "$MODPATH/pending_font" 2>/dev/null)
if [ -f "$MODPATH/fontctl.sh" ] && [ -n "$_pen_check" ] && [ "$_pen_check" != "none" ] && [ "$_pen_check" != "${LAST:-none}" ]; then
  ui_print "- 正在检查待生效字体的计划与 TTC 合集…"
  _pw2=$(CFS_PREWARM_TTC=1 sh "$MODPATH/fontctl.sh" prewarm "$_pen_check" 2>/dev/null | tail -n1)
  case "$_pw2" in
    *":hit") ui_print "  待生效字体：计划和 TTC 已存在，跳过" ;;
    OK:prewarm:*) ui_print "  待生效字体：计划和 TTC 已就绪" ;;
    *) ui_print "  待生效字体检查：${_pw2#ERROR:}" ;;
  esac
fi
ui_print "- 其他字体不预生成；第一次切换时按需生成，之后复用缓存"

ui_print "- 扫描与档案更新结束，正在写入文件权限…"

# ===========================================================================
# 刷入日志（2026-10-31 重排）：过程在前、汇总在后；键值对齐，不再重复信息
# ===========================================================================
_BV=$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
ui_print ""
ui_print "============================================================"
ui_print "  汇总 · 保时捷字体配色模块 $_BV"
ui_print "============================================================"
ui_print "[1/5] 设备与门禁"
ui_print "  设备      $(getprop ro.product.brand 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
ui_print "  系统      Android $(getprop ro.build.version.release 2>/dev/null) · 内核 $(uname -r 2>/dev/null)"
ui_print "  识别      $(tr -d '[:space:]' < "$MODPATH/current_rom" 2>/dev/null | head -c 40)"
_RM="KernelSU 系"
command -v magisk >/dev/null 2>&1 && _RM="Magisk"
[ -d /data/adb/ksu ] && _RM="KernelSU 系"
ui_print "  Root      $_RM"
ui_print "  挂载      模块自带挂载（无需元模块）"
GD="无"; [ -f "$OLD/disable" ] && GD="有"
GU="无"; [ -f "$OLD/update" ] && GU="有（上次安装未被激活）"
GS="无"; case "$(getprop persist.sys.safemode)$(getprop ro.sys.safemode)" in *1*) GS="有" ;; esac
GM="无"; { command -v magisk >/dev/null 2>&1 || [ -e /data/adb/magisk ]; } && GM="有"
ui_print "  门禁      已禁用=$GD · 待激活=$GU · 安全模式=$GS · Magisk共存=$GM"
ui_print "[2/5] 字体库与上次选择"
_LIBN=$(ls -1 "$LIB"/*.ttf 2>/dev/null | wc -l | tr -d ' ')
_LIBKB=$(du -sk "$LIB" 2>/dev/null | awk '{print $1}')
ui_print "  字体库    ${_LIBN:-0} 个 · ${_LIBKB:-0} KB（$LIB）"
_ACT=$(sed -n 's/^active=//p' "$STATEDIR/index" 2>/dev/null | head -n1 | tr -d '\r')
if [ -n "$_ACT" ] && [ "$_ACT" != "none" ]; then
  _AN=$(head -n1 "$LIB/$_ACT.name" 2>/dev/null)
  ui_print "  上次选择  ${_AN:-$_ACT}"
else
  ui_print "  上次选择  无字体（系统默认）"
fi
_GRP=$(grep -l '^group=' "$LIB"/*.meta 2>/dev/null | wc -l | tr -d ' ')
[ "${_GRP:-0}" -gt 0 ] 2>/dev/null && ui_print "  字重组    ${_GRP} 份参与分组"
if [ -d "$BACKUPDIR/orig" ]; then
  _OKB=$(du -sk "$BACKUPDIR/orig" 2>/dev/null | awk '{print $1}')
  ui_print "  主题备份  ${_OKB:-0} KB（卸载时自动还原）"
fi
ui_print "[3/5] 槽位与扫描"
ui_print "  槽位      总数 ${_an:-?} = 机型清单 ${_tn:-0} + 本机补 ${_en:-0}"
_TCN=$(awk '$2 ~ /\.ttc$/ {c++} END {print c+0}' "$MODPATH/slots.map" 2>/dev/null)
_SLOTN=$(grep -c . "$MODPATH/slots.map" 2>/dev/null | tr -d ' ')
ui_print "  计划      ${_SLOTN:-0} 个 · 中文合集 ${_TCN:-0} 个"
_SF=$(ls -1 /system/fonts 2>/dev/null | grep -c . )
_PF=$(ls -1 /product/fonts 2>/dev/null | grep -c . )
ui_print "  系统字体  /system/fonts ${_SF:-0} 个 · /product/fonts ${_PF:-0} 个"
_CFG=$(ls -1 /system/etc/fonts.xml /system/etc/fonts_fallback.xml 2>/dev/null | head -n1)
if [ -n "$_CFG" ]; then
  _CFGKB=$(du -k "$_CFG" 2>/dev/null | awk '{print $1}')
  ui_print "  字体配置  $_CFG（${_CFGKB:-?} KB）"
fi
if [ -d /data/system/theme/fonts ]; then
  _THN=$(ls -1 /data/system/theme/fonts 2>/dev/null | wc -l | tr -d ' ')
  ui_print "  主题字体  ${_THN:-0} 个文件（默认不替换）"
fi
ui_print "  印记      slot=$(mk_cur slot 2>/dev/null) · font=$(mk_cur font 2>/dev/null)"
ui_print "[4/5] 结果"
if [ -n "${CONFLICTS:-}" ]; then
  ui_print "  冲突      ⚠ $CONFLICTS（建议先停用，避免互相覆盖）"
else
  ui_print "  冲突      无"
fi
_UM="不适用"
if [ -d /data/adb/ksu ]; then
  if [ -e /data/adb/ksu/umount_enabled ] || [ "$(cat /data/adb/ksu/.umount 2>/dev/null)" = "1" ]; then
    _UM="开启（部分 App 可能看不到挂载）"
  else
    _UM="关闭（App 里也能看到字体）"
  fi
fi
ui_print "  卸载机制  $_UM"
if [ -n "$_ACT" ] && [ "$_ACT" != "none" ]; then
  ui_print "  生效      ⏳ 重启后生效（现在还是系统原字体）"
else
  ui_print "  生效      未选择字体，无需重启"
fi
ui_print "[5/5] 使用方法"
ui_print "  1. 管理器里点本模块 → 打开（WebUI）"
ui_print "  2. 点卡片切换字体；选「无字体」即恢复系统默认"
ui_print "  3. 出问题：WebUI「诊断报告」→ 生成 → 上传（也可存 Download 手动发）"
if [ "${_RM:-}" = "Magisk" ]; then
  ui_print "  · Magisk 没有 WebUI 入口：先装 KsuWebUI，再点模块卡片的「操作」"
fi
ui_print ""
ui_print "  注意  更新模块不丢字体库/设置/壁纸；卸载会一并删除字体库"
ui_print "  保险  若选字体后没能开机，下次开机会自动恢复为「无字体」"
# 完整包自带的就是字体包 v1.0：安装/升级到 4.6.0 后要记住这个版本。
# lite 包不覆盖这里，避免把用户后来升级的字体包版本改回 1.0。
if [ "${_LITE_PKG:-0}" != "1" ]; then
  _fp_variant=$(case "$MODID" in *718*) echo none ;; *911*) echo colon ;; *gt3*) echo flair ;; *) echo multi ;; esac)
  _fp_names=""
  for _fp in "$LIB"/builtin_*.ttf; do
    [ -f "$_fp" ] || continue
    _fpb=${_fp##*/}; _fpb=${_fpb#builtin_}; _fpb=${_fpb%.*}
    [ -n "$_fpb" ] && _fp_names="$_fp_names $_fpb"
  done
  mkdir -p "$STATEDIR" 2>/dev/null
  printf '{\n  "version": "v1.0",\n  "versionCode": 10000,\n  "variant": "%s",\n  "fonts": "%s",\n  "installedAt": "%s"\n}\n' \
    "$_fp_variant" "$(printf '%s' "$_fp_names" | sed 's/^ //')" "$(date +%s 2>/dev/null)" \
    > "$STATEDIR/font.pack.json" 2>/dev/null
fi
if ! lib_layout_commit; then
  ui_print "! 新目录校验失败：版本=$(cat "$LIBROOT/.layout_version" 2>/dev/null) 字体=$(ls "$LIBROOT/fonts"/f*.ttf 2>/dev/null | wc -l) 清单=$(wc -l < "$LIBROOT/.layout_manifest" 2>/dev/null)"
  ui_print "! 新目录校验失败，已取消刷入"
  abort "新目录校验失败"
fi
ui_print "============================================================"
