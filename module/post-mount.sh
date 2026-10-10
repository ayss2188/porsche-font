#!/system/bin/sh
# post-mount（KernelSU / APatch）：在元模块等挂载完成之后再挂本模块的字体，
# 避免被其他模块的目录级挂载盖住。Magisk 没有这个阶段，由 post-fs-data.sh 负责。

MODDIR=${0%/*}
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"
[ -f "$MODDIR/mount.sh" ] && . "$MODDIR/mount.sh"

# 只允许 KernelSU / APatch 走这个阶段：
# Magisk 没有 post-mount，如果这里也挂一次，而 post-fs-data 又因为管理器识别不准挂过，
# 就会叠出两层挂载（再也数不清、也卸不干净）
case "$(root_manager)" in
  ksu|apatch) ;;
  *) exit 0 ;;
esac

# 开机保护已在 post-fs-data 把选择恢复为 none 时，这里自然不会挂载
P=$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/pending_font")
case "$P" in ""|none) exit 0 ;; esac
[ "$(tr -d '[:space:]' 2>/dev/null < "$MODDIR/payload.mode")" = manager ] && exit 0
shutting_down && exit 0

payload_mount "$MODDIR" post-mount
