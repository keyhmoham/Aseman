import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../domain/tool_models.dart';
import '../domain/tool_templates.dart';

/// Opens the tool form and returns what was filled in, or null when
/// cancelled. One form for every kind of tool: a backend (external,
/// managed or installed) and a frontend (none, static or generative).
Future<ToolDraft?> showCreateToolForm(BuildContext context) =>
    showAppForm<ToolDraft>(context, const _ToolForm());

/// Opens the tool form on an existing tool (as tools.tool_get reports it to
/// its owner) and returns what was changed, or null when cancelled or
/// nothing changed. Where its backend runs stays: that is a new tool.
Future<ToolEdit?> showEditToolForm(BuildContext context, ToolInfo tool) =>
    showAppForm<ToolEdit>(context, _ToolForm(initial: tool));

class _ToolForm extends StatefulWidget {
  const _ToolForm({this.initial});

  /// The tool being edited; null when creating one.
  final ToolInfo? initial;

  @override
  State<_ToolForm> createState() => _ToolFormState();
}

class _ToolFormState extends State<_ToolForm> {
  final name = TextEditingController();
  final description = TextEditingController();

  // Backend.
  BackendMode mode = BackendMode.managed;
  final url = TextEditingController();
  final token = TextEditingController();
  bool perPerson = false;
  ToolRuntime runtime = ToolRuntime.quickjs;
  String language = 'js';
  final backendSource = TextEditingController(text: ToolTemplates.jsBackend);
  final image = TextEditingController();
  final port = TextEditingController(text: '8080');
  final path = TextEditingController(text: '/mcp');
  int cpu = 1;
  int memory = 512;

  // Frontend.
  FrontendMode frontendMode = FrontendMode.static;
  ToolRuntime frontendRuntime = ToolRuntime.quickjs;
  String frontendLanguage = 'js';
  final frontendSource = TextEditingController(text: ToolTemplates.jsFrontend);
  Uint8List? frontendBytecode;
  String bytecodeName = '';
  final skill = TextEditingController(text: ToolTemplates.skill);
  bool cacheFrontend = true;

  bool get editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    if (t == null) return;
    name.text = t.name;
    description.text = t.description;
    mode = t.mode;
    url.text = t.url;
    perPerson = t.auth == 'user';
    runtime = t.runtime ?? ToolRuntime.quickjs;
    if (t.language.isNotEmpty) language = t.language;
    backendSource.text = t.source;
    image.text = t.image;
    if (t.port > 0) port.text = '${t.port}';
    if (t.path.isNotEmpty) path.text = t.path;
    frontendMode = t.frontendMode;
    if (t.frontendRuntime != null) frontendRuntime = t.frontendRuntime!;
    if (t.frontendLanguage.isNotEmpty) frontendLanguage = t.frontendLanguage;
    // An empty program or skill is shown empty, not as the starter template,
    // so leaving it alone never replaces what the tool runs.
    if (t.frontendMode == FrontendMode.static) {
      frontendSource.text = t.frontendSource;
    }
    if (t.frontendMode == FrontendMode.generative) {
      skill.text = t.frontendSkill;
    }
    cacheFrontend = t.frontendCache;
  }

  @override
  void dispose() {
    for (final c in [
      name, description, url, token, backendSource, image, port, path, //
      frontendSource, skill,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _setRuntime(ToolRuntime value) {
    setState(() {
      final template =
          backendSource.text == ToolTemplates.backend(runtime.wire, language);
      runtime = value;
      if (value == ToolRuntime.quickjs) language = 'js';
      if (value == ToolRuntime.elpian && language == 'js') language = 'dart';
      // Swap the starter program along with the runtime, never the author's.
      if (template) {
        backendSource.text = ToolTemplates.backend(runtime.wire, language);
      }
    });
  }

  void _setLanguage(String value) {
    setState(() {
      final template =
          backendSource.text == ToolTemplates.backend(runtime.wire, language);
      language = value;
      if (template) {
        backendSource.text = ToolTemplates.backend(runtime.wire, language);
      }
    });
  }

  Future<void> _upload(
      TextEditingController into, List<String> extensions) async {
    final file = await openFile(acceptedTypeGroups: [
      XTypeGroup(label: 'Program', extensions: extensions),
    ]);
    if (file == null) return;
    final text = await file.readAsString();
    setState(() => into.text = text);
  }

  Future<void> _uploadBytecode() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Elpian bytecode', extensions: ['bc']),
    ]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() {
      frontendBytecode = bytes;
      bytecodeName = file.name;
    });
  }

  String? _problem() {
    if (name.text.trim().isEmpty) return 'Name the app.';
    final initial = widget.initial;
    if (initial != null && initial.mode != BackendMode.external) {
      // Its runtime cannot change; only its program can.
      if (runtime != ToolRuntime.docker && backendSource.text.trim().isEmpty) {
        return 'Upload or write the backend program.';
      }
      return _frontendProblem(initial);
    }
    switch (mode) {
      case BackendMode.external:
        final u = Uri.tryParse(url.text.trim());
        if (u == null || !u.hasScheme || u.host.isEmpty) {
          return 'Enter the MCP server URL.';
        }
      case BackendMode.managed:
      case BackendMode.installed:
        if (runtime == ToolRuntime.docker) {
          if (image.text.trim().isEmpty) return 'Enter the docker image.';
          final p = int.tryParse(port.text.trim());
          if (p == null || p < 1 || p > 65535) return 'Enter a port (1–65535).';
          if (!path.text.trim().startsWith('/'))
            return 'The MCP path starts with /.';
        } else if (backendSource.text.trim().isEmpty) {
          return 'Upload or write the backend program.';
        }
    }
    return _frontendProblem(initial);
  }

  String? _frontendProblem(ToolInfo? initial) {
    switch (frontendMode) {
      case FrontendMode.static:
        // An Elpian frontend uploaded only as bytecode keeps it when it is
        // left as it is.
        final kept = initial != null &&
            !_frontendChanged(initial) &&
            initial.frontendMode == FrontendMode.static;
        if (frontendSource.text.trim().isEmpty &&
            frontendBytecode == null &&
            !kept) {
          return 'Upload or write the frontend program.';
        }
      case FrontendMode.generative:
        if (skill.text.trim().isEmpty)
          return 'Describe the frontend to generate.';
      case FrontendMode.none:
    }
    return null;
  }

  bool _frontendChanged(ToolInfo t) {
    if (frontendMode != t.frontendMode) return true;
    switch (frontendMode) {
      case FrontendMode.none:
        return false;
      case FrontendMode.generative:
        return skill.text != t.frontendSkill ||
            cacheFrontend != t.frontendCache;
      case FrontendMode.static:
        final language =
            frontendRuntime == ToolRuntime.quickjs ? 'js' : frontendLanguage;
        return frontendRuntime != t.frontendRuntime ||
            (t.frontendLanguage.isNotEmpty && language != t.frontendLanguage) ||
            frontendSource.text != t.frontendSource ||
            frontendBytecode != null;
    }
  }

  /// What was changed of the tool being edited.
  ToolEdit _edit(ToolInfo t) {
    String? changed(String now, String before) => now == before ? null : now;
    final external = t.mode == BackendMode.external;
    final hosted = !external && t.runtime != ToolRuntime.docker;
    return ToolEdit(
      name: changed(name.text.trim(), t.name),
      description: changed(description.text.trim(), t.description),
      source: hosted ? changed(backendSource.text, t.source) : null,
      frontend: _frontendChanged(t) ? _draft().frontend : null,
      url: external ? changed(url.text.trim(), t.url) : null,
      auth: external ? changed(perPerson ? 'user' : '', t.auth) : null,
      // A token is never shown back: a new one replaces it, blank keeps it.
      token: external && !perPerson && token.text.trim().isNotEmpty
          ? token.text.trim()
          : null,
    );
  }

  ToolDraft _draft() => ToolDraft(
        name: name.text.trim(),
        description: description.text.trim(),
        backend: BackendDraft(
          mode: mode,
          url: url.text.trim(),
          auth: perPerson ? 'user' : '',
          token: token.text.trim(),
          runtime: runtime,
          language: language,
          source: backendSource.text,
          image: image.text.trim(),
          port: int.tryParse(port.text.trim()) ?? 8080,
          path: path.text.trim(),
          cpu: cpu,
          memoryMb: memory,
        ),
        frontend: FrontendDraft(
          mode: frontendMode,
          runtime: frontendRuntime,
          language: frontendLanguage,
          source: frontendSource.text,
          bytecode: frontendBytecode,
          skill: skill.text,
          cache: cacheFrontend,
        ),
      );

  @override
  Widget build(BuildContext context) => AppFormFrame(
        icon: editing ? Icons.edit_outlined : Icons.widgets_outlined,
        title: editing ? 'Edit app' : 'Create app',
        subtitle: editing
            ? 'Change its name, description, backend program or frontend. Where it runs stays as it is.'
            : 'A backend whose microtools agents and people use, and a frontend people use it through.',
        submit: editing ? 'Save changes' : 'Create',
        onSubmit: () {
          final problem = _problem();
          if (problem != null) {
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(SnackBar(content: Text(problem)));
            return;
          }
          final initial = widget.initial;
          if (initial == null) {
            Navigator.pop(context, _draft());
            return;
          }
          final edit = _edit(initial);
          Navigator.pop(context, edit.isEmpty ? null : edit);
        },
        children: [
          _field('Name', name, hint: 'e.g. Weather desk', autofocus: true),
          _field('Description', description,
              hint: 'What it does — agents read this too', maxLines: 2),
          const _Section('Backend'),
          if (editing)
            ..._editedBackendFields(context)
          else ...[
            AppSegmentedField<BackendMode>(
              label: 'Where it runs',
              value: mode,
              onChanged: (v) => setState(() => mode = v),
              choices: const [
                AppChoice(BackendMode.external, 'External',
                    icon: Icons.public_rounded,
                    hint:
                        'An MCP server you already run. Its tools become this app’s microtools.'),
                AppChoice(BackendMode.managed, 'Managed',
                    icon: Icons.cloud_outlined,
                    hint:
                        'Runs on this node as a service of its own, for every space it is added to; it knows which person or agent asks, from which space and room.'),
                AppChoice(BackendMode.installed, 'Installed',
                    icon: Icons.inventory_2_outlined,
                    hint:
                        'Installed into the sandbox of each space that adds it, and serves only that space.'),
              ],
            ),
            ..._backendFields(context),
          ],
          const _Section('Frontend'),
          AppSegmentedField<FrontendMode>(
            label: 'What people see',
            value: frontendMode,
            onChanged: (v) => setState(() => frontendMode = v),
            choices: const [
              AppChoice(FrontendMode.none, 'None',
                  icon: Icons.block_rounded,
                  hint: 'Only agents use it, through its microtools.'),
              AppChoice(FrontendMode.static, 'Static',
                  icon: Icons.phone_android_rounded,
                  hint:
                      'Your program, on the Elpian VM or QuickJS. It calls microtools with askHost(\'tool.call\', [name, args]).'),
              AppChoice(FrontendMode.generative, 'Generative',
                  icon: Icons.auto_awesome_rounded,
                  hint:
                      'Generated as A2UI from your skill the first time it is opened, then kept in the component registry and filled with fresh data.'),
            ],
          ),
          ..._frontendFields(context),
        ],
      );

  List<Widget> _backendFields(BuildContext context) {
    if (mode == BackendMode.external) {
      return [
        _field('MCP server URL', url, hint: 'https://mcp.example.com/mcp'),
        AppSwitchCard(
          icon: Icons.person_outline_rounded,
          title: 'Each person signs in',
          subtitle: 'Otherwise everyone uses the credential below.',
          value: perPerson,
          onChanged: (v) => setState(() => perPerson = v),
        ),
        if (!perPerson) _field('Access token (optional)', token, obscure: true),
      ];
    }
    return [
      AppSegmentedField<ToolRuntime>(
        label: 'Runtime',
        value: runtime,
        onChanged: _setRuntime,
        choices: const [
          AppChoice(ToolRuntime.elpian, 'Elpian VM',
              hint:
                  'Dart or the Elpian JS subset, compiled to Elpian bytecode.'),
          AppChoice(ToolRuntime.quickjs, 'QuickJS', hint: 'Plain JavaScript.'),
          AppChoice(ToolRuntime.docker, 'Docker',
              hint: 'Your image, serving MCP on its port.'),
        ],
      ),
      if (runtime == ToolRuntime.elpian)
        AppSegmentedField<String>(
          label: 'Language',
          value: language,
          onChanged: _setLanguage,
          choices: const [
            AppChoice('dart', 'Dart'),
            AppChoice('js', 'JavaScript'),
          ],
        ),
      if (runtime == ToolRuntime.docker) ...[
        _field('Image', image, hint: 'registry/image:tag'),
        Row(children: [
          Expanded(child: _field('Port', port)),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: _field('MCP path', path)),
        ]),
      ] else
        _program('Backend program', backendSource,
            onUpload: () => _upload(
                backendSource,
                runtime == ToolRuntime.elpian && language == 'dart'
                    ? ['dart']
                    : ['js', 'mjs'])),
      if (mode == BackendMode.managed)
        AppChoiceField<int>(
          label: 'Machine',
          hint: 'What its service is given; bigger costs more per minute.',
          value: memory,
          onChanged: (v) => setState(() {
            memory = v;
            cpu = v >= 2048 ? 2 : 1;
          }),
          choices: const [
            AppChoice(256, 'Small · 256 MB'),
            AppChoice(512, 'Standard · 512 MB'),
            AppChoice(2048, 'Large · 2 GB'),
          ],
        ),
    ];
  }

  /// The backend of a tool being edited: where it runs is shown, not
  /// offered; how an external one is reached and a hosted one's program can
  /// change.
  List<Widget> _editedBackendFields(BuildContext context) {
    final t = widget.initial!;
    final scheme = Theme.of(context).colorScheme;
    final where = switch (t.mode) {
      BackendMode.external => 'External MCP server',
      BackendMode.managed => 'Managed · ${t.runtime?.label ?? ''}',
      BackendMode.installed => 'Installed · ${t.runtime?.label ?? ''}',
    };
    final docker = t.runtime == ToolRuntime.docker;
    return [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: .45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(Icons.dns_outlined, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              docker
                  ? '$where — ${t.image}:${t.port}${t.path}. '
                      'To run it elsewhere or from another image, create a new app.'
                  : '$where. To run it elsewhere, create a new app.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ]),
      ),
      if (t.mode == BackendMode.external) ...[
        _field('MCP server URL', url, hint: 'https://mcp.example.com/mcp'),
        AppSwitchCard(
          icon: Icons.person_outline_rounded,
          title: 'Each person signs in',
          subtitle: 'Otherwise everyone uses the credential below.',
          value: perPerson,
          onChanged: (v) => setState(() => perPerson = v),
        ),
        if (!perPerson)
          _field('New access token (optional)', token,
              hint: 'Leave blank to keep the current one', obscure: true),
      ] else if (!docker)
        _program('Backend program', backendSource,
            onUpload: () => _upload(
                backendSource,
                runtime == ToolRuntime.elpian && language == 'dart'
                    ? ['dart']
                    : ['js', 'mjs'])),
    ];
  }

  List<Widget> _frontendFields(BuildContext context) {
    switch (frontendMode) {
      case FrontendMode.none:
        return const [];
      case FrontendMode.generative:
        return [
          _program('Skill', skill,
              hint:
                  'What to show, what each part does, which microtools fill it.',
              onUpload: () => _upload(skill, ['md', 'txt'])),
          AppSwitchCard(
            icon: Icons.cached_rounded,
            title: 'Cache frontend',
            subtitle: cacheFrontend
                ? 'The first frontend generated is kept and shown to everyone after that.'
                : 'A new frontend is generated each time it is opened, designed for what the person asked while following the skill.',
            value: cacheFrontend,
            onChanged: (v) => setState(() => cacheFrontend = v),
          ),
        ];
      case FrontendMode.static:
        return [
          AppSegmentedField<ToolRuntime>(
            label: 'Runtime',
            value: frontendRuntime,
            onChanged: (v) => setState(() {
              frontendRuntime = v;
              frontendLanguage =
                  v == ToolRuntime.quickjs ? 'js' : frontendLanguage;
            }),
            choices: const [
              AppChoice(ToolRuntime.elpian, 'Elpian VM',
                  hint:
                      'Compiled to bytecode by the node, or upload what elpian build produced.'),
              AppChoice(ToolRuntime.quickjs, 'QuickJS',
                  hint: 'Plain JavaScript.'),
            ],
          ),
          if (frontendRuntime == ToolRuntime.elpian) ...[
            AppSegmentedField<String>(
              label: 'Language',
              value: frontendLanguage,
              onChanged: (v) => setState(() => frontendLanguage = v),
              choices: const [
                AppChoice('dart', 'Dart'),
                AppChoice('js', 'JavaScript'),
              ],
            ),
            OutlinedButton.icon(
              onPressed: _uploadBytecode,
              icon: const Icon(Icons.memory_rounded, size: 18),
              label: Text(bytecodeName.isEmpty
                  ? 'Upload compiled bytecode (.bc, optional)'
                  : 'Bytecode: $bytecodeName'),
            ),
          ],
          _program('Frontend program', frontendSource,
              onUpload: () => _upload(frontendSource,
                  frontendLanguage == 'dart' ? ['dart'] : ['js', 'mjs']),
              example: frontendLanguage == 'js'
                  ? IconButton(
                      tooltip: 'Use the dashboard example (charts, a table)',
                      onPressed: () => setState(() => frontendSource.text =
                          ToolTemplates.jsDashboardFrontend),
                      icon: const Icon(Icons.insights_rounded, size: 20),
                    )
                  : null),
        ];
    }
  }

  Widget _program(String label, TextEditingController controller,
          {String? hint, required VoidCallback onUpload, Widget? example}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppFieldLabel(label,
            hint: hint,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (example != null) example,
              TextButton.icon(
                onPressed: onUpload,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('Upload'),
              ),
            ])),
        TextField(
          controller: controller,
          minLines: 6,
          maxLines: 14,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
        ),
      ]);

  Widget _field(String label, TextEditingController controller,
          {String? hint,
          int maxLines = 1,
          bool autofocus = false,
          bool obscure = false}) =>
      TextField(
        controller: controller,
        autofocus: autofocus,
        obscureText: obscure,
        minLines: maxLines > 1 ? 2 : 1,
        maxLines: obscure ? 1 : maxLines,
        decoration: InputDecoration(labelText: label, hintText: hint),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Text(title.toUpperCase(),
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.primary)),
          const SizedBox(width: 10),
          const Expanded(child: Divider()),
        ]),
      );
}
