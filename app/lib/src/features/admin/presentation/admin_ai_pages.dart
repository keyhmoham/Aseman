part of 'admin_page_content.dart';

Widget _buildModelsPage(_AppPageContentState state) {
    final response = _map(state.widget.results['llm.llm_providers_list']).isNotEmpty
        ? _map(state.widget.results['llm.llm_providers_list'])
        : _map(state.widget.results['llm.llm_models']);
    final providers = _listOfMaps(response['providers']);
    final models = <Map<String, dynamic>>[];
    for (final provider in providers) {
      for (final raw in _listOfMaps(provider['models'])) {
        models.add({...raw, '_provider': provider});
      }
    }
    final q = state.search.text.trim().toLowerCase();
    final shown = models.where((m) {
      final provider = _map(m['_provider']);
      final matches = switch (state.filter) {
        'all' => true,
        'unpriced' => m['unpriced'] == true,
        'disabled' => m['disabled'] == true,
        _ =>
          '${provider['id']}' == state.filter ||
              _modelPurpose(m).toLowerCase() == state.filter,
      };
      return matches &&
          (q.isEmpty ||
              '${provider['name']} ${m['id']} ${m['name']}'
                  .toLowerCase()
                  .contains(q));
    }).toList();
    final palette = adminPalette(state.context);
    final purposeColor = {
      for (var i = 0; i < _modelKinds.length; i++)
        _modelKinds[i].$2: palette[i % palette.length],
    };
    final present = [
      for (final k in _modelKinds)
        if (models.any((m) => _modelPurpose(m) == k.$2)) k.$2,
    ];
    final unpriced = models.where((m) => m['unpriced'] == true).length;
    final disabled = models.where((m) => m['disabled'] == true).length;
    final vercel = providers.where((p) => '${p['kind']}' == 'vercel').toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 2,
          minTileWidth: 340,
          children: [
            AdminSectionCard(
              title: 'Models by purpose',
              icon: Icons.category_rounded,
              child: AdminDonutPanel(
                size: 132,
                center: '${models.length}',
                caption: 'models',
                slices: [
                  for (final purpose in present)
                    AdminChartSlice(
                      purpose,
                      models
                          .where((m) => _modelPurpose(m) == purpose)
                          .length
                          .toDouble(),
                      purposeColor[purpose]!,
                    ),
                ],
              ),
            ),
            AdminSectionCard(
              title: 'Output price per 1M tokens',
              icon: Icons.bar_chart_rounded,
              child: AdminBarList(
                maxItems: 5,
                empty: 'No priced models yet.',
                items: [
                  for (final m in models)
                    AdminChartSlice(
                      '${m['name'] ?? m['id']}',
                      _number(m['output_price']),
                      purposeColor[_modelPurpose(m)]!,
                      display: _modelPrice(m['output_price']),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        state._toolbar(
          AdminSearchField(
            controller: state.search,
            hint: 'Search provider or model',
            onChanged: (_) => state.setState(() {}),
          ),
          [
            if (vercel.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => state._importVercel(vercel),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Import from Vercel'),
              ),
            FilledButton.icon(
              onPressed: providers.isEmpty ? null : () => state._showModel(providers),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add model'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        AdminFilterChips<String>(
          selected: state.filter,
          onSelected: (v) => state.setState(() => state.filter = v),
          options: [
            AdminFilterOption('all', 'All', count: models.length),
            for (final purpose in present)
              AdminFilterOption(
                purpose.toLowerCase(),
                purpose,
                count: models.where((m) => _modelPurpose(m) == purpose).length,
              ),
            if (unpriced > 0)
              AdminFilterOption('unpriced', 'Needs a price', count: unpriced),
            if (disabled > 0)
              AdminFilterOption('disabled', 'Disabled', count: disabled),
            for (final p in providers)
              AdminFilterOption(
                '${p['id']}',
                '${p['name']}',
                icon: Icons.hub_outlined,
              ),
          ],
        ),
        const SizedBox(height: 14),
        AdminDataTable(
          empty: providers.isEmpty
              ? 'Add a provider first, then add its models here.'
              : 'No models match.',
          columns: const [
            AdminTableColumn('Provider', width: 180),
            AdminTableColumn('Model', width: 260),
            AdminTableColumn('Purpose', width: 130),
            AdminTableColumn('Price', width: 260, align: TextAlign.right),
            AdminTableColumn('Actions', width: 170, align: TextAlign.right),
          ],
          rows: [
            for (final m in shown)
              [
                Row(
                  children: [
                    Icon(
                      _map(m['_provider'])['enabled'] == false
                          ? Icons.cloud_off_rounded
                          : Icons.cloud_done_rounded,
                      size: 18,
                      color: _map(m['_provider'])['enabled'] == false
                          ? Theme.of(state.context).colorScheme.onSurfaceVariant
                          : AppColors.successOf(state.context),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _primaryCell(
                        '${_map(m['_provider'])['name']}',
                        _map(m['_provider'])['enabled'] == false
                            ? 'disabled'
                            : 'enabled',
                      ),
                    ),
                  ],
                ),
                _primaryCell(
                  '${m['name'] ?? m['id']}',
                  [
                    if (m['name'] != null) '${m['id']}',
                    if (m['disabled'] == true) 'disabled',
                    if ('${m['source'] ?? ''}'.isNotEmpty)
                      m['markup'] is num
                          ? 'from ${m['source']} +${compactDecimal(_number(m['markup']))}%'
                          : m['unpriced'] == true
                          ? 'from ${m['source']}'
                          : 'from ${m['source']}, priced by hand',
                  ].join(' · '),
                ),
                _Tag(_modelPurpose(m), color: purposeColor[_modelPurpose(m)]),
                Text(
                  _modelPriceText(m),
                  textAlign: TextAlign.right,
                  style: m['unpriced'] == true
                      ? TextStyle(
                          color: AppColors.warningOf(state.context),
                          fontWeight: FontWeight.w700,
                        )
                      : null,
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    IconButton(
                      tooltip: m['disabled'] == true
                          ? 'Enable model'
                          : 'Disable model',
                      onPressed: () =>
                          state._setModelDisabled(m, m['disabled'] != true),
                      icon: Icon(
                        m['disabled'] == true
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 18,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Edit model',
                      onPressed: () => state._showModel(
                        providers,
                        provider: _map(m['_provider']),
                        model: m,
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                    ),
                    IconButton(
                      tooltip: 'Remove model',
                      onPressed: () => state._removeModel(m),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    ),
                  ],
                ),
              ],
          ],
        ),
      ],
    );
  }

Future<void> _buildSetModelDisabled(_AppPageContentState state, Map<String, dynamic> model, bool disabled) {
    final provider = _map(model['_provider']);
    return state.widget.onDirectAction('llm', 'llm_provider_set', {
      ...provider,
      'models': [
        for (final m in _listOfMaps(provider['models']))
          if ('${m['id']}' == '${model['id']}')
            ({...m}..remove('disabled'))
              ..addAll({if (disabled) 'disabled': true})
          else
            m,
      ],
    });
  }

Future<void> _buildImportVercel(_AppPageContentState state, List<Map<String, dynamic>> vercel) async {
    final last = [
      for (final p in vercel)
        for (final m in _listOfMaps(p['models']))
          if (m['markup'] is num) _number(m['markup']),
    ];
    final picked = await showAppDialog<(String, double)>(
      context: state.context,
      builder: (_) => _ImportVercelDialog(
        providers: vercel,
        markup: last.isEmpty ? null : last.first.toDouble(),
      ),
    );
    if (picked == null || !state.mounted) return;
    dynamic result;
    try {
      result = await state.widget.onDirectAction('llm', 'llm_import_vercel', {
        'provider_id': picked.$1,
        'markup': picked.$2,
      });
    } catch (_) {
      return; // The console reports the error.
    }
    await state.widget.onRefresh();
    if (!state.mounted) return;
    final r = _map(result);
    final skipped = _map(r['skipped']);
    final needPrice = _stringList(r['need_price']);
    final gone = _stringList(r['gone']);
    await showAppDialog<void>(
      context: state.context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.download_done_rounded),
        title: const Text('Vercel models imported'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_integer(r['added'])} added · ${_integer(r['updated'])} updated · ${_integer(r['unchanged'])} unchanged, at Vercel\'s price +${compactDecimal(_number(r['markup']))}%.',
              ),
              if (skipped.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Skipped: ${skipped.entries.map((e) => '${e.value} ${e.key}').join(', ')}.',
                  style: state._muted(),
                ),
              ],
              if (needPrice.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '${needPrice.length} need a price before they are served: ${needPrice.take(8).join(', ')}${needPrice.length > 8 ? '…' : ''}',
                  style: TextStyle(color: AppColors.warningOf(context)),
                ),
              ],
              if (gone.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '${gone.length} imported before are no longer listed by Vercel (kept, remove them if unused): ${gone.take(8).join(', ')}${gone.length > 8 ? '…' : ''}',
                  style: state._muted(),
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

Future<void> _buildShowModel(
  _AppPageContentState state,
    List<Map<String, dynamic>> providers, {
    Map<String, dynamic>? provider,
    Map<String, dynamic>? model,
  }) async {
    final selected =
        provider ??
        providers.firstWhere(
          (p) => '${p['id']}' == state.filter,
          orElse: () => providers.first,
        );
    await showAppDialog<void>(
      context: state.context,
      builder: (_) => _ModelEditorDialog(
        providers: providers,
        provider: selected,
        model: model,
        onSave: (nextProvider) =>
            state.widget.onDirectAction('llm', 'llm_provider_set', nextProvider),
      ),
    );
  }

Future<void> _buildRemoveModel(_AppPageContentState state, Map<String, dynamic> model) async {
    final provider = _map(model['_provider']);
    final confirmed = await showAppDialog<bool>(
      context: state.context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text('Remove ${model['name'] ?? model['id']}?'),
        content: Text(
          'Agents using it will fall back to the default model from ${provider['name']}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await state.widget.onDirectAction('llm', 'llm_provider_set', {
      ...provider,
      'models': _listOfMaps(
        provider['models'],
      ).where((item) => '${item['id']}' != '${model['id']}').toList(),
    });
  }

Widget _buildDecisionPage(_AppPageContentState state) {
    final setting = _map(state.widget.results['llm.llm_decision_get']);
    final providers = _listOfMaps(setting['providers']);
    final enabled = setting['enabled'] == true;
    final providerId = '${setting['provider_id'] ?? ''}';
    final modelId = '${setting['model_id'] ?? ''}';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          state._settingStatus(setting),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Fast decision model',
            icon: Icons.bolt_rounded,
            subtitle: 'App selection, routing, progress and completion checks.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppSwitchCard(
                  icon: Icons.alt_route_rounded,
                  title: enabled ? 'On' : 'Off',
                  subtitle: enabled
                      ? 'Decisions use the fast model below together with each agent’s own model.'
                      : modelId.isEmpty
                      ? 'Pick a provider and model below to turn it on. Until then every agent decides with its own model.'
                      : 'Every agent decides with its own model.',
                  value: enabled,
                  onChanged: modelId.isEmpty && !enabled
                      ? null
                      : (value) => state.widget.onDirectAction(
                          'llm',
                          'llm_decision_set',
                          state._decisionBody(setting, enabled: value),
                        ),
                ),
                const SizedBox(height: 20),
                state._modelPicker(
                  slot: 'decision',
                  providers: providers,
                  providerId: providerId,
                  modelId: modelId,
                  modelsOf: (id) => state._decisionModels(providers, id),
                  onSelect: (provider, model) => state.widget.onDirectAction(
                    'llm',
                    'llm_decision_set',
                    state._decisionBody(setting, provider: provider, model: model),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AppSwitchCard(
            icon: Icons.verified_user_outlined,
            title: 'Auto-approve low-risk calls',
            subtitle:
                'Every other action still waits for a person; approvals are written to the work log.',
            value: setting['auto_approve'] == true,
            onChanged: (value) => state.widget.onDirectAction(
              'llm',
              'llm_decision_set',
              state._decisionBody(setting, autoApprove: value),
            ),
          ),
        ],
      ),
    );
  }

Widget _buildImageModelPage(_AppPageContentState state) {
    final setting = _map(state.widget.results['llm.llm_image_get']);
    final providers = _listOfMaps(setting['providers']);
    final enabled = setting['enabled'] == true;
    final providerId = '${setting['provider_id'] ?? ''}';
    final modelId = '${setting['model_id'] ?? ''}';
    Map<String, dynamic> body({bool? on, String? provider, String? model}) => {
      'enabled': on ?? enabled,
      'provider_id': provider ?? providerId,
      'model_id': model ?? modelId,
    };
    List<Map<String, dynamic>> imageModels(String id) => _listOfMaps(
      providers.cast<Map<String, dynamic>?>().firstWhere(
        (p) => '${p?['id']}' == id,
        orElse: () => null,
      )?['image_models'],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          state._settingStatus(setting),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Image model',
            icon: Icons.image_rounded,
            subtitle:
                'Agents make images through the platform\'s image function, never with their own chat model, so any agent can make images. Mark a model "Image" on the Models page to offer it here.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppSwitchCard(
                  icon: Icons.image_outlined,
                  title: enabled ? 'On' : 'Off',
                  subtitle: enabled
                      ? 'Images are made with the model below and charged at its prices on the Models page.'
                      : modelId.isEmpty
                      ? 'Pick a provider and model below to turn it on. Until then agents cannot make images.'
                      : 'Agents cannot make images.',
                  value: enabled,
                  onChanged: modelId.isEmpty && !enabled
                      ? null
                      : (value) => state.widget.onDirectAction(
                          'llm',
                          'llm_image_set',
                          body(on: value),
                        ),
                ),
                const SizedBox(height: 20),
                state._modelPicker(
                  slot: 'image',
                  providers: providers,
                  providerId: providerId,
                  modelId: modelId,
                  modelsOf: imageModels,
                  onSelect: (provider, model) => state.widget.onDirectAction(
                    'llm',
                    'llm_image_set',
                    body(provider: provider, model: model),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

Widget _buildVoicePage(_AppPageContentState state) {
    final setting = _map(state.widget.results['llm.llm_voice_get']);
    final roles = _map(setting['roles']);
    final providers = _listOfMaps(setting['providers']);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionCard(
            title: 'Live voice',
            icon: Icons.record_voice_over_rounded,
            subtitle:
                'Powers Talk on the home Decillion assistant sheet: mic → transcription → Decillion assistant → speech. Run deploy/voice (Parakeet V3 + Kokoro) as an OpenAI-compatible provider, mark its models Speech / Transcription, then enable the roles below.',
            child: Text(
              providers.isEmpty
                  ? 'No enabled LLM provider with an API key yet. Add one under AI › Providers first.'
                  : 'Each role needs a model marked for that purpose on AI › Models.',
              style: Theme.of(state.context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(state.context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(height: 16),
          state._voiceRoleCard(
            role: 'transcription',
            title: 'Transcription (STT)',
            icon: Icons.mic_none_rounded,
            subtitle:
                'Turns the person\'s spoken audio into text before the Decillion assistant answers. Mark a model "Transcription" on the Models page (e.g. parakeet-tdt-0.6b-v3).',
            roles: roles,
            providers: providers,
            showVoiceName: false,
          ),
          const SizedBox(height: 16),
          state._voiceRoleCard(
            role: 'speech',
            title: 'Speech (TTS)',
            icon: Icons.volume_up_outlined,
            subtitle:
                'Speaks Aseman\'s reply aloud. Mark a model "Speech" on the Models page (e.g. kokoro). Optional voice name is passed to the provider.',
            roles: roles,
            providers: providers,
            showVoiceName: true,
          ),
          const SizedBox(height: 16),
          state._voiceRoleCard(
            role: 'live',
            title: 'Live (realtime)',
            icon: Icons.stream_rounded,
            subtitle:
                'Optional end-to-end realtime model. Leave off when using separate transcription + speech (recommended for the local sidecar).',
            roles: roles,
            providers: providers,
            showVoiceName: true,
          ),
        ],
      ),
    );
  }

Widget _buildVoiceRoleCard(_AppPageContentState state, {
    required String role,
    required String title,
    required IconData icon,
    required String subtitle,
    required Map<String, dynamic> roles,
    required List<Map<String, dynamic>> providers,
    required bool showVoiceName,
  }) {
    final r = _map(roles[role]);
    final enabled = r['enabled'] == true;
    final active = r['active'] == true;
    final providerId = '${r['provider_id'] ?? ''}';
    final modelId = '${r['model_id'] ?? ''}';
    final voice = '${r['voice'] ?? ''}';
    final status = '${r['status'] ?? ''}';
    Map<String, dynamic> body({
      bool? on,
      String? provider,
      String? model,
      String? voiceName,
    }) =>
        {
          'role': role,
          'enabled': on ?? enabled,
          'provider_id': provider ?? providerId,
          'model_id': model ?? modelId,
          'voice': voiceName ?? voice,
        };
    List<Map<String, dynamic>> roleModels(String id) {
      final p = providers.cast<Map<String, dynamic>?>().firstWhere(
            (x) => '${x?['id']}' == id,
            orElse: () => null,
          );
      final byRole = _map(p?['models']);
      return _listOfMaps(byRole[role]);
    }

    return AdminSectionCard(
      title: title,
      icon: icon,
      subtitle: subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status.isNotEmpty) ...[
            Text(
              status,
              style: Theme.of(state.context).textTheme.bodySmall?.copyWith(
                    color: active
                        ? Theme.of(state.context).colorScheme.primary
                        : Theme.of(state.context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
          ],
          AppSwitchCard(
            icon: icon,
            title: enabled ? (active ? 'On' : 'On, but unusable') : 'Off',
            subtitle: enabled
                ? (active
                    ? 'This role uses the model below.'
                    : 'Enabled, but the model is missing or misconfigured — check Providers and Models.')
                : modelId.isEmpty
                    ? 'Pick a provider and model below to turn it on.'
                    : 'Role is off; Talk will not use it.',
            value: enabled,
            onChanged: modelId.isEmpty && !enabled
                ? null
                : (value) => state.widget.onDirectAction(
                      'llm',
                      'llm_voice_set',
                      body(on: value),
                    ),
          ),
          const SizedBox(height: 20),
          state._modelPicker(
            slot: 'voice-$role',
            providers: providers,
            providerId: providerId,
            modelId: modelId,
            modelsOf: roleModels,
            onSelect: (provider, model) => state.widget.onDirectAction(
              'llm',
              'llm_voice_set',
              body(on: true, provider: provider, model: model),
            ),
          ),
          if (showVoiceName) ...[
            const SizedBox(height: 18),
            TextFormField(
              key: ValueKey('voice-name-$role-$voice'),
              initialValue: voice,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Voice name (optional)',
                hintText: 'af_heart, alloy, Puck…',
                border: OutlineInputBorder(),
                helperText: 'Press Enter to save. Leave blank for the model default.',
              ),
              onFieldSubmitted: (value) => state.widget.onDirectAction(
                'llm',
                'llm_voice_set',
                body(voiceName: value.trim()),
              ),
            ),
          ],
        ],
      ),
    );
  }

Widget _buildModelPicker(_AppPageContentState state, {
    required String slot,
    required List<Map<String, dynamic>> providers,
    required String providerId,
    required String modelId,
    required List<Map<String, dynamic>> Function(String providerId) modelsOf,
    required void Function(String providerId, String modelId) onSelect,
    bool allowNone = false,
  }) {
    final picked = state._pickedProvider[slot];
    final shownProvider = picked ?? providerId;
    final models = modelsOf(shownProvider);
    final shownModel = picked != null ? '' : modelId;
    List<AppChoice<String>> choices(
      List<Map<String, dynamic>> options,
      String value,
      IconData icon,
    ) => [
      for (final o in options)
        AppChoice('${o['id']}', '${o['name'] ?? o['id']}', icon: icon),
      if (value.isNotEmpty && !options.any((o) => '${o['id']}' == value))
        AppChoice(
          value,
          '$value (unavailable)',
          icon: Icons.warning_amber_rounded,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppChoiceField<String>(
          label: 'Provider',
          value: shownProvider,
          onChanged: (v) {
            if (v == shownProvider) return;
            final offered = modelsOf(v);
            if (v.isEmpty || offered.isNotEmpty) {
              state.setState(() => state._pickedProvider.remove(slot));
              onSelect(v, v.isEmpty ? '' : '${offered.first['id']}');
            } else {
              state.setState(() => state._pickedProvider[slot] = v);
            }
          },
          choices: [
            if (allowNone)
              const AppChoice(
                '',
                'None — not used',
                icon: Icons.do_not_disturb_on_outlined,
              ),
            ...choices(providers, shownProvider, Icons.hub_outlined),
          ],
        ),
        if (shownProvider.isNotEmpty) ...[
          const SizedBox(height: 18),
          AppChoiceField<String>(
            label: 'Model',
            hint: models.isEmpty
                ? 'This provider offers no model for this purpose yet. Mark one for it on the Models page.'
                : null,
            value: shownModel,
            onChanged: (v) {
              if (v == shownModel) return;
              state.setState(() => state._pickedProvider.remove(slot));
              onSelect(shownProvider, v);
            },
            choices: choices(models, shownModel, Icons.memory_rounded),
          ),
        ],
      ],
    );
  }

Widget _buildMemoryModelsPage(_AppPageContentState state) {
    final setting = _map(state.widget.results['llm.llm_memory_get']);
    final providers = _listOfMaps(setting['providers']);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          state._settingStatus(setting),
          const SizedBox(height: 16),
          state._memorySlot(
            title: 'Memory chat model',
            icon: Icons.edit_note_rounded,
            hint:
                'Reads each finished conversation and writes down preferences, decisions, people, and ways of working.',
            providers: providers,
            setting: setting,
            providerKey: 'chat_provider_id',
            modelKey: 'chat_model_id',
            listKey: 'chat_models',
            active: setting['chat_active'],
          ),
          const SizedBox(height: 16),
          state._memorySlot(
            title: 'Embedding model',
            icon: Icons.scatter_plot_rounded,
            hint:
                'Turns memories into vectors so agents find relevant context by meaning. Changing it re-indexes every project.',
            providers: providers,
            setting: setting,
            providerKey: 'embedding_provider_id',
            modelKey: 'embedding_model_id',
            listKey: 'embedding_models',
            active: setting['embedding_active'],
            confirm: true,
          ),
          const SizedBox(height: 14),
          Text(
            'Projects pay for memory token use at the model prices configured on Models, counted against the project budget.',
            style: state._muted(),
          ),
        ],
      ),
    );
  }

Widget _buildMemorySlot(_AppPageContentState state, {
    required String title,
    required IconData icon,
    required String hint,
    required List<Map<String, dynamic>> providers,
    required Map<String, dynamic> setting,
    required String providerKey,
    required String modelKey,
    required String listKey,
    dynamic active,
    bool confirm = false,
  }) {
    final providerId = '${setting[providerKey] ?? ''}';
    List<Map<String, dynamic>> modelsOf(String id) {
      final provider = providers.cast<Map<String, dynamic>?>().firstWhere(
        (p) => '${p?['id']}' == id,
        orElse: () => null,
      );
      return _listOfMaps(provider?[listKey] ?? provider?['models']);
    }

    Future<void> save(Map<String, dynamic> body) async {
      if (confirm &&
          !await state._confirm(
            'Re-index every project?',
            'Changing the embedding model rebuilds every project’s memory index. Recall is slower until it finishes.',
            'Change model',
          )) {
        return;
      }
      await state.widget.onDirectAction('llm', 'llm_memory_set', body);
    }

    return AdminSectionCard(
      title: title,
      icon: icon,
      subtitle: hint,
      trailing: active == null
          ? null
          : AdminStatusPill(active == true ? 'active' : 'off'),
      child: state._modelPicker(
        slot: providerKey,
        allowNone: true,
        providers: providers,
        providerId: providerId,
        modelId: '${setting[modelKey] ?? ''}',
        modelsOf: modelsOf,
        onSelect: (provider, model) => save({
          ...state._memoryBody(setting),
          providerKey: provider,
          modelKey: model,
        }),
      ),
    );
  }

Widget _buildSettingStatus(_AppPageContentState state, Map<String, dynamic> setting) {
    final scheme = Theme.of(state.context).colorScheme;
    final active = setting['active'] == true;
    final partly =
        !active &&
        (setting['chat_active'] == true || setting['embedding_active'] == true);
    final color = active
        ? AppColors.successOf(state.context)
        : partly
        ? AppColors.warningOf(state.context)
        : scheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(AppShape.innerOf(state.context)),
      ),
      child: Row(
        children: [
          Icon(
            active
                ? Icons.check_circle_rounded
                : partly
                ? Icons.timelapse_rounded
                : Icons.pause_circle_outline_rounded,
            color: color,
            size: 28,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  active
                      ? 'In effect'
                      : partly
                      ? 'Partly in effect'
                      : 'Not in effect',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${setting['status'] ?? 'No status from the node.'}',
                  style: state._muted(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

Map<String, dynamic> _buildDecisionBody(
  _AppPageContentState state,
    Map<String, dynamic> setting, {
    bool? enabled,
    String? provider,
    String? model,
    bool? autoApprove,
  }) => {
    'enabled': enabled ?? setting['enabled'] == true,
    'provider_id': provider ?? setting['provider_id'] ?? '',
    'model_id': model ?? setting['model_id'] ?? '',
    'auto_approve': autoApprove ?? setting['auto_approve'] == true,
  };

Map<String, dynamic> _buildMemoryBody(_AppPageContentState state, Map<String, dynamic> setting) => {
    'chat_provider_id': setting['chat_provider_id'] ?? '',
    'chat_model_id': setting['chat_model_id'] ?? '',
    'embedding_provider_id': setting['embedding_provider_id'] ?? '',
    'embedding_model_id': setting['embedding_model_id'] ?? '',
  };

List<Map<String, dynamic>> _buildDecisionModels(
  _AppPageContentState state,
    List<Map<String, dynamic>> providers,
    String providerId,
  ) {
    final provider = providers.cast<Map<String, dynamic>?>().firstWhere(
      (p) => '${p?['id']}' == providerId,
      orElse: () => null,
    );
    return _listOfMaps(provider?['decision_models'] ?? provider?['models']);
  }
