import '../../core/theme/theme_pack.dart';

class CreatedTheme {
  const CreatedTheme({
    required this.themeId,
    this.listingId = '',
    this.status = '',
  });

  final String themeId;
  final String listingId;
  final String status;
}

class ActiveThemePack {
  const ActiveThemePack({
    required this.themeId,
    required this.packJson,
    this.listingId = '',
  });

  final String themeId;
  final String listingId;
  final String packJson;

  ThemePack get pack => ThemePack.decode(packJson);
}
