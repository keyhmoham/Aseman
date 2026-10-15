import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// The leaderboards the traders evaluator ranks by (the `board` of
/// `tools.traders_leaderboard`).
enum TraderBoard {
  overall('overall', 'Overall', Icons.emoji_events_rounded),
  technical('technical', 'Technical', Icons.candlestick_chart_rounded),
  fundamental('fundamental', 'Fundamental', Icons.public_rounded),
  accuracy('accuracy', 'Accuracy', Icons.track_changes_rounded),
  consistency('consistency', 'Consistency', Icons.timeline_rounded),
  risk('risk', 'Risk', Icons.shield_rounded),
  timing('timing', 'Timing', Icons.schedule_rounded);

  const TraderBoard(this.api, this.label, this.icon);

  /// The board's name in the API.
  final String api;
  final String label;
  final IconData icon;
}

/// A trader's headline scores (0-100) from their latest reliability report.
class TraderScores {
  const TraderScores({
    this.overall,
    this.technical,
    this.fundamental,
    this.accuracy,
    this.consistency,
    this.risk,
    this.timing,
    this.confidence,
  });

  factory TraderScores.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const {};
    return TraderScores(
      overall: _num(j['overall_score']),
      technical: _num(j['technical_score']),
      fundamental: _num(j['fundamental_score']),
      accuracy: _num(j['historical_accuracy']),
      consistency: _num(j['consistency']),
      risk: _num(j['risk_management']),
      timing: _num(j['timing']),
      confidence: _num(j['confidence']),
    );
  }

  final double? overall;
  final double? technical;
  final double? fundamental;
  final double? accuracy;
  final double? consistency;
  final double? risk;
  final double? timing;
  final double? confidence;

  double? of(TraderBoard board) => switch (board) {
        TraderBoard.overall => overall,
        TraderBoard.technical => technical,
        TraderBoard.fundamental => fundamental,
        TraderBoard.accuracy => accuracy,
        TraderBoard.consistency => consistency,
        TraderBoard.risk => risk,
        TraderBoard.timing => timing,
      };
}

/// A trader on the evaluator's leaderboard: a CoinMarketCap community
/// profile and how reliable their published analysis has proven.
class Trader {
  const Trader({
    required this.handle,
    required this.name,
    required this.scores,
    this.profileLink,
    this.avatarUrl,
    this.followers,
    this.postsAnalyzed,
    this.status = 'queued',
    this.rating = 'Unrated',
    this.rank,
    this.change,
    this.lastEvaluatedAt,
    this.lastError,
    this.strengths = const [],
    this.warnings = const [],
    this.platformHandle,
  });

  factory Trader.fromJson(Map<String, dynamic> json) {
    final handle = (json['handle'] as String?)?.trim() ?? '';
    final name = (json['name'] as String?)?.trim();
    return Trader(
      handle: handle,
      name: name == null || name.isEmpty ? handle : name,
      scores: TraderScores.fromJson(json['scores'] is Map
          ? Map<String, dynamic>.from(json['scores'] as Map)
          : null),
      profileLink: json['profile_link'] as String?,
      avatarUrl: json['avatar'] is String ? json['avatar'] as String : null,
      followers: _num(json['followers'])?.round(),
      postsAnalyzed: _num(json['posts_analyzed'])?.round(),
      status: (json['status'] as String?) ?? 'queued',
      rating: (json['rating'] as String?) ?? 'Unrated',
      rank: _num(json['rank'])?.round(),
      change: _num(json['change']),
      lastEvaluatedAt: DateTime.tryParse('${json['last_evaluated_at'] ?? ''}'),
      lastError: json['last_error'] as String?,
      strengths: _strings(json['strengths']),
      warnings: _strings(json['warnings']),
      platformHandle: json['platform_account'] is Map
          ? (json['platform_account'] as Map)['handle'] as String?
          : null,
    );
  }

  final String handle;
  final String name;
  final TraderScores scores;
  final String? profileLink;
  final String? avatarUrl;
  final int? followers;
  final int? postsAnalyzed;

  /// queued, running, done or error.
  final String status;

  /// The STEP 13 analyst rating (Elite Institutional … Unreliable).
  final String rating;
  final int? rank;

  /// The overall score's change since the evaluation before.
  final double? change;
  final DateTime? lastEvaluatedAt;
  final String? lastError;
  final List<String> strengths;
  final List<String> warnings;

  /// The trader's account on this platform, where the evaluator publishes
  /// their latest posts.
  final String? platformHandle;

  bool get evaluated => scores.overall != null;

  String get initials {
    final source = name.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (source.isEmpty) return '?';
    return source.substring(0, source.length >= 2 ? 2 : 1).toUpperCase();
  }

  Color get color {
    const palette = [
      Color(0xFF14B8A6),
      AppColors.primary,
      Color(0xFF6366F1),
      AppColors.cyan,
      Color(0xFF3B82F6),
      Color(0xFFEC4899),
      Color(0xFFF97316),
      AppColors.success,
      Color(0xFF8B5CF6),
    ];
    return palette[handle.hashCode.abs() % palette.length];
  }

  /// The color of a rating, from elite (green) to unreliable (red).
  static Color ratingColor(String rating) => switch (rating) {
        'Elite Institutional' => const Color(0xFF10B981),
        'Professional' => const Color(0xFF22C55E),
        'Advanced' => const Color(0xFF3B82F6),
        'Intermediate' => const Color(0xFF6366F1),
        'Average' => AppColors.warning,
        'Weak' => const Color(0xFFF97316),
        'Unreliable' => AppColors.danger,
        _ => const Color(0xFF94A3B8),
      };

  /// The color of a 0-100 score.
  static Color scoreColor(double? score) {
    if (score == null) return const Color(0xFF94A3B8);
    if (score >= 80) return const Color(0xFF22C55E);
    if (score >= 60) return const Color(0xFF3B82F6);
    if (score >= 40) return AppColors.warning;
    return AppColors.danger;
  }
}

/// A trader's full reliability report (`tools.trader_profile`).
class TraderReport {
  const TraderReport({
    required this.trader,
    this.report = const {},
    this.history = const [],
    this.bio,
    this.analysedBy,
  });

  factory TraderReport.fromJson(Map<String, dynamic> json) {
    final report = json['report'] is Map
        ? Map<String, dynamic>.from(json['report'] as Map)
        : <String, dynamic>{};
    final analyst = json['analyst'] is Map
        ? Map<String, dynamic>.from(json['analyst'] as Map)
        : <String, dynamic>{};
    final history = <TraderScorePoint>[];
    for (final row in (json['history'] as List? ?? const [])) {
      if (row is! Map) continue;
      final at = DateTime.tryParse('${row['at'] ?? ''}');
      final overall = _num(row['overall_score']);
      if (at != null && overall != null) {
        history.add(TraderScorePoint(at, overall));
      }
    }
    return TraderReport(
      trader: Trader.fromJson(json),
      report: report,
      history: history,
      bio: analyst['bio'] as String?,
      analysedBy: json['analysed_by'] as String?,
    );
  }

  final Trader trader;

  /// The STEP 15 Final JSON as the evaluator stored it.
  final Map<String, dynamic> report;
  final List<TraderScorePoint> history;
  final String? bio;
  final String? analysedBy;

  List<String> get strengths => _strings(report['strengths']);
  List<String> get weaknesses => _strings(report['weaknesses']);
  List<String> get warnings => _strings(report['warnings']);

  /// The report's detail sections that hold anything (technical_analysis,
  /// fundamental_analysis, historical_statistics, market_validation,
  /// prediction_validation), flattened to label → value lines.
  Map<String, List<MapEntry<String, String>>> get sections {
    const keys = {
      'technical_analysis': 'Technical analysis',
      'fundamental_analysis': 'Fundamental analysis',
      'historical_statistics': 'Historical statistics',
      'market_validation': 'Market validation',
      'prediction_validation': 'Prediction validation',
    };
    final out = <String, List<MapEntry<String, String>>>{};
    keys.forEach((key, label) {
      final value = report[key];
      final lines = <MapEntry<String, String>>[];
      _flatten(value, '', lines);
      if (lines.isNotEmpty) out[label] = lines;
    });
    return out;
  }
}

class TraderScorePoint {
  const TraderScorePoint(this.at, this.overall);
  final DateTime at;
  final double overall;
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

List<String> _strings(Object? v) => v is List
    ? v.map((e) => '$e').where((e) => e.isNotEmpty).toList()
    : const [];

String _label(String key) {
  final words = key.replaceAll('_', ' ').trim();
  return words.isEmpty ? key : words[0].toUpperCase() + words.substring(1);
}

void _flatten(Object? value, String prefix, List<MapEntry<String, String>> out,
    [int depth = 0]) {
  if (out.length >= 40 || depth > 3) return;
  if (value is Map) {
    value.forEach((k, v) => _flatten(
        v,
        prefix.isEmpty ? _label('$k') : '$prefix · ${_label('$k')}',
        out,
        depth + 1));
  } else if (value is List) {
    if (value.isEmpty) return;
    if (value.every((e) => e is! Map && e is! List)) {
      out.add(MapEntry(prefix, value.join(', ')));
    } else {
      for (var i = 0; i < value.length && i < 8; i++) {
        _flatten(value[i], '$prefix ${i + 1}', out, depth + 1);
      }
    }
  } else if (value != null && '$value'.isNotEmpty) {
    final text = value is double && value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : '$value';
    out.add(MapEntry(prefix, text));
  }
}
