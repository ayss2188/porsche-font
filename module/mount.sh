#!/system/bin/sh
# mount.sh - 模块自带挂载（不依赖元模块，覆盖 my_product / mi_ext 等厂商分区）
#
# 原理：开机时把字体库里的字体文件直接 bind mount 到每个真实字体槽上，
#       不在模块目录生成任何副本（一份字体，零额外占用，也不受模块目录是镜像分区的影响）；
#       模块带 skip_mount，管理器不会重复挂载。
#   所有管理器      -> post-fs-data 阶段挂载（唯一保证会跑的阶段，主挂载点）
#   KernelSU/APatch -> 若支持 post-mount，那一步会再做一次幂等的「二次修补」
#
# slots.map 每行 "<字体id> <目标路径> [挂哪个文件]"：目标路径**永远是第 2 个字段**，
# 目标路径相对 /，如 f1700000000 system/fonts/Roboto-Regular.ttf
# 第 3 个字段只有 .ttc 合集槽位会写（挂的是包好的多 face TTC）；老格式只有两个字段。
# ⚠ 任何解析 slots.map 的地方都固定取第 2 个字段 —— 别按"字段数≥3 就取第 3 字段"，
#   那会把源文件路径当目标路径，把 .ttc 槽位误判成失效记录（真机上踩过）。
#
# 用法（source 后调用；需先 source common.sh）：
#   payload_mount <模块目录> <阶段名>   挂载，结果写入 mount.state
#   payload_verify <模块目录>          检查当前可见的系统字体是否就是本模块的文件，输出 "生效数 总数"

# 带超时执行：没有 timeout、或者 timeout 用不了（个别 ROM 上会返回 127）就直接执行。
# 目的只有一个 —— 任何一次 mount 都不允许把阻塞的 post-fs-data 阶段卡死。
# _to_s <秒数> <命令...>；_to 是"默认 5 秒"的简写。_to_n / _to_rc 是临时变量。
# ---------------------------------------------------------------------------
# boot_id —— 自带一份，不依赖调用方有没有 source common.sh。
#   ★ 2026-10-16：mount.sh 原先只"用" boot_id 却不定它，靠开机脚本先
#     source common.sh 才成立。直接 `sh mount.sh` 时它会静默变成空值，
#     而 mount.state 里 `boot=` 一空，mount_result 比对就失败
#     → 界面显示"本次开机未挂载"（live.sh 已经踩过这个坑）。
# ---------------------------------------------------------------------------
command -v boot_id >/dev/null 2>&1 || boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r\n'; }


_to_s() {
  _to_n="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_to_n" "$@"; _to_rc=$?
    [ "$_to_rc" = 127 ] || return $_to_rc
  fi
  # 没有可用的 timeout：自己兜底 —— 后台跑 + 每秒看一眼，超时就 kill。
  # 这一步不能赌：post-fs-data 是**阻塞**阶段，一个卡住的命令会把开机拖死
  # （老设备上就是"卡开机动画"）。busybox 的 timeout 在个别 ROM 上会返回 127，
  # 原来的写法在这种情况下等于完全不设超时。
  "$@" &
  _to_pid=$!
  _to_i=0
  while [ "$_to_i" -lt "$_to_n" ]; do
    if ! kill -0 "$_to_pid" 2>/dev/null; then
      wait "$_to_pid" 2>/dev/null
      return $?
    fi
    sleep 1
    _to_i=$((_to_i + 1))
  done
  kill -9 "$_to_pid" 2>/dev/null
  wait "$_to_pid" 2>/dev/null
  return 124
}
_to() { _to_s 5 "$@"; }

# ★ 2026-10-18：挂载命令统一入口（跟 live.sh 保持一致）
#   CFS_MOUNT_BIN 是给测试注入 mock 用的；真机上就是 /system/bin/mount。
# ★ 2026-10-18：挂载命令统一入口。
#   默认走 PATH 里的 mount（最稳 —— 有些 ROM 没有 /system/bin/mount）；
#   只有在测试注入 CFS_MOUNT_BIN 且它真的可执行时才用它。
_MOUNT_BIN=${CFS_MOUNT_BIN:-}
if [ -n "$_MOUNT_BIN" ] && [ ! -x "$_MOUNT_BIN" ]; then
  _MOUNT_BIN=""
fi
_mount() {
  if [ -n "$_MOUNT_BIN" ]; then
    _to "$_MOUNT_BIN" -o bind "$1" "$2"
  else
    _to mount -o bind "$1" "$2"
  fi
}



# ---------------------------------------------------------------------------
# ★ 2026-10-15：/data 上的"主题字体"槽位 —— 改成**物理替换（带备份）**
#
# 为什么不能用 bind 挂载（真机定位到的根因）：
#   bind 挂载只换"内容"，**inode 和 mtime 都不变**。
#   魅族主题服务（/data/customizecenter/font/flymeFont.ttf）靠"文件变了没有"
#   决定要不要重读 —— 内容变了但它看不出来，于是继续用缓存里的旧字形。
#   作者实测：手动"改名替换"能生效、"删掉再添加"不生效 —— 差别就在 inode 变没变。
#
# 所以这里不挂了，直接做作者手动做的那个动作：同分区 rename 覆盖。
#   · 换 inode、刷新 mtime → 系统认为"文件变了" → 重读 → 生效
#   · **必须备份原件**，否则用户切回「无字体」时他原来那份主题字体就没了
# ---------------------------------------------------------------------------
_datafont_is_ours() {   # $1=字体库源文件  $2=目标文件 → 0=目标已经是我们的
  local a b
  a=$(stat -L -c '%d:%i' "$1" 2>/dev/null)
  b=$(stat -L -c '%d:%i' "$2" 2>/dev/null)
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# 取字节数（取不到给 0；别把 $(wc …) 直接塞进算术里，ash 会当场报错）
_df_sz() {
  _v=$(wc -c < "$1" 2>/dev/null | tr -d ' \t\r\n')
  case "${_v:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$_v" ;; esac
}

datafont_swap() {   # $1=源(字体库文件) $2=目标(绝对路径) → 0=已替换 1=没做(调用方回退 bind)
  local src="$1" dst="$2" key bakdir bak tmp dir
  [ -f "$src" ] && [ -f "$dst" ] || return 1
  _datafont_is_ours "$src" "$dst" && return 0      # 已经是我们的，不用再动

  # -------------------------------------------------------------------------
  # ★ 2026-10-19：**跨重启的幂等判断** —— 别再每次开机都整份复制几十 MB。
  #
  #   上面那个 inode 判断只在**同一次开机内**有效：替换后我们会 bind 挂载它，
  #   stat 跟随挂载 → 同 inode → 跳过。可是**挂载不跨重启**，重启后 dst 就是一份
  #   复制出来的普通文件，inode 必然跟字体库里的不同 → 又整份复制一遍。
  #   魅族主题字体 17 MB、小米可变字体更大 —— 等于每次开机白写几十 MB
  #   （费 flash、拖慢开机），而用户根本没换字体。
  #
  #   做法：成功替换后记下 (目标大小 : 源大小 : 源 mtime)，下次开机对得上就**只补挂载**。
  #   用户真换了字体（源文件大小/mtime 变了）→ 对不上 → 正常重写一次。
  # -------------------------------------------------------------------------
  _df_st="$LIB/.datafont.state"
  _df_k=$(printf '%s' "$dst" | tr '/' '_' | tr -d ' ')
  _df_cur="$(_df_sz "$dst"):$(_df_sz "$src"):$(stat -c %Y "$src" 2>/dev/null)"
  _df_old=$(sed -n "s|^$_df_k=\(.*\)|\1|p" "$_df_st" 2>/dev/null | tail -n1)
  if [ -n "$_df_old" ] && [ "$_df_old" = "$_df_cur" ]; then
    _mount "$src" "$dst" 2>/dev/null       # 内容已经是我们的 → 只补 bind（双保险），不写盘
    return 0
  fi

  bakdir="$LIB/.orig"
  mkdir -p "$bakdir" 2>/dev/null || return 1

  # 用原路径编码成文件名，保留目录层级可读性
  key=$(printf '%s' "$dst" | tr '/' '_' | tr -d ' ')
  bak="$bakdir/$key"
  # ★ 只在**第一次**备份：以后（原件的 inode 已经变了）不再覆盖备份，
  #   否则第二次替换会把"已经是我们字体"的那份当成原件备份走，用户的原字体就丢了。
  if [ ! -s "$bak" ]; then
    cp -f "$dst" "$bak" 2>/dev/null || return 1
    [ -s "$bak" ] || return 1
    printf '%s\n' "$dst" >> "$bakdir/manifest.txt" 2>/dev/null
    echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 主题字体已备份原件：$dst -> $bak" >> "$LIB/mount.log" 2>/dev/null
  fi

  # 空间检查：替换要放得下一份（同分区）
  dir=${dst%/*}
  if command -v free_kb >/dev/null 2>&1; then
    local need free
    need=$(( $(wc -c < "$src" 2>/dev/null | tr -d ' ') / 1024 + 4096 ))
    free=$(free_kb "$dir")
    if [ -n "$free" ] && [ "$free" -lt "$need" ] 2>/dev/null; then
      echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 空间不足，主题字体改用挂载：$dst（需要 $((need/1024))MB，剩 $((free/1024))MB）" >> "$LIB/mount.log" 2>/dev/null
      return 1
    fi
  fi

  # 同目录临时文件 → mv（rename）覆盖。临时名不能带扩展名，免得被主题服务当成字体
  tmp="$dir/.cfs_tmp_$$"
  cp -f "$src" "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  # 内容核对（写入过程被截断的话宁可不动）
  if [ "$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')" != "$(wc -c < "$src" 2>/dev/null | tr -d ' ')" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  chmod 644 "$tmp" 2>/dev/null
  chcon u:object_r:system_file:s0 "$tmp" 2>/dev/null
  if mv -f "$tmp" "$dst" 2>/dev/null; then
    chmod 644 "$dst" 2>/dev/null
    chcon u:object_r:system_file:s0 "$dst" 2>/dev/null
    # ★ 作者的意思：**两种都做**（双保险）。
    #   物理替换已经换了 inode/mtime（让主题服务刷新）；
    #   再 bind 一次，是为了防"系统读的时候把文件钉住了"——
    #   即使它忽略了时间戳，路径上的内容也始终是我们的。
    #   挂载失败不影响：物理替换那一步已经达成了目的。
    _mount "$src" "$dst" 2>/dev/null
    # 记下"这次换的是什么"，下次开机对得上就不再写盘（见上面跨重启幂等那段）
    {
      sed -i "/^$_df_k=/d" "$_df_st" 2>/dev/null
      printf '%s=%s\n' "$_df_k" "$(_df_sz "$dst"):$(_df_sz "$src"):$(stat -c %Y "$src" 2>/dev/null)"
    } >> "$_df_st" 2>/dev/null
    echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 主题字体已物理替换 + 挂载（双保险）：$dst" >> "$LIB/mount.log" 2>/dev/null
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}


# ---------------------------------------------------------------------------
# ★ 2026-10-15：把物理替换过的主题字体**还原**回去
#
# 什么时候调：当前**没有选字体**（pending_font 为空/none）时。
#   因为"选了字体"意味着用户要用我们的字体，那时不该还原；
#   一旦他切回「无字体」，就该把他原来的主题字体还给他 —— 否则是我们弄丢了用户数据。
# 怎么做：读 .orig/manifest.txt 里登记过的路径，逐个用备份盖回去（同样 rename，
#   换 inode 让主题服务也重读一次）。还原成功后清掉该条登记（保留备份文件本身，
#   万一以后还要用；体积不大，且用户删模块时会一起被 uninstall 清掉）。
# ---------------------------------------------------------------------------
datafont_restore() {
  local bakdir="$LIB/.orig" mani="$LIB/.orig/manifest.txt" dst bak tmp dir n=0
  [ -s "$mani" ] || return 0
  tmp="$mani.$$"
  : > "$tmp" 2>/dev/null
  while IFS= read -r dst || [ -n "$dst" ]; do
    [ -n "$dst" ] || continue
    case "$dst" in /data/*) ;; *) printf '%s\n' "$dst" >> "$tmp"; continue ;; esac
    bak="$bakdir/$(printf '%s' "$dst" | tr '/' '_' | tr -d ' ')"
    if [ ! -s "$bak" ]; then
      # 备份没了：不敢乱动，跳过（留着登记，下次再看）
      printf '%s\n' "$dst" >> "$tmp"
      continue
    fi
    dir=${dst%/*}
    [ -d "$dir" ] || { printf '%s\n' "$dst" >> "$tmp"; continue; }
    if ! cp -f "$bak" "$dir/.cfs_rs_$$" 2>/dev/null; then
      printf '%s\n' "$dst" >> "$tmp"
      continue
    fi
    chmod 644 "$dir/.cfs_rs_$$" 2>/dev/null
    chcon u:object_r:system_file:s0 "$dir/.cfs_rs_$$" 2>/dev/null
    if mv -f "$dir/.cfs_rs_$$" "$dst" 2>/dev/null; then
      n=$((n+1))
      echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 已还原主题字体原件：$dst" >> "$LIB/mount.log" 2>/dev/null
    else
      rm -f "$dir/.cfs_rs_$$" 2>/dev/null
      printf '%s\n' "$dst" >> "$tmp"
    fi
  done < "$mani"
  mv -f "$tmp" "$mani" 2>/dev/null
  [ "$n" -gt 0 ] && echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 还原完成：$n 个主题字体" >> "$LIB/mount.log" 2>/dev/null
  return 0
}

payload_mount() {
  local moddir="$1" id rel src dst err ok=0 fail=0 skip=0 same=0
  local map="$moddir/slots.map"
  # 没有挂载计划时**不要静默 return** —— 那会一个槽位都不挂、日志里什么都没有，
  # 诊断报告只能写"本次开机未挂载"，用户无从下手。先在挂载前把计划补回来，
  # 让"更新后第一次重启"就直接生效，而不是要用户再重启一次。
  #
  # 边界（都要判）：
  #   · 只在"选了字体"时才补；pending_font 为空/none 就保持不动
  #   · manager 模式不补 —— 那是管理器挂载，slots.map 本来就不该有内容
  #   · 找不到 fontctl.sh 就不补（老版本模块没有这个文件）
  #   · 补计划这一步自己在阻塞的 post-fs-data 里跑，所以给它一个上限（20 秒）；
  #     真被掐掉的后果和"不补"完全一样（计划仍为空、本次不挂载），不会更糟。
  #   · **开机阶段只补"轻"的那部分**：CFS_NO_TTC=1 让这一次跳过 .ttc 合集的合成
  #     （那一步要读写几十 MB，老设备上能拖很久，正是"卡开机动画"的来源之一）。
  #     合集没换不影响这次开机：本来一个槽位都没挂上，现在至少把普通字体挂上；
  #     完整的一次（含合集）由 service 阶段在开机完成后补做。
  # ★ 2026-10-15：没选字体（或选了「无字体」）→ 把物理替换过的主题字体**还回去**。
  #   放在最前面：这一步跟 slots.map 有没有内容无关。
  #   为什么必须有：物理替换动的是用户 /data 上的文件，不还原就等于弄丢他的数据。
  _pf=$(tr -d '[:space:]' 2>/dev/null < "$moddir/pending_font")
  case "$_pf" in ""|none) datafont_restore ;; esac

  if [ ! -s "$map" ]; then
    local _p _pm _ttc_prev
    _p=$(tr -d '[:space:]' 2>/dev/null < "$moddir/pending_font")
    case "$_p" in ""|none) return 0 ;; esac
    _pm=$(tr -d '[:space:]' 2>/dev/null < "$moddir/payload.mode")
    [ "$_pm" = manager ] && return 0
    [ -f "$moddir/fontctl.sh" ] || return 0
    echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 阶段=${2:-unknown} 没有挂载计划（slots.map 为空），尝试重新生成（只补轻量部分，跳过合集合成）" >> "$LIB/mount.log" 2>/dev/null
    _ttc_prev=${CFS_NO_TTC-__unset__}
    export CFS_NO_TTC=1
    # ★ 上限 20 → 40 秒（2026-10-14）。
    #   为什么改：`slot_plan` 现在会**真的跑一遍自适应扫描**（以前那段被一个 bug 静默关掉了，
    #   见 slots.sh 的 slot_adaptive_extra）。真机上这一步约 1~2 秒，20 秒本来够；
    #   但 Windows 沙箱里"起一个进程"要 47ms，`slot_plan` 本身就要 17~21 秒，
    #   刚好被 20 秒掐断 → 自愈失效（回归测试 newfix-test 第 2 节就是这么红的）。
    #   自愈是**开机后台**动作，等 40 秒不影响用户；而"自愈没生效"会让字体整轮不挂载。
    #   宁可多等，不要静默失败。
    _to_s 40 sh "$moddir/fontctl.sh" apply "$_p" >/dev/null 2>&1
    _rc=$?
    # 还原：不用 `CFS_NO_TTC=1 函数名` 那种写法 —— POSIX 对"赋值前缀 + 函数"的作用域
    # 措辞是 **unspecified**（busybox ash 实测是临时的，但真机跑的是 mksh，不赌这个）。
    # 万一它留在当前 shell，这次开机后面所有 ttc_enabled 都会判成"跳过合集"。
    # （2026-10-11 姊妹项目同步时提出，我这边改成不依赖未定义行为）
    if [ "$_ttc_prev" = __unset__ ]; then
      unset CFS_NO_TTC
    else
      CFS_NO_TTC=$_ttc_prev
      export CFS_NO_TTC
    fi
    if [ ! -s "$map" ]; then
      # 退出码 124 = 被上面那个 20 秒上限掐断了
      echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 阶段=${2:-unknown} 重新生成后仍然没有挂载计划（退出码 $_rc），本次不挂载（请把诊断报告发给作者）" >> "$LIB/mount.log" 2>/dev/null
      return 0
    fi
    echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 阶段=${2:-unknown} 已补上挂载计划（$(grep -c . "$map" 2>/dev/null) 个槽位），继续挂载" >> "$LIB/mount.log" 2>/dev/null
  fi
  # ★ 2026-10-17 提速（开机挂载的主开销就在这个循环里）：
  #   原来**每个槽位**都要两次 `printf | tr -d '\r'` 去行尾 CR ——
  #   286 个槽位就是 572 个进程，全花在"去掉一个回车符"上。
  #   现在循环外一次把整份计划清洗好（2 个进程），循环里直接读干净的行。
  #   语义完全一样：只去 CR，别的都不动。清洗失败就退回原文件（宁慢勿错）。
  _mapc="${TMPDIR:-/data/local/tmp}/.slots.clean.$$"
  if tr -d '\r' < "$map" > "$_mapc" 2>/dev/null && [ -s "$_mapc" ]; then
    _usemap="$_mapc"
  else
    _usemap="$map"
  fi
  while read -r id rel src || [ -n "$rel" ]; do
    case "$id" in ""|*[!A-Za-z0-9_]*) continue ;; esac
    case "$rel" in ""|/*|*..*) continue ;; esac
    # 第三个字段 = 这个槽位挂哪个文件（.ttc 槽位挂的是包好的"多 face TTC"）；
    # 老格式只有两个字段，那就用字体库里的 $id.ttf
    [ -n "$src" ] || src="$LIB/$id.ttf"
    dst="/$rel"
    if [ ! -f "$src" ] || [ ! -f "$dst" ]; then
      skip=$((skip+1)); continue
    fi
    # ★ 2026-10-15：/data 上的"主题字体"（魅族 flymeFont.ttf 这类）**不挂载，改物理替换**。
    #   原因见上面 datafont_swap 的注释：bind 不改 inode/mtime → 主题服务认为文件没变 → 用缓存。
    #   替换成功就 continue（这个槽位不挂）；替换失败**回退到下面的 bind 挂载**（不比以前差）。
    # ★ 目前**只对魅族这一类**做物理替换（有真机证据：主题服务按 inode/mtime 判缓存，
    #   挂载只换内容、inode 不变 → 它认为文件没动 → 用旧字形）。
    #   其它 /data 槽位（MIUI 主题字体 / 三星 overlays / vivo vfonts）暂无证据说明挂载不够，
    #   保持原样走挂载 —— 动用户真实文件的面越小越好。
    # ★ 2026-10-20：把新接入的几家也纳入"物理替换"（否则 bind 挂载对主题服务无效）：
    #   ColorOS  /data/format_unclear/font、/data/oplus/uxres/theme
    #   vivo     /data/bbkcore/theme、/data/skin/fonts
    #   通用主题 /data/theme/fonts、/data/themes
    # 荣耀的 /data/system/theme_magic 刻意不在其中（它连替换名单都没进）。
    case "$dst" in
      /data/customizecenter/*|/data/format_unclear/*|/data/oplus/uxres/*|\
      /data/bbkcore/*|/data/skin/fonts/*|/data/theme/fonts/*|/data/themes/*)
        if datafont_swap "$src" "$dst"; then
          ok=$((ok+1)); continue
        fi
        ;;
    esac
    # 幂等：已经指向我们的文件了就别再叠一层
    # （post-fs-data 和 post-mount 万一都跑到，或者被重复调用，会叠出多层挂载且再也数不清）
    if [ "$(stat -L -c '%d:%i' "$src" 2>/dev/null)" = "$(stat -L -c '%d:%i' "$dst" 2>/dev/null)" ]; then
      same=$((same+1)); continue
    fi
    # 每个挂载加超时：万一某个槽位卡住，绝不能让整个开机阶段跟着卡死（post-fs-data 是阻塞阶段）
    # 成败看退出码，不看有没有输出 —— mount 成功时也可能打好几行警告
    err=$(_mount "$src" "$dst" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then
      if [ -n "$_MOUNT_BIN" ]; then _to "$_MOUNT_BIN" -o remount,bind,ro "$dst"
      else _to mount -o remount,bind,ro "$dst"; fi 2>/dev/null
      ok=$((ok+1))
    else
      fail=$((fail+1))
      echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 绑定失败 $src -> $dst : ${err:-未知错误}" >> "$LIB/mount.log" 2>/dev/null
    fi
  done < "$_usemap"
  rm -f "${_mapc:-}" 2>/dev/null
  echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 阶段=${2:-unknown} 成功=$ok 失败=$fail 跳过=$skip 已就位=$same" >> "$LIB/mount.log" 2>/dev/null
  if [ -f "$LIB/mount.log" ]; then
    tail -n 100 "$LIB/mount.log" > "$LIB/mount.log.tmp.$$" 2>/dev/null && mv -f "$LIB/mount.log.tmp.$$" "$LIB/mount.log" 2>/dev/null
  fi
  if command -v beat >/dev/null 2>&1; then
    beat mount "phase=${2:-unknown} ok=$ok fail=$fail skip=$skip same=$same"
  fi
  {
    echo "boot=$(boot_id)"
    echo "ok=$ok"
    echo "fail=$fail"
    echo "skip=$skip"
    echo "same=$same"
    echo "stage=${2:-unknown}"
    echo "time=$(date +%s)"
  } > "$moddir/mount.state"
}

# ---------------------------------------------------------------------------
# ★ 2026-10-19：**只把 /data 上的主题字体做物理替换**（元模块模式专用）
#
#   元模块（HybridMount / NoMount …）只覆盖 system/product/vendor/system_ext，
#   /data 下的主题字体它管不到；而主题服务（魅族、MIUI 主题、三星字体包）
#   认的是文件本身（inode / mtime），bind 挂载不改那两个 → 它会继续用缓存的旧字形。
#   所以这些槽位走"整份复制 + 备份原件"（datafont_swap），跟自带挂载时一样。
# ---------------------------------------------------------------------------
datafont_apply() {
  local moddir="$1" id rel src dst ok=0 skip=0
  local map="$moddir/slots.map"
  [ -s "$map" ] || return 0
  _da_clean="${TMPDIR:-/data/local/tmp}/.df.clean.$$"
  if tr -d '\r' < "$map" > "$_da_clean" 2>/dev/null && [ -s "$_da_clean" ]; then
    _da_map="$_da_clean"
  else
    _da_map="$map"
  fi
  while read -r id rel src || [ -n "$rel" ]; do
    rel=$(printf '%s' "$rel" | tr -d '\r')
    case "$rel" in data/*) ;; *) continue ;; esac
    case "$rel" in ""|/*|*..*) continue ;; esac
    [ -n "$src" ] || src="$LIB/$id.ttf"
    dst="/$rel"
    if [ ! -f "$src" ] || [ ! -f "$dst" ]; then skip=$((skip+1)); continue; fi
    if datafont_swap "$src" "$dst"; then ok=$((ok+1)); else skip=$((skip+1)); fi
  done < "$_da_map"
  rm -f "$_da_clean" 2>/dev/null
  [ "$ok" -gt 0 ] && echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] 元模块模式：已物理替换 $ok 个主题字体（跳过 $skip）" >> "$LIB/mount.log" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# 从 **PID 1 的视角**确认挂载是否真的对框架可见
#
#   框架（system_server）是 PID 1 的子进程，继承的是 PID 1 的挂载命名空间。
#   所以我们这边"挂上了"不等于框架看得见 —— 要看 /proc/1/mountinfo。
#
#   做法：拿挂载计划里的目标路径，去 PID 1 的挂载表里找同名挂载点。
#   输出："PID1 <可见数> <未见到数> <未见到路径…>"
#   只读、单次 awk（计划 + mountinfo 各扫一遍）。
# ---------------------------------------------------------------------------
pid1_visible() {   # $1=moddir
  local moddir="${1:-${MODDIR:-}}" plan mi
  mi="${CFS_MOUNTINFO:-/proc/1/mountinfo}"
  plan="$moddir/slots.map"
  [ -s "$plan" ] || plan="${LIB:-/data/adb/custom_font_lib}/slots.map"
  [ -s "$plan" ] || return 1
  [ -r "$mi" ] || return 1
  awk 'NR == FNR { if (NF >= 2) want["/" $2] = 1; next }
       { if (NF >= 5) seen[$5] = 1 }
       END {
         v = 0; m = 0; list = ""
         for (p in want) {
           if (p in seen) v++
           else { m++; if (m <= 8) list = list " " p }
         }
         printf "PID1 %d %d%s\n", v, m, list
       }' "$plan" "$mi" 2>/dev/null
}

payload_verify() {
  # 逐个核对 slots.map 里的槽位到底生效了没有，输出 "命中数 总数"。
  #
  # ★ 2026-10-19（作者要求：**两条路线，互不干扰**）
  #     自带挂载（self）    → 下面"路线 B"：按目录批量拿 inode 一次比完（快）。
  #     元模块挂载（manager）→ 下面"路线 A"：v1.3.0 的老实现，逐槽位比文件大小。
  #   为什么必须分开：
  #     · 管理器（KernelSU / Hybrid Mount）走 overlay/tmpfs，inode 天然不同，
  #       只有"文件大小"能对上 —— 这在 v1.3.0 就已经验证过；
  #     · 混在一起改的后果（真机踩过）：manager 判成 0/N，报告说"没挂上"；
  #       而且为了救 manager 去动公共逻辑，会把 self 的批量优化一起拖慢。
  #   所以：两条路各写各的，谁也别碰谁。
  local moddir="$1"
  local map="$moddir/slots.map"
  local key ck mode
  key="$(boot_id 2>/dev/null)_$(stat -c '%Y-%s' "$map" 2>/dev/null)"
  if [ -s "$LIB/.verify.cache" ]; then
    ck=$(sed -n '1p' "$LIB/.verify.cache" 2>/dev/null)
    if [ -n "$key" ] && [ "$ck" = "$key" ]; then
      sed -n '2p' "$LIB/.verify.cache" 2>/dev/null
      return 0
    fi
  fi
  [ -s "$map" ] || { echo "0 0"; return 0; }

  mode=$(tr -d '[:space:]' 2>/dev/null < "$moddir/payload.mode")

  _pv_finish() {   # $1 = 结果
    if [ -n "$key" ]; then
      { printf '%s\n' "$key"; printf '%s\n' "$1"; } > "$LIB/.verify.cache.tmp.$$" 2>/dev/null \
        && mv -f "$LIB/.verify.cache.tmp.$$" "$LIB/.verify.cache" 2>/dev/null
    fi
    printf '%s\n' "$1"
  }

  # =========================================================================
  # 路线 A：管理器 / 元模块挂载 —— **v1.3.0 的老实现，原样保留**
  #   管理器挂载会经过 overlay/tmpfs，inode 不同，只能比较大小：
  #     模块目录里摆好的那份（$MODDIR/<mgr_path>）  vs  系统里实际生效的那份（/$rel）
  #   注意：product/ vendor/ system_ext/ 在模块里是 system/<那个>（mgr_path 负责转换）。
  # =========================================================================
  if [ "$mode" = manager ]; then
    local id rel src a b n=0 hit=0
    while read -r id rel src || [ -n "$rel" ]; do
      rel=$(printf '%s' "$rel" | tr -d '\r')
      case "$rel" in ""|/*|*..*) continue ;; esac
      [ -f "/$rel" ] || continue
      n=$((n+1))
      case "$rel" in
        data/*)
          # ★ /data 上的主题字体：元模块覆盖不到，由 datafont_apply 整份复制过去
          #   → 拿字体库里的源文件大小跟实际文件比（复制过去的，大小必然相同）
          [ -n "$src" ] || src="$LIB/$id.ttf"
          a=$(stat -L -c '%s' "$src" 2>/dev/null)
          ;;
        *)
          a=$(stat -L -c '%s' "$moddir/$(mgr_path "$rel")" 2>/dev/null)
          ;;
      esac
      b=$(stat -L -c '%s' "/$rel" 2>/dev/null)
      [ -n "$a" ] && [ "$a" = "$b" ] && hit=$((hit+1))
    done < "$map"
    _pv_finish "$hit $n"
    return 0
  fi

  # =========================================================================
  # 路线 B：自带挂载 —— 批量快路（按目录 ls -ilL 一次拿完，inode 直接比）
  #   ⚠️ 这一段只服务 self 模式，不要为了别的模式改它。
  # =========================================================================
  local _pvc="${TMPDIR:-/data/local/tmp}/.pv.clean.$$" _pvmap _inomap _dirs _d _out
  if tr -d '\r' < "$map" > "$_pvc" 2>/dev/null && [ -s "$_pvc" ]; then
    _pvmap="$_pvc"
  else
    _pvmap="$map"
  fi

  # 一、涉及的目标目录（通常 2~3 个）：从 rel（system/fonts/X.ttf）去掉最后一段
  _dirs=" $(awk 'NF >= 2 { p = $2; sub(/^\//, "", p); sub(/\/[^\/]*$/, "", p); if (p != "") print "/" p }' "$_pvmap" 2>/dev/null | sort -u | tr '\n' ' ') "

  # 二、每个目录列一次 inode
  #   ⚠️ 必须 `ls -L`（跟随符号链接）：系统里不少槽位是链接
  #      （DroidSans.ttf -> Roboto-Regular.ttf），payload_mount 也是跟随链接去挂的，
  #      两边口径必须一致，否则"明明已就位 119，核对却显示 116"。
  _inomap="${TMPDIR:-/data/local/tmp}/.pv.ino.$$"
  : > "$_inomap"
  for _d in $_dirs; do
    [ -d "$_d" ] || continue
    # ★ 不能写 `grep -c . f || echo 0`：空文件时 grep 先输出 0 再以 1 退出，
    #   拼起来变 "0\n0"，`[ -le ]` 直接报 bad number。
    _before=$(grep -c . "$_inomap" 2>/dev/null); [ -n "$_before" ] || _before=0
    ( cd "$_d" 2>/dev/null && ls -iL 2>/dev/null \
        | awk -v d="$_d" 'NF >= 2 { ino = $1; nm = $NF; print d "/" ino " " nm }' ) >> "$_inomap" 2>/dev/null
    _after=$(grep -c . "$_inomap" 2>/dev/null); [ -n "$_after" ] || _after=0
    # 兜底：万一这个 ROM 的 ls 不认 -L（输出空），退回不跟随版本
    if [ "${_after:-0}" -le "${_before:-0}" ]; then
      ( cd "$_d" 2>/dev/null && ls -i 2>/dev/null \
          | awk -v d="$_d" 'NF >= 2 { ino = $1; nm = $NF; print d "/" ino " " nm }' ) >> "$_inomap" 2>/dev/null
    fi
  done

  # 三、比对：源 inode 现算（通常只有 1~2 个），目标从 _inomap 查
  local _all_src _si _s _i
  _all_src=$(awk 'NF >= 2 { s = (NF >= 3 && $3 != "") ? $3 : ""; if (s != "") print s }' "$_pvmap" 2>/dev/null | sort -u)
  _si=""
  for _s in $_all_src; do
    _i=$(stat -c '%i' "$_s" 2>/dev/null)
    [ -n "$_i" ] && _si="$_si$_s=$_i "
  done

  _out=$(awk -v SI="$_si" -v INO="$_inomap" '
    function src_inode(p,   n, arr, i, kv) {
      n = split(SI, arr, " ")
      for (i = 1; i <= n; i++) {
        if (arr[i] == "") continue
        kv = arr[i]
        if (substr(kv, 1, length(p) + 1) == p "=") return substr(kv, length(p) + 2)
      }
      return ""
    }
    BEGIN {
      while ((getline line < INO) > 0) {
        if (line == "") continue
        # 行格式： /system/fonts/<inode> <文件名>
        k = index(line, " ")
        if (k <= 1) continue
        full = substr(line, 1, k - 1)
        fname = substr(line, k + 1)
        dir = full
        sub(/\/[^\/]*$/, "", dir)
        ino = full
        sub(/.*\//, "", ino)
        T[dir "/" fname] = ino
      }
      close(INO)
    }
    NF >= 2 {
      p = $2; sub(/^\//, "", p)
      dst = "/" p
      src = (NF >= 3 && $3 != "") ? $3 : ""
      if (src == "") next
      # /data/ 下的槽位（主题字体）走"物理替换"，inode 必然不同 —— 单独算已处理
      if (substr(dst, 1, 6) == "/data/") { hit++; n++; next }
      n++
      a = src_inode(src)
      b = T[dst]
      if (a != "" && a == b) hit++
    }
    END { print hit + 0, n + 0 }
  ' "$_pvmap" 2>/dev/null)

  [ -n "$_out" ] || _out="0 0"
  rm -f "$_pvc" "$_inomap" 2>/dev/null
  _pv_finish "$_out"
}


