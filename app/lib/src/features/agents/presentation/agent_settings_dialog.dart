import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../shared/widgets/status_tag.dart';

Future<void> showAgentSettings(BuildContext context) => showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppColors.border)),
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Expanded(
                          child: Text('Agent settings · TradeBot Alpha',
                              style: TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w800))),
                      IconButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close))
                    ]),
                    const SizedBox(height: 12),
                    const Wrap(spacing: 8, runSpacing: 8, children: [
                      StatusTag('PERSONA', AppColors.primary),
                      StatusTag('API CONFIG', AppColors.cyan),
                      StatusTag('PRICING', AppColors.success),
                      StatusTag('MCP SKILLS', AppColors.warning)
                    ]),
                    const SizedBox(height: 18),
                    const Text('Model & API',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    const Row(children: [
                      Expanded(
                          child: TextField(
                              decoration: InputDecoration(
                                  labelText: 'Provider', hintText: 'OpenAI'))),
                      SizedBox(width: 10),
                      Expanded(
                          child: TextField(
                              decoration: InputDecoration(
                                  labelText: 'Model', hintText: 'GPT-4.1')))
                    ]),
                    const SizedBox(height: 14),
                    const Text('Connected tools',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    const Wrap(spacing: 8, runSpacing: 8, children: [
                      StatusTag('✓ Web Search', AppColors.success),
                      StatusTag('✓ DEX/CEX Trading', AppColors.success),
                      StatusTag('✓ Market Data', AppColors.success),
                      StatusTag('News Aggregator', AppColors.muted)
                    ]),
                    const SizedBox(height: 20),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Cancel')),
                      const SizedBox(width: 8),
                      FilledButton(
                          onPressed: () {
                            Navigator.pop(dialogContext);
                            context.showMessage('Agent settings saved');
                          },
                          child: const Text('Save changes'))
                    ]),
                  ]),
            )),
      ),
    );
