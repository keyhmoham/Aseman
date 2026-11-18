import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/services/aseman_service.dart';

/// What a project's computer is doing, as people see it.
enum ComputerState {
  /// Never started: there is no machine yet.
  none,
  starting,
  awake,
  asleep,
  failed,

  // While someone's request runs (theirs or anyone else's).
  waking,
  sleeping,
  replacing;

  static ComputerState parse(Object? v) => switch ('$v') {
    'awake' => awake,
    'starting' => starting,
    'asleep' => asleep,
    'failed' => failed,
    'waking' => waking,
    'sleeping' => sleeping,
    'replacing' => replacing,
    _ => none,
  };

  /// On its way somewhere: the buttons wait for it.
  bool get changing =>
      this == starting ||
      this == waking ||
      this == sleeping ||
      this == replacing;

  /// Its screen is dark.
  bool get off => this == none || this == asleep || this == failed;

  String get label => switch (this) {
    none => 'Not started yet',
    starting => 'Starting…',
    awake => 'Awake',
    asleep => 'Asleep',
    failed => 'Stopped with an error',
    waking => 'Waking up…',
    sleeping => 'Going to sleep…',
    replacing => 'Replacing…',
  };
}

/// The project's computer as the node last described it.
@immutable
class ComputerInfo {
  const ComputerInfo({
    this.state = ComputerState.none,
    this.rev = '',
    this.cpu,
    this.memoryMb,
    this.diskMb,
    this.idleTimeout = Duration.zero,
  });

  factory ComputerInfo.fromJson(Map<String, dynamic> m) => ComputerInfo(
    state: ComputerState.parse(m['state']),
    rev: '${m['rev'] ?? ''}',
    cpu: _num(m['cpu']),
    memoryMb: _num(m['memory_mb']),
    diskMb: _num(m['disk_mb']),
    idleTimeout: Duration(seconds: (_num(m['idle_timeout_sec']) ?? 0).round()),
  );

  final ComputerState state;

  /// Changes whenever anything shown of the computer does.
  final String rev;
  final num? cpu;
  final num? memoryMb;
  final num? diskMb;

  /// How long it stays awake with nothing using it.
  final Duration idleTimeout;

  ComputerInfo withState(ComputerState s) => ComputerInfo(
    state: s,
    rev: rev,
    cpu: cpu,
    memoryMb: memoryMb,
    diskMb: diskMb,
    idleTimeout: idleTimeout,
  );

  static num? _num(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');
}

/// How to reach the computer's desktop: its viewer page (a preview gateway
/// path) and the password the viewer connects with.
@immutable
class ComputerDesktop {
  const ComputerDesktop({required this.page, required this.password});

  /// The gateway path of the app's viewer (or noVNC's own page on a machine
  /// whose desktop program predates it).
  final String page;
  final String password;

  /// The viewer's address with what it needs in the fragment (never sent
  /// to a server): [view] for a live preview that takes no input.
  String viewer({bool view = false}) {
    // noVNC's own page reads the same fragment under its own names.
    final novnc = !page.contains('decillion-view');
    final fragment = Uri(
      queryParameters: {
        'password': password,
        if (view) 'view': '1',
        if (novnc) ...{
          'autoconnect': '1',
          'reconnect': '1',
          'resize': 'scale',
          if (view) 'view_only': '1',
        },
      },
    ).query;
    return '$page#$fragment';
  }
}

/// A project's computer, kept live: while anything listens it follows the
/// node's long poll (spaces.computer watch), so every screen showing it
/// changes the moment it does, whoever changed it. One per project, shared
/// by the Computer tab, its desk window and its sheet.
class SpaceComputer extends ChangeNotifier {
  SpaceComputer._(this.service, this.spaceId);

  static final _all = <String, SpaceComputer>{};

  /// The computer of [spaceId], shared by everything showing it.
  static SpaceComputer of(AsemanService service, String spaceId) =>
      _all.putIfAbsent(
        '${identityHashCode(service)}/$spaceId',
        () => SpaceComputer._(service, spaceId),
      );

  final AsemanService service;
  final String spaceId;

  ComputerInfo _info = const ComputerInfo();
  bool _loaded = false;
  Object? _error;

  /// What this screen asked for and is waiting on, shown at once.
  ComputerState? _asked;

  int _generation = 0;
  Timer? _pause;
  Completer<void>? _paused;
  Future<ComputerDesktop>? _desktop;

  ComputerInfo get info => _asked == null ? _info : _info.withState(_asked!);
  ComputerState get state => info.state;
  bool get loaded => _loaded;

  /// The last watch failed (the node could not be reached).
  Object? get error => _error;

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (first) _follow();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _unfollow();
  }

  void _follow() {
    final generation = ++_generation;
    unawaited(_watch(generation));
  }

  void _unfollow() {
    _generation++;
    _pause?.cancel();
    if (_paused?.isCompleted == false) _paused!.complete();
  }

  Future<void> _wait(Duration d) {
    final done = Completer<void>();
    _paused = done;
    _pause = Timer(d, () {
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  Future<void> _watch(int generation) async {
    var failures = 0;
    while (generation == _generation) {
      try {
        // Expo polls `spaces.computer` with operation `status` (no `watch`).
        final response = await service.invokeAction(
          'spaces',
          'computer',
          body: {'space': spaceId, 'operation': 'status'},
          timeout: const Duration(seconds: 60),
        );
        if (generation != _generation) return;
        failures = 0;
        _error = null;
        _apply(response);
        // Status is not a long poll: pause between refreshes like Expo's
        // useProjectSetup (10s awake / ~45–60s asleep).
        final awake = _info.state == ComputerState.awake;
        await _wait(Duration(seconds: awake ? 10 : 45));
      } catch (e) {
        if (generation != _generation) return;
        failures++;
        if (_error == null || !_loaded) {
          _error = e;
          _loaded = true;
          notifyListeners();
        }
        await _wait(Duration(seconds: (2 * failures).clamp(2, 15)));
      }
    }
  }

  void _apply(Object? response) {
    final m = response is Map
        ? response.map((k, v) => MapEntry('$k', v))
        : <String, dynamic>{};
    final next = ComputerInfo.fromJson(m);
    final changed =
        !_loaded || next.rev != _info.rev || next.state != _info.state;
    if (next.state != ComputerState.awake) _desktop = null;
    _info = next;
    _loaded = true;
    if (changed) notifyListeners();
  }

  Future<void> _operate(String operation, ComputerState shown) async {
    _asked = shown;
    notifyListeners();
    try {
      final response = await service.invokeAction(
        'spaces',
        'computer',
        body: {'space': spaceId, 'operation': operation},
        timeout: const Duration(minutes: 10),
      );
      _asked = null;
      _apply(response);
    } finally {
      if (_asked != null) {
        _asked = null;
        notifyListeners();
      }
    }
  }

  /// Starts the computer (Expo: `spaces.computer` operation `provision`).
  Future<void> wake() => _operate('provision', ComputerState.waking);

  /// Puts it to sleep: its files stay, its programs stop.
  Future<void> sleep() => _operate('sleep', ComputerState.sleeping);

  /// Rebuilds it from the current image; its files stay.
  Future<void> replace() {
    _desktop = null;
    return _operate('replace', ComputerState.replacing);
  }

  /// Someone is looking at the desktop: that counts as using it.
  Future<void> keepAlive() async {
    try {
      await service.invokeAction(
        'spaces',
        'computer',
        body: {'space': spaceId, 'operation': 'keepalive'},
        timeout: const Duration(seconds: 30),
      );
    } catch (_) {}
  }

  /// The desktop, started if it is not running (which wakes the computer
  /// if needed). Asked once per awake spell and shared.
  Future<ComputerDesktop> desktop() => _desktop ??= _startDesktop();

  Future<ComputerDesktop> _startDesktop() async {
    try {
      final response = await service.invokeAction(
        'spaces',
        'desktop_install',
        body: {'space': spaceId},
        timeout: const Duration(minutes: 5),
      );
      final m = response is Map ? response : const <String, dynamic>{};
      final page = '${m['viewer'] ?? m['url'] ?? ''}';
      if (page.isEmpty) {
        throw StateError('The desktop did not say where it is.');
      }
      return ComputerDesktop(page: page, password: '${m['password'] ?? ''}');
    } catch (_) {
      // The next screen to ask tries again.
      _desktop = null;
      rethrow;
    }
  }

  /// Asks for the desktop again (after it stopped answering).
  void forgetDesktop() => _desktop = null;
}
