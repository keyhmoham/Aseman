/// Lenient readers for values that come from generated view trees. A prop or
/// style value of the wrong type (`"true"` for a bool, `12` for a string, a
/// list where a word belongs) reads as the nearest sensible value or as
/// absent; it never throws and takes the node, or the screen, down.
library;

/// A string: strings as given, numbers and bools as text, anything else null.
String? looseStr(Object? v) => v is String ? v : (v is num || v is bool ? '$v' : null);

/// A bool: bools, `"true"` / `"false"`, numbers (non-zero is true).
bool? looseBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    switch (v.trim().toLowerCase()) {
      case 'true' || 'yes' || '1':
        return true;
      case 'false' || 'no' || '0' || '':
        return false;
    }
  }
  return null;
}

/// A number: numbers, and strings that parse as one ("12", "12px").
num? looseNum(Object? v) {
  if (v is num) return v;
  if (v is String) {
    final s = v.trim();
    return num.tryParse(s) ?? num.tryParse(s.replaceFirst(RegExp(r'[a-z%]+$'), ''));
  }
  return null;
}

double? looseDouble(Object? v) => looseNum(v)?.toDouble();

int? looseInt(Object? v) {
  final n = looseNum(v);
  return n == null || !n.isFinite ? null : n.round();
}
