/// [GenUiSurfaces]: genui's [SurfaceController] over Tradera's catalog, fed
/// raw A2UI messages (JSON maps or text, as tools and agents send them),
/// with the surfaces in creation order, their `sendDataModel` flags and the
/// problems genui reports.
library;

import 'dart:async';
import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:genui/genui.dart';

import '../catalog/catalog.dart';
import 'messages.dart';

/// The A2UI version this client reports in what it sends.
const String a2uiClientVersion = 'v0.9.1';

/// A problem with a message or a surface.
class GenUiProblemReport {
  const GenUiProblemReport(this.message, {this.code, this.surfaceId});
  final String message;

  /// VALIDATION_FAILED, FUNCTION_EXECUTION_FAILED, INVALID_MESSAGE…
  final String? code;
  final String? surfaceId;

  @override
  String toString() => message;
}

/// Deletes [path] of [model]; deleting an absent path does nothing.
void deletePath(DataModel model, String path) {
  final p = DataPath(path);
  try {
    if (p.segments.isNotEmpty && model.getValue<Object?>(p) == null) return;
    model.update(p, p.segments.isEmpty ? <String, dynamic>{} : null);
  } catch (e) {
    debugPrint('GenUI: could not delete $path: $e');
  }
}

class GenUiSurfaces extends ChangeNotifier {
  GenUiSurfaces({List<Catalog>? catalogs})
      : controller = SurfaceController(catalogs: catalogs ?? [traderaCatalog]) {
    _updates = controller.surfaceUpdates.listen(_onUpdate);
    _submits = controller.onSubmit.listen(_onSubmit);
  }

  final SurfaceController controller;
  late final StreamSubscription<SurfaceUpdate> _updates;
  late final StreamSubscription<ChatMessage> _submits;

  final Set<String> _sendDataModel = {};
  final _problems = StreamController<GenUiProblemReport>.broadcast();
  bool _disposed = false;

  /// Surfaces in the order they were created.
  List<String> get surfaceIds => controller.activeSurfaceIds.toList();

  List<String> get _order => surfaceIds;

  /// Problems: malformed messages, failed functions, schema findings.
  Stream<GenUiProblemReport> get problems => _problems.stream;

  /// Catalog ids surfaces may be created with.
  List<String> get supportedCatalogIds => [
        for (final c in controller.catalogs) ...[
          if (c.catalogId != null) c.catalogId!,
          ...c.catalogIdAliases,
        ]
      ];

  SurfaceContext contextFor(String surfaceId) =>
      controller.contextFor(surfaceId);

  /// Applies one server-to-client message; returns the problem it had.
  GenUiProblemReport? handle(Object? message) {
    final core.A2uiMessage parsed;
    try {
      parsed = parseA2uiMessage(message);
    } on FormatException catch (e) {
      return _report(GenUiProblemReport(e.message, code: 'INVALID_MESSAGE'));
    }
    switch (parsed) {
      case core.CreateSurfaceMessage(:final surfaceId, :final sendDataModel):
        if (_order.contains(surfaceId)) {
          // Creating a surface again starts it over.
          controller.handleMessage(core.DeleteSurfaceMessage(surfaceId: surfaceId));
        }
        if (sendDataModel) {
          _sendDataModel.add(surfaceId);
        } else {
          _sendDataModel.remove(surfaceId);
        }
      case core.DeleteSurfaceMessage(:final surfaceId):
        _sendDataModel.remove(surfaceId);
      case core.UpdateDataModelMessage(:final surfaceId, :final path, :final value)
          when value == null && controller.activeSurfaceIds.contains(surfaceId):
        // Deleting what is not there changes nothing (genui would pad a
        // list up to an out-of-range index).
        deletePath(controller.contextFor(surfaceId).dataModel, path ?? '/');
        return null;
      default:
        break;
    }
    controller.handleMessage(parsed);
    if (parsed is! core.UpdateDataModelMessage && !_disposed) {
      notifyListeners();
    }
    return null;
  }

  /// Applies [messages] in order; returns their problems.
  List<GenUiProblemReport> ingest(Iterable<Object?> messages) => [
        for (final m in messages)
          if (handle(m) case final GenUiProblemReport p) p,
      ];

  /// Deletes every surface.
  void reset() {
    for (final id in _order) {
      controller.handleMessage(core.DeleteSurfaceMessage(surfaceId: id));
    }
  }

  /// A copy of [surfaceId]'s data model (null when it has none).
  Object? dataModel(String surfaceId) {
    if (!_order.contains(surfaceId)) return null;
    try {
      final v = controller
          .contextFor(surfaceId)
          .dataModel
          .getValue<Object?>(DataPath.root);
      return v == null ? <String, dynamic>{} : plainJson(v);
    } catch (_) {
      return null;
    }
  }

  /// Writes [value] at [path] of [surfaceId]'s data model.
  void setData(String surfaceId, String path, Object? value) {
    if (!_order.contains(surfaceId)) return;
    final model = controller.contextFor(surfaceId).dataModel;
    if (value == null) {
      deletePath(model, path);
    } else {
      model.update(DataPath(path), value);
    }
  }

  /// The data models of the surfaces created with `sendDataModel` (what a
  /// turn sends the agent), or null when there are none.
  Map<String, dynamic>? clientDataModel() {
    final surfaces = <String, dynamic>{
      for (final id in _order)
        if (_sendDataModel.contains(id)) id: dataModel(id),
    };
    return surfaces.isEmpty
        ? null
        : {'version': a2uiClientVersion, 'surfaces': surfaces};
  }

  /// The surface's theme (`primaryColor`, `agentDisplayName`, `iconUrl`).
  Map<String, Object?> themeOf(String surfaceId) =>
      controller.contextFor(surfaceId).definition.value?.theme ?? const {};

  void _onUpdate(SurfaceUpdate update) {
    if (update is! ComponentsUpdated && !_disposed) notifyListeners();
  }

  void _onSubmit(ChatMessage message) {
    for (final part in message.parts.uiInteractionParts) {
      try {
        final json = jsonDecode(part.interaction);
        final error = json is Map ? json['error'] : null;
        if (error is Map) {
          _report(GenUiProblemReport('${error['message'] ?? 'Error'}',
              code: error['code'] as String?,
              surfaceId: error['surfaceId'] as String?));
        }
      } catch (_) {}
    }
  }

  GenUiProblemReport _report(GenUiProblemReport problem) {
    if (kDebugMode) debugPrint('GenUI: ${problem.code}: ${problem.message}');
    if (!_problems.isClosed) _problems.add(problem);
    return problem;
  }

  @override
  void dispose() {
    _disposed = true;
    _updates.cancel();
    _submits.cancel();
    _problems.close();
    controller.dispose();
    super.dispose();
  }
}
