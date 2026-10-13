#!/system/bin/sh
# fontcheck.sh —— 字体文件有效性校验（**独立文件，谁先 source 谁就有**）
#
# 为什么单独拆出来（这不是洁癖，是个真踩过的坑）：
#   valid_font 原来定义在 fontctl.sh 里。而 customize.sh 的 source 顺序是
#     common.sh → builtin.sh → … → fontctl.sh
#   builtin.sh 里的 builtin_import 要调 valid_font —— 那时它**还不存在**，
#   写成 `command -v valid_font >/dev/null && valid_font "$f"` 的话，
#   判断为假 → **校验被静默跳过**，等于没修。
#   所以把它抽成独立文件，在所有用到它的地方（builtin.sh / fontctl.sh / customize.sh）
#   之前就载入。规则：**校验工具不能依赖加载顺序。**
#
# 判据（和原来完全一致，没有放宽）：
#   · 魔数必须是 00010000 / OTTO / true
#   · 表数量合理（5~512）、表目录长度落在文件内
#   · 每条表的 偏移+长度 都落在文件内（截断文件必然过不了）
#   · 必需表齐全：cmap / head / hhea / hmtx / maxp
#   · 轮廓数据：glyf 或 CFF 至少有一个（两个都没有 = 空壳）

# 只接受 TTF / OTF（TTC 合集不能直接替换单文件槽位）
# ⚠ 光看魔数不够：**截断/损坏的文件魔数也是对的**，而把坏字体挂到系统字体槽上，
#   轻则文字显示异常，重则开机后系统字体加载失败（真机反馈过"卡开机后黑屏"）。
#   所以这里把表目录也验一遍：
#     · 表数量合理、目录长度落在文件内
#     · 每条表的 偏移+长度 都落在文件内（截断文件必然过不了这一关）
#     · 必需的几张表都在（cmap/head/hhea/hmtx/maxp + glyf/loca 或 CFF）
valid_font() {
  local f="$1" m sz b num tot bytes v c tag off ln
  local has_cmap=0 has_head=0 has_hhea=0 has_hmtx=0 has_maxp=0 has_glyf=0 has_cff=0
  [ -f "$f" ] || return 1
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  case "$sz" in ''|*[!0-9]*) return 1 ;; esac
  [ "$sz" -ge 512 ] 2>/dev/null || return 1
  m=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$m" in
    00010000|4f54544f|74727565) ;;
    *) return 1 ;;
  esac
  b=$(od -An -tu1 -j4 -N2 "$f" 2>/dev/null); set -- $b
  [ $# -ge 2 ] || return 1
  num=$(( $1 * 256 + $2 ))
  [ "$num" -ge 5 ] 2>/dev/null || return 1
  [ "$num" -le 512 ] 2>/dev/null || return 1
  tot=$(( 12 + 16 * num ))
  [ "$tot" -le "$sz" ] 2>/dev/null || return 1
  bytes=$(od -An -tu1 -j0 -N"$tot" "$f" 2>/dev/null | tr -s ' \n' ' ')
  set -- $bytes
  [ $# -ge "$tot" ] || return 1
  v=0; while [ "$v" -lt 12 ]; do shift; v=$((v+1)); done
  v=0
  while [ "$v" -lt "$num" ]; do
    [ $# -ge 16 ] || return 1
    tag=""
    # 只认要用的那几张表，省掉字符串比较
    [ "$1" = 99 ]  && [ "$2" = 109 ] && [ "$3" = 97 ]  && [ "$4" = 112 ] && tag=cmap
    [ "$1" = 104 ] && [ "$2" = 101 ] && [ "$3" = 97 ]  && [ "$4" = 100 ] && tag=head
    [ "$1" = 104 ] && [ "$2" = 104 ] && [ "$3" = 101 ] && [ "$4" = 97 ]  && tag=hhea
    [ "$1" = 104 ] && [ "$2" = 109 ] && [ "$3" = 116 ] && [ "$4" = 120 ] && tag=hmtx
    [ "$1" = 109 ] && [ "$2" = 97 ]  && [ "$3" = 120 ] && [ "$4" = 112 ] && tag=maxp
    [ "$1" = 103 ] && [ "$2" = 108 ] && [ "$3" = 121 ] && [ "$4" = 102 ] && tag=glyf
    [ "$1" = 67 ]  && [ "$2" = 70 ]  && [ "$3" = 70 ]  && [ "$4" = 32 ]  && tag=cff
    shift 8
    off=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); shift 4
    ln=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); shift 4
    # 截断文件在这里必然露馅
    [ $(( off + ln )) -le "$sz" ] 2>/dev/null || return 1
    case "$tag" in
      cmap) has_cmap=1 ;; head) has_head=1 ;; hhea) has_hhea=1 ;;
      hmtx) has_hmtx=1 ;; maxp) has_maxp=1 ;; glyf) has_glyf=1 ;; cff) has_cff=1 ;;
    esac
    v=$((v+1))
  done
  [ "$has_cmap" = 1 ] && [ "$has_head" = 1 ] && [ "$has_hhea" = 1 ] && \
  [ "$has_hmtx" = 1 ] && [ "$has_maxp" = 1 ] || return 1
  # 轮廓数据：TrueType 用 glyf，OpenType/CFF 用 CFF —— 两个都没有就是空壳
  [ "$has_glyf" = 1 ] || [ "$has_cff" = 1 ] || return 1
  return 0
}
