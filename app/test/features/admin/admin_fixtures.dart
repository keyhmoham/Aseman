import 'dart:io';

import 'package:flutter/services.dart';
import 'package:aseman/src/data/models/llm_provider.dart';

import '../../fake_aseman_service.dart';

/// Backend responses shaped like the node's admin actions, with long values
/// so layout problems surface in tests rather than in production.
Map<String, dynamic> adminFixtures() {
  final now = DateTime.utc(2026, 10, 12, 9, 30).toIso8601String();
  final providers = [
    {
      'id': 'prov-openai',
      'name': 'OpenAI production account with a long name',
      'kind': 'openai',
      'enabled': true,
      'models': [
        {
          'id': 'gpt-5.4',
          'name': 'GPT-5.4',
          'input_price': 25000,
          'output_price': 100000,
          'capabilities': ['chat']
        },
        {
          'id': 'gpt-5.4-mini',
          'input_price': 1500,
          'output_price': 6000,
          'capabilities': ['decision']
        },
        {
          'id': 'text-embedding-3-large',
          'input_price': 1300,
          'output_price': 0,
          'capabilities': ['embedding']
        },
      ],
      'decision_models': [
        {'id': 'gpt-5.4-mini', 'name': 'GPT-5.4 mini'}
      ],
      'chat_models': [
        {'id': 'gpt-5.4', 'name': 'GPT-5.4'}
      ],
      'embedding_models': [
        {'id': 'text-embedding-3-large'}
      ],
    },
    {
      'id': 'prov-anthropic',
      'name': 'Anthropic',
      'kind': 'anthropic',
      'enabled': false,
      'models': [
        {
          'id': 'claude-sonnet-5-5',
          'input_price': 30000,
          'output_price': 150000,
        }
      ],
    },
  ];
  final accounts = [
    for (var i = 0; i < 6; i++)
      {
        'id': 'acct-0000000000000000000$i',
        'handle': i == 0 ? 'ada' : 'user_with_a_long_handle_$i',
        'email': 'person.$i.with.a.long.address@example-company.com',
        'status': i == 3 ? 'disabled' : 'active',
        'role': i == 0 ? 'admin' : null,
        'is_admin': i == 0,
        'balance': 250000 * i,
        'created_at': now,
        'profile': {
          'firstName': i == 0 ? 'Ada' : 'Person',
          'lastName': i == 0 ? 'Lovelace' : 'Number $i',
          'hireable': i.isEven,
          'marketStatus': i == 2 ? 'approved' : 'pending',
          'skills': ['trading', 'research', 'python', 'risk management'],
        },
      }
  ];
  return {
    'admin.stats': {
      'counters': {
        'users': 1250,
        'projects': 340,
        'bots': 77,
        'room_turns': 1234567
      }
    },
    'admin.health': {
      'counts': {'fail': 1, 'warn': 2, 'ok': 9},
      'generated_at': now,
      'checks': [
        {
          'group': 'Security',
          'label': 'Admin password changed from the default value',
          'status': 'fail',
          'detail': 'The node still accepts the default admin password.',
          'fix': 'Set ASEMAN_ADMIN_PASSWORD and restart the node.'
        },
        {
          'group': 'Payments',
          'label': 'Store webhook secret',
          'status': 'warn',
          'detail': 'Unset'
        },
        {'group': 'Payments', 'label': 'Stripe key', 'status': 'ok'},
      ],
    },
    'admin.plugins_health': {
      'health': [
        {'name': 'postgres', 'ok': true, 'status': 'ok'},
        {
          'name': 'nomad',
          'ok': false,
          'status': 'fail',
          'message': 'dial tcp: refused'
        },
      ]
    },
    'admin.runs_list': {
      'runs': [
        {'id': 'r1', 'status': 'failed'},
        {'id': 'r2', 'status': 'done'}
      ]
    },
    'admin.node_stats': {
      'node': {
        'id': 'node-a-very-long-node-identifier',
        'go_version': 'go1.26.1',
        'plugins': 31,
        'goroutines': 412
      },
      'resources': {
        'cpu_cores': 8,
        'load_avg': [1.2, 0.9, 0.7],
        'mem_used_percent': 62.5,
        'mem_used_bytes': 10737418240,
        'mem_total_bytes': 17179869184,
        'process_rss_bytes': 524288000,
        'disk_used_percent': 41,
        'disk_used_bytes': 107374182400,
        'disk_total_bytes': 268435456000,
        'host_uptime_sec': 987654,
      },
    },
    'admin.telemetry': {
      'plugins': [
        {'name': 'finance', 'ok': true, 'message': 'ledger balanced'},
        {'name': 'sandbox', 'ok': false, 'message': 'provider token expired'},
      ]
    },
    'federation.node_info': {'id': 'node-a'},
    'federation.nodes_list': {
      'local_node': 'node-a',
      'nodes': [
        {
          'id': 'node-a',
          'url': 'https://node-a.aseman.example.com',
          'status': 'healthy',
          'is_central': true,
          'last_seen': now
        },
        {
          'id': 'node-b',
          'url': 'https://node-b.aseman.example.com',
          'status': 'unreachable',
          'last_seen': now
        },
      ]
    },
    'finance.payouts_list': {
      'payouts': [
        {
          'id': 'payout-1',
          'handle': 'ada',
          'amount': 500000,
          'status': 'pending',
          'created_at': now,
          'method': 'bank',
          'destination': {'iban': 'DE89370400440532013000', 'name': 'Ada L'}
        },
        {
          'id': 'payout-2',
          'handle': 'grace',
          'amount': 120000,
          'status': 'paid',
          'created_at': now
        },
      ]
    },
    'market.catalog': {
      'listings': [
        {'id': 'l1', 'bot_id': 'bot-1', 'type': 'agent', 'status': 'pending'},
        {'id': 'l2', 'bot_id': 'bot-2', 'type': 'agent', 'status': 'approved'},
        {'id': 'l3', 'bot_id': 'tool-1', 'type': 'tool', 'status': 'approved'},
      ]
    },
    'market.stats': {'listings': 3},
    'users.accounts_list': {'accounts': accounts},
    'admin.admins_list': {
      'admins': [
        {'id': 'acct-00000000000000000000'}
      ]
    },
    'spaces.space_list_all': {
      'spaces': [
        for (var i = 0; i < 4; i++)
          {
            'id': 'space-00000000000000000$i',
            'name': 'A project with a fairly long descriptive name $i',
            'owner': {'handle': 'ada'},
            'home': i == 0,
            'agents': i,
            'machine': {'state': i.isEven ? 'awake' : 'asleep'},
            'spent': 12345 * i,
            'created_at': now,
          }
      ]
    },
    'admin.bots_list': {
      'bots': [
        {
          'id': 'bot-1',
          'name': 'Research analyst with a long name',
          'handle': 'research_analyst',
          'kind': 'agent',
          'owner_handle': 'ada',
          'provider': 'openai',
          'model': 'gpt-5.4',
          'per_minute': 600,
        },
        {
          'id': 'bot-2',
          'name': 'Writer',
          'handle': 'writer',
          'kind': 'agent',
          'owner_handle': 'grace',
        },
        {
          'id': 'tool-1',
          'name': 'Market data MCP server',
          'kind': 'mcp',
          'url': 'https://mcp.market-data.example.com/v1/sse',
          'per_minute': 200,
        },
        {
          'id': 'tool-2',
          'name': 'Chart app',
          'kind': 'tool',
          'description': 'Draws charts'
        },
      ]
    },
    'bots.agent_samples': {'samples': <Map<String, dynamic>>[]},
    'tools.mcp_samples': {
      'samples': [
        {'id': 's1'}
      ]
    },
    'talent.list_mine': {'talent': <Map<String, dynamic>>[]},
    'finance.overview': {
      'income': {'credits_sold': 12345600, 'purchases': 45},
      'charged': {
        'total': 8000000,
        'compute': 2000000,
        'tools': 1000000,
        'llm': 3000000,
        'agent_time': 2000000
      },
      'paid_out': {
        'creators': 3000000,
        'platform_llm': 100000,
        'platform_compute': 200000,
        'platform_bots': 50000
      },
      'kept': 5000000,
      'held_by_users': 2000000,
    },
    'finance.costs': {'compute': 1500000},
    'finance.provider_costs': {
      'bill': 1500000,
      'charged': 2000000,
      'margin': 500000,
      'by_resource': [
        {'label': 'CPU', 'cost': 900000},
        {'label': 'Memory', 'cost': 600000},
      ]
    },
    'finance.reconcile': {
      'ok': false,
      'checked': 120,
      'issues': [
        {
          'kind': 'balance_mismatch',
          'account_id': 'acct-00000000000000000001',
          'detail': 'ledger says 100, wallet says 90'
        }
      ]
    },
    'finance.purchases_list': {
      'purchases': [
        for (var i = 0; i < 4; i++)
          {
            'id': 'purchase-$i',
            'transaction_id': 'txn_000000000000000$i',
            'email': 'buyer$i@example-company.com',
            'account_id': 'acct-0000000000000000000$i',
            'product_id': 'credits_pack_large_$i',
            'amount': 99900,
            'status': ['credited', 'pending', 'reversed', 'credited'][i],
            'sandbox': i == 3,
            'created_at': now,
          }
      ]
    },
    'llm.llm_providers_list': {'providers': providers},
    'llm.llm_decision_get': {
      'enabled': true,
      'provider_id': 'prov-openai',
      'model_id': 'gpt-5.4-mini',
      'auto_approve': true,
      'active': true,
      'status': 'On: tool selection and decisions use gpt-5.4-mini.',
      'providers': [providers.first],
    },
    'llm.llm_memory_get': {
      'chat_provider_id': 'prov-openai',
      'chat_model_id': 'gpt-5.4',
      'embedding_provider_id': '',
      'embedding_model_id': '',
      'chat_active': true,
      'active': false,
      'status': 'Partly in effect: memories are learned but not recalled.',
      'providers': [providers.first],
    },
    'admin.plugins_list': {
      'plugins': [
        {
          'name': 'finance',
          'type': 'action',
          'version': '1.2.0',
          'state': 'started',
          'provides': [
            'finance.overview',
            'finance.costs',
            'finance.reconcile'
          ],
          'state_changed': now,
        },
        {
          'name': 'sandbox-e2b-with-a-long-plugin-name',
          'type': 'adapter',
          'category': 'sandbox',
          'state': 'stopped',
          'last_error': 'provider token expired while starting the adapter',
        },
        {
          'name': 'sandbox-local',
          'type': 'adapter',
          'category': 'sandbox',
          'state': 'started',
        },
      ]
    },
    'admin.wiring': {
      'active': {'sandbox': 'sandbox-local'}
    },
    'admin.logs': {
      'logs': [
        for (var i = 0; i < 30; i++)
          {
            'time': now,
            'level': ['info', 'warn', 'error'][i % 3],
            'logger': 'gateway',
            'message':
                'request $i handled with a fairly long log line that should wrap on narrow screens instead of overflowing',
          }
      ]
    },
    'spaces.admin_sandboxes': {
      'provider': 'e2b',
      'sandboxes': [
        {
          'id': 'sbx_0123456789abcdef',
          'project': {'id': 'space-1', 'name': 'Atlas Capital research desk'},
          'started_at': now,
        },
        {'id': 'sbx_stray_0123456789', 'name': 'orphan', 'started_at': now},
      ]
    },
    'spaces.admin_storage': {
      'provider': 'e2b',
      'volumes': [
        {
          'id': 'vol_0123456789abcdef',
          'name': 'aseman-space-1',
          'project': {'id': 'space-1', 'name': 'Atlas Capital research desk'},
          'created_at': now,
        },
        {'id': 'vol_orphan_0123', 'name': 'aseman-old', 'created_at': now},
      ]
    },
    'settings.get': {
      'pricing': {
        'agent_per_minute': 600,
        'sandbox': {'per_minute': 1200, 'cpu_per_min': 5},
        'tool': {'per_minute': 200},
      },
      'machine': {'cpu': 2, 'memory_mb': 2048, 'disk_mb': 4096},
      'universal_system_prompt': 'Always answer in the user\'s language.',
      'categories': ['research', 'coding', 'quant-strategies'],
    },
    'spaces.space_detail': {
      'id': 'space-000000000000000001',
      'name': 'Atlas',
      'machine': {'state': 'awake', 'provider': 'e2b'},
      'owner': {
        'handle': 'ada',
        'profile': {'firstName': 'Ada'}
      },
      'members': [
        {'handle': 'grace', 'role': 'editor', 'joined_at': now}
      ],
      'budget': {'cap': 100000, 'remaining': 40000},
      'created_at': now,
    },
    'spaces.admin_work_log': {
      'logs': [
        {
          'time': now,
          'agent': 'writer',
          'event': 'tool_call',
          'message': 'search'
        }
      ]
    },
    'spaces.admin_files': {
      'files': [
        {
          'path': '/workspace/notes/long/path/to/file.md',
          'size': 2048,
          'modified_at': now
        }
      ]
    },
    'finance.admin_account': {
      'summary': {
        'balance': 250000,
        'bought': 99900,
        'bought_count': 1,
        'granted': 1000,
        'spent': 5000,
        'by_kind': [
          {'kind': 'llm', 'amount': 4000}
        ],
        'projects': [
          {'name': 'Atlas', 'spent': 5000}
        ],
      },
      'purchases': [
        {
          'created_at': now,
          'product_id': 'credits',
          'amount': 99900,
          'transaction_id': 'txn_1'
        }
      ],
      'ledger': [
        {
          'created_at': now,
          'description': 'Top-up',
          'kind': 'mint',
          'amount': 1000,
          'balance': 250000
        }
      ],
    },
  };
}

/// Fake service answering every admin action from [fixtures].
class AdminFakeService extends FakeAsemanService {
  AdminFakeService(this.fixtures);
  final Map<String, dynamic> fixtures;

  @override
  Future<dynamic> invokeAction(String namespace, String action,
      {Map<String, dynamic> body = const {}, Duration? timeout}) async {
    return fixtures['$namespace.$action'] ?? const <String, dynamic>{};
  }

  @override
  Future<List<LlmProvider>> adminLlmProviders() async => [
        for (final p
            in (fixtures['llm.llm_providers_list'] as Map)['providers'] as List)
          LlmProvider.fromJson({
            ...(p as Map<String, dynamic>),
            'base_url': 'https://api.example.com/v1',
            'has_key': true,
            'key_preview': 'sk-…abcd',
          }),
      ];

  @override
  Future<List<LlmKind>> adminLlmKinds() async => const [];
}

/// Loads Roboto and the Material icons so screenshots show real text.
Future<void> loadFonts() async {
  final root = '${Platform.environment['FLUTTER_ROOT']}'
      '/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File('$root/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf'
  ]);
  await load('sans-serif', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf'
  ]);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}
