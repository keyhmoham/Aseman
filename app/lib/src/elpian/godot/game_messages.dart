/// Off the web: a game running in a web view cannot post to its host, so
/// there is nothing to listen to. See `game_messages_web.dart`.
library;

/// Listens for `{arena: …}` messages from a game page at [origin]; returns
/// how to stop listening, or null where there are none.
void Function()? listenGameMessages(String origin, void Function(Object? event) onEvent) => null;
