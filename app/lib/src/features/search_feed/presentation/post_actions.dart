import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/aseman_tokens.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../domain/feed_post.dart';
import 'rich_post_parser.dart';

/// Asks before deleting a post; true when the user confirmed.
Future<bool> confirmDeletePost(BuildContext context) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.delete_outline_rounded),
      title: const Text('Delete this post?'),
      content: const Text(
        'It disappears from every feed it is in. Posts others shared from it keep their copy.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Why a post can be reported, as the server names them, with what each
/// means to the reader.
const postReportReasons = [
  (
    'spam',
    'Spam',
    'Ads, repeated posts or misleading links',
    Icons.campaign_outlined,
  ),
  (
    'scam',
    'Scam or fraud',
    'Fake offers, phishing or pump-and-dump',
    Icons.gpp_maybe_outlined,
  ),
  (
    'harassment',
    'Harassment',
    'Targets or bullies someone',
    Icons.record_voice_over_outlined,
  ),
  (
    'abuse',
    'Hate or abuse',
    'Hateful, violent or threatening',
    Icons.report_gmailerrorred_outlined,
  ),
  (
    'inappropriate',
    'Inappropriate',
    'Sexual, graphic or otherwise unsuitable',
    Icons.visibility_off_outlined,
  ),
  (
    'other',
    'Something else',
    'Tell the admins what is wrong',
    Icons.more_horiz_rounded,
  ),
];

/// Asks why a post is being reported; null when the user cancelled.
Future<({String reason, String note})?> showReportPostDialog(
  BuildContext context,
) => showAppDialog<({String reason, String note})>(
  context: context,
  builder: (_) => const _ReportPostDialog(),
);

class _ReportPostDialog extends StatefulWidget {
  const _ReportPostDialog();
  @override
  State<_ReportPostDialog> createState() => _ReportPostDialogState();
}

class _ReportPostDialogState extends State<_ReportPostDialog> {
  String? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.flag_rounded, color: scheme.error),
      title: const Text('Report post'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "The node's admins review every report. The author is not told who reported them.",
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              for (final (key, title, hint, icon) in postReportReasons)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: _reason == key
                        ? scheme.errorContainer.withValues(alpha: .55)
                        : AppSurfaces.card(scheme, tokens: AsemanTokens.maybeOf(context)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: _reason == key
                            ? scheme.error
                            : AppSurfaces.cardBorder(scheme),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => setState(() => _reason = key),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              icon,
                              size: 20,
                              color: _reason == key
                                  ? scheme.error
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    hint,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_reason == key)
                              Icon(
                                Icons.check_circle_rounded,
                                size: 20,
                                color: scheme.error,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              TextField(
                controller: _note,
                maxLines: 3,
                minLines: 1,
                maxLength: 1000,
                decoration: const InputDecoration(
                  labelText: 'Details (optional)',
                  hintText: 'Anything that helps the admins decide',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: _reason == null
              ? null
              : () => Navigator.pop(context, (
                  reason: _reason!,
                  note: _note.text.trim(),
                )),
          icon: const Icon(Icons.send_rounded, size: 18),
          label: const Text('Report'),
        ),
      ],
    );
  }
}

/// The plain text a post leaves the app as: who wrote it and what it says.
String postShareText(FeedPost post) {
  final who = post.isForward ? post.forwardName : post.name;
  final handle = post.isForward
      ? (post.forwardHandle.isEmpty ? '' : '@${post.forwardHandle}')
      : post.handle;
  final byline = [
    who,
    if (handle.isNotEmpty && handle != who) '($handle)',
  ].join(' ');
  final text = markupPlainText(post.body);
  return '$byline on Aseman:\n\n$text';
}

/// Opens the platform's share sheet (the share intent on Android, the
/// activity sheet on iOS and macOS, the Web Share API in browsers) with the
/// post's text. When sharing fails the text is copied instead.
Future<void> sharePostExternally(BuildContext context, FeedPost post) async {
  final text = postShareText(post);
  final box = context.findRenderObject() as RenderBox?;
  final origin = box != null && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    // Where the platform has no share sheet, share_plus falls back to an
    // email draft; it only throws when it cannot do either.
    await SharePlus.instance.share(
      ShareParams(
        text: text,
        subject: 'A post on Aseman',
        sharePositionOrigin: origin,
      ),
    );
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: text));
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Sharing is not available here; the post was copied'),
      ),
    );
  }
}
