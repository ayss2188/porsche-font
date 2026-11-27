import hashlib
import io
import json
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "module")
CFG = os.path.join(ROOT, "variants.conf")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "dist-lite")
ALI = "https://cfs-porsche-downloads-q2188366745.oss-cn-hangzhou.aliyuncs.com"
GH = "https://github.com/ayss2188/porsche-font-lite/releases/download"


def prop(name):
    p = os.path.join(MOD, "module.prop")
    for line in io.open(p, encoding="utf-8-sig"):
        if line.startswith(name + "="):
            return line.split("=", 1)[1].strip()
    return ""


VERSION = prop("version") or "v0.0"
VERSION_CODE = int(prop("versionCode") or 0)
TAG = VERSION if VERSION.startswith("v") else "v" + VERSION
rows = []
for line in io.open(CFG, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    p = line.split("|")
    if len(p) >= 6:
        rows.append(p)

os.makedirs(OUT, exist_ok=True)
for key, mid, up, fonts, disp, zipkey in rows:
    sk = zipkey or key
    name = "porsche-font-%s-%s-lite.zip" % (sk, TAG)
    out = os.path.join(OUT, name)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for b, ds, ns in os.walk(MOD):
            for n in ns:
                p = os.path.join(b, n)
                rel = os.path.relpath(p, MOD).replace("\\", "/")
                if rel.startswith("builtin/"):
                    continue
                data = open(p, "rb").read()
                if rel == "module.prop":
                    s = io.open(p, encoding="utf-8-sig").read()
                    s = re.sub(r"^id=.*$", "id=" + mid, s, flags=re.M)
                    s = re.sub(r"^name=.*$", "name=" + disp, s, flags=re.M)
                    s = re.sub(r"^updateJson=.*$", "updateJson=" + ALI + "/porsche/" + sk + "/manager-update.json", s, flags=re.M)
                    data = s.encode("utf-8")
                elif rel == "webroot/index.html":
                    s = data.decode("utf-8", "replace")
                    s = re.sub(r'const MODULE_HINT = "[^"]*"', 'const MODULE_HINT = "' + mid + '"', s)
                    data = s.encode("utf-8")
                zi = zipfile.ZipInfo(rel)
                zi.external_attr = ((0o755 if (n.endswith(".sh") or rel == "bin/run") else 0o644) | 0o100000) << 16
                zi.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(zi, data)
        z.writestr("lite.pkg", "lite=1\n")
    h = hashlib.sha256(open(out, "rb").read()).hexdigest()
    size = os.path.getsize(out)
    meta = {
        "version": VERSION,
        "versionCode": VERSION_CODE,
        "zipUrl": GH + "/" + TAG + "/" + name,
        "aliyunZipUrl": ALI + "/porsche/" + sk + "/" + name,
        "changelog": ALI + "/porsche/" + sk + "/CHANGELOG.md",
        "sha256": h,
        "size": size,
        "minModuleCode": 460000,
    }
    io.open(os.path.join(OUT, "manager-update-%s.json" % sk), "w", encoding="utf-8", newline="\n").write(
        json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    print(name, size, h)
