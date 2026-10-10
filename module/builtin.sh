#!/system/bin/sh
# builtin.sh —— 内置字体注入 + 刷入时选配色（内置字体模块专用）
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
# 注入：把 builtin/*.ttf 硬链接成字体库里的字体
# ---------------------------------------------------------------------------
builtin_import() {
  local bdir="$MODDIR/builtin" f n info id nm dst ok=0
  [ -d "$bdir" ] || return 0
  mkdir -p "$LIB" 2>/dev/null

  for f in "$bdir"/*.ttf "$bdir"/*.TTF "$bdir"/*.otf "$bdir"/*.OTF; do
    [ -f "$f" ] || continue
    n=${f##*/}; n=${n%.*}
    info=$(builtin_id_of "$n")
    id=${info%%|*}; nm=${info#*|}
    [ -n "$id" ] || continue
    dst="$LIB/$id.ttf"

    # 已经是指向同一份文件的硬链接就跳过（覆盖安装/重复安装时省事）
    if [ -f "$dst" ] && [ "$(stat -c %i "$dst" 2>/dev/null)" = "$(stat -c %i "$f" 2>/dev/null)" ]; then
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
    printf 'scope=all\nlatin=1\ncjk=1\n' > "$LIB/$id.meta" 2>/dev/null
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
  case "$(tr -d '[:space:]' 2>/dev/null < "$OLD/pending_font")" in
    ''|none) : ;;
    *) return 0 ;;
  esac

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
