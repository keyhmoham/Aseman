import 'package:flutter/material.dart';

import '../../domain/desk_board.dart';
import 'board_palette.dart';

/// What the pointer does on the whiteboard.
enum BoardTool {
  select('Select', Icons.near_me_outlined, 'V'),
  hand('Pan', Icons.pan_tool_outlined, 'H'),
  note('Note card', Icons.sticky_note_2_outlined, 'N'),
  shape('Shape', Icons.category_outlined, 'R'),
  text('Text', Icons.title_rounded, 'T'),
  arrow('Arrow', Icons.north_east_rounded, 'A'),
  pen('Pen', Icons.draw_outlined, 'P');

  const BoardTool(this.label, this.icon, this.key);
  final String label;
  final IconData icon;
  final String key;
}

IconData shapeIcon(String shape) => switch (shape) {
  'round' => Icons.rounded_corner_rounded,
  'ellipse' => Icons.circle_outlined,
  'diamond' => Icons.diamond_outlined,
  'triangle' => Icons.change_history_rounded,
  'hexagon' => Icons.hexagon_outlined,
  _ => Icons.crop_square_rounded,
};

/// A coloured dot of the palette.
class BoardSwatch extends StatelessWidget {
  const BoardSwatch({
    super.key,
    required this.name,
    this.selected = false,
    this.size = 20,
  });

  final String name;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = BoardInk.of(scheme, name);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ink.strong,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2.5 : 1,
        ),
      ),
    );
  }
}

/// The popup of palette colours.
class BoardColorMenu extends StatelessWidget {
  const BoardColorMenu({
    super.key,
    required this.value,
    required this.onSelected,
    this.tooltip = 'Color',
  });

  final String value;
  final ValueChanged<String> onSelected;
  final String tooltip;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: tooltip,
    onSelected: onSelected,
    padding: EdgeInsets.zero,
    itemBuilder: (_) => [
      PopupMenuItem<String>(
        enabled: false,
        padding: const EdgeInsets.all(10),
        child: SizedBox(
          width: 196,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in DeskBoardVocabulary.colors)
                InkResponse(
                  key: ValueKey('board-color-$c'),
                  radius: 18,
                  onTap: () => Navigator.of(context).pop(c),
                  child: BoardSwatch(name: c, selected: c == value, size: 26),
                ),
            ],
          ),
        ),
      ),
    ],
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: BoardSwatch(name: value, size: 22),
    ),
  );
}

/// A small icon button for the board's bars.
class BoardBarButton extends StatelessWidget {
  const BoardBarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      isSelected: selected,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      style: IconButton.styleFrom(
        foregroundColor: danger ? scheme.error : scheme.onSurfaceVariant,
        backgroundColor: selected ? scheme.primaryContainer : null,
        minimumSize: const Size(36, 36),
      ),
      icon: Icon(
        icon,
        color: selected ? scheme.onPrimaryContainer : null,
      ),
    );
  }
}

/// The bar of tools along the bottom of the whiteboard.
class BoardToolbar extends StatelessWidget {
  const BoardToolbar({
    super.key,
    required this.tool,
    required this.onTool,
    required this.shape,
    required this.onShape,
    required this.color,
    required this.onColor,
    required this.apps,
  });

  final BoardTool tool;
  final ValueChanged<BoardTool> onTool;
  final String shape;
  final ValueChanged<String> onShape;
  final String color;
  final ValueChanged<String> onColor;

  /// The menu of the desk's windows (the whiteboard's mini-apps).
  final Widget apps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      color: scheme.surfaceContainerHigh,
      shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in BoardTool.values)
              if (t == BoardTool.shape)
                PopupMenuButton<String>(
                  key: const ValueKey('board-tool-shape'),
                  tooltip: 'Shape (${t.key})',
                  onSelected: (s) {
                    onShape(s);
                    onTool(BoardTool.shape);
                  },
                  itemBuilder: (_) => [
                    for (final s in DeskBoardVocabulary.shapes)
                      PopupMenuItem(
                        value: s,
                        child: Row(
                          children: [
                            Icon(shapeIcon(s), size: 20),
                            const SizedBox(width: 12),
                            Text(s[0].toUpperCase() + s.substring(1)),
                          ],
                        ),
                      ),
                  ],
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: tool == BoardTool.shape
                          ? scheme.primaryContainer
                          : null,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      shapeIcon(shape),
                      size: 20,
                      color: tool == BoardTool.shape
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                BoardBarButton(
                  key: ValueKey('board-tool-${t.name}'),
                  icon: t.icon,
                  tooltip: '${t.label} (${t.key})',
                  selected: tool == t,
                  onPressed: () => onTool(t),
                ),
            const SizedBox(width: 2),
            SizedBox(
              height: 22,
              child: VerticalDivider(color: scheme.outlineVariant, width: 10),
            ),
            BoardColorMenu(
              value: color,
              onSelected: onColor,
              tooltip: 'Color for new things',
            ),
            apps,
          ],
        ),
      ),
    );
  }
}

/// The bar over the selected things: color, look, and what to do with them.
class BoardContextBar extends StatelessWidget {
  const BoardContextBar({
    super.key,
    required this.items,
    required this.onChange,
    required this.onDelete,
    required this.onDuplicate,
    required this.onFront,
    required this.onLabel,
  });

  final List<DeskItem> items;

  /// Replaces each selected item with `f(item)`.
  final void Function(DeskItem Function(DeskItem item) f) onChange;
  final VoidCallback onDelete;
  final VoidCallback onDuplicate;
  final VoidCallback onFront;

  /// Edits a single arrow's label.
  final VoidCallback onLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final one = items.length == 1 ? items.first : null;
    final color = items.map((i) => i.color).toSet().length == 1
        ? items.first.color
        : '';
    final withText = items.any((i) => i.isBox);
    Widget divider() => SizedBox(
      height: 22,
      child: VerticalDivider(color: scheme.outlineVariant, width: 10),
    );
    return Material(
      elevation: 3,
      color: scheme.surfaceContainerHigh,
      shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BoardColorMenu(
              value: color.isEmpty ? 'gray' : color,
              onSelected: (c) => onChange((i) => i.copyWith(color: c)),
            ),
            if (one != null && one.isShape) ...[
              PopupMenuButton<String>(
                tooltip: 'Shape',
                onSelected: (s) => onChange((i) => i.copyWith(shape: s)),
                itemBuilder: (_) => [
                  for (final s in DeskBoardVocabulary.shapes)
                    PopupMenuItem(
                      value: s,
                      child: Row(
                        children: [
                          Icon(shapeIcon(s), size: 20),
                          const SizedBox(width: 12),
                          Text(s),
                        ],
                      ),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(shapeIcon(one.shape), size: 20),
                ),
              ),
              BoardBarButton(
                icon: one.fill == 'solid'
                    ? Icons.format_color_fill_rounded
                    : one.fill == 'none'
                    ? Icons.border_style_rounded
                    : Icons.opacity_rounded,
                tooltip: 'Fill: ${one.fill.isEmpty ? 'soft' : one.fill}',
                onPressed: () => onChange(
                  (i) => i.copyWith(
                    fill: switch (i.fill) {
                      'solid' => 'none',
                      'none' => 'soft',
                      _ => 'solid',
                    },
                  ),
                ),
              ),
            ],
            if (one != null && one.isArrow) ...[
              BoardBarButton(
                icon: switch (one.path) {
                  'curved' => Icons.gesture_rounded,
                  'elbow' => Icons.turn_right_rounded,
                  _ => Icons.horizontal_rule_rounded,
                },
                tooltip: 'Line: ${one.path.isEmpty ? 'straight' : one.path}',
                onPressed: () => onChange(
                  (i) => i.copyWith(
                    path: switch (i.path) {
                      'straight' || '' => 'curved',
                      'curved' => 'elbow',
                      _ => 'straight',
                    },
                  ),
                ),
              ),
              BoardBarButton(
                icon: switch (one.dash) {
                  'dashed' => Icons.more_horiz_rounded,
                  'dotted' => Icons.drag_indicator_rounded,
                  _ => Icons.remove_rounded,
                },
                tooltip: 'Style: ${one.dash.isEmpty ? 'solid' : one.dash}',
                onPressed: () => onChange(
                  (i) => i.copyWith(
                    dash: switch (i.dash) {
                      'solid' || '' => 'dashed',
                      'dashed' => 'dotted',
                      _ => 'solid',
                    },
                  ),
                ),
              ),
              BoardBarButton(
                icon: one.head == 'none'
                    ? Icons.remove_rounded
                    : Icons.arrow_right_alt_rounded,
                tooltip: one.head == 'none' ? 'Add arrowhead' : 'No arrowhead',
                onPressed: () => onChange(
                  (i) => i.copyWith(head: i.head == 'none' ? 'arrow' : 'none'),
                ),
              ),
              BoardBarButton(
                icon: Icons.label_outline_rounded,
                tooltip: 'Label',
                onPressed: onLabel,
              ),
            ],
            if (withText) ...[
              BoardBarButton(
                icon: Icons.text_decrease_rounded,
                tooltip: 'Smaller text',
                onPressed: () => onChange(
                  (i) => i.isBox
                      ? i.copyWith(
                          fontSize: ((i.fontSize > 0 ? i.fontSize : (i.isText ? 18 : 15)) - 2)
                              .clamp(8, 96)
                              .toDouble(),
                        )
                      : i,
                ),
              ),
              BoardBarButton(
                icon: Icons.text_increase_rounded,
                tooltip: 'Larger text',
                onPressed: () => onChange(
                  (i) => i.isBox
                      ? i.copyWith(
                          fontSize: ((i.fontSize > 0 ? i.fontSize : (i.isText ? 18 : 15)) + 2)
                              .clamp(8, 96)
                              .toDouble(),
                        )
                      : i,
                ),
              ),
            ],
            divider(),
            BoardBarButton(
              key: const ValueKey('board-front'),
              icon: Icons.flip_to_front_rounded,
              tooltip: 'Bring to front',
              onPressed: onFront,
            ),
            BoardBarButton(
              key: const ValueKey('board-duplicate'),
              icon: Icons.content_copy_rounded,
              tooltip: 'Duplicate (Ctrl+D)',
              onPressed: onDuplicate,
            ),
            BoardBarButton(
              key: const ValueKey('board-delete'),
              icon: Icons.delete_outline_rounded,
              tooltip: 'Delete',
              danger: true,
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
