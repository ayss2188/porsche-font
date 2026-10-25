#!/system/bin/sh
# 自定义字体切换模块 - 公共函数库
# 提供：系统识别 / 系统名称 / Root 管理器识别 / 持久化设置 / 挂载路径映射
# 槽位发现见 slots.sh，自带挂载见 mount.sh；脚本中通过 source 引入

LIB=${LIB:-/data/adb/custom_font_lib}

# 字体库里所有"可用的字体 id"（不含扩展名）。
# ★ 2026-10-18：抽出来是为了让 grp_load 这类"遍历字库"的地方不乱 glob ——
#   子项目还要认内置配色 builtin_*，各项目在这里各写各的规则，
#   上层代码统一用 $(lib_font_ids)，就不会在同步时被互相覆盖。
lib_font_ids() {
  local f
  for f in "$LIB"/f[0-9]*.ttf; do
    [ -f "$f" ] || continue
    basename "$f" .ttf
  done
}

SETTINGS="$LIB/settings.conf"

getp() { getprop "$1" 2>/dev/null | tr -d '\r\n'; }

# ---------------------------------------------------------------------------
# 识别当前 ROM：
#   专项适配（有已知文件名清单）：hyperos | coloros | originos | flyme
#   （靠真实字体目录 + 字体配置 XML 自动发现槽位）：honor | huawei | nothing | aosp
#   ★ samsung 有自己的清单（targets/samsung.list）+ .ttc 合集处理，不属于这一类
#
# ★ 1.0.9 重做：识别要"多证据"，不能看到一个属性就下结论 ★
#   真实反馈（2026-10-12）：一台 **Android 16 类原生**被认成了 MIUI ——
#     · 类原生 / GSI / 移植包经常带着**残留属性**（ro.miui.ui.version.code 这类）；
#     · 老写法只要有一个非空就 return，于是"有 MIUI 残留属性"= MIUI，误判。
#   误判的代价不只是名字写错：ROM 决定用哪份 targets/*.list（槽位名单），
#     认错就会去找根本不存在的槽位名 → 计划里少几个槽位 → 用户看到"部分没换"。
#
#   新判定规则（对每一家都一样）：
#     ① **厂商专属属性**才算"强证据"；AOSP 通用属性（ro.product.* 这些谁都能改）只算弱证据；
#     ② 强证据 ≥1 → 直接认定；
#     ③ 只有弱证据（比如 brand=Xiaomi）→ **必须再有厂商目录/文件实证**（/system_ext/oplus 等）；
#     ④ 都不满足 → aosp（类原生）。
#   本函数每个属性只取一次（PROP_CACHE 缓存整个 getprop 输出），
#     比原来十几次 getprop 进程快，也不会同一台机器上两次读不一致。
# ---------------------------------------------------------------------------
# ★ 2026-10-15：**小米专有字体**是否存在 —— 用来证明"这确实是小米的 ROM"
#
#   为什么需要：`ro.product.brand` 是硬件品牌（小米机器刷类原生也报 xiaomi），
#   而 `ro.miui.*` 属性在移植/类原生包上会残留 → 光靠属性会把类原生认成 HyperOS。
#   实测对照：
#     真 HyperOS（小米 23116PN5BC / 红米 25102RKBEC）→ 小米专有字体 60 / 51 个
#     类原生  （小米 2210132C，AOSP 构建号 BP4A.*）  → **0 个**
#
#   ⚠ 不能改用 MiuiSystemUI / miui-framework 目录当判据：
#     查过真 HyperOS 的报告，那两个目录**根本没被列出来**，用它当门会误伤真小米用户。
# ---------------------------------------------------------------------------
_xm_exclusive_font() {
  local d f b dirs
  # ★ 2026-10-16 加保险（真机 v1.2.6 误判成"原生/类原生"）：
  #   原先只用 $(slot_dirs) 找目录。而 slot_dirs 有进程内缓存，
  #   安装最早期（customize.sh 一开始的 detect_rom）调用时若分区还没就绪，
  #   会算出**空**并被缓存住 → 这里就一个目录都扫不到 → 小米机器被认成类原生。
  #   （那个缓存问题已单独修了，但"认系统"这件事太关键，不该只剩一条命。）
  #   所以这里**直接扫最常见的字体目录**，不经过任何缓存/函数。
  dirs="$(slot_dirs 2>/dev/null)
/system/fonts
/system_ext/fonts
/product/fonts
/vendor/fonts
/odm/fonts
/mi_ext/fonts
/my_product/fonts"
  for d in $dirs; do
    [ -d "$FSROOT$d" ] || continue
    for f in "$FSROOT$d"/*.ttf "$FSROOT$d"/*.otf "$FSROOT$d"/*.ttc \
             "$FSROOT$d"/*.TTF "$FSROOT$d"/*.OTF; do
      [ -f "$f" ] || continue
      b=${f##*/}
      case "$b" in
        # 小米/红米/POCO 的专有字体名（真机实测出现过的那批）
        MiSans*|MiLanPro*|MiHaus*|MiClock*|MiSansVF*|MiSansLatinVF*|MiSansTCVF*) return 0 ;;
      esac
    done
  done
  return 1
}


# ---------------------------------------------------------------------------
_rom_props() {
  # 一次读完全部属性并缓存（getprop 不带参数 = 全量转储）。之后查询走内存，不起进程。
  # ★ 2026-10-16 修（真机 v1.2.6 把澎湃OS 判成 aosp）：
  #   原来读空时把 PROP_ALL 钉成 " "（一个空格）—— 那之后**永远**读不到属性，
  #   因为缓存已经"有值"了。开机最早期（post-fs-data）如果 getprop 一时不可用，
  #   整场运行就再也读不到 ro.product.brand → 小米那家判定被整段跳过 → 落到 aosp。
  #   现在：读空就不缓存，下次调用重试（代价只是一次 getprop）。
  if [ -z "${PROP_ALL+x}" ] || [ -z "${PROP_ALL// /}" ]; then
    local _pa
    _pa=$(getprop 2>/dev/null | tr -d '\r')
    if [ -n "${_pa// /}" ]; then
      PROP_ALL="$_pa"
    fi
  fi
}
# 查一个属性（结果写 PROP_V）；从缓存里按行匹配，纯 shell，不起进程
_prop_get() {
  local line
  [ -n "${1:-}" ] || { PROP_V=""; return 0; }
  _rom_props
  PROP_V=""
  while IFS= read -r line; do
    case "$line" in
      "[$1]:"*) PROP_V=${line#*: }; PROP_V=${PROP_V# }; PROP_V=${PROP_V# }; ;;
    esac
  done <<EOF
$PROP_ALL
EOF
  return 0
}
# 厂商目录/文件实证：有任意一个存在就返回 0（这些目录是 ROM 刷进去的，改属性改不出来）
_rom_has_dir() {
  local d
  for d in "$@"; do
    [ -e "$FSROOT$d" ] && return 0
  done
  return 1
}

detect_rom() {
  local vname vdisplay vbrand vmanu strong weak gen

  # 读一次通用属性（品牌/厂商/显示版本），后面每家都用
  _prop_get ro.product.brand;               vbrand="$PROP_V"
  _prop_get ro.product.manufacturer;        vmanu="$PROP_V"
  _prop_get ro.build.display.id;            vdisplay="$PROP_V"
  # "像不像手机厂商自己的品牌"：类原生/GSI 上这里通常是 google / Android / unknown
  case "$vbrand $vmanu" in
    *google*|*Google*|*GOOGLE*|*[Aa]ndroid*|*unknown*|*Unknown*|"") gen=1 ;;
    *) gen="" ;;
  esac

  # ---- 1. 澎湃OS / HyperOS / MIUI（小米/红米/POCO）----
  #   为什么这一家要**双重证据**：类原生/移植包带着 MIUI 残留属性的情况最常见
  #   （作者 2026-10-12 反馈的那台就是：Android 16 类原生被认成 MIUI）。
  #   强属性（ro.mi.os.version.name 等）单独不算数，必须再有"小米品牌"或"小米目录实证"。
  _prop_get ro.mi.os.version.name;          strong="$PROP_V"
  [ -n "$strong" ] || { _prop_get ro.miui.ui.version.code; strong="$PROP_V"; }
  [ -n "$strong" ] || { _prop_get ro.miui.ui.version.name; strong="$PROP_V"; }
  case "$vbrand $vmanu" in
    *[Xx]iaomi*|*[Rr]edmi*|*[Pp][Oo][Cc][Oo]*|*[Xx]IAOMI*|*[Rr]EDMI*) weak=1 ;;
    *) weak="" ;;
  esac
  # ★ 2026-10-16 加：**属性一个都没读到**时的兜底。
  #   真机 v1.2.6 现场：这一刻 getprop 全量转储是空的（或读不到 brand），
  #   weak 不成立 → 小米那一整段被判据跳过 → 直接落到 aosp
  #   → current_rom 写错 → 之后去读 targets/aosp.list 而不是 hyperos.list
  #     （计划从 172 变 152，覆盖范围跟着错）。
  #   现在：属性读不到时**不武断**，改用目录实证 —— 有小米专属路径就是小米。
  #   宁可认成 hyperos（多换几个槽位），也别认成 aosp（少换、清单也错）。
  if [ -z "$vbrand" ] && [ -z "$vmanu" ]; then
    if _rom_has_dir /product/etc/mi_fonts_customization.xml /product/etc/misans_variable_fonts.xml \
                     /mi_ext /system_ext/etc/hyper_fonts.xml /system_ext/etc/miui_fonts.xml \
                     /system_ext/priv-app/MiuiSystemUI; then
      echo "hyperos"; return 0
    fi
  fi
  if [ -n "$weak" ]; then
    # ★ 2026-10-15 真机修正：**小米这一家也要求实证**，不再"品牌是小米 + 有强属性"就认。
    #   证据（三份真机报告对照）：
    #     · 类原生：小米 2210132C / AOSP 构建号 BP4A.* → 小米专有字体 **0 个**，
    #       字体目录全是 AOSP 字体包（ACFilmstrip/Aclonica/AlphaClouds…），
    #       但 `ro.miui.ui.version.name=V816` 之类的属性**残留着** → 被误判成 HyperOS。
    #     · 真 HyperOS：小米 23116PN5BC / 红米 25102RKBEC → 小米专有字体 60 / 51 个。
    #   关键认识：`ro.product.brand` 是**硬件品牌**（小米机器刷什么 ROM 都是 xiaomi），
    #   它证明不了 ROM；而 `ro.miui.*` 属性在移植包上会残留。
    #   ⚠ 实证不能用 MiuiSystemUI / miui-framework —— 查过真 HyperOS 的报告，
    #     那两个目录在报告里**根本没被列出来**，用它当门会把真小米用户误判成 aosp。
    #     用"小米专有字体存不存在"：真机 51~60 个、类原生 0 个，干净。
    if _xm_exclusive_font; then
      echo "hyperos"; return 0
    fi
    if [ -z "$strong" ] && _rom_has_dir /system_ext/priv-app/MiuiSystemUI /system/framework/miui-framework.jar; then
      # 老 MIUI 可能没有 ro.miui.* 属性 —— 那时靠目录实证（但**不能**只靠品牌）
      echo "hyperos"; return 0
    fi
  elif [ -n "$strong" ] && { _rom_has_dir /system_ext/priv-app/MiuiSystemUI /system/framework/miui-framework.jar || _xm_exclusive_font; }; then
    # 品牌不像小米，但有小米实证（目录 或 专有字体）→ 移植/换皮，仍按小米处理
    echo "hyperos"; return 0
  fi
  # 走到这里：光有 MIUI 属性、品牌却是 google/类原生 → **不认**，继续往下判（最终落到 aosp）

  # ---- 2. ColorOS / OPPO / 一加 / realme（oplus 系）----
  _prop_get ro.build.version.oplusrom;      strong="$PROP_V"
  [ -n "$strong" ] || { _prop_get ro.oplus.version; strong="$PROP_V"; }
  [ -n "$strong" ] || { _prop_get ro.build.version.oplusrom.display; strong="$PROP_V"; }
  if [ -n "$strong" ]; then echo "coloros"; return 0; fi
  case "$vbrand $vmanu" in
    *[Oo][Pp][Pp][Oo]*|*[Oo]ne[Pp]lus*|*[Rr]ealme*|*[Rr]eal[Mm]e*)
      if _rom_has_dir /system_ext/oplus /my_product /my_stock; then
        echo "coloros"; return 0
      fi ;;
  esac
  if _rom_has_dir /system_ext/oplus /my_product; then echo "coloros"; return 0; fi

  # ---- 3. OriginOS / vivo / iQOO ----
  _prop_get ro.vivo.os.name;                vname="$PROP_V"
  _prop_get ro.vivo.product.version;        strong="$PROP_V"
  case "$vname $strong" in
    *[Oo]rigin[Oo][Ss]*|*[Ff]untouch*) echo "originos"; return 0 ;;
  esac
  case "$vbrand $vmanu" in
    *vivo*|*VIVO*|*iQOO*|*iqoo*|*IQOO*)
      if _rom_has_dir /system_ext/etc/vivo /vendor/etc/vivo /system/etc/vivo /data/vivo; then
        echo "originos"; return 0
      fi ;;
  esac

  # ---- 4. Flyme / 魅族 ----
  case "$vdisplay" in
    *Flyme*|*flyme*|*FLYME*) echo "flyme"; return 0 ;;
  esac
  _prop_get ro.flyme.version;               strong="$PROP_V"
  [ -n "$strong" ] && { echo "flyme"; return 0; }
  case "$vbrand $vmanu" in
    *Meizu*|*MEIZU*|*meizu*)
      if _rom_has_dir /system/etc/flyme /system/flyme /data/customizecenter; then
        echo "flyme"; return 0
      fi ;;
  esac

  # ---- 5. 荣耀 MagicOS（先于华为判断：荣耀的属性里也带 hw 字样）----
  _prop_get ro.build.version.magic;         strong="$PROP_V"
  [ -n "$strong" ] || { _prop_get ro.honor.build.version; strong="$PROP_V"; }
  if [ -n "$strong" ]; then echo "honor"; return 0; fi
  case "$vbrand $vmanu" in
    *HONOR*|*honor*|*Honor*)
      if _rom_has_dir /system/etc/honor /system_ext/etc/honor /product/etc/honor; then
        echo "honor"; return 0
      fi ;;
  esac

  # ---- 6. 华为 EMUI / HarmonyOS(AOSP 兼容版) ----
  _prop_get ro.build.version.emui;          strong="$PROP_V"
  [ -n "$strong" ] || { _prop_get ro.build.hw_emui_api_level; strong="$PROP_V"; }
  [ -n "$strong" ] || { _prop_get ro.huawei.build.version; strong="$PROP_V"; }
  if [ -n "$strong" ]; then echo "huawei"; return 0; fi
  case "$vbrand $vmanu" in
    *HUAWEI*|*huawei*|*Huawei*)
      if _rom_has_dir /system/etc/huawei /system_ext/etc/huawei /hw_product; then
        echo "huawei"; return 0
      fi ;;
  esac

  # ---- 7. 三星 One UI ----
  _prop_get ro.build.version.oneui;         strong="$PROP_V"
  [ -n "$strong" ] || { _prop_get ro.build.version.sem; strong="$PROP_V"; }
  [ -n "$strong" ] || { _prop_get ro.config.knox; strong="$PROP_V"; }
  if [ -n "$strong" ]; then echo "samsung"; return 0; fi
  case "$vbrand $vmanu" in
    *samsung*|*SAMSUNG*|*Samsung*)
      if _rom_has_dir /system/etc/floating_feature.xml /system/etc/samsung /system/samsung; then
        echo "samsung"; return 0
      fi ;;
  esac

  # ---- 8. Nothing OS ----
  _prop_get ro.nothing.build.version;       strong="$PROP_V"
  [ -n "$strong" ] && { echo "nothing"; return 0; }
  case "$vbrand $vmanu" in
    *Nothing*|*nothing*|*NOTHING*)
      if _rom_has_dir /system/etc/nothing /system_ext/etc/nothing; then
        echo "nothing"; return 0
      fi ;;
  esac

  # ---- 9. 兜底：原生 AOSP / 类原生 / 谷歌 Pixel / GSI / 其他 ----
  echo "aosp"; return 0
}

# ---------------------------------------------------------------------------
# ROM 标识 -> 中文名
# ---------------------------------------------------------------------------
rom_name() {
  case "$1" in
    hyperos)  echo "澎湃OS/HyperOS/MIUI" ;;
    coloros)  echo "ColorOS/OPPO/一加/realme" ;;
    originos) echo "OriginOS/vivo/iQOO" ;;
    flyme)    echo "Flyme/魅族" ;;
    samsung)  echo "三星 One UI" ;;
    honor)    echo "荣耀 MagicOS（自动发现）" ;;
    huawei)   echo "华为 EMUI/鸿蒙（自动发现）" ;;
    nothing)  echo "Nothing OS（自动发现）" ;;
    aosp)     echo "原生/类原生/谷歌Pixel" ;;
    *)        echo "未知系统" ;;
  esac
}

# ---------------------------------------------------------------------------
# Root 管理器：magisk | ksu | apatch | unknown
# 模块脚本运行时 KernelSU 会设置 KSU=true，APatch 会设置 APATCH=true
# ---------------------------------------------------------------------------
root_manager() {
  if [ "$APATCH" = true ] || [ -x /data/adb/apd ]; then echo apatch; return 0; fi
  if [ "$KSU" = true ] || [ -x /data/adb/ksud ]; then echo ksu; return 0; fi
  if [ -n "$MAGISK_VER_CODE" ] || command -v magisk >/dev/null 2>&1 || [ -d /data/adb/magisk ]; then echo magisk; return 0; fi
  echo unknown
}

# ---------------------------------------------------------------------------
# root_manager_strict —— 「只认实锤」版：**用于诊断报告，不要用它决定装模块的方式**
#
# 为什么需要它（2026-10-12 真机踩到）：
#   换过 Root 管理器的机器上，旧 Magisk 的痕迹会长期留着（`/data/adb/magisk`、`magisk.db`，
#   有的 APatch 版本还会提供 `/system/bin/magisk`，模块脚本里 `command -v magisk` 就命中了）。
#   上面那个 root_manager() 为了「装模块别装错」会在认不出管理器时兜底成 magisk ——
#   报告拿这个兜底值当真话，就会把一台**根本没装 KernelSU** 的机器说成"KernelSU 正在生效"。
#   所以报告里改用这个函数：**认不出就老实说认不出**，再由报告自己解释"为什么认不出"。
#
# 与 root_manager() 的区别只有一条：**去掉"看到 magisk 目录/命令就认定为 magisk"这条弱判据**。
# 真正在跑 Magisk 时会带 MAGISK_VER_CODE / MAGISK_VER 环境变量，这条仍然认。
#
# 注意：心跳日志 boot_events.log 里的 manager= 字段**仍然用 root_manager()**（保持原样，
# 免得有工具在对它做解析）—— 所以在没有 magisk 痕迹的沙箱里会看到 manager=unknown，属正常。
# ---------------------------------------------------------------------------
root_manager_strict() {
  if [ "$APATCH" = true ] || [ -x /data/adb/apd ]; then echo apatch; return 0; fi
  if [ "$KSU" = true ] || [ -x /data/adb/ksud ]; then echo ksu; return 0; fi
  if [ -n "$MAGISK_VER_CODE" ] || [ -n "${MAGISK_VER:-}" ]; then echo magisk; return 0; fi
  echo ""
}

root_manager_name() {
  case "$1" in
    magisk) echo "Magisk" ;;
    ksu)    echo "KernelSU 系" ;;
    apatch) echo "APatch" ;;
    *)      echo "未识别" ;;
  esac
}

# Root 管理器自带的 busybox（带 wget）
find_busybox() {
  local b
  for b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    [ -x "$b" ] && { echo "$b"; return 0; }
  done
  command -v busybox 2>/dev/null
}

# ---------------------------------------------------------------------------
# 小工具：判断是否纯数字 / 取当前秒数
#
# now_s 为什么放在 common.sh（1.0.9.2 修正）：
#   它原来只定义在 diag.sh 里。但 app_side_probe（/proc 抽样那段的超时判断）
#   也要用它 —— 而回归测试只 source 了 common.sh / slots.sh，
#   于是测试里报 `now_s: not found`，整个 /proc 抽样静默失败
#   （真机报告中表现为"App 侧抽样一个都没采到"）。
#   这类"函数只定义在某个脚本里、却被别的脚本依赖"的坑，放共享文件里最稳妥。
# ---------------------------------------------------------------------------
isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
now_s() { _NS_D=$(date +%s 2>/dev/null); isnum "$_NS_D" && printf '%s' "$_NS_D" || printf '0'; }

# ---------------------------------------------------------------------------
# 「完整性声明」的记账函数（1.0.9.2）
#   任何一节被超时/跳过都要记一笔，报告最前面会列出来 —— 规则：宁可难看，不许静默。
#   放在 common.sh 而不是 diag.sh：app_side_probe 里的 /proc 抽样超时要用它，
#   而回归测试是从 diag.sh 里**抠函数**出来跑的（diag.sh 有主流程，不能直接 source），
#   抠出来的函数拿不到 diag.sh 里的其它函数。放共享文件里，谁 source 谁就有。
# ---------------------------------------------------------------------------
DIAG_SKIPS=""
skip_note() {   # skip_note <小节名> <为什么> [怎么补回来]
  DIAG_SKIPS="$DIAG_SKIPS$1|$2|${3:-}
"
  return 0
}
skip_count() { printf '%s' "$DIAG_SKIPS" | grep -c . 2>/dev/null; }

# ---------------------------------------------------------------------------
# 持久化设置：保存在字体库目录，更新模块不会丢（卸载时一并删除）
# ---------------------------------------------------------------------------
cfg_get() {
  # ★ 2026-10-25 提速（作者反馈：刷入/应用太慢）：
  #   原来每次调用都跑 `sed | tail | tr` 三个进程。生成计划时
  #   「每个字体 × 每个开关」会调几千次 → 光起进程就几十秒到几分钟。
  #   现在第一次把 settings.conf 整份读进内存（一次），之后纯 shell 查。
  if [ "${CFG_CACHE_READY:-0}" != 1 ]; then
    CFG_CACHE_READY=1
    if [ -f "$SETTINGS" ]; then
      while IFS='=' read -r _k _v; do
        case "$_k" in ''|'#'*) continue ;; esac
        case "$_k" in *[!A-Za-z0-9_]*) continue ;; esac
        eval "CFGV_$_k=\$_v"
      done < "$SETTINGS" 2>/dev/null
    fi
  fi
  eval "_cv=\${CFGV_$1:-}"
  if [ -n "${_cv:-}" ]; then
    printf '%s\n' "$_cv"
  else
    printf '%s\n' "$2"
  fi
  return 0
}
cfg_set() {
  local tmp="$SETTINGS.tmp.$$"
  mkdir -p "$LIB" 2>/dev/null
  { grep -v "^$1=" "$SETTINGS" 2>/dev/null; echo "$1=$2"; } > "$tmp" && mv -f "$tmp" "$SETTINGS"
  # 同步内存缓存（同一个进程里 set 完再 get 要能读到新值）
  case "$1" in
    ''|*[!A-Za-z0-9_]*) ;; *) eval "CFGV_$1=\$2" ;;
  esac
  # ★ 2026-10-25：角色判定的开关缓存也要作废，否则改完开关同一进程里不生效
  _RF_READY=0
  return 0
}

# 挂载方式：self = 模块自带挂载（默认，不依赖元模块）；manager = 交给 Root 管理器/元模块挂载
mount_mode() {
  # ★ 2026-10-25 危险区：force_manager=1 时一律按管理器挂载处理
  if [ "$(cfg_get force_manager 0 2>/dev/null)" = 1 ]; then
    echo manager
    return 0
  fi
  case "$(cfg_get mount_mode self)" in
    manager) echo manager ;;
    *)       echo self ;;
  esac
}

# ---------------------------------------------------------------------------
# .ttc 合集替换是否启用
#   ttc_replace=1 / 0  -> 用户手动指定，照办（界面上的开关写的就是这个值）
#   auto（默认/未设置）-> **不认机型，认事实**：只要这台机器的字体配置里存在
#                        「被中文（lang 以 zh 开头）引用的 .ttc 合集」，就说明中文是从
#                        合集里读的，单文件字体顶不了它（表现就是"英文变了、中文没变"）。
#                        没有这种合集就不开 —— 不开的情况一定不会更差。
# 实测覆盖：三星 SM-S9280（Android 16）、魅族 Flyme 12.6（Redmi 移植版）
#           两边索引约定完全相同：0=日 1=韩 2=简中 3=繁中。
# 判断依据放在字体配置里，所以换 ROM、换机型都不用改代码。
# ---------------------------------------------------------------------------
_rom_cached() {
  local r=""
  [ -n "${MODDIR:-}" ] && r=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/current_rom")
  [ -n "$r" ] || r=$(detect_rom)
  printf '%s\n' "$r"
}
ttc_enabled() {
  # CFS_NO_TTC=1：这一次不碰 .ttc 合集。开机阶段的"轻量补计划"会带上它 ——
  # 合成合集要读写几十 MB，在阻塞的 post-fs-data 里做会把老设备卡在开机动画上。
  [ -n "${CFS_NO_TTC:-}" ] && return 1
  case "$(cfg_get ttc_replace auto)" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  # 直接调用（不用 $(...) 包）：这样 ttc_cn_pairs 的缓存留在当前 shell 里，
  # 同一条命令里后面再问（比如逐个合集判序号）就不会重复扫字体配置了。
  ttc_cn_pairs >/dev/null 2>&1
  [ -n "$TTC_PAIRS_CACHE" ]
}
# 生效值（1/0），给界面和设置回显用
ttc_effective() { ttc_enabled && echo 1 || echo 0; }

# ---------------------------------------------------------------------------
# 管理器挂载模式下，目标路径（相对 /）-> 模块内路径
#   system/... 原样；vendor/product/system_ext 放到 system/ 下（Magisk/KSU 标准做法）；
#   其他厂商分区（my_product、mi_ext…）放在模块根目录，只有支持该分区的元模块才会挂载
# ---------------------------------------------------------------------------
mgr_path() {
  case "$1" in
    system/*) printf '%s\n' "$1" ;;
    vendor/*|product/*|system_ext/*) printf 'system/%s\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# 本次开机的唯一标识（判断挂载记录是不是这次开机写的）
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r\n'; }

# 手机正在关机 / 重启：长时间循环必须查这个，不然会拖着 init 的关机流程（"关不了机"的常见原因）
shutting_down() {
  [ -n "$(getp sys.powerctl)$(getp sys.shutdown.requested)" ]
}

# ---------------------------------------------------------------------------
# 开机心跳：记录每个开机阶段是否真的被执行过（诊断用，见 diag.sh）
# 只要脚本被 Root 管理器执行过，就会留下一条带 boot_id 的记录；
# 完全没有记录 = 脚本没被执行（模块被禁用 / 安全模式 / Magisk 共存 / UAPI 不匹配…）
# ---------------------------------------------------------------------------
beat() {
  local f="$LIB/boot_events.log" t tmp
  mkdir -p "$LIB" 2>/dev/null
  t=$(date +%s 2>/dev/null)
  tmp="$f.tmp.$$"
  { tail -n 40 "$f" 2>/dev/null
    echo "time=$t boot=$(boot_id) stage=$1 info=$2 manager=$(root_manager)"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}
