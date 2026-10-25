#!/system/bin/sh
# 自定义字体切换模块 - GitHub 在线更新（在手机本地下载并安装，不用电脑）
# 更新信息来自 module.prop 里的 updateJson（仓库里那份 UPDATE-<版本>.json），
# Magisk / KernelSU / APatch 管理器也用同一个地址显示"有更新"。
#
# ★ 2026-10-12 定下的规矩：**只校验版本，不校验指纹。**
#   新版比手上新就装；指纹只记进日志，不作为拒绝安装的理由
#   （真正落地安装的是 Root 管理器，它自己会用账本里的 sha256 校验）。
#
# 用法：
#   sh update.sh check       输出 CUR_VER= CUR_CODE= NEW_VER= NEW_CODE= HAS= ERR=
#   sh update.sh changelog   输出更新日志正文
#   sh update.sh install     下载新版刷机包、用当前 Root 管理器安装（重启生效）

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


# ---------------------------------------------------------------------------
# ★ 2026-10-16（A2）：多地址取更新信息，谁给的版本新就用谁
#
# 为什么必须这么干：module.prop 里的 updateJson 是**随模块发出去的** ——
#   已经装了旧版的人，那份文件永远指着老地址。只改 module.prop 救不了他们。
#   而且 jsDelivr 的 @main 别名缓存 purge 不掉：v1.2.5 发布 3 小时后
#   它仍返回 v1.2.0，用户看到"已是最新"（真机实测，作者手动 purge 才跳过去）。
#
# 顺序：先快后稳 ——
#   ① module.prop 配的（v1.2.6 起 = 作者 Worker，一改就生效）
#   ② 作者 Worker 固定地址（老 module.prop 没有这条，靠它兜底）
#   ③ jsDelivr（老地址，缓存慢但一般能通）
#   ④ raw.githubusercontent.com（最权威，国内常连不上，放最后）
# 只要有一条返回了**更大的 versionCode**，就用它的整份数据。
# ---------------------------------------------------------------------------
UPD_WORKER="https://cfs-report.2188366745q.workers.dev"
UPD_REPO="ayss2188/custom-font-switcher"          # 在 case 里按仓库替换

_read_json() {   # $1=json 文件；把五个字段填进全局
  NEW_VER=$(jstr version "$1")
  NEW_CODE=$(jnum versionCode "$1")
  ZIP_URL=$(jstr zipUrl "$1")
  LOG_URL=$(jstr changelog "$1")
  SHA=$(jstr sha256 "$1")
}

# 试一个地址：成功就写进 $2，并把字段填好
#   用了子 shell 会丢变量，所以这里直接把结果放全局，用 _TRY_CODE 回传
_try_update_url() {   # $1=url  $2=目标文件
  _TRY_CODE=""
  rm -f "$2" 2>/dev/null
  fetch "$1" "$2" 20 || return 1
  [ -s "$2" ] || return 1
  _read_json "$2"
  case "$NEW_CODE" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$ZIP_URL" ] || return 1
  _TRY_CODE="$NEW_CODE"
  return 0
}

load_json() {
  local url base repo
  url=$(prop updateJson)
  case "$url" in
    https://*) ;;
    *) url="" ;;
  esac
  case "$url" in *ayss2188/custom-font-switcher*) url="" ;; esac

  # 本模块的仓库名（用于 Worker 和 raw 两个地址）
  repo="$UPD_REPO"

  NEW_VER=""; NEW_CODE=""; ZIP_URL=""; LOG_URL=""; SHA=""
  _BEST=""; _BEST_SRC=""

  # 依次尝试；记下 versionCode 最大的那个
  for base in \
      "${url:-}" \
      "$([ -n "$repo" ] && printf '%s/update?repo=%s' "$UPD_WORKER" "$repo")" \
      "$([ -n "$repo" ] && printf 'https://cdn.jsdelivr.net/gh/%s@main/update.json' "$repo")" \
      "$([ -n "$repo" ] && printf 'https://raw.githubusercontent.com/%s/main/update.json' "$repo")" ; do
    [ -n "$base" ] || continue
    if _try_update_url "$base" "$TMP/update.json"; then
      if [ -z "$_BEST" ] || [ "$_TRY_CODE" -gt "$_BEST" ] 2>/dev/null; then
        _BEST="$_TRY_CODE"
        _BEST_SRC="$base"
        # 把这份数据固化成"最终结果"（后面可能被更好的覆盖）
        NEW_VER=$(jstr version "$TMP/update.json")
        NEW_CODE=$(jnum versionCode "$TMP/update.json")
        ZIP_URL=$(jstr zipUrl "$TMP/update.json")
        LOG_URL=$(jstr changelog "$TMP/update.json")
        SHA=$(jstr sha256 "$TMP/update.json")
      fi
      # ★ 2026-10-16：**够新就停**。
      #   每个不可达地址要等满 fetch 的超时（20 秒），而作者自己的 Worker
      #   （workers.dev 域名）在部分网络下完全连不上 —— 依次全试最坏 4×20=80 秒，
      #   用户会以为界面卡死。
      #   一旦某个地址给出的版本**已经比本地新**，"有更新"这个结论就拿到了，
      #   后面的地址不必再试。（只有当所有渠道都显示"不比我新"时，
      #   才需要把它们都问一遍，以免漏掉某条渠道上的新版本。）
      if [ -n "$CUR_CODE" ] && [ "$_TRY_CODE" -gt "$CUR_CODE" ] 2>/dev/null; then
        _BEST_SRC="$_BEST_SRC（已够新，提前结束）"
        break
      fi
    fi
  done

  if [ -z "$_BEST" ]; then
    ERR="取不到更新信息（网络不可用，或几个地址都拿不到）"
    NEW_CODE=""
    return 1
  fi
  # 记一笔"最终用的是哪个渠道"，排查时有用（诊断报告会打印）
  printf '%s' "$_BEST_SRC" > "$TMP/update.src" 2>/dev/null
  return 0
}

CUR_VER=$(prop version)
CUR_CODE=$(prop versionCode)
ERR=""

case "${1:-check}" in
  # ★ 2026-10-16 新增：输出当前"开机标识"。
  #   界面用它判断"装完之后到底重启过没有" ——
  #   否则"当前版本 == 最新版本"会被当成"等待重启"，用户明明已经在最新版上，
  #   却永远看到红色「立即重启生效」（真机反馈）。
  bootid)
    boot_id
    ;;

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
    #
    # ★ 上限 60000，**不要再调回 30000**（2026-10-14 修）。
    #   日志文件已经 44,849 字节，30000 会把**后 5 个版本（v1.0.4 及更早）整段截掉**，
    #   而用户看到的是"更新日志就这么长"，不会知道少了 —— 也就是"悄悄少东西"，
    #   这是本项目最忌讳的一类问题。
    #   这个上限本来就该是 60000（早期从 30000 提上去过），换皮时又退回去了，别再退。
    if load_json && [ -n "$LOG_URL" ] && fetch "$LOG_URL" "$TMP/changelog.md" 25; then
      head -c 60000 "$TMP/changelog.md"
      exit 0
    fi
    if [ -s "$MODDIR/changelog.md" ]; then
      echo "（当前无法连接 GitHub，下面是随模块一起装进来的更新日志）"
      echo
      head -c 60000 "$MODDIR/changelog.md"
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
  # ★ 2026-10-14 新增：**后台安装**（真机上"进度条是摆设"的根因修法）。
  #
  # 为什么要拆成 installbg + install（worker）两步：
  #   以前 WebUI 直接 `ksuExec('update.sh install')` —— 而 KernelSU 的 exec 桥是**同步**的，
  #   install 一直跑到下载+安装结束才返回，**整个 JS 线程被占住**，
  #   UI 里那个每 500ms 读 state 的轮询循环**一次都来不及跑**。
  #   用户看到的就是：闪一下"准备中" →（几十 MB 的下载，全黑）→ "安装完成请重启"。
  #   主项目包才 100KB 所以不明显；子项目的包 20~65MB，中间那段长得离谱。
  #
  #   现在：这个分支**立刻返回**（只派生 worker、写个 started 状态），
  #   UI 拿到返回后线程就空了，轮询就能真正画进度条 —— 也就是 camsw_shennong 的做法
  #   （它的 upd_install 也是立刻 `echo "STATE=started"`，活交给 setsid 派生的 worker）。
  installbg)
    # 已经有 worker 在跑就别再来一个（用户连点两下按钮的情况）
    _ps=$(sed -n 's/^pid=//p' "$STATE" 2>/dev/null)
    _st=$(sed -n 's/^stage=//p' "$STATE" 2>/dev/null)
    case "$_st" in
      download|verify|install)
        case "$_ps" in ''|*[!0-9]*) ;; *) kill -0 "$_ps" 2>/dev/null && { echo "OK:running"; exit 0; } ;; esac
        ;;
    esac
    rm -f "$TMP/dl.rc" "$TMP/install.log" "$TMP/worker.rc" 2>/dev/null
    # 先写一个"已开始"状态：即使 worker 还没跑到第一次 prog，UI 也有东西可显示
    printf 'stage=download\ncur=0\ntotal=0\nmsg=正在准备下载\npid=0\n' > "$STATE" 2>/dev/null
    # setsid：让 worker 脱离当前会话，WebUI 那边断开也不会把它带走
    _ss=""; command -v setsid >/dev/null 2>&1 && _ss=setsid
    ( $_ss sh "$MODDIR/update.sh" install >/dev/null 2>&1 < /dev/null; echo $? > "$TMP/worker.rc" ) &
    # ★ 立刻把 **worker 自己的 pid** 写进 state。
    #   不能写 installbg 自己的 $$：那个进程马上就退出了，installstate 里的
    #   `kill -0 $pid` 判活会立刻判成"worker 死了" → 进度条刚出来就报错。
    printf 'stage=download\ncur=0\ntotal=0\nmsg=正在准备下载\npid=%s\n' "$!" > "$STATE" 2>/dev/null
    echo "OK:started"
    ;;
  # 后台安装的状态查询：把 state 文件原样吐出来（UI 直接解析 stage=/cur=/total=/pid=）
  #   顺带做一次"worker 死了但状态还停在 download"的判定 —— 不然进度条会一直转
  installstate)
    if [ -f "$STATE" ]; then
      cat "$STATE" 2>/dev/null
      _ps=$(sed -n 's/^pid=//p' "$STATE" 2>/dev/null)
      _st=$(sed -n 's/^stage=//p' "$STATE" 2>/dev/null)
      case "$_st" in
        download|verify|install)
          case "$_ps" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$_ps" 2>/dev/null || echo "stage=error" ;;
          esac
          ;;
      esac
    else
      echo "stage=none"
    fi
    if [ -f "$TMP/worker.rc" ]; then
      echo "done=$(cat "$TMP/worker.rc" 2>/dev/null)"
    fi
    ;;
  install)
    # 真正的活。WebUI 不再直接调它（会阻塞线程），只由 installbg 派生的 worker 调。
    # 手工在终端里调也没问题（那就变成"前台安装"，行为和以前一样）。
    load_json || { echo "ERROR:$ERR"; exit 1; }
    [ "$NEW_CODE" -gt "${CUR_CODE:-0}" ] 2>/dev/null || [ "$2" = force ] || { echo "ERROR:已是最新版本"; exit 1; }
    ZIP="$TMP/module.zip"
    # 顺带清掉上一次留下的 install.log 和校验状态：不然这次校验失败退出时，
    # 那几个旧文件还在，看起来像"这次装成功了/这次校验过了"
      rm -f "$ZIP" "$STATE" "$TMP/dl.rc" "$TMP/install.log" 2>/dev/null
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

    # -------------------------------------------------------------------------
    # 校验：**只看版本，不看指纹**（2026-10-12 按作者决定）
    #
    # 为什么不再校验 sha256：v1.0.6 那次事故里**包从头到尾都是好的**，被拒是因为我们手上
    #   那份账本来自 CDN 缓存、里面的 sha256 是上一版的 —— 等于我们自己拿旧指纹否掉了好包，
    #   用户看到"sha256 不一致，已取消安装"，只会以为我们发的包坏了。
    #   真正落地安装的是 Root 管理器自己（它会用账本里的 sha256 比对下载到的包），
    #   作者实测管理器里点更新直接就能刷进去 —— 所以这一层是多余的误伤点，去掉。
    #
    # 留下的两个检查都是版本层面的：
    #   · 包里的模块 ID 必须还是我们这个模块
    #   · 包里的版本必须比手上这个新（不让人被降级装回旧版）
    # 指纹只记进日志，供排查用，不影响安装。
    # -------------------------------------------------------------------------
    LOCAL=""
    [ -f "$ZIP" ] && command -v sha256sum >/dev/null 2>&1 && LOCAL=$(sha256sum "$ZIP" 2>/dev/null | cut -d' ' -f1 | tr -d '\r\n')
    F_OUT=$(wc -c < "$ZIP" 2>/dev/null | tr -dc '0-9')
    if [ "$LOCAL" = "$SHA" ] && [ -n "$SHA" ]; then
      echo "指纹：与账本一致（$LOCAL）"
    else
      echo "指纹：与账本不一致（账本=${SHA:-无} 实物=${LOCAL:-未知} 大小=${F_OUT:-?} 字节）—— 不拦截，由管理器在安装时校验"
    fi
    if command -v unzip >/dev/null 2>&1; then
      NID=$(unzip -p "$ZIP" module.prop 2>/dev/null | sed -n 's/^id=//p' | head -n1 | tr -d '\r')
      [ -z "$NID" ] || [ "$NID" = "$(prop id)" ] || { rm -f "$ZIP"; prog error 0 0 "模块 ID 不一致"; echo "ERROR:刷机包的模块 ID 不一致（$NID），已取消安装"; exit 1; }
    fi

    # -------------------------------------------------------------------------
    # 安装阶段：**后台装 + 轮询日志增长**，让 UI 有东西可显示。
    #
    # 以前这里是前台阻塞：写一次 `prog install 0 0`，然后就死等管理器装完。
    # 用户看到的是进度条停在 98%、文字一动不动 —— 几十 MB 的包解包要十几秒到一分钟，
    # 那段时间界面上没有任何"它在动"的证据（真机反馈过）。
    #
    # 现在借用 camsw_shennong 的思路（它读 upd.log）：安装器的输出本来就重定向到
    # `$TMP/install.log`，我们**后台跑它、每秒读一次日志字节数**当作"进展"。
    # 管理器（ksud/magisk）的输出节奏不保证，所以这个数字只用来告诉用户"还在动"，
    # 进度条按**耗时**稳着爬（见下面的 _ipct）—— 不假装知道真实百分比。
    # -------------------------------------------------------------------------
    _ILOG="$TMP/install.log"
    # ★ 2026-10-16（C1）：把上一份日志轮转走，别直接删 ——
    #   真机上排查"升级后状态不对"时，最需要的恰恰是**上一次**安装的输出，
    #   而原来每次 install 都 rm 掉，证据就没了（作者实测踩过）。
    [ -s "$_ILOG" ] && mv -f "$_ILOG" "$TMP/install-prev.log" 2>/dev/null
    rm -f "$_ILOG" "$TMP/install.rc" 2>/dev/null
    case "$(root_manager)" in
      magisk) _INS_CMD="magisk --install-module" ;;
      ksu)    _INS_CMD="/data/adb/ksud module install" ;;
      apatch) _INS_CMD="/data/adb/apd module install" ;;
      *) prog error 0 0 "未识别的管理器"; echo "ERROR:无法识别 Root 管理器，请手动安装：$ZIP"; exit 1 ;;
    esac
    # 注意：把安装器输出接到 install.log —— 它既是排错用的日志，也是进度源。
    ( $_INS_CMD "$ZIP" > "$_ILOG" 2>&1; echo $? > "$TMP/install.rc" ) &
    _IPID=$!
    # 立刻写"安装中"，并且**带上 pid** —— installstate 靠它判活，
    # 少了 pid 会被误判成"worker 已死"（这个坑在 installbg 那边踩过）。
    printf 'stage=install\ncur=0\ntotal=0\nmsg=正在安装（管理器解包中）\npid=%s\n' "$_IPID" > "$STATE" 2>/dev/null
    _iwaited=0
    _MID=$(prop id)
    _PREVVER=$(prop version)          # 安装前的版本：要求"变了"才算装好
    _iok=0
    while [ ! -f "$TMP/install.rc" ]; do
      # ★ 2026-10-23（作者实测"卡在正在安装"）：管理器**装完不返回**，install.rc 永远不写。
      #   所以除了退出码，再加"版本判据"：已装好的模块版本 == 目标版本，
      #   或出现了 modules_update/<id>（管理器已接管待生效），都算装好了。
      _iv=$(sed -n 's/^version=//p' "/data/adb/modules/$_MID/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
      if [ -n "$_MID" ] && [ "$_iv" = "$NEW_VER" ] && [ "$_iv" != "${_PREVVER:-}" ]; then
        _iok=1
        break
      fi
      if [ -n "$_MID" ] && [ -d "/data/adb/modules_update/$_MID" ]; then
        _iok=1
        break
      fi
      # 关机中就别再等了
      [ -n "$(getprop sys.powerctl)$(getprop sys.shutdown.requested)" ] && { kill "$_IPID" 2>/dev/null; break; }
      # ★ 必须判存在：安装器可能几秒内一个字都不吐，这时 `wc -c` 会**往 stderr 报错**
      #   （"can't open .../install.log: no such file"），最终混进用户看到的输出里。
      if [ -f "$_ILOG" ]; then
        _iby=$(wc -c < "$_ILOG" 2>/dev/null | tr -dc '0-9')
      else
        _iby=0
      fi
      # 进度条按耗时稳着爬：0% → 97%（最多 300 秒爬满），
      #   宁可"慢慢爬"也不要"跳一下停住"——后者看着像死机。
      # ★ 2026-10-18（作者反馈「进度条一秒到头」）：
      #   原来是线性爬：`waited * 97 / 300` —— 300 秒才爬满。
      #   而真机安装只要 20~60 秒，于是进度条才走到 6%~19% 就"突然完成"，
      #   看着像"根本没动"。反过来网慢下载时又瞬间冲到 97% 然后不动。
      #   现在用**渐近曲线** pct = 97 * t / (t + 40)：
      #       10 秒 → 19%    30 秒 → 41%    60 秒 → 58%
      #      120 秒 → 73%   300 秒 → 86%
      #   前快后慢、越来越慢但不会停，跟真实解包（先小文件后大字体）更贴。
      _ipct=$(( _iwaited * 97 / (_iwaited + 40) ))
      [ "$_ipct" -gt 97 ] && _ipct=97
      printf 'stage=install\ncur=%s\ntotal=%s\nmsg=正在安装（管理器解包中）\npid=%s\n' \
        "${_iby:-0}" "$_ipct" "$_IPID" > "$STATE" 2>/dev/null
      sleep 1
      _iwaited=$((_iwaited + 1))
      if [ "$_iwaited" -ge 180 ]; then
        case "$_IPID" in ''|*[!0-9]*|0|1) ;; *) kill "$_IPID" 2>/dev/null ;; esac
        break
      fi
    done
    if [ "${_iok:-0}" = 1 ] && [ ! -f "$TMP/install.rc" ]; then
      # 版本已对得上（管理器装好了只是没返回）→ 直接收工，别再等
      wait "$_IPID" 2>/dev/null
      rc=0
    else
      wait "$_IPID" 2>/dev/null
      rc=$(cat "$TMP/install.rc" 2>/dev/null)
    fi
    # 超时但版本已经对得上 → 也当成功（真机常见：装完了管理器不回话）
    if [ -z "$rc" ] && [ "${_iok:-0}" = 1 ]; then rc=0; fi
    rm -f "$TMP/install.rc" 2>/dev/null
    if [ "$rc" = 0 ]; then
      rm -f "$ZIP"
      prog finished 0 0 "安装完成，重启后生效"
      echo "OK:$NEW_VER"
    else
      # ★ 2026-10-16（C2）：把**完整**安装日志复制到 Download ——
      #   原来只把末 3 行拼成一行塞进进度条，ksud 的多行报错常被截掉关键原因，
      #   用户只能重来、作者也拿不到证据。现在留一份完整文件，界面能提示去哪看。
      #   顺手（C4）：区分"存储空间不足"和"网络/其他"——子项目的包有 63MB，
      #   低存储设备上会撞上，而原来的提示只会说"下载或安装失败"。
      _LOGOUT="/data/media/0/Download/安装日志.txt"
      [ -d /data/media/0/Download ] || _LOGOUT="$TMP/install.log"
      {
        echo "===== 安装失败时的完整日志 ====="
        echo "时间：$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        echo "模块：$(prop version) / $(prop versionCode)"
        echo "退出码：${rc:-?}"
        echo
        echo "----- 本次安装器输出（install.log）-----"
        cat "$_ILOG" 2>/dev/null
        echo
        echo "----- 上一次安装器输出（install-prev.log）-----"
        cat "$TMP/install-prev.log" 2>/dev/null
      } > "$_LOGOUT" 2>/dev/null

      # 空间不足？看一眼 /data 剩余再决定怎么说
      _why=""
      _free=$(free_kb /data 2>/dev/null)
      case "$_free" in ''|*[!0-9]*) _free="" ;; esac
      if [ -n "$_free" ] && [ "$_free" -lt 204800 ] 2>/dev/null; then
        _why="存储空间不足（/data 只剩 $(( _free / 1024 ))MB，安装需要临时空间）"
      elif [ ! -s "$_ILOG" ]; then
        _why="管理器没有输出（可能是下载不完整，或管理器拒绝了安装）"
      else
        _why="$(tail -n 3 "$_ILOG" 2>/dev/null | tr '\n' ' ')"
      fi

      prog error 0 0 "安装失败：$_why"
      echo "ERROR:安装失败：$_why"
      echo "      完整日志已存到：$_LOGOUT"
      echo "      （把它发给作者就能定位）"
      exit 1
    fi
    ;;
  *)
    echo "用法: sh update.sh check|changelog|install"
    exit 2
    ;;
esac
