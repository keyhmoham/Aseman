import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../data/services/aseman_service.dart';
import '../../computer/preview_view.dart';
import '../../desk/presentation/desk_controller.dart';
import '../../../core/deferred/deferred_loader.dart';
import '../../tools/elpian_app/elpian_app_view.dart' deferred as elpian_app;

import '../data/gadgets_api.dart';
import 'gadgets_controller.dart';

/// The App UI view library, loaded on first use (once).
final _elpianApp = DeferredLoader(() => elpian_app.loadLibrary());

/// Loads the App UI view library gadgets show.
Future<void> loadGadgetViews() async => _elpianApp.ensure();

/// A gadget's screen: the same App UI host as a desk app (Elpian natively, or
/// web in the sandboxed frame), without window chrome.
class GadgetView extends StatelessWidget {
  const GadgetView({
    super.key,
    required this.dependencies,
    required this.gadget,
    this.spaceId = '',
    this.roomId = '',
  });

  final AppDependencies dependencies;
  final GadgetInfo gadget;
  final String spaceId;
  final String roomId;

  @override
  Widget build(BuildContext context) {
    final service = dependencies.service;
    final space = gadget.appWide ? spaceId : gadget.spaceId;
    if (!gadget.isApp) {
      return Center(
        child: Text('This gadget has no App UI preview.',
            style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    final page = gadget.preview;
    final title = gadget.name;
    // Frameless gadget host: no desk window chrome / web strip — the
    // gadget draws its own shape. Desk apps keep CardWindow frames.
    if (gadget.web || gadget.entry.isEmpty) {
      return LivePreview(
        key: ValueKey('gadget-web-${gadget.id}-$page'),
        service: service,
        spaceId: space,
        title: title,
        page: page,
        embed: 'gadget',
        frameless: true,
      );
    }
    return LivePreview(
      key: ValueKey('gadget-elpian-${gadget.id}-$page-${gadget.entry}'),
      service: service,
      spaceId: space,
      title: title,
      page: page,
      embed: 'gadget',
      frameless: true,
      content: (_) => _DeferredElpianAppView(
        key: ValueKey('gadget-elpian-view-${gadget.id}'),
        service: service,
        page: page,
        entry: gadget.entry,
        spaceId: space,
        roomId: roomId,
        title: title,
      ),
    );
  }
}

/// Loads the Elpian app host library the first time a native gadget opens.
class _DeferredElpianAppView extends StatefulWidget {
  const _DeferredElpianAppView({
    super.key,
    required this.service,
    required this.page,
    required this.entry,
    required this.spaceId,
    required this.roomId,
    required this.title,
  });

  final AsemanService service;
  final String page;
  final String entry;
  final String spaceId;
  final String roomId;
  final String title;

  @override
  State<_DeferredElpianAppView> createState() => _DeferredElpianAppViewState();
}

class _DeferredElpianAppViewState extends State<_DeferredElpianAppView> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ready = _elpianApp.isLoaded;
    if (!_ready) {
      _elpianApp.ensure()?.then((_) {
        if (mounted) setState(() => _ready = true);
      }).ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return elpian_app.ElpianAppView(
      service: widget.service,
      page: widget.page,
      entry: widget.entry,
      spaceId: widget.spaceId,
      roomId: widget.roomId,
      title: widget.title,
    );
  }
}

/// Opens a gadget as a floating gadget on its surface, or as a page when
/// placement is [GadgetPlacement.page].
Future<void> openGadget(BuildContext context, AppDependencies dependencies,
    GadgetInfo gadget,
    {String spaceId = '', String roomId = '', DeskController? desk}) async {
  final gadgets = GadgetsScope.maybeOf(context);

  if (gadget.appWide && gadgets != null) {
    gadgets.open(gadget.id);
    return;
  }

  if (gadget.placement != GadgetPlacement.page && gadgets != null) {
    gadgets.open(gadget.id);
    return;
  }

  return openGadgetPage(context, dependencies, gadget,
      spaceId: spaceId, roomId: roomId);
}

/// Opens [gadget] as a page of its own, whatever its placement.
Future<void> openGadgetPage(BuildContext context, AppDependencies dependencies,
    GadgetInfo gadget,
    {String spaceId = '', String roomId = ''}) {
  final view = GadgetView(
      dependencies: dependencies,
      gadget: gadget,
      spaceId: spaceId,
      roomId: roomId);
  return Navigator.of(context).push<void>(MaterialPageRoute(
    builder: (context) => Scaffold(
      appBar: AppBar(title: Text(gadget.name)),
      body: SafeArea(child: view),
    ),
  ));
}
