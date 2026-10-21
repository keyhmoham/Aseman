import 'package:flutter/material.dart';

/// How a workspace file is shown: each kind has its own viewer.
enum FileKind {
  code,
  markdown,
  text,
  image,
  svg,
  video,
  audio,
  pdf,
  document,
  spreadsheet,
  presentation,
  archive,
  font,
  binary,
}

/// What a file is, from its name: how it is shown, its icon and colour, and
/// the language its code is highlighted as.
class FileType {
  const FileType(this.kind, this.icon, this.color, {this.language = ''});

  final FileKind kind;
  final IconData icon;
  final Color color;

  /// The highlight.js language of a code file ('' for none).
  final String language;

  /// The extension of [name] in lower case, or a well-known file name
  /// (Dockerfile, Makefile…) itself.
  static String extensionOf(String name) {
    final base = name.split('/').last.toLowerCase();
    if (_named.containsKey(base)) return base;
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? '' : base.substring(dot + 1);
  }

  static FileType of(String name) => _byExtension[extensionOf(name)] ?? _plain;

  /// MIME type for players that need one.
  static String mimeOf(String name) => switch (extensionOf(name)) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'svg' => 'image/svg+xml',
    'mp4' || 'm4v' => 'video/mp4',
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    'mkv' => 'video/x-matroska',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'ogg' || 'oga' => 'audio/ogg',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'flac' => 'audio/flac',
    'opus' => 'audio/opus',
    'pdf' => 'application/pdf',
    _ => 'application/octet-stream',
  };

  static const folder = Color(0xFFF2B84B);
  static const _plain = FileType(
    FileKind.text,
    Icons.description_outlined,
    Color(0xFF9AA4B2),
  );

  // Well-known files without an extension.
  static const _named = {
    'dockerfile': 'dockerfile',
    'makefile': 'makefile',
    'gemfile': 'ruby',
    'rakefile': 'ruby',
    'procfile': 'yaml',
    'jenkinsfile': 'groovy',
    '.gitignore': 'ini',
    '.dockerignore': 'ini',
    '.env': 'properties',
    '.editorconfig': 'ini',
    'license': 'txt',
    'readme': 'md',
  };

  static FileType _code(
    String language,
    Color color, [
    IconData icon = Icons.code_rounded,
  ]) => FileType(FileKind.code, icon, color, language: language);

  static final Map<String, FileType> _byExtension = {
    // Languages.
    'dart': _code('dart', const Color(0xFF29B6F6)),
    'go': _code('go', const Color(0xFF00ADD8)),
    'py': _code('python', const Color(0xFF3776AB)),
    'pyw': _code('python', const Color(0xFF3776AB)),
    'ipynb': _code('json', const Color(0xFFF37626), Icons.science_outlined),
    'js': _code(
      'javascript',
      const Color(0xFFF7DF1E),
      Icons.javascript_rounded,
    ),
    'mjs': _code(
      'javascript',
      const Color(0xFFF7DF1E),
      Icons.javascript_rounded,
    ),
    'cjs': _code(
      'javascript',
      const Color(0xFFF7DF1E),
      Icons.javascript_rounded,
    ),
    'jsx': _code('javascript', const Color(0xFF61DAFB)),
    'ts': _code('typescript', const Color(0xFF3178C6)),
    'tsx': _code('typescript', const Color(0xFF61DAFB)),
    'vue': _code('vue', const Color(0xFF42B883)),
    'java': _code('java', const Color(0xFFE76F00), Icons.coffee_outlined),
    'kt': _code('kotlin', const Color(0xFF7F52FF)),
    'kts': _code('kotlin', const Color(0xFF7F52FF)),
    'scala': _code('scala', const Color(0xFFDC322F)),
    'groovy': _code('groovy', const Color(0xFF4298B8)),
    'gradle': _code('gradle', const Color(0xFF02303A)),
    'swift': _code('swift', const Color(0xFFF05138)),
    'm': _code('objectivec', const Color(0xFF438EFF)),
    'c': _code('cpp', const Color(0xFF5C6BC0)),
    'h': _code('cpp', const Color(0xFF7986CB)),
    'cc': _code('cpp', const Color(0xFF00599C)),
    'cpp': _code('cpp', const Color(0xFF00599C)),
    'cxx': _code('cpp', const Color(0xFF00599C)),
    'hpp': _code('cpp', const Color(0xFF00599C)),
    'cs': _code('cs', const Color(0xFF9B4F96)),
    'fs': _code('fsharp', const Color(0xFF378BBA)),
    'rs': _code('rust', const Color(0xFFDEA584)),
    'rb': _code('ruby', const Color(0xFFCC342D)),
    'php': _code('php', const Color(0xFF777BB4)),
    'lua': _code('lua', const Color(0xFF000080)),
    'pl': _code('perl', const Color(0xFF39457E)),
    'r': _code('r', const Color(0xFF276DC3)),
    'jl': _code('julia', const Color(0xFF9558B2)),
    'hs': _code('haskell', const Color(0xFF5E5086)),
    'ex': _code('elixir', const Color(0xFF6E4A7E)),
    'exs': _code('elixir', const Color(0xFF6E4A7E)),
    'erl': _code('erlang', const Color(0xFFA90533)),
    'clj': _code('clojure', const Color(0xFF5881D8)),
    'elm': _code('elm', const Color(0xFF60B5CC)),
    'ml': _code('ocaml', const Color(0xFFEC6813)),
    'nim': _code('nimrod', const Color(0xFFFFE953)),
    'zig': _code('rust', const Color(0xFFF7A41D)),
    'sol': _code('solidity', const Color(0xFF8A92B2)),
    'v': _code('verilog', const Color(0xFF848BF3)),
    'vhd': _code('vhdl', const Color(0xFF848BF3)),
    'asm': _code('x86asm', const Color(0xFF6E4C13)),
    's': _code('armasm', const Color(0xFF6E4C13)),
    'glsl': _code('glsl', const Color(0xFF5686A5)),
    'tex': _code('tex', const Color(0xFF3D6117), Icons.functions_rounded),
    'sql': _code('sql', const Color(0xFFE38C00), Icons.storage_rounded),
    'graphql': _code('graphql', const Color(0xFFE10098)),
    'gql': _code('graphql', const Color(0xFFE10098)),
    'proto': _code('protobuf', const Color(0xFF4285F4)),
    // Shells and build files.
    'sh': _code('bash', const Color(0xFF4EAA25), Icons.terminal_rounded),
    'bash': _code('bash', const Color(0xFF4EAA25), Icons.terminal_rounded),
    'zsh': _code('bash', const Color(0xFF4EAA25), Icons.terminal_rounded),
    'fish': _code('shell', const Color(0xFF4EAA25), Icons.terminal_rounded),
    'ps1': _code('powershell', const Color(0xFF5391FE), Icons.terminal_rounded),
    'bat': _code('dos', const Color(0xFFC1F12E), Icons.terminal_rounded),
    'cmd': _code('dos', const Color(0xFFC1F12E), Icons.terminal_rounded),
    'dockerfile': _code(
      'dockerfile',
      const Color(0xFF2496ED),
      Icons.directions_boat_outlined,
    ),
    'makefile': _code(
      'makefile',
      const Color(0xFF6D8086),
      Icons.build_outlined,
    ),
    'mk': _code('makefile', const Color(0xFF6D8086), Icons.build_outlined),
    'cmake': _code('cmake', const Color(0xFF064F8C), Icons.build_outlined),
    'nix': _code('nix', const Color(0xFF7EBAE4)),
    'tf': _code('ini', const Color(0xFF7B42BC)),
    // Web.
    'html': _code('xml', const Color(0xFFE34F26), Icons.html_rounded),
    'htm': _code('xml', const Color(0xFFE34F26), Icons.html_rounded),
    'xhtml': _code('xml', const Color(0xFFE34F26), Icons.html_rounded),
    'css': _code('css', const Color(0xFF1572B6), Icons.css_rounded),
    'scss': _code('scss', const Color(0xFFCC6699), Icons.css_rounded),
    'sass': _code('scss', const Color(0xFFCC6699), Icons.css_rounded),
    'less': _code('less', const Color(0xFF1D365D), Icons.css_rounded),
    'styl': _code('stylus', const Color(0xFFFF6347), Icons.css_rounded),
    'hbs': _code('handlebars', const Color(0xFFF0772B)),
    'twig': _code('twig', const Color(0xFF8BC34A)),
    // Data and config.
    'json': _code('json', const Color(0xFFF5C518), Icons.data_object_rounded),
    'jsonc': _code('json', const Color(0xFFF5C518), Icons.data_object_rounded),
    'geojson': _code(
      'json',
      const Color(0xFFF5C518),
      Icons.data_object_rounded,
    ),
    'yaml': _code('yaml', const Color(0xFFCB171E), Icons.settings_outlined),
    'yml': _code('yaml', const Color(0xFFCB171E), Icons.settings_outlined),
    'toml': _code('ini', const Color(0xFF9C4121), Icons.settings_outlined),
    'ini': _code('ini', const Color(0xFF6D8086), Icons.settings_outlined),
    'cfg': _code('ini', const Color(0xFF6D8086), Icons.settings_outlined),
    'conf': _code('ini', const Color(0xFF6D8086), Icons.settings_outlined),
    'properties': _code(
      'properties',
      const Color(0xFF6D8086),
      Icons.settings_outlined,
    ),
    'env': _code('properties', const Color(0xFFECD53F), Icons.key_outlined),
    'xml': _code('xml', const Color(0xFF0060AC), Icons.code_rounded),
    'plist': _code('xml', const Color(0xFF0060AC)),
    'gitignore': _code('ini', const Color(0xFFF05032)),
    'diff': _code('diff', const Color(0xFF41B883), Icons.difference_outlined),
    'patch': _code('diff', const Color(0xFF41B883), Icons.difference_outlined),
    'nginx': _code('nginx', const Color(0xFF009639), Icons.settings_outlined),
    'http': _code('http', const Color(0xFF2E7D32)),
    // Prose.
    'md': const FileType(
      FileKind.markdown,
      Icons.article_outlined,
      Color(0xFF6CA6FF),
    ),
    'markdown': const FileType(
      FileKind.markdown,
      Icons.article_outlined,
      Color(0xFF6CA6FF),
    ),
    'mdx': const FileType(
      FileKind.markdown,
      Icons.article_outlined,
      Color(0xFF6CA6FF),
    ),
    'txt': _plain,
    'text': _plain,
    'log': const FileType(
      FileKind.text,
      Icons.receipt_long_outlined,
      Color(0xFF8D99AE),
    ),
    'rst': _plain,
    'adoc': _code('asciidoc', const Color(0xFFE40046), Icons.article_outlined),
    // Pictures.
    'png': const FileType(
      FileKind.image,
      Icons.image_outlined,
      Color(0xFF26A69A),
    ),
    'jpg': const FileType(
      FileKind.image,
      Icons.photo_outlined,
      Color(0xFF26A69A),
    ),
    'jpeg': const FileType(
      FileKind.image,
      Icons.photo_outlined,
      Color(0xFF26A69A),
    ),
    'gif': const FileType(
      FileKind.image,
      Icons.gif_box_outlined,
      Color(0xFFAB47BC),
    ),
    'webp': const FileType(
      FileKind.image,
      Icons.image_outlined,
      Color(0xFF26A69A),
    ),
    'bmp': const FileType(
      FileKind.image,
      Icons.image_outlined,
      Color(0xFF26A69A),
    ),
    'ico': const FileType(
      FileKind.image,
      Icons.image_outlined,
      Color(0xFF26A69A),
    ),
    'svg': const FileType(FileKind.svg, Icons.draw_outlined, Color(0xFFFFB13B)),
    // Media.
    'mp4': const FileType(
      FileKind.video,
      Icons.movie_outlined,
      Color(0xFFEF5350),
    ),
    'm4v': const FileType(
      FileKind.video,
      Icons.movie_outlined,
      Color(0xFFEF5350),
    ),
    'webm': const FileType(
      FileKind.video,
      Icons.movie_outlined,
      Color(0xFFEF5350),
    ),
    'mov': const FileType(
      FileKind.video,
      Icons.movie_outlined,
      Color(0xFFEF5350),
    ),
    'mkv': const FileType(
      FileKind.video,
      Icons.movie_outlined,
      Color(0xFFEF5350),
    ),
    'mp3': const FileType(
      FileKind.audio,
      Icons.music_note_rounded,
      Color(0xFFEC407A),
    ),
    'wav': const FileType(
      FileKind.audio,
      Icons.graphic_eq_rounded,
      Color(0xFFEC407A),
    ),
    'ogg': const FileType(
      FileKind.audio,
      Icons.music_note_rounded,
      Color(0xFFEC407A),
    ),
    'oga': const FileType(
      FileKind.audio,
      Icons.music_note_rounded,
      Color(0xFFEC407A),
    ),
    'm4a': const FileType(
      FileKind.audio,
      Icons.music_note_rounded,
      Color(0xFFEC407A),
    ),
    'aac': const FileType(
      FileKind.audio,
      Icons.music_note_rounded,
      Color(0xFFEC407A),
    ),
    'flac': const FileType(
      FileKind.audio,
      Icons.graphic_eq_rounded,
      Color(0xFFEC407A),
    ),
    'opus': const FileType(
      FileKind.audio,
      Icons.music_note_rounded,
      Color(0xFFEC407A),
    ),
    // Documents.
    'pdf': const FileType(
      FileKind.pdf,
      Icons.picture_as_pdf_outlined,
      Color(0xFFE53935),
    ),
    'docx': const FileType(
      FileKind.document,
      Icons.article_rounded,
      Color(0xFF2B579A),
    ),
    'odt': const FileType(
      FileKind.document,
      Icons.article_rounded,
      Color(0xFF2B579A),
    ),
    'xlsx': const FileType(
      FileKind.spreadsheet,
      Icons.table_chart_outlined,
      Color(0xFF217346),
    ),
    'ods': const FileType(
      FileKind.spreadsheet,
      Icons.table_chart_outlined,
      Color(0xFF217346),
    ),
    'csv': const FileType(
      FileKind.spreadsheet,
      Icons.grid_on_rounded,
      Color(0xFF43A047),
    ),
    'tsv': const FileType(
      FileKind.spreadsheet,
      Icons.grid_on_rounded,
      Color(0xFF43A047),
    ),
    'pptx': const FileType(
      FileKind.presentation,
      Icons.slideshow_outlined,
      Color(0xFFD24726),
    ),
    'odp': const FileType(
      FileKind.presentation,
      Icons.slideshow_outlined,
      Color(0xFFD24726),
    ),
    // Others.
    'zip': const FileType(
      FileKind.archive,
      Icons.folder_zip_outlined,
      Color(0xFFFFA000),
    ),
    'tar': const FileType(
      FileKind.archive,
      Icons.folder_zip_outlined,
      Color(0xFFFFA000),
    ),
    'gz': const FileType(
      FileKind.archive,
      Icons.folder_zip_outlined,
      Color(0xFFFFA000),
    ),
    'tgz': const FileType(
      FileKind.archive,
      Icons.folder_zip_outlined,
      Color(0xFFFFA000),
    ),
    'bz2': const FileType(
      FileKind.archive,
      Icons.folder_zip_outlined,
      Color(0xFFFFA000),
    ),
    'xz': const FileType(
      FileKind.archive,
      Icons.folder_zip_outlined,
      Color(0xFFFFA000),
    ),
    '7z': const FileType(
      FileKind.archive,
      Icons.folder_zip_outlined,
      Color(0xFFFFA000),
    ),
    'ttf': const FileType(
      FileKind.font,
      Icons.font_download_outlined,
      Color(0xFF8E24AA),
    ),
    'otf': const FileType(
      FileKind.font,
      Icons.font_download_outlined,
      Color(0xFF8E24AA),
    ),
    'woff': const FileType(
      FileKind.font,
      Icons.font_download_outlined,
      Color(0xFF8E24AA),
    ),
    'woff2': const FileType(
      FileKind.font,
      Icons.font_download_outlined,
      Color(0xFF8E24AA),
    ),
    'exe': const FileType(
      FileKind.binary,
      Icons.memory_rounded,
      Color(0xFF78909C),
    ),
    'bin': const FileType(
      FileKind.binary,
      Icons.memory_rounded,
      Color(0xFF78909C),
    ),
    'so': const FileType(
      FileKind.binary,
      Icons.memory_rounded,
      Color(0xFF78909C),
    ),
    'wasm': const FileType(
      FileKind.binary,
      Icons.memory_rounded,
      Color(0xFF654FF0),
    ),
    'db': const FileType(
      FileKind.binary,
      Icons.storage_rounded,
      Color(0xFF78909C),
    ),
    'sqlite': const FileType(
      FileKind.binary,
      Icons.storage_rounded,
      Color(0xFF78909C),
    ),
    for (final e in _named.entries)
      if (!const [
        'dockerfile',
        'makefile',
        'license',
        'readme',
      ].contains(e.key))
        e.key: _code(e.value, const Color(0xFF6D8086), Icons.settings_outlined),
    'license': const FileType(
      FileKind.text,
      Icons.gavel_rounded,
      Color(0xFFD4AF37),
    ),
    'readme': const FileType(
      FileKind.markdown,
      Icons.menu_book_outlined,
      Color(0xFF6CA6FF),
    ),
  };
}
