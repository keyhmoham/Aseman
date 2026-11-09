#!/usr/bin/env python3
"""Downloads the 3D models Aseman Arena uses (assets.json), at build time.

    python3 fetch_assets.py chess            # into games/chess/...
    python3 fetch_assets.py city-strike
    python3 fetch_assets.py garage --out ../app/public/assets/models
    python3 fetch_assets.py all
    python3 fetch_assets.py --list           # sources and licences

Layout it writes under a target's dest:
  * a Poly Haven model as glTF: <as>/<as>.gltf with its .bin and textures/
    (Godot imports it; the textures stay separate files);
  * a Poly Haven model as glb: <as> — one self-contained binary glTF, packed
    here from the glTF, its buffer and its textures (what a Scene3D loads at
    run time from one address);
  * a file from a pinned repository: <source>/<as>, with the files every
    model of that source references (Kenney's Textures/colormap.png).

Every source is CC0; LICENSES.md is written beside the models with each
model's source, author and licence. Already-downloaded files are kept, so a
rerun only fetches what is missing. Standard library only.
"""

import argparse
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
UA = {"User-Agent": "persian-rails-empire-asset-fetcher/1.0"}


def get(url, tries=4):
    last = None
    for n in range(tries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last = e
            time.sleep(2 ** n)
    raise RuntimeError("could not download %s: %s" % (url, last))


def save(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def polyhaven_files(asset_id, res):
    info = json.loads(get("https://api.polyhaven.com/files/%s" % asset_id))
    gltf = info["gltf"].get(res) or info["gltf"][sorted(info["gltf"])[0]]
    return gltf["gltf"]


def fetch_polyhaven_gltf(asset_id, folder, name, res="1k"):
    """The glTF and everything it includes, under folder/."""
    entry = polyhaven_files(asset_id, res)
    main = os.path.join(folder, name + ".gltf")
    if not os.path.exists(main):
        for rel, inc in entry.get("include", {}).items():
            dst = os.path.join(folder, rel)
            if not os.path.exists(dst):
                save(dst, get(inc["url"]))
        save(main, get(entry["url"]))
    return main


def pack_glb(gltf_path):
    """A self-contained .glb from a .gltf and its external files: the one
    buffer becomes the GLB's BIN chunk, every image a buffer view in it."""
    folder = os.path.dirname(gltf_path)
    doc = json.load(open(gltf_path, encoding="utf-8"))
    blob = bytearray()

    def append(data):
        while len(blob) % 4:
            blob.append(0)
        off = len(blob)
        blob.extend(data)
        return off

    # Buffers: concatenate, remember each one's offset in the new blob.
    offsets = []
    for buf in doc.get("buffers", []):
        uri = buf.get("uri")
        data = open(os.path.join(folder, urllib.request.url2pathname(uri)), "rb").read() if uri else b""
        offsets.append(append(data))
    for view in doc.get("bufferViews", []):
        view["byteOffset"] = view.get("byteOffset", 0) + offsets[view.get("buffer", 0)]
        view["buffer"] = 0
    for img in doc.get("images", []):
        uri = img.pop("uri", None)
        if not uri:
            continue
        data = open(os.path.join(folder, urllib.request.url2pathname(uri)), "rb").read()
        off = append(data)
        doc.setdefault("bufferViews", []).append({"buffer": 0, "byteOffset": off, "byteLength": len(data)})
        img["bufferView"] = len(doc["bufferViews"]) - 1
        img["mimeType"] = "image/png" if uri.lower().endswith(".png") else "image/jpeg"
    while len(blob) % 4:
        blob.append(0)
    doc["buffers"] = [{"byteLength": len(blob)}]
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js
    out += struct.pack("<II", len(blob), 0x004E4942) + bytes(blob)
    return out


def check_glb(data):
    if len(data) < 20 or struct.unpack("<I", data[:4])[0] != 0x46546C67:
        raise RuntimeError("not a binary glTF")
    n = struct.unpack("<I", data[12:16])[0]
    json.loads(data[20:20 + n])


def fetch_target(manifest, key, out=None, cache=None):
    target = manifest["targets"][key]
    dest = out or os.path.join(HERE, target["dest"])
    cache = cache or os.path.join(HERE, ".cache")
    os.makedirs(dest, exist_ok=True)
    rows = []
    for item in target["items"]:
        src = manifest["sources"][item["source"]]
        name = item["as"]
        if item["source"] == "polyhaven":
            fmt = item.get("format", "gltf")
            if fmt == "gltf":
                path = fetch_polyhaven_gltf(item["id"], os.path.join(dest, name), name, item.get("res", "1k"))
            else:
                path = os.path.join(dest, name)
                if not os.path.exists(path):
                    stem = os.path.splitext(name)[0]
                    gltf = fetch_polyhaven_gltf(item["id"], os.path.join(cache, "polyhaven", stem), stem, item.get("res", "1k"))
                    data = pack_glb(gltf)
                    check_glb(data)
                    save(path, data)
            rows.append((name, "Poly Haven — " + item["id"], "https://polyhaven.com/a/" + item["id"], src["license"]))
        else:
            folder = os.path.join(dest, item["source"])
            if key == "garage":
                folder = dest
            path = os.path.join(folder, name)
            if not os.path.exists(path):
                data = get(src["base"] + item["file"])
                if name.endswith(".glb"):
                    check_glb(data)
                save(path, data)
            for extra in src.get("extra", []):
                ep = os.path.join(folder, extra)
                if not os.path.exists(ep):
                    save(ep, get(src["base"] + extra))
            rows.append((name, src["name"], src["url"], src["license"]))
        print("  ok", key, name)
    with open(os.path.join(dest, "LICENSES.md"), "w", encoding="utf-8") as f:
        f.write("# Third-party models (%s)\n\nDownloaded by `games/fetch_assets.py` from `games/assets.json`.\n\n" % key)
        f.write("| File | Model | Source | Licence |\n| --- | --- | --- | --- |\n")
        for r in rows:
            f.write("| `%s` | %s | %s | %s |\n" % r)
    return dest


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("target", nargs="?", default="all")
    ap.add_argument("--out", help="write the target here instead of its dest")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args(argv)
    manifest = json.load(open(os.path.join(HERE, "assets.json"), encoding="utf-8"))
    if a.list:
        for k, s in manifest["sources"].items():
            print("%-14s %-55s %s" % (k, s["name"], s["license"]))
        return 0
    keys = list(manifest["targets"]) if a.target == "all" else [a.target]
    for k in keys:
        if k not in manifest["targets"]:
            print("unknown target %s (have: %s)" % (k, ", ".join(manifest["targets"])), file=sys.stderr)
            return 2
        dest = fetch_target(manifest, k, a.out if len(keys) == 1 else None)
        print("assets-ok %s -> %s" % (k, dest))
    return 0


if __name__ == "__main__":
    sys.exit(main())
