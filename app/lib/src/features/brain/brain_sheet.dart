import 'dart:async';
import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_surfaces.dart';
import '../../core/theme/theme_chrome.dart';
import '../../core/theme/theme_roles.dart';
import '../../shared/widgets/glass_surface.dart';
import '../messenger/presentation/chat_page.dart';
import 'brain_avatar.dart';
import 'brain_voice.dart';

/// Opens the personal Aseman chat (self chat) using the messenger panel flow.
Future<void> openSavedMessages(
  BuildContext context,
  AppDependencies dependencies,
) async {
  try {
    final chat = await dependencies.service.openSaved();
    if (!context.mounted) return;
    await showChat(context, dependencies, chat);
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open Aseman: $e')),
    );
  }
}

/// Opens the personal Aseman chat shell (Desk | Chat). Kept for callers that
/// still name "brain sheet"; the overlay note/voice sheet is no longer the
/// primary entry.
Future<void> showBrainSheet(
  BuildContext context,
  AppDependencies dependencies,
) =>
    openSavedMessages(context, dependencies);

/// Modern glass sheet for notes + live voice with Aseman.
class BrainSheet extends StatefulWidget {
  const BrainSheet({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<BrainSheet> createState() => _BrainSheetState();
}

class _BrainSheetState extends State<BrainSheet> {
  late final BrainVoiceClient voice =
      BrainVoiceClient(widget.dependencies.service);
  final noteController = TextEditingController();
  final noteFocus = FocusNode();

  BrainAvatarPrefs avatarPrefs = const BrainAvatarPrefs();
  bool sendingNote = false;

  @override
  void initState() {
    super.initState();
    voice.addListener(_onVoice);
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final userId =
        widget.dependencies.sessionController.session?.accountId ?? '';
    final prefs = await BrainAvatarPrefs.load(userId: userId);
    if (!mounted) return;
    setState(() => avatarPrefs = prefs);
    await voice.loadConfig();
  }

  void _onVoice() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    voice.removeListener(_onVoice);
    voice.dispose();
    noteController.dispose();
    noteFocus.dispose();
    super.dispose();
  }

  Color get _accent {
    final settings = AppSettingsScope.maybeOf(context);
    return avatarPrefs.accentOr(
      settings?.accent ?? Theme.of(context).colorScheme.primary,
    );
  }

  String get _statusLabel => switch (voice.state.status) {
        BrainVoiceStatus.listening => 'Listening',
        BrainVoiceStatus.thinking => 'Thinking',
        BrainVoiceStatus.speaking => 'Speaking',
        BrainVoiceStatus.idle => 'Idle',
      };

  Future<void> _sendNote() async {
    final body = noteController.text.trim();
    if (body.isEmpty || sendingNote) return;
    setState(() => sendingNote = true);
    final me = widget.dependencies.service.session?.accountId ?? '';
    try {
      await widget.dependencies.service.invokeAction(
        'users',
        'dm_send',
        body: {'to': me, 'body': body},
      );
      if (!mounted) return;
      noteController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to your notes')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save note: $e')),
      );
    } finally {
      if (mounted) setState(() => sendingNote = false);
    }
  }

  Future<void> _toggleCall() async {
    if (voice.state.status == BrainVoiceStatus.idle) {
      await voice.startCall();
    } else {
      await voice.stop();
    }
  }

  Future<void> _openAvatarSettings() async {
    final userId =
        widget.dependencies.sessionController.session?.accountId ?? '';
    final next = await showBrainAvatarSettings(
      context,
      prefs: avatarPrefs.copyWith(userId: userId),
      appAccent: AppSettingsScope.maybeOf(context)?.accent ??
          Theme.of(context).colorScheme.primary,
    );
    if (next != null && mounted) setState(() => avatarPrefs = next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _accent;
    final st = voice.state;
    final inCall = st.status != BrainVoiceStatus.idle;
    final setupNeeded = st.configLoaded && !st.voiceConfigured;

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Spacer(),
                  IconButton(
                    tooltip: 'Customize avatar',
                    onPressed: _openAvatarSettings,
                    icon: const Icon(Icons.settings_outlined, size: 20),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              Center(
                child: BrainAvatar(
                  prefs: avatarPrefs,
                  accent: accent,
                  size: 108,
                  listening: st.status == BrainVoiceStatus.listening,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Aseman',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.3,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'Your personal Aseman',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 18),
              _NoteField(
                controller: noteController,
                focusNode: noteFocus,
                sending: sendingNote,
                onSend: _sendNote,
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      openSavedMessages(context, widget.dependencies),
                  icon: const Icon(Icons.bookmark_outline_rounded, size: 18),
                  label: const Text('Open Aseman'),
                ),
              ),
              if (setupNeeded) ...[
                const SizedBox(height: 8),
                _SetupBanner(message: st.error.isNotEmpty
                    ? st.error
                    : 'Voice is not set up on this node. Ask an admin to '
                        'enable speech and transcription under Admin → AI → Voice.'),
              ] else if (st.error.isNotEmpty && !inCall) ...[
                const SizedBox(height: 8),
                Text(
                  st.error,
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
              ],
              const SizedBox(height: 12),
              _StatusLine(label: _statusLabel, status: st.status, accent: accent),
              const SizedBox(height: 12),
              Expanded(
                child: _Transcript(
                  heard: st.heard,
                  reply: st.reply,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (inCall)
                    IconButton.filledTonal(
                      tooltip: 'Stop / interrupt',
                      onPressed: () => voice.interrupt(),
                      icon: const Icon(Icons.stop_rounded),
                    ),
                  if (inCall) const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: inCall ? scheme.error : accent,
                        foregroundColor: inCall
                            ? scheme.onError
                            : (accent.computeLuminance() > .55
                                ? Colors.black
                                : Colors.white),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      onPressed: setupNeeded ? null : _toggleCall,
                      icon: Icon(
                        inCall ? Icons.call_end_rounded : Icons.graphic_eq_rounded,
                        size: 22,
                      ),
                      label: Text(inCall ? 'End' : 'Talk'),
                    ),
                  ),
                  if (st.status == BrainVoiceStatus.listening) ...[
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Send now',
                      onPressed: voice.finishUtterance,
                      icon: const Icon(Icons.done_rounded),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoteField extends StatelessWidget {
  const _NoteField({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassSurface(
      alpha: AppSurfaces.cardAlphaOf(context),
      blur: AppSurfaces.blurSigmaOf(context),
      borderRadius: ThemeChrome.inputShell(context).radius,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: 'Quick note to yourself…',
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Save note',
              onPressed: sending ? null : onSend,
              icon: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ThemeRoles.wellFill(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.tune_rounded, size: 18, color: ThemeRoles.wellInk(context)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: ThemeRoles.wellInk(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.label,
    required this.status,
    required this.accent,
  });

  final String label;
  final BrainVoiceStatus status;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = status != BrainVoiceStatus.idle;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? accent : scheme.outlineVariant,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: active ? scheme.onSurface : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({required this.heard, required this.reply});

  final String heard;
  final String reply;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (heard.isEmpty && reply.isEmpty) {
      return Center(
        child: Text(
          'Say something after you tap Talk,\nor leave a quick note above.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
        ),
      );
    }
    return ListView(
      children: [
        if (heard.isNotEmpty) ...[
          Text(
            'You',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 4),
          Text(heard, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 14),
        ],
        if (reply.isNotEmpty) ...[
          Text(
            'Aseman',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 4),
          Text(reply, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ],
    );
  }
}

/// Circular glass shortcut used beside [HomeTabBar] / on desktop.
class AsemanBrainButton extends StatelessWidget {
  const AsemanBrainButton({
    super.key,
    required this.dependencies,
    this.size = 52,
    this.chip = false,
  });

  final AppDependencies dependencies;
  final double size;

  /// Wider labeled chip for desktop header / lower-right.
  final bool chip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent =
        AppSettingsScope.maybeOf(context)?.accent ?? scheme.primary;

    void open() => openSavedMessages(context, dependencies);

    if (chip) {
      final fab = context.fabRecipe;
      final shell = ThemeChrome.floatingShell(context, lift: 2);
      final radius = fab.borderRadius;
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: shell.boxShadow,
        ),
        child: GlassSurface(
          alpha: AppSurfaces.overlayAlphaOf(context),
          blur: AppSurfaces.blurSigmaOf(context),
          borderRadius: radius,
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MiniMark(accent: accent, size: 28),
                const SizedBox(width: 8),
                Text(
                  'Aseman',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final shell = ThemeChrome.floatingShell(context, lift: 2);
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: shell.boxShadow,
      ),
      child: GlassSurface(
        alpha: AppSurfaces.overlayAlphaOf(context),
        blur: AppSurfaces.blurSigmaOf(context),
        borderRadius: context.fabRecipe.borderRadius,
        onTap: open,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: _MiniMark(accent: accent, size: size * .62)),
        ),
      ),
    );
  }
}

class _MiniMark extends StatelessWidget {
  const _MiniMark({required this.accent, required this.size});
  final Color accent;
  final double size;

  @override
  Widget build(BuildContext context) {
    return BrainAvatar(
      prefs: const BrainAvatarPrefs(),
      accent: accent,
      size: size,
    );
  }
}
