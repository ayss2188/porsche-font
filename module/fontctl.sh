#!/system/bin/sh
# 自定义字体切换模块 - 字体库管理 / 应用脚本（供 WebUI、安装脚本调用）
# 用法：
#   sh fontctl.sh status                      输出 A=<生效> P=<待生效> R=<系统> 等状态
#   sh fontctl.sh list                        列出字体库：id|名称|字节数|元数据
#   sh fontctl.sh ls <base64(目录)>           列出手机存储目录（文件夹 + ttf/otf）
#   sh fontctl.sh import <路径> [名称]         从手机存储导入字体（直接 cp，速度快）
#   sh fontctl.sh upload-start                开始分块上传（WebUI 文件选择器用）
#   sh fontctl.sh upload-finish <大小> [名称]  结束分块上传并入库
#   sh fontctl.sh rename <id> <新名称>
#   sh fontctl.sh delete <id> [id...]         删除（可多个；使用中的会跳过）
#   sh fontctl.sh apply <选择>                切换字体。选择：none | <id> | <中文id>+<英文id>
#   sh fontctl.sh reapply                     按当前待生效的选择重新生成（改设置后用）
#   sh fontctl.sh plan <选择>                 预览：将替换多少个槽位（不改动任何文件）
#   sh fontctl.sh setmeta <id> k=v [k=v...]   写入字体元数据（覆盖范围、scope 等）
#   sh fontctl.sh settings [get|set <k> <v>]  全局设置
#   sh fontctl.sh verify                      检查已替换的槽位当前是否真的生效
#   sh fontctl.sh relink                      修复断开的硬链接（节省空间，开机自动执行）
#   sh fontctl.sh conflicts                   列出其他同样修改系统字体的模块
#   sh fontctl.sh report [save]               诊断报告（save 则写到 Download 目录）
#   sh fontctl.sh diag <brief|full|install|save|bg [force] [fast]|state|text|textpage <off> <len>|partinfo|savenow|cancel|clean|estimate>  一键体检（原样转发给 diag.sh）
#   sh fontctl.sh sync                        开机后确认 pending -> active
#   sh fontctl.sh prop                        刷新 module.prop 描述
#   sh fontctl.sh ack                         清除"已自动恢复"提示
#
# 切换采用"先生成、再校验、最后提交"：新字体文件全部就绪才替换旧的，中途失败保留原来的字体。

MODDIR=$(cd "$(dirname "$0")" && pwd)
LIB=/data/adb/custom_font_lib
PART="$LIB/.upload.part"
# 直接读 /data/media/0 比走 /sdcard(FUSE) 快得多
STORAGE=${STORAGE:-/data/media/0}
[ -d "$STORAGE" ] || STORAGE=/storage/emulated/0

. "$MODDIR/common.sh" 2>/dev/null
. "$MODDIR/slots.sh" 2>/dev/null
. "$MODDIR/mount.sh" 2>/dev/null
mkdir -p "$LIB" 2>/dev/null
export TMPDIR="$LIB"

APPLIED="$MODDIR/slots.applied"
MODID=$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
[ -n "$MODID" ] || MODID=custom_font_switcher

# 旧版把设置放在模块目录（升级会被覆盖），迁移到字体库目录
[ -f "$SETTINGS" ] || { [ -f "$MODDIR/settings.conf" ] && cp -f "$MODDIR/settings.conf" "$SETTINGS" 2>/dev/null; }

# ---- 字体元数据：$LIB/<id>.meta，每行 key=value ----
meta_get() { sed -n "s/^$2=//p" "$LIB/$1.meta" 2>/dev/null | tail -n1 | tr -d '\r\n'; }
meta_set() {
  local tmp="$LIB/$1.meta.tmp.$$"
  case "$2" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
  case "$3" in *[!A-Za-z0-9_.-]*) return 1 ;; esac
  { grep -v "^$2=" "$LIB/$1.meta" 2>/dev/null; echo "$2=$3"; } > "$tmp" && mv -f "$tmp" "$LIB/$1.meta"
}
meta_compact() { tr '\n' ',' 2>/dev/null < "$LIB/$1.meta" | sed 's/,$//'; }

# 该字体实际使用的替换范围：用户指定 > 按覆盖范围自动判断
effective_scope() {
  local sc latin cjk
  case "$1" in *+*) echo combo; return ;; ""|none) echo all; return ;; esac
  sc=$(meta_get "$1" scope)
  case "$sc" in all|latin|cjk) echo "$sc"; return ;; esac
  latin=$(meta_get "$1" latin); cjk=$(meta_get "$1" cjk)
  if [ -z "$latin$cjk" ]; then echo all; return; fi      # 没有元数据：中英文都替换
  if [ "$cjk" = 1 ] && [ "$latin" = 1 ]; then echo all
  elif [ "$latin" = 1 ]; then echo latin
  elif [ "$cjk" = 1 ]; then echo cjk
  else echo latin; fi
}

clean_name() { printf '%s' "$1" | tr -d '|\\\r\n'; }

# 路径里不允许出现 .. 段或换行
bad_path() {
  case "$1" in
    ..|../*|*/..|*/../*) return 0 ;;
    *'
'*) return 0 ;;
  esac
  return 1
}

# 显示路径(/storage/emulated/0、/sdcard) -> 真实路径
to_real() {
  case "$1" in
    /storage/emulated/0)   echo "$STORAGE" ;;
    /storage/emulated/0/*) echo "$STORAGE${1#/storage/emulated/0}" ;;
    /sdcard)               echo "$STORAGE" ;;
    /sdcard/*)             echo "$STORAGE${1#/sdcard}" ;;
    *)                     echo "$1" ;;
  esac
}

name_of() {
  local n
  n=$(cat "$LIB/$1.name" 2>/dev/null | tr -d '\r\n')
  echo "${n:-$1}"
}

# ---- 选择：none | <id> | <中文id>+<英文id> ----
sel_cjk() { echo "${1%%+*}"; }
sel_lat() { echo "${1##*+}"; }
sel_ids() {
  case "$1" in
    ""|none) ;;
    *+*) echo "$(sel_cjk "$1")"; echo "$(sel_lat "$1")" ;;
    *) echo "$1" ;;
  esac
}

label_of() {
  case "$1" in
    ""|none) echo "无字体（系统默认）" ;;
    *+*) echo "中文 $(name_of "$(sel_cjk "$1")") + 英文 $(name_of "$(sel_lat "$1")")" ;;
    *) name_of "$1" ;;
  esac
}

cur_active()  { local v; v=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/active_font"); echo "${v:-none}"; }
cur_pending() { local v; v=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font"); echo "${v:-$(cur_active)}"; }

# 只接受 TTF / OTF（TTC 合集不能直接替换单文件槽位）
valid_font() {
  local m
  m=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$m" in
    00010000|4f54544f|74727565) return 0 ;;
  esac
  return 1
}

new_id() {
  local t i id
  t=$(date +%s); i=0; id="f$t"
  while [ -e "$LIB/$id.ttf" ] && [ "$i" -lt 1000 ]; do
    i=$((i+1)); id="f${t}_$i"
  done
  echo "$id"
}

id_ok() {
  case "$1" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
  [ -f "$LIB/$1.ttf" ]
}

check_id() {
  case "$1" in
    ""|*[!A-Za-z0-9_]*) echo "ERROR:非法的字体 ID"; exit 1 ;;
  esac
  [ -f "$LIB/$1.ttf" ] || { echo "ERROR:字体不存在"; exit 1; }
}

# 校验并规范化选择；非法时直接退出
check_sel() {
  local id
  case "$1" in
    ""|none) echo none; return 0 ;;
    *+*+*) echo "ERROR:选择格式不正确"; exit 1 ;;
  esac
  for id in $(sel_ids "$1"); do
    id_ok "$id" || { echo "ERROR:字体不存在或 ID 非法：$id"; exit 1; }
  done
  # 中英文选了同一个字体 = 普通单字体
  case "$1" in *+*) [ "$(sel_cjk "$1")" = "$(sel_lat "$1")" ] && { sel_cjk "$1"; return 0; } ;; esac
  echo "$1"
}

in_use() {
  local id
  for id in $(sel_ids "$(cur_active)") $(sel_ids "$(cur_pending)"); do
    [ "$id" = "$1" ] && return 0
  done
  return 1
}

# 入库：store_font <源文件> <名称> <cp|mv>
store_font() {
  local src="$1" name="$2" mode="$3" id dst
  if ! valid_font "$src"; then
    rm -f "$PART"
    echo "ERROR:不是有效的 TTF/OTF 字体文件（TTC 合集请先在电脑上用 tools/optimize_font.py --face 拆出单个字体）"
    return 1
  fi
  id=$(new_id); dst="$LIB/$id.ttf"
  if [ "$mode" = mv ]; then
    mv -f "$src" "$dst" 2>/dev/null || cp -f "$src" "$dst"
  else
    cp -f "$src" "$dst"
  fi
  if [ ! -s "$dst" ]; then
    rm -f "$dst"
    echo "ERROR:写入字体库失败（存储空间不足？）"
    return 1
  fi
  if [ "$mode" != mv ] && [ "$(wc -c < "$src")" != "$(wc -c < "$dst")" ]; then
    rm -f "$dst"
    echo "ERROR:复制不完整（存储空间不足？）"
    return 1
  fi
  chmod 644 "$dst" 2>/dev/null
  # 字体最终会被硬链接进模块目录，必须是 system_file 标签，否则 zygote 读不了
  chcon u:object_r:system_file:s0 "$dst" 2>/dev/null
  [ -n "$name" ] || name=$(basename "$src" | sed 's/\.[^.]*$//')
  printf '%s' "$(clean_name "$name")" > "$LIB/$id.name"
  echo "OK:$id"
}

# 目录里是否存在真实字体文件（必须是文件；未匹配的通配符串会被 [ -f ] 挡掉）
_conf_fonts_in() {
  local f
  [ -d "$1" ] || return 1
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.[tT][tT][fFcC]|*.[oO][tT][fF]) return 0 ;; esac
  done
  return 1
}

# ---- 冲突检测：其他启用中、且会把字体挂到系统分区上的模块 ----
# 只认 system/ 下的 fonts 目录 + 根级的厂商分区（vendor/product/system_ext/odm/my_*…），
# 并排除 webroot/webui/web/assets/tools 这类界面/资源目录 —— 否则自带字体的 WebUI 模块
# （例如 ReZygisk 之类）会被误判成"其他字体模块"。
list_conflicts() {
  local m id d f hit name rel
  for m in /data/adb/modules/*; do
    [ -d "$m" ] || continue
    id=${m##*/}
    [ "$id" = "$MODID" ] && continue
    { [ -f "$m/disable" ] || [ -f "$m/remove" ]; } && continue
    hit=0
    for d in "$m"/system/fonts "$m"/system/*/fonts "$m"/system/*/*/fonts; do
      [ -d "$d" ] || continue
      _conf_fonts_in "$d" && { hit=1; break; }
    done
    if [ "$hit" = 0 ]; then
      for d in "$m"/*/fonts; do
        [ -d "$d" ] || continue
        rel=${d#"$m"/}
        case "$rel" in
          webroot/*|webui/*|WebUI/*|web/*|assets/*|docs/*|tools/*|lib/*|lib64/*) continue ;;
        esac
        _conf_fonts_in "$d" && { hit=1; break; }
      done
    fi
    if [ "$hit" = 0 ]; then
      for f in "$m"/system/etc/fonts.xml "$m"/system/etc/font_fallback.xml "$m"/system/etc/fonts_additional.xml; do
        [ -f "$f" ] && { hit=1; break; }
      done
    fi
    [ "$hit" = 1 ] || continue
    name=$(sed -n 's/^name=//p' "$m/module.prop" 2>/dev/null | head -n1 | tr -d '\r|')
    echo "$id|${name:-$id}"
  done
}

# 本次开机的挂载结果："ok fail stage"；不是本次开机写的则为空
mount_result() {
  local f="$MODDIR/mount.state"
  [ -f "$f" ] || return 0
  [ "$(sed -n 's/^boot=//p' "$f")" = "$(boot_id)" ] || return 0
  # ok fail stage same skip —— same/skip 一定要带上，否则界面上"成功 18"看着像丢了 6 个槽位
  echo "$(sed -n 's/^ok=//p' "$f") $(sed -n 's/^fail=//p' "$f") $(sed -n 's/^stage=//p' "$f") $(sed -n 's/^same=//p' "$f") $(sed -n 's/^skip=//p' "$f")"
}

refresh_prop() {
  local A P ROM_NAME D PROP_FILE warn=""
  A=$(cur_active); P=$(cur_pending)
  ROM_NAME=$(rom_name "$(cat "$MODDIR/current_rom" 2>/dev/null | tr -d '[:space:]')")
  [ -n "$(list_conflicts | head -n1)" ] && warn=" ⚠ 检测到其他字体模块，可能互相覆盖。"
  if [ "$A" = "$P" ]; then
    D="[系统：$ROM_NAME | 当前生效：$(label_of "$A")] 在 WebUI 导入自己的字体并切换，默认不替换任何字体。$warn"
  else
    D="[系统：$ROM_NAME | 当前生效：$(label_of "$A")，待重启后生效：$(label_of "$P")] 在 WebUI 导入自己的字体并切换，默认不替换任何字体。$warn"
  fi
  PROP_FILE="$MODDIR/module.prop"
  [ -f "$PROP_FILE" ] || return 0
  awk -v new="description=$D" '{ if ($0 ~ /^description=/) print new; else print $0 }' \
    "$PROP_FILE" > "$PROP_FILE.tmp" && mv "$PROP_FILE.tmp" "$PROP_FILE"
}

# 刷新 ROM 识别（OTA 后可能变化）
refresh_rom() {
  detect_rom > "$MODDIR/current_rom" 2>/dev/null
}

# 生成计划到文件（每行 "角色 目标路径"）；输出 scope
make_plan() {
  local sel="$1" out="$2" scope kl ks
  scope=$(effective_scope "$sel")
  kl=$(cfg_get keep_lang 1); ks=$(cfg_get keep_special 1)
  if [ "$scope" = combo ]; then
    slot_plan "$MODDIR" all "$kl" "$ks" > "$out"
  else
    slot_plan "$MODDIR" "$scope" "$kl" "$ks" > "$out"
  fi
  echo "$scope"
}

# 某个角色的槽位用哪个字体：组合模式下中文/混合主槽用中文字体，其余用英文字体
font_for_role() {
  case "$1" in
    *+*)
      case "$2" in
        cjk|main|lang) sel_cjk "$1" ;;
        *) sel_lat "$1" ;;
      esac ;;
    *) echo "$1" ;;
  esac
}

# 删掉旧的"管理器挂载"文件（按 slots.applied 记录）
remove_manager_files() {
  local rel p
  [ -f "$APPLIED" ] || return 0
  while IFS= read -r rel || [ -n "$rel" ]; do
    rel=$(printf '%s' "$rel" | tr -d '\r')
    case "$rel" in ""|/*|*..*) continue ;; esac
    p=$(mgr_path "$rel")
    rm -f "$MODDIR/$p" 2>/dev/null
    ( cd "$MODDIR" && rmdir -p "${p%/*}" 2>/dev/null )
  done < "$APPLIED"
}

# 提交：用已生成好的 stage 替换旧的字体文件 / 槽位记录
commit_payload() {
  local stage="$1" mode="$2" old_mode f
  old_mode=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")
  # 管理器模式的旧文件，以及旧版遗留的直接放在模块根目录的旧链接
  [ "$old_mode" = self ] || remove_manager_files
  rm -rf "$MODDIR/payload" 2>/dev/null

  if [ "$mode" = manager ]; then
    if [ -d "$stage" ]; then
      ( cd "$stage" && find . -type f ) | while IFS= read -r f; do
        f=${f#./}
        mkdir -p "$MODDIR/${f%/*}" 2>/dev/null
        mv -f "$stage/$f" "$MODDIR/$f"
      done
    fi
    rm -f "$MODDIR/skip_mount"
  else
    # 自带挂载开机时直接挂字体库里的文件，模块目录里不需要任何副本
    touch "$MODDIR/skip_mount"
  fi
  rm -rf "$stage" 2>/dev/null

  if [ -f "$stage.list" ]; then mv -f "$stage.list" "$APPLIED"; else : > "$APPLIED"; fi
  if [ -f "$stage.map" ]; then mv -f "$stage.map" "$MODDIR/slots.map"; else : > "$MODDIR/slots.map"; fi
  echo "$mode" > "$MODDIR/payload.mode"
}

do_apply() {
  local sel scope plan role rel id src dest stage mode COUNT=0 fail=0
  sel=$(check_sel "$1") || { echo "$sel"; exit 1; }
  refresh_rom
  mode=$(mount_mode)
  plan="$LIB/.plan.$$"
  stage="$MODDIR/.stage.$$"
  rm -rf "$MODDIR"/.stage.* 2>/dev/null
  scope=none

  if [ "$sel" != none ]; then
    scope=$(make_plan "$sel" "$plan")
    if [ ! -s "$plan" ]; then
      rm -f "$plan"
      echo "ERROR:没有找到可替换的槽位（范围：$scope）。可到设置里关闭「保留…」选项，或查看诊断报告"
      exit 1
    fi
    for id in $(sel_ids "$sel"); do
      chmod 644 "$LIB/$id.ttf" 2>/dev/null
      chcon u:object_r:system_file:s0 "$LIB/$id.ttf" 2>/dev/null
    done

    # 1. 生成：自带挂载只需记录 槽位 -> 字体；管理器挂载要在模块里放文件（硬链接不额外占空间）
    mkdir -p "$stage"
    : > "$stage.list"
    : > "$stage.map"
    while read -r role rel; do
      [ -n "$rel" ] || continue
      id=$(font_for_role "$sel" "$role")
      src="$LIB/$id.ttf"
      if [ "$mode" = manager ]; then
        dest="$stage/$(mgr_path "$rel")"
        mkdir -p "${dest%/*}" 2>/dev/null
        if ! ln -f "$src" "$dest" 2>/dev/null; then
          # 2. 校验：复制出来的文件必须完整
          if ! cp -f "$src" "$dest" 2>/dev/null || [ "$(wc -c < "$dest")" != "$(wc -c < "$src")" ]; then
            fail=1; break
          fi
          chmod 644 "$dest" 2>/dev/null
          chcon u:object_r:system_file:s0 "$dest" 2>/dev/null
        fi
      fi
      echo "$rel" >> "$stage.list"
      echo "$id $rel" >> "$stage.map"
      COUNT=$((COUNT+1))
    done < "$plan"
    rm -f "$plan"

    if [ "$fail" = 1 ] || [ "$COUNT" = 0 ]; then
      rm -rf "$stage" "$stage.list" "$stage.map"
      echo "ERROR:生成字体文件失败（存储空间不足？），已保留原来的字体"
      exit 1
    fi
  fi

  # 3. 提交
  commit_payload "$stage" "$mode"
  echo "$sel" > "$MODDIR/pending_font"
  echo "$sel" > "$LIB/last_selection"
  [ -f "$MODDIR/active_font" ] || echo none > "$MODDIR/active_font"
  refresh_prop
  echo "OK:$(label_of "$sel"):$COUNT:$scope"
}

do_report() {
  local A P id mr v
  A=$(cur_active); P=$(cur_pending)
  # 一键体检的结论放最前面（见 diag.sh）
  [ -f "$MODDIR/diag.sh" ] && sh "$MODDIR/diag.sh" brief 2>/dev/null
  echo "== 自定义字体切换模块 诊断报告 =="
  echo "模块版本: $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null) ($(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null))"
  echo "设备: $(getp ro.product.brand) $(getp ro.product.model) | Android $(getp ro.build.version.release) (SDK $(getp ro.build.version.sdk))"
  echo "系统: $(detect_rom) / $(rom_name "$(detect_rom)")"
  echo "构建号: $(getp ro.build.display.id)"
  echo "Root: $(root_manager_name "$(root_manager)")$(command -v magisk >/dev/null 2>&1 && echo " $(magisk -v 2>/dev/null)")"
  echo "内存: $(sed -n 's/^MemTotal: *//p' /proc/meminfo 2>/dev/null)  可用: $(sed -n 's/^MemAvailable: *//p' /proc/meminfo 2>/dev/null)"
  echo "---- 字体 ----"
  echo "当前生效: $(label_of "$A") ($A)"
  echo "待生效:   $(label_of "$P") ($P)"
  for id in $(sel_ids "$P"); do
    [ -f "$LIB/$id.ttf" ] || continue
    echo "  $(name_of "$id"): $(( $(wc -c < "$LIB/$id.ttf") / 1024 )) KB | 范围 $(effective_scope "$id") | 元数据 $(meta_compact "$id")"
  done
  echo "设置: keep_lang=$(cfg_get keep_lang 1) keep_special=$(cfg_get keep_special 1) mount_mode=$(mount_mode)"
  echo "字体库: $(ls "$LIB"/f*.ttf 2>/dev/null | wc -l) 个，占用 $(du -sk "$LIB" 2>/dev/null | cut -f1) KB"
  echo "---- 槽位 ----"
  echo "字体目录: $(slot_dirs | tr '\n' ' ')"
  echo "字体配置: $(slot_xml_files | tr '\n' ' ')"
  echo "候选统计: $(slot_report "$MODDIR")"
  echo "已应用槽位: $(wc -l 2>/dev/null < "$APPLIED" | tr -d ' ')（方式：$(cat "$MODDIR/payload.mode" 2>/dev/null)）"
  echo "---- 挂载 ----"
  mr=$(mount_result)
  if [ -n "$mr" ]; then
    set -- $mr
    echo "本次开机自带挂载: 成功 $1 / 失败 $2（阶段 $3）"
  else
    echo "本次开机自带挂载: 未执行（无字体、管理器挂载模式，或尚未重启）"
  fi
  [ -f "$MODDIR/mount_missed" ] && echo "提示: 本次开机没有执行挂载，Root 管理器可能不支持 post-mount 阶段，可改用「交给管理器挂载」"
  v=$(payload_verify "$MODDIR")
  echo "实际生效检测: ${v% *} / ${v#* }（待生效与当前生效不同时，重启前此项为旧状态）"
  echo "skip_mount: $([ -f "$MODDIR/skip_mount" ] && echo 有 || echo 无)"
  echo "冲突模块: $(list_conflicts | cut -d'|' -f2 | tr '\n' ' ')"
  echo "谷歌字体兼容: $(sh "$MODDIR/google_font.sh" status 2>/dev/null)"
  echo "模块目录占用: $(du -sk "$MODDIR" 2>/dev/null | cut -f1) KB"
  echo "/data 剩余: $(df -k /data 2>/dev/null | tail -n1 | tr -s ' ' | cut -d' ' -f4) KB"
  [ -f "$MODDIR/rescued" ] && echo "提示: 上次开机未完成，已触发自动恢复"
  return 0
}

case "${1:-}" in
  status)
    A=$(cur_active); P=$(cur_pending)
    echo "A=$A"
    echo "P=$P"
    echo "R=$(cat "$MODDIR/current_rom" 2>/dev/null | tr -d '[:space:]')"
    if [ -f "$MODDIR/rescued" ]; then echo "X=1"; else echo "X=0"; fi
    echo "N=$(wc -l 2>/dev/null < "$APPLIED" | tr -d ' ')"
    echo "S=$(effective_scope "$P" 2>/dev/null)"
    echo "M=$(mount_mode)"
    echo "PM=$(cat "$MODDIR/payload.mode" 2>/dev/null | tr -d '[:space:]')"
    echo "RM=$(root_manager)"
    echo "V=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
    echo "MO=$(mount_result | tr ' ' ',')"
    echo "VF=$(payload_verify "$MODDIR" | tr ' ' ',')"
    if [ -f "$MODDIR/mount_missed" ]; then echo "MM=1"; else echo "MM=0"; fi
    echo "CF=$(list_conflicts 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')"
    ;;
  ack)
    rm -f "$MODDIR/rescued"
    echo "OK"
    ;;
  ls)
    d=$(printf '%s' "$2" | base64 -d 2>/dev/null)
    bad_path "$d" && { echo "ERROR:路径不允许"; exit 1; }
    r=$(to_real "$d")
    case "$r" in "$STORAGE"|"$STORAGE"/*) ;; *) echo "ERROR:路径不允许"; exit 1 ;; esac
    [ -d "$r" ] || { echo "ERROR:不是文件夹"; exit 1; }
    echo "P|$d"
    ls -1p "$r" 2>/dev/null | head -n 2000 | while IFS= read -r n; do
      case "$n" in ""|*'|'*) continue ;; esac
      case "$n" in
        */) echo "D|${n%/}" ;;
        *.[tT][tT][fF]|*.[oO][tT][fF]) echo "F|$n|$(stat -c %s "$r/$n" 2>/dev/null)" ;;
      esac
    done
    ;;
  list)
    for f in "$LIB"/f*.ttf; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .ttf)
      echo "$id|$(name_of "$id")|$(wc -c < "$f" | tr -d ' ')|$(meta_compact "$id")"
    done
    ;;
  import)
    bad_path "$2" && { echo "ERROR:路径不允许"; exit 1; }
    src=$(to_real "$2")
    [ -f "$src" ] || src="$2"
    [ -f "$src" ] || { echo "ERROR:找不到文件：$2"; exit 1; }
    out=$(store_font "$src" "$3" cp); rc=$?
    echo "$out"; exit $rc
    ;;
  upload-start)
    mkdir -p "$LIB"; : > "$PART"
    echo "OK"
    ;;
  upload-finish)
    [ -f "$PART" ] || { echo "ERROR:没有待处理的上传"; exit 1; }
    if [ -n "$2" ] && [ "$(wc -c < "$PART" | tr -d ' ')" != "$2" ]; then
      rm -f "$PART"
      echo "ERROR:传输不完整，请重试（或改用「扫描」导入）"
      exit 1
    fi
    out=$(store_font "$PART" "$3" mv); rc=$?
    echo "$out"; exit $rc
    ;;
  rename)
    check_id "$2"
    [ -n "$3" ] || { echo "ERROR:名称不能为空"; exit 1; }
    printf '%s' "$(clean_name "$3")" > "$LIB/$2.name"
    refresh_prop
    echo "OK"
    ;;
  delete)
    shift
    DEL=0; SKIP=0
    for id in "$@"; do
      case "$id" in ""|*[!A-Za-z0-9_]*) continue ;; esac
      [ -f "$LIB/$id.ttf" ] || continue
      if in_use "$id"; then
        SKIP=$((SKIP+1)); continue
      fi
      rm -f "$LIB/$id.ttf" "$LIB/$id.name" "$LIB/$id.meta"
      DEL=$((DEL+1))
    done
    echo "OK:$DEL:$SKIP"
    ;;
  apply)
    do_apply "$2"
    ;;
  reapply)
    do_apply "$(cur_pending)"
    ;;
  plan)
    sel=$(check_sel "${2:-none}") || { echo "$sel"; exit 1; }
    refresh_rom
    p="$LIB/.plan.$$"
    if [ "$sel" = none ]; then : > "$p"; sc=none; else sc=$(make_plan "$sel" "$p"); fi
    echo "PLAN:$sc:$(wc -l < "$p" | tr -d ' ')"
    rm -f "$p"
    ;;
  setmeta)
    check_id "$2"
    id="$2"; shift 2
    for kv in "$@"; do
      case "$kv" in *=*) ;; *) echo "ERROR:元数据格式不正确：$kv"; exit 1 ;; esac
      meta_set "$id" "${kv%%=*}" "${kv#*=}" || { echo "ERROR:元数据格式不正确：$kv"; exit 1; }
    done
    echo "OK"
    ;;
  settings)
    case "$2" in
      set)
        case "$3" in
          keep_lang|keep_special)
            case "$4" in 0|1) ;; *) echo "ERROR:取值只能是 0 或 1"; exit 1 ;; esac ;;
          mount_mode)
            case "$4" in self|manager) ;; *) echo "ERROR:取值只能是 self 或 manager"; exit 1 ;; esac ;;
          *) echo "ERROR:未知设置项"; exit 1 ;;
        esac
        cfg_set "$3" "$4"; echo "OK"
        ;;
      *)
        echo "keep_lang=$(cfg_get keep_lang 1) keep_special=$(cfg_get keep_special 1) mount_mode=$(mount_mode)"
        ;;
    esac
    ;;
  verify)
    payload_verify "$MODDIR"
    ;;
  relink)
    # 管理器挂载模式：部分管理器更新模块时是"复制"而不是"移动"，硬链接会断开，每个槽位各占一份空间。
    # 这里把断开的重新链回字体库。自带挂载模式没有副本，不需要处理。
    n=0
    pm=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")
    [ "$pm" = manager ] && [ -s "$MODDIR/slots.map" ] || { echo "OK:0"; exit 0; }
    while read -r id rel src; do
      id_ok "$id" || continue
      case "$rel" in ""|/*|*..*) continue ;; esac
      [ -n "$src" ] || src="$LIB/$id.ttf"
      dst="$MODDIR/$(mgr_path "$rel")"
      [ -f "$dst" ] || continue
      [ "$(stat -c %i "$src" 2>/dev/null)" = "$(stat -c %i "$dst" 2>/dev/null)" ] && continue
      ln -f "$src" "$dst.tmp.$$" 2>/dev/null && mv -f "$dst.tmp.$$" "$dst" && n=$((n+1))
      rm -f "$dst.tmp.$$" 2>/dev/null
    done < "$MODDIR/slots.map"
    echo "OK:$n"
    ;;
  conflicts)
    list_conflicts
    ;;
  report)
    # 有 diag.sh 时，报告就是「一键体检」（结论在最上面 + 10 节明细）
    if [ -f "$MODDIR/diag.sh" ]; then
      if [ "$2" = save ]; then sh "$MODDIR/diag.sh" save; else sh "$MODDIR/diag.sh" full; fi
    elif [ "$2" = save ]; then
      out="/sdcard/Download/font_switcher_report.txt"
      mkdir -p /sdcard/Download 2>/dev/null
      do_report > "$out" 2>&1 && echo "OK:$out" || echo "ERROR:写入失败"
    else
      do_report
    fi
    ;;
  diag)
    if [ -f "$MODDIR/diag.sh" ]; then
      # 原样转发后面所有参数：diag bg force fast / diag textpage 60000 60000 / diag state ...
      shift
      [ -n "${1:-}" ] || set -- full
      sh "$MODDIR/diag.sh" "$@"
    else
      echo "ERROR:缺少 diag.sh"
    fi
    ;;
  sync)
    [ -f "$MODDIR/pending_font" ] && cp -f "$MODDIR/pending_font" "$MODDIR/active_font"
    cp -f "$MODDIR/active_font" "$LIB/last_selection" 2>/dev/null
    refresh_prop
    ;;
  prop)
    refresh_prop
    ;;
  *)
    echo "用法: sh fontctl.sh status|list|import|upload-start|upload-finish|ls|rename|delete|apply|reapply|plan|setmeta|settings|verify|relink|conflicts|report|diag|sync|prop|ack"
    exit 2
    ;;
esac
