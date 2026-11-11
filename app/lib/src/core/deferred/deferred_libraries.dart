import '../../app.dart' show loadPlatformHome;
import '../../features/calls/call_overlay.dart' show loadIncomingCallScreen;
import '../../features/gadgets/presentation/gadgets_panel.dart'
    show loadGadgetViews;
import '../../features/home/presentation/desk_surface_entry.dart'
    show loadDeskSurfaces;
import '../../features/home/presentation/workspace_entry.dart'
    show loadWorkspace;
import '../../features/messenger/presentation/chat_page.dart'
    show loadChatScreens;
import '../../features/search_feed/presentation/search_feed_screen.dart'
    show loadFeedAdminConsole;
import '../../shared/widgets/profile_menu.dart' show loadProfileScreens;
import '../../shared/widgets/theme_slot_host.dart' show loadThemeSurfaces;

/// Loads every library the app defers (the workspace desk and its surfaces,
/// the profile menu's and the feed's admin screens, a direct chat's calls
/// and desk, theme surfaces, gadget views, a platform's home), each
/// through its own [DeferredLoader]: to warm them up ahead of use, or, in
/// tests, to load them once before any test runs (a deferred load awaited
/// inside one test's fake-async zone would not complete in the next).
Future<void> loadDeferredLibraries() async {
  await Future.wait([
    loadWorkspace(),
    loadDeskSurfaces(),
    loadProfileScreens(),
    loadChatScreens(),
    loadIncomingCallScreen(),
    loadFeedAdminConsole(),
    loadThemeSurfaces(),
    loadGadgetViews(),
    loadPlatformHome(),
  ]);
}
