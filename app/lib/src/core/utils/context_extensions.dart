import 'package:flutter/material.dart';

extension ContextFeedback on BuildContext {
  void showMessage(String message) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}
