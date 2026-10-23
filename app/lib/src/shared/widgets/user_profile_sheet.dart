import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/bot.dart';
import '../../data/models/post.dart';
import '../../features/search_feed/presentation/feed_post_card.dart';
import '../../features/search_feed/presentation/search_feed_view_model.dart'
    show feedPostFromServer;
import 'avatar.dart';
import 'avatar_editor.dart';
import 'mini_tag.dart';
import 'skeleton.dart';
import 'overlay_panels.dart';

/// User profile sheet shown from the profile menu. Server-backed: the header
/// shows the signed-in account, the stats reflect the live wallet/bots/posts,
/// and the composer publishes a real post.
class UserProfileSheet extends StatefulWidget {
  const UserProfileSheet({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<UserProfileSheet> createState() => _UserProfileSheetState();
}

class _UserProfileSheetState extends State<UserProfileSheet> {
  final composer = TextEditingController();
  List<SocialPost> _posts = const [];
  int _balance = 0;
  int _bots = 0;
  int _workspaces = 0;
  bool _loading = true;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    composer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final service = widget.dependencies.service;
    try {
      final me = widget.dependencies.sessionController.session?.accountId ?? '';
      final results = await Future.wait([
        service.fetchUserPosts(me),
        service.fetchWallet(),
        service.fetchBots(),
        service.fetchSpaces(),
      ]);
      if (!mounted) return;
      setState(() {
        _posts = (results[0] as List).cast<SocialPost>();
        _balance = (results[1] as Wallet).available;
        _bots = (results[2] as List).length;
        _workspaces = (results[3] as List).length;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _share() async {
    final session = widget.dependencies.sessionController.session;
    final id = session?.accountId ?? '';
    if (id.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: id));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Account id copied')));
  }

  Future<void> _edit() async {
    final deps = widget.dependencies;
    String displayName = '';
    String bio = '';
    try {
      final tree = await deps.service.fetchMyMetadata();
      final profile = tree['profile'];
      if (profile is Map) {
        displayName = profile['displayName']?.toString() ?? '';
        bio = profile['bio']?.toString() ?? '';
      }
    } catch (_) {}
    if (!mounted) return;
    final result = await showAppDialog<_EditProfileResult>(
      context: context,
      builder: (_) => _EditProfileDialog(displayName: displayName, bio: bio),
    );
    if (result == null || !mounted) return;
    try {
      await deps.service.updateMetadata([
        {
          'op': 'set',
          'path': 'profile/displayName',
          'value': result.displayName
        },
        {'op': 'set', 'path': 'profile/bio', 'value': result.bio},
      ]);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profile updated')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _publish() async {
    final body = composer.text.trim();
    if (body.isEmpty || _publishing) return;
    setState(() => _publishing = true);
    try {
      await widget.dependencies.service.createPost(body);
      composer.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Publish failed: $e')));
    }
    if (!mounted) return;
    setState(() => _publishing = false);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.dependencies.sessionController.session;
    final handle = session?.handle ?? 'guest';
    final initials = handle.isEmpty ? '?' : handle[0].toUpperCase();
    return ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
        children: [
          _ProfileHeader(
              initials: initials,
              handle: handle,
              avatar: AvatarEditor(
                service: widget.dependencies.service,
                avatar: widget.dependencies.sessionController.avatar,
                initials: initials,
                radius: 34,
                subject: 'profile picture',
                enabled: session?.isLoggedIn ?? false,
                onChanged: (id) async {
                  await widget.dependencies.sessionController.setAvatar(id);
                  if (mounted) setState(() {});
                },
              ),
              onShare: _share,
              onEdit: _edit),
          const SizedBox(height: 12),
          _ProfileStats(
            balance: _balance,
            bots: _bots,
            posts: _posts.length,
            workspaces: _workspaces,
          ),
          const SizedBox(height: 14),
          Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(22)),
              child: Column(children: [
                Row(children: [
                  AppAvatar(initials,
                      color: AppColors.primary,
                      radius: 17,
                      image: widget.dependencies.service.avatarImage(
                          widget.dependencies.sessionController.avatar)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: TextField(
                          controller: composer,
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration.collapsed(
                              hintText: 'Share a thesis, chart or signal…'))),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  const _ProfileComposerAction(
                      icon: Icons.show_chart_rounded, label: 'Chart'),
                  const _ProfileComposerAction(
                      icon: Icons.image_outlined, label: 'Media'),
                  const _ProfileComposerAction(
                      icon: Icons.tag_rounded, label: 'Ticker'),
                  const Spacer(),
                  FilledButton.icon(
                      onPressed: _publishing ? null : _publish,
                      icon: const Icon(Icons.arrow_upward_rounded, size: 17),
                      label: Text(_publishing ? 'Publishing…' : 'Publish'))
                ])
              ])),
          const SizedBox(height: 20),
          Row(children: [
            const Text('Signal stream',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            const SizedBox(width: 8),
            Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(9)),
                child: Text('${_posts.length}',
                    style: const TextStyle(
                        fontSize: 9, fontWeight: FontWeight.w900))),
            const Spacer(),
            IconButton(
                tooltip: 'Filter posts',
                onPressed: () {},
                icon: const Icon(Icons.tune_rounded, size: 19))
          ]),
          const SizedBox(height: 6),
          if (_loading)
            const SkeletonList(itemCount: 2, item: SkeletonPost())
          else if (_posts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Text('No posts yet — publish your first signal above.',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            )
          else
            ..._posts.map((p) => FeedPostCard(
                  key: ValueKey('my-post-${p.id}'),
                  post: feedPostFromServer(p),
                  dependencies: widget.dependencies,
                  onToggleLike: () => _toggleLike(p),
                  onEdited: (body) => _replace(p.id,
                      (old) => old.copyWith(body: body, editedAt: DateTime.now())),
                  onDeleted: () => setState(() =>
                      _posts = _posts.where((old) => old.id != p.id).toList()),
                  onShared: _load,
                )),
        ]);
  }

  void _replace(String id, SocialPost Function(SocialPost) change) =>
      setState(() => _posts = [
            for (final p in _posts) p.id == id ? change(p) : p,
          ]);

  Future<void> _toggleLike(SocialPost post) async {
    final liked = !post.likedByMe;
    _replace(
        post.id,
        (p) => p.withLike(
            likes: liked ? p.likes + 1 : (p.likes > 0 ? p.likes - 1 : 0),
            likedByMe: liked));
    try {
      if (liked) {
        await widget.dependencies.service.likePost(post.id);
      } else {
        await widget.dependencies.service.unlikePost(post.id);
      }
    } catch (_) {
      if (mounted) _replace(post.id, (_) => post);
    }
  }
}

class _ProfileComposerAction extends StatelessWidget {
  const _ProfileComposerAction({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => IconButton(
      tooltip: label,
      visualDensity: VisualDensity.compact,
      onPressed: () {},
      icon: Icon(icon, size: 18));
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader(
      {required this.initials,
      required this.handle,
      this.avatar,
      this.onShare,
      this.onEdit});
  final String initials;
  final String handle;

  /// The account's avatar; its initials when not given.
  final Widget? avatar;
  final VoidCallback? onShare;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final compact = box.maxWidth < 500;
        return Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(26)),
            child: Column(children: [
              Container(
                  height: compact ? 76 : 92,
                  decoration: BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                        Theme.of(context).colorScheme.primary,
                        Theme.of(context).colorScheme.tertiary,
                        const Color(0xff16b8a6)
                      ])),
                  child: Stack(children: [
                    Positioned(
                        right: -24,
                        top: -34,
                        child: Icon(Icons.blur_circular_rounded,
                            size: 144,
                            color: Colors.white.withValues(alpha: .17))),
                    const Positioned(
                        left: 18,
                        top: 14,
                        child: MiniTag('MEMBER', Colors.white))
                  ])),
              Transform.translate(
                  offset: const Offset(0, -27),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(children: [
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                      color:
                                          Theme.of(context).colorScheme.surface,
                                      shape: BoxShape.circle),
                                  child: avatar ??
                                      CircleAvatar(
                                          radius: 34,
                                          child: Text(initials,
                                              style: const TextStyle(
                                                  fontSize: 20,
                                                  fontWeight:
                                                      FontWeight.w900)))),
                              const Spacer(),
                              IconButton.filledTonal(
                                  tooltip: 'Share profile',
                                  onPressed: onShare,
                                  icon: const Icon(Icons.ios_share_rounded,
                                      size: 18)),
                              const SizedBox(width: 6),
                              FilledButton.tonalIcon(
                                  onPressed: onEdit,
                                  icon:
                                      const Icon(Icons.edit_outlined, size: 17),
                                  label: const Text('Edit')),
                            ]),
                        const SizedBox(height: 9),
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(handle,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.w900)),
                                  Text('@$handle',
                                      style: const TextStyle(fontSize: 11))
                                ])),
                        const SizedBox(height: 10),
                      ])))
            ]));
      });
}

/// Single profile stat metric used across profile surfaces.
class ProfileStat extends StatelessWidget {
  const ProfileStat(this.value, this.label, {super.key, this.onTap});
  final String value, label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(15),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
          onTap: onTap,
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
              child: Column(children: [
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w900)),
                const SizedBox(height: 2),
                Text(label, style: const TextStyle(fontSize: 9))
              ]))));
}

class _ProfileStats extends StatelessWidget {
  const _ProfileStats({
    required this.balance,
    required this.bots,
    required this.posts,
    required this.workspaces,
  });
  final int balance;
  final int bots;
  final int posts;
  final int workspaces;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        const gap = 7.0;
        final columns = math.max(
            2, math.min(4, ((box.maxWidth + gap) / (120 + gap)).floor()));
        final width = (box.maxWidth - gap * (columns - 1)) / columns;
        final items = [
          ProfileStat('$posts', 'Posts'),
          ProfileStat('$bots', 'Bots'),
          ProfileStat('$balance', 'Credits'),
          ProfileStat('$workspaces', 'Workspaces'),
        ];
        return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: items
                .map((item) => SizedBox(width: width, child: item))
                .toList());
      });
}

class _EditProfileResult {
  const _EditProfileResult(this.displayName, this.bio);
  final String displayName;
  final String bio;
}

class _EditProfileDialog extends StatefulWidget {
  const _EditProfileDialog({required this.displayName, required this.bio});
  final String displayName;
  final String bio;
  @override
  State<_EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends State<_EditProfileDialog> {
  late final nameController = TextEditingController(text: widget.displayName);
  late final bioController = TextEditingController(text: widget.bio);

  @override
  void dispose() {
    nameController.dispose();
    bioController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit profile'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Display name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: bioController,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Bio'),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _EditProfileResult(
                nameController.text.trim(), bioController.text.trim()),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
