import 'package:flutter/widgets.dart';

import 'google_sign_in_button_stub.dart'
    if (dart.library.js_interop) 'google_sign_in_button_web.dart' as platform;

Widget buildGoogleSignInButton({
  required bool ready,
  required bool busy,
  required VoidCallback onPressed,
}) =>
    platform.buildGoogleSignInButton(
      ready: ready,
      busy: busy,
      onPressed: onPressed,
    );
