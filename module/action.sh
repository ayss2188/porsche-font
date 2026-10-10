#!/system/bin/sh
# 模块卡片上的「操作」按钮：
#   Magisk：尝试用 KsuWebUI 打开本模块的 WebUI
#   所有管理器：显示当前状态，并检查 GitHub 上有没有新版本

MODDIR=${0%/*}
. "$MODDIR/common.sh"
MODID=$(sed -n 's/^id=//p' "$MODDIR/module.prop" | head -n1 | tr -d '\r')
MODNAME=$(sed -n 's/^name=//p' "$MODDIR/module.prop" | head -n1 | tr -d '\r')
KSUWEBUI=io.github.a13e300.ksuwebui

if [ "$(root_manager)" = magisk ]; then
  if pm path "$KSUWEBUI" >/dev/null 2>&1; then
    if am start -n "$KSUWEBUI/.WebUIActivity" -e id "$MODID" -e name "$MODNAME" >/dev/null 2>&1; then
      echo "已用 KsuWebUI 打开 WebUI"
      exit 0
    fi
    echo "KsuWebUI 启动失败，请直接打开 KsuWebUI 选择本模块"
  else
    echo "未安装 KsuWebUI（包名 $KSUWEBUI）"
    echo "Magisk 没有 WebUI 入口，请先安装 KsuWebUI 或 WebUI X，"
    echo "再点一次「操作」即可打开字体管理界面。"
  fi
  echo " "
fi

eval "$(sh "$MODDIR/fontctl.sh" status 2>/dev/null | sed -n 's/^\([A-Z]*\)=\(.*\)$/\1="\2"/p')"
echo "版本：$V"
echo "系统：$(rom_name "$R")"
echo "已替换槽位：${N:-0}"
case "$MO" in
  "") echo "本次开机自带挂载：未执行" ;;
  *)  echo "本次开机自带挂载：成功 $(echo "$MO" | cut -d, -f1) / 失败 $(echo "$MO" | cut -d, -f2)" ;;
esac
echo " "
# 诊断报告：手动触发，结论打印在这里，完整报告写入 Download
if [ -f "$MODDIR/diag.sh" ]; then
  echo "正在生成诊断报告（一般 1~2 分钟，字体多或机型慢时更久；生成时会主动降优先级，"
  echo "所以比全速跑慢一些，但不影响你用手机）..."
  echo "报告会保存到 Download/完整体检报告.txt（快速体检时是 快速体检报告.txt）"
  echo " "
  sh "$MODDIR/diag.sh" install 2>&1
  echo " "
fi
echo "正在检查更新..."
eval "$(sh "$MODDIR/update.sh" check 2>/dev/null)"
if [ -z "$NEW_CODE" ]; then
  echo "检查失败：$ERR"
elif [ "$HAS" = 1 ]; then
  echo "发现新版本：$NEW_VER（当前 $CUR_VER）"
  echo "请在 WebUI 里点「下载并安装」，或在管理器里更新。"
else
  echo "已是最新版本（$CUR_VER）"
fi
