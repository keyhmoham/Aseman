"""Tests of apkpatch.py (python3 -m unittest, from this directory).

testdata/template-fixture.apk stands in for the prebuilt client: its
manifest was linked by aapt2 (android-36) with --rename-manifest-package
io.aseman.platform.template, so it is binary XML as a Flutter build writes
it, with a permission and two provider authorities named after the app id
(as androidx adds) and --rename-resources-package (the resource table is
named after the app id, as the Android Gradle plugin builds it); it has the client's assets/flutter_assets/assets/client.json,
stored native libraries for three ABIs and a (dummy) v1 signature.
"""

import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import apkpatch  # noqa: E402

FIXTURE = os.path.join(HERE, "testdata", "template-fixture.apk")
TEMPLATE_ID = "io.aseman.platform.template"


class ApkPatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, name):
        return os.path.join(self.dir, name)

    def patch(self, out="out.apk", app_id="com.acme.shop_app", label="Acme فروشگاه ✓", version_name="2.3.4",
              version_code=29700000, cleartext="true", abis="armeabi-v7a,arm64-v8a", template=FIXTURE):
        client = {"node": "https://n.example", "platform": "acme", "name": "Acme",
                  "frontend": "https://n.example/v1/platforms/acme/app/", "accent": "#4F5BD5", "godot": False}
        with open(self.path("client.json"), "w") as f:
            json.dump(client, f)
        args = ["patch", template, self.path(out), "--template-app-id", TEMPLATE_ID, "--client-json",
                self.path("client.json"), "--app-id", app_id, "--label", label, "--version-name", version_name,
                "--version-code", str(version_code), "--cleartext", cleartext, "--abis", abis]
        apkpatch.main(args)
        return client

    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", os.path.join(HERE, "apkpatch.py"), *args],
                              capture_output=True, text=True)

    def test_patch_writes_the_platform_in(self):
        client = self.patch()
        info = apkpatch.inspect(self.path("out.apk"))
        self.assertEqual(info["manifest"], {"package": "com.acme.shop_app", "versionCode": 29700000,
                                            "versionName": "2.3.4", "label": "Acme فروشگاه ✓",
                                            "usesCleartextTraffic": True})
        self.assertEqual(info["client"], client)
        strings = info["manifest_strings"]
        self.assertFalse([s for s in strings if TEMPLATE_ID in s], "the template's id is left in the manifest")
        self.assertIn("com.acme.shop_app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION", strings)
        self.assertIn("com.acme.shop_app.androidx-startup;com.acme.shop_app.other", strings)
        # The activity keeps its class (the namespace, never the app id).
        self.assertIn("io.aseman.aseman_platform_client.MainActivity", strings)
        self.assertEqual(info["abis"], ["arm64-v8a", "armeabi-v7a"])
        # The resource table is named after the app id too (as AGP builds it).
        self.assertEqual(info["resource_packages"], ["com.acme.shop_app"])
        self.assertEqual(info["v1_signature_files"], [])
        self.assertEqual(info["unaligned"], [])
        self.assertTrue(info["resources_arsc_stored"])

    def test_untouched_entries_are_copied_byte_for_byte(self):
        self.patch(abis="")
        before = {e.name: e for e in apkpatch.read_zip(FIXTURE)}
        after = {e.name: e for e in apkpatch.read_zip(self.path("out.apk"))}
        changed = {"AndroidManifest.xml", apkpatch.CLIENT_JSON, "resources.arsc"}
        dropped = {n for n in before if apkpatch.is_signature_file(n)}
        self.assertEqual(set(after), set(before) - dropped)
        for name, e in after.items():
            if name in changed:
                continue
            self.assertEqual((e.data, e.crc, e.method), (before[name].data, before[name].crc, before[name].method), name)
        self.assertEqual(apkpatch.abis_of(list(after.values())), ["arm64-v8a", "armeabi-v7a", "x86_64"])

    def test_resources_arsc_is_renamed_in_place(self):
        self.patch()
        before = {e.name: e for e in apkpatch.read_zip(FIXTURE)}["resources.arsc"]
        after = {e.name: e for e in apkpatch.read_zip(self.path("out.apk"))}["resources.arsc"]
        self.assertEqual(after.method, 0, "resources.arsc stays stored (Android 11+)")
        old, new = apkpatch.entry_bytes(before), apkpatch.entry_bytes(after)
        self.assertEqual(len(old), len(new))
        diff = [i for i in range(len(old)) if old[i] != new[i]]
        off = apkpatch.arsc_packages(old)[0][0]
        self.assertTrue(diff and min(diff) >= off and max(diff) < off + 256, "only the package name changes")

    def test_too_long_app_id_fails(self):
        with self.assertRaises(apkpatch.PatchError):
            self.patch(app_id="a." + "b" * 130)

    def test_alignment(self):
        self.patch()
        for e in apkpatch.read_zip(self.path("out.apk")):
            if e.method == 0:
                align = 16384 if e.name.endswith(".so") else 4
                self.assertEqual(e.data_off % align, 0, e.name)

    def test_false_cleartext_and_a_long_label(self):
        label = "L" * 200 + " — ﷽"
        self.patch(cleartext="false", label=label, app_id="io.aseman.platform.acme_shop")
        m = apkpatch.inspect(self.path("out.apk"))["manifest"]
        self.assertIs(m["usesCleartextTraffic"], False)
        self.assertEqual(m["label"], label)
        self.assertEqual(m["package"], "io.aseman.platform.acme_shop")

    def test_patching_twice_from_one_template_is_independent(self):
        self.patch(out="a.apk", app_id="com.a.app")
        self.patch(out="b.apk", app_id="com.b.app", version_code=5)
        self.assertEqual(apkpatch.inspect(self.path("a.apk"))["manifest"]["package"], "com.a.app")
        b = apkpatch.inspect(self.path("b.apk"))["manifest"]
        self.assertEqual((b["package"], b["versionCode"]), ("com.b.app", 5))

    def test_a_missing_abi_fails(self):
        with self.assertRaises(apkpatch.PatchError):
            self.patch(abis="mips")

    def test_bad_app_id_fails(self):
        r = self.run_cli("patch", FIXTURE, self.path("x.apk"), "--template-app-id", TEMPLATE_ID, "--client-json",
                         FIXTURE, "--app-id", "1bad", "--label", "x", "--version-name", "1", "--version-code", "1",
                         "--cleartext", "false")
        self.assertEqual(r.returncode, 1)
        self.assertIn("--app-id", r.stderr)

    def test_wrong_template_id_fails(self):
        with open(self.path("c.json"), "w") as f:
            f.write("{}")
        with self.assertRaises(apkpatch.PatchError):
            apkpatch.main(["patch", FIXTURE, self.path("x.apk"), "--template-app-id", "io.other.app", "--client-json",
                           self.path("c.json"), "--app-id", "com.a.b", "--label", "x", "--version-name", "1",
                           "--version-code", "1", "--cleartext", "false"])

    def test_check_template(self):
        r = self.run_cli("check-template", FIXTURE, "--app-id", TEMPLATE_ID)
        self.assertEqual(r.returncode, 0, r.stderr)
        # The app id compiled in elsewhere (a BuildConfig, a resource) would
        # survive the patch: such a template is refused.
        entries = apkpatch.read_zip(FIXTURE)
        extra = apkpatch.read_zip(FIXTURE)[0]
        extra.name, extra.raw_name = "classes.dex", b"classes.dex"
        apkpatch.set_entry_bytes(extra, b"dex\n" + TEMPLATE_ID.encode("utf-16-le"))
        apkpatch.write_zip(self.path("bad.apk"), entries + [extra])
        r = self.run_cli("check-template", self.path("bad.apk"), "--app-id", TEMPLATE_ID)
        self.assertEqual(r.returncode, 1)
        self.assertIn("classes.dex", r.stderr)

    def test_utf16_and_utf8_pools_round_trip(self):
        e = {x.name: x for x in apkpatch.read_zip(FIXTURE)}
        data = apkpatch.entry_bytes(e["AndroidManifest.xml"])
        m = apkpatch.Manifest(data)
        self.assertEqual(m.build(), data, "an untouched manifest is rebuilt byte for byte")
        for utf8 in (False, True):
            pool = apkpatch.StringPool(data, m.hsize)
            pool.utf8 = utf8
            pool.flags = (pool.flags | apkpatch.UTF8_FLAG) if utf8 else (pool.flags & ~apkpatch.UTF8_FLAG)
            pool.raw = [pool._encode(s) for s in pool.strings]
            pool.add("ü" * 300)  # two-byte lengths
            built = pool.build()
            again = apkpatch.StringPool(built, 0)
            self.assertEqual(again.strings, pool.strings)
            self.assertEqual(struct.unpack_from("<I", built, 4)[0], len(built))
            self.assertEqual(len(built) % 4, 0)


if __name__ == "__main__":
    unittest.main()
