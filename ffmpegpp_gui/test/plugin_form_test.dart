import 'dart:convert';

import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:ffmpegpp_gui/widgets/plugin_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _fields = <Map<String, dynamic>>[
  {
    'key': 'gain',
    'label': 'Gain',
    'type': 'number',
    'default': 0,
    'min': -12,
    'max': 12,
  },
  {
    'key': 'count',
    'label': 'Count',
    'type': 'integer',
    'default': 1,
    'min': 0,
    'max': 10,
  },
  {'key': 'label', 'label': 'Label', 'type': 'string', 'default': ''},
  {'key': 'active', 'label': 'Active', 'type': 'boolean', 'default': false},
  {
    'key': 'axis',
    'label': 'Axis',
    'type': 'select',
    'default': 'horizontal',
    'options': ['horizontal', 'vertical'],
  },
];

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

Finder _field(String key) => find.byKey(ValueKey('plugin_field_$key'));

void main() {
  testWidgets(
    'renders five host controls and emits normalized declared values',
    (tester) async {
      Map<String, dynamic>? result;
      await tester.pumpWidget(
        _host(
          PluginForm(
            fields: _fields,
            values: const {},
            onChanged: (values) => result = values,
          ),
        ),
      );
      expect(find.byType(TextField), findsNWidgets(3));
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(find.byType(OptionMenuBar<String>), findsOneWidget);
      await tester.enterText(_field('gain'), '2.5');
      expect(result, {
        'gain': 2.5,
        'count': 1,
        'label': '',
        'active': false,
        'axis': 'horizontal',
      });
      await tester.enterText(_field('count'), '3');
      expect(result!['count'], isA<int>());
      await tester.enterText(_field('label'), 'Example');
      expect(result!['label'], 'Example');
      await tester.tap(_field('active'));
      await tester.pump();
      expect(result!['active'], isTrue);
      await tester.ensureVisible(_field('axis'));
      await tester.tap(_field('axis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('vertical').last);
      await tester.pumpAndSettle();
      expect(result!['axis'], 'vertical');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rejects nonfinite, fractional integer and out-of-range drafts', (
    tester,
  ) async {
    final emitted = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      _host(
        PluginForm(fields: _fields, values: const {}, onChanged: emitted.add),
      ),
    );
    for (final invalid in ['-', 'NaN', 'Infinity', '1e309', '13']) {
      await tester.enterText(_field('gain'), invalid);
      await tester.pump();
      expect(emitted, isEmpty, reason: invalid);
    }
    await tester.enterText(_field('gain'), '1');
    expect(emitted, hasLength(1));
    await tester.enterText(_field('count'), '1.5');
    await tester.pump();
    expect(emitted, hasLength(1));
    await tester.enterText(_field('label'), 'Still invalid');
    expect(emitted, hasLength(1));
    await tester.enterText(_field('count'), '2');
    expect(emitted, hasLength(2));
    expect(emitted.last['label'], 'Still invalid');
  });

  testWidgets('rejects unknown callbacks and duplicate or undeclared fields', (
    tester,
  ) async {
    for (final schema in [
      [
        {..._fields.first, 'onChanged': 'evil'},
      ],
      [_fields.first, _fields.first],
      [
        {..._fields.first, 'type': 'widget'},
      ],
    ]) {
      await tester.pumpWidget(
        _host(
          PluginForm(
            key: UniqueKey(),
            fields: schema,
            values: const {},
            onChanged: (_) => fail('Invalid schema emitted values'),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('plugin_form_schema_error')),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(
      _host(
        PluginForm(
          key: UniqueKey(),
          fields: _fields,
          values: const {'undeclared': 1},
          onChanged: (_) => fail('Unknown values emitted'),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('plugin_form_schema_error')),
      findsOneWidget,
    );
  });

  testWidgets('disabled fields cannot invoke host value callbacks', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        PluginForm(
          fields: _fields,
          values: const {},
          enabled: false,
          onChanged: (_) => fail('Disabled form emitted values'),
        ),
      ),
    );
    expect(tester.widget<TextField>(_field('gain')).enabled, isFalse);
    expect(tester.widget<SwitchListTile>(_field('active')).onChanged, isNull);
    await tester.tap(_field('axis'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('vertical'), findsNothing);
    // A captured child callback also rechecks enabled at the host boundary.
    tester.widget<OptionMenuBar<String>>(_field('axis')).onChanged('vertical');
    expect(tester.takeException(), isNull);
  });

  testWidgets('equivalent schema rebuild preserves an invalid local draft', (
    tester,
  ) async {
    late StateSetter refresh;
    Map<String, dynamic> values = {'gain': 0};
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            final schema = (jsonDecode(jsonEncode(_fields)) as List)
                .cast<Map<String, dynamic>>();
            return PluginForm(
              fields: schema,
              values: values,
              onChanged: (next) => values = next,
            );
          },
        ),
      ),
    );
    await tester.enterText(_field('gain'), '-');
    refresh(() {});
    await tester.pump();
    expect(tester.widget<TextField>(_field('gain')).controller!.text, '-');
    refresh(() => values = {'gain': 5});
    await tester.pump();
    expect(tester.widget<TextField>(_field('gain')).controller!.text, '5');
    expect(tester.takeException(), isNull);
  });
}
