import 'package:flutter/material.dart';

import 'plugin_contract.dart';
import 'ui_components.dart';

class PluginConfigDialog extends StatefulWidget {
  final String title;
  final Map schema;
  final Map<String, dynamic> values;
  const PluginConfigDialog({
    super.key,
    required this.title,
    required this.schema,
    required this.values,
  });
  @override
  State<PluginConfigDialog> createState() => _PluginConfigDialogState();
}

class _PluginConfigDialogState extends State<PluginConfigDialog> {
  final _controllers = <String, TextEditingController>{};
  final _values = <String, dynamic>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    final properties = widget.schema['properties'] as Map;
    for (final key in properties.keys.cast<String>()) {
      final field = properties[key] as Map;
      final value = widget.values[key] ?? field['default'];
      if (field['type'] == 'boolean' && field['enum'] is! List) {
        _values[key] = value ?? false;
      } else if (field['enum'] is List) {
        if (value != null) _values[key] = value;
      } else {
        _controllers[key] = TextEditingController(
          text: value?.toString() ?? '',
        );
      }
    }
  }

  void _save() {
    try {
      final values = Map<String, dynamic>.of(_values);
      final properties = widget.schema['properties'] as Map;
      for (final entry in _controllers.entries) {
        final type = properties[entry.key]['type'];
        final text = entry.value.text;
        if (text.isEmpty && type != 'string') continue;
        values[entry.key] = switch (type) {
          'integer' => int.parse(text),
          'number' => double.parse(text),
          _ => text,
        };
      }
      Navigator.pop(context, PluginContract.values(widget.schema, values));
    } catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final properties = widget.schema['properties'] as Map;
    return TideDialogs.glassContent(
      context: context,
      children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .5,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final key in properties.keys.cast<String>())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _field(key, properties[key] as Map),
                  ),
              ],
            ),
          ),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(onPressed: _save, child: const Text('保存')),
          ],
        ),
      ],
    );
  }

  Widget _field(String key, Map field) {
    final title = field['title']?.toString() ?? key;
    if (field['enum'] is List) {
      final options = field['enum'] as List;
      return DropdownButtonFormField<dynamic>(
        initialValue: options.contains(_values[key]) ? _values[key] : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: title,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final option in options)
            DropdownMenuItem(value: option, child: Text(option.toString())),
        ],
        onChanged: (value) => setState(() => _values[key] = value),
      );
    }
    if (field['type'] == 'boolean') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        value: _values[key] as bool? ?? false,
        onChanged: (value) => setState(() => _values[key] = value),
      );
    }
    return TextField(
      controller: _controllers[key],
      obscureText: field['format'] == 'password',
      keyboardType: {'number', 'integer'}.contains(field['type'])
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: title,
        helperText: field['description']?.toString(),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
