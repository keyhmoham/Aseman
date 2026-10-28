import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../app_dependencies.dart';
import 'assistant_common.dart';

/// Asks the person on this device before a change to their computer.
typedef HostConfirm = Future<bool> Function(String tool, String summary);

/// Runs the person's agents' calls on this computer. Every call already
/// passed the node's policy (which by default asks before anything that
/// changes the computer); here each path is checked again against the shared
/// folders with links resolved, and commands and writes are confirmed on the
/// desktop itself.
class HostAgent {
  HostAgent(this.dependencies, {required this.confirm});
  final AppDependencies dependencies;
  final HostConfirm confirm;

  static const _hostKey = 'hostaccess.host';
  static const _foldersKey = 'hostaccess.folders';
  static const _outputLimit = 200000;
  static const _execTimeout = Duration(minutes: 5);

  static bool get supported =>
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  String _host = '';
  List<String> _folders = const [];
  bool _running = false;

  bool get running => _running;
  String get hostId => _host;
  List<String> get folders => _folders;

  /// Starts again if the person had it on.
  Future<void> restore() async {
    if (!supported) return;
    final prefs = await SharedPreferences.getInstance();
    final folders = prefs.getStringList(_foldersKey) ?? const [];
    _host = prefs.getString(_hostKey) ?? '';
    if (_host.isNotEmpty && folders.isNotEmpty) await start(folders);
  }

  /// Registers this computer with [folders] shared and starts answering.
  Future<void> start(List<String> folders) async {
    if (!supported) return;
    final out = jsonMap(
      await dependencies.service.invokeAction(
        'hostaccess',
        'register',
        body: {
          if (_host.isNotEmpty) 'host': _host,
          'name': Platform.localHostname,
          'platform': Platform.operatingSystem,
          'folders': folders,
        },
      ),
    );
    final host = jsonMap(out['host']);
    _host = '${host['id']}';
    _folders = jsonStrings(host['folders']);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hostKey, _host);
    await prefs.setStringList(_foldersKey, _folders);
    if (!_running) {
      _running = true;
      unawaited(_loop());
    }
  }

  /// Stops answering and tells the node this computer is off.
  Future<void> stop() async {
    _running = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_foldersKey);
    if (_host.isEmpty) return;
    try {
      await dependencies.service.invokeAction(
        'hostaccess',
        'set_enabled',
        body: {'host': _host, 'enabled': false},
      );
    } catch (_) {}
  }

  Future<void> _loop() async {
    var backoff = 1;
    while (_running) {
      try {
        final out = jsonMap(
          await dependencies.service.invokeAction(
            'hostaccess',
            'next',
            body: {'host': _host},
            timeout: const Duration(seconds: 60),
          ),
        );
        backoff = 1;
        final call = jsonMap(out['call']);
        if (call.isNotEmpty) await _answer(call);
      } catch (_) {
        await Future<void>.delayed(Duration(seconds: backoff));
        backoff = (backoff * 2).clamp(1, 60);
      }
    }
  }

  Future<void> _answer(Map<String, dynamic> call) async {
    String output = '';
    String failure = '';
    try {
      final args = jsonMap(jsonDecode('${call['args'] ?? '{}'}'));
      output = await _run('${call['tool']}', args);
    } catch (e) {
      failure = errorText(e);
    }
    if (output.length > _outputLimit)
      output = output.substring(0, _outputLimit);
    await dependencies.service.invokeAction(
      'hostaccess',
      'result',
      body: {
        'call': call['id'],
        'output': output,
        if (failure.isNotEmpty) 'error': failure,
      },
    );
  }

  Future<String> _run(String tool, Map<String, dynamic> args) async {
    switch (tool) {
      case 'host_list':
        final path = '${args['path'] ?? ''}';
        if (path.isEmpty) return _folders.join('\n');
        final dir = Directory(await _inside(path));
        final names = await dir
            .list()
            .map((e) => e is Directory ? '${_name(e.path)}/' : _name(e.path))
            .toList();
        names.sort();
        return names.join('\n');
      case 'host_read':
        return File(await _inside('${args['path']}')).readAsString();
      case 'host_write':
        final path = await _inside('${args['path']}', mayNotExist: true);
        if (!await confirm(tool, 'Write ${args['path']}'))
          throw 'refused on the computer';
        await File(path).writeAsString('${args['content'] ?? ''}');
        return 'Wrote ${args['path']}';
      case 'host_exec':
        final dir = await _inside(
          '${args['dir'] ?? (_folders.isEmpty ? '' : _folders.first)}',
        );
        final command = '${args['command']}';
        if (!await confirm(tool, '$command\nin $dir'))
          throw 'refused on the computer';
        final shell = Platform.isWindows
            ? ['cmd', '/c', command]
            : ['/bin/sh', '-c', command];
        final result = await Process.run(
          shell.first,
          shell.sublist(1),
          workingDirectory: dir,
        ).timeout(_execTimeout);
        return [
          if ('${result.stdout}'.isNotEmpty) '${result.stdout}',
          if ('${result.stderr}'.isNotEmpty) 'stderr:\n${result.stderr}',
          'exit ${result.exitCode}',
        ].join('\n');
    }
    throw 'unknown tool $tool';
  }

  String _name(String path) => path.split(Platform.pathSeparator).last;

  String _expand(String path) {
    if (path.startsWith('~')) {
      final home =
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      return home + path.substring(1);
    }
    return path;
  }

  /// The real path of [path] when it lies inside a shared folder (links
  /// resolved, so a link cannot lead out of one); otherwise an error.
  Future<String> _inside(String path, {bool mayNotExist = false}) async {
    final wanted = _expand(path);
    String real;
    if (mayNotExist && !await FileSystemEntity.isFile(wanted)) {
      final parent = File(wanted).parent;
      real =
          '${await parent.resolveSymbolicLinks()}${Platform.pathSeparator}${_name(wanted)}';
    } else {
      real = await File(wanted).resolveSymbolicLinks();
    }
    for (final folder in _folders) {
      final root = await Directory(_expand(folder)).resolveSymbolicLinks();
      if (real == root || real.startsWith('$root${Platform.pathSeparator}'))
        return real;
    }
    throw 'outside the shared folders';
  }
}
