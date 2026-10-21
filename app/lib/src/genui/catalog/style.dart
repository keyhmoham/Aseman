/// Aseman's design language for generated UI: the app's Material 3
/// Expressive theme (pill buttons, 28/20/16 radii, outlined surface cards,
/// heavy headings, rounded icons) and the data palette of the UI kit.
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_shape.dart';
import '../../core/theme/app_surfaces.dart';
import '../../elpian/widgets/elpian_icon.dart';
import '../../features/tools/ui_kit/palette.dart';
import '../../features/tools/ui_kit/values.dart';

export '../../core/theme/app_shape.dart';
export '../../core/theme/app_surfaces.dart';

/// Gap between the children of Columns, Rows, Wraps and Grids.
const double genUiGap = 12;

/// Typography of `Text` variants.
TextStyle genUiTextStyle(BuildContext context, String? variant) {
  final base = DefaultTextStyle.of(context).style;
  final scheme = Theme.of(context).colorScheme;
  final inContent = ContentColor.maybeOf(context) != null;
  return switch (variant) {
    'h1' => base.copyWith(
        fontSize: 34, fontWeight: FontWeight.w800, height: 1.15, letterSpacing: -0.5),
    'h2' => base.copyWith(
        fontSize: 28, fontWeight: FontWeight.w800, height: 1.2, letterSpacing: -0.3),
    'h3' => base.copyWith(fontSize: 24, fontWeight: FontWeight.w800, height: 1.25),
    'h4' => base.copyWith(fontSize: 20, fontWeight: FontWeight.w800, height: 1.3),
    'h5' => base.copyWith(fontSize: 16, fontWeight: FontWeight.w700, height: 1.35),
    'caption' => base.copyWith(
        fontSize: 12.5,
        height: 1.35,
        color: inContent ? null : scheme.onSurfaceVariant),
    _ => base.copyWith(fontSize: 15, height: 1.45),
  };
}

/// Marks content drawn on a colored face (a button, a filled badge): text
/// and icons inside take the face's content color instead of their own.
class ContentColor extends InheritedWidget {
  const ContentColor({super.key, required this.color, required super.child});

  final Color? color;

  static ContentColor? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ContentColor>();

  @override
  bool updateShouldNotify(ContentColor old) => old.color != color;
}

/// The A2UI icon name → Material icon (`accountCircle`, `trendingUp`,
/// `arrow_upward`), rounded where the app uses rounded icons.
IconData? genUiIcon(Object? name) {
  if (name is! String || name.isEmpty) return null;
  return _a2uiIcons[name] ?? iconFor(name) ?? ElpianIcon.iconData(_snake(name));
}

String _snake(String name) => name
    .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
    .toLowerCase();

const Map<String, IconData> _a2uiIcons = {
  'accountCircle': Icons.account_circle_rounded,
  'add': Icons.add_rounded,
  'arrowBack': Icons.arrow_back_rounded,
  'arrowForward': Icons.arrow_forward_rounded,
  'attachFile': Icons.attach_file_rounded,
  'calendarToday': Icons.calendar_today_rounded,
  'call': Icons.call_rounded,
  'camera': Icons.camera_alt_rounded,
  'check': Icons.check_rounded,
  'close': Icons.close_rounded,
  'delete': Icons.delete_outline_rounded,
  'download': Icons.download_rounded,
  'edit': Icons.edit_rounded,
  'event': Icons.event_rounded,
  'error': Icons.error_outline_rounded,
  'fastForward': Icons.fast_forward_rounded,
  'favorite': Icons.favorite_rounded,
  'favoriteOff': Icons.favorite_border_rounded,
  'folder': Icons.folder_rounded,
  'help': Icons.help_outline_rounded,
  'home': Icons.home_rounded,
  'info': Icons.info_outline_rounded,
  'locationOn': Icons.location_on_rounded,
  'lock': Icons.lock_rounded,
  'lockOpen': Icons.lock_open_rounded,
  'mail': Icons.mail_outline_rounded,
  'menu': Icons.menu_rounded,
  'moreVert': Icons.more_vert_rounded,
  'moreHoriz': Icons.more_horiz_rounded,
  'notificationsOff': Icons.notifications_off_rounded,
  'notifications': Icons.notifications_rounded,
  'pause': Icons.pause_rounded,
  'payment': Icons.payment_rounded,
  'person': Icons.person_rounded,
  'phone': Icons.phone_rounded,
  'photo': Icons.photo_rounded,
  'play': Icons.play_arrow_rounded,
  'print': Icons.print_rounded,
  'refresh': Icons.refresh_rounded,
  'rewind': Icons.fast_rewind_rounded,
  'search': Icons.search_rounded,
  'send': Icons.send_rounded,
  'settings': Icons.settings_rounded,
  'share': Icons.share_rounded,
  'shoppingCart': Icons.shopping_cart_rounded,
  'skipNext': Icons.skip_next_rounded,
  'skipPrevious': Icons.skip_previous_rounded,
  'star': Icons.star_rounded,
  'starHalf': Icons.star_half_rounded,
  'starOff': Icons.star_border_rounded,
  'stop': Icons.stop_rounded,
  'upload': Icons.upload_rounded,
  'visibility': Icons.visibility_rounded,
  'visibilityOff': Icons.visibility_off_rounded,
  'volumeDown': Icons.volume_down_rounded,
  'volumeMute': Icons.volume_mute_rounded,
  'volumeOff': Icons.volume_off_rounded,
  'volumeUp': Icons.volume_up_rounded,
  'warning': Icons.warning_amber_rounded,
};

/// Every A2UI basic-catalog icon name (the catalog's `IconName` enum).
Iterable<String> get basicIconNames => _a2uiIcons.keys;

/// A color spec as a color: `#hex`, a categorical hue or slot (`blue`,
/// `series-2`), a status (`good`, `warning`, `serious`, `critical`), or a
/// surface token (`surface`, `surfaceVariant`, `surfaceHigh`, `primary`,
/// `primaryContainer`, `outline`).
Color? genUiColor(BuildContext context, Object? spec) {
  if (spec is! String || spec.isEmpty) return null;
  final scheme = Theme.of(context).colorScheme;
  final token = switch (spec) {
    'surface' => scheme.surface,
    'surfaceVariant' => scheme.surfaceContainerHighest,
    'surfaceHigh' => scheme.surfaceContainerHigh,
    'surfaceLow' => scheme.surfaceContainerLow,
    'primary' => scheme.primary,
    'onPrimary' => scheme.onPrimary,
    'primaryContainer' => scheme.primaryContainer,
    'secondary' => scheme.secondary,
    'tertiary' => scheme.tertiary,
    'outline' => scheme.outlineVariant,
    'error' => scheme.error,
    'transparent' => Colors.transparent,
    _ => null,
  };
  return token ?? VizPalette.of(context).parse(spec);
}

/// The decoration of an in-page card (as the app's [Card]s).
BoxDecoration genUiCard(BuildContext context,
        {double radius = AppShape.inner, Color? color}) =>
    AppSurfaces.cardDecoration(context, radius: radius)
        .copyWith(color: color);

/// An error box drawn in place of a component that cannot render.
class GenUiProblem extends StatelessWidget {
  const GenUiProblem(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(AppShape.control)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline_rounded, size: 16, color: scheme.error),
        const SizedBox(width: 6),
        Flexible(
            child: Text(message,
                style: TextStyle(fontSize: 12.5, color: scheme.error))),
      ]),
    );
  }
}
