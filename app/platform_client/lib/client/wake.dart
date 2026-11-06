import 'dart:async';

import 'package:flutter/foundation.dart';

import 'node_api.dart';

/// Where waking the frontend's computer stands.
enum WakePhase { idle, waking, ready, failed }

/// Wakes the platform's computer whenever this client needs it: when it is
/// opened, when it comes back to the foreground, and when the frontend
/// answers 503 (its computer fell asleep). Waking is the node's: any device
/// with the internet asks `_aseman/wake`, signed in or not, and the computer
/// starts as the person who published the frontend. One wake runs at a time.
class WakeController extends ChangeNotifier {
  WakeController(this._wake, {this.giveUpAfter = const Duration(minutes: 6), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Future<WakeReport> Function({Duration wait}) _wake;
  final Duration giveUpAfter;
  final DateTime Function() _now;

  WakePhase _phase = WakePhase.idle;
  String _error = '';
  DateTime? _readyAt;
  Future<bool>? _running;

  WakePhase get phase => _phase;
  String get error => _error;

  /// Whether the computer answered at least once since the client opened.
  bool get everReady => _readyAt != null;

  /// How long a ready answer is trusted without asking again.
  static const fresh = Duration(seconds: 60);

  void _set(WakePhase phase, [String error = '']) {
    if (_phase == phase && _error == error) return;
    _phase = phase;
    _error = error;
    notifyListeners();
  }

  /// Makes sure the computer is awake; true once it is. [force] asks even
  /// when it answered a moment ago (the frontend just said it is asleep).
  Future<bool> ensureAwake({bool force = false}) {
    final readyAt = _readyAt;
    if (!force && _phase == WakePhase.ready && readyAt != null && _now().difference(readyAt) < fresh) {
      return Future.value(true);
    }
    return _running ??= _run().whenComplete(() => _running = null);
  }

  Future<bool> _run() async {
    _set(WakePhase.waking);
    final started = _now();
    var failures = 0;
    while (true) {
      try {
        final report = await _wake(wait: const Duration(seconds: 15));
        if (report.ready) {
          _readyAt = _now();
          _set(WakePhase.ready);
          return true;
        }
        if (report.failed) {
          _set(WakePhase.failed, report.error.isEmpty ? 'The app could not be woken' : report.error);
          return false;
        }
        failures = 0;
        await Future<void>.delayed(report.retryAfter);
      } on NodeException catch (e) {
        // No connection yet (a phone coming back online): keep trying a while.
        if (++failures >= 5 || (e.status >= 400 && e.status < 500)) {
          _set(WakePhase.failed, e.message);
          return false;
        }
        await Future<void>.delayed(Duration(seconds: 2 * failures));
      }
      if (_now().difference(started) > giveUpAfter) {
        _set(WakePhase.failed, 'The app is taking too long to wake up');
        return false;
      }
    }
  }
}
