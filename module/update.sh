#!/system/bin/sh
# 自定义字体切换模块 - GitHub 在线更新（在手机本地下载并安装，不用电脑）
# 更新信息来自 module.prop 里的 updateJson（GitHub 仓库里的 update.json），
# Magisk / KernelSU / APatch 管理器也会用同一个地址显示"有更新"。
#
# 用法：
#   sh update.sh check       输出 CUR_VER= CUR_CODE= NEW_VER= NEW_CODE= HAS= ERR=
#   sh update.sh changelog   输出更新日志正文
#   sh update.sh install     下载新版刷机包、校验后用当前 Root 管理器安装（重启生效）

MODDIR=$(cd "$(dirname "$0")" && pwd)
. "$MODDIR/common.sh"
TMP="$LIB/.update"
mkdir -p "$TMP" 2>/dev/null
STATE="$TMP/state"      # 进度状态文件，WebUI 会轮询它画进度条

prop() { sed -n "s/^$1=//p" "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r'; }

# 写进度：prog <阶段> <已下载字节> <总字节> <提示>
prog() { printf 'stage=%s\ncur=%s\ntotal=%s\nmsg=%s\n' "$1" "${2:-0}" "${3:-0}" "${4:-}" > "$STATE" 2>/dev/null; }

# 试探下载地址的总字节数（拿不到就返回 0，WebUI 会退化成"已下载 xx MB"）
http_size() {
  local n=""
  if command -v curl >/dev/null 2>&1; then
    n=$(curl -sIL --connect-timeout 10 -m 30 "$1" 2>/dev/null | tr -d '\r' \
        | grep -i '^content-length:' | tail -n1 | tr -dc '0-9')
  fi
  echo "${n:-0}"
}

# fetch <地址> <输出文件> [最长秒数]
# 注意超时：检查更新/更新日志用短超时（否则网络差时会把 WebUI 卡住好几分钟），
# 下载刷机包才用长超时。
fetch() {
  local url bb mt
  url="$1"; mt="${3:-60}"
  rm -f "$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 8 -m "$mt" -o "$2" "$url" 2>/dev/null && [ -s "$2" ] && return 0
  fi
  bb=$(find_busybox)
  # wget 只有"-T 单次读超时"，没有总时长上限：网络卡在半路时它会一直挂着，
  # 这个进程又是在后台跑的（父脚本早退了）→ 会一直活到关机窗口里。
  # 所以有 timeout 就套一层总超时，没有就用 -T（至少别无限等）。
  if [ -n "$bb" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout "$mt" "$bb" wget -q -T 12 -O "$2" "$url" 2>/dev/null && [ -s "$2" ] && return 0
    else
      "$bb" wget -q -T 12 -O "$2" "$url" 2>/dev/null && [ -s "$2" ] && return 0
    fi
  fi
  if command -v wget >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      timeout "$mt" wget -q -T 12 -O "$2" "$url" 2>/dev/null && [ -s "$2" ] && return 0
    else
      wget -q -T 12 -O "$2" "$url" 2>/dev/null && [ -s "$2" ] && return 0
    fi
  fi
  rm -f "$2"
  return 1
}

# 简易 JSON 取值（update.json 结构固定，不需要完整解析器）
jstr() { tr -d '\r\n' < "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }
jnum() { tr -d '\r\n' < "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"; }

load_json() {
  local url
  url=$(prop updateJson)
  case "$url" in
    https://*) ;;
    *) ERR="module.prop 里没有配置 updateJson"; return 1 ;;
  esac
  case "$url" in *__REPO__*) ERR="作者还没有配置 GitHub 仓库地址"; return 1 ;; esac
  fetch "$url" "$TMP/update.json" 20 || { ERR="无法连接 GitHub，请检查网络后重试"; return 1; }
  NEW_VER=$(jstr version "$TMP/update.json")
  NEW_CODE=$(jnum versionCode "$TMP/update.json")
  ZIP_URL=$(jstr zipUrl "$TMP/update.json")
  LOG_URL=$(jstr changelog "$TMP/update.json")
  SHA=$(jstr sha256 "$TMP/update.json")
  [ -n "$NEW_CODE" ] && [ -n "$ZIP_URL" ] || { ERR="update.json 格式不正确"; NEW_CODE=""; return 1; }
  return 0
}

CUR_VER=$(prop version)
CUR_CODE=$(prop versionCode)
ERR=""

case "${1:-check}" in
  check)
    HAS=0
    if load_json && [ "$NEW_CODE" -gt "${CUR_CODE:-0}" ] 2>/dev/null; then HAS=1; fi
    echo "CUR_VER='$CUR_VER'"
    echo "CUR_CODE='$CUR_CODE'"
    echo "NEW_VER='$NEW_VER'"
    echo "NEW_CODE='$NEW_CODE'"
    echo "HAS='$HAS'"
    echo "ERR='$ERR'"
    ;;
  changelog)
    # 优先用网上的（永远是最新）；拿不到就用随模块打包的那一份 ——
    # raw.githubusercontent.com 在国内经常连不上，没网时至少还能看到本版的更新说明
    if load_json && [ -n "$LOG_URL" ] && fetch "$LOG_URL" "$TMP/changelog.md" 25; then
      head -c 30000 "$TMP/changelog.md"
      exit 0
    fi
    if [ -s "$MODDIR/changelog.md" ]; then
      echo "（当前无法连接 GitHub，下面是随模块一起装进来的更新日志）"
      echo
      head -c 30000 "$MODDIR/changelog.md"
      exit 0
    fi
    echo "ERROR:下载更新日志失败（也找不到随模块打包的 changelog.md）"
    exit 1
    ;;
  # 后台检查更新：立刻返回，网络请求丢到后台做（WebUI 打开时用它，避免占住界面线程）
  # 结果写到 $TMP/check.out，界面用下面的 checkstate 轮询（每次只是一个 cat）
  bgcheck)
    rm -f "$TMP/check.out" "$TMP/check.rc" 2>/dev/null
    ( sh "$MODDIR/update.sh" check > "$TMP/check.out" 2>&1; echo $? > "$TMP/check.rc" ) &
    echo "OK:started"
    ;;
  checkstate)
    if [ -f "$TMP/check.rc" ]; then
      echo "READY=1"
      cat "$TMP/check.out" 2>/dev/null
    else
      echo "READY=0"
    fi
    ;;
  install)
    load_json || { echo "ERROR:$ERR"; exit 1; }
    [ "$NEW_CODE" -gt "${CUR_CODE:-0}" ] 2>/dev/null || [ "$2" = force ] || { echo "ERROR:已是最新版本"; exit 1; }
    ZIP="$TMP/module.zip"
    rm -f "$ZIP" "$STATE" "$TMP/dl.rc" 2>/dev/null
    TOTAL=$(http_size "$ZIP_URL")
    prog download 0 "$TOTAL" "正在下载刷机包"
    # 后台下载 + 每秒刷新进度。
    # 注意：不能用 kill -0 判断子进程是否结束 —— 子进程变成僵尸时 kill -0 仍返回成功，
    # 会死循环卡住（表现为"进度条一直转圈，更新不动"）。改成看结束标记文件。
    ( fetch "$ZIP_URL" "$ZIP" 180; echo $? > "$TMP/dl.rc" ) &
    DLPID=$!
    waited=0
    while [ ! -f "$TMP/dl.rc" ]; do
      # 关机中就别再下载了（后台下载进程会一直活到关机窗口里）
      [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && { kill "$DLPID" 2>/dev/null; break; }
      cur=$(wc -c < "$ZIP" 2>/dev/null | tr -d ' \n')
      prog download "${cur:-0}" "$TOTAL" "正在下载刷机包"
      sleep 1
      waited=$((waited + 1))
      if [ "$waited" -ge 600 ]; then
        # 校验 pid 再杀：pid 只可能是 $!，但万一是空的/0/1 就别动
        case "$DLPID" in ''|*[!0-9]*|0|1) ;; *) kill "$DLPID" 2>/dev/null ;; esac
        break
      fi
    done
    wait "$DLPID" 2>/dev/null
    rc=$(cat "$TMP/dl.rc" 2>/dev/null)
    rm -f "$TMP/dl.rc" 2>/dev/null
    if [ ! -s "$ZIP" ] || { [ -n "$rc" ] && [ "$rc" != 0 ]; }; then
      prog error 0 "$TOTAL" "下载失败"
      echo "ERROR:下载刷机包失败，请检查网络后重试"; exit 1
    fi
    prog verify 0 0 "正在校验刷机包"

    # 校验：是 zip、体积合理、sha256 一致、模块 id 一致
    [ "$(head -c 2 "$ZIP")" = PK ] || { rm -f "$ZIP"; prog error 0 0 "不是 zip"; echo "ERROR:下载的文件不是 zip（网络可能返回了错误页面）"; exit 1; }
    [ "$(wc -c < "$ZIP")" -gt 10240 ] || { rm -f "$ZIP"; prog error 0 0 "文件不完整"; echo "ERROR:下载的文件不完整"; exit 1; }
    if [ -n "$SHA" ] && command -v sha256sum >/dev/null 2>&1; then
      [ "$(sha256sum "$ZIP" | cut -d' ' -f1)" = "$SHA" ] || { rm -f "$ZIP"; prog error 0 0 "sha256 不一致"; echo "ERROR:校验失败（sha256 不一致），已取消安装"; exit 1; }
    fi
    if command -v unzip >/dev/null 2>&1; then
      NID=$(unzip -p "$ZIP" module.prop 2>/dev/null | sed -n 's/^id=//p' | head -n1 | tr -d '\r')
      [ -z "$NID" ] || [ "$NID" = "$(prop id)" ] || { rm -f "$ZIP"; prog error 0 0 "模块 ID 不一致"; echo "ERROR:刷机包的模块 ID 不一致（$NID），已取消安装"; exit 1; }
    fi

    prog install 0 0 "正在安装（管理器解包中）"
    case "$(root_manager)" in
      magisk) magisk --install-module "$ZIP" > "$TMP/install.log" 2>&1 ;;
      ksu)    /data/adb/ksud module install "$ZIP" > "$TMP/install.log" 2>&1 ;;
      apatch) /data/adb/apd module install "$ZIP" > "$TMP/install.log" 2>&1 ;;
      *) prog error 0 0 "未识别的管理器"; echo "ERROR:无法识别 Root 管理器，请手动安装：$ZIP"; exit 1 ;;
    esac
    rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$ZIP"
      prog finished 0 0 "安装完成，重启后生效"
      echo "OK:$NEW_VER"
    else
      prog error 0 0 "安装失败"
      echo "ERROR:安装失败（$(tail -n 3 "$TMP/install.log" | tr '\n' ' ')）"
      exit 1
    fi
    ;;
  *)
    echo "用法: sh update.sh check|changelog|install"
    exit 2
    ;;
esac
