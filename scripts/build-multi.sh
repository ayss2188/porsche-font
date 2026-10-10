#!/system/bin/sh
# build-multi.sh —— 一次打出保时捷字体的 4 个变体包（三合一 + 3 个单色）
#
# 用法（在仓库根目录跑）：
#     sh scripts/build-multi.sh <源码目录> <输出目录>
#     例：sh scripts/build-multi.sh module dist
#
# 做的事（对 variants.conf 里每一行）：
#   1. 复制一份源码到临时目录
#   2. 改 module.prop：id / name / version / versionCode / description / updateJson
#   3. 只保留该变体需要的字体（builtin/ 里多余的删掉）
#      —— 单色包只剩 1 个字体，安装时 builtin_menu 会自动选中、不弹菜单
#   4. 打包成 porsche-font-<变体>-<版本>.zip，并打印 sha256
# 最后把 4 个包的 sha256 汇总写到 $OUT/sha256.txt（CI 用它写 update.json）
#
# 依赖：zip 命令（CI 里有；本地 Windows 上可用 Git Bash 或 WSL 跑）

set -e
SRC="${1:-module}"
OUT="${2:-dist}"
CONF="${3:-variants.conf}"

[ -d "$SRC" ] || { echo "ERROR: 找不到源码目录 $SRC"; exit 1; }
[ -f "$CONF" ] || { echo "ERROR: 找不到 $CONF"; exit 1; }
mkdir -p "$OUT"
OUT_ABS=$(cd "$OUT" && pwd)      # 用绝对路径，避免子 shell 里 cd 之后相对路径失效

VER=$(sed -n 's/^version=//p' "$SRC/module.prop" | head -n1 | tr -d '\r')
CODE=$(sed -n 's/^versionCode=//p' "$SRC/module.prop" | head -n1 | tr -d '\r')
VER=${VER:-v0.0}
CODE=${CODE:-0}
: > "$OUT/sha256.txt"

echo "版本：$VER ($CODE)"
echo

grep -v '^#' "$CONF" | grep -v '^[[:space:]]*$' | while IFS='|' read -r key id upfile fonts disp zipkey; do
  key=$(printf '%s' "$key" | tr -d ' \r')
  id=$(printf '%s' "$id" | tr -d ' \r')
  upfile=$(printf '%s' "$upfile" | tr -d ' \r')
  zipkey=$(printf '%s' "${zipkey:-}" | tr -d ' \r')
  [ -n "$key" ] || continue
  # zip 文件名用"给用户看的型号名"（718/911/gt3），别用 none/colon/flair 这种内部代号；
  # 留空则回落到变体键
  [ -n "$zipkey" ] || zipkey="$key"

  work="$OUT/.work-$key"
  rm -rf "$work"; mkdir -p "$work"
  cp -r "$SRC"/. "$work"/

  # 1) 只留该变体的字体
  for f in "$work/builtin"/*.ttf "$work/builtin"/*.TTF "$work/builtin"/*.otf "$work/builtin"/*.OTF; do
    [ -f "$f" ] || continue
    base=${f##*/}; base=${base%.*}
    keep=0
    for want in $fonts; do [ "$base" = "$want" ] && keep=1; done
    [ "$keep" = 1 ] || rm -f "$f"
  done

  # 2) 改 module.prop
  prop="$work/module.prop"
  {
    awk -v id="$id" -v ver="$VER" -v code="$CODE" -v disp="$disp" -v up="$upfile" '
      /^id=/          { print "id=" id; next }
      /^name=/        { print "name=" disp; next }
      /^version=/     { print "version=" ver; next }
      /^versionCode=/ { print "versionCode=" code; next }
      /^updateJson=/  { print "updateJson=https://raw.githubusercontent.com/ayss2188/porsche-font/main/" up; next }
      { print }
    ' "$prop"
    # 没有 updateJson 就补一行（老包都没有这一行）
    grep -q '^updateJson=' "$prop" || \
      echo "updateJson=https://raw.githubusercontent.com/ayss2188/porsche-font/main/$upfile"
  } > "$prop.new" && mv "$prop.new" "$prop"

  # 3) 把界面里的模块 id 改成这个变体的 id
  #    为什么必须改：4 个包共用同一份 index.html，而界面里所有 shell 调用都要拼模块目录路径。
  #    以前是写死主项目的 custom_font_switcher（换皮时漏改），结果整个界面一条命令都调不到；
  #    现在改成运行时探测，这里再把"先试哪个 id"按变体写准，单色包也不会猜错。
  idx="$work/webroot/index.html"
  if [ -f "$idx" ]; then
    if grep -q 'const MODULE_HINT' "$idx"; then
      sed "s/const MODULE_HINT = \"[^\"]*\"/const MODULE_HINT = \"$id\"/" "$idx" > "$idx.new" && mv "$idx.new" "$idx"
    else
      echo "  ⚠ 界面里没有 const MODULE_HINT，跳过 id 注入（升级模板后请同步 build-multi.sh）"
    fi
  fi

  # 4) 打包（模块内容在 zip 根目录）
  zipname="porsche-font-$zipkey-$VER.zip"
  rm -f "$OUT/$zipname"
  ( cd "$work" && zip -r -9 -X "$OUT_ABS/$zipname" . >/dev/null )

  sum=$(sha256sum "$OUT_ABS/$zipname" | cut -d' ' -f1)
  size=$(wc -c < "$OUT_ABS/$zipname" | tr -d ' ')
  echo "$key|$id|$zipname|$upfile|$sum" >> "$OUT/sha256.txt"
  echo "  ✓ $zipname  ($size 字节)  id=$id  update=$upfile"
  rm -rf "$work"
done

echo
echo "完成。sha256 汇总在 $OUT/sha256.txt："
cat "$OUT/sha256.txt"
echo
echo "下一步（CI 的 release.yml）：拿这个汇总去生成 4 个 update.json："
echo '  {"version":"'"$VER"'","versionCode":'"$CODE"',"zipUrl":".../releases/download/'"$VER"'/<zip>","changelog":".../main/CHANGELOG.md","sha256":"<sum>"}'
