#!/system/bin/sh
# ttcwrap.sh - 把单文件字体（.ttf/.otf）包成"多 face 的 TTC 合集"
#
# 用途：三星/部分机型的简中字体来自 .ttc 合集（如 SECCJK-Regular.ttc，配置里写 index="2"），
#       单文件字体没法直接顶替它。这个脚本把用户的字体复制成 N 份 face（共用同一份字形数据），
#       于是 index 0..N-1 全都是用户的字体 —— 系统配置里的 index 依然有效，不用改任何配置。
#
# 原理（TTC 结构）：
#   'ttcf' + 主版本(2) + 次版本(2) + face数(4) + [每个 face 的目录偏移(4)] × N
#   + N 份"sfnt 表目录" + 表数据
#   所有 face 共用同一份表数据：把源文件表目录里每个表的 offset 整体后移 H（H = 头部+目录总长），
#   再把源文件原样接在后面，偏移就正好指对位置。多个 face 指向同一份数据是 TTC 允许的。
#
# 用法：
#   sh ttcwrap.sh <源字体> <face数> <输出.ttc>     命令行（测试用）
#   ttc_wrap <源字体> <face数> <输出.ttc>           source 之后调用
# 成功返回 0，并保证输出文件以 ttcf 开头、后续 face 目录完整。

# 4 字节大端 -> printf 的八进制转义
_be4() {
  _b=$1
  printf '\\%03o\\%03o\\%03o\\%03o' \
    $(( (_b >> 24) & 255 )) $(( (_b >> 16) & 255 )) $(( (_b >> 8) & 255 )) $(( _b & 255 ))
}

isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

ttc_wrap() {
  _tw_src="$1"; _tw_faces="$2"; _tw_out="$3"
  [ -f "$_tw_src" ] || return 1
  isnum "$_tw_faces" || return 1
  [ "$_tw_faces" -ge 1 ] 2>/dev/null || return 1
  [ "$_tw_faces" -le 64 ] 2>/dev/null || return 1

  # 源文件头 6 字节 = sfntVersion(4) + numTables(2, 大端)
  _tw_b=$(od -An -tu1 -N6 "$_tw_src" 2>/dev/null)
  set -- $_tw_b
  [ $# -ge 6 ] || return 1
  _tw_num=$(( $5 * 256 + $6 ))              # numTables：偏移 4 起两个字节
  [ "$_tw_num" -ge 1 ] && [ "$_tw_num" -le 512 ] || return 1

  _tw_dir=$(( 12 + 16 * _tw_num ))                                  # 一个 face 的目录长度
  _tw_H=$(( 12 + 4 * _tw_faces + _tw_faces * _tw_dir ))             # 表数据整体后移这么多

  _tw_tmp="${TMPDIR:-/data/local/tmp}/.ttcw.$$"
  # 先搬 sfnt 目录头（12 字节：版本、表数量、searchRange 等）—— 少了它整个 TTC 都不合法
  dd if="$_tw_src" bs=1 count=12 2>/dev/null > "$_tw_tmp.dir" || { rm -f "$_tw_tmp.dir"; return 1; }

  # 逐条表记录：tag+checksum 原样搬，offset 加 H，length 原样搬
  _tw_i=0
  while [ "$_tw_i" -lt "$_tw_num" ]; do
    _tw_at=$(( 12 + _tw_i * 16 ))
    dd if="$_tw_src" bs=1 skip="$_tw_at" count=8 2>/dev/null >> "$_tw_tmp.dir"
    _tw_o=$(od -An -tu1 -j$(( _tw_at + 8 )) -N4 "$_tw_src" 2>/dev/null)
    set -- $_tw_o
    if [ $# -lt 4 ]; then rm -f "$_tw_tmp.dir"; return 1; fi
    _tw_old=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
    printf "$(_be4 $(( _tw_old + _tw_H )))" >> "$_tw_tmp.dir"
    dd if="$_tw_src" bs=1 skip=$(( _tw_at + 12 )) count=4 2>/dev/null >> "$_tw_tmp.dir"
    _tw_i=$(( _tw_i + 1 ))
  done

  # 校验刚才那份目录长度对不对（12 字节头 + 每条记录 16 字节）
  _tw_got=$(wc -c < "$_tw_tmp.dir" 2>/dev/null | tr -d ' ')
  if [ "$_tw_got" != "$(( 12 + 16 * _tw_num ))" ]; then
    rm -f "$_tw_tmp.dir"
    return 1
  fi

  # 组装：TTC 头 + N 份目录 + 源文件整体
  {
    printf 'ttcf'
    printf '\000\001\000\000'                       # 版本 1.0
    printf "$(_be4 "$_tw_faces")"
    _tw_i=0
    while [ "$_tw_i" -lt "$_tw_faces" ]; do
      printf "$(_be4 $(( 12 + 4 * _tw_faces + _tw_i * _tw_dir )))"
      _tw_i=$(( _tw_i + 1 ))
    done
  } > "$_tw_out" 2>/dev/null || { rm -f "$_tw_tmp.dir"; return 1; }

  _tw_i=0
  while [ "$_tw_i" -lt "$_tw_faces" ]; do
    cat "$_tw_tmp.dir" >> "$_tw_out" 2>/dev/null
    _tw_i=$(( _tw_i + 1 ))
  done
  cat "$_tw_src" >> "$_tw_out" 2>/dev/null
  rm -f "$_tw_tmp.dir" 2>/dev/null

  # 收尾自检：文件得比源文件大，且以 ttcf 开头
  _tw_sz=$(wc -c < "$_tw_out" 2>/dev/null | tr -d ' ')
  _tw_srcsz=$(wc -c < "$_tw_src" 2>/dev/null | tr -d ' ')
  isnum "$_tw_sz" || return 1
  [ "$_tw_sz" -gt "$_tw_srcsz" ] || return 1
  [ "$(head -c 4 "$_tw_out" 2>/dev/null)" = ttcf ] || return 1
  return 0
}

# 读一个 .ttc 有多少个 face（不是 ttc 返回 0）
ttc_faces_of() {
  [ -f "$1" ] || { echo 0; return; }
  [ "$(head -c 4 "$1" 2>/dev/null)" = ttcf ] || { echo 0; return; }
  _tf=$(od -An -tu1 -j8 -N4 "$1" 2>/dev/null)
  set -- $_tf
  [ $# -ge 4 ] || { echo 0; return; }
  echo $(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
}

# 0..255 的一个字节 -> printf 的八进制转义，写进 _OCT（纯 shell 算术，不起进程）
_oct3() {
  _OCT="\\$(( $1 / 64 ))$(( ($1 / 8) % 8 ))$(( $1 % 8 ))"
}

# 读一个 .ttc 里第 i 号 face 的表目录偏移（大端 4 字节）
_ttc_face_off() {
  _TFO=$(od -An -tu1 -j$(( 12 + 4 * $2 )) -N4 "$1" 2>/dev/null)
  set -- $_TFO
  [ $# -ge 4 ] || { echo -1; return; }
  echo $(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
}

# ---------------------------------------------------------------------------
# 混合合集：**只把中文那几号 face 换成用户字体**，其它 face 保留原合集的字形数据。
#
#   ttc_wrap_mix <用户字体> <face数> <输出> <原合集> <要替换的序号，如 "2 3">
#
# 为什么需要它：三星的合集里 0=日文 1=韩文 2=简中 3=繁中（真机实测）。
# 把整份合集都换成用户的字体，等于日文/韩文也换掉了 —— 用户的字体没有假名/谚文字形就出方块。
# 只换中文那几号，日韩保留原字形，才不会互相牵连。
#
# 结构：TTC 头 + N 份"face 目录"，然后依次接上【用户字体整个文件】【原合集整个文件】。
#   · 要换的 face：用用户字体的表目录，表里的偏移 + base_u（= 用户字体数据的起点）
#   · 保留的 face：用原合集里那一号 face 的表目录，偏移 + base_o（= 原合集数据的起点）
# 每个 face 的表目录长度可以不同（表数量不同），所以头部长度按各 face 实际长度累加。
# 全部 face 都要换时自动退回 ttc_wrap（不用白带一份原合集数据）。
# ---------------------------------------------------------------------------
ttc_wrap_mix() {
  local _tm_src="$1" _tm_faces="$2" _tm_out="$3" _tm_orig="$4" _tm_cn="$5"
  local _tm_i _tm_u _tm_n _tm_b _tm_H _tm_off _tm_cnt _tm_len _tm_esc _tm_bytes _tm_v
  local _tm_dirsz _tm_esc_u _tm_esc_o _tm_keep

  [ -f "$_tm_src" ] && [ -f "$_tm_orig" ] || return 1
  isnum "$_tm_faces" || return 1
  [ "$_tm_faces" -ge 1 ] 2>/dev/null || return 1
  [ "$_tm_faces" -le 64 ] 2>/dev/null || return 1
  [ "$(head -c 4 "$_tm_orig" 2>/dev/null)" = ttcf ] || return 1
  [ "$(ttc_faces_of "$_tm_orig")" = "$_tm_faces" ] || return 1

  # ---- 用户字体的表目录（读一次，所有"要换的 face"共用）----
  _tm_b=$(od -An -tu1 -N6 "$_tm_src" 2>/dev/null)
  set -- $_tm_b
  [ $# -ge 6 ] || return 1
  _tm_u=$(( $5 * 256 + $6 ))                      # numTables
  [ "$_tm_u" -ge 1 ] && [ "$_tm_u" -le 512 ] || return 1
  _tm_dirsz=$(( 12 + 16 * _tm_u ))

  # 要换几号 face：做成 " 2 3 " 这种可匹配的串
  _tm_cn=" $(printf '%s' "$_tm_cn" | tr -s ' ') "
  _tm_keep=0
  _tm_i=0
  while [ "$_tm_i" -lt "$_tm_faces" ]; do
    case "$_tm_cn" in *" $_tm_i "*) ;; *) _tm_keep=$((_tm_keep+1)) ;; esac
    _tm_i=$((_tm_i+1))
  done
  # 一个都不用保留 -> 交给普通版（不带原合集数据，省一半空间）
  [ "$_tm_keep" = 0 ] && { ttc_wrap "$_tm_src" "$_tm_faces" "$_tm_out"; return $?; }

  # ---- 头部长度 H = 12 + 4*N + 各 face 目录长度之和 ----
  _tm_H=$(( 12 + 4 * _tm_faces ))
  _tm_i=0
  while [ "$_tm_i" -lt "$_tm_faces" ]; do
    case "$_tm_cn" in
      *" $_tm_i "*) _tm_H=$(( _tm_H + _tm_dirsz )) ;;
      *)
        _tm_off=$(_ttc_face_off "$_tm_orig" "$_tm_i")
        [ "$_tm_off" -ge 12 ] 2>/dev/null || return 1
        _tm_n=$(od -An -tu1 -j$(( _tm_off + 4 )) -N2 "$_tm_orig" 2>/dev/null)
        set -- $_tm_n
        [ $# -ge 2 ] || return 1
        _tm_n=$(( $1 * 256 + $2 ))
        [ "$_tm_n" -ge 1 ] && [ "$_tm_n" -le 512 ] || return 1
        _tm_H=$(( _tm_H + 12 + 16 * _tm_n ))
        ;;
    esac
    _tm_i=$((_tm_i+1))
  done

  # base_u = 用户字体数据起点，base_o = 原合集数据起点（都接在 face 目录后面）
  _tm_v=$(wc -c < "$_tm_src" 2>/dev/null | tr -d ' ')
  isnum "$_tm_v" || return 1
  local _tm_bu="$_tm_H"
  local _tm_bo=$(( _tm_H + _tm_v ))

  # ---- 写 TTC 头 ----
  {
    printf 'ttcf'
    printf '\000\001\000\000'
    printf "$(_be4 "$_tm_faces")"
    _tm_off=$(( 12 + 4 * _tm_faces ))
    _tm_i=0
    while [ "$_tm_i" -lt "$_tm_faces" ]; do
      printf "$(_be4 "$_tm_off")"
      case "$_tm_cn" in
        *" $_tm_i "*) _tm_off=$(( _tm_off + _tm_dirsz )) ;;
        *) _tm_n=$(_ttc_face_off "$_tm_orig" "$_tm_i")
           _tm_len=$(od -An -tu1 -j$(( _tm_n + 4 )) -N2 "$_tm_orig" 2>/dev/null); set -- $_tm_len
           _tm_off=$(( _tm_off + 12 + 16 * ( $1 * 256 + $2 ) )) ;;
      esac
      _tm_i=$((_tm_i+1))
    done
  } > "$_tm_out" 2>/dev/null || return 1

  # ---- 逐个 face 的目录（重定位偏移）----
  _tm_i=0
  while [ "$_tm_i" -lt "$_tm_faces" ]; do
    case "$_tm_cn" in
      *" $_tm_i "*)
        # 用户字体的目录：算一次就够（所有要换的 face 内容相同）
        if [ -z "$_tm_esc_u" ]; then
          _tm_bytes=$(dd if="$_tm_src" bs=1 count="$_tm_dirsz" 2>/dev/null | od -An -tu1 -v 2>/dev/null)
          set -- $_tm_bytes
          _tm_esc=""; _tm_cnt=0
          while [ "$_tm_cnt" -lt 12 ]; do _oct3 "$1"; _tm_esc="$_tm_esc$_OCT"; shift; _tm_cnt=$((_tm_cnt+1)); done
          _tm_cnt=0
          while [ "$_tm_cnt" -lt "$_tm_u" ]; do
            _tm_n=0; while [ "$_tm_n" -lt 8 ]; do _oct3 "$1"; _tm_esc="$_tm_esc$_OCT"; shift; _tm_n=$((_tm_n+1)); done
            _tm_v=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); shift 4
            _tm_v=$(( _tm_v + _tm_bu ))
            _oct3 $(( _tm_v / 16777216 % 256 )); _tm_esc="$_tm_esc$_OCT"
            _oct3 $(( _tm_v / 65536 % 256 ));    _tm_esc="$_tm_esc$_OCT"
            _oct3 $(( _tm_v / 256 % 256 ));      _tm_esc="$_tm_esc$_OCT"
            _oct3 $(( _tm_v % 256 ));            _tm_esc="$_tm_esc$_OCT"
            _tm_n=0; while [ "$_tm_n" -lt 4 ]; do _oct3 "$1"; _tm_esc="$_tm_esc$_OCT"; shift; _tm_n=$((_tm_n+1)); done
            _tm_cnt=$((_tm_cnt+1))
          done
          _tm_esc_u="$_tm_esc"
        fi
        printf "$_tm_esc_u" >> "$_tm_out" 2>/dev/null || return 1
        ;;
      *)
        _tm_off=$(_ttc_face_off "$_tm_orig" "$_tm_i")
        _tm_n=$(od -An -tu1 -j$(( _tm_off + 4 )) -N2 "$_tm_orig" 2>/dev/null); set -- $_tm_n
        _tm_n=$(( $1 * 256 + $2 ))
        _tm_len=$(( 12 + 16 * _tm_n ))
        _tm_bytes=$(dd if="$_tm_orig" bs=1 skip="$_tm_off" count="$_tm_len" 2>/dev/null | od -An -tu1 -v 2>/dev/null)
        set -- $_tm_bytes
        _tm_esc=""; _tm_cnt=0
        while [ "$_tm_cnt" -lt 12 ]; do _oct3 "$1"; _tm_esc="$_tm_esc$_OCT"; shift; _tm_cnt=$((_tm_cnt+1)); done
        _tm_cnt=0
        while [ "$_tm_cnt" -lt "$_tm_n" ]; do
          _tm_b=0; while [ "$_tm_b" -lt 8 ]; do _oct3 "$1"; _tm_esc="$_tm_esc$_OCT"; shift; _tm_b=$((_tm_b+1)); done
          _tm_v=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); shift 4
          _tm_v=$(( _tm_v + _tm_bo ))
          _oct3 $(( _tm_v / 16777216 % 256 )); _tm_esc="$_tm_esc$_OCT"
          _oct3 $(( _tm_v / 65536 % 256 ));    _tm_esc="$_tm_esc$_OCT"
          _oct3 $(( _tm_v / 256 % 256 ));      _tm_esc="$_tm_esc$_OCT"
          _oct3 $(( _tm_v % 256 ));            _tm_esc="$_tm_esc$_OCT"
          _tm_b=0; while [ "$_tm_b" -lt 4 ]; do _oct3 "$1"; _tm_esc="$_tm_esc$_OCT"; shift; _tm_b=$((_tm_b+1)); done
          _tm_cnt=$((_tm_cnt+1))
        done
        printf "$_tm_esc" >> "$_tm_out" 2>/dev/null || return 1
        ;;
    esac
    _tm_i=$((_tm_i+1))
  done

  # ---- 接上两份数据 ----
  cat "$_tm_src" >> "$_tm_out" 2>/dev/null
  cat "$_tm_orig" >> "$_tm_out" 2>/dev/null

  # ---- 自检 ----
  _tm_v=$(wc -c < "$_tm_out" 2>/dev/null | tr -d ' ')
  isnum "$_tm_v" || return 1
  _tm_b=$(( _tm_H + $(wc -c < "$_tm_src" 2>/dev/null | tr -d ' ') + $(wc -c < "$_tm_orig" 2>/dev/null | tr -d ' ') ))
  [ "$_tm_v" = "$_tm_b" ] || return 1
  [ "$(head -c 4 "$_tm_out" 2>/dev/null)" = ttcf ] || return 1
  [ "$(ttc_faces_of "$_tm_out")" = "$_tm_faces" ] || return 1
  return 0
}

# 直接运行 = 命令行模式（被 source 时不能 exit，否则会把调用方一起退出）
case "${0##*/}" in
  ttcwrap.sh)
    if [ -n "${1:-}" ]; then
      if [ -n "${5:-}" ]; then
        ttc_wrap_mix "$1" "${2:-1}" "${3:-/data/local/tmp/out.ttc}" "${4:-}" "$5" \
          && echo "OK(mix):$3" || echo "ERROR:生成失败"
      else
        ttc_wrap "$1" "${2:-1}" "${3:-/data/local/tmp/out.ttc}" && echo "OK:$3" || echo "ERROR:生成失败"
      fi
    else
      echo "用法: sh ttcwrap.sh <源字体> <face数> <输出.ttc>"
      echo "      sh ttcwrap.sh <源字体> <face数> <输出.ttc> <原合集> \"<要换的序号>\"   混合模式"
      echo "      ttc_faces_of <某个.ttc>   查看这个合集有多少个 face"
    fi
    ;;
esac
return 0 2>/dev/null || true
