#!/system/bin/sh
# 模块卡片上的「操作」按钮
#
#   KernelSU / APatch：只做一件事 —— 抓崩溃日志（开始 / 停止并导出）
#   Magisk：只做一件事 —— 打开 WebUI（Magisk 没有自带的 WebUI 入口）
#
# ★ 2026-10-24（作者要求"纯粹一点"）：
#   以前这里还会顺手生成诊断报告、检查更新 —— 点一下要等 1~2 分钟，
#   而且和"抓日志"这件事混在一起。现在两件事彻底分开：
#     · 要完整诊断报告 → 进 WebUI 里点
#     · 只想抓崩溃日志 → 点这个按钮（KernelSU）
#     · Magisk 用户 → 点这个按钮打开 WebUI

MODDIR=${0%/*}
. "$MODDIR/common.sh" 2>/dev/null
LIB="${LIB:-/data/adb/custom_font_lib}"
MODID=$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
MODNAME=$(sed -n 's/^name=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -d '\r')

# ===========================================================================
# Magisk：只负责打开 WebUI
# ===========================================================================
if [ "$(root_manager 2>/dev/null)" = magisk ]; then
  for PKG in io.github.a13e300.ksuwebui com.dergoogler.mmrl.webui; do
    if pm path "$PKG" >/dev/null 2>&1; then
      if am start -n "$PKG/.WebUIActivity" -e id "$MODID" -e name "$MODNAME" >/dev/null 2>&1; then
        echo "已用 $PKG 打开 WebUI"
        exit 0
      fi
    fi
  done
  echo "没找到可用的 WebUI 容器（KsuWebUI / WebUI X）。"
  echo "装一个之后，再点一次「操作」就能打开本模块界面。"
  exit 0
fi

# ===========================================================================
# KernelSU / APatch：只负责抓崩溃日志（开始 ⇄ 停止并导出）
# ===========================================================================
if [ ! -f "$MODDIR/logcatch.sh" ]; then
  echo "这个版本没有抓日志脚本（logcatch.sh），请更新模块。"
  exit 1
fi

echo "—— 抓崩溃日志 ——"
if [ -f "$LIB/logs/.on" ]; then
  echo "状态：正在抓"
  _sz=$(wc -c < "$LIB/logs/catch.log" 2>/dev/null | tr -d ' ')
  [ -n "$_sz" ] && echo "已抓：$(( _sz / 1024 )) KB"
  echo " "
  echo "现在停止并导出…"
  sh "$MODDIR/logcatch.sh" stop
else
  echo "状态：未开始"
  echo " "
  sh "$MODDIR/logcatch.sh" start
  echo " "
  echo "（复现完问题后再点一次「操作」，就会停止并导出）"
fi
