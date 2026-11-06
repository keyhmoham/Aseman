#!/usr/bin/env python3
"""apkpatch — makes one platform's APK from the prebuilt platform client.

The sandbox image carries the platform client built once (template.apk,
built by `aseman-platform-client template`). A platform's app differs from it
only in what this tool writes:

  * assets/flutter_assets/assets/client.json — the frontend's address, the
    platform's name and accent (what the Dart side reads at start);
  * AndroidManifest.xml (binary XML) — the application id (the manifest's
    package, and every authority / permission named after it, as aapt2's
    --rename-manifest-package does), the label, versionCode, versionName and
    usesCleartextTraffic;
  * resources.arsc — the resource table's package name, which the Android
    Gradle plugin sets to the application id (Resources.getIdentifier looks
    a resource up by it): a fixed 128-character field, rewritten in place;
  * lib/<abi>/ — the ABIs the app is for (the template carries more).

The old signature is dropped and every stored entry is aligned as zipalign
does (4 bytes; shared libraries to 16 KiB pages, `zipalign -P 16`), so the
result is ready for `apksigner sign` (which must come after: an APK Signature
Scheme v2+ signature covers the whole file). Nothing else in the APK changes:
entries are copied byte for byte, still compressed.

  apkpatch.py patch TEMPLATE.apk OUT.apk --template-app-id ID --client-json FILE
      --app-id ID --label NAME --version-name 1.2.3 --version-code N
      --cleartext true|false [--abis armeabi-v7a,arm64-v8a]
  apkpatch.py inspect FILE.apk        # the manifest, client.json, ABIs, alignment (JSON)
  apkpatch.py check-template FILE.apk --app-id ID
      # the app id is only in the manifest (so renaming it there renames the app)

Standard library only; run it with `python3 -I`.
"""

import argparse
import json
import re
import struct
import sys
import zlib

CLIENT_JSON = "assets/flutter_assets/assets/client.json"
MANIFEST = "AndroidManifest.xml"

# Android attribute resource ids (android.R.attr).
ATTR_LABEL = 0x01010001
ATTR_VERSION_CODE = 0x0101021B
ATTR_VERSION_NAME = 0x0101021C
ATTR_USES_CLEARTEXT = 0x010104EC

# Res_value data types.
TYPE_STRING = 0x03
TYPE_INT_DEC = 0x10
TYPE_INT_HEX = 0x11
TYPE_INT_BOOLEAN = 0x12

# Chunk types.
RES_STRING_POOL = 0x0001
RES_TABLE = 0x0002
RES_TABLE_PACKAGE = 0x0200
RES_XML = 0x0003
RES_XML_START_ELEMENT = 0x0102
RES_XML_RESOURCE_MAP = 0x0180

UTF8_FLAG = 0x100
SORTED_FLAG = 0x1
NO_INDEX = 0xFFFFFFFF


class PatchError(Exception):
    pass


# --- zip ----------------------------------------------------------------------

class Entry:
    __slots__ = ("name", "raw_name", "flags", "method", "time", "date", "crc", "csize", "usize",
                 "ver_made", "ver_need", "iattr", "eattr", "comment", "data", "data_off")


def read_zip(path):
    with open(path, "rb") as f:
        buf = f.read()
    # End of central directory (with up to 64 KiB of comment after it).
    eocd = buf.rfind(b"PK\x05\x06", max(0, len(buf) - 22 - 0xFFFF))
    if eocd < 0:
        raise PatchError(f"{path} is not a zip file")
    (_, disk, cd_disk, n_disk, n, cd_size, cd_off, _) = struct.unpack_from("<IHHHHIIH", buf, eocd)
    if disk or cd_disk or n_disk != n or n == 0xFFFF or cd_off == 0xFFFFFFFF:
        raise PatchError(f"{path}: multi-disk or zip64 archives are not supported")
    entries, p = [], cd_off
    for _ in range(n):
        if buf[p:p + 4] != b"PK\x01\x02":
            raise PatchError(f"{path}: bad central directory")
        (_, made, need, flags, method, tm, dt, crc, csize, usize, nlen, xlen, clen, _, iattr, eattr,
         lho) = struct.unpack_from("<IHHHHHHIIIHHHHHII", buf, p)
        e = Entry()
        e.raw_name = buf[p + 46:p + 46 + nlen]
        e.name = e.raw_name.decode("utf-8" if flags & 0x800 else "cp437")
        e.comment = buf[p + 46 + nlen + xlen:p + 46 + nlen + xlen + clen]
        if 0xFFFFFFFF in (csize, usize, lho):
            raise PatchError(f"{path}: zip64 entries are not supported")
        if flags & 0x1:
            raise PatchError(f"{path}: encrypted entries are not supported")
        if buf[lho:lho + 4] != b"PK\x03\x04":
            raise PatchError(f"{path}: bad local header for {e.name}")
        lnlen, lxlen = struct.unpack_from("<HH", buf, lho + 26)
        start = lho + 30 + lnlen + lxlen
        e.data, e.data_off = buf[start:start + csize], start
        if len(e.data) != csize:
            raise PatchError(f"{path}: {e.name} is truncated")
        e.flags, e.method, e.time, e.date, e.crc, e.csize, e.usize = flags, method, tm, dt, crc, csize, usize
        e.ver_made, e.ver_need, e.iattr, e.eattr = made, need, iattr, eattr
        entries.append(e)
        p += 46 + nlen + xlen + clen
    return entries


def entry_bytes(e):
    if e.method == 0:
        out = e.data
    elif e.method == 8:
        out = zlib.decompress(e.data, -15)
    else:
        raise PatchError(f"{e.name}: unsupported compression method {e.method}")
    if len(out) != e.usize or (zlib.crc32(out) & 0xFFFFFFFF) != e.crc:
        raise PatchError(f"{e.name}: CRC or size mismatch")
    return out


def set_entry_bytes(e, data):
    """Replaces an entry's content, compressed as it was (deflate or stored)."""
    e.crc, e.usize = zlib.crc32(data) & 0xFFFFFFFF, len(data)
    if e.method == 0:
        e.data = data
    else:
        e.method = 8
        c = zlib.compressobj(9, zlib.DEFLATED, -15)
        e.data = c.compress(data) + c.flush()
    e.csize = len(e.data)


def alignment_for(e):
    """What zipalign -P 16 4 aligns a stored entry's data to (0: not at all)."""
    if e.method != 0:
        return 0
    return 16384 if e.name.endswith(".so") else 4


def write_zip(path, entries):
    """Writes [entries] with every stored entry's data aligned, the way
    zipalign does it (padding in the local header's extra field: the 0xD935
    alignment record apksigner itself writes). No data descriptors, no
    signature block: apksigner adds that."""
    out, central = bytearray(), bytearray()
    for e in entries:
        flags = e.flags & ~0x0008  # sizes are in the local header
        off = len(out)
        extra = b""
        align = alignment_for(e)
        if align:
            base = off + 30 + len(e.raw_name) + 6
            pad = (-base) % align
            extra = struct.pack("<HHH", 0xD935, 2 + pad, align) + b"\0" * pad
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, e.ver_need, flags, e.method, e.time, e.date,
                           e.crc, e.csize, e.usize, len(e.raw_name), len(extra))
        out += e.raw_name + extra
        if align and len(out) % align:
            raise PatchError(f"{e.name}: alignment failed")
        out += e.data
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, e.ver_made, e.ver_need, flags, e.method,
                               e.time, e.date, e.crc, e.csize, e.usize, len(e.raw_name), 0, len(e.comment),
                               0, e.iattr, e.eattr, off)
        central += e.raw_name + e.comment
    if len(entries) >= 0xFFFF or len(out) + len(central) >= 0xFFFFFFFF:
        raise PatchError("the APK is too large for a non-zip64 archive")
    cd_off = len(out)
    out += central
    out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(central), cd_off, 0)
    with open(path, "wb") as f:
        f.write(out)


def alignment_problems(path):
    """Stored entries whose data is not aligned (what `zipalign -c -P 16 4` checks)."""
    return [e.name for e in read_zip(path) if alignment_for(e) and e.data_off % alignment_for(e)]


# --- binary XML (AXML) ------------------------------------------------------------

def _u8len(buf, p):
    n = buf[p]
    if n & 0x80:
        return ((n & 0x7F) << 8) | buf[p + 1], p + 2
    return n, p + 1


def _u16len(buf, p):
    n = struct.unpack_from("<H", buf, p)[0]
    if n & 0x8000:
        return ((n & 0x7FFF) << 16) | struct.unpack_from("<H", buf, p + 2)[0], p + 4
    return n, p + 2


class StringPool:
    """A ResStringPool chunk. Strings it does not change keep their exact
    encoded bytes; changed and added ones are encoded the pool's way."""

    def __init__(self, buf, off):
        (ctype, hsize, size, count, style_count, flags, strings_start,
         styles_start) = struct.unpack_from("<HHIIIIII", buf, off)
        if ctype != RES_STRING_POOL:
            raise PatchError("the manifest has no string pool")
        self.size, self.flags, self.utf8 = size, flags, bool(flags & UTF8_FLAG)
        offsets = struct.unpack_from(f"<{count}I", buf, off + hsize)
        self.style_offsets = list(struct.unpack_from(f"<{style_count}I", buf, off + hsize + 4 * count))
        base = off + strings_start
        self.raw, self.strings = [], []
        for o in offsets:
            p = base + o
            if self.utf8:
                _, p = _u8len(buf, p)
                n, p = _u8len(buf, p)
                s = buf[p:p + n].decode("utf-8", "surrogatepass")
                end = p + n + 1
            else:
                n, p = _u16len(buf, p)
                s = buf[p:p + 2 * n].decode("utf-16-le", "surrogatepass")
                end = p + 2 * n + 2
            self.raw.append(buf[base + o:end])
            self.strings.append(s)
        self.style_data = buf[off + styles_start:off + size] if style_count else b""

    def _encode(self, s):
        if self.utf8:
            b = s.encode("utf-8", "surrogatepass")
            n16 = len(s.encode("utf-16-le", "surrogatepass")) // 2
            if n16 > 0x7FFF or len(b) > 0x7FFF:
                raise PatchError("a string is too long for the manifest")

            def ln(n):
                return bytes([(n >> 8) | 0x80, n & 0xFF]) if n > 0x7F else bytes([n])
            return ln(n16) + ln(len(b)) + b + b"\0"
        b = s.encode("utf-16-le", "surrogatepass")
        n = len(b) // 2
        head = struct.pack("<HH", (n >> 16) | 0x8000, n & 0xFFFF) if n > 0x7FFF else struct.pack("<H", n)
        return head + b + b"\0\0"

    def set(self, i, s):
        if self.strings[i] != s:
            self.strings[i], self.raw[i] = s, self._encode(s)

    def add(self, s):
        self.strings.append(s)
        self.raw.append(self._encode(s))
        return len(self.strings) - 1

    def build(self):
        count, style_count = len(self.raw), len(self.style_offsets)
        offsets, data = [], bytearray()
        for r in self.raw:
            offsets.append(len(data))
            data += r
        data += b"\0" * ((-len(data)) % 4)
        hsize = 28
        strings_start = hsize + 4 * count + 4 * style_count
        styles_start = strings_start + len(data) if style_count else 0
        body = struct.pack(f"<{count}I", *offsets) + struct.pack(f"<{style_count}I", *self.style_offsets)
        size = strings_start + len(data) + len(self.style_data)
        # Strings were changed and appended: the pool is no longer sorted.
        flags = self.flags & ~SORTED_FLAG
        head = struct.pack("<HHIIIIII", RES_STRING_POOL, hsize, size, count, style_count, flags,
                           strings_start, styles_start)
        return head + body + bytes(data) + self.style_data


class Manifest:
    """A binary AndroidManifest.xml: its string pool, and every attribute of
    every element (with where its value lives, to change it in place)."""

    def __init__(self, data):
        ctype, hsize, size = struct.unpack_from("<HHI", data, 0)
        if ctype != RES_XML or size != len(data):
            raise PatchError("AndroidManifest.xml is not binary XML")
        self.hsize = hsize
        self.pool = StringPool(data, hsize)
        self.rest = bytearray(data[hsize + self.pool.size:])  # resource map and nodes
        self.resmap = []
        self.attrs = []  # (element, name, resource id, offset of the attribute in rest)
        p = 0
        while p < len(self.rest):
            ctype, chsize, csize = struct.unpack_from("<HHI", self.rest, p)
            if csize < 8 or p + csize > len(self.rest):
                raise PatchError("AndroidManifest.xml is malformed")
            if ctype == RES_XML_RESOURCE_MAP:
                self.resmap = list(struct.unpack_from(f"<{(csize - chsize) // 4}I", self.rest, p + chsize))
            elif ctype == RES_XML_START_ELEMENT:
                ext = p + chsize
                _, name, astart, asize, acount = struct.unpack_from("<IIHHH", self.rest, ext)
                element = self.pool.strings[name]
                for i in range(acount):
                    a = ext + astart + i * asize
                    aname = struct.unpack_from("<I", self.rest, a + 4)[0]
                    rid = self.resmap[aname] if aname < len(self.resmap) else 0
                    self.attrs.append((element, self.pool.strings[aname], rid, a))
            p += csize

    def find(self, element, name=None, rid=None):
        for el, an, r, a in self.attrs:
            if el == element and ((rid is not None and r == rid) or (rid is None and an == name)):
                return a
        return None

    def value(self, a):
        raw, _, _, dtype, data = struct.unpack_from("<IHBBI", self.rest, a + 8)
        if dtype == TYPE_STRING:
            return self.pool.strings[data]
        if dtype == TYPE_INT_BOOLEAN:
            return data != 0
        if dtype in (TYPE_INT_DEC, TYPE_INT_HEX):
            return data
        if raw != NO_INDEX:
            return self.pool.strings[raw]
        return {"type": dtype, "data": data}

    def _typed(self, a):
        return struct.unpack_from("<B", self.rest, a + 8 + 4 + 3)[0]

    def set_string(self, a, s):
        """Points a string attribute at a new string (appended to the pool:
        the old one may be shared, and the resource map covers the first)."""
        if self._typed(a) != TYPE_STRING:
            raise PatchError("expected a string attribute")
        i = self.pool.add(s)
        struct.pack_into("<I", self.rest, a + 8, i)
        struct.pack_into("<I", self.rest, a + 16, i)

    def set_int(self, a, n):
        if self._typed(a) not in (TYPE_INT_DEC, TYPE_INT_HEX):
            raise PatchError("expected an integer attribute")
        struct.pack_into("<I", self.rest, a + 16, n & 0xFFFFFFFF)

    def set_bool(self, a, b):
        if self._typed(a) != TYPE_INT_BOOLEAN:
            raise PatchError("expected a boolean attribute")
        struct.pack_into("<I", self.rest, a + 16, 0xFFFFFFFF if b else 0)

    def build(self):
        pool = self.pool.build()
        size = self.hsize + len(pool) + len(self.rest)
        return struct.pack("<HHI", RES_XML, self.hsize, size) + pool + bytes(self.rest)

    def summary(self):
        def get(element, name=None, rid=None):
            a = self.find(element, name, rid)
            return None if a is None else self.value(a)
        return {
            "package": get("manifest", name="package"),
            "versionCode": get("manifest", rid=ATTR_VERSION_CODE),
            "versionName": get("manifest", rid=ATTR_VERSION_NAME),
            "label": get("application", rid=ATTR_LABEL),
            "usesCleartextTraffic": get("application", rid=ATTR_USES_CLEARTEXT),
        }


def app_id_pattern(app_id):
    # The id as a whole dotted name: alone, or followed by ".x" (authorities,
    # permissions); never inside a longer identifier.
    return re.compile(r"(?<![A-Za-z0-9_.])" + re.escape(app_id) + r"(?![A-Za-z0-9_])")


def patch_manifest(data, old_id, new_id, label, version_name, version_code, cleartext):
    m = Manifest(data)
    pkg = m.find("manifest", name="package")
    if pkg is None or m.value(pkg) != old_id:
        raise PatchError(f"the template's manifest package is {m.value(pkg) if pkg is not None else None!r}, not {old_id!r}")
    pat = app_id_pattern(old_id)
    renamed = 0
    for i, s in enumerate(m.pool.strings):
        if pat.search(s):
            m.pool.set(i, pat.sub(new_id, s))
            renamed += 1
    for element, rid, what in (("application", ATTR_LABEL, "label"), ("manifest", ATTR_VERSION_CODE, "versionCode"),
                               ("manifest", ATTR_VERSION_NAME, "versionName"),
                               ("application", ATTR_USES_CLEARTEXT, "usesCleartextTraffic")):
        if m.find(element, rid=rid) is None:
            raise PatchError(f"the template's manifest has no {element} {what}")
    m.set_string(m.find("application", rid=ATTR_LABEL), label)
    m.set_string(m.find("manifest", rid=ATTR_VERSION_NAME), version_name)
    m.set_int(m.find("manifest", rid=ATTR_VERSION_CODE), version_code)
    m.set_bool(m.find("application", rid=ATTR_USES_CLEARTEXT), cleartext)
    out = m.build()
    # Read back what was written, as the package manager will.
    check = Manifest(out)
    want = {"package": new_id, "versionCode": version_code, "versionName": version_name, "label": label,
            "usesCleartextTraffic": cleartext}
    got = check.summary()
    if got != want:
        raise PatchError(f"the patched manifest reads back as {got}, not {want}")
    if new_id != old_id and any(pat.search(s) for s in check.pool.strings):
        raise PatchError("the template's app id is still in the patched manifest")
    return out, renamed


# --- resources.arsc -------------------------------------------------------------

PACKAGE_NAME_CHARS = 128  # ResTable_package.name: char16_t[128], zero padded


def arsc_packages(data):
    """(offset of the name field, name) of each package in a resource table."""
    ctype, hsize, size, _ = struct.unpack_from("<HHII", data, 0)
    if ctype != RES_TABLE or size != len(data):
        raise PatchError("resources.arsc is not a resource table")
    out, p = [], hsize
    while p < size:
        ctype, chsize, csize = struct.unpack_from("<HHI", data, p)
        if csize < 8 or p + csize > size:
            raise PatchError("resources.arsc is malformed")
        if ctype == RES_TABLE_PACKAGE:
            raw = data[p + 12:p + 12 + 2 * PACKAGE_NAME_CHARS]
            out.append((p + 12, raw.decode("utf-16-le").split("\0", 1)[0]))
        p += csize
    return out


def rename_arsc_package(data, old_id, new_id):
    """Renames the resource table's package [old_id] to [new_id], in place
    (the name is a fixed field: nothing else moves)."""
    if len(new_id) >= PACKAGE_NAME_CHARS:
        raise PatchError(f"the app id is longer than {PACKAGE_NAME_CHARS - 1} characters")
    out = bytearray(data)
    found = False
    for off, name in arsc_packages(data):
        if name == old_id:
            out[off:off + 2 * PACKAGE_NAME_CHARS] = new_id.encode("utf-16-le").ljust(2 * PACKAGE_NAME_CHARS, b"\0")
            found = True
    if not found:
        raise PatchError(f"resources.arsc has no package {old_id!r} (it has {[n for _, n in arsc_packages(data)]})")
    if [n for _, n in arsc_packages(bytes(out))].count(new_id) < 1:
        raise PatchError("resources.arsc did not take the new package name")
    return bytes(out)


# --- commands ---------------------------------------------------------------------

def is_signature_file(name):
    # The JAR (v1) signature apksigner writes again.
    return name == "META-INF/MANIFEST.MF" or bool(re.match(r"^META-INF/[^/]+\.(SF|RSA|DSA|EC)$", name, re.I))


def abis_of(entries):
    return sorted({e.name.split("/")[1] for e in entries if e.name.startswith("lib/") and e.name.count("/") >= 2})


def cmd_patch(a):
    entries = read_zip(a.template)
    names = {e.name for e in entries}
    for need in (MANIFEST, CLIENT_JSON, "resources.arsc"):
        if need not in names:
            raise PatchError(f"the template has no {need}")
    with open(a.client_json, "rb") as f:
        client = f.read()
    json.loads(client)  # it must be JSON
    keep_abis = [x for x in (a.abis or "").split(",") if x]
    have = abis_of(entries)
    missing = [x for x in keep_abis if x not in have]
    if missing:
        raise PatchError(f"the template has no {', '.join(missing)} libraries (it has {', '.join(have)})")
    out, renamed = [], 0
    for e in entries:
        if is_signature_file(e.name):
            continue
        if keep_abis and e.name.startswith("lib/") and e.name.split("/")[1] not in keep_abis:
            continue
        if e.name == CLIENT_JSON:
            set_entry_bytes(e, client)
        elif e.name == "resources.arsc":
            if a.app_id != a.template_app_id:
                set_entry_bytes(e, rename_arsc_package(entry_bytes(e), a.template_app_id, a.app_id))
        elif e.name == MANIFEST:
            data, renamed = patch_manifest(entry_bytes(e), a.template_app_id, a.app_id, a.label, a.version_name,
                                           a.version_code, a.cleartext == "true")
            set_entry_bytes(e, data)
        out.append(e)
    write_zip(a.out, out)
    bad = alignment_problems(a.out)
    if bad:
        raise PatchError(f"not aligned: {', '.join(bad[:5])}")
    print(json.dumps({"out": a.out, "entries": len(out), "abis": abis_of(out), "renamed_strings": renamed}))


def inspect(path):
    entries = read_zip(path)
    by = {e.name: e for e in entries}
    if MANIFEST not in by:
        raise PatchError(f"{path} has no {MANIFEST}")
    m = Manifest(entry_bytes(by[MANIFEST]))
    client = None
    if CLIENT_JSON in by:
        client = json.loads(entry_bytes(by[CLIENT_JSON]))
    arsc = by.get("resources.arsc")
    return {
        "manifest": m.summary(),
        "resource_packages": [n for _, n in arsc_packages(entry_bytes(arsc))] if arsc is not None else [],
        "manifest_strings": m.pool.strings,
        "client": client,
        "abis": abis_of(entries),
        "resources_arsc_stored": arsc is not None and arsc.method == 0,
        "v1_signature_files": [e.name for e in entries if is_signature_file(e.name)],
        "unaligned": alignment_problems(path),
        "entries": len(entries),
    }


def cmd_inspect(a):
    print(json.dumps(inspect(a.apk), indent=2, ensure_ascii=False))


def cmd_check_template(a):
    """The app id must appear only in the manifest: renaming it there must
    rename the app. (Gradle's applicationId reaches BuildConfig and
    resources only when the app asks for it; this client does not.)"""
    info = inspect(a.apk)
    if info["manifest"]["package"] != a.app_id:
        raise PatchError(f"the template's package is {info['manifest']['package']!r}, not {a.app_id!r}")
    for k in ("label", "versionName"):
        if not isinstance(info["manifest"][k], str):
            raise PatchError(f"the template's {k} is not a plain string")
    if not isinstance(info["manifest"]["versionCode"], int) or not isinstance(info["manifest"]["usesCleartextTraffic"], bool):
        raise PatchError("the template's versionCode or usesCleartextTraffic is not a plain value")
    if info["client"] is None:
        raise PatchError(f"the template has no {CLIENT_JSON}")
    if not info["resources_arsc_stored"]:
        raise PatchError("the template's resources.arsc is compressed (Android 11+ refuses to install that)")
    needles = (a.app_id.encode("utf-8"), a.app_id.encode("utf-16-le"))
    elsewhere = []
    for e in read_zip(a.apk):
        if e.name == MANIFEST or is_signature_file(e.name):
            continue
        data = entry_bytes(e)
        if e.name == "resources.arsc":
            # Its package name is renamed with the manifest; nowhere else.
            if a.app_id in [n for _, n in arsc_packages(data)]:
                data = rename_arsc_package(data, a.app_id, "x.x")
        if any(n in data for n in needles):
            elsewhere.append(e.name)
    if elsewhere:
        raise PatchError(f"the template's app id is also in {', '.join(elsewhere)}: a patched app would keep it there")
    print(json.dumps({"ok": True, "manifest": info["manifest"], "abis": info["abis"]}))


def main(argv):
    p = argparse.ArgumentParser(prog="apkpatch")
    sub = p.add_subparsers(dest="cmd", required=True)
    pp = sub.add_parser("patch")
    pp.add_argument("template")
    pp.add_argument("out")
    pp.add_argument("--template-app-id", required=True)
    pp.add_argument("--client-json", required=True)
    pp.add_argument("--app-id", required=True)
    pp.add_argument("--label", required=True)
    pp.add_argument("--version-name", required=True)
    pp.add_argument("--version-code", required=True, type=int)
    pp.add_argument("--cleartext", required=True, choices=("true", "false"))
    pp.add_argument("--abis", default="")
    pp.set_defaults(fn=cmd_patch)
    pi = sub.add_parser("inspect")
    pi.add_argument("apk")
    pi.set_defaults(fn=cmd_inspect)
    pc = sub.add_parser("check-template")
    pc.add_argument("apk")
    pc.add_argument("--app-id", required=True)
    pc.set_defaults(fn=cmd_check_template)
    a = p.parse_args(argv)
    if a.cmd == "patch":
        if not re.match(r"^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$", a.app_id):
            raise PatchError("--app-id is a Java package name, e.g. com.example.shop")
        if len(a.app_id) >= PACKAGE_NAME_CHARS:
            raise PatchError(f"--app-id is at most {PACKAGE_NAME_CHARS - 1} characters")
        if not 1 <= a.version_code <= 2100000000:
            raise PatchError("--version-code is 1..2100000000")
    a.fn(a)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except PatchError as err:
        print(f"apkpatch: {err}", file=sys.stderr)
        sys.exit(1)
