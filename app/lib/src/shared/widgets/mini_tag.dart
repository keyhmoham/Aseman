import 'package:flutter/material.dart';

/// Small uppercase pill label used across the app (tags, badges, chips).
class MiniTag extends StatelessWidget {
  const MiniTag(this.label, this.color, {super.key});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(8)),
      child: Text(label,
          style: TextStyle(
              fontSize: 7, fontWeight: FontWeight.w900, color: color)));
}
