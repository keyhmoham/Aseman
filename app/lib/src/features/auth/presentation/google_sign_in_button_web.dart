import 'package:flutter/material.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

Widget buildGoogleSignInButton({
  required bool ready,
  required bool busy,
  required VoidCallback onPressed,
}) {
  if (!ready) {
    return const SizedBox(
      height: 48,
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }
  return IgnorePointer(
    ignoring: busy,
    child: Opacity(
      opacity: busy ? .55 : 1,
      child: SizedBox(
        height: 48,
        child: Center(
          child: web.renderButton(
            configuration: web.GSIButtonConfiguration(
              type: web.GSIButtonType.standard,
              theme: web.GSIButtonTheme.outline,
              size: web.GSIButtonSize.large,
              text: web.GSIButtonText.continueWith,
              shape: web.GSIButtonShape.pill,
              logoAlignment: web.GSIButtonLogoAlignment.left,
              minimumWidth: 260,
            ),
          ),
        ),
      ),
    ),
  );
}
