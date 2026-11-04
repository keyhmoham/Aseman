import 'dart:convert';
import 'dart:typed_data';

/// Where a tool's backend runs. Whichever it is, the backend is an MCP server
/// whose microtools agents call as tools and the frontend calls as its API.
enum BackendMode {
  /// An MCP server someone else runs.
  external('external', 'External'),

  /// Run by the node as a service of its own (an Elpian VM, QuickJS or
  /// docker backend on Nomad), serving every space it is added to.
  managed('managed', 'Managed'),

  /// Installed into the sandbox of each space that adds it, serving only
  /// that space.
  installed('installed', 'Installed');

  const BackendMode(this.wire, this.label);
  final String wire;
  final String label;

  static BackendMode parse(String? v) =>
      values.firstWhere((m) => m.wire == v, orElse: () => BackendMode.external);
}

/// What a managed or installed backend, or a static frontend, runs on.
enum ToolRuntime {
  /// The Elpian VM: Dart (or the Elpian JS subset) compiled to bytecode.
  elpian('elpian', 'Elpian VM'),

  /// Plain JavaScript on QuickJS.
  quickjs('quickjs', 'QuickJS'),

  /// A docker image serving MCP (backends only).
  docker('docker', 'Docker');

  const ToolRuntime(this.wire, this.label);
  final String wire;
  final String label;

  static ToolRuntime? parse(String? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }
}

/// What people see of a tool.
enum FrontendMode {
  none('', 'None'),

  /// An Elpian app: a program on the Elpian VM or QuickJS.
  static('static', 'Static');

  const FrontendMode(this.wire, this.label);
  final String wire;
  final String label;

  static FrontendMode parse(String? v) {
    return values
        .firstWhere((m) => m.wire == (v ?? ''), orElse: () => FrontendMode.none);
  }
}

/// The backend half of the tool form.
class BackendDraft {
  const BackendDraft({
    required this.mode,
    this.url = '',
    this.auth = '',
    this.token = '',
    this.runtime = ToolRuntime.quickjs,
    this.language = 'js',
    this.source = '',
    this.image = '',
    this.port = 8080,
    this.path = '/mcp',
    this.cpu = 1,
    this.memoryMb = 512,
    this.diskMb = 512,
  });

  final BackendMode mode;
  // external
  final String url;
  final String auth; // '' (shared credentials) or 'user' (each person signs in)
  final String token;
  // managed / installed
  final ToolRuntime runtime;
  final String language; // dart | js (elpian); js (quickjs)
  final String source;
  // docker
  final String image;
  final int port;
  final String path;
  // resources (managed)
  final int cpu;
  final int memoryMb;
  final int diskMb;

  Map<String, dynamic> toJson() => {
        'mode': mode.wire,
        if (mode == BackendMode.external) ...{
          'url': url,
          if (auth.isNotEmpty) 'auth': auth,
          if (token.isNotEmpty) 'token': token,
        } else ...{
          'runtime': runtime.wire,
          if (runtime == ToolRuntime.docker) ...{
            'image': image,
            'port': port,
            'path': path,
          } else ...{
            'language': runtime == ToolRuntime.quickjs ? 'js' : language,
            'source': source,
          },
          if (mode == BackendMode.managed)
            'resources': {'cpu': cpu, 'memory': memoryMb, 'disk': diskMb},
        },
      };
}

/// The frontend half of the tool form.
class FrontendDraft {
  const FrontendDraft({
    this.mode = FrontendMode.none,
    this.runtime = ToolRuntime.quickjs,
    this.language = 'js',
    this.source = '',
    this.bytecode,
  });

  final FrontendMode mode;
  final ToolRuntime runtime; // elpian | quickjs
  final String language;
  final String source;

  /// A static Elpian frontend already compiled (`elpian build`), for a node
  /// without a tool compiler.
  final Uint8List? bytecode;

  Map<String, dynamic> toJson() => {
        'mode': mode.wire,
        if (mode == FrontendMode.static) ...{
          'runtime': runtime.wire,
          'language': runtime == ToolRuntime.quickjs ? 'js' : language,
          if (source.isNotEmpty) 'source': source,
          if (bytecode != null) 'bytecode': base64Encode(bytecode!),
        },
      };
}

/// The whole tool form.
class ToolDraft {
  const ToolDraft({
    required this.name,
    this.description = '',
    required this.backend,
    this.frontend = const FrontendDraft(),
    this.perCall = 0,
  });

  final String name;
  final String description;
  final BackendDraft backend;
  final FrontendDraft frontend;

  /// Flat price per call, in ledger credits.
  final int perCall;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (description.isNotEmpty) 'description': description,
        'backend': backend.toJson(),
        'frontend': frontend.toJson(),
        if (perCall > 0) 'per_call': perCall,
      };
}

/// What the tool form changed of an existing tool; only what is set changes.
class ToolEdit {
  const ToolEdit({
    this.name,
    this.description,
    this.source,
    this.frontend,
    this.url,
    this.auth,
    this.token,
  });

  final String? name;
  final String? description;

  /// A new backend program (elpian/quickjs).
  final String? source;
  final FrontendDraft? frontend;

  /// An external backend's server URL, who signs in ('' shared, 'user' each
  /// person) and a new shared token.
  final String? url;
  final String? auth;
  final String? token;

  bool get isEmpty =>
      name == null &&
      description == null &&
      source == null &&
      frontend == null &&
      url == null &&
      auth == null &&
      token == null;

  Map<String, dynamic> toJson() => {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (source != null) 'source': source,
        if (frontend != null) 'frontend': frontend!.toJson(),
        if (url != null) 'url': url,
        if (auth != null) 'auth': auth,
        if (token != null) 'token': token,
      };
}

/// One function a tool's backend offers.
class Microtool {
  const Microtool(
      {required this.name, this.description = '', this.schema = const {}});

  final String name;
  final String description;
  final Map<String, dynamic> schema;

  factory Microtool.fromJson(Map<String, dynamic> j) => Microtool(
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        schema: (j['schema'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// A tool as tools.tool_get reports it. Its owner also gets what it was made
/// from ([editable]), so the tool can be edited.
class ToolInfo {
  const ToolInfo({
    required this.botId,
    this.name = '',
    this.description = '',
    this.status = '',
    this.mode = BackendMode.external,
    this.runtime,
    this.language = '',
    this.url = '',
    this.auth = '',
    this.image = '',
    this.port = 0,
    this.path = '',
    this.source = '',
    this.frontendMode = FrontendMode.none,
    this.frontendRuntime,
    this.frontendLanguage = '',
    this.frontendSource = '',
    this.editable = false,
    this.microtools = const [],
  });

  final String botId;
  final String name;
  final String description;
  final String status;
  final BackendMode mode;
  final ToolRuntime? runtime;
  final String language;
  // external
  final String url;
  final String auth;
  // docker
  final String image;
  final int port;
  final String path;

  /// The backend program (elpian/quickjs), for its owner.
  final String source;
  final FrontendMode frontendMode;
  final ToolRuntime? frontendRuntime;
  final String frontendLanguage;

  /// The static frontend's program, for its owner.
  final String frontendSource;
  final bool editable;
  final List<Microtool> microtools;

  bool get hasFrontend => frontendMode != FrontendMode.none;

  factory ToolInfo.fromJson(Map<String, dynamic> j) {
    final frontend = (j['frontend'] as Map?)?.cast<String, dynamic>() ?? {};
    return ToolInfo(
      botId: j['bot_id'] as String? ?? '',
      name: j['name'] as String? ?? '',
      description: j['description'] as String? ?? '',
      status: j['status'] as String? ?? '',
      mode: BackendMode.parse(j['mode'] as String?),
      runtime: ToolRuntime.parse(j['runtime'] as String?),
      language: j['language'] as String? ?? '',
      url: j['url'] as String? ?? '',
      auth: j['auth'] as String? ?? '',
      image: j['image'] as String? ?? '',
      port: (j['port'] as num?)?.toInt() ?? 0,
      path: j['path'] as String? ?? '',
      source: j['source'] as String? ?? '',
      frontendMode: FrontendMode.parse(frontend['mode'] as String?),
      frontendRuntime: ToolRuntime.parse(frontend['runtime'] as String?),
      frontendLanguage: frontend['language'] as String? ?? '',
      frontendSource: j['frontend_source'] as String? ?? '',
      editable: j['editable'] as bool? ?? false,
      microtools: [
        for (final c in (j['commands'] as List?) ?? const <dynamic>[])
          if (c is Map) Microtool.fromJson(c.cast<String, dynamic>()),
      ],
    );
  }
}

/// A tool's frontend as tools.frontend_get serves it.
class ToolFrontendPayload {
  const ToolFrontendPayload({
    required this.mode,
    this.runtime,
    this.source = '',
    this.bytecode,
    this.title = '',
    this.version = '',
    this.plugin,
  });

  final FrontendMode mode;
  final ToolRuntime? runtime;

  /// A static QuickJS frontend's program.
  final String source;

  /// A static Elpian frontend, compiled.
  final Uint8List? bytecode;
  final String title;
  final String version;

  /// The plugin this frontend belongs to (`tools.plugin_list` shape), when the
  /// tool is a plugin the person may use: its screen talks to the app through
  /// the plugin gate.
  final Map<String, dynamic>? plugin;

  factory ToolFrontendPayload.fromJson(Map<String, dynamic> j) {
    final bytecode = j['bytecode'] as String?;
    return ToolFrontendPayload(
      mode: FrontendMode.parse(j['mode'] as String?),
      runtime: ToolRuntime.parse(j['runtime'] as String?),
      source: j['source'] as String? ?? '',
      bytecode:
          bytecode == null || bytecode.isEmpty ? null : base64Decode(bytecode),
      title: j['title'] as String? ?? '',
      version: j['version'] as String? ?? '',
      plugin: j['plugin'] is Map
          ? (j['plugin'] as Map).cast<String, dynamic>()
          : null,
    );
  }
}

/// What a microtool returned (an MCP tool result), as data: its structured
/// content, else its text (as JSON when it is JSON).
dynamic microtoolValue(dynamic result) {
  if (result is! Map) return result;
  if (!result.containsKey('content') &&
      !result.containsKey('structuredContent')) {
    return result;
  }
  final texts = <String>[
    for (final block in (result['content'] as List?) ?? const <dynamic>[])
      if (block is Map && block['type'] == 'text') '${block['text'] ?? ''}',
  ];
  final text = texts.join('\n');
  if (result['isError'] == true) {
    throw MicrotoolException(
        text.isEmpty ? 'the tool reported an error' : text);
  }
  if (result['structuredContent'] != null) return result['structuredContent'];
  try {
    return jsonDecode(text);
  } catch (_) {
    return text;
  }
}

/// A microtool reported an error.
class MicrotoolException implements Exception {
  const MicrotoolException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One result a tool frontend opens on: the microtool an agent called and
/// the arguments it called it with.
class ShownResult {
  const ShownResult({this.microtool = '', this.args = const {}});

  /// Read from a `ToolFrontend` component's props (null when it has none).
  static ShownResult? fromProps(Map<String, dynamic> props) {
    final microtool =
        props['microtool'] is String ? props['microtool'] as String : '';
    final args = props['args'] is Map
        ? (props['args'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    if (microtool.isEmpty && args.isEmpty) return null;
    return ShownResult(microtool: microtool, args: args);
  }

  final String microtool;
  final Map<String, dynamic> args;

  Map<String, dynamic> toJson() => {
        if (microtool.isNotEmpty) 'microtool': microtool,
        if (args.isNotEmpty) 'args': args,
      };
}
