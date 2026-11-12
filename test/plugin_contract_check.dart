import 'package:tide_bot/plugin_contract.dart';

// Runs with `dart test/plugin_contract_check.dart`; no Flutter build needed.
void main() {
  var checks = 0;
  void expect(bool condition) {
    checks++;
    if (!condition) throw StateError('Check $checks failed');
  }

  void rejects(void Function() work) {
    try {
      work();
    } on FormatException {
      checks++;
      return;
    }
    throw StateError('Expected FormatException');
  }

  final schema = {
    'type': 'object',
    'properties': {
      'token': {'type': 'string', 'maxLength': 10},
      'active': {'type': 'boolean', 'default': false},
      'count': {'type': 'integer', 'minimum': 1, 'maximum': 5},
      'mode': {
        'type': 'string',
        'enum': ['a', 'b'],
        'default': 'a',
      },
    },
    'required': ['token'],
  };
  final values = PluginContract.values(schema, {'token': 'key', 'count': 3});
  expect(
    values['active'] == false &&
        values['mode'] == 'a' &&
        values['count'] is int,
  );
  rejects(() => PluginContract.values(schema, {}));
  rejects(
    () => PluginContract.values(schema, {'token': 'key', 'active': 'true'}),
  );
  rejects(() => PluginContract.values(schema, {'token': 'key', 'count': 6}));
  rejects(() => PluginContract.values(schema, {'token': 'key', 'count': 1.5}));
  rejects(() => PluginContract.values(schema, {'token': 'key', 'mode': 'c'}));
  rejects(() => PluginContract.values(schema, {'token': 'too long token'}));
  rejects(() => PluginContract.values(schema, {'token': 'key', 'unknown': 1}));
  rejects(
    () => PluginContract.schema({
      'type': 'object',
      'properties': {},
      'required': ['missing'],
    }),
  );
  rejects(
    () => PluginContract.schema({
      'type': 'object',
      'properties': {
        'x': {'type': 'object'},
      },
    }),
  );
  PluginContract.layout({
    'type': 'column',
    'children': [
      {'type': 'input', 'id': 'message', 'value': ''},
      {'type': 'toggle', 'id': 'active', 'value': true},
      {'type': 'button', 'action': 'save', 'label': '保存'},
    ],
  });
  checks++;
  rejects(() => PluginContract.layout({'type': 'webview'}));
  rejects(() => PluginContract.layout({'type': 'input', 'id': '../bad'}));
  rejects(
    () =>
        PluginContract.layout({'type': 'toggle', 'id': 'ok', 'value': 'true'}),
  );
  rejects(() => PluginContract.layout({'type': 'button'}));
  rejects(
    () => PluginContract.layout({
      'type': 'column',
      'children': [
        {'type': 'input', 'id': 'same'},
        {'type': 'input', 'id': 'same'},
      ],
    }),
  );
  var root = <String, dynamic>{'type': 'text'};
  for (var i = 0; i < 18; i++) {
    root = {
      'type': 'column',
      'children': [root],
    };
  }
  rejects(() => PluginContract.layout(root));
  rejects(
    () => PluginContract.layout({
      'type': 'column',
      'children': [
        for (var i = 0; i < 301; i++) {'type': 'text'},
      ],
    }),
  );
  for (final field in [
    {
      'type': 'string',
      'enum': ['a', 'a'],
    },
    {
      'type': 'integer',
      'enum': [1, '2'],
    },
    {'type': 'number', 'minimum': 'bad'},
    {'type': 'number', 'minimum': 2, 'maximum': 1},
    {'type': 'string', 'maxLength': -1},
    {'type': 'string', 'title': 12},
  ]) {
    rejects(
      () => PluginContract.schema({
        'type': 'object',
        'properties': {'x': field},
      }),
    );
  }
  final form = PluginContract.formValues(
    {
      'type': 'column',
      'children': [
        {'type': 'input', 'id': 'kept', 'value': 'default'},
        {'type': 'toggle', 'id': 'changed', 'value': true},
        {'type': 'input', 'id': 'newField'},
      ],
    },
    {'kept': 'edited', 'changed': 'old string', 'removed': 'stale'},
  );
  expect(form['kept'] == 'edited');
  expect(form['changed'] == true);
  expect(form['newField'] == '');
  expect(!form.containsKey('removed'));
  rejects(
    () => PluginContract.layout({
      'type': 'input',
      'id': 'field',
      'secret': 'true',
    }),
  );
  rejects(
    () => PluginContract.layout({
      'type': 'text',
      'children': [
        {'type': 'input', 'id': 'hidden'},
      ],
    }),
  );
  print('Plugin contract: $checks checks passed');
}
