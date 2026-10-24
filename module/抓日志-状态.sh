#!/system/bin/sh
# ===========================================================================
# 用 MT 管理器点这个文件 → 执行 → 选「以 root 身份执行」
# 作用：看现在是不是在抓日志、抓了多久、文件多大
# ===========================================================================
D=${0%/*}
cd "$D" 2>/dev/null
if [ -f "$D/logcatch.sh" ]; then
  sh "$D/logcatch.sh" status
  F="/data/adb/custom_font_lib/logs/catch.log"
  if [ -s "$F" ]; then
    echo "文件：$F  $(wc -c < "$F" 2>/dev/null) 字节"
  fi
  echo
  echo "导出过的日志："
  ls -lt /sdcard/Download/崩溃日志_*.txt 2>/dev/null | head -5
else
  echo "找不到 logcatch.sh（模块目录：$D）"
fi
