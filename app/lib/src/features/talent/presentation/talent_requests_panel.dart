import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/skeleton.dart';

/// Opens the person's requests for talent: a bottom sheet on phones, a
/// floating window on wider screens.
Future<void> showTalentRequests(
        BuildContext context, AppDependencies dependencies) =>
    showFloatingPanel(
        context, TalentRequestsPanel(service: dependencies.service),
        maxWidth: 820, barrierLabel: 'Close talent requests');

/// What a request can be about, how its budget counts and how long the work
/// takes, as `talent.request_create` takes them.
const talentCategories = [
  'Development',
  'Design',
  'Marketing',
  'Community',
  'Research',
  'Other'
];
const talentBudgetTypes = [
  ('fixed', 'Fixed'),
  ('hourly', 'Per hour'),
  ('monthly', 'Per month')
];
const talentTimelines = [
  ('flexible', 'Flexible'),
  ('lt_1_week', 'Under a week'),
  ('1_4_weeks', '1–4 weeks'),
  ('1_3_months', '1–3 months'),
  ('ongoing', 'Ongoing'),
];

/// The jobs a person posted for talent. Hiring partners read the open ones
/// and get in touch; nothing here moves money.
class TalentRequestsPanel extends StatefulWidget {
  const TalentRequestsPanel({super.key, required this.service});
  final AsemanService service;

  @override
  State<TalentRequestsPanel> createState() => _TalentRequestsPanelState();
}

class _TalentRequestsPanelState extends State<TalentRequestsPanel> {
  List<Map<String, dynamic>> _requests = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.service.fetchTalentRequests();
      if (!mounted) return;
      setState(() {
        _requests = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _post() async {
    final posted = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
            builder: (_) => TalentRequestForm(service: widget.service)));
    if (posted == true) {
      _say('Posted. Hiring partners can now see it.');
      await _load();
    }
  }

  Future<void> _setStatus(Map<String, dynamic> r, String status) async {
    try {
      await widget.service.setTalentRequestStatus('${r['id']}', status);
      await _load();
    } catch (e) {
      _say('$e');
    }
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: const Text('Delete this request?'),
        content: Text('“${r['title']}” is removed for good.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.service.deleteTalentRequest('${r['id']}');
      await _load();
    } catch (e) {
      _say('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 560;
    final gutter = compact ? 16.0 : 26.0;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 16 : 22, gutter, 0),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PanelHeader(
            icon: Icons.work_outline_rounded,
            title: 'Hire talent',
            subtitle: 'Post a job; hiring partners read the open ones',
            onClose: () => Navigator.of(context).maybePop(),
            actions: [
              FilledButton.icon(
                  onPressed: _post,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('New request')),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const SkeletonList(
                    item: SkeletonCard(mediaHeight: 0), spacing: 10)
                : _error != null
                    ? Center(child: Text('Could not load requests: $_error'))
                    : _requests.isEmpty
                        ? Center(
                            child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.work_outline_rounded,
                                      size: 44, color: scheme.primary),
                                  const SizedBox(height: 12),
                                  const Text('No requests yet',
                                      style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800)),
                                  const SizedBox(height: 6),
                                  Text(
                                      'Describe the work you need: hiring partners see it and contact you.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: scheme.onSurfaceVariant)),
                                ]),
                          ))
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              padding: const EdgeInsets.only(bottom: 24),
                              itemCount: _requests.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, i) => _RequestCard(
                                request: _requests[i],
                                onStatus: (s) => _setStatus(_requests[i], s),
                                onDelete: () => _delete(_requests[i]),
                              ),
                            ),
                          ),
          ),
        ]),
      ),
    );
  }
}

/// A request's budget in words: "$500 fixed", "$40 / hour".
String talentBudget(Map<String, dynamic> r) {
  final raw = (r['budget_amount'] as num?)?.toDouble() ?? 0;
  final amount = raw == raw.roundToDouble()
      ? raw.toStringAsFixed(0)
      : raw.toStringAsFixed(2);
  return switch ('${r['budget_type']}') {
    'hourly' => '\$$amount / hour',
    'monthly' => '\$$amount / month',
    _ => '\$$amount fixed',
  };
}

class _RequestCard extends StatelessWidget {
  const _RequestCard(
      {required this.request, required this.onStatus, required this.onDelete});
  final Map<String, dynamic> request;
  final ValueChanged<String> onStatus;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = '${request['status']}';
    final (label, color) = switch (status) {
      'open' => ('Open', scheme.primary),
      'hidden' => ('Removed by an admin', scheme.error),
      _ => ('Closed', scheme.onSurfaceVariant),
    };
    final skills = [for (final s in request['skills'] as List? ?? const []) '$s'];
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.inner)),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text('${request['title']}',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
            '${request['category']} · ${talentBudget(request)}${'${request['company'] ?? ''}'.isEmpty ? '' : ' · ${request['company']}'}'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: color)),
          PopupMenuButton<String>(
            tooltip: 'Request options',
            onSelected: (v) => v == 'delete' ? onDelete() : onStatus(v),
            itemBuilder: (_) => [
              if (status == 'open')
                const PopupMenuItem(value: 'closed', child: Text('Close')),
              if (status == 'closed')
                const PopupMenuItem(value: 'open', child: Text('Reopen')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ]),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${request['description'] ?? ''}'),
          if (skills.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in skills)
                Chip(label: Text(s), visualDensity: VisualDensity.compact),
            ]),
          ],
          if (status == 'hidden') ...[
            const SizedBox(height: 10),
            Text(
                'The node’s admins took this request down; partners no longer see it.',
                style: TextStyle(fontSize: 12, color: scheme.error)),
          ],
        ],
      ),
    );
  }
}

/// Posts a request for talent. Pops with true once it is posted.
class TalentRequestForm extends StatefulWidget {
  const TalentRequestForm({super.key, required this.service});
  final AsemanService service;

  @override
  State<TalentRequestForm> createState() => _TalentRequestFormState();
}

class _TalentRequestFormState extends State<TalentRequestForm> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _budget = TextEditingController();
  final _company = TextEditingController();
  final _skills = TextEditingController();
  String _category = talentCategories.first;
  String _budgetType = 'fixed';
  String _timeline = '';
  bool _busy = false;
  String? _error;

  /// One id per form, so a retry after a lost answer posts once.
  final _requestId = DateTime.now().microsecondsSinceEpoch.toString();

  @override
  void dispose() {
    for (final c in [_title, _description, _budget, _company, _skills]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _check() {
    final title = _title.text.trim().length;
    final description = _description.text.trim().length;
    final company = _company.text.trim().length;
    final budget = double.tryParse(_budget.text.trim().replaceAll(',', ''));
    if (title < 5 || title > 120) return 'The title needs 5 to 120 characters.';
    if (description < 50 || description > 5000) {
      return 'Describe the work in 50 to 5,000 characters ($description so far).';
    }
    if (budget == null || budget <= 0 || budget > 1000000) {
      return 'Enter a budget in US dollars, up to \$1,000,000.';
    }
    if (company < 2 || company > 80) {
      return 'Name the company or project (2 to 80 characters).';
    }
    if (_skillList.length > 10) return 'Add at most 10 skills.';
    return null;
  }

  List<String> get _skillList => [
        for (final s in _skills.text.split(','))
          if (s.trim().isNotEmpty) s.trim()
      ];

  Future<void> _submit() async {
    final problem = _check();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.createTalentRequest({
        'title': _title.text.trim(),
        'category': _category,
        'description': _description.text.trim(),
        'budget_type': _budgetType,
        'budget_amount':
            double.parse(_budget.text.trim().replaceAll(',', '')),
        'company': _company.text.trim(),
        if (_timeline.isNotEmpty) 'timeline': _timeline,
        'skills': _skillList,
        'request_id': _requestId,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  InputDecoration _field(String label, {String? hint, String? helper}) =>
      InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          border: const OutlineInputBorder());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('New request for talent')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(padding: const EdgeInsets.all(20), children: [
              TextField(
                  controller: _title,
                  maxLength: 120,
                  decoration: _field('Title',
                      hint: 'Senior Flutter developer for a trading app')),
              const SizedBox(height: 8),
              AppChoiceField<String>(
                label: 'Category',
                value: _category,
                onChanged: (v) => setState(() => _category = v),
                choices: [
                  for (final c in talentCategories) AppChoice(c, c),
                ],
              ),
              const SizedBox(height: 18),
              TextField(
                  controller: _description,
                  minLines: 5,
                  maxLines: 12,
                  maxLength: 5000,
                  decoration: _field('What you need',
                      helper:
                          'The work, the skills it takes and how you will work together (at least 50 characters).')),
              const SizedBox(height: 12),
              AppChoiceField<String>(
                label: 'Budget',
                value: _budgetType,
                onChanged: (v) => setState(() => _budgetType = v),
                choices: [
                  for (final (value, label) in talentBudgetTypes)
                    AppChoice(value, label),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                  controller: _budget,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: _field('Amount',
                      hint: '2500',
                      helper: 'In US dollars').copyWith(prefixText: '\$ ')),
              const SizedBox(height: 16),
              TextField(
                  controller: _company,
                  maxLength: 80,
                  decoration: _field('Company or project', hint: 'Acme Labs')),
              const SizedBox(height: 8),
              AppChoiceField<String>(
                label: 'Timeline (optional)',
                value: _timeline,
                onChanged: (v) =>
                    setState(() => _timeline = v == _timeline ? '' : v),
                choices: [
                  for (final (value, label) in talentTimelines)
                    AppChoice(value, label),
                ],
              ),
              const SizedBox(height: 18),
              TextField(
                  controller: _skills,
                  decoration: _field('Skills (optional)',
                      hint: 'Flutter, Go, Postgres',
                      helper: 'Separated by commas, up to 10.')),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: scheme.secondaryContainer.withValues(alpha: .6),
                    borderRadius: BorderRadius.circular(AppShape.inner)),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded,
                      color: scheme.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        'Your name and email are shared with hiring partners so they can contact you. The project you post from is not.',
                        style: TextStyle(color: scheme.onSecondaryContainer)),
                  ),
                ]),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                    onPressed: _busy ? null : _submit,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded, size: 18),
                    label: const Text('Post request')),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
