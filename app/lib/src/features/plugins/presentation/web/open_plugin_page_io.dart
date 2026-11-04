import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Writes [document] to a temporary file and opens it in the browser.
/// Whether it opened.
Future<bool> openPluginPageInBrowser(String id, String document) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/aseman_plugins');
  await dir.create(recursive: true);
  final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final file = File('${dir.path}/$safe.html');
  await file.writeAsString(document);
  return launchUrl(Uri.file(file.path), mode: LaunchMode.externalApplication);
}
