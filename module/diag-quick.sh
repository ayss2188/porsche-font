#!/system/bin/sh
# ===========================================================================
# 快捷上报 —— 纯读现成数据 + 一次 glob 比对，**秒级**，不扫描不算哈希
#
# 作者要的：
#   ① 快 —— 不要像完整报告那样 24~29 分钟
#   ② 有"没被替换的"这种能直接拿去改适配清单的数据
#
# 「没被替换的」怎么算（两种来源，都不扫盘）：
#   A. slots.map  = 最后一次实际替换的槽位（现成文件）
#   B. 计划(.plan.$PID) 里出现、但盘上确实存在的字体名 —— 用 shell glob 比对
#      —— 计划里没出现的名字，就是"没进计划"的（这才是要改适配清单的）
#
# 为什么不靠 .cand.*：
#   实测 .cand 写在 ${TMPDIR:-/data/local/tmp}/.cand.$$（临时目录），
#   不是字体库；重启后可能已被清掉。而 .plan.$PID 在字体库里，稳定。
#   → 所以"候选"这一侧改成**直接问文件系统**（glob 是 shell 内建，不起进程）。
#
# 用法：
#   sh diag-quick.sh                 打印
#   sh diag-quick.sh file <路径>      写文件
#   sh diag-quick.sh size            只打印字节数
# ===========================================================================

MODDIR=${0%/*}
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/custom_font_switcher
case "$MODDIR" in .|"") MODDIR=$(pwd 2>/dev/null || echo /data/adb/modules/custom_font_switcher) ;; esac
LIB=/data/adb/custom_font_lib

CMD="${1:-print}"
OUT="${2:-}"

_p()  { getprop "$1" 2>/dev/null | tr -d '\r\n'; }
_one() { [ -f "$1" ] && head -n1 "$1" 2>/dev/null | tr -d '\r\n '; }
_all() { [ -f "$1" ] && tr -d '\r' < "$1" 2>/dev/null; }

# 最新的非空缓存（.plan.$PID 按 pid 命名，盘上会留好几轮）
_newest() {
  local pat="$1" best="" bestn=0 f base n
  for f in $pat; do
    [ -s "$f" ] || continue
    base=${f##*/}; n=${base##*.}
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    n=$((n + 0))
    [ "$n" -gt "$bestn" ] && { bestn=$n; best="$f"; }
  done
  printf '%s' "$best"
}
_hsz() {
  local k; k=$(printf '%s' "${1:-0}" | tr -dc '0-9'); [ -n "$k" ] || k=0
  if [ "$k" -ge 1048576 ] 2>/dev/null; then
    printf '%s.%s MB' "$((k/1048576))" "$(((k%1048576)*10/1048576))"
  elif [ "$k" -ge 1024 ] 2>/dev/null; then printf '%s KB' "$((k/1024))"
  else printf '%s B' "$k"; fi
}

build() {
  local ver code rom pend act mode slots_n lib_n lib_sz kl ks scope ttc
  local planf plan
  local d f b dirs missing n_missing

  ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
  code=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
  rom=$(_one "$MODDIR/current_rom")
  pend=$(_one "$MODDIR/pending_font")
  act=$(_one "$MODDIR/active_font")
  mode=$(_one "$MODDIR/payload.mode")
  slots_n=$(grep -c . "$MODDIR/slots.map" 2>/dev/null); [ -n "$slots_n" ] || slots_n=0
  planf=$(_newest "$LIB/.plan.*")
  plan=$(_all "$planf")

  lib_n=$(ls -1 "$LIB" 2>/dev/null | grep -cE '\.(ttf|otf|ttc)$'); [ -n "$lib_n" ] || lib_n=0
  lib_sz=$(du -sk "$LIB" 2>/dev/null | awk '{print $1}')
  [ -n "$lib_sz" ] && lib_sz=$((lib_sz*1024)) || lib_sz=0

  kl=$(sed -n 's/^keep_lang=//p'    "$MODDIR/settings.conf" 2>/dev/null | tail -n1 | tr -d '\r')
  ks=$(sed -n 's/^keep_special=//p' "$MODDIR/settings.conf" 2>/dev/null | tail -n1 | tr -d '\r')
  scope=$(sed -n 's/^scope=//p'     "$MODDIR/settings.conf" 2>/dev/null | tail -n1 | tr -d '\r')
  ttc=$(sed -n 's/^ttc_replace=//p' "$MODDIR/settings.conf" 2>/dev/null | tail -n1 | tr -d '\r')

  # =========================================================================
  printf '===== 字体模块 · 快捷报告 =====\n'
  printf '时间: %s\n' "$(date '+%Y-%m-%d %H:%M' 2>/dev/null)"
  printf '模块: %s (code %s)   系统识别: %s\n' "${ver:-?}" "${code:-?}" "${rom:-?}"
  printf '设备: %s %s | Android %s (SDK %s)\n' \
    "$(_p ro.product.brand)" "$(_p ro.product.model)" \
    "$(_p ro.build.version.release)" "$(_p ro.build.version.sdk)"
  printf '构建: %s   代号: %s\n' "$(_p ro.build.display.id)" "$(_p ro.product.device)"
  printf '\n'

  printf '== 状态 ==\n'
  printf '待生效=%s  当前生效=%s  %s\n' "${pend:-无}" "${act:-无}" \
    "$([ -n "$pend" ] && [ "$pend" = "$act" ] && printf '(已生效)' || printf '(未重启处理)')"
  printf '槽位计划=%s 个   字体库=%s 个/%s   挂载方式=%s\n' \
    "$slots_n" "$lib_n" "$(_hsz "$lib_sz")" "${mode:-?}"
  printf '设置: keep_lang=%s keep_special=%s scope=%s ttc=%s\n' \
    "${kl:-默认}" "${ks:-默认}" "${scope:-默认}" "${ttc:-默认}"
  printf '开机: post-fs-data=%s service=%s\n' \
    "$([ -f "$LIB/.boot.post-fs-data" ] && printf 有 || printf 未见)" \
    "$([ -f "$LIB/.boot.service" ] && printf 有 || printf 未见)"
  printf '\n'

  printf '== 实际替换的槽位（共 %s 个）==\n' "$slots_n"
  if [ "$slots_n" -gt 0 ] 2>/dev/null; then
    # ★ 2026-10-16：**必须限制行数**。真机实测：一台 AOSP 机器有 172 个槽位，
    #   全列出来 5KB+ —— 而邮件正文上限是 4000 字符，
    #   结果这份"槽位清单"把后面几段（挂载日志、值得注意的）全挤掉了。
    #   作者收到的邮件末尾就写着"(截断)"。
    #   所以只列前 24 个（够看出挂到哪些目录、文件名什么风格），其余报个数。
    awk -v lim=24 '{ n=split($2,a,"/"); d=""; for(i=1;i<n;i++) d=d (i>1?"/":"") a[i];
           if (d!=last) { if(last!="") printf "\n"; printf "  [%s]\n", d; last=d }
           cnt++;
           if (cnt<=lim) printf "    %s\n", a[n] }' "$MODDIR/slots.map" 2>/dev/null
    [ "$slots_n" -gt 24 ] && printf '    …（还有 %s 个，略 —— 完整清单在「导出完整报告」里）\n' "$((slots_n - 24))"
  else
    printf '  （空 —— 还没成功应用过）\n'
  fi
  printf '\n'

  # -----------------------------------------------------------------------
  # ★ 作者最需要的一段：盘上有、但计划里没有的
  # -----------------------------------------------------------------------
  printf '== 该换却没进计划的（只列"看着该换"的）==\n'
  if [ -z "$plan" ]; then
    printf '  （缺 .plan.* 缓存 —— 应用一次字体或重启后会生成）\n'
  else
    printf '  （来源 %s，%s 行）\n' "${planf##*/}" "$(printf '%s\n' "$plan" | grep -c .)"
    dirs=$(printf '%s\n' "$plan" | awk '{ n=split($2,a,"/"); d=""; for(i=1;i<n;i++) d=d (i>1?"/":"") a[i];
                  if(d=="") next;
                  # ★ 2026-10-16 修：计划里通常是相对路径（system/fonts/x.ttf），
                  #   但也可能是绝对路径 —— 无条件拼 "/" 会得到 "//data/..."，
                  #   [ -d ] 失败 → 整个检查被静默跳过 → 报告写"没有遗漏"（假结论）。
                  if (substr(d,1,1)=="/") print d; else print "/" d }' 2>/dev/null | sort -u)
    n_missing=0
    n_noise=0
    shown=0
    for d in $dirs; do
      [ -d "$d" ] || continue
      missing=""
      # glob 是 shell 内建：一次展开整个目录，不起进程
      for f in "$d"/*.ttf "$d"/*.otf "$d"/*.ttc "$d"/*.TTF "$d"/*.OTF; do
        [ -f "$f" ] || continue
        b=${f##*/}
        # 计划里出现过这个名字吗（含角色/目录的整行匹配）
        case "$plan" in
          *"/$b"*) continue ;;             # 在计划里 → 会替换，不算
        esac
        n_missing=$((n_missing + 1))
        # ★ 关键：把"本来就不该换"的滤掉 —— 跟 slots.sh 的准入规则一致。
        #   不滤的话，一台 AOSP 机器会列出几百个 NotoSansKhmer/Lao/Malayalam…
        #   真机反馈就是被这些占满、把有用信息挤出了 4000 字符上限。
        bl=$(printf '%s' "$b" | tr 'A-Z' 'a-z')
        case "$bl" in
          noto*|droid*|android*|*emoji*|*symbol*|*dingbat*|*braille*|*clock*|\
          *mono*|*italic*|*oblique*|*serif*|*myanmar*|*khmer*|*lao*|*thai*|\
          *devanagari*|*bengali*|*tamil*|*telugu*|*kannada*|*malayalam*|\
          *gujarati*|*gurmukhi*|*oriya*|*sinhala*|*tibetan*|*ethiopic*|\
          *hebrew*|*arabic*|*armenian*|*georgian*|*syriac*|*thaana*|\
          *cherokee*|*mongolian*|*javanese*|*balinese*|*sundanese*|*buginese*|\
          *batak*|*lepcha*|*limbu*|*olchiki*|*meetei*|*tirhuta*|*modi*|\
          *marchen*|*newa*|*bhaiksuki*|*sharada*|*takri*|*dogra*|*grantha*|\
          *saurashtra*|*cham*|*kayah*|*rejang*|*syloti*|*vai*|*bamum*|\
          *bassa*|*osage*|*adlam*|*nko*|*tifinagh*|*lineara*|*linearb*|\
          *cuneiform*|*hieroglyph*|*coptic*|*glagolitic*|*gothic*|*runic*|\
          *ogham*|*deseret*|*shavian*|*osmanya*|*phags*|*yi-*|*nushu*|\
          *tangut*|*duployan*|*miao*|*ahom*|*multani*|*khojki*|*khudawadi*|\
          *mahajani*|*siddham*|*soyombo*|*zanabazar*|*warang*|*elbasan*|\
          *caucasian*|*lycian*|*carian*|*lydian*|*phoenician*|*imperial*|\
          *meroitic*|*olditalic*|*oldpersian*|*oldsoutharabian*|*avestan*|\
          *brahmi*|*kaithi*|*sora*|*toto*|*vithkuqi*|*cypriot*|*linear*)
            n_noise=$((n_noise + 1)) ;;
          *)
            if [ "$shown" -lt 30 ]; then
              printf '    %s\n' "$b"
              shown=$((shown + 1))
            fi ;;
        esac
      done
    done
    printf '  合计 %s 个名字没进计划；其中"看着该换"的 %s 个（上面最多列 30 个）\n' \
      "$n_missing" "$shown"
    printf '  其余 %s 个是其它文字体系/符号字体 —— 本来就不该换，略过\n' "$n_noise"
    [ "$shown" = 0 ] && printf '  ✅ 没有发现"该换却没换"的\n'
  fi
  printf '\n'

  printf '== 计划全文 ==\n'
  if [ -n "$plan" ]; then
    # 计划可能上百行，全列会把后面的段落挤出长度上限 —— 只列前 40 行
    _pn=$(printf '%s\n' "$plan" | grep -c .)
    printf '%s\n' "$plan" | head -n 40 | sed 's/^/  /'
    [ "$_pn" -gt 40 ] && printf '  …（共 %s 行，其余略）\n' "$_pn"
  else
    printf '  （无）\n'
  fi
  printf '\n'

  printf '== 挂载日志 · 最后 6 条 ==\n'
  [ -f "$LIB/mount.log" ] && tail -n 6 "$LIB/mount.log" 2>/dev/null | sed 's/^/  /' || printf '  （无）\n'
  printf '\n'

  printf '== 值得注意的 ==\n'
  local any=0
  for f in /data/fonts/*.ttf /data/fonts/*.otf /data/fonts/*.ttc; do
    [ -f "$f" ] && { printf '  ! /data/fonts 有字体: %s\n' "$(ls -1 /data/fonts 2>/dev/null | head -n 6 | tr '\n' ' ')"; any=1; break; }
  done
  [ -f /data/customizecenter/font/flymeFont.ttf ] && { printf '  ! 厂商个性化字体 /data/customizecenter/font/flymeFont.ttf\n'; any=1; }
  for f in /data/system/theme/fonts/*.ttf /data/system/theme/fonts/*.otf; do
    [ -f "$f" ] && { printf '  ! 主题字体: %s\n' "$(ls -1 /data/system/theme/fonts 2>/dev/null | head -n 6 | tr '\n' ' ')"; any=1; break; }
  done
  # ColorOS 主题字体桥接目录：只报"有普通文件"的情况（那些我们确实没替换）
  if [ -d /data/format_unclear/font ]; then
    _of=$(ls -1 /data/format_unclear/font 2>/dev/null | grep -Ei '\.(ttf|otf|ttc)$' | head -n 8)
    if [ -n "$_of" ]; then
      _on=$(printf '%s\n' "$_of" | grep -c . 2>/dev/null); [ -n "$_on" ] || _on=0
      _ol=0
      while IFS= read -r _n; do
        [ -n "$_n" ] || continue
        [ -L "/data/format_unclear/font/$_n" ] && _ol=$((_ol + 1))
      done <<EOF_OQ
$_of
EOF_OQ
      _of2=$((_on - _ol))
      if [ "$_of2" -gt 0 ]; then
        printf '  ! ColorOS 主题字体目录 /data/format_unclear/font：%s 个条目，其中 %s 个普通文件（本模块没替换）\n' "$_on" "$_of2"
        any=1
      fi
    fi
  fi
  [ -e "$MODDIR/disable" ] && { printf '  ! 模块被禁用\n'; any=1; }
  [ -e "$MODDIR/remove" ]  && { printf '  ! 模块待卸载\n'; any=1; }
  [ "$any" = 0 ] && printf '  （无）\n'
  printf '\n'
  printf '== 说明 ==\n'
  printf '只读现成状态文件 + 一次目录名比对，不扫描内容、不算哈希。\n'
  printf '需要完整数据请用「导出完整报告」。\n'
}

# ---------------------------------------------------------------------------
# 兜底：把整份报告卡在 UI 的正文上限之内
#
# 为什么要这层：界面是拿这份文本当**邮件正文**发的（Web3Forms 正文上限 4000 字符），
# 超了就被服务端砍掉，而且砍的是**后半段**（挂载日志、值得注意的）——
# 真机上就发生过：作者收到的邮件末尾是"(截断)"，重要的几段没了。
#
# 上面每段各自限制了行数，但段数多、机型差异大，"各段都不超"不等于"合起来不超"。
# 所以这里做最后一道：真超了就在**末尾**明确打印一句，而不是让服务端静默切掉。
# 留 200 字节余量给界面自己加的尾巴。
# ---------------------------------------------------------------------------
LIMIT=${CFS_QUICK_MAX:-4000}
LIMIT=$((LIMIT - 200))
[ "$LIMIT" -gt 500 ] 2>/dev/null || LIMIT=3800

emit_limited() {
  _tmp=$(build 2>/dev/null)
  _n=$(printf '%s' "$_tmp" | wc -c | tr -d ' ')
  if [ -n "$_n" ] && [ "$_n" -gt "$LIMIT" ] 2>/dev/null; then
    # 按字节截可能切断一个多字节字符（末尾半个汉字）。
    # iconv 不带 -c 时遇到残缺序列会**报错并且不输出任何东西** ——
    # 所以先试 iconv，没输出就退回 head -c 原样。
    # （不用临时文件：某个版本的 $TMPD 根本没定义，写到 "$TMPD/cut.$$" 会变成 /cut.123
    #   根目录不可写 → 兜底静默失效。这个坑踩过了。）
    _cut=$(printf '%s' "$_tmp" | head -c "$LIMIT" | iconv -f UTF-8 -t UTF-8 2>/dev/null)
    if [ -n "$_cut" ]; then
      printf '%s' "$_cut"
    else
      printf '%s' "$_tmp" | head -c "$LIMIT"
    fi
    printf '\n（这份报告 %s 字符，超过邮件正文上限，已在此截断）\n' "$_n"
    printf '需要完整数据请用「查看 / 生成完整报告」，或把 Download/快捷报告.txt 直接发我。\n'
  else
    printf '%s' "$_tmp"
  fi
}

case "$CMD" in
  size)  emit_limited 2>/dev/null | wc -c | tr -d ' ' ;;
  file)  [ -n "$OUT" ] || OUT=/data/local/tmp/cfs-quick.txt
         emit_limited > "$OUT" 2>/dev/null
         printf 'OK:%s\n' "$OUT" ;;
  *)     emit_limited 2>/dev/null ;;
esac
exit 0
