part of 'admin_page_content.dart';

Widget _buildHealthPage(_AppPageContentState state) {
    final report = _map(state.widget.results['admin.health']);
    final checks = _listOfMaps(report['checks']);
    final pluginHealth = _listOfMaps(
      _map(state.widget.results['admin.plugins_health'])['health'],
    );
    final counts = _map(report['counts']);
    String statusOf(Map<String, dynamic> c) =>
        '${c['status'] ?? (c['ok'] == true ? 'ok' : 'fail')}';
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final check in checks) {
      (groups['${check['group'] ?? 'Platform'}'] ??= []).add(check);
    }
    if (pluginHealth.isNotEmpty) groups['Module health'] = pluginHealth;
    for (final rows in groups.values) {
      rows.sort(
        (a, b) => _healthRank(statusOf(a)).compareTo(_healthRank(statusOf(b))),
      );
    }
    final fail = counts.isNotEmpty
        ? _integer(counts['fail'])
        : checks.where((c) => '${c['status']}' == 'fail').length;
    final warn = counts.isNotEmpty
        ? _integer(counts['warn'])
        : checks.where((c) => '${c['status']}' == 'warn').length;
    final ok = counts.isNotEmpty
        ? _integer(counts['ok'])
        : checks.where((c) => '${c['status']}' == 'ok').length;
    final total = ok + warn + fail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminHeroCard(
          tone: fail > 0
              ? AppColors.dangerOf(state.context)
              : warn > 0
              ? AppColors.warningOf(state.context)
              : AppColors.successOf(state.context),
          icon: fail > 0
              ? Icons.gpp_maybe_rounded
              : warn > 0
              ? Icons.tips_and_updates_rounded
              : Icons.verified_rounded,
          title: fail > 0
              ? '$fail ${fail == 1 ? 'check needs' : 'checks need'} fixing'
              : warn > 0
              ? 'Working, with $warn to review'
              : 'Healthy deployment',
          message: total == 0
              ? 'Re-check the deployment to load live configuration checks.'
              : 'Checked ${_date(report['generated_at'])}. Secrets are never shown, only whether they are set.',
          actions: [
            FilledButton.tonalIcon(
              onPressed: state.widget.onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Re-check'),
            ),
          ],
          visual: AdminDonutChart(
            size: 140,
            center: total == 0 ? '—' : '${(ok / total * 100).round()}%',
            caption: 'healthy',
            slices: [
              AdminChartSlice('Healthy', ok.toDouble(), AppColors.successOf(state.context)),
              AdminChartSlice(
                'Worth a look',
                warn.toDouble(),
                AppColors.warningOf(state.context),
              ),
              AdminChartSlice('Need fixing', fail.toDouble(), AppColors.dangerOf(state.context)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AdminGrid(
          maxColumns: 3,
          minTileWidth: 180,
          children: [
            AdminStatCard(
              label: 'Need fixing',
              value: '$fail',
              hint: fail > 0 ? 'Broken or unsafe' : 'Nothing broken',
              icon: Icons.cancel_rounded,
              tone: fail > 0 ? AppColors.dangerOf(state.context) : AppColors.successOf(state.context),
            ),
            AdminStatCard(
              label: 'Worth a look',
              value: '$warn',
              hint: 'Works, but something is unset',
              icon: Icons.error_rounded,
              tone: warn > 0 ? AppColors.warningOf(state.context) : null,
            ),
            AdminStatCard(
              label: 'Healthy',
              value: '$ok',
              icon: Icons.check_circle_rounded,
              tone: AppColors.successOf(state.context),
            ),
          ],
        ),
        const SizedBox(height: 16),
        for (final group in groups.entries) ...[
          AdminSectionCard(
            title: group.key,
            trailing: Text(
              '${group.value.where((c) => adminTone(statusOf(c)) == AdminTone.ok).length}/${group.value.length} ok',
              style: state._muted(),
            ),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Column(
              children: [
                for (final c in group.value)
                  Builder(
                    builder: (context) {
                      final tone = adminTone(statusOf(c));
                      final color = adminToneColor(context, tone);
                      final detail = '${c['detail'] ?? c['message'] ?? ''}';
                      final fix = '${c['fix'] ?? ''}';
                      return Container(
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: tone == AdminTone.ok
                              ? Colors.transparent
                              : color.withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(adminToneIcon(tone), color: color, size: 22),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${c['label'] ?? c['name'] ?? c['id']}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (detail.isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(detail, style: state._muted()),
                                  ],
                                  if (fix.isNotEmpty &&
                                      tone != AdminTone.ok) ...[
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: ThemeRoles.selectedFill(context),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.build_circle_outlined,
                                            size: 16,
                                            color: ThemeRoles.selectedInk(context),
                                          ),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            child: Text(
                                              'Fix: $fix',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color:
                                                    ThemeRoles.selectedInk(context),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (checks.isEmpty && pluginHealth.isEmpty)
          const AdminEmptyState(
            'No health report',
            'Re-check the deployment to load live configuration checks.',
            icon: Icons.monitor_heart_outlined,
          ),
      ],
    );
  }

Widget _buildLiveChip(_AppPageContentState state, String period) => FilterChip(
    selected: state.live,
    showCheckmark: false,
    avatar: Icon(state.live ? Icons.sensors_rounded : Icons.pause_rounded, size: 18),
    label: Text(state.live ? 'Live · $period' : 'Paused'),
    onSelected: (value) => state.setState(() => state.live = value),
  );

Widget _buildNodePage(_AppPageContentState state) {
    final stats = _map(state.widget.results['admin.node_stats']);
    final r = _map(stats['resources']);
    final node = _map(stats['node']);
    final telemetry = _map(state.widget.results['admin.telemetry']);
    final plugins = _listOfMaps(telemetry['plugins']);
    final mesh = _map(state.widget.results['federation.nodes_list']);
    final nodes = _listOfMaps(mesh['nodes']);
    final load = _doubleList(r['load_avg']);
    final cores = _number(r['cpu_cores'], fallback: 1);
    final memoryPercent = _number(r['mem_used_percent']);
    final palette = adminPalette(state.context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${node['id'] ?? 'This node'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            state._liveChip('5s'),
          ],
        ),
        const SizedBox(height: 12),
        AdminSectionCard(
          title: 'Resources',
          icon: Icons.speed_rounded,
          child: Wrap(
            alignment: WrapAlignment.spaceAround,
            spacing: 12,
            runSpacing: 12,
            children: [
              AdminGauge(
                label: 'CPU load',
                value:
                    (load.isEmpty ? 0 : load.first) / (cores == 0 ? 1 : cores),
              ),
              AdminGauge(label: 'Memory', value: memoryPercent / 100),
              AdminGauge(
                label: 'Disk',
                value: _number(r['disk_used_percent']) / 100,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AdminGrid(
          children: [
            AdminStatCard(
              label: 'Modules',
              value: '${node['plugins'] ?? 0}',
              hint: '${node['goroutines'] ?? 0} goroutines',
              icon: Icons.extension_rounded,
            ),
            AdminStatCard(
              label: 'Uptime',
              value: _uptime(r['host_uptime_sec']),
              hint: '${r['cpu_cores'] ?? '—'} cores',
              icon: Icons.timer_rounded,
              tone: AppColors.cyanOf(state.context),
            ),
            AdminStatCard(
              label: 'Disk',
              value: '${_number(r['disk_used_percent']).round()}%',
              hint:
                  '${_bytes(r['disk_used_bytes'])} of ${_bytes(r['disk_total_bytes'])}',
              icon: Icons.storage_rounded,
              progress: _number(r['disk_used_percent']) / 100,
              tone: AppColors.warningOf(state.context),
            ),
            AdminStatCard(
              label: 'Runtime',
              value: '${node['go_version'] ?? '—'}',
              hint: 'Process ${_bytes(r['process_rss_bytes'])}',
              icon: Icons.code_rounded,
              tone: AppColors.successOf(state.context),
            ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 700;
            final charts = <Widget>[
              AdminLiveChart(
                label: 'CPU load',
                samples: state.cpu,
                value: '${(state.cpu.isEmpty ? 0 : state.cpu.last).round()}%',
                subtitle:
                    'load ${load.map((v) => v.toStringAsFixed(2)).join(' / ')}',
                color: AppColors.cyanOf(context),
              ),
              AdminLiveChart(
                label: 'Memory',
                samples: state.memory,
                value: '${memoryPercent.round()}%',
                subtitle:
                    '${_bytes(r['mem_used_bytes'])} of ${_bytes(r['mem_total_bytes'])} · process ${_bytes(r['process_rss_bytes'])}',
                color: palette.first,
              ),
            ];
            if (narrow) {
              return Column(
                children: [charts[0], const SizedBox(height: 12), charts[1]],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: charts[0]),
                const SizedBox(width: 12),
                Expanded(child: charts[1]),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        AdminSectionCard(
          title: 'Module health',
          icon: Icons.health_and_safety_rounded,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: plugins.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('No telemetry yet.', style: state._muted()),
                )
              : Column(
                  children: [
                    for (final p in plugins)
                      ListTile(
                        leading: Icon(
                          adminToneIcon(
                            p['ok'] == true ? AdminTone.ok : AdminTone.bad,
                          ),
                          color: p['ok'] == true
                              ? AppColors.successOf(state.context)
                              : AppColors.dangerOf(state.context),
                        ),
                        title: Text(
                          '${p['name']}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text('${p['message'] ?? ''}'),
                        trailing: AdminStatusPill(
                          p['ok'] == true ? 'healthy' : 'error',
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 14),
        AdminSectionCard(
          title: 'Mesh',
          icon: Icons.hub_rounded,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: nodes.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'This node is not federated with any other.',
                    style: state._muted(),
                  ),
                )
              : Column(
                  children: [
                    for (final n in nodes)
                      ListTile(
                        leading: AdminAvatar(
                          '${n['id']}',
                          icon: n['is_central'] == true
                              ? Icons.hub_rounded
                              : Icons.dns_rounded,
                        ),
                        title: Text(
                          '${n['id']}${n['id'] == mesh['local_node'] ? ' (s node)' : ''}${n['is_central'] == true ? ' · central' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          '${n['url'] ?? ''} · last seen ${_date(n['last_seen'])}',
                        ),
                        trailing: AdminStatusPill(
                          '${n['status'] ?? 'unknown'}',
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

Widget _buildNodePluginsPage(_AppPageContentState state) {
    final plugins = _listOfMaps(
      _map(state.widget.results['admin.plugins_list'])['plugins'],
    );
    final active = _map(_map(state.widget.results['admin.wiring'])['active']);
    bool loaded(Map<String, dynamic> p) =>
        const {'loaded', 'initialized', 'started'}.contains('${p['state']}');
    final q = state.search.text.trim().toLowerCase();
    final shown = plugins.where((p) {
      final kind = '${p['type']}' == 'adapter' ? 'adapter' : 'namespace';
      return (state.filter == 'all' ||
              state.filter == kind ||
              (state.filter == 'error' && p['last_error'] != null)) &&
          (q.isEmpty ||
              '${p['name']} ${p['type']} ${p['category']} ${p['provides']}'
                  .toLowerCase()
                  .contains(q));
    }).toList();
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final p in shown) {
      final key = '${p['type']}' == 'adapter'
          ? 'Adapters · ${p['category'] ?? 'other'}'
          : 'Action namespaces';
      (groups[key] ??= []).add(p);
    }
    final errors = plugins.where((p) => p['last_error'] != null).length;
    final loadedCount = plugins.where(loaded).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 3,
          minTileWidth: 180,
          children: [
            AdminStatCard(
              label: 'Loaded',
              value: '$loadedCount / ${plugins.length}',
              icon: Icons.extension_rounded,
              progress: plugins.isEmpty ? 0 : loadedCount / plugins.length,
            ),
            AdminStatCard(
              label: 'Active adapters',
              value: '${active.length}',
              hint: active.entries
                  .map((e) => '${e.key}: ${e.value}')
                  .join(' · '),
              icon: Icons.cable_rounded,
              tone: AppColors.cyanOf(state.context),
            ),
            AdminStatCard(
              label: 'Errors',
              value: '$errors',
              icon: Icons.error_rounded,
              tone: errors > 0 ? AppColors.dangerOf(state.context) : AppColors.successOf(state.context),
            ),
          ],
        ),
        const SizedBox(height: 18),
        AdminSearchField(
          controller: state.search,
          hint: 'Search namespaces and adapters',
          onChanged: (_) => state.setState(() {}),
        ),
        const SizedBox(height: 12),
        AdminFilterChips<String>(
          selected: state.filter,
          onSelected: (v) => state.setState(() => state.filter = v),
          options: [
            AdminFilterOption('all', 'All', count: plugins.length),
            AdminFilterOption(
              'namespace',
              'Namespaces',
              icon: Icons.api_rounded,
              count: plugins.where((p) => '${p['type']}' != 'adapter').length,
            ),
            AdminFilterOption(
              'adapter',
              'Adapters',
              icon: Icons.cable_rounded,
              count: plugins.where((p) => '${p['type']}' == 'adapter').length,
            ),
            if (errors > 0)
              AdminFilterOption(
                'error',
                'With errors',
                icon: Icons.error_outline_rounded,
                count: errors,
              ),
          ],
        ),
        const SizedBox(height: 16),
        for (final group in groups.entries) ...[
          AdminSectionCard(
            title: group.key,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Column(
              children: [
                for (final p in group.value)
                  state._adaptiveTile(
                    leading: AdminAvatar(
                      '${p['name']}',
                      icon: '${p['type']}' == 'adapter'
                          ? Icons.cable_rounded
                          : Icons.api_rounded,
                    ),
                    title: Text(
                      '${p['name']}${p['version'] == null ? '' : '  v${p['version']}'}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      [
                        _stringList(p['provides']).join(', '),
                        p['state_changed'] == null
                            ? ''
                            : 'since ${_date(p['state_changed'])}',
                        '${p['last_error'] ?? ''}',
                      ].where((x) => x.isNotEmpty).join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      if (p['category'] != null &&
                          active['${p['category']}'] == p['name'])
                        const _Tag('Active', icon: Icons.radio_button_checked)
                      else if (p['category'] != null)
                        TextButton(
                          onPressed: () => state.widget.onDirectAction(
                            'admin',
                            'plugins_set_active',
                            {'category': p['category'], 'plugin': p['name']},
                          ),
                          child: const Text('Make active'),
                        ),
                      AdminStatusPill(
                        '${p['last_error'] == null ? p['state'] : 'error'}',
                      ),
                      Switch(
                        value: loaded(p),
                        thumbIcon: WidgetStateProperty.resolveWith(
                          (states) => Icon(
                            states.contains(WidgetState.selected)
                                ? Icons.power_rounded
                                : Icons.power_off_rounded,
                          ),
                        ),
                        onChanged: (on) async {
                          if (!on &&
                              !await state._confirm(
                                'Unload ${p['name']}?',
                                'Its actions stop answering until it is loaded again.',
                                'Unload',
                              )) {
                            return;
                          }
                          await state.widget.onDirectAction(
                            'admin',
                            on ? 'plugins_load' : 'plugins_unload',
                            {'name': p['name']},
                          );
                        },
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (groups.isEmpty)
          const AdminEmptyState(
            'No modules match',
            'Try a different namespace or adapter name.',
            icon: Icons.extension_off_rounded,
          ),
      ],
    );
  }

Widget _buildLogsPage(_AppPageContentState state) {
    final all = _listOfMaps(_map(state.widget.results['admin.logs'])['logs']);
    final q = state.search.text.trim().toLowerCase();
    final rows =
        all.where((line) {
          final level = _logLevel('${line['level'] ?? 'log'}');
          return (state.filter == 'all' || state.filter == level) &&
              (q.isEmpty ||
                  '${line['logger']} ${line['state.context']} ${line['message']}'
                      .toLowerCase()
                      .contains(q));
        }).toList()..sort(
          (a, b) => '${a['time'] ?? ''}'.compareTo('${b['time'] ?? ''}'),
        );
    final dump = rows
        .map((line) {
          final level = _logLevel(
            '${line['level'] ?? 'log'}',
          ).toUpperCase().padRight(5);
          return '${_date(line['time'])} $level ${line['logger'] == null ? '' : '[${line['logger']}] '}${line['message'] ?? ''}';
        })
        .join('\n');
    int count(String level) =>
        all.where((l) => _logLevel('${l['level'] ?? 'log'}') == level).length;
    final scheme = Theme.of(state.context).colorScheme;
    // Events per minute over the window on screen, split by level.
    final buckets = <String, Map<String, int>>{};
    for (final line in all) {
      final t = _time(line['time']);
      if (t.length < 5) continue;
      final minute = t.substring(0, 5);
      final level = _logLevel('${line['level'] ?? 'log'}');
      final bucket = buckets[minute] ??= {};
      bucket[level] = (bucket[level] ?? 0) + 1;
    }
    final minutes = buckets.keys.toList()..sort();
    final recent = minutes.length > 30
        ? minutes.sublist(minutes.length - 30)
        : minutes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        state._toolbar(
          AdminFilterChips<String>(
            selected: state.filter,
            onSelected: (v) => state.setState(() => state.filter = v),
            options: [
              AdminFilterOption('all', 'All', count: all.length),
              AdminFilterOption(
                'log',
                'Info',
                count: count('log'),
                icon: Icons.info_outline_rounded,
              ),
              AdminFilterOption(
                'warn',
                'Warnings',
                count: count('warn'),
                icon: Icons.warning_amber_rounded,
              ),
              AdminFilterOption(
                'error',
                'Errors',
                count: count('error'),
                icon: Icons.error_outline_rounded,
              ),
            ],
          ),
          [
            state._liveChip('3s'),
            IconButton.filledTonal(
              tooltip: 'Copy filtered log',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: dump));
                if (state.mounted) {
                  ScaffoldMessenger.of(state.context).showSnackBar(
                    const SnackBar(content: Text('Filtered log copied')),
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
            ),
          ],
        ),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 14),
          AdminSectionCard(
            title: 'Events per minute',
            icon: Icons.insights_rounded,
            child: AdminColumnChart(
              height: 84,
              columns: [
                for (final m in recent)
                  AdminColumn(m, [
                    AdminChartSlice(
                      'info',
                      ((buckets[m]!['log'] ?? 0) + (buckets[m]!['debug'] ?? 0))
                          .toDouble(),
                      scheme.primary.withValues(alpha: .55),
                    ),
                    AdminChartSlice(
                      'warn',
                      (buckets[m]!['warn'] ?? 0).toDouble(),
                      AppColors.warningOf(state.context),
                    ),
                    AdminChartSlice(
                      'error',
                      (buckets[m]!['error'] ?? 0).toDouble(),
                      AppColors.dangerOf(state.context),
                    ),
                  ]),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        AdminSearchField(
          controller: state.search,
          hint: 'Filter by text…',
          onChanged: (_) => state.setState(() {}),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppShape.cardOf(state.context)- 4),
          child: Container(
            height: 520,
            color: const Color(0xFF07101C),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  color: const Color(0xFF0D1A2B),
                  child: Row(
                    children: [
                      for (final c in [
                        AppColors.dangerOf(state.context),
                        AppColors.warningOf(state.context),
                        AppColors.successOf(state.context),
                      ]) ...[
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${rows.length} lines${all.length >= 500 ? ' · showing latest' : ''}',
                          style: TextStyle(
                            color: Theme.of(
                              state.context,
                            ).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: rows.isEmpty
                      ? Center(
                          child: Text(
                            'No lines yet for this filter. Reproduce the problem, then refresh.',
                            style: TextStyle(
                              color: Theme.of(
                                state.context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(14),
                          itemCount: rows.length,
                          itemBuilder: (_, index) {
                            final line = rows[index];
                            final level = _logLevel(
                              '${line['level'] ?? 'log'}',
                            );
                            final color = level == 'error'
                                ? AppColors.dangerOf(state.context)
                                : level == 'warn'
                                ? AppColors.warningOf(state.context)
                                : level == 'debug'
                                ? Theme.of(state.context).colorScheme.onSurfaceVariant
                                : Theme.of(state.context).colorScheme.onSurface;
                            return SelectableText(
                              '${_time(line['time'])} ${level.toUpperCase().padRight(5)} ${line['logger'] == null ? '' : '[${line['logger']}] '}${line['message'] ?? ''}',
                              style: TextStyle(
                                color: color,
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                height: 1.55,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Updated ${TimeOfDay.now().format(state.context)}${state.live ? ' · live every 3s' : ' · paused'}',
          style: state._muted(),
        ),
      ],
    );
  }

Widget _buildSandboxesPage(_AppPageContentState state) {
    final response = _map(state.widget.results['spaces.admin_sandboxes']);
    final rows = _listOfMaps(response['sandboxes']);
    final mine = rows
        .where((r) => _map(r['project']).isNotEmpty || r['space_id'] != null)
        .toList();
    final stray = rows.where((r) => !mine.contains(r)).toList();
    Widget list(List<Map<String, dynamic>> values, String empty) =>
        values.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(12),
            child: Text(empty, style: state._muted()),
          )
        : Column(
            children: [
              for (final row in values)
                state._adaptiveTile(
                  leading: AdminAvatar(
                    '${_map(row['project'])['name'] ?? row['id']}',
                    icon: Icons.computer_rounded,
                  ),
                  title: Text(
                    '${_map(row['project'])['name'] ?? row['machine'] ?? row['name'] ?? 'Unknown machine'}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: SelectableText(
                    '${row['id']} · started ${_date(row['started_at'] ?? row['created_at'])}',
                  ),
                  actions: [
                    const AdminStatusPill('running'),
                    if (_map(row['project']).isNotEmpty)
                      TextButton(
                        onPressed: () => state._showProject(_map(row['project'])),
                        child: const Text('Open project'),
                      )
                    else
                      TextButton.icon(
                        onPressed: () => state._terminateSandbox(row),
                        icon: const Icon(
                          Icons.power_settings_new_rounded,
                          size: 18,
                        ),
                        label: const Text('Terminate'),
                      ),
                  ],
                ),
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 2,
          minTileWidth: 340,
          children: [
            AdminSectionCard(
              title: 'Running now',
              icon: Icons.computer_rounded,
              subtitle:
                  'Every one is billed by ${response['provider'] ?? 'the provider'}.',
              child: AdminDonutPanel(
                size: 132,
                center: '${rows.length}',
                caption: 'machines',
                emptyLabel: 'None running',
                slices: [
                  AdminChartSlice(
                    "Projects' computers",
                    mine.length.toDouble(),
                    AppColors.successOf(state.context),
                  ),
                  AdminChartSlice(
                    'Not used by a project',
                    stray.length.toDouble(),
                    AppColors.warningOf(state.context),
                  ),
                ],
              ),
            ),
            AdminStatCard(
              label: 'Not used by a project',
              value: '${stray.length}',
              hint: stray.isEmpty
                  ? 'Every running machine belongs to a project.'
                  : 'Running without a project: check these',
              icon: Icons.report_problem_rounded,
              tone: stray.isEmpty ? AppColors.successOf(state.context) : AppColors.warningOf(state.context),
            ),
          ],
        ),
        if (stray.isNotEmpty) ...[
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Not used by a project',
            icon: Icons.report_problem_rounded,
            subtitle:
                'These run at the provider but no project on this node uses them.',
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: list(stray, 'None'),
          ),
        ],
        const SizedBox(height: 16),
        AdminSectionCard(
          title: "Projects' computers",
          icon: Icons.folder_rounded,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: list(mine, 'No project computer is running right now.'),
        ),
      ],
    );
  }

Future<void> _buildTerminateSandbox(_AppPageContentState state, Map<String, dynamic> row) async {
    final ok = await showAppDialog<bool>(
      context: state.context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.power_settings_new_rounded),
        title: const Text('Terminate this machine?'),
        content: Text(
          '${row['machine'] ?? row['name'] ?? row['id']} runs at the provider '
          'without a project on this node. Terminating it stops its billing '
          'and deletes it; this cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Terminate'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await state.widget.onDirectAction('spaces', 'admin_terminate_sandbox', {
        'id': row['id'],
      });
    } catch (_) {
      // The console reports the error.
    }
  }

Widget _buildStoragePage(_AppPageContentState state) {
    final response = _map(state.widget.results['spaces.admin_storage']);
    final all = _listOfMaps(response['volumes']);
    final q = state.search.text.trim().toLowerCase();
    final rows = all
        .where(
          (v) =>
              q.isEmpty ||
              '${v['name']} ${v['id']} ${_map(v['project'])['name']}'
                  .toLowerCase()
                  .contains(q),
        )
        .toList();
    final used = rows.where((v) => _map(v['project']).isNotEmpty).toList();
    final unused = rows.where((v) => _map(v['project']).isEmpty).toList();
    final usedAll = all.where((v) => _map(v['project']).isNotEmpty).length;
    Widget list(List<Map<String, dynamic>> values, String empty) =>
        values.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(12),
            child: Text(empty, style: state._muted()),
          )
        : Column(
            children: [
              for (final v in values)
                state._adaptiveTile(
                  leading: AdminAvatar(
                    '${_map(v['project'])['name'] ?? v['name'] ?? v['id']}',
                    icon: Icons.storage_rounded,
                  ),
                  title: Text(
                    '${_map(v['project'])['name'] ?? v['name'] ?? v['id']}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: SelectableText(
                    [
                      v['name'],
                      v['id'],
                      'created ${_date(v['created_at'])}',
                    ].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
                  ),
                  actions: [
                    if (_map(v['project']).isNotEmpty)
                      TextButton(
                        onPressed: () => state._showProject(_map(v['project'])),
                        child: const Text('Open project'),
                      ),
                  ],
                ),
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 2,
          minTileWidth: 340,
          children: [
            AdminSectionCard(
              title: 'Volumes',
              icon: Icons.storage_rounded,
              subtitle: '${response['provider'] ?? 'Provider'} storage',
              child: AdminDonutPanel(
                size: 132,
                center: '${all.length}',
                caption: 'volumes',
                slices: [
                  AdminChartSlice(
                    "Holding a project's files",
                    usedAll.toDouble(),
                    AppColors.successOf(state.context),
                  ),
                  AdminChartSlice(
                    'With no project',
                    (all.length - usedAll).toDouble(),
                    AppColors.warningOf(state.context),
                  ),
                ],
              ),
            ),
            AdminStatCard(
              label: 'With no project',
              value: '${all.length - usedAll}',
              hint: "Left from deleted projects, or not this node's",
              icon: Icons.cleaning_services_rounded,
              tone: all.length == usedAll
                  ? AppColors.successOf(state.context)
                  : AppColors.warningOf(state.context),
            ),
          ],
        ),
        const SizedBox(height: 18),
        AdminSearchField(
          controller: state.search,
          hint: 'Search by project, volume name or id',
          onChanged: (_) => state.setState(() {}),
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Projects (${used.length})',
          icon: Icons.folder_rounded,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: list(used, "No volume holds a project's files."),
        ),
        if (unused.isNotEmpty) ...[
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'No project (${unused.length})',
            icon: Icons.cleaning_services_rounded,
            subtitle:
                'Nothing on this node uses these. Remove them at the provider only after checking they are not needed.',
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: list(unused, 'None'),
          ),
        ],
      ],
    );
  }

Widget _buildCategoriesPage(_AppPageContentState state) {
    final scheme = Theme.of(state.context).colorScheme;
    final settings = _map(state.widget.results['settings.get']);
    final enabled = _stringList(settings['categories']);
    const builtIn = {
      'productivity': Icons.task_alt_rounded,
      'research': Icons.travel_explore_rounded,
      'coding': Icons.code_rounded,
      'writing': Icons.edit_note_rounded,
      'design': Icons.palette_outlined,
      'data': Icons.dataset_outlined,
      'business': Icons.business_center_outlined,
      'education': Icons.school_outlined,
      'finance': Icons.show_chart_rounded,
      'legal': Icons.gavel_rounded,
      'marketing': Icons.campaign_outlined,
      'support': Icons.support_agent_rounded,
    };
    final custom = enabled.where((c) => !builtIn.containsKey(c)).toList()
      ..sort();
    final q = state.search.text.trim().toLowerCase();
    bool match(String id) => q.isEmpty || id.contains(q);
    void toggle(String id) {
      final next = [...enabled];
      enabled.contains(id) ? next.remove(id) : next.add(id);
      state.widget.onDirectAction('settings', 'update', {'categories': next});
    }

    String label(String id) => id.isEmpty
        ? id
        : '${id[0].toUpperCase()}${id.substring(1).replaceAll('-', ' ')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 2,
          minTileWidth: 260,
          children: [
            AdminStatCard(
              label: 'Shown in the market',
              value: '${enabled.length}',
              hint: 'Tap a category below to turn it on or off.',
              icon: Icons.category_rounded,
              progress: (builtIn.length + custom.length) == 0
                  ? 0
                  : enabled.length / (builtIn.length + custom.length),
            ),
            AdminStatCard(
              label: 'Custom',
              value: '${custom.length}',
              hint: 'Added for this node',
              icon: Icons.new_label_rounded,
              tone: AppColors.cyanOf(state.context),
            ),
          ],
        ),
        const SizedBox(height: 18),
        state._toolbar(
          AdminSearchField(
            controller: state.search,
            hint: 'Filter categories',
            onChanged: (_) => state.setState(() {}),
          ),
          [
            FilledButton.icon(
              onPressed: () => state._addCategory(enabled),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add category'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Built-in',
          icon: Icons.inventory_2_rounded,
          subtitle: 'Selected categories are offered when listing an agent.',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in builtIn.entries)
                if (match(e.key))
                  FilterChip(
                    selected: enabled.contains(e.key),
                    avatar: Icon(e.value, size: 18),
                    label: Text(label(e.key)),
                    onSelected: (_) => toggle(e.key),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AdminSectionCard(
          title: 'Custom',
          icon: Icons.new_label_rounded,
          child: custom.where(match).isEmpty
              ? Text(
                  custom.isEmpty
                      ? 'No custom categories yet. Add one for a niche your node serves.'
                      : 'No custom category matches.',
                  style: state._muted(),
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final id in custom)
                      if (match(id))
                        InputChip(
                          label: Text(label(id)),
                          avatar: Icon(
                            Icons.label_rounded,
                            size: 18,
                            color: scheme.primary,
                          ),
                          deleteIcon: const Icon(Icons.close_rounded, size: 18),
                          deleteButtonTooltipMessage: 'Remove',
                          onDeleted: () => toggle(id),
                        ),
                  ],
                ),
        ),
      ],
    );
  }

Future<void> _buildAddCategory(_AppPageContentState state, List<String> enabled) async {
    final controller = TextEditingController();
    String slug(String value) => value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final value = await showAppDialog<String>(
      context: state.context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          icon: const Icon(Icons.new_label_rounded),
          title: const Text('Add category'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                onChanged: (_) => setDialog(() {}),
                onSubmitted: (_) => Navigator.pop(context, controller.text),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Real estate',
                ),
              ),
              const SizedBox(height: 12),
              if (slug(controller.text).isNotEmpty)
                Chip(
                  avatar: const Icon(Icons.label_rounded, size: 18),
                  label: Text(slug(controller.text)),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: slug(controller.text).isEmpty
                  ? null
                  : () => Navigator.pop(context, controller.text),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (value == null) return;
    final id = slug(value);
    if (id.isEmpty) return;
    await state.widget.onDirectAction('settings', 'update', {
      'categories': <String>{...enabled, id}.toList(),
    });
  }
