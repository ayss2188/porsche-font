#!/system/bin/sh
# builtin.sh —— 内置字体注入 + 刷入时选配色（内置字体模块专用）
#
# ⚠️ 本文件是**本项目专属**的：主项目 D:\ds\src 里没有它。
#    同步主项目（覆盖源码）时，这个文件不会被动到，但 customize.sh 里对它的三处调用
#    （builtin_sibling_cleanup / builtin_import / builtin_clean_legacy）和
#    builtin_menu 的调用**必须重放**，否则内置配色注入不进字体库（详见接手文档第 17 节）。
#
# 思路：不改造老的内置字体模块，直接复用"自定义字体切换"的全套机制 ——
# 把模块自带的字体在**安装时**硬链接进字体库（/data/adb/custom_font_lib），
# 于是它和"用户自己导入的字体"完全一样：界面能选、能切配色、开机保护、诊断报告、在线更新全都现成。
#
# 硬链接要点：模块目录和字体库都在 /data 同一个分区 → 不额外占空间（44MB×3 也不会变 132MB）。
# 安装失败再退回复制。卸载时主模块的 uninstall.sh 会清掉字体库，不留残留。
#
# 用法（在 customize.sh 里）：
#     . "$MODDIR/builtin.sh"
#     builtin_import        # 硬链接进字体库（必须在字体库准备好之后）
#     builtin_menu          # 刷入时音量键选配色；只有一个字体时自动跳过
# 老体验保持不变：**刷完直接重启就生效**，不需要先导入字体。

# ---------------------------------------------------------------------------
# 内置字体识别：文件名 → 字体库 id / 显示名
# ---------------------------------------------------------------------------
builtin_id_of() {
  case "$1" in
    none|无色|素装|718)  echo "builtin_none|718素装版（无色版）" ;;
    colon|一点红|911)    echo "builtin_colon|911经典版（一点红）" ;;
    flair|烈焰|gt3|GT3)  echo "builtin_flair|GT3赛道版（烈焰版）" ;;
    *) echo "builtin_$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_')|$1" ;;
  esac
}

# 本模块自带的字体文件（绝对路径，按文件名排序 —— glob 顺序就是菜单序号）
# ⚠️ 所有"数自带字体 / 列菜单 / 按序号取文件"的地方都走这一个函数，
#    否则会出现"builtin_count 认 4 种扩展名、菜单只认 .ttf"这种错位（.otf 包会静默失效）
builtin_files() {
  local bdir="$MODDIR/builtin" f
  [ -d "$bdir" ] || return 0
  for f in "$bdir"/*.otf "$bdir"/*.OTF "$bdir"/*.ttf "$bdir"/*.TTF; do
    [ -f "$f" ] || continue
    # ★ 只返回**有效**字体。放在这里而不是各个调用点，是因为 builtin_count / builtin_menu /
    #   builtin_apply_first 全都走这个函数 —— 在这里挡住，菜单就不会列出坏选项、
    #   计数也不会把坏文件算进去（否则用户选了、apply 才发现不行）。
    #   校验函数由 fontcheck.sh 提供；载不进来时**不放行**（宁可少一份，也不给系统坏文件）。
    if ! command -v valid_font >/dev/null 2>&1; then return 0; fi
    valid_font "$f" || continue
    echo "$f"
  done
}

# 本模块自带的字体有几个（决定要不要弹选择菜单）
builtin_count() {
  local n
  n=$(builtin_files | grep -c .)
  echo "${n:-0}"
}

# ---------------------------------------------------------------------------
# 这个自带字体是不是"可变字体"（带字重轴）
#
# 为什么要判：诊断报告和界面的「字体粗细」说明都靠 meta 里的 vf= 字段 ——
#   系统设置里的「字体粗细」调节靠的是可变字体的 wght 轴，普通单字重字体没有这个轴。
#   本模块自带的三套配色都是可变字体（fvar 表 + wght 轴 150~700），所以正常都该写 vf=1；
#   万一哪个包里的字体被换成静态字体，这个字段就是"报告为什么会说粗细调不动"的依据。
#
# 判据：sfnt 的表目录紧跟在文件头 12 字节后面，长度 = 12 + 16×表数量（这里 21 张表 = 348 字节），
#   所以 'fvar' 这个表标签一定出现在**文件前 512 字节**里。只读这 512 字节，不读整个 44MB 文件。
# ---------------------------------------------------------------------------
builtin_is_vf() {
  local f="$1" n
  [ -f "$f" ] || return 1
  n=$(head -c 512 "$f" 2>/dev/null | grep -c 'fvar' 2>/dev/null)
  case "$n" in ''|0) return 1 ;; esac
  return 0
}

# ---------------------------------------------------------------------------
# 注入：把 builtin/*.ttf 硬链接成字体库里的字体
# ---------------------------------------------------------------------------
builtin_import() {
  local bdir="$MODDIR/builtin" f n info id nm dst ok=0 vf=0
  [ -d "$bdir" ] || return 0
  mkdir -p "$LIB" 2>/dev/null

  for f in "$bdir"/*.ttf "$bdir"/*.TTF "$bdir"/*.otf "$bdir"/*.OTF; do
    [ -f "$f" ] || continue
    n=${f##*/}; n=${n%.*}
    info=$(builtin_id_of "$n")
    id=${info%%|*}; nm=${info#*|}
    [ -n "$id" ] || continue
    dst="$LIB/$id.ttf"

    # ★★ 必须校验！**这一步以前漏了，导致坏字体被挂上系统槽 → 卡开机。**
    #   用户导入的字体走 fontctl.sh 的 store_font()，那里会调 valid_font 验表目录
    #   （表数量、每张表的偏移+长度是否落在文件内、必需的 cmap/head/hhea/hmtx/maxp 是否齐）。
    #   而内置字体走的是**硬链接**，绕过了那一整套校验 —— 一个 2KB 的假文件
    #   照样被注入字体库、被 builtin_apply_first 自动选中、被挂到系统字体槽上，
    #   结果就是"卡开机第二屏"。
    #   现在：不合法就**跳过这一份**，宁可不注入，也绝不把坏文件交给系统。
    # 校验函数由 fontcheck.sh 提供（customize.sh / fontctl.sh 都会先载入它）。
    # 真载不进来时也**不能放行** —— 宁可整份跳过，也不把没验过的文件交给系统。
    if ! command -v valid_font >/dev/null 2>&1; then
      ui_print "  ⚠ 缺少 fontcheck.sh，无法校验自带配色「$n」——已跳过（不注入、不挂载）"
      continue
    fi
    if ! valid_font "$f"; then
      ui_print "  ⚠ 自带配色「$n」不是有效的字体文件（损坏/截断/假文件）——已跳过，不注入也不挂载"
      continue
    fi

    # 本模块自带的三套配色都是可变字体（带 wght 字重轴）→ 写进 meta 供报告/界面判断
    if builtin_is_vf "$f"; then vf=1; else vf=0; fi

    # 已经是指向同一份文件的硬链接就跳过（覆盖安装/重复安装时省事）
    if [ -f "$dst" ] && [ "$(stat -c %i "$dst" 2>/dev/null)" = "$(stat -c %i "$f" 2>/dev/null)" ]; then
      # 硬链接已经在位，但 meta 可能还是旧格式（比如少了 vf=）→ 重写一遍
      printf '%s' "$nm" > "$LIB/$id.name" 2>/dev/null
      # ★ 2026-10-19：把真实文件大小写进 meta（size=）。
      #   界面显示字体大小读的就是它；不写的话内置配色会显示成「—」，
      #   只有被应用过的那一套才会因为轮廓分析补上大小。
      _bsz=$(wc -c < "$dst" 2>/dev/null | tr -d ' \t\r\n')
      case "${_bsz:-}" in ''|*[!0-9]*) _bsz=0 ;; esac
      printf 'scope=all\nlatin=1\ncjk=1\nvf=%s\nsize=%s\n' "$vf" "$_bsz" > "$LIB/$id.meta" 2>/dev/null
      ok=$((ok + 1)); continue
    fi

    rm -f "$dst" 2>/dev/null
    ln "$f" "$dst" 2>/dev/null || cp -f "$f" "$dst" 2>/dev/null
    if [ ! -s "$dst" ]; then
      rm -f "$dst" 2>/dev/null
      continue
    fi
    chmod 644 "$dst" 2>/dev/null
    chcon u:object_r:system_file:s0 "$dst" 2>/dev/null
    printf '%s' "$nm" > "$LIB/$id.name" 2>/dev/null
    _bsz=$(wc -c < "$dst" 2>/dev/null | tr -d ' \t\r\n')
    case "${_bsz:-}" in ''|*[!0-9]*) _bsz=0 ;; esac
    printf 'scope=all\nlatin=1\ncjk=1\nvf=%s\nsize=%s\n' "$vf" "$_bsz" > "$LIB/$id.meta" 2>/dev/null
    ok=$((ok + 1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# 某个字体 id 现在有没有人在用（正在生效 / 待生效 / 上次的选择）
#
# ⚠️ 安装时 $MODDIR 是**暂存目录**（/data/adb/modules_update/<id>），zip 里不带状态文件，
#    所以在 $MODDIR 里读 pending_font / active_font 永远读不到 —— 必须读：
#      $OLD=/data/adb/modules/<id>  已安装模块目录（升级前用户的选择就在这里）
#      $LIB/last_selection          字体库记录的选择（姊妹项目 custom_font_switcher 也写它）
# ---------------------------------------------------------------------------
builtin_in_use() {
  local id="$1" s v
  for s in "$OLD/pending_font" "$OLD/active_font" "$LIB/last_selection" \
           "$MODDIR/pending_font" "$MODDIR/active_font"; do
    [ -f "$s" ] || continue
    v=$(tr -d '[:space:]' 2>/dev/null < "$s")
    [ -n "$v" ] || continue
    # 选择可能是 "中文id+英文id" 的组合，逐个比对，别做子串匹配（f1 会误配 f11）
    case "+$v+" in *"+$id+"*) return 0 ;; esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# 用户上次选的是哪套配色（用来把菜单光标停在那一项上）
#
# 为什么要读这么多地方：三代的记录方式完全不同，跨版本升级要都能认出来
#   老包 v2.0：$MODDIR/active_profile 或 pending_profile，内容是 **数字** 1/2/3
#              （老包把字体硬链接进 module/system/fonts，根本不进字体库，
#                所以升级上来字体库里没有旧字体，不用迁移）
#   新模板   ：<已安装模块目录>/active_font 或 pending_font，内容是字体库 id
#   字体库   ：$LIB/last_selection，内容是字体库 id
#
# ⚠️ 读的必须是**已安装**目录（$OLD = /data/adb/modules/<id>）：
#    安装时 $MODPATH 是暂存目录 /data/adb/modules_update/<id>，zip 里没有状态文件，
#    在那儿读永远读不到 → 菜单光标固定回落到第 1 项。$OLD 由调用方传进来。
# 返回 1..n（builtin/ 里 *.ttf 的 glob 顺序）或者空。
# ---------------------------------------------------------------------------
builtin_last_choice() {
  local want="" i=0 b bn v
  # 1) 老包 v2.0 的数字：1=素装(none) 2=一点红(colon) 3=烈焰(flair)
  #    ⚠️ 千万别把这个数字直接当 builtin/ 的序号用：glob 是按文件名排序的
  #       （colon / flair / none），和老包菜单的 1/2/3 完全错位。必须按文件名映射。
  for v in "$OLD/active_profile" "$OLD/pending_profile" "$MODDIR/active_profile" "$MODDIR/pending_profile"; do
    [ -f "$v" ] || continue
    v=$(tr -d '[:space:]' 2>/dev/null < "$v")
    case "$v" in
      1) want="none" ;;
      2) want="colon" ;;
      3) want="flair" ;;
      *) continue ;;
    esac
    break
  done
  # 2) 字体库 id（builtin_none 之类）
  if [ -z "$want" ]; then
    v=$(tr -d '[:space:]' 2>/dev/null < "$LIB/last_selection")
    [ -n "$v" ] || v=$(tr -d '[:space:]' 2>/dev/null < "$OLD/active_font")
    [ -n "$v" ] || v=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/active_font")
    case "$v" in
      builtin_*) want=${v#builtin_} ;;
      *) return 1 ;;
    esac
  fi
  [ -n "$want" ] || return 1
  # 按文件名找回 glob 序号（两个循环的顺序必须一致：同一个目录、同一种 glob）
  for b in "$MODDIR/builtin"/*.ttf; do
    [ -f "$b" ] || continue
    i=$((i + 1))
    bn=${b##*/}
    [ "$bn" = "$want.ttf" ] && { echo "$i"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# 清掉字体库里"没人用"的旧字体（f<时间戳>.ttf，一个就几十 MB）
#
# ⚠️ 只删**孤儿**：正在生效 / 待生效 / 上次选择 指向的一律保留。
#    为什么这么保守：字体库是**和姊妹项目 custom_font_switcher 共用**的
#    （它也把用户导入的字体存在同一个 /data/adb/custom_font_lib）。
#    删掉它正在用的字体 = 那个模块下次开机挂载失效、字体静默变回默认。
#    省空间是次要目标，绝不值得冒这个险。
#
# 另外：老包 v2.0 从来不往字体库放东西（它把字体硬链接进 module/system/fonts，
# 状态写 active_profile/pending_profile），所以"老包升级上来库里有旧字体"并不成立；
# 这个函数实际只服务于"用户同时用过姊妹项目"的边缘情况。
# ---------------------------------------------------------------------------
builtin_clean_legacy() {
  local f id kept=0 removed=0 kb=0 n
  [ -d "$LIB" ] || return 0
  for f in "$LIB"/f[0-9]*.ttf; do          # 只认 f<数字>（导入的），内置配色 builtin_* 不碰
    [ -f "$f" ] || continue
    id=${f##*/}; id=${id%.*}
    if builtin_in_use "$id"; then
      kept=$((kept + 1))
      continue
    fi
    # 取字节数：取不到就按 0 算。别把 $(wc …) 直接塞进算术表达式 ——
    # wc 不在 PATH / 读失败时表达式会变成 $((kb + / 1024))，在 ash 里是致命错误，
    # 整个安装脚本会当场中断（后面 ROM 识别、写状态、set_perm 全不执行）。
    n=$(wc -c < "$f" 2>/dev/null | tr -d ' \t\r\n')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    kb=$((kb + n / 1024))
    rm -f "$f" "$LIB/$id.name" "$LIB/$id.meta" 2>/dev/null
    removed=$((removed + 1))
  done
  if [ "$removed" -gt 0 ]; then
    ui_print "- 已清理没人使用的旧字体 $removed 个（约 $((kb / 1024)) MB）"
  fi
  [ "$kept" -gt 0 ] && ui_print "- 保留正在使用的字体 $kept 个"
  return 0
}

# ---------------------------------------------------------------------------
# ★ 2026-10-19：把字体库**归位**到只剩本模块的内置配色
#
#   背景：老版本界面里还带着主项目那套「导入第三方字体 / 删除」功能，
#   于是用户会往这个"配色字体包"里塞自己的字体（真机截图里就有
#   「犬神志-超级保时捷Pro公开版 21.6MB」），也有把内置配色删掉的。
#   新版本把导入入口去掉了，所以升级时顺便归位：
#     · 非内置的（f<数字> 这类导入字体）→ 删掉（连 .name/.meta/合集一起）
#     · 内置的被用户删了 → builtin_import 已经按包里的原件重新链回来
#     · 选中的正好是被删掉的那个 → 清掉记录，自动回落内置配色
#
#   ⚠️ 字体库是**和姊妹项目 custom_font_switcher 共用**的。
#      那个模块在装（且没被标记删除）时，库里的 f<数字> 一个都不能动 ——
#      否则它下次开机会挂载失败、字体静默变回默认。
# ---------------------------------------------------------------------------
builtin_prune_imported() {
  local d sib=0 f f2 n id v wl="" ids kb=0 removed=0
  for d in /data/adb/modules/custom_font_switcher \
           /data/adb/modules_update/custom_font_switcher; do
    [ -d "$d" ] && [ ! -f "$d/remove" ] && sib=1
  done
  if [ "$sib" = "1" ]; then
    ui_print "- 检测到姊妹项目「自定义字体切换模块」也在用字体库 → 已导入的字体保留不动"
    return 0
  fi
  [ -d "$LIB" ] || return 0

  # 内置白名单
  for f in "$MODDIR"/builtin/*.ttf "$MODDIR"/builtin/*.TTF "$MODDIR"/builtin/*.otf "$MODDIR"/builtin/*.OTF; do
    [ -f "$f" ] || continue
    n=${f##*/}; n=${n%.*}
    id=$(builtin_id_of "$n"); id=${id%%|*}
    [ -n "$id" ] && wl="$wl $id"
  done

  # 待清理的 id（去重）
  ids=$(for f in "$LIB"/f[0-9]*.ttf "$LIB"/f[0-9]*.TTF "$LIB"/f[0-9]*.otf "$LIB"/f[0-9]*.OTF; do
          [ -f "$f" ] || continue
          n=${f##*/}
          printf '%s\n' "${n%%.*}"
        done | sort -u)

  for id in $ids; do
    [ -n "$id" ] || continue
    case " $wl " in *" $id "*) continue ;; esac
    n=$(wc -c < "$LIB/$id.ttf" 2>/dev/null | tr -d ' \t\r\n')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    kb=$((kb + n / 1024))
    rm -f "$LIB/$id".ttf "$LIB/$id".TTF "$LIB/$id".otf "$LIB/$id".OTF \
          "$LIB/$id".name "$LIB/$id".meta "$LIB/$id".ttc* 2>/dev/null
    removed=$((removed + 1))
  done
  if [ "$removed" -gt 0 ]; then
    ui_print "- 已移除 $removed 个非内置字体（约 $((kb / 1024)) MB）—— 本模块只用内置配色"
  fi

  # 选中项如果指向已经不存在的字体 → 清掉，回落内置配色
  for f2 in "$LIB/last_selection" "$LIB/.last_good" "$OLD/active_font" "$OLD/pending_font"; do
    [ -f "$f2" ] || continue
    v=$(tr -d '[:space:]' 2>/dev/null < "$f2")
    case "$v" in ""|none) continue ;; esac
    if [ ! -f "$LIB/$v.ttf" ] && [ ! -f "$LIB/$v.TTF" ] && [ ! -f "$LIB/$v.otf" ] && [ ! -f "$LIB/$v.OTF" ]; then
      printf 'none' > "$f2" 2>/dev/null
      ui_print "- 你上次选的那个字体已不在库里，已改为内置配色"
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# 刷入时选配色（沿用老模块的体验：音量[下]切换、音量[上]确定）
# 只写 pending_font —— 开机会自动把它挂上并转成 active_font，所以"刷完重启即生效"。
#
# 光标会停在你**上次选的那套**配色上：想保持不变就按一下音量[上]；
# 不按的话默认就是上次那套（builtin_last_choice 认不出时才回落到第 1 项）。
# ---------------------------------------------------------------------------
builtin_menu() {
  local n sel=1 last keyInfo isUp name id list="" i=0
  n=$(builtin_count)
  [ "$n" -gt 0 ] 2>/dev/null || return 0

  # 覆盖安装：只在**已安装目录**里已有有效选择时才早退。
  # ⚠️ 别读 $MODDIR/pending_font —— 安装时它是暂存目录，而且 customize.sh 会先写成 none，
  #    在那儿判永远判不出"有选择"，菜单每次都会弹（老用户随手按一下就把配色换掉了）。
  #
  # ★★ 第二个坑（真机上就是这样"更新完字体变了"的）：
  #    **`active_font` 也必须看**。用户正常用着的时候，`pending_font` 就是 `none`
  #    （选完重启后 pending 归 none、active 才是真正生效的那套）。
  #    只看 pending 的话，每一次更新都会弹菜单 → 用户随手按音量[上] →
  #    配色被静默换成第一项。这正是"3.5 用着喜欢的字体，更新后变成别的"的机制。
  #    所以：pending 或 active **任一**指向真实字体，就说明用户有选择，别打扰他。
  _prev_p=$(tr -d '[:space:]' 2>/dev/null < "$OLD/pending_font")
  _prev_a=$(tr -d '[:space:]' 2>/dev/null < "$OLD/active_font")
  case "$_prev_p" in ''|none) _prev_p="" ;; esac
  case "$_prev_a" in ''|none) _prev_a="" ;; esac
  if [ -n "$_prev_p" ] || [ -n "$_prev_a" ]; then
    # ★ 措辞交给调用方决定：恢复**成功**才叫"沿用"，恢复失败（改用了内置配色）
    #   就不能说"沿用" —— 否则日志里会出现

    #   「没找到你上次选的 X」+「沿用你上次的配色选择」

    #   这种自相矛盾（作者本人吐槽过）。
    #   调用方在进菜单之前设 BUILTIN_MENU_NOTE=... 就能覆盖这句话。
    if [ -n "${BUILTIN_MENU_NOTE:-}" ]; then
      ui_print "- $BUILTIN_MENU_NOTE"
    else
      ui_print "- 沿用你上次的配色选择（不弹菜单；想换配色请在 WebUI 里点）"
    fi
    return 0
  fi

  # 上一次选的配色（老包的数字 / 字体库的 id 都认）
  last=$(builtin_last_choice)
  case "$last" in
    ''|*[!0-9]*) last=1 ;;
  esac
  [ "$last" -ge 1 ] 2>/dev/null || last=1
  [ "$last" -le "$n" ] 2>/dev/null || last=1
  sel="$last"

  # 只有一个字体（单色版）：自动选中，不打扰用户
  if [ "$n" = 1 ]; then
    for f in $(builtin_files); do
      [ -f "$f" ] || continue
      b=${f##*/}; b=${b%.*}                      # 去掉扩展名再识别，否则匹配不上
      info=$(builtin_id_of "$b")
      printf '%s' "${info%%|*}" > "$MODDIR/pending_font"
      printf 'none' > "$MODDIR/active_font"
      ui_print "- 内置配色：${info#*|}"
      break
    done
    return 0
  fi

  # 测试/无人值守用：PF_BUILTIN_DEFAULT=<1..n> 直接选定，不等音量键
  # （沙箱里没有 getevent，等下去会一直挂住；真机刷入时这个变量不存在，走正常交互）
  case "${PF_BUILTIN_DEFAULT:-}" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$PF_BUILTIN_DEFAULT" -ge 1 ] 2>/dev/null && [ "$PF_BUILTIN_DEFAULT" -le "$n" ] 2>/dev/null; then
        i=0
        for ff in $(builtin_files); do
          [ -f "$ff" ] || continue
          i=$((i + 1))
          [ "$i" = "$PF_BUILTIN_DEFAULT" ] || continue
          bb=${ff##*/}; bb=${bb%.*}
          id=$(builtin_id_of "$bb" | cut -d'|' -f1)
          printf '%s' "$id" > "$MODDIR/pending_font"
          printf 'none' > "$MODDIR/active_font"
          ui_print "- 已按 PF_BUILTIN_DEFAULT 选定：$(builtin_id_of "$bb" | cut -d'|' -f2)（重启后生效）"
          break
        done
        return 0
      fi
      ;;
  esac

  # 多套配色：列出全部（顺序 = builtin_files 的顺序，也就是 glob 顺序）
  for f in $(builtin_files); do
    [ -f "$f" ] || continue
    i=$((i + 1))
    b=${f##*/}; b=${b%.*}
    name=$(builtin_id_of "$b" | cut -d'|' -f2)
    list="$list$i|$name
"
  done

  ui_print " "
  ui_print "====== 请选择初始配色 ======"
  printf '%s' "$list" | while IFS='|' read -r k v; do
    [ -n "$v" ] && ui_print "   <$k> $v"
  done
  ui_print "  按音量[下]切换，按音量[上]确定"
  if [ "$sel" -gt 1 ] 2>/dev/null; then
    ui_print "  （默认停在 <$sel>：你上次选的就是这套，直接按音量[上]即可）"
  else
    ui_print "  （按音量[上]就用 <1>）"
  fi
  ui_print "============================"

  keyInfo=true
  while $keyInfo; do
    keyInfo=$(getevent -qlc 1 2>/dev/null | grep KEY_VOLUME)
    if [ -z "$keyInfo" ]; then continue; fi
    isUp=$(printf '%s' "$keyInfo" | grep KEY_VOLUMEUP)
    if [ -z "$isUp" ]; then
      sel=$((sel + 1)); [ "$sel" -gt "$i" ] && sel=1
      name=$(printf '%s' "$list" | sed -n "${sel}p" | cut -d'|' -f2)
      ui_print "- 当前选择：$sel ==> $name"
      sleep 1
    else
      break
    fi
    keyInfo=true
  done

  f=$(printf '%s' "$list" | sed -n "${sel}p" | cut -d'|' -f2)
  # 按序号找回对应的文件（必须和上面列菜单用同一个 builtin_files，顺序才一致）
  i=0
  for ff in $(builtin_files); do
    [ -f "$ff" ] || continue
    i=$((i + 1))
    [ "$i" = "$sel" ] || continue
    bb=${ff##*/}; bb=${bb%.*}
    id=$(builtin_id_of "$bb" | cut -d'|' -f1)
    printf '%s' "$id" > "$MODDIR/pending_font"
    printf 'none' > "$MODDIR/active_font"
    ui_print "- 已确定：<$f>（重启后生效）"
    break
  done
  return 0
}

# ---------------------------------------------------------------------------
# ★ 关键：把「用户上次选的那份字体」认成**内置的哪一套**
#
# 为什么需要（作者一句话点破）：
#   从老版本升上来时，**字体原文件换了**（旧版的字体库 id 跟新版的 builtin_* 不是一回事），
#   所以 `apply $LAST` 必然找不到 —— 这**不是 bug，是必然**。
#   但既然"没找到就能自动改用一套"，那就该改用到**用户原来那套**，
#   而不是闭着眼睛挑排序第一的（那样每个从旧版升上来的用户都会被换成 911·一点红）。
#
# 判据（都是"这份字体到底是不是同一份"的直接证据）：
#   ① 文件名里就带型号（老包可能存成 718.ttf / colon.ttf / none.ttf…）
#   ② **文件大小**（三套真字体的大小各不相同，实测 44,844,664 / 796 / 868，只差几十字节 —— 够用）
#   ③ 字体库里的 `last_selection` 记录（老包可能写的是数字 1/2/3 或直接是型号名）
# 输出：内置的字体 id（builtin_xxx）；认不出返回空。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# ★★ 最可靠的一招：**读已安装模块的 module.prop 描述**
#
# 为什么这个最优先（作者点破的，比按文件大小猜干净得多）：
#   老版本是**正常在用**的，而 refresh_prop 每次切换都会把"当前生效的是哪套"
#   写进 module.prop 的描述里：
#       description=[系统：自动识别 | 当前生效：718素装版（无色版）] 内置配色版：…
#   所以覆盖安装时读 **$OLD/module.prop**（= 升级前那份）就能直接知道用户原来用哪套，
#   不用去猜文件、也不用管 id 换没换。
#
# 注意：读 $OLD 而不是 $MODDIR —— 安装时 $MODDIR 是暂存目录，里面是新包的描述。
# 输出：内置字体 id（builtin_xxx）；读不到/认不出返回空（调用方会退回别的判据）。
# ---------------------------------------------------------------------------
builtin_map_from_prop() {
  local desc cur
  [ -f "$OLD/module.prop" ] || { printf '%s' ""; return 0; }
  desc=$(sed -n 's/^description=//p' "$OLD/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
  [ -n "$desc" ] || { printf '%s' ""; return 0; }
  # 取「当前生效：」到「，」或「]」之间的那段
  cur=$(printf '%s' "$desc" | sed -n 's/.*当前生效：\([^]，]*\).*/\1/p')
  [ -n "$cur" ] || { printf '%s' ""; return 0; }
  # 交给型号名判据去认（它认 none/无色/素装/718、colon/一点红/911、flair/烈焰/gt3）
  builtin_map_from_prev "$cur"
}

builtin_map_from_prev() {
  local last="$1" f b info id sz bsz
  # ① 记录里直接就是型号名（老包 / 手工改过的情况）
  case "$last" in
    *none*|*无色*|*素装*|*718*)  builtin_id_of none  | cut -d'|' -f1; return 0 ;;
    *colon*|*一点红*|*911*)      builtin_id_of colon | cut -d'|' -f1; return 0 ;;
    *flair*|*烈焰*|*gt3*|*GT3*)  builtin_id_of flair | cut -d'|' -f1; return 0 ;;
  esac
  # ② 老包 v2.0 的数字：1=素装(none) 2=一点红(colon) 3=烈焰(flair)
  case "$last" in
    1) builtin_id_of none  | cut -d'|' -f1; return 0 ;;
    2) builtin_id_of colon | cut -d'|' -f1; return 0 ;;
    3) builtin_id_of flair | cut -d'|' -f1; return 0 ;;
  esac
  # ③ 按"文件大小"认：用户上次选的那个文件，和三套自带字体比大小
  #    ⚠️ 必须在**删掉它之前**比 —— 所以调用方要放在 builtin_clean_legacy 前面
  for id in $(printf '%s' "$last" | tr '+' '\n'); do
    [ -f "$LIB/$id.ttf" ] || continue
    sz=$(wc -c < "$LIB/$id.ttf" 2>/dev/null | tr -d ' \t\r\n')
    case "$sz" in ''|*[!0-9]*) continue ;; esac
    for f in $(builtin_files); do
      [ -f "$f" ] || continue
      bsz=$(wc -c < "$f" 2>/dev/null | tr -d ' \t\r\n')
      [ "$bsz" = "$sz" ] || continue
      b=${f##*/}; b=${b%.*}
      id=$(builtin_id_of "$b" | cut -d'|' -f1)
      [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    done
  done
  printf '%s' ""
  return 0
}

# ---------------------------------------------------------------------------
# 兜底：恢复上次选择**失败**时，自动挑一套可用配色（绝不让模块静默空转）
#
# 为什么必须有它（2026-10-14，真机踩到）：
#   覆盖安装时 customize.sh 会用 `fontctl.sh apply "$LAST"` 恢复上次的配色。
#   老代码一旦这步失败，只把 pending_font 写成 none 就结束 —— 结果是：
#   **模块装上了、但什么都不替换**。用户重启看到"没生效"，
#   却不知道是恢复失败（他以为在测新包，其实这个包等于没启用）。
#
# 正确做法：恢复失败就退一步，**自动挑一套自带配色用上**，
#   并在管理器里把原因说清楚。宁可"配色不是你上次那套"，也不要"整个模块空转"。
# ---------------------------------------------------------------------------
builtin_apply_first() {
  local f b info id nm out
  # ★ 先试着"认出用户上次用的是哪一套"，认出来就直接用那一套（而不是排序第一的）。
  #   调用方会把"上次的原始记录"放在 BUILTIN_PREV（因为此时 $1 已经是失败的那个 id）。
  #   必须在 builtin_clean_legacy **之前**调用本函数 —— 那个函数可能已经把旧文件清掉了。
  if [ -n "${BUILTIN_PREV:-}" ]; then
    _mapped=$(builtin_map_from_prev "$BUILTIN_PREV")
    if [ -n "$_mapped" ] && [ -f "$LIB/$_mapped.ttf" ]; then
      out=$(sh "$MODDIR/fontctl.sh" apply "$_mapped" 2>&1 | tail -n1)
      case "$out" in
        OK:*)
          printf '%s' "$_mapped" > "$MODDIR/pending_font" 2>/dev/null
          nm=$(builtin_id_of "$(printf '%s' "$_mapped" | sed 's/^builtin_//')" | cut -d'|' -f2)
          ui_print "  ✓ 认出你上次用的就是这一套：$nm（$(echo "$out" | cut -d: -f3) 个槽位）"
          BUILTIN_MAPPED=1
          return 0
          ;;
      esac
    fi
  fi
  # 认不出来 → 退回"挑第一套能用的"（保证模块不空转）
  for f in $(builtin_files); do
    [ -f "$f" ] || continue
    b=${f##*/}; b=${b%.*}
    info=$(builtin_id_of "$b")
    id=${info%%|*}; nm=${info#*|}
    [ -n "$id" ] || continue
    [ -f "$LIB/$id.ttf" ] || continue          # 字体库里没有这份 → 换下一个
    out=$(sh "$MODDIR/fontctl.sh" apply "$id" 2>&1 | tail -n1)
    case "$out" in
      OK:*)
        printf '%s' "$id" > "$MODDIR/pending_font" 2>/dev/null
        ui_print "  ✓ 已自动改用「$nm」（$(echo "$out" | cut -d: -f3) 个槽位）"
        return 0
        ;;
    esac
  done
  # ⚠️ 一次都没进循环时 $out 从未赋值 → 老写法会打印「自动兜底也失败了：」后面空白，
  #    看不出到底是"没有候选"还是"apply 失败"（真机上"恢复失败：（空）"就是这么来的）。
  if [ -z "$out" ]; then
    ui_print "  ✗ 自动兜底失败：没有可用候选（模块 builtin/ 里没有字体，或字体库里一份都没有）"
    ui_print "     字体库现有：$(ls "$LIB"/builtin_*.ttf 2>/dev/null | wc -l | tr -d ' ') 份；模块自带：$(builtin_count) 份"
    return 1
  fi
  ui_print "  ✗ 自动兜底也失败了：${out#ERROR:}"
  return 1
}

# ---------------------------------------------------------------------------
# 兄弟模块互斥：4 个包（三合一 + 3 个单色）是各自独立的 id，同时装两个会互相抢字体。
# 安装时扫 /data/adb/modules/porsche_font_*，把**不是自己**的那些标记为"下次重启卸载"
# （写 remove 标记是管理器的标准做法，比直接删目录安全）。
# 这样用户直接刷另一个配色包就能无痛切换，不会剩两个字体模块打架。
# ---------------------------------------------------------------------------
builtin_sibling_cleanup() {
  local me="${1:-$MODDIR}" d name found=""
  me=${me##*/}
  for d in /data/adb/modules/porsche_font_*; do
    [ -d "$d" ] || continue
    name=${d##*/}
    [ "$name" = "$me" ] && continue
    [ -f "$d/disable" ] && continue
    : > "$d/remove" 2>/dev/null && found="$found $name"
  done
  if [ -n "$found" ]; then
    ui_print " "
    ui_print "- 检测到其它保时捷字体模块：$found"
    ui_print "- 已标记为重启后卸载（同一时间只保留一个配色包）"
  fi
  return 0
}
