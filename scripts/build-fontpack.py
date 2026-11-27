import base64
import hashlib
import io
import json
import os
import sys
import zipfile
from datetime import datetime

from cryptography.hazmat.primitives import serialization

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "module")
BUILTIN = os.path.join(MOD, "builtin")
CFG = os.path.join(ROOT, "variants.conf")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "dist-fontpack")
KEY_FILE = os.environ.get("PORSCHE_FONT_KEY_FILE", "")
TAG = os.environ.get("FONT_TAG", "fonts-v1.0")
FONT_VERSION = os.environ.get("FONT_VERSION", "v1.0")
FONT_CODE = int(os.environ.get("FONT_CODE", "10000"))
MIN_MODULE_CODE = 460000
REPO = "ayss2188/porsche-font-lite"
ALI = "https://cfs-porsche-downloads-q2188366745.oss-cn-hangzhou.aliyuncs.com"
BUILD = datetime.now().strftime("%m%d-%H%M")

NAMES = {
    "none": "718 素装版（无色版）",
    "colon": "911 经典版（一点红）",
    "flair": "GT3 赛道版（烈焰版）",
}
PACK_NAMES = {
    "multi": "保时捷内置字体包（全配色）",
    "none": "保时捷内置字体包（718 素装版）",
    "colon": "保时捷内置字体包（911 经典版）",
    "flair": "保时捷内置字体包（GT3 赛道版）",
}

rows = []
for line in io.open(CFG, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    p = line.split("|")
    if len(p) >= 6:
        rows.append(p)

os.makedirs(OUT, exist_ok=True)
if KEY_FILE:
    key = serialization.load_pem_private_key(open(KEY_FILE, "rb").read(), password=None)
else:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    key = Ed25519PrivateKey.generate()
    print("WARN: PORSCHE_FONT_KEY_FILE 未设置，本次使用临时密钥（只能本地测试）")

keyid = "k" + hashlib.sha256(key.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw)).hexdigest()[:12]
print("keyid", keyid)

for keyname, mid, up, fonts, disp, zipkey in rows:
    sk = zipkey or keyname
    ids = fonts.split()
    zname = "porsche-fontpack-%s-%s.zip" % (sk, FONT_VERSION)
    out = os.path.join(OUT, zname)
    prop = [
        "id=porsche_font_pack_%s" % sk,
        "name=%s" % PACK_NAMES.get(keyname, disp or keyname),
        "version=%s" % FONT_VERSION,
        "code=%d" % FONT_CODE,
        "variant=%s" % keyname,
        "min_module_code=%d" % MIN_MODULE_CODE,
        "author=暗影双生",
        "build=%s" % BUILD,
        "font_count=%d" % len(ids),
    ]
    for i in ids:
        prop.append("font.%s.name=%s" % (i, NAMES.get(i, i)))
    files = {}
    files["font.prop"] = ("\n".join(prop) + "\n").encode("utf-8")
    files["module.prop"] = (
        "id=porsche_font_pack_%s\n"
        "name=%s\n"
        "version=%s\n"
        "versionCode=%d\n"
        "author=暗影双生\n"
        "description=这是字体包，不是模块；请从字体工具箱本地导入。\n"
    ) % (sk, PACK_NAMES.get(keyname, disp or keyname), FONT_VERSION, FONT_CODE)
    files["module.prop"] = files["module.prop"].encode("utf-8")
    files["customize.sh"] = """#!/system/bin/sh
ui_print "=================================================="
ui_print "  This is a FONT PACK, not a module."
ui_print "  这是一个【字体包】，不是独立模块。"
ui_print ""
ui_print "  Please open the font module WebUI:"
ui_print "  请打开字体模块 WebUI："
ui_print "  字体工具箱 -> 字体更新 -> 安装字体 -> 从本地导入"
ui_print "=================================================="
abort "Font pack cannot be installed from the root manager / 字体包不能从 Root 管理器安装"
""".encode("utf-8")
    for i in ids:
        src = os.path.join(BUILTIN, i + ".ttf")
        if not os.path.exists(src):
            raise SystemExit("missing " + src)
        files["builtin/%s.ttf" % i] = open(src, "rb").read()

    lines = sorted(hashlib.sha256(files[n]).hexdigest() + "  " + n for n in files)
    manifest = ("\n".join(lines) + "\n").encode("utf-8")
    sig = key.sign(manifest)
    signature = ("ed25519:%s\n%s\n" % (keyid, base64.b64encode(sig).decode())).encode("utf-8")

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for n in sorted(files):
            zi = zipfile.ZipInfo(n)
            zi.external_attr = ((0o755 if n.endswith(".sh") else 0o644) | 0o100000) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, files[n])
        z.writestr("MANIFEST.sha256", manifest)
        z.writestr("SIGNATURE", signature)

    h = hashlib.sha256(open(out, "rb").read()).hexdigest()
    size = os.path.getsize(out)
    meta = {
        "version": FONT_VERSION,
        "versionCode": FONT_CODE,
        "variant": keyname,
        "zipUrl": "https://github.com/%s/releases/download/%s/%s" % (REPO, TAG, zname),
        "changelog": "%s/porsche/%s/FONT-CHANGELOG.md" % (ALI, sk),
        "sha256": h,
        "size": size,
        "minModuleCode": MIN_MODULE_CODE,
    }
    io.open(os.path.join(OUT, "font-%s.json" % sk), "w", encoding="utf-8", newline="\n").write(
        json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    print(zname, size, h)
