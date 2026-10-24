#!/system/bin/sh
# ===========================================================================
# 用 MT 管理器点这个文件 → 执行 → 选「以 root 身份执行」
# 作用：打开本模块的 WebUI（Magisk 用户没有「操作」按钮时用这个）
#
#   KernelSU / APatch：一般管理器卡片里就有「打开」，这个文件是备用
#   Magisk：需要先装 KsuWebUI 或 WebUI X，本脚本会尝试直接拉起
# ===========================================================================
D=${0%/*}
cd "$D" 2>/dev/null
. "$D/common.sh" 2>/dev/null

MODID=$(sed -n 's/^id=//p' "$D/module.prop" 2>/dev/null | head -n1 | tr -d '\r')
MODNAME=$(sed -n 's/^name=//p' "$D/module.prop" 2>/dev/null | head -n1 | tr -d '\r')

echo "模块：${MODNAME:-?}（id=${MODID:-?}）"
echo "目录：$D"
echo

# ① KsuWebUI（KernelSU 系常用）
for PKG in io.github.a13e300.ksuwebui com.dergoogler.mmrl.webui; do
  if pm path "$PKG" >/dev/null 2>&1; then
    if am start -n "$PKG/.WebUIActivity" -e id "$MODID" -e name "$MODNAME" >/dev/null 2>&1; then
      echo "已用 $PKG 打开 WebUI"
      exit 0
    fi
  fi
done

# ② 都没成功 → 给明确指引
echo "没能自动打开 WebUI。可以这样进："
echo "  · KernelSU / APatch：管理器里点本模块卡片就能打开"
echo "  · Magisk：先装 KsuWebUI（或 WebUI X），再从里面选本模块"
echo
echo "只想抓日志的话，不用进 WebUI："
echo "  · 执行「抓日志-开始.sh」"
echo "  · 复现问题后执行「抓日志-停止导出.sh」"
echo "  · 结果在 Download/崩溃日志_时间.txt"
