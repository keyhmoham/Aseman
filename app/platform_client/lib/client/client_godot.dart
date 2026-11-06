import '../src/elpian/elpian.dart';

/// Whether 3D `Scene3D` scenes run on the embedded Godot engine in this build.
///
/// Godot is off unless the build turned it on (`aseman-platform-client
/// --godot`, which also adds the engine's plugin to the APK): then the
/// engine's platform channel is used. Off, a `Scene3D` is a placeholder and
/// nothing reaches for a plugin the APK does not have.
void useGodot(bool on) {
  resetGodotBinding();
  debugGodotBindingOverride = on ? null : MockGodotBinding();
}

/// Whether a `Scene3D` would show a live engine.
bool get godotLive => resolveGodotBinding().isLive;
