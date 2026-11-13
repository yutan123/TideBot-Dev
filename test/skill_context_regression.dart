import 'dart:convert';

import 'package:tide_bot/skill_context.dart';
import 'package:tide_bot/tool_bot_scope.dart';

void main() {
  final fullInstructions = List.generate(
    200,
    (i) => '步骤$i：按声明式指引处理任务。',
  ).join('\n');
  final rows = <Map<String, dynamic>>[
    {
      'id': 'guide',
      'name': '声明式技能',
      'enabled': 1,
      'bot_scope': '["bot-a"]',
      'manifest_json': jsonEncode({
        'instructions': fullInstructions,
        'files': ['references/guide.md'],
        'tools': [],
      }),
    },
    {
      'id': 'disabled',
      'enabled': 0,
      'manifest_json': jsonEncode({'instructions': 'DISABLED_GUIDANCE'}),
    },
    {
      'id': 'other',
      'enabled': 1,
      'bot_scope': '["bot-b"]',
      'manifest_json': jsonEncode({'instructions': 'OTHER_BOT_GUIDANCE'}),
    },
  ];
  final context = buildEnabledSkillContext(toolRowsForBot(rows, 'bot-a'));
  void check(bool value, String message) {
    if (!value) throw StateError(message);
  }

  check(
    context.contains(fullInstructions),
    'Guidance must be complete without truncation',
  );
  check(
    context.contains('references/guide.md'),
    'Reference list must remain visible',
  );
  check(context.contains('无需调用工具读取本段指引'), 'Guidance must apply directly');
  check(
    !context.contains('DISABLED_GUIDANCE'),
    'Disabled skills must be excluded',
  );
  check(!context.contains('OTHER_BOT_GUIDANCE'), 'Bot scope must be respected');
  check(
    buildEnabledSkillContext([]).isEmpty,
    'Empty catalogs must add no prompt',
  );
  print(
    'PASS: complete declarative guidance, direct use, references, enabled state and bot scope',
  );
}
