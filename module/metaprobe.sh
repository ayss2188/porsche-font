#!/bin/sh
# metaprobe.sh —— 刷入时就把"能不能合成 / 会不会跟着变粗"需要的字段写进 .meta
#
# 为什么要有这个：
#   合成面板需要知道每份字体的轮廓类型（glyf/CFF2/CFF）、是不是可变字体、
#   字重轴范围、轴标签。这些以前是**打开界面时**由网页端探测的 —— 慢，而且
#   档案不全时界面会误判。现在改成**刷入时**在 shell 里一次写好，界面直接读。
#
# 写入的字段（只增改这几个，不动 .meta 里其它内容）：
#   outline_type=glyf|cff2|cff|?
#   vf=0|1
#   wgmin= wgdef= wgmax=      （仅可变字体，取 fvar 里 wght 轴）
#   axistags=wght wdth ...
#   ttc=1                     （仅当是 TTC 合集）
#
# 用法：
#   sh metaprobe.sh           # 全部字体
#   sh metaprobe.sh f123      # 单个
# 环境：CFS_FDATA_LIB 可指定目录（自检用，不影响真机）

LIBX="${CFS_FDATA_LIB:-${LIB:-/data/adb/custom_font_lib}}"

_fb() {   # _fb <file> <off> <len> → 十进制字节串
  od -An -tu1 -j "$2" -N "$3" "$1" 2>/dev/null | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'
}
_u16() {
  local _s="$1" _idx="$2"
  case "$_idx" in ''|*[!0-9]*) return 1 ;; esac
  set -- $_s
  shift $(( _idx * 2 )) 2>/dev/null || return 1
  [ -n "$1" ] && [ -n "$2" ] || return 1
  echo $(( $1 * 256 + $2 ))
}
_u32() {
  local _s="$1" _idx="$2"
  case "$_idx" in ''|*[!0-9]*) return 1 ;; esac
  set -- $_s
  shift $(( _idx * 4 )) 2>/dev/null || return 1
  [ -n "$1" ] && [ -n "$4" ] || return 1
  echo $(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
}
_tag() {
  local b
  b=$(_fb "$1" "$2" 4)
  set -- $b
  [ $# -ge 4 ] || { printf '?'; return; }
  printf '%s%s%s%s' \
    "$(printf "\\$(printf "%03o" "$1")")" \
    "$(printf "\\$(printf "%03o" "$2")")" \
    "$(printf "\\$(printf "%03o" "$3")")" \
    "$(printf "\\$(printf "%03o" "$4")")"
}

# 把 key=value 写进 meta（先删同名的旧行，再追加）
_put() {   # _put <metafile> <key> <value>
  local mf="$1" k="$2" v="$3" tmp="${1}.tmp.$$"
  [ -f "$mf" ] || : > "$mf"
  grep -v "^${k}=" "$mf" > "$tmp" 2>/dev/null
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv -f "$tmp" "$mf" 2>/dev/null || rm -f "$tmp"
}

probe_one() {   # probe_one <id>
  local id="$1" f="$LIBX/$1.ttf" mf="$LIBX/$1.meta"
  [ -f "$f" ] || return 1

  # TTC 合集（魔数 "ttcf"）
  if [ "$(_tag "$f" 0)" = "ttcf" ]; then
    _put "$mf" ttc 1
    _put "$mf" outline_type "?"
    return 0
  fi

  local num ob
  num=$(_u16 "$(_fb "$f" 4 2)" 0)
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  [ "$num" -ge 1 ] && [ "$num" -le 512 ] || return 1

  local i tag
  local p_glyf="" p_cff="" p_cff2="" p_fvar=""
  i=0
  while [ "$i" -lt "$num" ]; do
    tag=$(_tag "$f" $(( 12 + i * 16 )))
    ob=$(_fb "$f" $(( 12 + i * 16 + 8 )) 4)
    local off
    off=$(_u32 "$ob" 0)
    case "$tag" in
      glyf) p_glyf="$off" ;;
      "CFF ") p_cff="$off" ;;
      CFF2) p_cff2="$off" ;;
      fvar) p_fvar="$off" ;;
    esac
    i=$(( i + 1 ))
  done

  # 轮廓类型
  local ot="?"
  [ -n "$p_glyf" ] && ot="glyf"
  [ -z "$p_glyf" ] && [ -n "$p_cff2" ] && ot="cff2"
  [ -z "$p_glyf" ] && [ -z "$p_cff2" ] && [ -n "$p_cff" ] && ot="cff"
  _put "$mf" outline_type "$ot"

  # 可变字体
  if [ -z "$p_fvar" ]; then
    _put "$mf" vf 0
    _put "$mf" axistags ""
    return 0
  fi
  _put "$mf" vf 1

  # fvar 头：version(4) axesArrayOffset(2) reserved(2) axisCount(2) axisSize(2)
  local hdr axesoff axiscount axissize
  hdr=$(_fb "$f" "$p_fvar" 16)
  axesoff=$(_u16 "$hdr" 2)
  axiscount=$(_u16 "$hdr" 4)
  axissize=$(_u16 "$hdr" 5)
  case "$axiscount" in ''|*[!0-9]*) axiscount=0 ;; esac
  case "$axissize" in ''|*[!0-9]*) axissize=0 ;; esac
  case "$axesoff" in ''|*[!0-9]*) axesoff=16 ;; esac
  [ "$axiscount" -ge 1 ] && [ "$axiscount" -le 32 ] || axiscount=0
  [ "$axissize" -ge 20 ] || axissize=20

  local tags="" j p t
  j=0
  while [ "$j" -lt "$axiscount" ]; do
    p=$(( p_fvar + axesoff + j * axissize ))
    t=$(_tag "$f" "$p")
    tags="$tags${tags:+ }$t"
    if [ "$t" = "wght" ]; then
      # min/default/max 是 Fixed(16.16)：取高 16 位整数部分
      local b4
      b4=$(_fb "$f" $(( p + 4 )) 4);  _put "$mf" wgmin "$(_u16 "$b4" 0)"
      b4=$(_fb "$f" $(( p + 8 )) 4);  _put "$mf" wgdef "$(_u16 "$b4" 0)"
      b4=$(_fb "$f" $(( p + 12 )) 4); _put "$mf" wgmax "$(_u16 "$b4" 0)"
    fi
    j=$(( j + 1 ))
  done
  _put "$mf" axistags "$tags"
  return 0
}

probe_all() {
  local n=0 ok=0 f id
  for f in "$LIBX"/f*.ttf; do
    [ -e "$f" ] || continue
    id=${f##*/}; id=${id%.ttf}
    case "$id" in f*) ;; *) continue ;; esac
    n=$(( n + 1 ))
    probe_one "$id" && ok=$(( ok + 1 ))
  done
  [ "$n" -gt 0 ] && echo "  metaprobe: $ok/$n"
  return 0
}

case "$1" in
  "") probe_all ;;
  *) probe_one "$1" && echo "OK" ;;
esac
