#!/system/bin/sh
# 保时捷字体（三合一） - 安装脚本（Magisk / KernelSU / APatch 通用）
# 刷机包里的文件已由管理器解压到 $MODPATH

LIB=/data/adb/custom_font_lib
MODID=$(sed -n 's/^id=//p' "$MODPATH/module.prop" | head -n1 | tr -d '\r')
OLD="/data/adb/modules/$MODID"

ui_print "========================================================"
ui_print " 保时捷字体（三合一）  $(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -n1 | tr -d '\r')"
ui_print " 内置配色：素装(无色) / 一点红 / 烈焰"
ui_print "========================================================"

. "$MODPATH/common.sh"
# ★ 字体校验工具必须**在 builtin.sh 之前**载入 —— builtin_import 要用它挡住坏字体。
#   （不提前载入的话，那里的 `command -v valid_font` 判断为假 → 校验被静默跳过。）
if [ -f "$MODPATH/fontcheck.sh" ]; then
  . "$MODPATH/fontcheck.sh"
fi
if ! command -v valid_font >/dev/null 2>&1; then
  ui_print "  ⚠ 缺少 fontcheck.sh"
    ui_print "     内置字体的有效性校验被跳过"
  valid_font() { [ -f "$1" ]; }
fi
mkdir -p "$LIB"

# ★ 2026-10-19（作者要求）：**从旧版本升上来，一律重新扫描 + 重新合成**。
#   旧版留下的派生数据不能信：
#     · 1.3.5~1.3.7 的 scanned/ttc.list 写的时候被自己截断成空，
#       读取端把"空"当结论 → 中文合集永久不换（三星中文一直没变过）
#     · 旧的合成 .ttc 可能是在"只换 2 号"的兜底逻辑下造的，照用就是错的
#   所以版本号一变就整份作废：清单删掉（首次切换会重扫）、合成产物删掉（会重造）。
#   字体文件 / .name / .meta / settings.conf / last_selection 都不动（用户数据）。
_MK="$LIB/.scan_version"
_CUR=$(sed -n 's/^versionCode=//p' "$MODPATH/module.prop" 2>/dev/null | head -n1 | tr -d '\r\n')
_OLD=$(cat "$_MK" 2>/dev/null | tr -d '\r\n')
if [ -n "$_CUR" ] && [ "$_OLD" != "$_CUR" ]; then
  rm -rf "$LIB/scanned" 2>/dev/null
  rm -f "$LIB"/*.ttc[0-9]* 2>/dev/null
  rm -f "$LIB/.verify.cache" "$LIB/.device_fonts" "$LIB/.cand.cache" \
        "$LIB/.plan.cache" "$LIB/.plan.marks" 2>/dev/null
  if [ -n "$_OLD" ]; then
    _ov=$(sed -n 's/^version=//p' "$OLD/module.prop" 2>/dev/null | head -n1 | tr -d '\r\n')
    _nv=$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -n1 | tr -d '\r\n')
    ui_print "- 从 ${_ov:-旧版本} 升级到 ${_nv:-新版本}：重新扫描字体、重建中文合集"
  fi
  printf '%s' "$_CUR" > "$_MK" 2>/dev/null
fi

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


# ---------------------------------------------------------------------------
# 内置字体：把模块自带的配色注入字体库（硬链接，同一分区不额外占空间），
# 并把其它保时捷模块标记为重启后卸载（4 个包 id 各不相同，同时装会互相抢字体）
# ---------------------------------------------------------------------------
MODDIR="$MODPATH"                      # 注意：这是暂存目录！已安装目录是 $OLD
if [ -f "$MODPATH/builtin.sh" ]; then
  . "$MODPATH/builtin.sh"

  # ---------------------------------------------------------------------------
  # ★★ 第一件事：记下"用户上次用的是哪一套自带配色"（**必须最先做**）
  #
  #   为什么顺序这么关键（两个理由，都会让映射认错）：
  #     ① 老版本升上来时**字体原文件换了**（旧 id 和新的 builtin_* 不是一回事），
  #        所以 `apply $LAST` 必然失败 —— 这不是 bug，是必然。
  #        但"失败后自动改用一套"不该闭眼挑排序第一的（那样每个老用户都被换成 911·一点红），
  #        而该改用到**他原来那套**。
  #     ② 判定要读**旧字体文件的大小**，而下面 builtin_import / builtin_clean_legacy
  #        都可能动字体库（硬链接覆盖同名、清理孤儿）—— 一旦先跑，读到的就不是原文件了。
  #        顺序错了映射会认错（沙箱里就是这么复现的：本该认成 718，结果认成 911）。
  # ---------------------------------------------------------------------------
  BUILTIN_PREV=""
  # ① 最可靠：读**已安装模块**的描述 —— 里面写着"当前生效：xxxxx"
  #    （老版本正常在用，所以这行是当时真正生效的那套，不依赖 id、也不用猜文件）
  _mp=$(builtin_map_from_prop)
  [ -n "$_mp" ] || {
    # ② 退回：字体库 / 已安装模块的状态文件里记的选择
    _pl=$(tr -d '[:space:]' 2>/dev/null < "$LIB/last_selection")
    case "$_pl" in ""|none) _pl="" ;; esac
    [ -n "$_pl" ] || { _pl=$(tr -d '[:space:]' 2>/dev/null < "$OLD/active_font");  case "$_pl" in ""|none) _pl="" ;; esac; }
    [ -n "$_pl" ] || { _pl=$(tr -d '[:space:]' 2>/dev/null < "$OLD/pending_font"); case "$_pl" in ""|none) _pl="" ;; esac; }
    [ -n "$_pl" ] && _mp=$(builtin_map_from_prev "$_pl")
  }
  if [ -n "$_mp" ]; then
    BUILTIN_PREV="$_mp"
    ui_print "- 认出你上次用的配色："
    ui_print "     $(builtin_id_of "$(printf '%s' "$_mp" | sed 's/^builtin_//')" | cut -d'|' -f2)"
  fi
  export BUILTIN_PREV

  builtin_sibling_cleanup "$MODID"
  builtin_import

  # 清掉字体库里没人用的旧字体（在用的会保留；$OLD/$LIB 都参与"在用"判断）
  builtin_clean_legacy

  # ★ 2026-10-19：本模块只认内置配色 —— 把用户以前导入的字体清掉、
  #   被删掉的内置配色由上面的 builtin_import 重新补回。
  builtin_prune_imported
fi

# 1.0.9：识别机型要读全部系统属性、还要找厂商目录，会花一两秒。
#   特意把话说在前面，免得用户看管理器"卡在那儿不动"以为死机了。
#   这一阶段等一下完全没问题 —— 它不是开机流程，不影响开机时间。
ui_print "- 正在检测你的机型与字体配置，请稍等…"
ROM_ID=$(detect_rom)
ROM_NAME=$(rom_name "$ROM_ID")
RM=$(root_manager)
echo "$ROM_ID" > "$MODPATH/current_rom"
ui_print "- 已识别：$ROM_NAME"

# 旧版设置在模块目录里，迁移到字体库目录（以后更新不会丢）
[ -f "$SETTINGS" ] || { [ -f "$OLD/settings.conf" ] && cp -f "$OLD/settings.conf" "$SETTINGS"; }

# 当前实际生效的字体（升级前的状态），用于界面显示"当前 / 待生效"
A=$(tr -d '[:space:]' 2>/dev/null < "$OLD/active_font")
[ -n "$A" ] || A=none
echo "$A" > "$MODPATH/active_font"
echo none > "$MODPATH/pending_font"

# 上次的选择：**尽量保住用户正在用的那套**（这是升级体验的关键）
#
# ⚠️ 原来的链有两个毛病，真机上直接导致"更新完字体变了/变回默认"：
#   ① **`$OLD/active_font`（当前真正在用的）根本没被读** —— 它才是最该恢复的那个。
#      `pending_font` 只在"选完还没重启"时有值，正常用着的时候它是不准的。
#   ② `[ -n "$LAST" ] ||` 这个判断把 **"none" 也当成有效值** ——
#      于是 pending_font 里写着 none（选完未重启就是这样）时，
#      它挡住后面的来源，最后 apply none → 用户升级完字体没了。
#   现在：**跳过空值和 none**，一路找到第一个真正可用的来源。
#   顺序：字体库记录 → 当前生效 → 待生效（三者里第一个不是 none 的）
_pick() {   # $1=文件；echo 出值（空/none 视为无值）
  local v
  v=$(tr -d '[:space:]' 2>/dev/null < "$1")
  case "$v" in ""|none) return 0 ;; esac
  printf '%s' "$v"
}
LAST=$(_pick "$LIB/last_selection")
[ -n "$LAST" ] || LAST=$(_pick "$OLD/active_font")     # ★ 当前真正在用的
[ -n "$LAST" ] || LAST=$(_pick "$OLD/pending_font")
# ★ 2026-10-16（B1）兜底一：.last_good —— 最近一次**真正生效过**的字体。
#   它刻意不被 apply none 覆盖，所以能区分"记录丢了"和"确实选了无字体"。
#   （用户真的选了无字体时它已被删掉，这里自然拿不到 → 保持 none，符合用户意图）
[ -n "$LAST" ] || LAST=$(_pick "$LIB/.last_good")
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
    ui_print "  ⚠ 没找到"
    ui_print "     "上次用哪套" 的记录"
    ui_print "     （可能是上一次切换失败留下的）"
    ui_print "     已按最近用过的恢复：$_cand"
  fi
fi
[ -n "$LAST" ] || LAST=none

# ★★ 关键一步：如果上面已经**认出"用户上次用的是哪一套自带配色"**（BUILTIN_PREV），
#   就直接拿它当恢复目标 —— 别再去 apply 那个旧的 id。
#
#   为什么：老版本升上来时字体 id 变了（旧的 f<数字>/内置旧名 vs 新的 builtin_*），
#   旧 id 必然找不到；但我们已经知道"他原来用的是 718"，那就该恢复成 718。
#   真机/沙箱都验证过：不换成 BUILTIN_PREV 的话，日志会出现
#     「认出你上次用的配色：718素装版」+「已恢复：911经典版」
#   这种"认出来了却没用它"的荒唐结果。
if [ -n "${BUILTIN_PREV:-}" ]; then
  ui_print "  → 按你原来的配色恢复到："
  ui_print "     $(builtin_id_of "$(printf \'%s\' "$BUILTIN_PREV" | sed \'s/^builtin_//\')" | cut -d\'|\' -f2)"
  LAST="$BUILTIN_PREV"
fi
# 把"本来想恢复什么"记下来 —— 恢复失败时日志里能看出是哪个，不用猜
WANTED="$LAST"

for f in common.sh slots.sh mount.sh fontctl.sh update.sh google_font.sh gms_cache.sh nameclone.sh action.sh \
         diag.sh post-fs-data.sh post-mount.sh service.sh uninstall.sh metaprobe.sh fdata.sh ; do
  chmod 755 "$MODPATH/$f" 2>/dev/null
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

RESTORED=0
if [ "$LAST" != none ]; then
  ui_print "- 正在恢复上次的字体选择…"
  # ★ 排障信息一定要留全。
  #   真机上出过「恢复失败：」后面**一片空白** —— 用户和作者都不知道是哪一步不对，
  #   只能靠猜（最后是靠"字体库里没有那个文件"才推断出来的）。
  #   这里把三件事都打出来：
  #     ① 上次选的到底是什么（$LAST 原文）
  #     ② 这个 id 在字体库里有没有对应文件（最常见的原因就是"没有"）
  #     ③ apply 的**完整**输出（不只最后一行 —— 报错可能不在最后一行）
  _LAST_RAW="$LAST"
  _HAVE=""; _MISS=""
  for _i in $(printf '%s' "$LAST" | tr '+' ' '); do
    if [ -f "$LIB/$_i.ttf" ]; then _HAVE="$_HAVE $_i"; else _MISS="$_MISS $_i"; fi
  done
  [ -n "$_HAVE" ] && ui_print "  上次选择：$_HAVE（字体库里有）"
  [ -n "$_MISS" ] && ui_print "  上次选择：$_MISS（⚠ 字体库里**没有**这个文件 —— 通常是被清理过/换过字体库）"

  # ★ 2026-10-14：加"要等一会儿"的提示（与主项目同步）。
  #   为什么必须加：下一行 `fontctl.sh apply` 要**扫一遍机器上的字体配置 + 逐文件判定**，
  #   字体多的机器上要十几秒到一分钟。而这段时间安装界面**一行输出都没有** ——
  #   用户会以为卡死了、甚至去强杀管理器。真机反馈过（截图里就是停在"上次选择"这行不动）。
  #   提示要写在 apply **之前**（写在后面就是马后炮了，用户已经等完了）。
  #   ⚠️ 改这里时别删：它不参与任何逻辑，纯粹是给用户看的。
  ui_print "  ⏳ 正在扫描本机字体并生成槽位清单"
      ui_print "     大概十几秒到一分钟。"
      ui_print "     卡住不动是正常的，请稍等…"

  _APPLY_OUT=$(sh "$MODPATH/fontctl.sh" apply "$LAST" 2>&1)
  OUT=$(printf '%s\n' "$_APPLY_OUT" | tail -n1)
  case "$OUT" in
    OK:*)
      RESTORED=1
      ui_print "  已恢复：$(echo "$OUT" | cut -d: -f2)（$(echo "$OUT" | cut -d: -f3) 个槽位）"
      ;;
    *)
      # ★ 文案：**不要说"失败"**。
      #   原来这里是「恢复失败：」+ 紧接着「✓ 已自动改用 911」——
      #   用户读到的是"坏了？又好了？"，完全懵（作者本人就吐槽过这个自相矛盾）。
      #   真相是：上次那套找不到了 → 自动沿用了内置的一套，**结果是可用的**。
      #   所以按"结果"说话，别按"过程"说话。
      if [ -n "${OUT#ERROR:}" ]; then
        ui_print "  没找到你上次选的「$_LAST_RAW」"
        ui_print "     原因：${OUT#ERROR:}"
      else
        ui_print "  没找到你上次选的「$_LAST_RAW」"
        printf '%s\n' "$_APPLY_OUT" | while IFS= read -r _l; do
          [ -n "$_l" ] && ui_print "    | $_l"
        done
      fi
      ui_print "  常见原因：那个字体文件已被清理，"
ui_print "  或者换过字体库"
ui_print "  （模块之间共用同一个库）"
      # ⚠️ 不能只写 none 就完事 —— 那样模块会**静默空转**（装上了却什么都不换），
      #    用户重启后看到"没生效"，还以为新包坏了。
      #    这里兜底自动挑一套可用配色，保证模块一定处于"能用"的状态。
      FALLBACK=0
      if command -v builtin_apply_first >/dev/null 2>&1; then
        if builtin_apply_first; then
          FALLBACK=1
          # 告诉 builtin_menu：这次不是"沿用你上次的"，是"改用了内置配色"
          BUILTIN_MENU_NOTE="已改用内置配色（不是沿用上次的选择）—— 想换请在 WebUI 里点"
          export BUILTIN_MENU_NOTE
          ui_print "  → 已改为内置配色，重启后即可用"
ui_print "     （想换配色请在 WebUI 里点）"
        else
          echo none > "$MODPATH/pending_font"
          ui_print "  → 也没有可用的内置配色"
          ui_print "     已设为「无字体」"
ui_print "     请开机后在 WebUI 选择"
        fi
      else
        echo none > "$MODPATH/pending_font"
        ui_print "  → 已设为「无字体」"
ui_print "     请开机后在 WebUI 重新选择"
      fi
      ;;
  esac
fi
# ★★ 只有「恢复失败 **且** 兜底也失败」时，才把选择清成 none。
#
#   以前这里是无条件的 `[ "$RESTORED" = 1 ] || apply none` —— 于是：
#     ① 恢复失败 → ② 兜底 builtin_apply_first 挑了一套配色、写好 pending_font
#     → ③ 紧接着这句 apply none 把 pending_font 覆盖回 none
#     → ④ 用户重启后**回到系统默认**，界面显示"待生效 none"。
#   真机上就是这么表现的（作者反馈"重启完回到默认状态，重新选一次才生效"）。
#   ⚠️ 注意：`builtin_apply_first && FALLBACK=1 || ...` 这个写法是**故意**的 ——
#      `a && b || c` 在 b 失败时会执行 c，而这里 b 只是赋值、不会失败，所以安全。
if [ "$RESTORED" = 1 ] || [ "$FALLBACK" = 1 ]; then
  :                                   # 已经有可用选择（恢复成功 / 兜底成功），别动它
else
  sh "$MODPATH/fontctl.sh" apply none >/dev/null 2>&1
fi
sh "$MODPATH/fontctl.sh" prop >/dev/null 2>&1

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
#
# 这一段同时承担"菜单选完配色之后的第一次 apply" —— 全新安装时 slots.map 还不存在，
# 自然就会走到下面的重新生成分支。
# ---------------------------------------------------------------------------
PEND=$(tr -d '[:space:]' 2>/dev/null < "$MODPATH/pending_font")
if [ -n "$PEND" ] && [ "$PEND" != none ]; then
  if [ ! -s "$MODPATH/slots.map" ]; then
    ui_print " "
    ui_print "- 正在为「$PEND」生成挂载计划…"
    # ★ 2026-10-14（与主项目同步）：这一步要扫一遍字体配置，会停十几秒到一分钟，
    #   必须先在界面上说清楚，否则用户以为卡死（真机反馈过）。
    ui_print "  ⏳ 正在扫描本机字体并生成槽位清单"
      ui_print "     大概十几秒到一分钟"
      ui_print "     卡住不动是正常的，请稍等…"
    sh "$MODPATH/fontctl.sh" apply "$PEND" >/dev/null 2>&1 || true
    if [ ! -s "$MODPATH/slots.map" ]; then
      ui_print "⚠ 挂载计划没有生成（slots.map 为空）"
      ui_print "  字体库里有 $(ls "$LIB"/builtin_*.ttf 2>/dev/null | wc -l | tr -d \' \') 套自带配色"
      ui_print "  修复尝试：重新生成一次…"
      OUT2=$(sh "$MODPATH/fontctl.sh" apply "$PEND" 2>&1 | tail -n1)
      case "$OUT2" in
        OK:*) ui_print "  ✓ 已生成（$OUT2）" ;;
        *)    ui_print "  ✗ 仍然失败：${OUT2#ERROR:}"
              ui_print "  开机后请在 WebUI 里重新选一次配色" ;;
      esac
    fi
  fi
fi

LIB_COUNT=$(lib_font_ids 2>/dev/null | grep -c '^builtin_')
# ★ 2026-10-14（与主项目同步）：`conflicts` 也要扫一遍机器上的字体配置，会停一会儿。
ui_print "- 正在检查有没有其它字体模块…"
ui_print "  （也会扫一遍字体配置，稍等）"
CONFLICTS=$(sh "$MODPATH/fontctl.sh" conflicts 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')

# ===========================================================================
# 刷入日志（4 区 + 分割线；与主项目同一套排版，内容换成子项目的）
# ===========================================================================
GD="无"; [ -f "$OLD/disable" ] && GD="有"
GU="无"; [ -f "$OLD/update" ] && GU="有（上一次安装没被激活）"
GS="无"; case "$(getprop persist.sys.safemode)$(getprop ro.sys.safemode)" in *1*) GS="有" ;; esac
GM="无"; { command -v magisk >/dev/null 2>&1 || [ -e /data/adb/magisk ]; } && GM="有"

ui_print " "
ui_print "========================================================"
ui_print " 保时捷字体（三合一）  $(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -n1 | tr -d '\r')"
ui_print "========================================================"
ui_print " "
ui_print "[1/4] 设备与系统"
ui_print "- 设备：$(getprop ro.product.brand 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
ui_print "- 系统：Android $(getprop ro.build.version.release 2>/dev/null)   内核 $(uname -r 2>/dev/null)"
ui_print "- 系统识别：${ROM_NAME:-未知}"
ui_print "- Root 管理器：$(root_manager_name "$RM" 2>/dev/null)"
if [ "$(mount_mode 2>/dev/null)" = manager ]; then
  ui_print "- 挂载方式：交给管理器 / 元模块"
else
  ui_print "- 挂载方式：模块自带挂载（无需元模块）"
fi
ui_print "- 门禁：已禁用=$GD   待激活=$GU   安全模式=$GS   Magisk共存=$GM"
ui_print "--------------------------------------------------------"
ui_print " "
ui_print "[2/4] 内置配色"
ui_print "- 自带配色：${LIB_COUNT:-0} 套（素装 / 一点红 / 烈焰）"
ui_print "  位置：$LIB"
if [ -n "${PEND:-}" ] && [ "$PEND" != "none" ]; then
  ui_print "- 当前选择：$PEND"
else
  ui_print "- 当前选择：无字体（系统默认）"
fi
if [ -d "$LIB/.orig" ]; then
  _okb=$(du -sk "$LIB/.orig" 2>/dev/null | awk '{print $1}')
  ui_print "- 主题字体原件备份：${_okb:-0} KB（卸载时自动还原）"
fi
ui_print "- 更新模块不会丢失选择；卸载全部配色包才会删除字体库"
ui_print "--------------------------------------------------------"
ui_print " "
ui_print "[3/4] 扫描与槽位"
_slotn=$(grep -c . "$MODPATH/slots.map" 2>/dev/null | tr -d ' ')
[ -n "$_slotn" ] || _slotn=0
_tcn=$(awk '$2 ~ /\.ttc$/ {c++} END {print c+0}' "$MODPATH/slots.map" 2>/dev/null)
ui_print "- 槽位计划：${_slotn} 个，其中中文合集槽位 ${_tcn:-0} 个"
_sf=$(ls -1 /system/fonts 2>/dev/null | grep -c . )
_pf=$(ls -1 /product/fonts 2>/dev/null | grep -c . )
ui_print "- 系统字体：/system/fonts ${_sf:-0} 个，/product/fonts ${_pf:-0} 个"
_cfg=$(ls -1 /system/etc/fonts.xml /system/etc/fonts_fallback.xml 2>/dev/null | head -n1)
if [ -n "$_cfg" ]; then
  _cfgkb=$(du -k "$_cfg" 2>/dev/null | awk '{print $1}')
  ui_print "- 字体配置：$_cfg（${_cfgkb:-?} KB）"
fi
if [ -n "${CONFLICTS:-}" ]; then
  ui_print "- ⚠ 冲突字体模块：$CONFLICTS   （建议先停用，避免互相覆盖）"
else
  ui_print "- 冲突字体模块：无"
fi
ui_print "--------------------------------------------------------"
ui_print " "
ui_print "[4/4] 完成"
ui_print "- 模块版本：$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -n1 | tr -d '\r')   安装位置：$MODPATH"
_um="不适用"
if [ -d /data/adb/ksu ]; then
  if [ -e /data/adb/ksu/umount_enabled ] || [ "$(cat /data/adb/ksu/.umount 2>/dev/null)" = "1" ]; then
    _um="开启（部分 App 可能看不到挂载）"
  else
    _um="关闭（App 里也能看到字体）"
  fi
fi
ui_print "- 管理器卸载机制：$_um"
if [ -n "${PEND:-}" ] && [ "$PEND" != "none" ]; then
  ui_print "- ⏳ 重启后生效（现在还是系统原字体）"
fi
ui_print " "
ui_print "- 使用方法："
ui_print "  1. 管理器里点本模块 → 打开（WebUI）"
ui_print "  2. 点选配色卡片切换（内置三套，不用导入）"
ui_print "  3. 重启生效；选「无字体」即恢复系统默认"
if [ "$RM" = magisk ]; then
  ui_print "  · Magisk 没有 WebUI 入口：先装 KsuWebUI，再点模块卡片的「操作」"
fi
ui_print " "
ui_print "- 出问题时：界面「诊断报告」→ 生成（会自动存到 Download）"
ui_print "- 保险：若选配色后没能开机，下次开机会自动恢复为「无字体」"
ui_print "========================================================"

if [ -f "$MODPATH/diag.sh" ]; then
  cp -f "$MODPATH/diag.sh" /data/local/tmp/font_diag.sh 2>/dev/null
  chmod 755 /data/local/tmp/font_diag.sh 2>/dev/null
fi



# ---------------------------------------------------------------------------
# 字体档案：给已有字体补 .fdata（结构清单），诊断报告要用
#   放在安装结束前跑，用户打开界面时档案已经在了
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 扫描印记：只在"需要重扫"时才扫
#   scanmarks.conf 声明要求版本（slot / font 分开），设备上 .scanmarks 记已扫到哪版
#   设备记录 <= 要求版本 → 扫（含同版本覆盖安装，方便开发自测）
#   设备记录 >  要求版本 → 跳过
# ---------------------------------------------------------------------------
LIB="${LIB:-/data/adb/custom_font_lib}"
MARKS="$LIB/.scanmarks"
MCUR=$(sed -n 's/^versionCode=//p' "$MODPATH/module.prop" 2>/dev/null | head -1 | tr -d '\r')
case "$MCUR" in ''|*[!0-9]*) MCUR=0 ;; esac

mk_req() {
  [ -f "$MODPATH/scanmarks.conf" ] || return 1
  sed -n "s/^$1=//p" "$MODPATH/scanmarks.conf" 2>/dev/null | head -1 | tr -d '\r'
}
mk_cur() {
  [ -f "$MARKS" ] || return 1
  sed -n "s/^$1=//p" "$MARKS" 2>/dev/null | head -1 | tr -d '\r'
}
mk_need() {
  _req=$(mk_req "$1")
  case "$_req" in ''|*[!0-9]*) return 1 ;; esac
  _cur=$(mk_cur "$1")
  case "$_cur" in '') return 0 ;; esac
  case "$_cur" in *[!0-9]*) return 0 ;; esac
  [ "$_cur" -le "$_req" ] && return 0
  return 1
}
mk_set() {
  mkdir -p "$LIB" 2>/dev/null
  [ -f "$MARKS" ] || : > "$MARKS" 2>/dev/null
  grep -v "^$1=" "$MARKS" > "$MARKS.tmp" 2>/dev/null
  echo "$1=$2" >> "$MARKS.tmp"
  mv -f "$MARKS.tmp" "$MARKS" 2>/dev/null
}

if [ -f "$LIB/.force_rescan" ]; then
  rm -f "$MARKS" "$LIB/.force_rescan" 2>/dev/null
  ui_print "- 检测到强制重扫标记，本次全部重扫"
fi

if mk_need slot; then
  rm -f "$LIB/scanned/device.list" "$LIB/scanned/slots.list" "$LIB/scanned/slots.meta" \
        "$LIB/scanned/skip.list" "$LIB/scanned/ttc.list" "$LIB/scanned/env.list" \
        "$LIB/scanned/.schema" 2>/dev/null
  if [ -f "$MODPATH/fontctl.sh" ]; then
    sh "$MODPATH/fontctl.sh" rescan >/dev/null 2>&1 && {
      mk_set slot "$MCUR"
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


if mk_need font; then
  if [ -f "$MODPATH/fdata.sh" ]; then
    sh "$MODPATH/fdata.sh" 2>/dev/null | sed 's/^/  /' >/dev/null 2>&1
    ui_print "- 已为已有字体补充结构档案"
  fi
  
# ---------------------------------------------------------------------------
# 清理旧版"GMS 缓存桥接"的残留（本版已移除该功能）
# ---------------------------------------------------------------------------
if [ -f "$LIB/gms_cache.sh" ]; then
  LIB="$LIB" sh "$LIB/gms_cache.sh" off >/dev/null 2>&1 || true
fi
rm -f "$LIB"/.clone.*.ttf "$LIB/.gms_cache_on" "$LIB"/.gms_bridge.list "$LIB"/.gms_bridge.log 2>/dev/null

if [ -f "$MODPATH/metaprobe.sh" ]; then
    LIB="$LIB" sh "$MODPATH/metaprobe.sh" 2>/dev/null | sed 's/^/  /' >/dev/null 2>&1
    ui_print "- 已写入字体合成所需信息（轮廓类型 / 可变轴）"
  fi
  mk_set font "$MCUR"
else
  ui_print "- 字体档案已是最新（无需重扫）"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in common.sh slots.sh mount.sh fontctl.sh update.sh google_font.sh gms_cache.sh nameclone.sh action.sh \
         diag.sh post-fs-data.sh post-mount.sh service.sh uninstall.sh; do
  set_perm "$MODPATH/$f" 0 0 0755
done
