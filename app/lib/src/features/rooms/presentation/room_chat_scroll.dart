import 'package:flutter/foundation.dart';

/// Session-wide last vertical scroll position of each room chat.
///
/// Leaving a chat (another room, the desk, the feed, another page) disposes
/// its list; coming back reads the saved offset so the person lands where
/// they left off instead of jumping to the bottom.
class RoomChatScrollStore {
  RoomChatScrollStore._();

  static final Map<String, RoomChatScroll> _saved = {};

  static String key(String spaceId, String roomId) => '$spaceId/$roomId';

  static RoomChatScroll? read(String spaceId, String roomId) {
    if (spaceId.isEmpty || roomId.isEmpty) return null;
    return _saved[key(spaceId, roomId)];
  }

  static void save(String spaceId, String roomId, RoomChatScroll scroll) {
    if (spaceId.isEmpty || roomId.isEmpty) return;
    _saved[key(spaceId, roomId)] = scroll;
  }

  @visibleForTesting
  static void reset() => _saved.clear();
}

/// A chat list's last scroll: the pixel offset, whether it was pinned to the
/// live bottom (so a return after new messages still follows the end), and
/// the list's extent at save time (so restore can scale when content height
/// changed).
class RoomChatScroll {
  const RoomChatScroll({
    required this.offset,
    required this.nearBottom,
    this.maxExtent = 0,
  });

  final double offset;
  final bool nearBottom;

  /// [ScrollPosition.maxScrollExtent] when this was saved; 0 when unknown.
  final double maxExtent;

  /// Offset to apply for a list whose extent is now [currentMax].
  ///
  /// Small layout jitter keeps the raw offset. Only a meaningful height change
  /// (window resize, much longer/shorter thread) rescales so the relative
  /// place in the conversation is kept.
  double offsetFor(double currentMax) {
    if (nearBottom) return currentMax;
    if (currentMax <= 0) return 0;
    if (maxExtent > 0) {
      final ratio = currentMax / maxExtent;
      if (ratio < 0.75 || ratio > 1.25) {
        return (offset * ratio).clamp(0.0, currentMax);
      }
    }
    return offset.clamp(0.0, currentMax);
  }
}
