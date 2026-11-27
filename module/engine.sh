#!/system/bin/sh
LIBROOT="${LIBROOT:-${LIB:-/data/adb/custom_font_lib}}"
LIBROOT="${LIBROOT:-/data/adb/custom_font_lib}"
LIB="$LIBROOT/fonts"
FONTDIR="$LIBROOT/fonts"
BUILTINDIR="$LIBROOT/builtin"
CLOCKDIR="$LIBROOT/clock"
CACHEDIR="$LIBROOT/cache"
STATEDIR="$LIBROOT/state"
BACKUPDIR="$LIBROOT/backup"
WORKDIR="$LIBROOT/work"
LOGDIR="$STATEDIR/logs"
# engine.sh —— 字体工具箱（插件引擎）的安装 / 卸载 / 调用入口
#
# 用法：
#   sh engine.sh status
#   sh engine.sh install                 # 从 engine.json 指定的 GitHub 地址下载
#   sh engine.sh install <url> <sha256>  # 指定地址
#   sh engine.sh install-local [zip]     # 从本地 zip 安装（默认扫 Download）
#   sh engine.sh uninstall
#   sh engine.sh run <action> [args...]  # 调用已安装引擎
#   sh engine.sh check-update
#
# 安装位置：$LIB/engine
# 引擎包要求：
#   plugin.prop 必须包含
#     id=cfs_fontlab_porsche
#     vendor=ayss2188
#     magic=cfs-fontlab-porsche
#     api=1
#     arch=arm64（或 aarch64）
#     entry=bin/run
#   zip 内所有文件都在根目录（不是套一层文件夹）

MODDIR=${0%/*}
# 跟主项目一致：插件放 state/engine，状态文件放 state/engine.state
ENG="$STATEDIR/engine"
STATE="$STATEDIR/engine.state"
META="$MODDIR/engine.json"
# 兼容排查：如果插件在旧位置/被环境变量带偏，status 仍能找到它
if [ ! -d "$ENG" ]; then
  for _eng_cand in "$LIBROOT/engine" "$LIBROOT/plugin" "$LIB/state/engine"; do
    [ -d "$_eng_cand" ] || continue
    ENG="$_eng_cand"
    break
  done
fi
# 开发者公钥（Ed25519）：只认这把私钥签出来的插件包
KEYS_FILE="$MODDIR/engine_keys.conf"
TMP="${TMPDIR:-/data/local/tmp}"

say() { printf '%s\n' "$*"; }
err() { printf 'ERROR:%s\n' "$*"; }

need_tools() {
  command -v unzip >/dev/null 2>&1 || { err "缺少 unzip，无法安装插件"; exit 1; }
}

arch_ok() {
  case "$(uname -m 2>/dev/null)" in
    aarch64|arm64) echo arm64 ;;
    *) echo "其它" ;;
  esac
}

read_prop() { # $1=file $2=key
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 | tr -d '\r'
}

verify_zip() { # $1=zip → 0 通过；失败打印原因
  _z="$1"
  [ -s "$_z" ] || { err "文件不存在或为空"; return 1; }
  _p="$TMP/.eng.prop.$$"
  unzip -p "$_z" plugin.prop > "$_p" 2>/dev/null || { rm -f "$_p"; err "不是插件包（缺 plugin.prop）"; return 1; }
  _id=$(read_prop "$_p" id)
  _vendor=$(read_prop "$_p" vendor)
  _magic=$(read_prop "$_p" magic)
  _api=$(read_prop "$_p" api)
  _entry=$(read_prop "$_p" entry)
  _arch=$(read_prop "$_p" arch)
  rm -f "$_p"
  [ "$_id" = "cfs_fontlab_porsche" ] || { err "不是本项目的插件（id=$_id）"; return 1; }
  [ "$_vendor" = "ayss2188" ] || { err "插件来源不对（vendor=$_vendor）"; return 1; }
  [ "$_magic" = "cfs-fontlab-porsche" ] || { err "缺少插件标记（magic）"; return 1; }
  [ "$_api" = "1" ] || { err "插件接口版本不兼容（api=$_api）"; return 1; }
  [ "$_entry" = "bin/run" ] || { err "插件入口不对（entry=$_entry）"; return 1; }
  [ "$_arch" = "$(arch_ok)" ] || { err "插件架构不匹配（需要 $(arch_ok)，包里是 $_arch）"; return 1; }
  unzip -l "$_z" 2>/dev/null | grep -q " bin/run$" || { err "插件包里没有 bin/run"; return 1; }
  return 0
}

verify_manifest() { # $1=解压目录
  _d="$1"
  _mf="$_d/MANIFEST.sha256"
  [ -s "$_mf" ] || { err "插件包缺少 MANIFEST.sha256"; return 1; }
  # 清单里必须包含 plugin.prop 和 bin/run
  grep -q '  plugin.prop$' "$_mf" || { err "清单没有覆盖 plugin.prop"; return 1; }
  grep -q '  bin/run$' "$_mf" || { err "清单没有覆盖 bin/run"; return 1; }
  # 逐文件校验
  _bad=0
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _hash=$(printf '%s' "$_line" | awk '{print $1}')
    _file=$(printf '%s' "$_line" | awk '{print $2}')
    [ -f "$_d/$_file" ] || { err "清单里的文件不存在：$_file"; _bad=1; break; }
    _got=$(sha256sum "$_d/$_file" 2>/dev/null | awk '{print $1}')
    [ "$_got" = "$_hash" ] || { err "文件被改动：$_file"; _bad=1; break; }
  done < "$_mf"
  [ "$_bad" = "0" ] || return 1
  # 不允许清单之外的可执行文件混进来（防止偷偷加脚本）
  _extras=$(cd "$_d" && find . -type f 2>/dev/null | sed 's|^\./||' \
    | grep -v '^MANIFEST.sha256$' | grep -v '^SIGNATURE$' \
    | while IFS= read -r f; do grep -q "  $f\$" "$_mf" || echo "$f"; done)
  [ -z "$_extras" ] || { err "插件包含清单之外的文件：$(printf '%s' "$_extras" | head -n1)"; return 1; }
  return 0
}

verify_signature() { # $1=解压目录
  _d="$1"
  [ -f "$_d/SIGNATURE" ] || { err "插件没有签名（SIGNATURE）"; return 1; }
  _v="$MODDIR/bin/cfs-verify"
  if [ ! -x "$_v" ]; then
    # 老版本主模块没带校验器：明确告知，不让它悄悄通过
    err "主模块缺少签名校验器，无法验证插件来源（请升级主模块）"
    return 1
  fi
  # SIGNATURE 第一行 ed25519:<keyid>，第二行 base64
  _keyid=$(sed -n '1s/^ed25519://p' "$_d/SIGNATURE" | tr -d '\r')
  _sig=$(sed -n '2p' "$_d/SIGNATURE" | tr -d '\r')
  [ -n "$_keyid" ] || { err "签名格式不对（缺 keyid）"; return 1; }
  _pub=$(sed -n "s/^${_keyid}=//p" "$KEYS_FILE" 2>/dev/null | head -n1 | tr -d '\r')
  # 兜底：老版本模块的 engine_keys.conf 可能没有 porsche 公钥
  [ -n "$_pub" ] || [ "$_keyid" != "kb4284ec43397" ] || _pub="8ce16a9138c1965fb891db59a1ef9739699ce4f9f122d26283e959e8fdf38a4d"
  [ -n "$_pub" ] || { err "不认识的签名密钥（keyid=$_keyid）"; return 1; }
  "$_v" "$_d/MANIFEST.sha256" "$_sig" "$_pub" || { err "插件签名无效（不是开发者发布的包）"; return 1; }
  return 0
}

install_zip() { # $1=zip
  need_tools
  verify_zip "$1" || exit 1
  _stage="$STATEDIR/engine.stage.$$"
  rm -rf "$_stage" 2>/dev/null
  mkdir -p "$_stage" 2>/dev/null || { err "无法创建临时目录"; exit 1; }
  unzip -q -o "$1" -d "$_stage" 2>/dev/null || { rm -rf "$_stage"; err "解压失败"; exit 1; }
  verify_manifest "$_stage" || { rm -rf "$_stage"; exit 1; }
  if [ "${CFS_ALLOW_UNSIGNED:-0}" = "1" ]; then
    say "警告：已跳过签名校验（仅测试用）"
  else
    verify_signature "$_stage" || { rm -rf "$_stage"; exit 1; }
  fi
  chmod 755 "$_stage/bin/run" 2>/dev/null
  chmod -R 755 "$_stage/bin" 2>/dev/null
  chmod 755 "$_stage/usr/bin/"* 2>/dev/null
  # 先跑一次 info，确认能执行
  _info=$("$_stage/bin/run" info --json 2>/dev/null)
  case "$_info" in
    *'"ok"'*|*'"name"'*) : ;;
    *) rm -rf "$_stage"; err "插件无法运行（可能 /data 不允许执行，或架构不匹配）"; exit 1 ;;
  esac
  rm -rf "$ENG" 2>/dev/null
  mv -f "$_stage" "$ENG" 2>/dev/null || { rm -rf "$_stage"; err "安装失败（移动目录出错）"; exit 1; }
  # WebUI 的 ksu.exec 可能以 shell 身份读取；插件目录不能是 700 root
  chmod -R a+rX "$ENG" 2>/dev/null
  chmod 755 "$ENG/bin/run" 2>/dev/null
  chmod -R a+rX "$ENG/bin" 2>/dev/null
  _ver=$(read_prop "$ENG/plugin.prop" version)
  printf 'version=%s\nsize_kb=%s\ninstalled=%s\n' "${_ver:-?}" "$(du -sk "$ENG" 2>/dev/null | awk '{print $1}')" "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" > "$STATE"
  # WebUI 的 shell 域不能读 /data/adb；写一份公开状态给界面
  _mark="/data/local/tmp/cfs-porsche.engine"
  {
    echo "INSTALLED=1"
    grep -E '^(version|build|code|author)=' "$ENG/plugin.prop" 2>/dev/null | sed 's/^version=/VERSION=/; s/^build=/BUILD=/; s/^code=/CODE=/; s/^author=/AUTHOR=/'
    echo "DIR=$ENG"
  } > "$_mark" 2>/dev/null
  chmod 644 "$_mark" 2>/dev/null
  say "OK:字体工具箱 ${_ver:-?} 已安装"
}

uninstall_engine() {
  rm -rf "$ENG" 2>/dev/null
  rm -rf "$WORKDIR" 2>/dev/null
  rm -f "$STATE" "$STATEDIR/engine.progress" "$STATEDIR/engine.dl" "$STATEDIR/engine.done" 2>/dev/null
  rm -rf "$LIB"/.engine.stage.* 2>/dev/null
  rm -f /data/local/tmp/cfs-porsche.engine 2>/dev/null
  say "OK:字体工具箱已卸载"
}

status() {
  if [ -x "$ENG/bin/run" ]; then
    _v=$(read_prop "$ENG/plugin.prop" version)
    _sz=$(sed -n "s/^size_kb=//p" "$STATE" 2>/dev/null | head -n1)
    say "INSTALLED=1"
    say "VERSION=${_v:-?}"
    say "CODE=$(read_prop "$ENG/plugin.prop" code)"
    say "BUILD=$(read_prop "$ENG/plugin.prop" build)"
    say "AUTHOR=$(read_prop "$ENG/plugin.prop" author)"
    say "SIZE_KB=${_sz:-0}"
    say "DIR=$ENG"
  else
    say "INSTALLED=0"
  fi
  say "ARCH=$(arch_ok)"
}

fetch_url() { # $1=url $2=out
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 15 -m 900 -o "$2" "$1" 2>/dev/null && return 0
  fi
  _bb=""
  for _b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /system/bin/busybox; do
    [ -x "$_b" ] && _bb="$_b" && break
  done
  if [ -n "$_bb" ]; then
    "$_bb" wget -q -T 20 -O "$2" "$1" 2>/dev/null && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -T 20 -O "$2" "$1" 2>/dev/null && return 0
  fi
  return 1
}


ENGINE_META_URLS="https://cfs-porsche-downloads-q2188366745.oss-cn-hangzhou.aliyuncs.com/porsche/engine.json https://raw.githubusercontent.com/ayss2188/porsche-font/main/engine.json"

fetch_meta() { # $1=输出文件；依次尝试 GitHub raw / jsDelivr
  for _mu in $ENGINE_META_URLS; do
    _mto=8
    case "$_mu" in *cfs-porsche-downloads*) _mto=3 ;; esac
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -m "$_mto" -o "$1" "$_mu" 2>/dev/null && [ -s "$1" ] && return 0
    else
      fetch_url "$_mu" "$1" && [ -s "$1" ] && return 0
    fi
  done
  return 1
}

install_remote() {
  need_tools
  _url="${1:-}"; _sha="${2:-}"
  if [ -z "$_url" ]; then
    [ -s "$META" ] || { err "缺少 engine.json，无法下载"; exit 1; }
    _url=$(sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$META" | head -n1)
    _sha=$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$META" | head -n1)
  fi
  [ -n "$_url" ] || { err "下载地址为空"; exit 1; }
  say "下载中：$_url"
  _z="$TMP/.fontlab.$$.zip"
  rm -f "$_z" 2>/dev/null
  fetch_url "$_url" "$_z" || { rm -f "$_z"; err "下载失败（网络不通，或用「从本地安装」）"; exit 1; }
  if [ -n "$_sha" ]; then
    _got=$(sha256sum "$_z" 2>/dev/null | awk '{print $1}')
    [ "$_got" = "$_sha" ] || { rm -f "$_z"; err "校验失败（下载不完整或被篡改）"; exit 1; }
  fi
  install_zip "$_z"
  _rc=$?
  rm -f "$_z" 2>/dev/null
  exit $_rc
}

find_local_zip() {
  for _f in /sdcard/Download/cfs-fontlab-porsche*.zip /sdcard/Download/fontlab*.zip \
            /storage/emulated/0/Download/cfs-fontlab-porsche*.zip /storage/emulated/0/Download/fontlab*.zip \
            /sdcard/Download/字体工具箱*.zip /sdcard/*.zip "$LIB"/*.zip; do
    [ -f "$_f" ] && { printf '%s' "$_f"; return 0; }
  done
  return 1
}

_engine_ver_gt() { # $1 是否大于 $2
  awk -v a="$1" -v b="$2" 'BEGIN {
    n=split(a,A,"."); m=split(b,B,"."); L=(n>m?n:m);
    for (i=1;i<=L;i++) {
      x=(i<=n && A[i] ~ /^[0-9]+$/ ? A[i]+0 : 0);
      y=(i<=m && B[i] ~ /^[0-9]+$/ ? B[i]+0 : 0);
      if (x>y) exit 0;
      if (x<y) exit 1;
    }
    exit 1;
  }'
}

case "${1:-status}" in
  status) status ;;
  install) shift; install_remote "$@" ;;
  install-local-bg)
    shift
    _f="${1:-}"
    [ -n "$_f" ] || _f=$(find_local_zip)
    [ -n "$_f" ] || { err "没找到插件 zip"; exit 1; }
    [ -f "$_f" ] || { err "文件不存在：$_f"; exit 1; }
    rm -f "$STATEDIR/engine.local.done" "$STATEDIR/engine.local.log" 2>/dev/null
    ( sh "$0" install-local "$_f" > "$STATEDIR/engine.local.log" 2>&1; echo "$?" > "$STATEDIR/engine.local.done" ) >/dev/null 2>&1 &
    echo "OK:started" ;;
  install-local)
    shift
    _f="${1:-}"
    [ -n "$_f" ] || _f=$(find_local_zip)
    [ -n "$_f" ] || { err "没找到插件 zip，请放到 Download（文件名 cfs-fontlab-porsche*.zip）"; exit 1; }
    [ -f "$_f" ] || { err "文件不存在：$_f"; exit 1; }
    install_zip "$_f" ;;
  uninstall) uninstall_engine ;;

  latest)
    _j="$TMP/.eng.latest.$$"
    fetch_meta "$_j" || { err "获取最新版本失败（网络不通）"; rm -f "$_j"; exit 1; }
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/VERSION=\1/p' "$_j" | head -n1
    sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/URL=\1/p' "$_j" | head -n1
    sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/SHA256=\1/p' "$_j" | head -n1
    rm -f "$_j" ;;
  install-latest)
    _j="$TMP/.eng.latest.$$"
    fetch_meta "$_j" || { err "获取最新版本失败（网络不通）"; rm -f "$_j"; exit 1; }
    _url=$(sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_j" | head -n1)
    _sha=$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_j" | head -n1)
    rm -f "$_j"
    [ -n "$_url" ] || { err "最新包没有下载地址"; exit 1; }
    _z="$TMP/.eng.dl.$$.zip"; rm -f "$_z"
    fetch_url "$_url" "$_z" || { rm -f "$_z"; err "下载失败（网络不通，或用「从本地安装」）"; exit 1; }
    if [ -n "$_sha" ]; then
      _g=$(sha256sum "$_z" 2>/dev/null | awk '{print $1}')
      [ "$_g" = "$_sha" ] || { rm -f "$_z"; err "下载校验失败"; exit 1; }
    fi
    install_zip "$_z"; _rc=$?
    rm -f "$_z"
    exit $_rc ;;
  install-latest-bg)
    rm -f "$STATEDIR/engine.dl" "$STATEDIR/engine.done" 2>/dev/null
    ( _j="$TMP/.eng.latest.$$"
      for _u in "https://cfs-porsche-downloads-q2188366745.oss-cn-hangzhou.aliyuncs.com/porsche/engine.json" "https://raw.githubusercontent.com/ayss2188/porsche-font/main/engine.json"; do
        _mto=8; case "$_u" in *cfs-porsche-downloads*) _mto=3 ;; esac
        command -v curl >/dev/null 2>&1 && curl -fsSL -m "$_mto" -o "$_j" "$_u" 2>/dev/null || fetch_url "$_u" "$_j"
        [ -s "$_j" ] && break
      done
      [ -s "$_j" ] || { echo "ERROR:获取最新版本失败" > "$STATEDIR/engine.done"; exit 1; }
      _url=$(sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_j" | head -n1)
      _sha=$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_j" | head -n1)
      rm -f "$_j"
      [ -n "$_url" ] || { echo "ERROR:最新包没有下载地址" > "$STATEDIR/engine.done"; exit 1; }
      _z="$TMP/.eng.dl.$$.zip"; rm -f "$_z"
      _total=$(command -v curl >/dev/null 2>&1 && curl -sIL "$_url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
      [ -n "$_total" ] || _total=0
      if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 15 -m 900 -o "$_z" "$_url" 2>/dev/null &
        _cpid=$!
        _n=0
        while kill -0 "$_cpid" 2>/dev/null && [ "$_n" -lt 3600 ]; do
          _n=$((_n + 1))
          _sz=$(stat -c %s "$_z" 2>/dev/null || wc -c < "$_z" 2>/dev/null)
          [ -n "$_sz" ] && printf '%s|%s\n' "$_sz" "$_total" > "$STATEDIR/engine.dl"
          sleep 0.3
        done
        wait "$_cpid" 2>/dev/null
        _sz=$(stat -c %s "$_z" 2>/dev/null || wc -c < "$_z" 2>/dev/null)
        if [ -z "$_sz" ] || { [ "$_total" -gt 0 ] && [ "$_sz" -lt "$_total" ]; }; then
          curl -fL --connect-timeout 15 -m 900 -o "$_z" "$_url" 2>/dev/null
          _sz=$(stat -c %s "$_z" 2>/dev/null || wc -c < "$_z" 2>/dev/null)
        fi
        if [ -z "$_sz" ] || { [ "$_total" -gt 0 ] && [ "$_sz" -lt "$_total" ]; }; then
          rm -f "$_z"; echo "ERROR:下载不完整（${_sz:-0}/$_total）" > "$STATEDIR/engine.done"; exit 1
        fi
        printf '%s|%s\n' "$_sz" "$_total" > "$STATEDIR/engine.dl"
      else
        fetch_url "$_url" "$_z" || { echo "ERROR:下载失败" > "$STATEDIR/engine.done"; exit 1; }
      fi
      if [ -n "$_sha" ]; then
        _g=$(sha256sum "$_z" 2>/dev/null | awk '{print $1}')
        [ "$_g" = "$_sha" ] || { rm -f "$_z"; echo "ERROR:下载校验失败" > "$STATEDIR/engine.done"; exit 1; }
      fi
      ( install_zip "$_z" ) >/dev/null 2>&1
      _irc=$?
      if [ "$_irc" = "0" ]; then echo "OK" > "$STATEDIR/engine.done"; else echo "ERROR:安装失败（rc=$_irc）" > "$STATEDIR/engine.done"; fi
      rm -f "$_z"
    ) >/dev/null 2>&1 &
    echo "STARTED" ;;
  check-update)
    status
    _j="$TMP/.eng.latest.$$"
    if fetch_meta "$_j"; then
      _lv=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_j" | head -n1)
      say "LATEST=${_lv:-?}"
      _iv=$(read_prop "$ENG/plugin.prop" version)
      [ -n "$_lv" ] && [ "$_lv" != "$_iv" ] && _engine_ver_gt "$_lv" "$_iv" && say "HAS_UPDATE=1"
    else
      say "ERROR:检查更新失败（网络不通）"
    fi
    rm -f "$_j" ;;
  run)
    shift
    [ -x "$ENG/bin/run" ] || { err "字体工具箱还没安装"; exit 1; }
    CFS_MOD="$MODDIR" CFS_LIB="$LIBROOT" CFS_WORKROOT="$WORKDIR" exec "$ENG/bin/run" "$@" ;;
  *)
    err "用法：status|install|install-local|uninstall|check-update|run" ;;
esac
