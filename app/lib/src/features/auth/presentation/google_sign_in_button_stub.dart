import 'package:flutter/material.dart';

Widget buildGoogleSignInButton({
  required bool ready,
  required bool busy,
  required VoidCallback onPressed,
}) =>
    SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: ready && !busy ? onPressed : null,
        icon: const Icon(Icons.g_mobiledata_rounded),
        label: const Text('Continue with Google'),
      ),
    );
