#!/system/bin/sh
# post-mount（KernelSU / APatch 支持时才会跑）：**二次修补**，不是主挂载点。
#
# 主挂载在 post-fs-data.sh —— 因为 post-mount 不是所有管理器都执行
# （真机上遇到过不执行这个阶段的管理器，结果字体一个槽位都没换上）。
# 这里的作用只有一个：如果元模块的目录级挂载排在 post-fs-data 之后、把我们挂上去的
# 文件盖住了，这一遍会靠 inode 比对发现并补回来 —— payload_mount 是幂等的
# （已经指向我们的文件就跳过），所以这里不会叠出两层挂载。

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
