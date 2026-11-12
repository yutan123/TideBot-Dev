import 'dart:convert';

/// The supported, deliberately small JSON Schema subset shared by settings and SDK.
class PluginContract {
  static const hooks = {'tool.before', 'tool.after', 'app.ready'};
  static final identifier = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,39}$');

  static void layout(Map root) {
    var count = 0;
    final ids = <String>{};
    void visit(Map node, int depth) {
      if (++count > 300 || depth > 16) throw const FormatException('界面层级或节点过多');
      final type = node['type'];
      if (!{
        'text',
        'column',
        'row',
        'card',
        'divider',
        'input',
        'toggle',
        'button',
      }.contains(type)) {
        throw const FormatException('不支持的界面组件');
      }
      for (final field in ['label', 'text', 'style', 'action', 'id']) {
        if (node[field] != null && node[field] is! String)
          throw FormatException('UI $field 必须是文本');
      }
      if (type == 'input' || type == 'toggle') {
        final id = node['id'];
        if (id is! String || !identifier.hasMatch(id) || !ids.add(id))
          throw const FormatException('表单 id 无效或重复');
        if (node['value'] != null &&
            (type == 'input'
                ? node['value'] is! String
                : node['value'] is! bool)) {
          throw const FormatException('表单默认值类型无效');
        }
      }
      if (type == 'button' &&
          (node['action'] is! String ||
              !identifier.hasMatch(node['action'] as String))) {
        throw const FormatException('按钮 action 无效');
      }
      if (node['secret'] != null && node['secret'] is! bool)
        throw const FormatException('secret 必须为布尔值');
      final children = node['children'] ?? [];
      if (children is! List || children.any((child) => child is! Map))
        throw const FormatException('children 必须是组件数组');
      if (children.isNotEmpty && !{'column', 'row', 'card'}.contains(type))
        throw const FormatException('只有布局容器可包含 children');
      for (final child in children) {
        visit(child as Map, depth + 1);
      }
    }

    visit(root, 0);
  }

  /// Keeps only active form fields, preserving compatible values by ID.
  static Map<String, dynamic> formValues(
    Map root,
    Map<String, dynamic> current,
  ) {
    layout(root);
    final values = <String, dynamic>{};
    void visit(Map node) {
      final type = node['type'];
      if (type == 'input' || type == 'toggle') {
        final id = node['id'] as String;
        final old = current[id];
        values[id] = type == 'input'
            ? (old is String ? old : node['value'] ?? '')
            : (old is bool ? old : node['value'] ?? false);
      }
      for (final child in node['children'] as List? ?? []) {
        visit(child as Map);
      }
    }

    visit(root);
    return values;
  }

  static void schema(Map schema) {
    if (schema['type'] != 'object' || schema['properties'] is! Map) {
      throw const FormatException('配置/工具参数必须声明 object 和 properties');
    }
    final properties = schema['properties'] as Map;
    for (final entry in properties.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('Schema 属性无效');
      }
      final field = entry.value as Map;
      if (!{'string', 'boolean', 'integer', 'number'}.contains(field['type'])) {
        throw const FormatException('字段支持 string/boolean/integer/number');
      }
      for (final key in ['title', 'description', 'format']) {
        if (field[key] != null && field[key] is! String)
          throw FormatException('$key 必须为文本');
      }
      for (final key in ['minimum', 'maximum']) {
        if (field[key] != null &&
            (field[key] is! num || !(field[key] as num).isFinite))
          throw FormatException('$key 必须为有限数字');
      }
      if (field['minimum'] != null &&
          field['maximum'] != null &&
          field['minimum'] > field['maximum'])
        throw const FormatException('minimum 不能大于 maximum');
      if (field['maxLength'] != null &&
          (field['maxLength'] is! int || field['maxLength'] < 0))
        throw const FormatException('maxLength 必须为非负整数');
      if (field['enum'] != null &&
          (field['enum'] is! List || (field['enum'] as List).isEmpty)) {
        throw const FormatException('enum 必须为非空数组');
      }
      if (field['enum'] is List) {
        final seen = <dynamic>{};
        for (final option in field['enum'] as List) {
          _field(entry.key, option, field);
          if (!seen.add(option)) throw const FormatException('enum 不允许重复值');
        }
      }
      if (field.containsKey('default'))
        _field(entry.key, field['default'], field);
    }
    final required = schema['required'];
    if (required != null &&
        (required is! List ||
            required.any((key) => !properties.containsKey(key)))) {
      throw const FormatException('required 必须引用已声明的属性');
    }
  }

  static Map<String, dynamic> values(Map schema, Map<String, dynamic> input) {
    schemaCheck(schema);
    final properties = schema['properties'] as Map;
    final result = <String, dynamic>{};
    for (final entry in properties.entries) {
      final field = entry.value as Map;
      final key = entry.key as String;
      final value = input.containsKey(key) ? input[key] : field['default'];
      if (value == null) {
        if ((schema['required'] as List? ?? []).contains(key)) {
          throw FormatException('$key 为必填项');
        }
        continue;
      }
      _field(key, value, field);
      result[key] = value;
    }
    if (input.keys.any((key) => !properties.containsKey(key))) {
      throw const FormatException('包含未声明的配置/参数');
    }
    return result;
  }

  static void schemaCheck(Map value) => schema(value);

  static void _field(Object key, dynamic value, Map field) {
    final valid = switch (field['type']) {
      'string' => value is String,
      'boolean' => value is bool,
      'integer' => value is int,
      'number' => value is num && value.isFinite,
      _ => false,
    };
    if (!valid) throw FormatException('$key 的类型不符合 ${field['type']}');
    if (field['enum'] is List && !(field['enum'] as List).contains(value)) {
      throw FormatException('$key 必须选择声明的枚举值');
    }
    if (value is num) {
      if (field['minimum'] is num && value < field['minimum']) {
        throw FormatException('$key 小于最小值');
      }
      if (field['maximum'] is num && value > field['maximum']) {
        throw FormatException('$key 大于最大值');
      }
    }
    if (value is String &&
        field['maxLength'] is int &&
        value.length > field['maxLength']) {
      throw FormatException('$key 超出长度限制');
    }
    if (jsonEncode(value).length > 65536) throw FormatException('$key 内容过长');
  }
}
