#!/system/bin/sh
# 自定义字体切换模块 - 谷歌字体兼容（停用 GMS FontsProvider，立即生效）
# 解决 Chrome / Gmail 等应用英数被 GMS 下载字体覆盖、又恢复默认的问题。
# 仅停用 com.google.android.gms 的 FontsProvider 组件，不卸载、不清缓存、不动账户。
# 只有本模块停用的才会由本模块恢复（记录在字体库目录 .gms_owned），卸载模块时自动恢复。
# 用法：sh google_font.sh status|enable|restore|uninstall

MODDIR=${0%/*}
LIB=/data/adb/custom_font_lib
OWNED="$LIB/.gms_owned"
STATUS_CACHE="$LIB/.gms_status"     # 状态缓存：dumpsys 很慢，WebUI 每次打开不能都跑
CACHE_TTL=21600                     # 缓存有效期 6 小时；点「重新检测」会强制刷新
GMS="com.google.android.gms"
PROVIDER="com.google.android.gms.fonts.provider.FontsProvider"
COMPONENT="$GMS/$PROVIDER"

# 尽量用完整路径，避免 ksu.exec 环境下 PATH 不全
PM="/system/bin/pm";   [ -x "$PM" ] || PM="$(command -v pm 2>/dev/null)"
DUMP="/system/bin/dumpsys"; [ -x "$DUMP" ] || DUMP="$(command -v dumpsys 2>/dev/null)"
AM="/system/bin/am";   [ -x "$AM" ] || AM="$(command -v am 2>/dev/null)"

# 给可能卡住的系统命令加超时（没有 timeout 就直接跑）
tmo() {
  local t="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; else "$@"; fi
}

[ "$(id -u)" = "0" ] || { echo '需要 Root 权限'; exit 1; }

has_gms() { [ -n "$PM" ] && tmo 10 "$PM" path "$GMS" >/dev/null 2>&1; }

# 判断组件当前是否被停用（dumpsys package 很慢，必须加超时）
is_disabled() {
  [ -n "$DUMP" ] && tmo 12 "$DUMP" package "$GMS" 2>/dev/null | grep -i -A60 "disabledComponents" | grep -q "$PROVIDER" && return 0
  return 1
}

# 缓存的状态（过期或不存在则返回空）
cached_status() {
  local age
  [ -f "$STATUS_CACHE" ] || return 1
  age=$(( $(date +%s 2>/dev/null || echo 0) - $(stat -c %Y "$STATUS_CACHE" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$CACHE_TTL" ] 2>/dev/null || return 1
  cat "$STATUS_CACHE" 2>/dev/null
}
put_status() {
  mkdir -p "$LIB" 2>/dev/null
  printf '%s\n' "$1" > "$STATUS_CACHE" 2>/dev/null
}

# 刷新 GMS / 谷歌商店进程，让已缓存的下载字体失效
flush_google() {
  [ -n "$AM" ] && "$AM" force-stop "$GMS" >/dev/null 2>&1
  [ -n "$AM" ] && "$AM" force-stop com.android.vending >/dev/null 2>&1
}

do_restore() {
  local pm_out rc
  pm_out=$("$PM" enable --user 0 "$COMPONENT" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s' "$pm_out" | grep -q "new state"; then
    pm_out=$("$PM" default-state --user 0 "$COMPONENT" 2>&1); rc=$?
  fi
  if [ "$rc" -eq 0 ] || printf '%s' "$pm_out" | grep -q "new state"; then
    rm -f "$OWNED"
    put_status off
    flush_google
    echo "OK：已关闭谷歌字体兼容"
    return 0
  fi
  echo "警告：恢复失败（$pm_out）"
  return 1
}

case "${1:-status}" in
  status)
    # 默认读缓存（避免每次打开 WebUI 都跑 dumpsys）；status fresh 强制重新检测
    if [ "$2" != fresh ]; then
      c=$(cached_status) && { echo "$c"; exit 0; }
    fi
    if ! has_gms; then
      put_status nogms; echo "nogms"; exit 0
    fi
    if is_disabled; then put_status on; echo "on"; else put_status off; echo "off"; fi
    ;;
  enable)
    has_gms || { echo "未检测到 Google Play 服务，无需开启"; exit 0; }
    if is_disabled; then
      # 已经是停用状态（用户自己或其他工具停用的），不记为本模块所有
      put_status on
      echo "OK：谷歌字体兼容本来就是开启状态"
      exit 0
    fi
    pm_out=$("$PM" disable --user 0 "$COMPONENT" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && ! printf '%s' "$pm_out" | grep -q "new state"; then
      pm_out=$("$PM" disable-user --user 0 "$COMPONENT" 2>&1); rc=$?
    fi
    if [ "$rc" -eq 0 ] || printf '%s' "$pm_out" | grep -q "new state"; then
      mkdir -p "$LIB" 2>/dev/null
      date +%s > "$OWNED"
      put_status on
      flush_google
      echo "OK：已开启谷歌字体兼容"
    else
      echo "警告：停用失败（$pm_out）"
    fi
    ;;
  restore)
    has_gms || { echo "未检测到 Google Play 服务"; exit 0; }
    do_restore
    ;;
  uninstall)
    # 卸载模块时：只恢复本模块自己停用的组件
    [ -f "$OWNED" ] || exit 0
    has_gms || { rm -f "$OWNED"; exit 0; }
    do_restore >/dev/null 2>&1
    ;;
  *)
    echo "用法: sh google_font.sh status|enable|restore|uninstall"
    exit 2
    ;;
esac
