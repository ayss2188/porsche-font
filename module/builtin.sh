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

# 本模块自带的字体有几个（决定要不要弹选择菜单）
builtin_count() {
  local bdir="$MODDIR/builtin" f n=0
  [ -d "$bdir" ] || { echo 0; return; }
  for f in "$bdir"/*.ttf "$bdir"/*.TTF "$bdir"/*.otf "$bdir"/*.OTF; do
    [ -f "$f" ] && n=$((n + 1))
  done
  echo "$n"
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
# 刷入时选配色（沿用老模块的体验：音量[下]切换、音量[上]确定）
# 只写 pending_font —— 主模块开机会自动把它挂上并转成 active_font，所以"刷完重启即生效"。
# 覆盖安装时**不动**用户已有的选择。
# ---------------------------------------------------------------------------
builtin_menu() {
  local n sel=1 keyInfo isUp name id list="" i=0
  n=$(builtin_count)
  [ "$n" -gt 0 ] 2>/dev/null || return 0

  # 覆盖安装（已经有选择）就别再弹菜单，尊重用户原来的选择
  case "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")" in
    ''|none) : ;;
    *) return 0 ;;
  esac

  # 只有一个字体（单色版）：自动选中，不打扰用户
  if [ "$n" = 1 ]; then
    for f in "$MODDIR/builtin"/*.ttf; do
      [ -f "$f" ] || continue
      b=${f##*/}; b=${b%.*}                      # 去掉 .ttf 再识别，否则匹配不上
      info=$(builtin_id_of "$b")
      printf '%s' "${info%%|*}" > "$MODDIR/pending_font"
      printf 'none' > "$MODDIR/active_font"
      ui_print "- 内置配色：${info#*|}"
      break
    done
    return 0
  fi

  # 三合一：列出所有配色
  for f in "$MODDIR/builtin"/*.ttf; do
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
  # 按序号找回对应的文件名（顺序与 builtin/ 的 glob 顺序一致）
  i=0
  for ff in "$MODDIR/builtin"/*.ttf; do
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
