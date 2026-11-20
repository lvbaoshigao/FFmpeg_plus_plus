import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/models/node_picker_options.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/multi_window.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_dropdown.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_reverse_step_editor.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

List<PipelineStepType> pickerOrder(WidgetTester tester, {Finder? scope}) {
  final items = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('node-picker-item-'),
  );
  final matches = scope == null
      ? items
      : find.descendant(of: scope, matching: items);
  return [
    for (final element in matches.evaluate())
      PipelineStepType.values.asNameMap()[(element.widget.key!
              as ValueKey<String>)
          .value
          .substring('node-picker-item-'.length)]!,
  ];
}

Future<AppState> openEditor(WidgetTester tester, {PipelineGraph? graph}) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState();
  state.config
    ..language = 'en'
    ..aiEnabled = false
    ..cardStyle = 'gray'
    ..menuStyle = 'gray'
    ..pillStyle = 'gray'
    ..nodeEditorElementLayout = 'list'
    ..nodeUsageCount = {};
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: PipelineEditorPage(
          video: VideoFile(id: 'picker-test', filename: 'Template'),
          initialGraph: graph,
          onSave: (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
  return state;
}

Future<void> closeEditor(WidgetTester tester, AppState state) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('NodePickerOptions', () {
    test('should place all six new nodes in their source media category', () {
      for (final type in [
        PipelineStepType.audioSpectrum,
        PipelineStepType.audioWaveform,
        PipelineStepType.audioReverse,
        PipelineStepType.audioEqualizer,
      ]) {
        expect(nodePickerCategoryFor(type), NodePickerCategory.audio);
        expect(nodePickerAudioTypes, contains(type));
      }
      for (final type in [
        PipelineStepType.videoReverse,
        PipelineStepType.videoFade,
      ]) {
        expect(nodePickerCategoryFor(type), NodePickerCategory.video);
        expect(nodePickerVideoTypes, contains(type));
      }
      expect(
        nodePickerCategoryFor(PipelineStepType.start),
        NodePickerCategory.control,
      );
      expect(nodePickerCategoryFor(PipelineStepType.unknown), isNull);
    });

    test(
      'should restrict bilingual search to the chosen category without duplicates',
      () {
        final types = [
          PipelineStepType.audioReverse,
          PipelineStepType.videoReverse,
          PipelineStepType.audioReverse,
          PipelineStepType.unknown,
        ];
        expect(
          selectNodePickerTypes(
            types,
            category: NodePickerCategory.audio,
            query: '  reverse  ',
          ),
          [PipelineStepType.audioReverse],
        );
        expect(
          selectNodePickerTypes(
            types,
            category: NodePickerCategory.video,
            query: PipelineNode(
              id: '',
              type: PipelineStepType.audioReverse,
            ).label,
          ),
          isEmpty,
        );
        expect(
          selectNodePickerTypes(
            types,
            category: NodePickerCategory.audio,
            query: PipelineNode(
              id: '',
              type: PipelineStepType.audioReverse,
            ).label,
          ),
          [PipelineStepType.audioReverse],
        );
        expect(types, hasLength(4));
      },
    );

    test('should use stable English A–Z regardless of catalog order', () {
      final types = List<PipelineStepType>.from(nodePickerAudioTypes)
        ..addAll(nodePickerVideoTypes);
      final expected = List<PipelineStepType>.from(types)
        ..sort(
          (a, b) => PipelineNode(id: '', type: a).labelEn
              .toLowerCase()
              .compareTo(PipelineNode(id: '', type: b).labelEn.toLowerCase()),
        );
      expect(selectNodePickerTypes(types), expected);
      expect(selectNodePickerTypes(types.reversed), expected);
    });

    test('should rank usage first and break ties by stable English names', () {
      final types = [
        PipelineStepType.audioWaveform,
        PipelineStepType.audioReverse,
        PipelineStepType.audioSpectrum,
      ];
      final counts = {
        'audioWaveform': 8,
        'audioReverse': 2,
        'audioSpectrum': 2,
      };
      final byName = selectNodePickerTypes(types);
      final byUsage = selectNodePickerTypes(
        types,
        sort: NodePickerSort.usage,
        usageCounts: counts,
      );
      expect(byUsage.first, PipelineStepType.audioWaveform);
      expect(
        byUsage.skip(1),
        byName.where((type) => type != PipelineStepType.audioWaveform),
      );
      counts.clear();
      expect(
        selectNodePickerTypes(
          types,
          sort: NodePickerSort.usage,
          usageCounts: counts,
        ),
        byName,
      );
      expect(types.first, PipelineStepType.audioWaveform);
    });
  });

  group('PipelineEditorPage node picker', () {
    const channel = MethodChannel('window_manager');
    setUp(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'isMaximized' ? false : null,
          ),
    );
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    testWidgets(
      'should filter only after category selection and preserve preview versus insertion counts',
      (tester) async {
        final state = await openEditor(tester);
        expect(
          tester
              .widget<ChoiceChip>(
                find.byKey(const ValueKey('node-picker-category-video')),
              )
              .selected,
          isTrue,
        );
        await tester.tap(
          find.byKey(const ValueKey('node-picker-category-audio')),
        );
        await tester.pump();
        final query = find.byKey(const ValueKey('node-picker-query'));
        await tester.ensureVisible(query);
        await tester.enterText(query, 'audioReverse');
        await tester.pump();
        expect(pickerOrder(tester), [PipelineStepType.audioReverse]);
        final item = find.byKey(
          const ValueKey('node-picker-item-audioReverse'),
        );
        await tester.ensureVisible(item);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Draggable<Object>>(item).data,
          PipelineStepType.audioReverse,
        );
        await tester.tap(item.hitTestable());
        await tester.pump(const Duration(milliseconds: 400));
        expect(state.config.nodeUsageCount, isEmpty);
        expect(find.byType(AudioReverseStepEditor), findsOneWidget);
        await tester.ensureVisible(item);
        await tester.pumpAndSettle();
        await tester.tap(item.hitTestable());
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(item.hitTestable());
        await tester.pump();
        expect(state.config.nodeUsageCount['audioReverse'], 1);
        state.mcpOnUndo!();
        state.mcpOnRedo!();
        expect(state.config.nodeUsageCount['audioReverse'], 1);
        await tester.ensureVisible(
          find.byKey(const ValueKey('node-picker-category-video')),
        );
        await tester.tap(
          find.byKey(const ValueKey('node-picker-category-video')),
        );
        await tester.pump();
        expect(tester.widget<TextField>(query).controller!.text, isEmpty);
        expect(
          pickerOrder(tester).every(
            (type) => nodePickerCategoryFor(type) == NodePickerCategory.video,
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await closeEditor(tester, state);
      },
    );

    testWidgets(
      'should refresh frequency sorting after mutating the existing usage map',
      (tester) async {
        final state = await openEditor(tester);
        await tester.tap(
          find.byKey(const ValueKey('node-picker-category-audio')),
        );
        await tester.pump();
        tester
            .widget<AppDropdown<NodePickerSort>>(
              find.byKey(const ValueKey('node-picker-sort')),
            )
            .onChanged!(NodePickerSort.usage);
        await tester.pump();
        state.config.nodeUsageCount['audioWaveform'] = 100;
        state.notifyListeners();
        await tester.pump();
        expect(pickerOrder(tester).first, PipelineStepType.audioWaveform);
        state.config.nodeUsageCount.clear();
        state.notifyListeners();
        await tester.pump();
        expect(
          pickerOrder(tester),
          selectNodePickerTypes(nodePickerAudioTypes),
        );
        expect(tester.takeException(), isNull);
        await closeEditor(tester, state);
      },
    );

    testWidgets(
      'should count successful control insertions once and sort by frequency',
      (tester) async {
        final state = await openEditor(
          tester,
          graph: PipelineGraph(
            nodes: [
              PipelineNode(
                id: 'source',
                type: PipelineStepType.start,
                x: 3000,
                y: 3000,
              ),
              PipelineNode(
                id: 'sink',
                type: PipelineStepType.output,
                x: 3300,
                y: 3000,
              ),
              PipelineNode(
                id: 'processor',
                type: PipelineStepType.audioReverse,
                x: 3150,
                y: 3150,
              ),
            ],
          ),
        );
        final host =
            tester.state(find.byType(PipelineEditorPage)) as PanelHostDelegate;
        final args = {
          'gate': 'and',
          'nodeId': 'control-new',
          'x': 3000,
          'y': 3000,
        };
        expect(
          await host.onPanelRequest(PanelMethod.graphAddGate, args),
          'control-new',
        );
        expect(
          await host.onPanelRequest(PanelMethod.graphAddGate, args),
          'control-new',
        );
        state.mcpOnAddGate!('and', 3000, 3000);
        state.mcpOnAddGate!('or', 3000, 3000);
        await tester.pumpAndSettle();
        expect(state.config.nodeUsageCount, {'gate:and': 2, 'gate:or': 1});
        expect(state.config.recentNodeTypes, isEmpty);
        state.mcpOnUndo!();
        state.mcpOnRedo!();
        expect(state.config.nodeUsageCount, {'gate:and': 2, 'gate:or': 1});
        await tester.tap(
          find.byKey(const ValueKey('node-picker-category-control')),
        );
        await tester.pumpAndSettle();
        tester
            .widget<AppDropdown<NodePickerSort>>(
              find.byKey(const ValueKey('node-picker-sort')),
            )
            .onChanged!(NodePickerSort.usage);
        await tester.pumpAndSettle();
        List<String> controlOrder(String prefix) => [
          for (final element
              in find
                  .byWidgetPredicate(
                    (widget) =>
                        widget.key is ValueKey<String> &&
                        (widget.key! as ValueKey<String>).value.startsWith(
                          prefix,
                        ),
                  )
                  .evaluate())
            (element.widget.key! as ValueKey<String>).value.substring(
              prefix.length,
            ),
        ];
        expect(controlOrder('node-picker-gate-').take(2), ['and', 'or']);
        final group = find.byKey(const ValueKey('node-picker-block-group'));
        await tester.ensureVisible(group);
        await tester.pumpAndSettle();
        await tester.tap(group.hitTestable());
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(group.hitTestable());
        await tester.pumpAndSettle();
        expect(
          find.text('Box-select elements on canvas to include'),
          findsOneWidget,
        );
        final canvas = tester.getRect(find.byType(InteractiveViewer));
        // Graph copies and undo/redo remap IDs; use the live public snapshot.
        final graph =
            host.panelSnapshot(DetachedPanel.elements)['graph'] as Map;
        final processorId = (graph['nodes'] as List)
            .map(
              (raw) =>
                  PipelineNode.fromJson(Map<String, dynamic>.from(raw as Map)),
            )
            .singleWhere((node) => node.type == PipelineStepType.audioReverse)
            .id;
        final processor = find.byKey(ValueKey('node-$processorId'));
        expect(processor, findsOneWidget);
        final selection = tester.getRect(processor).inflate(16);
        expect(canvas.contains(selection.topLeft), isTrue);
        expect(canvas.contains(selection.bottomRight), isTrue);
        final drag = await tester.startGesture(
          selection.topLeft,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await drag.moveTo(selection.bottomRight);
        await tester.pump();
        await drag.up();
        await tester.pumpAndSettle();
        expect(state.config.nodeUsageCount['block:group'], 1);
        expect(state.config.recentNodeTypes, isEmpty);
        expect(controlOrder('node-picker-block-').first, 'group');
        state.mcpOnUndo!();
        state.mcpOnRedo!();
        expect(state.config.nodeUsageCount['block:group'], 1);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await closeEditor(tester, state);
      },
    );

    testWidgets(
      'should refresh right-click category ordering after usage reset and add once',
      (tester) async {
        final state = await openEditor(tester);
        final canvas = tester.getRect(find.byType(InteractiveViewer));
        await tester.tapAt(
          canvas.topLeft + const Offset(80, 160),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('All elements...'));
        await tester.pumpAndSettle();
        final dialog = find.byKey(const ValueKey('node-picker-dialog'));
        expect(dialog, findsOneWidget);
        Finder inside(String key) =>
            find.descendant(of: dialog, matching: find.byKey(ValueKey(key)));
        await tester.tap(inside('node-picker-category-audio').hitTestable());
        await tester.pumpAndSettle();
        tester
            .widget<AppDropdown<NodePickerSort>>(inside('node-picker-sort'))
            .onChanged!(NodePickerSort.usage);
        await tester.pump();
        state.config.nodeUsageCount['audioWaveform'] = 10;
        state.notifyListeners();
        await tester.pump();
        expect(
          pickerOrder(tester, scope: dialog).first,
          PipelineStepType.audioWaveform,
        );
        state.config.favoriteNodeTypes.add('audioSpectrum');
        // Wait for AppState's async config notification before checking the route.
        await state.updateConfig((config) => config..nodeUsageCount = {});
        await tester.pumpAndSettle();
        expect(state.config.nodeUsageCount, isEmpty);
        expect(pickerOrder(tester, scope: dialog), [
          PipelineStepType.audioSpectrum,
          ...selectNodePickerTypes(
            nodePickerAudioTypes,
          ).where((type) => type != PipelineStepType.audioSpectrum),
        ]);
        expect(state.config.favoriteNodeTypes, contains('audioSpectrum'));
        final item = inside('node-picker-item-audioSpectrum');
        await tester.ensureVisible(item);
        await tester.pumpAndSettle();
        await tester.tap(item.hitTestable());
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(state.config.nodeUsageCount, {'audioSpectrum': 1});
        expect(tester.takeException(), isNull);
        await closeEditor(tester, state);
      },
    );

    testWidgets(
      'should expose image processing after audio visualization and count detached insert once',
      (tester) async {
        final state = await openEditor(
          tester,
          graph: PipelineGraph(
            nodes: [
              PipelineNode(
                id: 'imported',
                type: PipelineStepType.audioSpectrum,
              ),
            ],
          ),
        );
        expect(state.config.nodeUsageCount, isEmpty);
        await tester.tap(
          find.byTooltip('Only show elements usable for this file'),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('node-picker-category-image')),
        );
        await tester.pump();
        expect(pickerOrder(tester), contains(PipelineStepType.imageBrightness));
        final host =
            tester.state(find.byType(PipelineEditorPage)) as PanelHostDelegate;
        final descriptors =
            host.panelSnapshot(DetachedPanel.elements)['toolbox'] as List;
        final gates = descriptors
            .where((item) => item['kind'] == 'gate')
            .toList();
        expect(gates.length, LogicGateType.values.length);
        expect(gates.every((item) => item['group'] == 'control'), isTrue);
        final args = {
          'typeId': 'audioWaveform',
          'nodeId': 'detached-new',
          'x': 3000,
          'y': 3000,
        };
        expect(
          await host.onPanelRequest(PanelMethod.addNode, args),
          'detached-new',
        );
        expect(
          await host.onPanelRequest(PanelMethod.addNode, args),
          'detached-new',
        );
        expect(state.config.nodeUsageCount, {'audioWaveform': 1});
        expect(
          await host.onPanelRequest(PanelMethod.addNode, {
            'typeId': 'not-a-type',
          }),
          isFalse,
        );
        expect(state.config.nodeUsageCount, {'audioWaveform': 1});
        state.mcpOnUndo!();
        state.mcpOnRedo!();
        expect(state.config.nodeUsageCount, {'audioWaveform': 1});
        await tester.pump();
        expect(tester.takeException(), isNull);
        await closeEditor(tester, state);
      },
    );
  });
}
