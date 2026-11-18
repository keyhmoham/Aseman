import 'package:flutter/foundation.dart';

/// What the desk does with a web page's frame once it is up.
abstract class WebPageHandle {
  /// Loads the page again.
  Future<void> reload();

  /// Sends the app's theme to the page (Aseman's web UI kit follows it).
  void setTheme(Map<String, dynamic> theme);
}

/// Called by a frame as it loads ([error] when the page could not load).
typedef WebPageStatus = void Function({bool loading, String? error});

/// How many windows are being dragged or resized right now. A web page is an
/// `<iframe>` that swallows every pointer event crossing it, so while this is
/// above zero the frames let pointers fall through to the app, and a drag
/// keeps tracking the pointer over a page. (Covering the page with another
/// platform view does not work: creating one mid-gesture cuts the gesture.)
final ValueNotifier<int> webFramesPointerHold = ValueNotifier<int>(0);
