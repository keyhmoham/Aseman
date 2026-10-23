import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:aseman/src/agui/agui.dart';

/// [child] in an app, in a scroll view.
Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// AG-UI events that create surface `s` with [components] and optional [data].
List<Map<String, dynamic>> surface(List<Map<String, dynamic>> components,
        [Map<String, dynamic>? data]) =>
    surfaceEvents(
      surfaceId: 's',
      components: components,
      data: data,
      catalog: asemanCatalogId,
    );

Map<String, Object?> requiredCheck(String path) => {
      'condition': {
        'call': 'required',
        'args': {
          'value': {'path': path}
        }
      },
      'message': 'Required'
    };

/// Runs a catalog function on [args] (first result).
Future<Object?> call(String name, Map<String, Object?> args,
        [Object? data]) =>
    DataContext(InMemoryDataModel()..update(DataPath.root, data ?? {}),
            DataPath.root,
            functions: asemanCatalog.functions)
        .resolve({'call': name, 'args': args}).first;
