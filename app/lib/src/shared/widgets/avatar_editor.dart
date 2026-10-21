import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../data/services/aseman_service.dart';

/// The largest picture taken as an avatar.
const int maxAvatarBytes = 5 * 1024 * 1024;

const _avatarTypes = [
  XTypeGroup(
    label: 'Pictures',
    extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
    mimeTypes: ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
    uniformTypeIdentifiers: ['public.image'],
    webWildCards: ['image/*'],
  ),
];

String _mimeOf(String name) => switch (name.split('.').last.toLowerCase()) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };

/// An avatar (of the account, a workspace, an agent or an app) that whoever
/// may change it changes in place: tapping it offers to upload a picture, or
/// to remove the one it has. [onChanged] saves the chosen picture's file id
/// ("" when removed) and throws when it could not be saved.
class AvatarEditor extends StatefulWidget {
  const AvatarEditor({
    super.key,
    required this.service,
    required this.avatar,
    required this.initials,
    required this.onChanged,
    this.color,
    this.filled = false,
    this.radius = 30,
    this.enabled = true,
    this.subject = 'avatar',
  });

  final AsemanService service;

  /// The current avatar: a stored picture's id, "" when there is none.
  final String avatar;

  /// Shown when there is no picture, or while it loads.
  final String initials;
  final Future<void> Function(String fileId) onChanged;

  /// The avatar's hue; the theme's primary color when not given.
  final Color? color;

  /// A solid circle in [color] rather than a tonal one.
  final bool filled;
  final double radius;

  /// False shows the avatar without offering to change it.
  final bool enabled;

  /// What the avatar is called in its menu and messages.
  final String subject;

  @override
  State<AvatarEditor> createState() => _AvatarEditorState();
}

class _AvatarEditorState extends State<AvatarEditor> {
  late String _avatar = widget.avatar;
  bool _busy = false;

  @override
  void didUpdateWidget(AvatarEditor old) {
    super.didUpdateWidget(old);
    if (old.avatar != widget.avatar) _avatar = widget.avatar;
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _change() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined),
              title: Text(
                _avatar.isEmpty ? 'Upload a picture' : 'Upload a new picture',
              ),
              subtitle: const Text('PNG, JPEG, GIF or WebP, up to 5 MB'),
              onTap: () => Navigator.pop(context, 'upload'),
            ),
            if (_avatar.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.hide_image_outlined),
                title: Text('Remove the ${widget.subject}'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'upload') await _upload();
    if (choice == 'remove') await _save('');
  }

  Future<void> _upload() async {
    final XFile? picked;
    try {
      picked = await openFile(acceptedTypeGroups: _avatarTypes);
    } catch (e) {
      _say('The picture could not be opened: $e');
      return;
    }
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) throw const FormatException('the file is empty');
      if (bytes.length > maxAvatarBytes) {
        _say('${picked.name} is larger than 5 MB.');
        return;
      }
      final mime = picked.mimeType?.startsWith('image/') == true
          ? picked.mimeType!
          : _mimeOf(picked.name);
      final id = await widget.service.uploadAvatar(
        name: picked.name,
        mime: mime,
        bytes: bytes,
      );
      await _save(id);
    } catch (e) {
      _say('The ${widget.subject} could not be changed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(String fileId) async {
    setState(() => _busy = true);
    try {
      await widget.onChanged(fileId);
      if (!mounted) return;
      setState(() => _avatar = fileId);
      _say(
        fileId.isEmpty
            ? 'The ${widget.subject} was removed.'
            : 'The ${widget.subject} was changed.',
      );
    } catch (e) {
      _say('The ${widget.subject} could not be changed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.color ?? scheme.primary;
    final image = widget.service.avatarImage(_avatar);
    final radius = widget.radius;
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: widget.filled ? color : color.withValues(alpha: .18),
      foregroundImage: image,
      onForegroundImageError: image == null ? null : (_, __) {},
      child: Text(
        widget.initials,
        style: TextStyle(
          color: widget.filled ? scheme.onPrimary : color,
          fontWeight: FontWeight.w800,
          fontSize: (radius * .62).clamp(10, 26).toDouble(),
        ),
      ),
    );
    if (!widget.enabled) return avatar;
    final badge = (radius * .62).clamp(16, 26).toDouble();
    return Tooltip(
      message: 'Change the ${widget.subject}',
      child: Semantics(
        button: true,
        label: 'Change the ${widget.subject}',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _busy ? null : _change,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              avatar,
              if (_busy)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: .35),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: badge,
                  height: badge,
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Icon(
                    Icons.photo_camera_outlined,
                    size: badge * .6,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
