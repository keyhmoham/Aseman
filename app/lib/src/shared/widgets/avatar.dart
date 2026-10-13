import 'package:flutter/material.dart';

class AppAvatar extends StatelessWidget {
  const AppAvatar(this.text,
      {super.key, required this.color, this.radius = 19});
  final String text;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: radius,
        backgroundColor: color.withValues(alpha: .18),
        child: Text(text,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 12)),
      );
}
