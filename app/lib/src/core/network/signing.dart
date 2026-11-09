import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;

/// Client-side implementation of the Aseman request signing protocol.
///
/// Every authenticated request is signed with the account's Ed25519 private
/// key over the canonical payload:
///
///     method \n path \n nonce \n timestamp \n sha256hex(body)
///
/// The three headers below are attached to the request; the gateway verifies
/// them against the account's public key and rejects replays via the nonce
/// guard plus a freshness window.
class RequestSigner {
  RequestSigner(this._privateKeyHex);

  /// 64-byte Ed25519 private key as 128 hex chars (seed || public).
  final String _privateKeyHex;

  static const _nonceHeader = 'X-Decillion-Nonce';
  static const _timestampHeader = 'X-Decillion-Timestamp';
  static const _signatureHeader = 'X-Decillion-Signature';

  static const headerNonce = _nonceHeader;
  static const headerTimestamp = _timestampHeader;
  static const headerSignature = _signatureHeader;

  final Random _random = Random.secure();

  /// True when a usable private key is held.
  bool get hasKey => _privateKeyHex.isNotEmpty;

  /// Compute the canonical payload that gets signed.
  static String canonicalPayload({
    required String method,
    required String path,
    required String nonce,
    required String timestamp,
    required String body,
  }) {
    final bodyHash = sha256.convert(utf8.encode(body)).toString();
    return '$method\n$path\n$nonce\n$timestamp\n$bodyHash';
  }

  /// Sign a request and return the headers to attach. [body] must be the exact
  /// request body bytes sent to the server.
  Future<Map<String, String>> signRequest({
    required String method,
    required String path,
    required String body,
  }) async {
    if (!hasKey) return const {};
    final seed = _seedBytes();
    final keyPair = await crypto.Ed25519().newKeyPairFromSeed(seed);
    final nonce = _randomNonce();
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = canonicalPayload(
      method: method,
      path: path,
      nonce: nonce,
      timestamp: '$timestamp',
      body: body,
    );
    final signature = await crypto.Ed25519().sign(
      utf8.encode(payload),
      keyPair: keyPair,
    );
    return {
      _nonceHeader: nonce,
      _timestampHeader: '$timestamp',
      _signatureHeader: _hex(signature.bytes),
    };
  }

  /// Derive the account's public key hex from the private key, used for
  /// display/debug purposes.
  Future<String> publicKeyHex() async {
    final keyPair = await crypto.Ed25519().newKeyPairFromSeed(_seedBytes());
    final bytes = await keyPair.extractPublicKey();
    return _hex(bytes.bytes);
  }

  /// The signing seed is the first 32 bytes of the 64-byte private key.
  List<int> _seedBytes() {
    final raw = _privateKeyHex.trim();
    final decoded =
        raw.length == 128 ? _fromHex(raw).sublist(0, 32) : _fromHex(raw);
    return decoded;
  }

  String _randomNonce() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return _hex(bytes);
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _fromHex(String hex) {
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }
}
