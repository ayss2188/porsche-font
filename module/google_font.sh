#!/system/bin/sh
# 谷歌字体兼容（停用 GMS 的 FontsProvider）—— 开关 + 记录 + 开机复查
#
# ★ 状态判据**照搬已经在真机上跑通的那份实现**（姊妹项目 D:\ds2 的 google_font.sh），
#   就一行：
#     dumpsys package com.google.android.gms | grep -i -A60 "disabledComponents" | grep -q "$PROVIDER"
#   不做"声明检查"、不猜 dumpsys 排版、不去 APK 里捞类名、不读 package-restrictions.xml。
#   教训：多一层自己发明的判断，就多一种把"没有"误判成"有"、或反过来拒绝动手的机会。
#   开启/关闭也一样：**以 pm 的返回为准**（成不成由它说了算），成功就认账，不再拿 dumpsys 去"复核"。
#
# 我们在此之上只保留两件不影响判据的事：
#   ① 记录（哪个用户 / 原状态 / 时间）→ 卸载时能恢复、关闭时按原状态还原、开机复查知道是我们的
#   ② 开机复查：GMS 更新会把组件覆盖项重置 → 开机时看状态，不是"已停用"就补一次
#
# 用法：sh google_font.sh status [fresh] | enable | restore | reconcile | diag | uninstall

LIB=${LIB:-/data/adb/custom_font_lib}
JOURNAL="$LIB/.gms_journal.conf"      # user= / original= / changedAt=
STATUS_CACHE="$LIB/.gms_status"       # 状态缓存（dumpsys 慢，界面每次打开不能都跑）
CACHE_ON_FLAG="$LIB/.gms_cache_on"    # ★ 缓存桥接的启用标志（gms_cache.sh 开机时看它）
GFLOG="$LIB/.gms_log"                 # 做过什么
CACHE_TTL=${CACHE_TTL:-21600}         # 缓存 6 小时；「重新检测」= status fresh 强制刷新
BOOTID_FILE=${CFS_BOOTID_FILE:-/proc/sys/kernel/random/boot_id}

GMS="com.google.android.gms"
PROVIDER="com.google.android.gms.fonts.provider.FontsProvider"
COMPONENT="$GMS/$PROVIDER"
VENDING="com.android.vending"

# 尽量用完整路径（ksu.exec 环境 PATH 不一定全）；测试可用环境变量指到桩上
PM=${PM:-/system/bin/pm};         [ -x "$PM" ]   || PM="$(command -v pm 2>/dev/null)"
DUMP=${DUMP:-/system/bin/dumpsys}; [ -x "$DUMP" ] || DUMP="$(command -v dumpsys 2>/dev/null)"
AM=${AM:-/system/bin/am};         [ -x "$AM" ]   || AM="$(command -v am 2>/dev/null)"

mkdir -p "$LIB" 2>/dev/null

# 超时包装：优先用外部 timeout（测试可覆盖成垫片），没有就直接跑
tmo() {
  # 给可能卡住的系统命令加超时。三层，从最可靠到最保守：
  #   ① CFS_TMO_BIN（外部指定）
  #   ② 系统自带 timeout（Android 7+ 的 toybox 基本都有）
  #   ③ 纯 shell 看门狗（只有①②都没有时才用）
  # ★ 看门狗的关键细节（1.0.9.2，踩过两次）：
  #   · 只 kill 主进程是不够的 —— `dumpsys` 这类命令卡在内核里时不响应 TERM，
  #     它 fork 出来的子进程还在，管道另一端（grep/head）就一直等，等于没超时。
  #   · 但**无条件** `kill -TERM -$pid`（杀进程组）更危险：busybox 的 setsid 在
  #     "当前进程已是组长"时会失败，后台命令就与脚本同组 → 杀组 = **把调用方自己杀掉**
  #     （真机症状：报告正文生成了，最后写文件那一步却是空的）。
  #   · 所以：**先看 setsid 有没有真的成功**；成功才杀组，失败只杀单个 pid。
  local t="$1"; shift
  if [ -n "$CFS_TMO_BIN" ] && [ -x "$CFS_TMO_BIN" ]; then "$CFS_TMO_BIN" "$t" "$@"; return $?; fi
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; return $?; fi
  # ---- 以下只在"没有 timeout"时执行 ----
  local o pid wd rc own=0
  o="${LIB:-/data/local/tmp}/.tmo.out"
  mkdir -p "${o%/*}" 2>/dev/null
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$o" 2>/dev/null &
    pid=$!
    # 新会话的组长 pid 就等于它自己；用它当"能不能杀组"的判据
    [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ] && own=1
  else
    "$@" >"$o" 2>/dev/null &
    pid=$!
  fi
  (
    _i=0
    while [ "$_i" -lt "$t" ]; do
      sleep 1
      kill -0 "$pid" 2>/dev/null || exit 0
      _i=$((_i + 1))
    done
    if [ "$own" = 1 ]; then
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    else
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill -TERM "$wd" 2>/dev/null
  cat "$o" 2>/dev/null
  rm -f "$o" 2>/dev/null
  [ "$rc" = 143 ] || [ "$rc" = 137 ] && rc=124
  return "$rc"
}
need_root() {
  [ "$(id -u 2>/dev/null)" = "0" ] && return 0
  [ "$CFS_ALLOW_NONROOT" = 1 ] && return 0      # 沙箱测试逃生门
  echo '需要 Root 权限'
  return 1
}
log_gf() {
  mkdir -p "$LIB" 2>/dev/null
  printf 'time=%s boot=%s %s\n' "$(date +%s 2>/dev/null)" "$(cat "$BOOTID_FILE" 2>/dev/null)" "$*" >> "$GFLOG" 2>/dev/null
  [ -f "$GFLOG" ] && { tail -n 50 "$GFLOG" > "$GFLOG.tmp.$$" 2>/dev/null && mv -f "$GFLOG.tmp.$$" "$GFLOG" 2>/dev/null; }
}
has_gms() { [ -n "$PM" ] && tmo 10 "$PM" path "$GMS" >/dev/null 2>&1; }
gms_present() {
  has_gms && return 0
  [ -d "/data/data/$GMS" ] || [ -d "/data/user/0/$GMS" ] || [ -d "/data/user_de/0/$GMS" ]
}

# ---------------------------------------------------------------------------
# 状态判据（照搬跑通的那份，一行搞定）
# ---------------------------------------------------------------------------
is_disabled() {
  [ -n "$DUMP" ] || return 1
  tmo 12 "$DUMP" package "$GMS" 2>/dev/null | grep -i -A60 "disabledComponents" | grep -q "$PROVIDER"
}

cached_status() {
  local age
  [ -f "$STATUS_CACHE" ] || return 1
  age=$(( $(date +%s 2>/dev/null || echo 0) - $(stat -c %Y "$STATUS_CACHE" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$CACHE_TTL" ] 2>/dev/null || return 1
  cat "$STATUS_CACHE" 2>/dev/null
}
put_status() { mkdir -p "$LIB" 2>/dev/null; printf '%s\n' "$1" > "$STATUS_CACHE" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 记录（仅用于"我们停用过"这件事：卸载恢复 / 按原状态还原 / 开机复查）
# ---------------------------------------------------------------------------
journal_val() { [ -f "$JOURNAL" ] && sed -n "s/^$1=//p" "$JOURNAL" 2>/dev/null | head -n1; }
write_journal() {   # $1=用户  $2=原状态(0/1/unknown)
  mkdir -p "$LIB" 2>/dev/null
  {
    printf 'user=%s\n' "$1"
    printf 'original=%s\n' "$2"
    printf 'changedAt=%s\n' "$(date +%s 2>/dev/null)"
  } > "$JOURNAL" 2>/dev/null
  chmod 600 "$JOURNAL" 2>/dev/null
}
owned() { [ -f "$JOURNAL" ]; }

# 原状态怎么读：只有 dumpsys 能看到"启用/默认"的区别，读不到就记 unknown（关闭时按「启用」还原）
original_state() {
  if is_disabled; then echo 2; return 0; fi
  [ -n "$DUMP" ] || { echo unknown; return 0; }
  if tmo 12 "$DUMP" package "$GMS" 2>/dev/null | grep -i -A60 "enabledComponents" | grep -q "$PROVIDER"; then
    echo 1
  else
    echo 0
  fi
}

bridge() {   # 商店缓存桥接（让商店也生效）；测试环境不跑
  [ -z "$CFS_ALLOW_NONROOT" ] || return 0
  [ -f "$MODDIR/gms_cache.sh" ] || return 0
  # ★ 2026-10-16：这里传 force —— 因为调用方是**界面上的按钮**（用户显式开启/关闭）。
  #   而 gms_cache.sh 的 do_on 现在有一道门槛：账本不在就拒绝自动挂载
  #   （修"关掉了还被开机脚本挂回去"那个 bug）。
  #   用户点「开启兼容」时账本还没建立，不传 force 就会被那道门槛挡掉。
  tmo 60 sh "$MODDIR/gms_cache.sh" "$1" force >/dev/null 2>&1
}
cur_user() {
  local u=""
  [ -n "$AM" ] && u=$(tmo 5 "$AM" get-current-user 2>/dev/null | tr -d '[:space:]')
  case "$u" in ''|*[!0-9]*) u="" ;; esac
  printf '%s' "$u"
}

# 清掉消费者进程，让组件停用立刻生效（用 am kill 只清后台；有频率限制，别反复折腾）
kill_consumers() {
  local u="$1" stamp n
  [ -n "$AM" ] || return 0
  stamp="$LIB/.gms_lastkill"
  if [ -f "$stamp" ]; then
    n=$(sed -n 's/^count=//p' "$stamp" 2>/dev/null); n=${n:-0}
    local last boot now bootnow
    last=$(sed -n 's/^time=//p' "$stamp" 2>/dev/null); last=${last:-0}
    boot=$(sed -n 's/^boot=//p' "$stamp" 2>/dev/null)
    bootnow=$(cat "$BOOTID_FILE" 2>/dev/null)
    now=$(date +%s 2>/dev/null || echo 0)
    if [ "$boot" = "$bootnow" ]; then
      [ "$n" -ge 4 ] 2>/dev/null && return 0                  # 同一次开机最多 4 次
      [ $((now - last)) -lt 60 ] 2>/dev/null && return 0       # 两次之间至少 60 秒
    else
      n=0
    fi
  else
    n=0
  fi
  n=$((n + 1))
  printf 'count=%s\ntime=%s\nboot=%s\n' "$n" "$(date +%s 2>/dev/null)" "$(cat "$BOOTID_FILE" 2>/dev/null)" > "$stamp" 2>/dev/null
  tmo 10 "$AM" kill --user "$u" "$GMS"     >/dev/null 2>&1
  tmo 10 "$AM" kill --user "$u" "$VENDING" >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------------------
# status：缓存 → 状态判据 → （判据说"没停用"但我们有记录 = 被 GMS 顶回去了，仍按我们的记录报 on）
#   只有 on / off / foreign / nogms 四种，**不引入"未知"**（判据读不到就当"没停用"，
#   这跟跑通的那份行为一致；少一个状态就少一种把用户绕晕的可能）
# ---------------------------------------------------------------------------
do_status() {
  local fresh="$1" c
  # ★ 1.0.9.2：**只读缓存模式**（报告专用）。设了 CFS_GF_CACHED_ONLY=1 就绝不跑 dumpsys。
  #   为什么必须加这个口子：真机实测「诊断报告卡在谷歌字体兼容」——
  #   `dumpsys package com.google.android.gms` 在 Android 17 / HyperOS 上要跑**几分钟**，
  #   而诊断报告**根本不需要实时值**（界面有专门的「重新检测」按钮）。
  #   判据全部取自本地文件，毫秒级：
  #     · 有状态缓存文件 → 直接用它的值
  #     · 没有缓存：有账本（我们停用过）→ on；否则 → off（或没装 GMS → nogms）
  if [ "${CFS_GF_CACHED_ONLY:-0}" = 1 ]; then
    c=$(cached_status) && { printf '%s\n' "$c"; return 0; }
    if [ -f "$STATUS_CACHE" ]; then
      c=$(tr -d '[:space:]' < "$STATUS_CACHE" 2>/dev/null)
      case "$c" in on|off|foreign|nogms) printf '%s\n' "$c"; return 0 ;; esac
    fi
    # 没缓存：用"账本 + GMS 是否存在"粗判（都是本地文件判断，不起进程）
    if [ ! -d "/data/data/$GMS" ] && [ ! -d "/data/user/0/$GMS" ] && [ ! -d "/data/user_de/0/$GMS" ]; then
      printf 'nogms\n'; return 0
    fi
    if owned; then printf 'on\n'; else printf 'off\n'; fi
    return 0
  fi
  if [ "$fresh" != fresh ]; then
    c=$(cached_status) && { printf '%s\n' "$c"; return 0; }
  fi
  if ! gms_present; then put_status nogms; printf 'nogms\n'; return 0; fi
  if is_disabled; then
    if owned; then put_status on; printf 'on\n'
    else put_status foreign; printf 'foreign\n'; fi
    # ★ 2026-10-16：用户点了「开启兼容」→ 记下"缓存桥接要开着"。
    #   原来这里直接 return 0，**既没写标志也没调 bridge on** ——
    #   于是"用户点了开启、桥接却没被标记"；而如果库目录里还留过老账本，
    #   开机脚本就会照挂，用户看到"我没开啊，怎么还有挂载"（真机反馈过）。
    #   组件是谁停的不影响"用户要桥接"这个意图，所以两条路都写。
    mkdir -p "$LIB" 2>/dev/null
    : > "$CACHE_ON_FLAG" 2>/dev/null
    return 0
  fi
  if owned; then put_status on; printf 'on\n'; return 0; fi   # pm 说过成功 = 就是我们开的
  put_status off; printf 'off\n'
}

# ---------------------------------------------------------------------------
# enable：以 pm 的返回为准（不拿 dumpsys 复核）
# ---------------------------------------------------------------------------
do_enable() {
  local u st out rc
  need_root || return 1
  gms_present || { printf '未检测到 Google Play 服务，无需开启\n'; return 0; }
  [ -n "$PM" ] || { printf 'ERROR:这台机器上读不到 pm 命令，无法安全地改组件状态\n'; return 1; }
  u=$(cur_user)
  [ -n "$u" ] || { printf 'ERROR:读不到当前用户（am get-current-user 失败），为安全起见没有动手\n'; return 1; }
  if is_disabled; then
    if owned; then printf 'OK：谷歌字体兼容本来就是开启状态\n'
    else printf '这个组件已经被停用了（不是本模块操作的）—— 本模块不会接管别人的设置。\n'; fi
    put_status on
    return 0
  fi
  st=$(original_state)
  write_journal "$u" "$st"
  out=$(tmo 20 "$PM" disable --user "$u" "$COMPONENT" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q "new state"; then
    out=$(tmo 20 "$PM" disable-user --user "$u" "$COMPONENT" 2>&1); rc=$?
  fi
  if [ "$rc" -eq 0 ] || printf '%s' "$out" | grep -q "new state"; then
    put_status on
    kill_consumers "$u"
    bridge on
    log_gf "已开启谷歌字体兼容（用户 $u，原状态 $st）"
    printf 'OK：已开启谷歌字体兼容（已清掉后台进程，现在就该生效了）\n'
  else
    rm -f "$JOURNAL" 2>/dev/null                     # 失败就回滚记录
    printf 'ERROR:停用失败 —— 已回滚记录、什么都没改。pm 的原话：\n  %s\n' \
      "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# restore：按记录里的原状态还原（0→default-state / 1→enable / unknown→enable）
# ---------------------------------------------------------------------------
do_restore() {
  local u orig out rc ok=0 i
  need_root || return 1
  u=$(journal_val user); orig=$(journal_val original)
  case "$u" in ''|*[!0-9]*) u=$(cur_user); [ -n "$u" ] || u=0 ;; esac
  case "$orig" in 0|1) ;; *) orig=1 ;; esac     # 读不到原状态 → 按「启用」还原（并说明）
  [ -n "$PM" ] || { printf 'ERROR:读不到 pm 命令，无法还原\n'; return 1; }
  for i in 1 2 3; do
    if [ "$orig" = 0 ]; then
      out=$(tmo 20 "$PM" default-state --user "$u" "$COMPONENT" 2>&1); rc=$?
    else
      out=$(tmo 20 "$PM" enable --user "$u" "$COMPONENT" 2>&1); rc=$?
    fi
    if [ "$rc" -eq 0 ] || printf '%s' "$out" | grep -q "new state"; then ok=1; break; fi
    sleep 2
  done
  # ★ 先删"缓存桥接启用标志"（无论组件还原成不成功）：
  #   用户点了「关闭兼容」，就不该再有桥接挂载 ——
  #   否则开机脚本还会照挂，用户看到"关了还在挂"（真机反馈过）。
  rm -f "$CACHE_ON_FLAG" 2>/dev/null
  if [ "$ok" = 1 ]; then
    rm -f "$JOURNAL" 2>/dev/null
    put_status off
    kill_consumers "$u"
    bridge off
    log_gf "已关闭谷歌字体兼容（用户 $u，按原状态 $orig 还原）"
    [ "$(journal_val original)" = unknown ] && printf 'OK：已关闭谷歌字体兼容（原来的状态没读到，按「启用」还原）\n' || printf 'OK：已关闭谷歌字体兼容\n'
    return 0
  fi
  printf 'ERROR:恢复失败 —— 记录已保留（重装模块或下次开机会自动再试）。pm 的原话：\n  %s\n' \
    "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  return 1
}

# ---------------------------------------------------------------------------
# reconcile：开机复查（GMS 更新会把组件覆盖项重置）—— 只按状态判
# ---------------------------------------------------------------------------
do_reconcile() {
  local u out rc
  need_root || return 1
  owned || return 0
  gms_present || return 0
  is_disabled && return 0                    # 还是"已停用"，什么都不用做
  u=$(journal_val user); case "$u" in ''|*[!0-9]*) u=$(cur_user) ;; esac
  [ -n "$u" ] || return 0
  out=$(tmo 20 "$PM" disable --user "$u" "$COMPONENT" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] || printf '%s' "$out" | grep -q "new state"; then
    put_status on
    mkdir -p "$LIB" 2>/dev/null
    : > "$CACHE_ON_FLAG" 2>/dev/null
    log_gf "复查：组件不是「已停用」（多半被 GMS 更新重置），已补上（用户 $u）"
  else
    log_gf "复查：组件不是「已停用」，补停用失败（用户 $u），下次开机再试"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# diag：只读诊断（体检报告用）—— 只讲事实，不下结论
# ---------------------------------------------------------------------------
do_diag() {
  local u
  if ! gms_present; then echo "gms=未安装（这台机器没有 Google Play 服务）"; return 0; fi
  echo "gms=已安装  包路径=$(tmo 10 "$PM" path "$GMS" 2>/dev/null | head -n1)"
  echo "组件=$COMPONENT"
  if is_disabled; then echo "组件状态=已停用（dumpsys 里能在 disabledComponents 找到）"
  else echo "组件状态=没停用（或这份 dumpsys 里读不出来）"; fi
  if owned; then
    echo "本模块的记录=有（用户 $(journal_val user)，原状态 $(journal_val original)，时间 $(journal_val changedAt)）"
  else
    echo "本模块的记录=没有（本模块没有停用过它）"
  fi
  u=$(cur_user); echo "当前用户=${u:-读不到}"
  echo "最近动作："
  [ -f "$GFLOG" ] && tail -n 3 "$GFLOG" | while IFS= read -r l; do echo "  $l"; done
# 商店缓存桥接的现场（以前漏接了这一块，报告里看不到 found=/已顶替）
  if [ -f "$MODDIR/gms_cache.sh" ]; then
    echo "商店缓存桥接："
    tmo 30 sh "$MODDIR/gms_cache.sh" diag 2>/dev/null | while IFS= read -r _l; do echo "  $_l"; done
  else
    echo "商店缓存桥接：没有 gms_cache.sh（装的还是旧版包）"
  fi
  echo "边界：组件停用 ≠ 字体渲染已验证；应用内置字体（如新版 Play 商店）不受影响"
  return 0
}

# ---------------------------------------------------------------------------
case "${1:-status}" in
  status)    do_status "$2" ;;
  enable)    do_enable ;;
  restore)   do_restore ;;
  reconcile) do_reconcile ;;
  diag)      do_diag ;;
  uninstall) do_restore >/dev/null 2>&1 ;;
  *) echo "用法: sh google_font.sh status [fresh] | enable | restore | reconcile | diag | uninstall"; exit 2 ;;
esac
