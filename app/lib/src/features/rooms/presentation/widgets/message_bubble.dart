import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_chrome.dart';
import '../../../../domain/models/message.dart';
import '../../../../shared/widgets/avatar.dart';
import '../../../../shared/widgets/status_tag.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final agent = message.isAgent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppAvatar(agent ? 'AI' : message.author[0],
            color: agent
                ? AppColors.primaryOf(context)
                : AppColors.successOf(context)),
        const SizedBox(width: 10),
        Expanded(
            child: Container(
          padding: ThemeChrome.chatBubblePadding(context),
          decoration: ThemeChrome.chatBubble(
            context,
            mine: false,
            agent: agent,
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(message.author,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              if (agent) ...[
                const SizedBox(width: 6),
                StatusTag('AI', AppColors.primaryOf(context))
              ],
              const Spacer(),
              Text(message.sentAt,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 10))
            ]),
            const SizedBox(height: 5),
            Text(message.body, style: const TextStyle(height: 1.4)),
          ]),
        )),
      ]),
    );
  }
}
