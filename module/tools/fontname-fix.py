#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fontname-fix.py —— 体检并修复字体的「身份表」（name 表）

【为什么需要它】2026-10-12 实测到一个真事故（保时捷字体项目 · 一加 ColorOS）：

  那个模块的字体 `flair.ttf` 内部 name 表是这样写的：
      postscript 名 (nid=6, pid=3) 原始字节 = 67 2a 5b 9a 4e 49  →  UTF-16BE = "未定义"
      family     名 (nid=1, pid=1) 原始字节 = b1 a3              →  半个汉字的乱码
  而系统（ColorOS/OPlus）的中文字体族是按名字找字体的：
      <family lang="zh-Hans"><font ... postScriptName="OPPO_Sans_4.0_SC">SysSans-Hans-Regular.ttf
  结果：字形明明齐全（cmap 覆盖 36,816 字、中文 3000/3000），
        但系统按名字找不到这个字体 → **整个中文族渲染成方框（全是方块）**。

  同一时期我们自己的字体（MiSansVF）身份是正常的：
      postscript 名 = "MiSansVF"（纯 ASCII）→ 与系统配置一致 → 没有这个问题。

【这个工具做什么】
  1. 体检（无参数或 --check）：把 name 表里所有记录打印出来，并给出「是否可疑」的判定
  2. 修复（--fix）：重写 name 表 —— 去掉可疑记录（非 ASCII 的 postscript 名、
     用 UTF-16 冒充 ASCII 的记录），并补上规范的 ASCII 记录
  3. 只改 name 表：表目录里只动 `name` 一条的 offset/length，其余表（字形/cmap/hmtx…）原样复制

【用法】
  python fontname-fix.py 字体.ttf                    # 只体检
  python fontname-fix.py 字体.ttf -o 修好的.ttf       # 修复并另存（不改原文件）
  python fontname-fix.py 字体.ttf -o 修好的.ttf --family "MyFont" --psname "MyFont-Regular"

【判定规则（保守：只处理"明确可疑"的）】
  · postscript 名（nid=6）不是纯 ASCII 可见字符（0x20-0x7E）→ 可疑（系统拿它当标识符）
  · pid=1（Mac/ASCII 平台）却用了非 ASCII 字节 → 可疑（半个汉字的乱码就是这么来的）
  · pid=3 的记录里含非 ASCII → 若它同时是 postscript 名，也可疑
  · family/subfamily/full（nid=1/2/4）允许非 ASCII（中文名很正常），**不动它们**
"""
import argparse
import os
import struct
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

NID = {0: "copyright", 1: "family族名", 2: "subfamily子族", 3: "唯一标识",
       4: "full全名", 5: "版本", 6: "postscript名", 7: "商标", 8: "厂商",
       9: "设计者", 10: "描述", 11: "厂商URL", 12: "设计者URL", 13: "许可",
       14: "许可URL", 16: "typo族名", 17: "typo子族", 18: "兼容全名",
       19: "样例文字", 20: "postscript CID", 21: "WWS族名", 22: "WWS子族",
       23: "轻量调色板", 24: "调色板", 25: "可变字体的postscript前缀"}


def sfnt_offset(fh):
    """返回 (第一个字体的表目录起始偏移, face数)"""
    fh.seek(0)
    head = fh.read(12)
    if head[:4] == b"ttcf":
        n = struct.unpack(">I", head[8:12])[0]
        offs = struct.unpack(">%dI" % n, fh.read(4 * n))
        return offs[0], n
    return 0, 1


def read_tables(fh):
    base, faces = sfnt_offset(fh)
    fh.seek(base)
    head = fh.read(12)
    num = struct.unpack(">H", head[4:6])[0]
    fh.seek(base + 12)
    tables = {}
    order = []
    for _ in range(num):
        tag, csum, off, ln = struct.unpack(">4sIII", fh.read(16))
        t = tag.decode("latin1")
        tables[t] = {"off": off, "len": ln, "sum": csum, "entry": base + 12 + 16 * len(order)}
        order.append(t)
    return base, faces, tables, order


def read_name_records(fh, tables):
    """返回 (原始字节, [记录dict])"""
    off, ln = tables["name"]["off"], tables["name"]["len"]
    fh.seek(off)
    raw = fh.read(ln)
    fmt, count, strOff = struct.unpack(">HHH", raw[:6])
    recs = []
    for i in range(count):
        pid, eid, lid, nid, l, o = struct.unpack(">HHHHHH", raw[6 + 12 * i:18 + 12 * i])
        recs.append(dict(pid=pid, eid=eid, lid=lid, nid=nid, len=l, off=o, idx=i))
    return raw, fmt, count, strOff, recs


def decode(rec, raw, strOff):
    data = raw[strOff + rec["off"]: strOff + rec["off"] + rec["len"]]
    if rec["pid"] in (0, 3):          # Unicode / Windows
        try:
            return data.decode("utf-16-be")
        except Exception:
            return data.decode("utf-8", "replace")
    return data.decode("latin1")       # Mac / ASCII


def is_ascii(s):
    return all(0x20 <= ord(c) <= 0x7E for c in s)


def looks_utf16_as_ascii(rec, raw, strOff):
    """pid=1（ASCII 平台）却含非 ASCII 字节 → 很可能是"把 UTF-16 按 ASCII 存了"（半个汉字）"""
    data = raw[strOff + rec["off"]: strOff + rec["off"] + rec["len"]]
    return rec["pid"] == 1 and any(b < 0x20 or b > 0x7E for b in data)


def check(path):
    with open(path, "rb") as fh:
        base, faces, tables, order = read_tables(fh)
        if "name" not in tables:
            print("  ❌ 这个字体没有 name 表 —— 系统无法识别它的身份")
            return None
        raw, fmt, count, strOff, recs = read_name_records(fh, tables)

    print("  文件: %s (%d 字节)   face 数: %d" % (os.path.basename(path), os.path.getsize(path), faces))
    print("  表: %s" % " ".join(sorted(tables.keys())))
    print("  name 表: 格式=%d  记录数=%d" % (fmt, count))
    print()
    print("  %-4s %-14s %-5s %-5s %-5s  %s" % ("nid", "含义", "pid", "eid", "lid", "值 / 判定"))
    print("  " + "-" * 76)
    suspects = []
    for r in recs:
        v = decode(r, raw, strOff)
        flag = ""
        if r["nid"] == 6 and not is_ascii(v):
            flag = "  ← ❌ 可疑：postscript 名不是 ASCII（系统拿它当标识符）"
            suspects.append(r)
        elif looks_utf16_as_ascii(r, raw, strOff):
            flag = "  ← ⚠ 可疑：ASCII 平台却存了非 ASCII 字节（像半个汉字）"
            suspects.append(r)
        show = v if len(v) <= 46 else v[:46] + "…"
        print("  %-4d %-14s %-5d %-5d %-5d  %r%s" % (r["nid"], NID.get(r["nid"], "?"),
                                                     r["pid"], r["eid"], r["lid"], show, flag))
    print()
    if suspects:
        print("  === 判定：发现 %d 条可疑记录 —— 建议修复 ===" % len(suspects))
        for r in suspects:
            print("     nid=%d(%s) pid=%d lid=%d 值=%r" % (r["nid"], NID.get(r["nid"], "?"),
                                                          r["pid"], r["lid"], decode(r, raw, strOff)))
    else:
        print("  === 判定：身份表正常（没有可疑记录）===")
    return dict(raw=raw, fmt=fmt, count=count, strOff=strOff, recs=recs,
                tables=tables, base=base, faces=faces, suspects=suspects)


def build_name_table(fh, info, family, subfamily, psname):
    """重写 name 表：保留 family/subfamily/full 这类非 ASCII 也正常的记录，
       丢掉可疑记录，补上规范的 ASCII 记录。"""
    raw, strOff = info["raw"], info["strOff"]
    keep = []
    for r in info["recs"]:
        if r in info["suspects"]:
            continue
        if r["nid"] == 6 and r["pid"] == 3:       # 旧的 postscript 名一律丢弃，重建
            continue
        key = (r["pid"], r["eid"], r["lid"], r["nid"])
        keep.append((key, raw[strOff + r["off"]: strOff + r["off"] + r["len"]],
                     r["pid"] in (0, 3)))

    # 需要重建的记录：(pid,eid,lid,nid) -> 文本
    want = [
        ((3, 1, 0x409, 1), family), ((1, 0, 0, 1), family),
        ((3, 1, 0x409, 2), subfamily), ((1, 0, 0, 2), subfamily),
        ((3, 1, 0x409, 4), "%s %s" % (family, subfamily)), ((1, 0, 0, 4), "%s %s" % (family, subfamily)),
        ((3, 1, 0x409, 6), psname), ((1, 0, 0, 6), psname),
    ]
    existing = set(k for k, _, _ in keep)
    for key, text in want:
        if key in existing:
            continue
        if key[0] in (0, 3):
            keep.append((key, text.encode("utf-16-be"), True))
        else:
            keep.append((key, text.encode("latin1", "replace"), False))

    # 组装字符串池（每条独立存放，简单但完全合规）+ 记录表
    pool = bytearray()
    recs = bytearray()
    out = []
    for key, data, wide in keep:
        pid, eid, lid, nid = key
        off = len(pool)
        pool += data
        out.append((pid, eid, lid, nid, len(data), off))
    out.sort(key=lambda x: (x[0], x[1], x[2], x[3]))
    for pid, eid, lid, nid, ln, off in out:
        recs += struct.pack(">HHHHHH", pid, eid, lid, nid, ln, off)
    header = struct.pack(">HHH", 0, len(out), 6 + 12 * len(out))
    return header + bytes(recs) + bytes(pool)


def fix(path, out, family, subfamily, psname):
    with open(path, "rb") as fh:
        info = check(path)
        if info is None:
            return 1
        fam, sub = family, subfamily
        if not fam:
            for r in info["recs"]:
                if r["nid"] in (1, 16) and r["pid"] == 3 and is_ascii(decode(r, info["raw"], info["strOff"])):
                    fam = decode(r, info["raw"], info["strOff"]); break
        if not fam:
            for r in info["recs"]:
                if r["nid"] == 1:
                    v = decode(r, info["raw"], info["strOff"])
                    fam = "".join(ch for ch in v if 0x20 <= ord(ch) <= 0x7E) or "UserFont"
                    break
        fam = fam or "UserFont"
        sub = sub or "Regular"
        ps = psname or ("%s-%s" % (fam.replace(" ", ""), sub))
        ps = "".join(ch for ch in ps if 0x20 <= ord(ch) <= 0x7E)[:63] or "UserFont-Regular"

        new_name = build_name_table(fh, info, fam, sub, ps)

        print()
        print("  === 修复 ===  族名=%r  子族=%r  postscript名=%r" % (fam, sub, ps))

        # 读整个文件，替换 name 表：追加新表到末尾，改表目录里 name 那条
        fh.seek(0)
        blob = bytearray(fh.read())
        # 4 字节对齐
        while len(blob) % 4:
            blob.append(0)
        new_off = len(blob)
        blob += new_name
        new_len = len(new_name)
        # 找 name 表在表目录里的条目位置
        entry = info["tables"]["name"]["entry"]
        # 重算校验和
        pad = (4 - new_len % 4) % 4
        csum_data = new_name + b"\0" * pad
        csum = 0
        for i in range(0, len(csum_data), 4):
            csum = (csum + struct.unpack(">I", csum_data[i:i + 4])[0]) & 0xFFFFFFFF
        struct.pack_into(">III", blob, entry + 4, csum, new_off, new_len)
        # 修 head.checkSumAdjustment（简单做法：置 0，系统仍能加载；严格校验请看 --strict）
        base, faces, tables, order = read_tables(open(path, "rb"))
        fh2 = open(path, "rb"); fh2.seek(base + 8); fh2.read(4); fh2.close()
        struct.pack_into(">I", blob, base + 8, 0)
        with open(out, "wb") as g:
            g.write(bytes(blob))
    print("  已写出: %s (%d 字节)" % (out, os.path.getsize(out)))
    print()
    print("  === 复检 === ")
    check(out)
    return 0


def main():
    ap = argparse.ArgumentParser(description="体检/修复字体的 name 表（身份）")
    ap.add_argument("font", help="字体文件（ttf/otf/ttc）")
    ap.add_argument("-o", "--out", help="修复后另存的文件（不给就只体检）")
    ap.add_argument("--family", help="指定族名（默认自动取）")
    ap.add_argument("--subfamily", help="指定子族名（默认 Regular）")
    ap.add_argument("--psname", help="指定 postscript 名（默认 族名-子族）")
    a = ap.parse_args()
    if not os.path.isfile(a.font):
        print("找不到文件: %s" % a.font); return 2
    if a.out:
        return fix(a.font, a.out, a.family, a.subfamily, a.psname)
    check(a.font)
    return 0


if __name__ == "__main__":
    sys.exit(main())
