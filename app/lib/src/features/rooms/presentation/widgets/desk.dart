import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../shared/widgets/app_panel.dart';
import '../../../../shared/widgets/status_tag.dart';

enum DeskWidgetType { chart, trade, agents, depth }

class Desk extends StatefulWidget {
  const Desk({super.key, required this.openAgentSettings});
  final VoidCallback openAgentSettings;
  @override
  State<Desk> createState() => _DeskState();
}

class _DeskState extends State<Desk> {
  final items = <DeskWidgetType>[
    DeskWidgetType.chart,
    DeskWidgetType.trade,
    DeskWidgetType.agents
  ];

  void add() {
    if (items.contains(DeskWidgetType.depth))
      return context.showMessage('All demo widgets are already on the desk');
    setState(() => items.add(DeskWidgetType.depth));
  }

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
            color: AppColors.navigation,
            border: Border(left: BorderSide(color: AppColors.border))),
        child: ListView(padding: const EdgeInsets.all(12), children: [
          Row(children: [
            const Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('The desk',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  Text('Drag widgets to rearrange',
                      style: TextStyle(color: AppColors.muted, fontSize: 10))
                ])),
            IconButton(
                tooltip: 'Add widget',
                onPressed: add,
                icon: const Icon(Icons.add_box_outlined,
                    color: AppColors.primary))
          ]),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            onReorder: (oldIndex, newIndex) => setState(() {
              if (newIndex > oldIndex) newIndex--;
              items.insert(newIndex, items.removeAt(oldIndex));
            }),
            itemBuilder: (context, index) {
              final type = items[index];
              return Padding(
                  key: ValueKey(type),
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AppPanel(
                    title: _title(type),
                    action: IconButton(
                        onPressed: () => setState(() => items.remove(type)),
                        icon: const Icon(Icons.close_rounded,
                            color: AppColors.muted, size: 16)),
                    child: _content(type),
                  ));
            },
          ),
          OutlinedButton.icon(
              onPressed: widget.openAgentSettings,
              icon: const Icon(Icons.tune),
              label: const Text('Agent settings')),
        ]),
      );

  String _title(DeskWidgetType type) => switch (type) {
        DeskWidgetType.chart => 'BTC / USDT',
        DeskWidgetType.trade => 'Trade ticket',
        DeskWidgetType.agents => 'Agent status',
        DeskWidgetType.depth => 'Market depth'
      };

  Widget _content(DeskWidgetType type) => switch (type) {
        DeskWidgetType.chart =>
          SizedBox(height: 130, child: CustomPaint(painter: _ChartPainter())),
        DeskWidgetType.trade => Column(children: [
            const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  StatusTag('BUY BTC', AppColors.success),
                  Text('Limit / Market',
                      style: TextStyle(color: AppColors.muted, fontSize: 11))
                ]),
            const SizedBox(height: 10),
            const TextField(
                decoration: InputDecoration(
                    labelText: 'Amount', hintText: '1.2', isDense: true)),
            const SizedBox(height: 8),
            SizedBox(
                width: double.infinity,
                child: FilledButton(
                    onPressed: () =>
                        context.showMessage('Order preview opened'),
                    child: const Text('Buy BTC')))
          ]),
        DeskWidgetType.agents => const Column(children: [
            _AgentState('BotAlpha', 'Analyzing', AppColors.success),
            _AgentState('Agent73', 'Monitoring', AppColors.primary)
          ]),
        DeskWidgetType.depth => const Column(children: [
            LinearProgressIndicator(value: .68, color: AppColors.primary),
            SizedBox(height: 10),
            LinearProgressIndicator(value: .46, color: AppColors.danger)
          ]),
      };
}

class _AgentState extends StatelessWidget {
  const _AgentState(this.name, this.status, this.color);
  final String name, status;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Icon(Icons.smart_toy, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(name)),
        Text(status, style: TextStyle(color: color, fontSize: 11))
      ]));
}

class _ChartPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(0, size.height * .75);
    for (var i = 1; i <= 16; i++) {
      path.lineTo(size.width * i / 16,
          size.height * (.72 - .035 * i + math.sin(i * 1.45) * .10));
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
