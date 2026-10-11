#!/system/bin/sh
# 保时捷字体（内置配色版）- 公共函数库（换皮自主项目的 custom_font_switcher）
# 提供：系统识别 / 系统名称 / Root 管理器识别 / 持久化设置 / 挂载路径映射
# 槽位发现见 slots.sh，自带挂载见 mount.sh；脚本中通过 source 引入
#
# ⚠️ 本项目对主项目源码的固定改动，同步主项目时**必须重放**（清单见接手文档第 17 节）：
#    1. 本文件：lib_font_ids / lib_font_files（内置配色是 builtin_*.ttf，主项目只认 f<数字>）
#    2. module.prop：id / name / version / versionCode / description / updateJson
#    3. builtin.sh + builtin/（内置配色注入 + 刷入时音量键选配色）
#    4. customize.sh：接 builtin_* 的三处调用
#    5. webroot/index.html：内置配色版界面（去掉导入/改名/多选删除）+ 模块目录运行时探测
#    6. fontctl.sh / diag.sh：模块 id 兜底扫 porsche_font_*（别写死主项目的 id）
#    7. uninstall.sh：字体库共用判断扫 porsche_font_*

LIB=${LIB:-/data/adb/custom_font_lib}
SETTINGS="$LIB/settings.conf"

getp() { getprop "$1" 2>/dev/null | tr -d '\r\n'; }

# ---------------------------------------------------------------------------
# 字体库枚举：库里"算数的字体"有哪些
#
# ⚠️ 内置配色版必须同时认两种命名，只认一种会出大事：
#     f<时间戳>     用户导入的（fontctl.sh 的 new_id 生成）—— 主项目只有这一种
#     builtin_xxx   本模块自带的配色（builtin.sh 的 builtin_import 注入）
#   如果哪里只 glob f*.ttf，界面就列不出任何配色、诊断报告也会写"字体库 0 个"，
#   用户会以为模块装坏了。所以统一走这两个函数，别再各处手写 glob。
#
# 放在 common.sh 的原因：fontctl.sh 和 diag.sh 都要用，而 diag.sh 只 source
# common.sh / slots.sh / mount.sh，**不 source fontctl.sh**。
# ---------------------------------------------------------------------------
lib_font_ids() {
  local f
  for f in "$LIB"/f[0-9]*.ttf "$LIB"/builtin_*.ttf; do
    [ -f "$f" ] || continue
    basename "$f" .ttf
  done
}

lib_font_files() {
  local f
  for f in "$LIB"/f[0-9]*.ttf "$LIB"/builtin_*.ttf; do
    [ -f "$f" ] || continue
    echo "$f"
  done
}

# ---------------------------------------------------------------------------
# 识别当前 ROM：
#   专项适配（有已知文件名清单）：hyperos | coloros | originos | flyme
#   通用适配（靠真实字体目录 + 字体配置 XML 发现槽位）：samsung | honor | huawei | nothing | aosp
# ---------------------------------------------------------------------------
detect_rom() {
  local vname vdisplay vbrand vmanu

  # 1. 澎湃OS / HyperOS / MIUI（小米/红米/POCO）
  if [ -n "$(getp ro.mi.os.version.name)" ] || [ -n "$(getp ro.miui.ui.version.code)" ]; then
    echo "hyperos"; return 0
  fi

  # 2. ColorOS / OPPO / 一加 / realme（oplus 系）
  if [ -n "$(getp ro.build.version.oplusrom)" ] || [ -d /data/oplus/os ] || [ -d /system_ext/oplus ]; then
    echo "coloros"; return 0
  fi

  # 3. OriginOS / vivo / iQOO
  vname=$(getp ro.vivo.os.name)
  vdisplay=$(getp ro.build.display.id)
  vbrand=$(getp ro.product.brand)
  vmanu=$(getp ro.product.manufacturer)
  case "$vname $vdisplay" in
    *OriginOS*|*originos*) echo "originos"; return 0 ;;
  esac
  case "$vbrand $vmanu" in
    *vivo*|*VIVO*|*iQOO*|*iqoo*|*IQOO*)
      [ -n "$vname$vdisplay" ] && { echo "originos"; return 0; }
      ;;
  esac

  # 4. Flyme / 魅族
  case "$vdisplay" in
    *Flyme*|*flyme*) echo "flyme"; return 0 ;;
  esac
  case "$vbrand $vmanu" in
    *Meizu*|*MEIZU*|*meizu*) echo "flyme"; return 0 ;;
  esac

  # 5. 荣耀 MagicOS（先于华为判断：荣耀的 build 属性里也带 hw 字样）
  if [ -n "$(getp ro.build.version.magic)" ] || [ -n "$(getp ro.honor.build.version)" ]; then
    echo "honor"; return 0
  fi
  case "$vbrand $vmanu" in
    *HONOR*|*honor*|*Honor*) echo "honor"; return 0 ;;
  esac

  # 6. 华为 EMUI / HarmonyOS(AOSP 兼容版)
  if [ -n "$(getp ro.build.version.emui)" ] || [ -n "$(getp ro.build.hw_emui_api_level)" ]; then
    echo "huawei"; return 0
  fi
  case "$vbrand $vmanu" in
    *HUAWEI*|*huawei*|*Huawei*) echo "huawei"; return 0 ;;
  esac

  # 7. 三星 One UI
  if [ -n "$(getp ro.build.version.oneui)" ] || [ -n "$(getp ro.build.version.sem)" ]; then
    echo "samsung"; return 0
  fi
  case "$vbrand $vmanu" in
    *samsung*|*SAMSUNG*|*Samsung*) echo "samsung"; return 0 ;;
  esac

  # 8. Nothing OS
  case "$vbrand $vmanu" in
    *Nothing*|*nothing*|*NOTHING*) echo "nothing"; return 0 ;;
  esac

  # 9. 兜底：原生 AOSP / 类原生 / 谷歌 Pixel / GSI / 其他
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
    samsung)  echo "三星 One UI（通用适配）" ;;
    honor)    echo "荣耀 MagicOS（通用适配）" ;;
    huawei)   echo "华为 EMUI/鸿蒙（通用适配）" ;;
    nothing)  echo "Nothing OS（通用适配）" ;;
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
# 持久化设置：保存在字体库目录，更新模块不会丢（卸载时一并删除）
# ---------------------------------------------------------------------------
cfg_get() {
  local v
  v=$(sed -n "s/^$1=//p" "$SETTINGS" 2>/dev/null | tail -n1 | tr -d '[:space:]')
  echo "${v:-$2}"
}
cfg_set() {
  local tmp="$SETTINGS.tmp.$$"
  mkdir -p "$LIB" 2>/dev/null
  { grep -v "^$1=" "$SETTINGS" 2>/dev/null; echo "$1=$2"; } > "$tmp" && mv -f "$tmp" "$SETTINGS"
}

# 挂载方式：self = 模块自带挂载（默认，不依赖元模块）；manager = 交给 Root 管理器/元模块挂载
mount_mode() {
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
