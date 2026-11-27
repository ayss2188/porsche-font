#!/system/bin/sh
# fontpack.sh - 字体包安装/校验（不经过 Root 管理器）
# 用法:
#   sh fontpack.sh state
#   sh fontpack.sh install <zip>
#   sh fontpack.sh version
#
# 字体包只包含 builtin/*.ttf 和签名清单；安装前必须用 porsche 插件同一把
# Ed25519 公钥校验。安装成功后会清空所有由字体内容派生的缓存。

MODDIR=${0%/*}
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/porsche_font_multi
case "$MODDIR" in .|"") MODDIR=$(pwd 2>/dev/null || echo /data/adb/modules/porsche_font_multi) ;; esac
. "$MODDIR/common.sh" 2>/dev/null
[ -f "$MODDIR/builtin.sh" ] && . "$MODDIR/builtin.sh" 2>/dev/null

LIB="${LIB:-$LIBROOT/fonts}"
KEYS="$MODDIR/engine_keys.conf"
VERIFY="$MODDIR/bin/cfs-verify"
STAGE=""
trap 'rm -rf "$STAGE" 2>/dev/null' EXIT 2>/dev/null

_fp_die() { echo "ERROR:$*"; exit 1; }
_fp_say() { echo "$*"; }

_fp_variant() {
  case "$1" in
    *porsche_font_multi*) echo multi ;;
    *porsche_font_718*) echo none ;;
    *porsche_font_911*) echo colon ;;
    *porsche_font_gt3*) echo flair ;;
    *) echo "" ;;
  esac
}

_fp_keyid() {
  sed -n '1s/^ed25519://p' "$1/SIGNATURE" 2>/dev/null | tr -d '\r'
}

_fp_pub() {
  _kid="$1"
  _pub=$(sed -n "s/^${_kid}=//p" "$KEYS" 2>/dev/null | head -n1 | tr -d '\r')
  if [ -z "$_pub" ] && [ "$_kid" = "kb4284ec43397" ]; then
    _pub="8ce16a9138c1965fb891db59a1ef9739699ce4f9f122d26283e959e8fdf38a4d"
  fi
  printf '%s' "$_pub"
}

_fp_verify() {
  _d="$1"
  [ -f "$_d/font.prop" ] || _fp_die "字体包缺少 font.prop"
  [ -f "$_d/MANIFEST.sha256" ] || _fp_die "字体包缺少 MANIFEST.sha256"
  [ -f "$_d/SIGNATURE" ] || _fp_die "字体包缺少 SIGNATURE"
  [ -x "$VERIFY" ] || _fp_die "模块缺少签名校验器，请升级模块"

  _kid=$(_fp_keyid "$_d")
  _pub=$(_fp_pub "$_kid")
  [ -n "$_kid" ] && [ -n "$_pub" ] || _fp_die "不认识的字体包签名密钥"
  _sig=$(sed -n '2p' "$_d/SIGNATURE" | tr -d '\r')
  "$VERIFY" "$_d/MANIFEST.sha256" "$_sig" "$_pub" || _fp_die "字体包签名无效（不是开发者发布的包）"

  _bad=0
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _h=$(printf '%s' "$_line" | awk '{print $1}')
    _f=$(printf '%s' "$_line" | awk '{print $2}')
    [ -f "$_d/$_f" ] || { _bad=1; break; }
    [ "$(sha256sum "$_d/$_f" 2>/dev/null | awk '{print $1}')" = "$_h" ] || { _bad=1; break; }
  done < "$_d/MANIFEST.sha256"
  [ "$_bad" = 0 ] || _fp_die "字体包文件被改动"

  _extra=$(cd "$_d" && find . -type f 2>/dev/null | sed 's|^\./||' \
    | grep -v '^MANIFEST.sha256$' | grep -v '^SIGNATURE$' \
    | while IFS= read -r f; do grep -q "  $f\$" "$_d/MANIFEST.sha256" || echo "$f"; done)
  [ -z "$_extra" ] || _fp_die "字体包含清单之外的文件：$(printf '%s' "$_extra" | head -n1)"
}

_fp_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 | tr -d '\r'
}

_fp_clear_caches() {
  # 字体内容一变，所有由字体派生的东西都必须失效。
  rm -rf "$CACHEDIR/plan" "$CACHEDIR/ttc" 2>/dev/null
  rm -rf "$CLOCKDIR"/* 2>/dev/null
  mkdir -p "$CACHEDIR/plan" "$CACHEDIR/ttc" "$CLOCKDIR" 2>/dev/null
  rm -f "$STATEDIR"/verify.cache "$STATEDIR"/cand.cache "$STATEDIR"/marks.cache \
        "$STATEDIR"/skipscan.cache "$STATEDIR"/extra.cache "$STATEDIR"/xmlnames.cache \
        "$STATEDIR"/dirnames.cache "$STATEDIR"/oemnames.cache "$STATEDIR"/scan_names.cache \
        "$STATEDIR"/scan.stat "$STATEDIR"/ttc.committed "$STATEDIR"/clock.committed \
        "$STATEDIR"/ttc.used "$STATEDIR"/clock.used "$STATEDIR"/apply.state \
        "$STATEDIR"/reapply.state 2>/dev/null
  rm -f "$STATEDIR"/pw.*.state 2>/dev/null
  # 旧版遗留的 per-font 缓存
  rm -rf "$STATEDIR"/cand "$STATEDIR"/verify 2>/dev/null

  # 字体内容变了，旧计划 / 旧 payload 里可能还指向已删除的 TTC / 时钟文件。
  # 只清缓存不清计划，开机会拿旧 slots.map 去挂已经不存在的文件，表现就是卡开机/救援。
  rm -f "$MODDIR/slots.map" "$MODDIR/slots.applied" "$MODDIR/slots.boot.map" \
        "$MODDIR/slots.map.prev" "$MODDIR/mount.state" 2>/dev/null
  rm -rf "$MODDIR/payload" 2>/dev/null
  mkdir -p "$MODDIR/payload" 2>/dev/null
  printf 'none\n' > "$MODDIR/pending_font" 2>/dev/null
  printf 'none\n' > "$MODDIR/active_font" 2>/dev/null
  printf 'none\n' > "$STATEDIR/last_selection" 2>/dev/null
}

_fp_state() {
  _st="$STATEDIR/font.pack.json"
  if [ -s "$_st" ]; then
    cat "$_st"
  else
    echo '{"version":"v1.0","versionCode":10000,"variant":"","fonts":""}'
  fi
}

_fp_install() {
  _zip="$1"
  [ -f "$_zip" ] || _fp_die "找不到字体包：$_zip"
  _stage="$STATEDIR/fontpack.stage.$$"
  rm -rf "$_stage" 2>/dev/null
  mkdir -p "$_stage" 2>/dev/null || _fp_die "无法创建临时目录"
  STAGE="$_stage"
  unzip -q -o "$_zip" -d "$_stage" 2>/dev/null || _fp_die "解压失败"
  _fp_verify "$_stage"

  _v=$(_fp_field "$_stage/font.prop" variant)
  _ver=$(_fp_field "$_stage/font.prop" version)
  _code=$(_fp_field "$_stage/font.prop" code)
  _min=$(_fp_field "$_stage/font.prop" min_module_code)
  case "$_code" in ''|*[!0-9]*) _fp_die "字体包 code 非法" ;; esac
  _variant=$(_fp_variant "$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1)")
  [ -n "$_variant" ] || _fp_die "无法识别当前模块变体"
  [ "$_v" = "$_variant" ] || _fp_die "字体包变体不匹配：包=$_v，模块=$_variant"
  _modcode=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
  case "$_modcode" in ''|*[!0-9]*) _modcode=0 ;; esac
  case "$_min" in ''|*[!0-9]*) _min=0 ;; esac
  [ "$_modcode" -ge "$_min" ] || _fp_die "当前模块版本过低，字体包要求 $(_min)"

  _ids=$(awk -F= '/^font\.[^.]+\.name=/{sub(/^font\./,"",$1); sub(/\.name$/,"",$1); print $1}' "$_stage/font.prop")
  [ -n "$_ids" ] || _fp_die "字体包里没有字体条目"

  # 备份当前内置字体
  _bk="$BACKUPDIR/fontpack/${_ver:-unknown}-$(date +%s 2>/dev/null)"
  mkdir -p "$_bk" 2>/dev/null
  for _f in "$LIB"/builtin_*.ttf; do [ -f "$_f" ] && cp -f "$_f" "$_bk/" 2>/dev/null; done

  # 清掉不在新包里的旧内置字体
  for _old in "$LIB"/builtin_*.ttf; do
    [ -f "$_old" ] || continue
    _id=${_old##*/}; _id=${_id#builtin_}; _id=${_id%.*}
    case " $_ids " in *" $_id "*) ;; *)
      rm -f "$LIB/builtin_$_id".ttf "$LIB/builtin_$_id".meta "$LIB/builtin_$_id".name 2>/dev/null
    ;; esac
  done

  for _id in $_ids; do
    _src="$_stage/builtin/$_id.ttf"
    [ -f "$_src" ] || _fp_die "字体包缺少 builtin/$_id.ttf"
    cp -f "$_src" "$LIB/builtin_$_id.ttf" 2>/dev/null || _fp_die "写入字体失败：$_id"
    chmod 644 "$LIB/builtin_$_id.ttf" 2>/dev/null
    _nm=$(_fp_field "$_stage/font.prop" "font.$_id.name")
    [ -n "$_nm" ] || _nm="$_id"
    printf '%s' "$_nm" > "$LIB/builtin_$_id.name" 2>/dev/null
    _vf=0
    command -v builtin_is_vf >/dev/null 2>&1 && builtin_is_vf "$LIB/builtin_$_id.ttf" >/dev/null 2>&1 && _vf=1
    command -v _builtin_meta_ensure >/dev/null 2>&1 && _builtin_meta_ensure "builtin_$_id" "$_vf" >/dev/null 2>&1
  done

  _fp_clear_caches
  mkdir -p "$STATEDIR" 2>/dev/null
  printf '{\n  "version": "%s",\n  "versionCode": %s,\n  "variant": "%s",\n  "fonts": "%s",\n  "installedAt": "%s"\n}\n' \
    "$_ver" "$_code" "$_variant" "$(printf '%s' "$_ids" | tr '\n' ' ' | sed 's/ $//')" "$(date +%s 2>/dev/null)" \
    > "$STATEDIR/font.pack.json" 2>/dev/null
  echo "OK:${_ver}:$_code"
}

case "${1:-}" in
  state) _fp_state ;;
  version) sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATEDIR/font.pack.json" 2>/dev/null | head -n1 ;; 
  install) shift; _fp_install "$1" ;;
  *) echo "ERROR:用法: fontpack.sh [state|version|install <zip>]" ;;
esac
