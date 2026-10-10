#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
optimize_font.py - 自定义字体切换模块配套的字体精简工具（电脑或手机 Termux 上运行均可）

作用（针对"字体模块刷完很卡 / 体积太大"）：
  1. 可变字体(VF) -> 静态实例：去掉 gvar/fvar/STAT 等变量数据，渲染更直接
  2. 裁剪字符集：默认保留 拉丁/标点/假名 + GB2312 简体 + Big5 常用繁体（约 1.2 万字），
     冷门汉字在手机上会回退到系统字体
  3. 去掉无用表：DSIG / hdmx / LTSH / VDMX / 字形名(post 3)
  4. 修正名称表（避免乱码的字体名）和垂直度量不一致
  5. 容忍个别字形的变量数据损坏（会跳过该字形的变量数据，不让整个流程崩）

依赖：pip install fonttools（手机 Termux 先 pkg install python，再 pip install fonttools）
用法示例：
  python optimize_font.py 原字体.ttf -o 精简后.ttf --family "My Sans"
  python optimize_font.py 原字体.ttf -o out.ttf --wght 330            # 指定可变字体的字重
  python optimize_font.py 原字体.ttf -o out.ttf --wght 330 --wght 630 # 一次导出多个字重
  python optimize_font.py 原字体.ttf -o out.ttf --no-subset            # 只转静态，不裁剪字符
  python optimize_font.py 原字体.ttf -o out.ttf --big5-full --keep-hangul-less
  python optimize_font.py 合集.ttc -o out.ttf --face 0               # 从 TTC 合集里取出第 1 个字体
"""
import argparse
import os
import sys
import time

try:
    from fontTools.ttLib import TTFont
    from fontTools import subset
    from fontTools.varLib.instancer import instantiateVariableFont
except ImportError:
    sys.exit("缺少依赖，请先运行：pip install fonttools")


def mb(path):
    return os.path.getsize(path) / 1048576


def build_charset(args):
    """要保留的 Unicode 码点集合。"""
    cps = set()
    # 拉丁 / 标点 / 货币 / 数字与符号常用区
    for lo, hi in [(0x20, 0x7E), (0xA0, 0x24F), (0x2C6, 0x2DD), (0x2000, 0x206F), (0x20A0, 0x20CF),
                   (0x2100, 0x218F), (0x2190, 0x21FF), (0x2460, 0x24FF), (0x25A0, 0x25FF),
                   (0x3000, 0x303F), (0xFE30, 0xFE4F), (0xFF00, 0xFFEF)]:
        cps.update(range(lo, hi + 1))
    if not args.no_kana:
        cps.update(range(0x3040, 0x30FF + 1))
    if not args.no_cyrillic_greek:
        cps.update(range(0x370, 0x3FF + 1))
        cps.update(range(0x400, 0x4FF + 1))
    # GB2312（简体 + 全角符号）
    for hi in range(0xA1, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                cps.add(ord(bytes([hi, lo]).decode("gb2312")))
            except (UnicodeDecodeError, ValueError):
                pass
    # Big5 常用字（一级 5401 字；--big5-full 加二级）
    last_hi = 0xF9 if args.big5_full else 0xC6
    for hi in range(0xA4, last_hi + 1):
        for lo in list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF)):
            try:
                cps.add(ord(bytes([hi, lo]).decode("big5")))
            except (UnicodeDecodeError, ValueError):
                pass
    return cps


def sanitize_gvar(font):
    """个别字形的 gvar 数据损坏时，清空该字形的变量数据，保证后续处理不崩。"""
    if "gvar" not in font:
        return 0
    gvar = font["gvar"]
    bad = 0
    fixed = {}
    for name in font.getGlyphOrder():
        try:
            fixed[name] = gvar.variations[name]
        except Exception:
            fixed[name] = []
            bad += 1
    if bad:
        gvar.variations = fixed
    return bad


def fix_names(font, family, style="Regular"):
    """用干净的 ASCII 名称重建关键 name 记录（原字体名称乱码时很有用）。"""
    name = font["name"]
    ps = family.replace(" ", "") + "-" + style.replace(" ", "")
    full = family if style == "Regular" else family + " " + style
    for nid in (1, 2, 3, 4, 6, 16, 17, 21, 22, 25):
        name.removeNames(nameID=nid)
    for pid, eid, lid in ((3, 1, 0x409), (1, 0, 0)):
        name.setName(family, 1, pid, eid, lid)
        name.setName(style, 2, pid, eid, lid)
        name.setName(ps + ";optimized", 3, pid, eid, lid)
        name.setName(full, 4, pid, eid, lid)
        name.setName(ps, 6, pid, eid, lid)


def fix_metrics(font):
    """让 hhea / OS/2 typo / win 三套垂直度量一致，避免不同系统行高不同。"""
    hhea, os2 = font["hhea"], font["OS/2"]
    os2.sTypoAscender = hhea.ascent
    os2.sTypoDescender = hhea.descent
    os2.sTypoLineGap = hhea.lineGap
    os2.usWinAscent = max(0, hhea.ascent)
    os2.usWinDescent = max(0, -hhea.descent)
    os2.fsSelection |= (1 << 7)  # USE_TYPO_METRICS


def process(src, dst, args, wght=None):
    t0 = time.time()
    font = TTFont(src, fontNumber=args.face) if args.face is not None else TTFont(src)
    print(f"  读取 {os.path.basename(src)}  {mb(src):.1f} MB  字形 {len(font.getGlyphOrder())}")

    bad = sanitize_gvar(font)
    if bad:
        print(f"  ! 有 {bad} 个字形的变量数据损坏，已跳过其变量数据")

    if "fvar" in font:
        axes = {a.axisTag: (a.minValue, a.defaultValue, a.maxValue) for a in font["fvar"].axes}
        loc = {}
        for tag, (lo, df, hi) in axes.items():
            v = df
            if tag == "wght" and wght is not None:
                v = max(lo, min(hi, wght))
            loc[tag] = v
        print(f"  可变字体 -> 静态实例 {loc}（轴范围 { {k: v[::2] for k, v in axes.items()} }）")
        font = instantiateVariableFont(font, loc, inplace=False, optimize=True)
    else:
        print("  已是静态字体，跳过实例化")

    if not args.no_subset:
        cps = build_charset(args)
        opts = subset.Options()
        opts.layout_features = ["*"]
        opts.glyph_names = False
        opts.notdef_outline = True
        opts.name_IDs = ["*"]
        opts.name_languages = ["*"]
        opts.drop_tables += ["DSIG", "hdmx", "LTSH", "VDMX"]
        opts.hinting = False
        sub = subset.Subsetter(opts)
        sub.populate(unicodes=cps)
        before = len(font.getGlyphOrder())
        sub.subset(font)
        print(f"  裁剪字符集：保留 {len(cps)} 个码点，字形 {before} -> {len(font.getGlyphOrder())}")
    else:
        for t in ("DSIG", "hdmx", "LTSH", "VDMX"):
            if t in font:
                del font[t]

    if "SVG " in font:        # Android 系统字体不渲染 SVG，空壳表只会添乱
        del font["SVG "]
    if "post" in font:
        font["post"].formatType = 3.0   # 去掉字形名

    if args.weight_class:
        font["OS/2"].usWeightClass = args.weight_class
    if not args.no_fix_metrics:
        fix_metrics(font)
    if args.family:
        style = "Regular"
        fix_names(font, args.family, style)

    font.save(dst)
    print(f"  完成 -> {dst}  {mb(dst):.1f} MB  用时 {time.time() - t0:.0f}s")


def main():
    ap = argparse.ArgumentParser(description="字体模块用字体精简工具")
    ap.add_argument("src", help="输入字体（.ttf / .otf，单个字体文件，不是 TTC）")
    ap.add_argument("-o", "--out", required=True, help="输出文件")
    ap.add_argument("--wght", type=float, action="append", help="可变字体的字重值，可重复；不填则用默认字重")
    ap.add_argument("--weight-class", type=int, default=400, help="写入 OS/2 usWeightClass（默认 400）")
    ap.add_argument("--family", help="重建干净的字体名称（原名称乱码时使用）")
    ap.add_argument("--no-subset", action="store_true", help="不裁剪字符集")
    ap.add_argument("--no-kana", action="store_true", help="不保留日文假名")
    ap.add_argument("--no-cyrillic-greek", action="store_true", help="不保留西里尔/希腊字母")
    ap.add_argument("--big5-full", action="store_true", help="保留 Big5 二级繁体字（体积更大）")
    ap.add_argument("--no-fix-metrics", action="store_true", help="不统一垂直度量")
    ap.add_argument("--face", type=int, help="TTC 合集里要取出的字体序号（从 0 开始）")
    ap.add_argument("--keep-hangul-less", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()

    if not os.path.isfile(args.src):
        sys.exit("找不到输入文件")
    with open(args.src, "rb") as f:
        if f.read(4) == b"ttcf" and args.face is None:
            from fontTools.ttLib import TTCollection
            n = len(TTCollection(args.src).fonts)
            sys.exit(f"这是 TTC 合集（含 {n} 个字体），请加 --face 序号（0~{n - 1}）取出其中一个")

    weights = args.wght or [None]
    base, ext = os.path.splitext(args.out)
    for w in weights:
        dst = args.out if len(weights) == 1 else f"{base}-{int(w) if w is not None else 'default'}{ext or '.ttf'}"
        print(f"[{'默认字重' if w is None else 'wght=' + str(w)}]")
        process(args.src, dst, args, w)


if __name__ == "__main__":
    main()
