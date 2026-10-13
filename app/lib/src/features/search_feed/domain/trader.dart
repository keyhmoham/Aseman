import 'package:flutter/material.dart';

/// A trader entry in the platform leaderboard.
class Trader {
  const Trader({
    required this.initials,
    required this.name,
    required this.handle,
    required this.score,
    required this.roi,
    required this.accuracy,
    required this.followers,
    required this.color,
    required this.change,
    this.verified = false,
  });

  final String initials;
  final String name;
  final String handle;
  final double score;
  final String roi;
  final String accuracy;
  final String followers;
  final Color color;
  final String change;
  final bool verified;
}
