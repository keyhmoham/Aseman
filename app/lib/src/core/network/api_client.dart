import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'session_store.dart';
import 'signing.dart';

/// Thrown when the gateway returns a structured error.
class ApiException implements Exception {
  const ApiException(this.code, this.message, {this.status = 500});

  final String code;
  final String message;
  final int status;

  bool get isUnauthenticated => code == 'UNAUTHENTICATED' || status == 401;
  bool get isPermission => code == 'PERMISSION' || status == 403;
  bool get isNotFound => code == 'NOT_FOUND' || status == 404;

  @override
  String toString() => 'ApiException($status, $code): $message';
}

/// Typed response envelope returned by every namespace/action call.
class ApiResponse {
  const ApiResponse(this.status, this.body);

  final int status;
  final dynamic body; // decoded JSON (Map/List/String/num/bool)

  bool get ok => status >= 200 && status < 300;
}

/// The Tradera HTTP client. Every request is Ed25519-signed with the
/// account's identity key and carries the session bearer token, so each action
/// runs with the user's identity — this is what lets an app frontend call
/// its backend "as the user".
class TraderaApiClient {
  TraderaApiClient({
    required this.baseUrl,
    this.session,
    this.timeout = const Duration(seconds: 60),
  }) : _http = http.Client();

  final String baseUrl;
  Session? session;
  final Duration timeout;
  final http.Client _http;

  RequestSigner? get signer =>
      session == null ? null : RequestSigner(session!.privateKey);

  bool get isAuthenticated => session != null && session!.isLoggedIn;

  /// Call an action at /v1/{namespace}/{action}.
  Future<ApiResponse> call(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? requestTimeout,
  }) async {
    final path = '/v1/$namespace/$action';
    final rawBody = body.isEmpty ? '' : jsonEncode(body);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (session?.token != null && session!.token.isNotEmpty)
        'Authorization': 'Bearer ${session!.token}',
    };
    final signer = this.signer;
    if (signer != null && signer.hasKey) {
      headers.addAll(await signer.signRequest(
        method: 'POST',
        path: path,
        body: rawBody,
      ));
    }
    final uri = Uri.parse('$baseUrl$path');
    late http.Response resp;
    try {
      resp = await _http
          .post(
            uri,
            headers: headers,
            body: rawBody.isEmpty ? null : rawBody,
          )
          .timeout(requestTimeout ?? timeout);
    } on TimeoutException {
      throw const ApiException('TIMEOUT', 'The server did not answer in time',
          status: 504);
    } on http.ClientException catch (e) {
      throw ApiException('NETWORK', 'Network error: ${e.message}', status: 0);
    }
    final decodedBody = resp.body.isEmpty ? null : _tryDecode(resp.body);
    final apiResp = ApiResponse(resp.statusCode, decodedBody);
    if (apiResp.status >= 400) {
      final errBody = decodedBody is Map ? decodedBody : null;
      throw ApiException(
        (errBody?['code'] as String?) ?? 'ERROR',
        (errBody?['error'] as String?) ?? resp.body,
        status: apiResp.status,
      );
    }
    return apiResp;
  }

  /// Health probe.
  Future<bool> ping() async {
    try {
      final resp = await _http
          .get(Uri.parse('$baseUrl/healthz'))
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static dynamic _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  void dispose() => _http.close();
}
