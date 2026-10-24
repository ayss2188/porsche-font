#!/system/bin/sh
# logcatch.sh - 一键抓崩溃日志（给"某个 App 闪退 / WebUI 闪退"用）
#
#   sh logcatch.sh start     开始抓（后台记录，正常用手机就行）
#   sh logcatch.sh stop      停止并导出到 Download/崩溃日志_<时间>.txt
#   sh logcatch.sh status    看状态（on/off + 大小 + 已抓秒数）
#   sh logcatch.sh resume    开机续抓（service.sh 调用）
#   sh logcatch.sh upload    把最近一次导出上传给作者（走 curl，和诊断报告同一条通道）
#
# 状态文件写在 $MODDIR/webroot/logstate.txt —— 界面用 fetch 读它（异步、不卡），
# 不再每次轮询都调一次同步 exec。

MODDIR=${0%/*}
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"
LIB="${LIB:-/data/adb/custom_font_lib}"
D="$LIB/logs"
F="$D/catch.log"
PIDF="$D/logcat.pid"
ONF="$D/.on"
STF="$MODDIR/webroot/logstate.txt"
LASTF="$D/last_export.txt"

_now() { date '+%Y%m%d-%H%M%S' 2>/dev/null; }
_secs() { date '+%s' 2>/dev/null; }

_state() {   # $1=on|off  $2=pid  $3=bytes  $4=start_ts  $5=file
  mkdir -p "$MODDIR/webroot" 2>/dev/null
  {
    echo "state=${1}"
    echo "pid=${2:-}"
    echo "bytes=${3:-0}"
    echo "started=${4:-}"
    echo "now=$(_secs)"
    echo "file=${5:-}"
  } > "$STF" 2>/dev/null
  chmod 644 "$STF" 2>/dev/null
}

_running() {
  [ -f "$PIDF" ] || return 1
  _p=$(tr -dc '0-9' < "$PIDF" 2>/dev/null)
  case "$_p" in ''|0) return 1 ;; esac
  kill -0 "$_p" 2>/dev/null || return 1
  return 0
}

_do_start() {
  mkdir -p "$D" 2>/dev/null
  if _running; then
    echo "已经在抓了（pid $_p，$(wc -c < "$F" 2>/dev/null) 字节）"
    _state on "$_p" "$(wc -c < "$F" 2>/dev/null)" "$(cat "$D/.started" 2>/dev/null)" "$F"
    return 0
  fi
  [ "${1:-}" = resume ] || { rm -f "$F" "$F".* 2>/dev/null; }
  _t=$(_secs)
  printf '%s\n' "$_t" > "$D/.started" 2>/dev/null
  ( nohup logcat -b crash -b main -b system -b events -v threadtime \
      -f "$F" -r 4096 -n 6 >/dev/null 2>&1 & echo $! > "$PIDF" ) 2>/dev/null
  sleep 1
  if _running; then
    printf '%s\n' "$(_now)" > "$ONF" 2>/dev/null
    _state on "$(cat "$PIDF" 2>/dev/null)" "$(wc -c < "$F" 2>/dev/null)" "$_t" "$F"
    echo "已开始抓日志（pid $(cat "$PIDF" 2>/dev/null)）"
    echo "现在去复现：打开会闪退的 App / 进 WebUI 触发一下"
  else
    rm -f "$PIDF" "$ONF" 2>/dev/null
    _state off "" 0 "" ""
    echo "启动失败：拿不到 logcat（可能没有 root 权限）"
    return 1
  fi
}

_stamp() {   # 用 大小:修改时间 判断"日志有没有变过"
  [ -f "$F" ] || { echo none; return; }
  _sz=$(wc -c < "$F" 2>/dev/null | tr -d ' ')
  _mt=$(stat -c %Y "$F" 2>/dev/null | tr -d ' ')
  echo "${_sz:-0}:${_mt:-0}"
}

_do_stop() {
  _started=$(cat "$D/.started" 2>/dev/null)
  # ★ 2026-10-24：已经停过、日志也没再变过 → 直接把上次那份告诉他，别重复生成
  if ! _running; then
    _last=$(cat "$LASTF" 2>/dev/null)
    if [ -n "$_last" ] && [ -s "$_last" ] && [ -f "$D/.laststamp" ]; then
      if [ "$(cat "$D/.laststamp" 2>/dev/null)" = "$(_stamp)" ]; then
        echo "已经停过了，没有新内容。"
        echo "上次导出的是：$_last"
        echo "（要重新抓：先点「开始抓日志」，或执行「抓日志-开始.sh」）"
        return 0
      fi
    fi
  fi
  if _running; then
    kill "$_p" 2>/dev/null
    sleep 1
    kill -9 "$_p" 2>/dev/null
  fi
  rm -f "$PIDF" "$ONF" 2>/dev/null
  _state off "" 0 "" ""

  if [ ! -s "$F" ]; then
    echo "没有抓到内容（可能刚开就关了）"
    return 1
  fi

  OUT="/sdcard/Download/崩溃日志_$(_now).txt"
  _lines=$(wc -l < "$F" 2>/dev/null | tr -d ' ')
  # ── 崩溃点：每个 FATAL/ANR 前后各截一段（以前只给尾部 1500 行，崩溃一多就漏上下文）
  grep -nE 'FATAL EXCEPTION|ANR in |DeadSystemException|beginning of crash|SIGSEGV|SIGABRT' "$F" 2>/dev/null \
    | cut -d: -f1 | head -20 > "$D/.n.$$" 2>/dev/null
  {
    echo "==========================================================="
    echo "  抓取日志  $(_now)"
    echo "==========================================================="
    echo "设备    : $(getprop ro.product.brand 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
    echo "系统    : Android $(getprop ro.build.version.release 2>/dev/null)   构建 $(getprop ro.build.display.id 2>/dev/null)"
    echo "模块    : $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')"
    echo "字体    : $(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")"
    echo "槽位    : $(grep -c . "$MODDIR/slots.map" 2>/dev/null) 个"
    echo "挂载方式 : $(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")"
    echo "抓取开始 : $_started    总行数: ${_lines:-?}"
    echo "崩溃条数 : $(grep -cE 'FATAL EXCEPTION|ANR in ' "$F" 2>/dev/null)"
    echo
    echo "########## 崩溃点上下文（每个崩溃前后各 120 / 260 行） ##########"
    if [ -s "$D/.n.$$" ]; then
      while read -r _n; do
        [ -n "$_n" ] || continue
        _s=$(( _n - 120 )); [ "$_s" -lt 1 ] && _s=1
        _e=$(( _n + 260 ))
        echo
        echo "---------- 崩溃点 第 $_n 行（显示 $_s-$_e） ----------"
        sed -n "${_s},${_e}p" "$F" 2>/dev/null
      done < "$D/.n.$$"
    else
      echo "（没有匹配到 FATAL/ANR 关键字 —— 可能不是崩溃，或者只是 App 被杀）"
    fi
    echo
    echo "---------- 最近 4000 行（完整上下文） ----------"
    tail -4000 "$F" 2>/dev/null

    # ---------------------------------------------------------------------
    # ★ 2026-10-24（作者要求：要能真的定位问题）：只靠 logcat 经常定不了性，
    #   这里再抓三处系统证据 —— 都是 root 可读的纯文本，直接并进同一份文件里，
    #   用户还是只要发一个 txt 就行。
    # ---------------------------------------------------------------------
    echo
    echo "########## 系统侧证据（dropbox / tombstone / ANR） ##########"

    _db=$(ls -t /data/system/dropbox/*data_app_crash* /data/system/dropbox/*system_server_crash* \
                 /data/system/dropbox/*system_server_watchdog* /data/system/dropbox/*data_app_anr* 2>/dev/null | head -5)
    if [ -n "$_db" ]; then
      for _f in $_db; do
        echo
        echo "---------- dropbox: ${_f##*/} ----------"
        head -200 "$_f" 2>/dev/null
      done
    else
      echo
      echo "（没有可读的 dropbox 崩溃记录 —— 可能是没崩过，或路径不同）"
    fi

    _tb=$(ls -t /data/tombstones/tombstone_* 2>/dev/null | head -2)
    if [ -n "$_tb" ]; then
      for _f in $_tb; do
        echo
        echo "---------- tombstone: ${_f##*/}（原生崩溃） ----------"
        head -200 "$_f" 2>/dev/null
      done
    fi

    _ar=$(ls -t /data/anr/* 2>/dev/null | head -1)
    if [ -n "$_ar" ]; then
      echo
      echo "---------- ANR: ${_ar##*/}（前 120 行） ----------"
      head -120 "$_ar" 2>/dev/null
    fi

    echo
    echo "########## 附加：本次挂载了什么（字体层面） ##########"
    grep -c . "$MODDIR/slots.map" 2>/dev/null | sed 's/^/槽位总数: /'
    head -40 "$MODDIR/slots.map" 2>/dev/null
  } > "$OUT" 2>&1
  rm -f "$D/.n.$$" 2>/dev/null

  # 封顶 6MB：太大就只保留"崩溃点 + 尾部 1500 行"
  _sz=$(wc -c < "$OUT" 2>/dev/null | tr -d ' ')
  if [ "${_sz:-0}" -gt 6291456 ] 2>/dev/null; then
    _tmp="$OUT.small"
    {
      head -40 "$OUT" 2>/dev/null
      echo "（原文 $(( _sz / 1024 )) KB，超出 6MB 上限，已裁剪为：崩溃点 + 尾部 1500 行）"
      if [ -s "$D/.n2.$$" ]; then :; fi
      grep -nE 'FATAL EXCEPTION|ANR in ' "$F" 2>/dev/null | cut -d: -f1 | head -10 > "$D/.n2.$$" 2>/dev/null
      if [ -s "$D/.n2.$$" ]; then
        while read -r _n; do
          _s=$(( _n - 100 )); [ "$_s" -lt 1 ] && _s=1
          sed -n "${_s},$(( _n + 200 ))p" "$F" 2>/dev/null
        done < "$D/.n2.$$"
      fi
      rm -f "$D/.n2.$$" 2>/dev/null
      echo "---------- 尾部 1500 行 ----------"
      tail -1500 "$F" 2>/dev/null
    } > "$_tmp" 2>&1
    mv -f "$_tmp" "$OUT" 2>/dev/null
    _sz=$(wc -c < "$OUT" 2>/dev/null | tr -d ' ')
  fi

  printf '%s\n' "$OUT" > "$LASTF" 2>/dev/null
  _stamp > "$D/.laststamp.tmp" 2>/dev/null && mv -f "$D/.laststamp.tmp" "$D/.laststamp" 2>/dev/null
  echo "已生成：$OUT"
  echo "大小：${_sz:-0} 字节"
  echo "把这个文件发出去就行（也可以在界面里点「上传给作者」）。"
}

_do_upload() {
  _note="${2:-}"                      # 用户在弹窗里写的问题描述（百分号编码后的）
  _f=$(cat "$LASTF" 2>/dev/null)
  [ -n "$_f" ] || _f=$(ls -t /sdcard/Download/崩溃日志_*.txt 2>/dev/null | head -n1)
  [ -s "$_f" ] || { echo "ERROR:没有可上传的日志（先在界面里停止一次）"; return 1; }
  _k=$(sed -n 's/^UPLOAD_KEY=//p' "$MODDIR/report.conf" 2>/dev/null | head -n1)
  if [ -z "$_k" ]; then
    # 口令写在 webroot 里（界面同款来源），拿不到就报错
    _k=$(grep -o "WORKER_KEY[^\"']*[\"'][^\"']*" "$MODDIR/webroot/index.html" 2>/dev/null | head -n1 | sed "s/.*[\"']//")
  fi
  _u="https://cfs-report.2188366745q.workers.dev/report"
  command -v curl >/dev/null 2>&1 || { echo "ERROR:没有 curl"; return 1; }
  _out=$(curl -sS --connect-timeout 8 -m 60 -X POST \
      -H "x-cfs-key: $_k" \
      -H "x-cfs-note: ${_note:-$(basename "$_f")}" \
      -H "x-cfs-desc: ${_note:-}" \
      -H 'Content-Type: text/plain; charset=utf-8' \
      --data-binary @"$_f" "$_u" 2>&1)
  echo "上传返回：$_out"
}

case "${1:-status}" in
  start)  _do_start start ;;
  resume) _do_start resume ;;
  stop)   _do_stop ;;
  upload) _do_upload "$@" ;;
  lastpath)
    _f=$(cat "$LASTF" 2>/dev/null)
    [ -n "$_f" ] || _f=$(ls -t /sdcard/Download/崩溃日志_*.txt 2>/dev/null | head -n1)
    [ -n "$_f" ] && echo "$_f" || echo ""
    ;;
  status)
    if _running; then
      echo "state=on pid=$_p bytes=$(wc -c < "$F" 2>/dev/null)"
    else
      echo "state=off"
    fi
    ;;
  *) echo "用法: sh logcatch.sh start|stop|status|resume|upload" ;;
esac
