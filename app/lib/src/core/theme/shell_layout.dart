import 'package:flutter/foundation.dart';

/// Stable feature slot ids themes may place. Unknown ids are ignored.
abstract final class FeatureSlots {
  static const homeChats = 'home.chats';
  static const homeExplore = 'home.explore';
  static const homeYou = 'home.you';
  static const homeComposer = 'home.composer';
  static const homeWideLeft = 'home.wide.left';
  static const homeWideCenter = 'home.wide.center';
  static const homeWideRight = 'home.wide.right';

  static const workspaceRail = 'workspace.rail';
  static const workspaceHeader = 'workspace.header';
  static const workspaceMain = 'workspace.main';
  static const workspacePanels = 'workspace.panels';

  static const storeLibrary = 'store.library';
  static const storeDiscover = 'store.discover';
  static const storeThemes = 'store.themes';

  static const settingsAppearance = 'settings.appearance';
  static const settingsAccount = 'settings.account';
  static const settingsNotifications = 'settings.notifications';
  static const settingsAdvanced = 'settings.advanced';

  static const profileStore = 'profile.store';
  static const profileWallet = 'profile.wallet';
  static const profileSettings = 'profile.settings';
  static const profileAdmin = 'profile.admin';

  static const known = <String>{
    homeChats,
    homeExplore,
    homeYou,
    homeComposer,
    homeWideLeft,
    homeWideCenter,
    homeWideRight,
    workspaceRail,
    workspaceHeader,
    workspaceMain,
    workspacePanels,
    storeLibrary,
    storeDiscover,
    storeThemes,
    settingsAppearance,
    settingsAccount,
    settingsNotifications,
    settingsAdvanced,
    profileStore,
    profileWallet,
    profileSettings,
    profileAdmin,
  };

  static bool isKnown(String id) => known.contains(id);

  /// Built-in slots or theme islands (`island.*`) shell lists may place.
  static bool isPlaceable(String id) =>
      isKnown(id) || id.startsWith('island.');
}

/// Navigation chrome style for a shell surface.
enum ShellNavStyle {
  pill,
  rail,
  drawer,
  tabs,
  bar;

  static ShellNavStyle parse(Object? raw, [ShellNavStyle fallback = pill]) {
    final s = '$raw'.toLowerCase();
    for (final v in ShellNavStyle.values) {
      if (v.name == s) return v;
    }
    return fallback;
  }
}

@immutable
class ShellLayoutSpec {
  const ShellLayoutSpec({
    this.home = const HomeShellSpec(),
    this.workspace = const WorkspaceShellSpec(),
    this.store = const StoreShellSpec(),
    this.settings = const SettingsShellSpec(),
    this.profile = const ProfileShellSpec(),
  });

  final HomeShellSpec home;
  final WorkspaceShellSpec workspace;
  final StoreShellSpec store;
  final SettingsShellSpec settings;
  final ProfileShellSpec profile;

  Map<String, dynamic> toJson() => {
        'home': home.toJson(),
        'workspace': workspace.toJson(),
        'store': store.toJson(),
        'settings': settings.toJson(),
        'profile': profile.toJson(),
      };

  factory ShellLayoutSpec.fromJson(Map<String, dynamic> json) =>
      ShellLayoutSpec(
        home: HomeShellSpec.fromJson(_map(json['home'])),
        workspace: WorkspaceShellSpec.fromJson(_map(json['workspace'])),
        store: StoreShellSpec.fromJson(_map(json['store'])),
        settings: SettingsShellSpec.fromJson(_map(json['settings'])),
        profile: ProfileShellSpec.fromJson(_map(json['profile'])),
      );

  static Map<String, dynamic> _map(Object? raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : const {};
}

@immutable
class HomeShellSpec {
  const HomeShellSpec({
    this.phoneNav = ShellNavStyle.pill,
    this.phoneTabs = const [
      FeatureSlots.homeChats,
      FeatureSlots.homeExplore,
      FeatureSlots.homeYou,
    ],
    this.widePanes = const [
      FeatureSlots.homeWideLeft,
      FeatureSlots.homeWideCenter,
      FeatureSlots.homeWideRight,
    ],
    this.composerOn = const [FeatureSlots.homeExplore],
  });

  final ShellNavStyle phoneNav;
  final List<String> phoneTabs;
  final List<String> widePanes;
  /// Phone tabs where the explore composer is visible.
  final List<String> composerOn;

  List<String> get resolvedPhoneTabs =>
      phoneTabs.where(FeatureSlots.isPlaceable).toList(growable: false);

  List<String> get resolvedWidePanes =>
      widePanes.where(FeatureSlots.isPlaceable).toList(growable: false);

  Map<String, dynamic> toJson() => {
        'phone_nav': phoneNav.name,
        'phone_tabs': phoneTabs,
        'wide_panes': widePanes,
        'composer_on': composerOn,
      };

  factory HomeShellSpec.fromJson(Map<String, dynamic> json) => HomeShellSpec(
        phoneNav: ShellNavStyle.parse(json['phone_nav'], ShellNavStyle.pill),
        phoneTabs: _stringList(
          json['phone_tabs'],
          const [
            FeatureSlots.homeChats,
            FeatureSlots.homeExplore,
            FeatureSlots.homeYou,
          ],
        ),
        widePanes: _stringList(
          json['wide_panes'],
          const [
            FeatureSlots.homeWideLeft,
            FeatureSlots.homeWideCenter,
            FeatureSlots.homeWideRight,
          ],
        ),
        composerOn: _stringList(
          json['composer_on'],
          const [FeatureSlots.homeExplore],
        ),
      );
}

@immutable
class WorkspaceShellSpec {
  const WorkspaceShellSpec({
    this.nav = ShellNavStyle.rail,
    this.regions = const [
      FeatureSlots.workspaceRail,
      FeatureSlots.workspaceHeader,
      FeatureSlots.workspaceMain,
      FeatureSlots.workspacePanels,
    ],
  });

  final ShellNavStyle nav;
  final List<String> regions;

  List<String> get resolvedRegions =>
      regions.where(FeatureSlots.isPlaceable).toList(growable: false);

  Map<String, dynamic> toJson() => {
        'nav': nav.name,
        'regions': regions,
      };

  factory WorkspaceShellSpec.fromJson(Map<String, dynamic> json) =>
      WorkspaceShellSpec(
        nav: ShellNavStyle.parse(json['nav'], ShellNavStyle.rail),
        regions: _stringList(
          json['regions'],
          const [
            FeatureSlots.workspaceRail,
            FeatureSlots.workspaceHeader,
            FeatureSlots.workspaceMain,
            FeatureSlots.workspacePanels,
          ],
        ),
      );
}

@immutable
class StoreShellSpec {
  const StoreShellSpec({
    this.tabs = const [
      FeatureSlots.storeLibrary,
      FeatureSlots.storeDiscover,
      FeatureSlots.storeThemes,
    ],
  });

  final List<String> tabs;

  List<String> get resolvedTabs {
    final known = tabs.where(FeatureSlots.isPlaceable).toList();
    if (known.isEmpty) {
      return const [
        FeatureSlots.storeLibrary,
        FeatureSlots.storeDiscover,
        FeatureSlots.storeThemes,
      ];
    }
    return known;
  }

  Map<String, dynamic> toJson() => {'tabs': tabs};

  factory StoreShellSpec.fromJson(Map<String, dynamic> json) => StoreShellSpec(
        tabs: _stringList(
          json['tabs'],
          const [
            FeatureSlots.storeLibrary,
            FeatureSlots.storeDiscover,
            FeatureSlots.storeThemes,
          ],
        ),
      );
}

@immutable
class SettingsShellSpec {
  const SettingsShellSpec({
    this.sections = const [
      FeatureSlots.settingsAppearance,
      FeatureSlots.settingsAccount,
      FeatureSlots.settingsNotifications,
      FeatureSlots.settingsAdvanced,
    ],
  });

  final List<String> sections;

  List<String> get resolvedSections {
    final known = sections.where(FeatureSlots.isPlaceable).toList();
    if (known.isEmpty) {
      return const [
        FeatureSlots.settingsAppearance,
        FeatureSlots.settingsAccount,
        FeatureSlots.settingsNotifications,
        FeatureSlots.settingsAdvanced,
      ];
    }
    return known;
  }

  Map<String, dynamic> toJson() => {'sections': sections};

  factory SettingsShellSpec.fromJson(Map<String, dynamic> json) =>
      SettingsShellSpec(
        sections: _stringList(
          json['sections'],
          const [
            FeatureSlots.settingsAppearance,
            FeatureSlots.settingsAccount,
            FeatureSlots.settingsNotifications,
            FeatureSlots.settingsAdvanced,
          ],
        ),
      );
}

@immutable
class ProfileShellSpec {
  const ProfileShellSpec({
    this.entries = const [
      FeatureSlots.profileStore,
      FeatureSlots.profileWallet,
      FeatureSlots.profileSettings,
      FeatureSlots.profileAdmin,
    ],
  });

  final List<String> entries;

  List<String> get resolvedEntries {
    final known = entries.where(FeatureSlots.isPlaceable).toList();
    if (known.isEmpty) {
      return const [
        FeatureSlots.profileStore,
        FeatureSlots.profileWallet,
        FeatureSlots.profileSettings,
        FeatureSlots.profileAdmin,
      ];
    }
    return known;
  }

  Map<String, dynamic> toJson() => {'entries': entries};

  factory ProfileShellSpec.fromJson(Map<String, dynamic> json) =>
      ProfileShellSpec(
        entries: _stringList(
          json['entries'],
          const [
            FeatureSlots.profileStore,
            FeatureSlots.profileWallet,
            FeatureSlots.profileSettings,
            FeatureSlots.profileAdmin,
          ],
        ),
      );
}

List<String> _stringList(Object? raw, List<String> fallback) {
  if (raw is! List || raw.isEmpty) return fallback;
  return [for (final e in raw) '$e'];
}
