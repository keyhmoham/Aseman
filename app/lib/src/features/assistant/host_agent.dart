/// The desktop app's side of host access: it registers this computer, polls
/// the node for agent calls, runs them inside the folders the person shared
/// and answers. On the web and on phones there is no such computer.
library;

export 'host_agent_stub.dart' if (dart.library.io) 'host_agent_io.dart';
