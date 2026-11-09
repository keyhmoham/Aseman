#!/usr/bin/env python3
"""Installs the Godot 4.3 editor (Linux) and the one export template the
games need, without the whole 1 GB template archive.

    python3 godot_setup.py [--dir DIR]       # prints the editor's path

The editor comes from Godot's GitHub release. The Web template
(web_nothreads_release.zip and its debug twin: no SharedArrayBuffer, so the games run in any
page, iframes included) is read straight out of the release's .tpz with HTTP
range requests: only the archive's directory and that one entry are
downloaded. 4.3 matches the engine embedded in the Aseman client
(org.godotengine:godot:4.3.0.stable), so the games' resource packs load there.
Standard library only.
"""

import argparse
import io
import os
import stat
import struct
import sys
import urllib.request
import zipfile
import zlib

VERSION = "4.3"
TAG = VERSION + "-stable"
BASE = "https://github.com/godotengine/godot/releases/download/%s/" % TAG
EDITOR = "Godot_v%s_linux.x86_64" % TAG
TPZ = "Godot_v%s_export_templates.tpz" % TAG
# The editor checks that both exist before any Web export.
WEB_TEMPLATES = ["templates/web_nothreads_release.zip", "templates/web_nothreads_debug.zip"]
UA = {"User-Agent": "persian-rails-empire-godot-setup/1.0"}


def fetch(url, start=None, end=None):
    headers = dict(UA)
    if start is not None:
        headers["Range"] = "bytes=%d-%d" % (start, end)
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=600) as r:
        return r.read(), r.headers


def content_length(url):
    data, headers = fetch(url, 0, 0)
    rng = headers.get("Content-Range", "")
    if "/" not in rng:
        raise RuntimeError("the server does not serve byte ranges for " + url)
    return int(rng.rsplit("/", 1)[1])


def remote_zip_member(url, name):
    """One member of a zip at [url], read with range requests."""
    size = content_length(url)
    tail_len = min(size, 66000)
    tail, _ = fetch(url, size - tail_len, size - 1)
    eocd = tail.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise RuntimeError("no zip directory at the end of " + url)
    cd_size, cd_off = struct.unpack("<II", tail[eocd + 12:eocd + 20])
    if cd_off == 0xFFFFFFFF:  # zip64
        loc = tail.rfind(b"PK\x06\x07")
        z64_off = struct.unpack("<Q", tail[loc + 8:loc + 16])[0]
        z64, _ = fetch(url, z64_off, z64_off + 55)
        cd_size, cd_off = struct.unpack("<QQ", z64[40:56])
    cd, _ = fetch(url, cd_off, cd_off + cd_size - 1)
    i = 0
    while i < len(cd):
        if cd[i:i + 4] != b"PK\x01\x02":
            break
        method, = struct.unpack("<H", cd[i + 10:i + 12])
        csize, usize = struct.unpack("<II", cd[i + 20:i + 28])
        nlen, xlen, clen = struct.unpack("<HHH", cd[i + 28:i + 34])
        hoff, = struct.unpack("<I", cd[i + 42:i + 46])
        fname = cd[i + 46:i + 46 + nlen].decode()
        extra = cd[i + 46 + nlen:i + 46 + nlen + xlen]
        if 0xFFFFFFFF in (csize, usize, hoff):
            # zip64 extended information: the 0xFFFFFFFF fields, in order.
            j = 0
            while j < len(extra):
                hid, hsz = struct.unpack("<HH", extra[j:j + 4])
                if hid == 1:
                    vals = list(struct.unpack("<%dQ" % (hsz // 8), extra[j + 4:j + 4 + hsz]))
                    if usize == 0xFFFFFFFF:
                        usize = vals.pop(0)
                    if csize == 0xFFFFFFFF:
                        csize = vals.pop(0)
                    if hoff == 0xFFFFFFFF:
                        hoff = vals.pop(0)
                j += 4 + hsz
        if fname == name:
            head, _ = fetch(url, hoff, hoff + 29)
            lnlen, lxlen = struct.unpack("<HH", head[26:30])
            start = hoff + 30 + lnlen + lxlen
            data, _ = fetch(url, start, start + csize - 1)
            if method == 8:
                data = zlib.decompress(data, -15)
            elif method != 0:
                raise RuntimeError("unsupported compression %d" % method)
            if len(data) != usize:
                raise RuntimeError("size mismatch reading %s" % name)
            return data
        i += 46 + nlen + xlen + clen
    raise RuntimeError("%s is not in %s" % (name, url))


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=os.path.join(os.path.expanduser("~"), ".cache", "aseman-godot"))
    ap.add_argument("--no-web", action="store_true", help="skip the Web export template")
    a = ap.parse_args(argv)
    os.makedirs(a.dir, exist_ok=True)
    editor = os.path.join(a.dir, EDITOR)
    if not os.path.exists(editor):
        print("downloading the Godot %s editor…" % VERSION, file=sys.stderr)
        data, _ = fetch(BASE + EDITOR + ".zip")
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            with open(editor, "wb") as f:
                f.write(z.read(EDITOR))
        os.chmod(editor, os.stat(editor).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    if not a.no_web:
        tdir = os.path.join(os.path.expanduser("~"), ".local", "share", "godot", "export_templates", VERSION + ".stable")
        for member in WEB_TEMPLATES:
            target = os.path.join(tdir, os.path.basename(member))
            if os.path.exists(target):
                continue
            print("fetching %s from the release archive…" % os.path.basename(member), file=sys.stderr)
            data = remote_zip_member(BASE + TPZ, member)
            os.makedirs(tdir, exist_ok=True)
            with open(target + ".part", "wb") as f:
                f.write(data)
            os.replace(target + ".part", target)
        with open(os.path.join(tdir, "version.txt"), "w") as f:
            f.write(VERSION + ".stable")
    print(editor)
    return 0


if __name__ == "__main__":
    sys.exit(main())
