# tradera_elpian_vm

The native half of the Elpian VM Tradera's app runs tool frontends on: an
FFI plugin that builds `libelpian_vm` (Android `.so`, iOS/macOS static
library, Linux `.so`, Windows `.dll`) from the Rust sources under `rust/`. It
has no Dart API of its own — the bindings, the rendering engine, the
miniapp host and the A2UI renderer are in the app, under `lib/src/elpian`.
On the web the same VM runs as WebAssembly (`assets/elpian/web_runtime`).

## Origin

Copied from [Elpian](https://github.com/cosmopole-org/elpian) (BSD-3-Clause):

| Here | Elpian |
|---|---|
| `rust/crates/{elpian-ffi, elpian-vm, elpian-runtime, elpian-dart-runtime, elpian-crypto, js2elpian, dart2elpian}` | `rust/crates/…` |
| `guest-sdk/dart/gui.dart` | `guest-sdk/dart/gui.dart` (embedded by elpian-dart-runtime) |
| `android/`, `ios/`, `linux/`, `macos/`, `windows/`, `tool/` | `flutter/rust_builder/` |

Tradera does not depend on Elpian's packages: to refresh the VM, copy the
directories above again (keeping this layout) and rebuild.

## Build

Rust is required (`rustup`); Android also needs `cargo-ndk`. The platform
builds invoke cargo themselves. To check the library alone:

```bash
cd rust && cargo build --release -p elpian-ffi
```
