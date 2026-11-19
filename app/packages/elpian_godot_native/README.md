# aseman_elpian_godot

The embedded **Godot 4** engine behind the `Scene3D` widget of the app's
Elpian engine. The Dart side — the `Scene3D` widget, `GodotSceneController`,
the op protocol and the scene DSL — is in the app, under
`lib/src/elpian/godot`. This package supplies the native side: the Android and
iOS platform views and the op transport, plus the Godot project and the
GDExtension the engine runs.

Without the engine artifacts below, everything still builds and `Scene3D`
shows a placeholder instead of a viewport — the app never crashes for lack of
an engine.

## Origin

Copied from [Elpian](https://github.com/cosmopole-org/elpian) (BSD-3-Clause),
`godot/`: `android/`, `ios/`, `extension/`, `godot-project/`, `web/`. Aseman
does not depend on Elpian's packages; to refresh, copy those directories
again. Only the Flutter package name changed (`elpian_godot` →
`aseman_elpian_godot`, and the podspec with it); channel names, the Kotlin and
Swift classes and the GDExtension keep their names, since the Dart side and
the Godot project address them by those names.

Upstream notes that the native code (Kotlin, Swift, `.gd`) was written
without an Android SDK, Xcode or Godot editor at hand: it still needs its
first build.

## The engine artifacts

They are large, reproducible from pinned upstream versions, and not checked
in (see `.gitignore`). Elpian's `build_godot_artifacts.yml` workflow builds
them; by hand:

1. **The Godot engine for Android** comes from Maven Central
   (`org.godotengine:godot:4.3.0.stable`, see `android/build.gradle`) — Gradle
   fetches it, about 87 MB unpacked across four ABIs.
2. **The `elpian_godot` GDExtension** → `godot-project/bin/` (the reflective
   `ElpianScene3D` op interpreter):

   ```sh
   cd extension
   git clone --depth 1 -b godot-4.3-stable https://github.com/godotengine/godot-cpp godot-cpp
   scons platform=android target=template_release arch=arm64
   scons platform=linux target=template_release   # the headless editor needs it to export
   ```

3. **The packed op-sink project** → `android/src/main/assets/godot/embed.pck`:

   ```sh
   godot --headless --path godot-project --export-pack "Android" \
         ../android/src/main/assets/godot/embed.pck
   ```

**Android host:** the Godot fragment needs a `FragmentActivity`; the app's
`MainActivity` extends `FlutterFragmentActivity` for it.

**iOS:** `GodotRuntimeHost` (`ios/Classes/GodotSurfaceView.swift`) is the
seam a Godot runtime is attached through; see `ios/README.md`.

## Web

Not on by default: `Scene3D` is a live viewport on the web only where the page
ships an HTML5 export of `godot-project/` (the GDExtension built for wasm32
and the extensions-support, no-threads export template).

```sh
tool/build-web-export.sh [OUT_DIR]            # builds the export, in Docker (default OUT_DIR: web-export/)
tool/install-web-export.sh OUT_DIR ../../web  # Aseman: installs it beside index.html
```

`build-web-export.sh` needs only Docker and curl. It pins Godot 4.3-stable
(checking the editor against Godot's published sums) and builds the extension
with emscripten 3.1.62. Downloads are cached in `~/.cache/elpian-godot`
(`ELPIAN_GODOT_CACHE`). Of Godot's 1 GB export-templates archive only the web
templates are fetched, by HTTP range requests (`tool/fetch_zip_members.py`).

`install-web-export.sh` copies the export and the glue `web/elpian_godot_web.js`
into the web directory — `web/` before `flutter build web`, or `build/web`
after it — and adds `<script src="elpian_godot_web.js">` before
`flutter_bootstrap.js` (the glue announces a live engine as soon as it loads,
so it is only added together with an export). The large files are git-ignored.

The Expo client takes the same export: `ELPIAN_GODOT_EXPORT=OUT_DIR` at its
`npm run build:elpian`, or the files in `elpian-engine/vendor/godot` (which
also covers its phones, as they load that page in a WebView).

One `Scene3D` per page on the web: a Godot web export drives a single canvas.
