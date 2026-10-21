import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/bot.dart';
import '../../data/models/post.dart';
import '../../features/search_feed/presentation/rich_post_content.dart';
import 'avatar.dart';
import 'mini_tag.dart';

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
    final result = await showDialog<_EditProfileResult>(
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
                  AppAvatar(initials, color: AppColors.primary, radius: 17),
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
            const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()))
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
            ..._posts.map((p) => _ProfilePostCard(
                  initials: initials,
                  handle: handle,
                  body: p.body,
                  tag: p.tags.isEmpty ? 'POST' : p.tags.first.toUpperCase(),
                  likes: p.likes,
                  time: _timeAgo(p.createdAt),
                  headers: widget.dependencies.service.authHeaders(),
                )),
        ]);
  }

  static String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
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

class _ProfilePostCard extends StatelessWidget {
  const _ProfilePostCard({
    required this.initials,
    required this.handle,
    required this.body,
    required this.tag,
    required this.likes,
    required this.time,
    this.headers = const {},
  });
  final String initials;
  final String handle;
  final String body;
  final String tag;
  final int likes;
  final String time;

  /// Sign-in headers for the post's images.
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) => Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(21)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppAvatar(initials, color: AppColors.primary, radius: 18),
          const SizedBox(width: 9),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(handle,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w800)),
                Text('@$handle · $time', style: const TextStyle(fontSize: 9))
              ])),
          IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Post actions',
              onPressed: () {},
              icon: const Icon(Icons.more_horiz_rounded, size: 18))
        ]),
        const SizedBox(height: 9),
        DefaultTextStyle.merge(
            style: const TextStyle(fontSize: 13, height: 1.45),
            child: RichPostContent(body, headers: headers)),
        const SizedBox(height: 12),
        Row(children: [
          MiniTag(tag, Theme.of(context).colorScheme.primary),
          const Spacer(),
          const Icon(Icons.favorite_border_rounded, size: 16),
          const SizedBox(width: 4),
          Text('$likes', style: const TextStyle(fontSize: 10)),
          const SizedBox(width: 13),
          const Icon(Icons.chat_bubble_outline_rounded, size: 15),
          const SizedBox(width: 13),
          const Icon(Icons.bookmark_border_rounded, size: 16)
        ])
      ]));
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader(
      {required this.initials,
      required this.handle,
      this.onShare,
      this.onEdit});
  final String initials;
  final String handle;
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
                                  child: CircleAvatar(
                                      radius: 34,
                                      child: Text(initials,
                                          style: const TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.w900)))),
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
                        Row(children: [
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Row(children: [
                                  Flexible(
                                      child: Text(handle,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 22,
                                              fontWeight: FontWeight.w900))),
                                  const SizedBox(width: 5),
                                  const Icon(Icons.verified_rounded,
                                      size: 17, color: Colors.blueAccent)
                                ]),
                                Text('@$handle · Federated member',
                                    style: const TextStyle(fontSize: 11))
                              ])),
                          Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(10)),
                              child: const Text('●  ACTIVE',
                                  style: TextStyle(
                                      color: Colors.green,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w900)))
                        ]),
                        const SizedBox(height: 10),
                      ])))
            ]));
      });
}

/// Single profile stat metric used across profile surfaces.
class ProfileStat extends StatelessWidget {
  const ProfileStat(this.value, this.label, {super.key});
  final String value, label;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(15)),
      child: Column(children: [
        Text(value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 9))
      ]));
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
