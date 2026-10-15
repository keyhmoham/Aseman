import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:tradera/src/genui/genui.dart';

/// [child] in an app, in a scroll view.
Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// The messages of one surface `s`: its components and data.
List<Map<String, dynamic>> surface(List<Map<String, dynamic>> components,
        [Map<String, dynamic>? data]) =>
    [
      {
        'version': 'v0.9',
        'createSurface': {'surfaceId': 's', 'catalogId': basicCatalogId}
      },
      {
        'version': 'v0.9',
        'updateComponents': {'surfaceId': 's', 'components': components}
      },
      if (data != null)
        {
          'version': 'v0.9',
          'updateDataModel': {'surfaceId': 's', 'path': '/', 'value': data}
        },
    ];

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
            functions: traderaCatalog.functions)
        .resolve({'call': name, 'args': args}).first;
