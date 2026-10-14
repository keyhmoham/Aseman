import 'dart:convert';

/// The values a frontend program and its host exchange through `askHost`,
/// on the Elpian VM and QuickJS alike.
abstract final class HostValues {
  /// A host call's arguments: a JSON list, a single JSON value, or raw text.
  static List<dynamic> args(String payload) {
    if (payload.isEmpty) return const [];
    try {
      final decoded = jsonDecode(payload);
      if (decoded is List) return decoded;
      return <dynamic>[decoded];
    } catch (_) {
      return <dynamic>[payload];
    }
  }

  /// [raw] as JSON when it is JSON, else the text itself.
  static dynamic decode(String raw) {
    if (raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  /// The typed envelope a program unwraps (`JSON.parse(raw).data.value`).
  static String reply(String type, dynamic value) => jsonEncode({
        'type': type,
        'data': {'value': value}
      });

  /// A failure the program can read: `{error: {code, message}}`.
  static String error(String code, Object message) => reply('object', {
        'error': {'code': code, 'message': message.toString()},
      });
}
