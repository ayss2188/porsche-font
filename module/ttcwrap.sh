#!/system/bin/sh
# ttcwrap.sh - 把单文件字体（.ttf/.otf）包成"多 face 的 TTC 合集"
#
# ★ 2026-10-24 修（真机：Flyme/魅族上 ttc_wrap 一直 rc=1、产物 0 字节）
#   根因：_be4 的 printf 格式写成了 '\\%03o'（双反斜杠）——
#   在 shell 单引号里 '\\' 是两个字符，printf 把它当"字面反斜杠"，
#   于是输出的不是字节，而是文本 "\101\102..." → 表目录长度永远对不上 → rc=1。
#   同时补一层兼容：有的 shell 只认 \101（3 位），mksh 只认 \0101（前导 0 + 3 位），
#   启动时探一次，两种都不认就用 awk 逐字节写，保证任何 sh 都能生成合法 TTC。
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

# ---------------------------------------------------------------------------
# 字节发射：探测这台机器的 printf 认哪种八进制转义
#   TW_ESC=1 → \101   （3 位，busybox/ash）
#   TW_ESC=2 → \0101  （前导 0 + 3 位，mksh）
#   TW_ESC=3 → awk 逐字节
# ---------------------------------------------------------------------------
_tw_probe() {
  [ -n "${TW_ESC:-}" ] && return 0
  if [ "$(printf '\101' 2>/dev/null | od -An -tu1 2>/dev/null | tr -dc '0-9')" = "65" ]; then
    TW_ESC=1
  elif [ "$(printf '\0101' 2>/dev/null | od -An -tu1 2>/dev/null | tr -dc '0-9')" = "65" ]; then
    TW_ESC=2
  else
    TW_ESC=3
  fi
  export TW_ESC
}

# 4 字节大端 → stdout
_be4() {
  _tw_probe
  _b=${1:-0}
  case "$TW_ESC" in
    1)
      printf "\\$(printf '%03o' $(( (_b >> 24) & 255 )))\\$(printf '%03o' $(( (_b >> 16) & 255 )))\\$(printf '%03o' $(( (_b >> 8) & 255 )))\\$(printf '%03o' $(( _b & 255 )))"
      ;;
    2)
      printf "\\0$(printf '%03o' $(( (_b >> 24) & 255 )))\\0$(printf '%03o' $(( (_b >> 16) & 255 )))\\0$(printf '%03o' $(( (_b >> 8) & 255 )))\\0$(printf '%03o' $(( _b & 255 )))"
      ;;
    *)
      awk -v v="$_b" 'BEGIN{
        a[1]=int(v/16777216)%256; a[2]=int(v/65536)%256; a[3]=int(v/256)%256; a[4]=v%256;
        for (i=1;i<=4;i++) printf "%c", a[i];
      }'
      ;;
  esac
}

# 一串十进制字节值（"1 2 3 ..."）→ stdout
_emit_dec() {
  _tw_probe
  case "$TW_ESC" in
    1|2)
      _ed_esc=""
      for _ed_b in $1; do
        case "$TW_ESC" in
          1) _ed_esc="$_ed_esc\\$(printf '%03o' "$_ed_b")" ;;
          2) _ed_esc="$_ed_esc\\0$(printf '%03o' "$_ed_b")" ;;
        esac
      done
      printf "$_ed_esc"
      ;;
    *)
      awk -v s="$1" 'BEGIN{ n=split(s,a," "); for(i=1;i<=n;i++) printf "%c", (a[i]+0)%256 }'
      ;;
  esac
}

isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

ttc_wrap() {
  _tw_src="$1"; _tw_faces="$2"; _tw_out="$3"
  [ -f "$_tw_src" ] || return 1
  isnum "$_tw_faces" || return 1
  [ "$_tw_faces" -ge 1 ] 2>/dev/null || return 1
  [ "$_tw_faces" -le 64 ] 2>/dev/null || return 1
  _tw_probe

  # 源文件头 6 字节 = sfntVersion(4) + numTables(2, 大端)
  _tw_b=$(od -An -tu1 -N6 "$_tw_src" 2>/dev/null)
  set -- $_tw_b
  [ $# -ge 6 ] || return 1
  _tw_num=$(( $5 * 256 + $6 ))
  [ "$_tw_num" -ge 1 ] && [ "$_tw_num" -le 512 ] || return 1

  _tw_dir=$(( 12 + 16 * _tw_num ))
  _tw_H=$(( 12 + 4 * _tw_faces + _tw_faces * _tw_dir ))

  _tw_tmp="${TMPDIR:-/data/local/tmp}/.ttcw.$$"
  mkdir -p "${_tw_tmp%/*}" 2>/dev/null

  dd if="$_tw_src" bs=1 count=12 2>/dev/null > "$_tw_tmp.dir" || { rm -f "$_tw_tmp.dir"; return 1; }

  _tw_i=0
  while [ "$_tw_i" -lt "$_tw_num" ]; do
    _tw_at=$(( 12 + _tw_i * 16 ))
    dd if="$_tw_src" bs=1 skip="$_tw_at" count=8 2>/dev/null >> "$_tw_tmp.dir"
    _tw_o=$(od -An -tu1 -j$(( _tw_at + 8 )) -N4 "$_tw_src" 2>/dev/null)
    set -- $_tw_o
    if [ $# -lt 4 ]; then rm -f "$_tw_tmp.dir"; return 1; fi
    _tw_old=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
    _be4 $(( _tw_old + _tw_H )) >> "$_tw_tmp.dir"
    dd if="$_tw_src" bs=1 skip=$(( _tw_at + 12 )) count=4 2>/dev/null >> "$_tw_tmp.dir"
    _tw_i=$(( _tw_i + 1 ))
  done

  _tw_got=$(wc -c < "$_tw_tmp.dir" 2>/dev/null | tr -d ' ')
  if [ "$_tw_got" != "$(( 12 + 16 * _tw_num ))" ]; then
    rm -f "$_tw_tmp.dir"
    return 1
  fi

  {
    printf 'ttcf'
    _be4 65536                       # 版本 1.0（0x00010000）
    _be4 "$_tw_faces"
    _tw_i=0
    while [ "$_tw_i" -lt "$_tw_faces" ]; do
      _be4 $(( 12 + 4 * _tw_faces + _tw_i * _tw_dir ))
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

  _tw_sz=$(wc -c < "$_tw_out" 2>/dev/null | tr -d ' ')
  _tw_srcsz=$(wc -c < "$_tw_src" 2>/dev/null | tr -d ' ')
  isnum "$_tw_sz" || return 1
  [ "$_tw_sz" -gt "$_tw_srcsz" ] || return 1
  [ "$(head -c 4 "$_tw_out" 2>/dev/null)" = ttcf ] || return 1
  return 0
}

# 读一个 .ttc 有多少个 face（不是 ttc 返回 0）
ttc_faces_of() {
  _tf_sz=0
  [ -f "$1" ] || { echo 0; return; }
  [ "$(head -c 4 "$1" 2>/dev/null)" = ttcf ] || { echo 0; return; }
  _tf_sz=$(wc -c < "$1" 2>/dev/null | tr -d ' \t\r\n')
  isnum "$_tf_sz" && [ "$_tf_sz" -ge 100 ] 2>/dev/null || { echo 0; return; }
  _tf=$(od -An -tu1 -j8 -N4 "$1" 2>/dev/null)
  set -- $_tf
  [ $# -ge 4 ] || { echo 0; return; }
  echo $(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
}

# 读 .ttc 里第 i 号 face 的表目录偏移（大端 4 字节）
_ttc_face_off() {
  _TFO=$(od -An -tu1 -j$(( 12 + 4 * $2 )) -N4 "$1" 2>/dev/null)
  set -- $_TFO
  [ $# -ge 4 ] || { echo -1; return; }
  echo $(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
}

# ---------------------------------------------------------------------------
# 混合合集：只把中文那几号 face 换成用户字体，其它 face 保留原合集的字形数据
#   ttc_wrap_mix <用户字体> <face数> <输出> <原合集> <要替换的序号，如 "2 3">
# ---------------------------------------------------------------------------
ttc_wrap_mix() {
  _tm_src="$1"; _tm_faces="$2"; _tm_out="$3"; _tm_orig="$4"; _tm_cn="$5"
  [ -f "$_tm_src" ] && [ -f "$_tm_orig" ] || return 1
  isnum "$_tm_faces" || return 1
  [ "$_tm_faces" -ge 1 ] 2>/dev/null || return 1
  [ "$_tm_faces" -le 64 ] 2>/dev/null || return 1
  [ "$(head -c 4 "$_tm_orig" 2>/dev/null)" = ttcf ] || return 1
  [ "$(ttc_faces_of "$_tm_orig")" = "$_tm_faces" ] || return 1
  _tw_probe

  _tm_b=$(od -An -tu1 -N6 "$_tm_src" 2>/dev/null)
  set -- $_tm_b
  [ $# -ge 6 ] || return 1
  _tm_u=$(( $5 * 256 + $6 ))
  [ "$_tm_u" -ge 1 ] && [ "$_tm_u" -le 512 ] || return 1
  _tm_dirsz=$(( 12 + 16 * _tm_u ))

  _tm_cn=" $(printf '%s' "$_tm_cn" | tr -s ' ') "
  _tm_keep=0
  _tm_i=0
  while [ "$_tm_i" -lt "$_tm_faces" ]; do
    case "$_tm_cn" in *" $_tm_i "*) ;; *) _tm_keep=$((_tm_keep+1)) ;; esac
    _tm_i=$((_tm_i+1))
  done
  [ "$_tm_keep" = 0 ] && { ttc_wrap "$_tm_src" "$_tm_faces" "$_tm_out"; return $?; }

  # 头部长度 H = 12 + 4*faces + 各 face 目录长度之和
  _tm_H=$(( 12 + 4 * _tm_faces ))
  _tm_i=0
  while [ "$_tm_i" -lt "$_tm_faces" ]; do
    case "$_tm_cn" in
      *" $_tm_i "*) _tm_H=$(( _tm_H + _tm_dirsz )) ;;
      *)
        _tm_o=$(_ttc_face_off "$_tm_orig" "$_tm_i")
        [ "$_tm_o" -ge 12 ] 2>/dev/null || return 1
        _tm_n=$(od -An -tu1 -j$(( _tm_o + 4 )) -N2 "$_tm_orig" 2>/dev/null)
        set -- $_tm_n
        [ $# -ge 2 ] || return 1
        _tm_n=$(( $1 * 256 + $2 ))
        [ "$_tm_n" -ge 1 ] && [ "$_tm_n" -le 512 ] || return 1
        _tm_H=$(( _tm_H + 12 + 16 * _tm_n ))
        ;;
    esac
    _tm_i=$((_tm_i+1))
  done

  _tm_v=$(wc -c < "$_tm_src" 2>/dev/null | tr -d ' ')
  isnum "$_tm_v" || return 1
  _tm_bu="$_tm_H"
  _tm_bo=$(( _tm_H + _tm_v ))

  # 写 TTC 头
  {
    printf 'ttcf'
    _be4 65536
    _be4 "$_tm_faces"
    _tm_o=$(( 12 + 4 * _tm_faces ))
    _tm_i=0
    while [ "$_tm_i" -lt "$_tm_faces" ]; do
      _be4 "$_tm_o"
      case "$_tm_cn" in
        *" $_tm_i "*) _tm_o=$(( _tm_o + _tm_dirsz )) ;;
        *)
          _tm_n=$(_ttc_face_off "$_tm_orig" "$_tm_i")
          _tm_len=$(od -An -tu1 -j$(( _tm_n + 4 )) -N2 "$_tm_orig" 2>/dev/null)
          set -- $_tm_len
          _tm_o=$(( _tm_o + 12 + 16 * ( $1 * 256 + $2 ) )) ;;
      esac
      _tm_i=$((_tm_i+1))
    done
  } > "$_tm_out" 2>/dev/null || return 1

  # 逐个 face 的目录：用十进制字节值拼接，最后一次性发射
  _tm_i=0
  while [ "$_tm_i" -lt "$_tm_faces" ]; do
    _tm_dec=""
    case "$_tm_cn" in
      *" $_tm_i "*)
        _tm_bytes=$(dd if="$_tm_src" bs=1 count="$_tm_dirsz" 2>/dev/null | od -An -tu1 -v 2>/dev/null)
        set -- $_tm_bytes
        [ $# -ge "$_tm_dirsz" ] || return 1
        _tm_cnt=0
        while [ "$_tm_cnt" -lt 12 ]; do
          _tm_dec="$_tm_dec $1"; shift; _tm_cnt=$((_tm_cnt+1))
        done
        _tm_cnt=0
        while [ "$_tm_cnt" -lt "$_tm_u" ]; do
          _tm_k=0
          while [ "$_tm_k" -lt 8 ]; do _tm_dec="$_tm_dec $1"; shift; _tm_k=$((_tm_k+1)); done
          _tm_v2=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); shift 4
          _tm_v2=$(( _tm_v2 + _tm_bu ))
          _tm_dec="$_tm_dec $(( _tm_v2 / 16777216 % 256 )) $(( _tm_v2 / 65536 % 256 )) $(( _tm_v2 / 256 % 256 )) $(( _tm_v2 % 256 ))"
          _tm_k=0
          while [ "$_tm_k" -lt 4 ]; do _tm_dec="$_tm_dec $1"; shift; _tm_k=$((_tm_k+1)); done
          _tm_cnt=$((_tm_cnt+1))
        done
        ;;
      *)
        _tm_o=$(_ttc_face_off "$_tm_orig" "$_tm_i")
        _tm_n=$(od -An -tu1 -j$(( _tm_o + 4 )) -N2 "$_tm_orig" 2>/dev/null); set -- $_tm_n
        _tm_n=$(( $1 * 256 + $2 ))
        _tm_len=$(( 12 + 16 * _tm_n ))
        _tm_bytes=$(dd if="$_tm_orig" bs=1 skip="$_tm_o" count="$_tm_len" 2>/dev/null | od -An -tu1 -v 2>/dev/null)
        set -- $_tm_bytes
        [ $# -ge "$_tm_len" ] || return 1
        _tm_k=0
        while [ "$_tm_k" -lt 12 ]; do _tm_dec="$_tm_dec $1"; shift; _tm_k=$((_tm_k+1)); done
        _tm_cnt=0
        while [ "$_tm_cnt" -lt "$_tm_n" ]; do
          _tm_k=0
          while [ "$_tm_k" -lt 8 ]; do _tm_dec="$_tm_dec $1"; shift; _tm_k=$((_tm_k+1)); done
          _tm_v2=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 )); shift 4
          _tm_v2=$(( _tm_v2 + _tm_bo ))
          _tm_dec="$_tm_dec $(( _tm_v2 / 16777216 % 256 )) $(( _tm_v2 / 65536 % 256 )) $(( _tm_v2 / 256 % 256 )) $(( _tm_v2 % 256 ))"
          _tm_k=0
          while [ "$_tm_k" -lt 4 ]; do _tm_dec="$_tm_dec $1"; shift; _tm_k=$((_tm_k+1)); done
          _tm_cnt=$((_tm_cnt+1))
        done
        ;;
    esac
    _emit_dec "$_tm_dec" >> "$_tm_out" 2>/dev/null || return 1
    _tm_i=$((_tm_i+1))
  done

  cat "$_tm_src" >> "$_tm_out" 2>/dev/null
  cat "$_tm_orig" >> "$_tm_out" 2>/dev/null

  _tm_sz=$(wc -c < "$_tm_out" 2>/dev/null | tr -d ' ')
  isnum "$_tm_sz" || return 1
  _tm_expect=$(( _tm_H + $(wc -c < "$_tm_src" 2>/dev/null | tr -d ' ') + $(wc -c < "$_tm_orig" 2>/dev/null | tr -d ' ') ))
  [ "$_tm_sz" = "$_tm_expect" ] || return 1
  [ "$(head -c 4 "$_tm_out" 2>/dev/null)" = ttcf ] || return 1
  [ "$(ttc_faces_of "$_tm_out")" = "$_tm_faces" ] || return 1
  return 0
}

# 直接运行 = 命令行模式（被 source 时不能 exit）
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
