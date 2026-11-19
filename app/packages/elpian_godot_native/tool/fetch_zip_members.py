#!/usr/bin/env python3
"""Copies selected members of a remote zip into a new zip, reading only those
bytes (HTTP range requests; the server must support them).

    fetch_zip_members.py URL OUT.zip PATTERN...

Member names are fnmatch patterns; each member is CRC-checked as it is read.
Used for Godot's 1 GB export-templates archive, of which the web templates
are a few tens of MB.
"""
import fnmatch
import io
import sys
import urllib.request
import zipfile


class RangeFile(io.RawIOBase):
    BLOCK = 1 << 20

    def __init__(self, url):
        self.url, self.pos, self.cache = url, 0, {}
        req = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
        with urllib.request.urlopen(req, timeout=60) as r:
            if r.status != 206:
                sys.exit("the server does not support range requests")
            self.size = int(r.headers["Content-Range"].rsplit("/", 1)[1])

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, off, whence=io.SEEK_SET):
        self.pos = off if whence == io.SEEK_SET else self.pos + off if whence == io.SEEK_CUR else self.size + off
        return self.pos

    def _block(self, n):
        if n not in self.cache:
            lo = n * self.BLOCK
            hi = min(lo + self.BLOCK, self.size) - 1
            for attempt in range(4):
                try:
                    req = urllib.request.Request(self.url, headers={"Range": f"bytes={lo}-{hi}"})
                    with urllib.request.urlopen(req, timeout=120) as r:
                        self.cache[n] = r.read()
                    break
                except Exception:
                    if attempt == 3:
                        raise
            if len(self.cache) > 8:
                self.cache.pop(next(iter(self.cache)))
        return self.cache[n]

    def readinto(self, b):
        want = min(len(b), self.size - self.pos)
        got = 0
        while got < want:
            n, off = divmod(self.pos, self.BLOCK)
            chunk = self._block(n)[off : off + want - got]
            b[got : got + len(chunk)] = chunk
            got += len(chunk)
            self.pos += len(chunk)
        return got


def main():
    url, out, patterns = sys.argv[1], sys.argv[2], sys.argv[3:]
    with zipfile.ZipFile(io.BufferedReader(RangeFile(url), 1 << 16)) as src, zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as dst:
        names = [n for n in src.namelist() if any(fnmatch.fnmatch(n, p) for p in patterns)]
        if not names:
            sys.exit("no member matches " + " ".join(patterns))
        for n in names:
            print("fetching", n, flush=True)
            dst.writestr(n.rsplit("/", 1)[-1], src.read(n))  # read() checks the CRC


main()
