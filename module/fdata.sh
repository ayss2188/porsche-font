#!/system/bin/sh
# ===========================================================================
# 字体档案（.fdata）：记录每份字体的结构清单，供诊断报告判断
#   "到底是字体本身缺东西，还是模块处理错了"
#
#   为什么用 shell 而不是界面来做：刷模块的那一刻就应该把档案建好，
#   用户打开界面时报告里就有内容了，不需要先点一次什么。
#
#   只读字体头部（表目录 + 几张小的度量表），不读 glyf/CFF 本体，
#   42MB 的字体也是秒级。
# ===========================================================================
MODDIR=${0%/*}
. "$MODDIR/common.sh" 2>/dev/null

# 测试用：CFS_FDATA_LIB 可指定目录（不影响真机）
FIN_LIB="${CFS_FDATA_LIB:-${LIB:-/data/adb/custom_font_lib}}"

# 读 1 字节无符号（跳 offset）→ 打印十进制
_fb() {   # _fb <file> <off> <len>
  od -An -tu1 -j "$2" -N "$3" "$1" 2>/dev/null | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'
}
_u16() {  # _u16 "<字节串>" <下标>  → 第 idx 个 u16（0 起）
  local _s="$1" _idx="$2"
  case "$_idx" in ''|*[!0-9]*) return 1 ;; esac
  set -- $_s
  shift $(( _idx * 2 )) 2>/dev/null || return 1
  [ -n "$1" ] && [ -n "$2" ] || return 1
  echo $(( $1 * 256 + $2 ))
}
_tag() {  # _tag <file> <off> → 4 字符标签
  local b
  b=$(_fb "$1" "$2" 4)
  set -- $b
  [ $# -ge 4 ] || { printf '?'; return; }
  printf '%s' "$(printf "\\$(printf '%03o' "$1")\\$(printf '%03o' "$2")")$(printf "\\$(printf '%03o' "$3")\\$(printf '%03o' "$4")")"
}

fdata_of() {   # fdata_of <id>
  local id="$1" f="$FIN_LIB/$1.ttf" out="$FIN_LIB/$1.fdata"
  [ -f "$f" ] || return 1
  local num i off len tag
  num=$(_u16 "$(_fb "$f" 4 2)" 0)
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  [ "$num" -ge 1 ] && [ "$num" -le 512 ] || return 1

  local list="" outline="?" glyf=0 cff=0 cff2=0
  local t_head=0 t_hhea=0 t_maxp=0 t_os2=0 t_cmap=0 t_name=0
  local layout="" vert="" hint="" var="" color="" nlayout=0
  i=0
  while [ "$i" -lt "$num" ]; do
    tag=$(_tag "$f" $(( 12 + i * 16 )))
    # offset/length 是 4 字节大端
    local ob lb o l k
    ob=$(_fb "$f" $(( 12 + i * 16 + 8 )) 4); set -- $ob
    [ $# -ge 4 ] || break
    o=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
    lb=$(_fb "$f" $(( 12 + i * 16 + 12 )) 4); set -- $lb
    [ $# -ge 4 ] || break
    l=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
    list="$list $tag($l)"
    case "$tag" in
      head) t_head=$o ;; hhea) t_hhea=$o ;; maxp) t_maxp=$o ;;
      "OS/2") t_os2=$o ;; cmap) t_cmap=$o ;; name) t_name=$o ;;
      glyf) glyf=1 ;; "CFF ") cff=1 ;; CFF2) cff2=1 ;;
      GSUB|GPOS|GDEF|BASE|MATH) layout="$layout$tag," ;;
      vhea|vmtx|VORG) vert="$vert$tag," ;;
      hdmx|LTSH|VDMX|"cvt "|fpgm|prep|gasp) hint="$hint$tag," ;;
      fvar|gvar|HVAR|VVAR|MVAR|avar|STAT) var="$var$tag," ;;
      COLR|CPAL|CBDT|CBLC|sbix|"SVG ") color="$color$tag," ;;
    esac
    i=$(( i + 1 ))
  done

  [ "$glyf" = 1 ] && outline="glyf"
  [ "$cff" = 1 ] && outline="cff"
  [ "$cff2" = 1 ] && outline="cff2"

  local nglyph="?" upem="?" macstyle="?" locfmt="?"
  if [ "$t_maxp" != 0 ]; then
    nglyph=$(_u16 "$(_fb "$f" $(( t_maxp + 4 )) 2)" 0)
  fi
  if [ "$t_head" != 0 ]; then
    upem=$(_u16 "$(_fb "$f" $(( t_head + 18 )) 2)" 0)
    macstyle=$(_u16 "$(_fb "$f" $(( t_head + 44 )) 2)" 0)
    locfmt=$(_u16 "$(_fb "$f" $(( t_head + 50 )) 2)" 0)
  fi
  local weight="?" nhmetrics="?"
  if [ "$t_os2" != 0 ]; then
    weight=$(_u16 "$(_fb "$f" $(( t_os2 + 4 )) 2)" 0)
  fi
  if [ "$t_hhea" != 0 ]; then
    nhmetrics=$(_u16 "$(_fb "$f" $(( t_hhea + 34 )) 2)" 0)
  fi

  # cmap 子表（平台/编码/格式）
  local subs="" nsub=0 sfmt="" pid eid soff
  if [ "$t_cmap" != 0 ]; then
    nsub=$(_u16 "$(_fb "$f" $(( t_cmap + 2 )) 2)" 0)
    case "$nsub" in ''|*[!0-9]*) nsub=0 ;; esac
    [ "$nsub" -gt 12 ] && nsub=12
    i=0
    while [ "$i" -lt "$nsub" ]; do
      pid=$(_u16 "$(_fb "$f" $(( t_cmap + 4 + i * 8 )) 2)" 0)
      eid=$(_u16 "$(_fb "$f" $(( t_cmap + 6 + i * 8 )) 2)" 0)
      local sb; sb=$(_fb "$f" $(( t_cmap + 8 + i * 8 )) 4); set -- $sb
      if [ $# -ge 4 ]; then
        soff=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
        sfmt=$(_u16 "$(_fb "$f" $(( t_cmap + soff )) 2)" 0)
        subs="$subs $pid/$eid:fmt$sfmt"
      fi
      i=$(( i + 1 ))
    done
  fi

  {
    echo "tables=$num"
    echo "table_list=${list# }"
    echo "outline=$outline"
    echo "numGlyphs=$nglyph"
    echo "upem=$upem"
    echo "head_macStyle=$macstyle locFmt=$locfmt"
    echo "os2_weight=$weight nHMetrics=$nhmetrics"
    echo "cmap_subtables=${subs# }"
    echo "layout=${layout%,}"
    [ -z "$layout" ] && echo "layout=none"
    echo "vertical=${vert%,}"
    [ -z "$vert" ] && echo "vertical=none"
    echo "hint_tables=${hint%,}"
    [ -z "$hint" ] && echo "hint_tables=none"
    echo "variable=${var%,}"
    [ -z "$var" ] && echo "variable=none"
    echo "color=${color%,}"
    [ -z "$color" ] && echo "color=none"
    echo "source=shell"
  } > "$out" 2>/dev/null
  [ -s "$out" ] || { rm -f "$out"; return 1; }
  return 0
}

fdata_all() {
  local n=0 ok=0 f id
  for f in "$FIN_LIB"/f*.ttf; do
    [ -e "$f" ] || continue
    id=${f##*/}; id=${id%.ttf}
    [ -f "$FIN_LIB/$id.fdata" ] && continue
    n=$(( n + 1 ))
    fdata_of "$id" && ok=$(( ok + 1 ))
  done
  [ "$n" -gt 0 ] && echo "  fdata: $ok/$n"
  return 0
}

# 直接执行（customize.sh / 手动）时只有一句：补全部
case "$1" in
  "") fdata_all ;;
  *) fdata_of "$1" && echo "OK" ;;
esac
