import 'dart:convert';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/models/node_picker_options.dart';
import 'package:ffmpegpp_gui/pages/detached_window_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/multi_window.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_dropdown.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_equalizer_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_reverse_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_spectrum_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_waveform_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/video_fade_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/video_reverse_step_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

typedef _HostCall = ({String method, Map<String, dynamic> args});

const _newTypes = [
  PipelineStepType.audioSpectrum,
  PipelineStepType.audioWaveform,
  PipelineStepType.audioReverse,
  PipelineStepType.audioEqualizer,
  PipelineStepType.videoReverse,
  PipelineStepType.videoFade,
];

Map<String, dynamic> _snapshot(AppConfig config, {PipelineNode? selected}) => {
  'config': config.toJson(),
  'video': {'fileMediaType': 'audio'},
  'selection': selected?.toJson(),
  'toolbox': [
    for (final type in [..._newTypes, PipelineStepType.audioSpectrum])
      {'kind': 'node', 'id': type.name},
    {'kind': 'node', 'id': PipelineStepType.metadataStrip.name},
    {'kind': 'gate', 'id': 'and', 'gateType': 'and'},
    {'kind': 'gate', 'id': 'or', 'gateType': 'or'},
    {'kind': 'block', 'id': 'main-only-block', 'labelEn': 'Host block'},
  ],
};

PanelWindowStore _store(
  List<_HostCall> calls, {
  PipelineNode? selected,
  Map<String, int>? usageCounts,
}) {
  final store = PanelWindowStore(
    const DetachedWindowArgs(panel: DetachedPanel.elements, lang: 'en'),
    send: (method, [arguments]) async {
      calls.add((
        method: method,
        args: Map<String, dynamic>.from(
          jsonDecode(jsonEncode(arguments ?? <String, dynamic>{})) as Map,
        ),
      ));
      return true;
    },
  );
  final config = AppConfig()
    ..language = 'en'
    ..cardStyle = 'gray'
    ..menuStyle = 'gray'
    ..pillStyle = 'gray'
    ..nodeEditorElementLayout = 'list'
    ..nodeUsageCount = usageCounts ?? {'audioWaveform': 20, 'audioReverse': 10};
  store.hydrate(_snapshot(config, selected: selected));
  addTearDown(store.dispose);
  return store;
}

Future<void> _mount(
  WidgetTester tester,
  PanelWindowStore store,
  Widget child,
) async {
  tester.view.physicalSize = const Size(500, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: store.app,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _item(PipelineStepType type) =>
    find.byKey(ValueKey('detached-node-${type.name}'));

Future<void> _choose<T>(WidgetTester tester, String key, String label) async {
  final menu = find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(OptionMenuBar<T>),
  );
  await tester.ensureVisible(menu);
  await tester.pumpAndSettle();
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('DetachedNodeToolbox', () {
    testWidgets('should filter and sort real items then send one add request', (
      tester,
    ) async {
      final calls = <_HostCall>[];
      final store = _store(calls);
      await _mount(tester, store, DetachedNodeToolbox(store: store));
      for (final type in _newTypes.take(4)) {
        expect(_item(type), findsOneWidget);
      }
      expect(_item(PipelineStepType.videoReverse), findsNothing);
      expect(_item(PipelineStepType.videoFade), findsNothing);
      expect(
        tester.getTopLeft(_item(PipelineStepType.audioEqualizer)).dy,
        lessThan(tester.getTopLeft(_item(PipelineStepType.audioWaveform)).dy),
      );
      final category = tester.widget<AppDropdown<NodePickerCategory>>(
        find.byKey(const ValueKey('detached-node-category')),
      );
      expect(
        category.items.map((item) => item.value),
        isNot(contains(NodePickerCategory.container)),
      );
      await _choose<NodePickerSort>(tester, 'detached-node-sort', 'Most used');
      expect(
        tester.getTopLeft(_item(PipelineStepType.audioWaveform)).dy,
        lessThan(tester.getTopLeft(_item(PipelineStepType.audioEqualizer)).dy),
      );
      await tester.enterText(
        find.byKey(const ValueKey('detached-node-query')),
        'REVERSE',
      );
      await tester.pumpAndSettle();
      expect(_item(PipelineStepType.audioReverse), findsOneWidget);
      expect(_item(PipelineStepType.audioSpectrum), findsNothing);
      expect(_item(PipelineStepType.videoReverse), findsNothing);
      await _choose<NodePickerCategory>(
        tester,
        'detached-node-category',
        'Video',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('detached-node-query')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(_item(PipelineStepType.videoReverse), findsOneWidget);
      expect(_item(PipelineStepType.videoFade), findsOneWidget);
      expect(_item(PipelineStepType.audioReverse), findsNothing);
      final fade = _item(PipelineStepType.videoFade);
      await tester.ensureVisible(fade);
      await tester.pumpAndSettle();
      await tester.tap(fade);
      await tester.pump();
      expect(calls, hasLength(1));
      expect(calls.single.method, PanelMethod.addNode);
      expect(calls.single.args['typeId'], 'videoFade');
      expect(
        calls.single.args['nodeId'],
        isA<String>().having(
          (id) => id.isNotEmpty,
          'non-empty node ID',
          isTrue,
        ),
      );
      expect(store.config.nodeUsageCount, {
        'audioWaveform': 20,
        'audioReverse': 10,
      });
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'should sort gates by host usage and add through the existing protocol',
      (tester) async {
        final calls = <_HostCall>[];
        final store = _store(
          calls,
          usageCounts: {'gate:or': 20, 'gate:and': 1},
        );
        await _mount(tester, store, DetachedNodeToolbox(store: store));
        await _choose<NodePickerCategory>(
          tester,
          'detached-node-category',
          'Control & logic',
        );
        final gate = find.byKey(const ValueKey('detached-gate-and'));
        expect(gate, findsOneWidget);
        final orGate = find.byKey(const ValueKey('detached-gate-or'));
        expect(
          tester.getTopLeft(gate).dy,
          lessThan(tester.getTopLeft(orGate).dy),
        );
        await _choose<NodePickerSort>(
          tester,
          'detached-node-sort',
          'Most used',
        );
        expect(
          tester.getTopLeft(orGate).dy,
          lessThan(tester.getTopLeft(gate).dy),
        );
        expect(find.text('Host block'), findsNothing);
        expect(_item(PipelineStepType.audioSpectrum), findsNothing);
        await tester.ensureVisible(gate);
        await tester.pumpAndSettle();
        await tester.tap(gate);
        await tester.pump();
        expect(calls, hasLength(1));
        expect(calls.single.method, PanelMethod.graphAddGate);
        expect(calls.single.args['gate'], 'and');
        expect(calls.single.args['nodeId'], isNotEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Detached node properties', () {
    testWidgets('should select the shared form for each of the six new nodes', (
      tester,
    ) async {
      final calls = <_HostCall>[];
      final store = _store(calls);
      for (final (type, editorType) in const [
        (PipelineStepType.audioSpectrum, AudioSpectrumStepEditor),
        (PipelineStepType.audioWaveform, AudioWaveformStepEditor),
        (PipelineStepType.audioReverse, AudioReverseStepEditor),
        (PipelineStepType.audioEqualizer, AudioEqualizerStepEditor),
        (PipelineStepType.videoReverse, VideoReverseStepEditor),
        (PipelineStepType.videoFade, VideoFadeStepEditor),
      ]) {
        final node = PipelineNode(id: 'selected-${type.name}', type: type);
        await _mount(tester, store, buildDetachedNodeEditor(store, node));
        expect(find.byType(editorType), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(calls, isEmpty);
    });

    testWidgets(
      'should return equalizer slider edits with the selected node ID',
      (tester) async {
        final calls = <_HostCall>[];
        final store = _store(
          calls,
          selected: PipelineNode(
            id: 'equalizer-selected',
            type: PipelineStepType.audioEqualizer,
            params: {'bass_db': 0.0, 'mid_db': -2.0, 'treble_db': 1.5},
          ),
        );
        final node = store.selected!;
        await _mount(tester, store, buildDetachedNodeEditor(store, node));
        final bass = find.descendant(
          of: find.byKey(const ValueKey('equalizer_bass_db')),
          matching: find.byType(AppSlider),
        );
        await tester.ensureVisible(bass);
        await tester.pumpAndSettle();
        final rect = tester.getRect(bass);
        await tester.tapAt(
          Offset(rect.left + rect.width * 0.8, rect.center.dy),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(node.params['bass_db'], greaterThan(0));
        expect(calls, isNotEmpty);
        for (final call in calls) {
          expect(call.method, PanelMethod.setParams);
          expect(call.args['nodeId'], 'equalizer-selected');
        }
        final sent = calls.last.args['params'] as Map;
        expect(sent['bass_db'], node.params['bass_db']);
        expect(sent['mid_db'], -2);
        expect(sent['treble_db'], 1.5);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
