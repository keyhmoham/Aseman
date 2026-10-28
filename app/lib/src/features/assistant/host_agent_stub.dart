import '../../app_dependencies.dart';

/// Asks the person on this device before a change to their computer.
typedef HostConfirm = Future<bool> Function(String tool, String summary);

/// No host agent where there is no desktop.
class HostAgent {
  HostAgent(this.dependencies, {required this.confirm});
  final AppDependencies dependencies;
  final HostConfirm confirm;

  static bool get supported => false;
  bool get running => false;
  String get hostId => '';
  List<String> get folders => const [];

  Future<void> restore() async {}
  Future<void> start(List<String> folders) async {}
  Future<void> stop() async {}
}
