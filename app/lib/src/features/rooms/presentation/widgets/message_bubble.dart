import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../domain/models/message.dart';
import '../../../../shared/widgets/avatar.dart';
import '../../../../shared/widgets/status_tag.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 13),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AppAvatar(message.isAgent ? 'AI' : message.author[0],
              color: message.isAgent ? AppColors.primary : AppColors.success),
          const SizedBox(width: 10),
          Expanded(
              child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: message.isAgent
                  ? AppColors.primary.withValues(alpha: .10)
                  : AppColors.panel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: message.isAgent
                      ? AppColors.primary.withValues(alpha: .3)
                      : AppColors.border),
            ),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(message.author,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                if (message.isAgent) ...[
                  const SizedBox(width: 6),
                  const StatusTag('AI', AppColors.primary)
                ],
                const Spacer(),
                Text(message.sentAt,
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 10))
              ]),
              const SizedBox(height: 5),
              Text(message.body, style: const TextStyle(height: 1.4)),
            ]),
          )),
        ]),
      );
}
