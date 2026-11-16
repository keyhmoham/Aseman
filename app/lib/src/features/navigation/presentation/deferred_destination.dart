import 'package:flutter/material.dart';

import '../../../core/deferred/deferred_loader.dart';

/// Builds [builder] after [loader]'s deferred library has loaded.
///
/// Keeps the shell's destination switch honest: the rail can exist without
/// pulling the store, settings, or workspace libraries into the first chunk.
class DeferredDestination extends StatefulWidget {
  const DeferredDestination({
    super.key,
    required this.loader,
    required this.builder,
  });

  final DeferredLoader loader;
  final WidgetBuilder builder;

  @override
  State<DeferredDestination> createState() => _DeferredDestinationState();
}

class _DeferredDestinationState extends State<DeferredDestination> {
  bool _ready = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _error = null;
        _ready = widget.loader.isLoaded;
      });
    }
    if (widget.loader.isLoaded) return;
    try {
      await widget.loader.ensure();
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.builder(context);
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: _error == null
            ? const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Could not open this area: $_error'),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
      ),
    );
  }
}
