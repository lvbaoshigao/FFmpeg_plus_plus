import 'dart:async';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/quick_config_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:ffmpegpp_gui/services/quick_config_pipeline.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_volume_step_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

QuickConfig _config(QuickFileType type, [List<PipelineNode>? nodes]) =>
    QuickConfig(id: 'quick-test', fileType: type, nodes: nodes ?? []);

Future<void> _open(
  WidgetTester tester,
  QuickConfig config, {
  Future<void> Function(QuickConfig)? onSave,
  Future<void> Function(QuickConfig, PipelineGraph)? onExecute,
  Size size = const Size(1200, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final app = AppState();
  addTearDown(app.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<QuickConfig>(
                context: context,
                builder: (_) => QuickConfigPage(
                  config: config,
                  isZh: false,
                  onSave: onSave ?? (_) async {},
                  onExecute: onExecute,
                ),
              ),
              child: const Text('Open wizard'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open wizard'));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('serial quick configuration', () {
    test(
      'image-to-video accepts a single image and exposes video successors',
      () {
        final node = createQuickConfigNode(
          PipelineStepType.imageToVideo,
          MediaType.image,
        );
        expect(
          availableQuickNodeTypes(QuickFileType.image),
          contains(PipelineStepType.imageToVideo),
        );
        final types = availableQuickNodeTypes(
          QuickFileType.image,
          nodes: [node],
        );
        expect(types, contains(PipelineStepType.avProcess));
        expect(types, isNot(contains(PipelineStepType.imageCompress)));
        final cfg = _config(QuickFileType.image, [
          node,
          createQuickConfigNode(PipelineStepType.videoReverse, MediaType.video),
        ]);
        expect(
          GraphExecutor.validateGraph(
            buildGraphFromQuickConfig(cfg, isZh: false).graph,
          ),
          isEmpty,
        );
      },
    );

    test('multi-frame output only connects to an image-sequence consumer', () {
      for (final mode in ['all', 'range']) {
        final frame = createQuickConfigNode(
          PipelineStepType.frame,
          MediaType.video,
        )..params['extract_mode'] = mode;
        expect(availableQuickNodeTypes(QuickFileType.video, nodes: [frame]), [
          PipelineStepType.imageToVideo,
        ]);
        final invalid = _config(QuickFileType.video, [
          frame,
          createQuickConfigNode(
            PipelineStepType.imageBrightness,
            MediaType.image,
          ),
        ]);
        expect(
          validateQuickConfigNodes(invalid, isZh: false).join(),
          contains('produces a folder'),
        );
        expect(
          () => buildGraphFromQuickConfig(invalid, isZh: false),
          throwsFormatException,
        );
        final valid = _config(QuickFileType.video, [
          frame,
          createQuickConfigNode(PipelineStepType.imageToVideo, MediaType.image),
        ]);
        expect(validateQuickConfigNodes(valid), isEmpty);
        expect(
          buildGraphFromQuickConfig(valid, isZh: false).appliedKeys.length,
          2,
        );
      }
    });

    test(
      'unvisited crop nodes cannot compile until dimensions are configured',
      () {
        for (final type in [
          PipelineStepType.mediaCrop,
          PipelineStepType.videoCrop,
          PipelineStepType.imageCrop,
        ]) {
          final media = type == PipelineStepType.imageCrop
              ? MediaType.image
              : MediaType.video;
          final node = createQuickConfigNode(type, media);
          final cfg = _config(QuickFileType.values.byName(media.name), [node]);
          expect(validateQuickConfigParameters(cfg), isNotEmpty);
          expect(
            () => buildGraphFromQuickConfig(cfg, isZh: false),
            throwsFormatException,
          );
          node.params.addAll({'crop_w': 640, 'crop_h': 360});
          expect(validateQuickConfigParameters(cfg), isEmpty);
          expect(buildGraphFromQuickConfig(cfg, isZh: false).appliedKeys, [
            node.id,
          ]);
          node.params['crop_w'] = 0.5;
          expect(validateQuickConfigParameters(cfg), isNotEmpty);
          node.params['crop_w'] = 640;
          node.params['crop_h'] = 0.5;
          expect(validateQuickConfigParameters(cfg), isNotEmpty);
          node.params['crop_h'] = 360;
          node.params['crop_w'] = double.nan;
          expect(validateQuickConfigParameters(cfg), isNotEmpty);
        }
      },
    );

    test('native graph parameter validation also runs before saving', () {
      final node = createQuickConfigNode(PipelineStepType.clip, MediaType.video)
        ..params['start_time'] = -1.0;
      expect(
        () => buildGraphFromQuickConfig(
          _config(QuickFileType.video, [node]),
          isZh: false,
        ),
        throwsFormatException,
      );
    });

    test(
      'catalog follows every conversion and hides unsupported media and control nodes',
      () {
        final video = availableQuickNodeTypes(QuickFileType.video);
        expect(video, contains(PipelineStepType.avProcess));
        expect(video, isNot(contains(PipelineStepType.audioVolume)));
        expect(video, isNot(contains(PipelineStepType.start)));
        expect(video, isNot(contains(PipelineStepType.output)));
        expect(video, isNot(contains(PipelineStepType.unknown)));
        expect(video, isNot(contains(PipelineStepType.concatMedia)));
        final extract = createQuickConfigNode(
          PipelineStepType.extractAudio,
          MediaType.video,
        );
        final audio = availableQuickNodeTypes(
          QuickFileType.video,
          nodes: [extract],
        );
        expect(audio, contains(PipelineStepType.audioVolume));
        expect(audio, isNot(contains(PipelineStepType.avProcess)));
        expect(audio, isNot(contains(PipelineStepType.mediaCrop)));
        final spectrum = createQuickConfigNode(
          PipelineStepType.audioSpectrum,
          MediaType.audio,
        );
        final image = availableQuickNodeTypes(
          QuickFileType.video,
          nodes: [extract, spectrum],
        );
        expect(image, contains(PipelineStepType.imageCompress));
        expect(image, contains(PipelineStepType.mediaCrop));
        expect(image, isNot(contains(PipelineStepType.mediaOverlay)));
        expect(image, isNot(contains(PipelineStepType.audioVolume)));
      },
    );

    test(
      'generic candidates adopt the upstream type and reject unsupported kinds',
      () {
        final crop = createQuickConfigNode(
          PipelineStepType.mediaCrop,
          MediaType.image,
        );
        expect(crop.mediaKind, MediaType.image);
        expect(
          () => createQuickConfigNode(
            PipelineStepType.mediaCrop,
            MediaType.audio,
          ),
          throwsArgumentError,
        );
        expect(
          () => createQuickConfigNode(PipelineStepType.start, MediaType.video),
          throwsArgumentError,
        );
      },
    );

    test(
      'duplicate node types stay separate and execute in exact list order',
      () {
        final first = createQuickConfigNode(
          PipelineStepType.audioVolume,
          MediaType.audio,
        )..params['volume_db'] = -6.0;
        final second = createQuickConfigNode(
          PipelineStepType.audioVolume,
          MediaType.audio,
        )..params['volume_db'] = 3.0;
        final spectrum = createQuickConfigNode(
          PipelineStepType.audioSpectrum,
          MediaType.audio,
        );
        final rotate = createQuickConfigNode(
          PipelineStepType.imageRotate,
          MediaType.image,
        );
        final cfg = _config(QuickFileType.audio, [
          first,
          second,
          spectrum,
          rotate,
        ]);
        final result = buildGraphFromQuickConfig(cfg, isZh: false);
        expect(first.id, isNot(second.id));
        expect(result.appliedKeys, [
          first.id,
          second.id,
          spectrum.id,
          rotate.id,
        ]);
        expect(GraphExecutor.validateGraph(result.graph), isEmpty);
        final plan = GraphExecutor.resolvePlans(result.graph).single;
        expect(
          plan.steps.expand((step) => step.nodes).map((node) => node.id),
          result.appliedKeys,
        );
        expect(result.graph.connections.length, cfg.nodes!.length + 1);
        result.graph.nodes[1].params['volume_db'] = 99;
        expect(first.params['volume_db'], -6.0);
      },
    );

    test(
      'full-chain validation rejects invalid edits, logic gates and duplicate IDs',
      () {
        final extract = createQuickConfigNode(
          PipelineStepType.extractAudio,
          MediaType.video,
        );
        final volume = createQuickConfigNode(
          PipelineStepType.audioVolume,
          MediaType.audio,
        );
        final cfg = _config(QuickFileType.video, [volume, extract]);
        expect(validateQuickConfigNodes(cfg), isNotEmpty);
        expect(
          () => buildGraphFromQuickConfig(cfg, isZh: false),
          throwsFormatException,
        );
        cfg.nodes = [extract, volume];
        expect(validateQuickConfigNodes(cfg), isEmpty);
        volume.gateType = 'and';
        expect(validateQuickConfigNodes(cfg), isNotEmpty);
        volume.gateType = null;
        cfg.nodes = [extract, volume, volume.deepCopy()];
        expect(validateQuickConfigNodes(cfg).join(), contains('标识重复'));
      },
    );

    test(
      'graph restoration follows edges, preserves boundary parameters and clones nested values',
      () {
        final node =
            createQuickConfigNode(
                PipelineStepType.audioMetadata,
                MediaType.audio,
              )
              ..params['nested'] = {
                'list': [1, 2],
              };
        final cfg = _config(QuickFileType.audio, [node])
          ..inputParams = {'file_media_type': 'audio', 'node_name': 'Input'}
          ..outputParams = {
            'output_dir': '/keep/me',
            'output_format': 'flac',
            'filename': '{name}_done',
          };
        final graph = buildGraphFromQuickConfig(cfg, isZh: false).graph;
        graph.nodes.setAll(0, graph.nodes.reversed.toList());
        final restored = quickConfigFromGraph(
          graph: graph,
          fileType: QuickFileType.audio,
          id: 'restored',
        );
        expect(restored.id, 'restored');
        expect(restored.nodes!.single.id, node.id);
        expect(restored.inputParams, cfg.inputParams);
        expect(restored.outputParams, cfg.outputParams);
        final rebuilt = buildGraphFromQuickConfig(restored, isZh: false).graph;
        expect(rebuilt.nodes.last.params, cfg.outputParams);
        (restored.nodes!.single.params['nested']['list'] as List)[0] = 99;
        expect(node.params['nested']['list'], [1, 2]);
        expect(
          graph.nodes
              .firstWhere((n) => n.id == node.id)
              .params['nested']['list'],
          [1, 2],
        );
      },
    );

    test(
      'unsafe branch, disconnected, control, unknown and cyclic graphs cannot be flattened',
      () {
        final cfg = _config(QuickFileType.audio, [
          createQuickConfigNode(PipelineStepType.audioVolume, MediaType.audio),
        ]);
        final original = buildGraphFromQuickConfig(cfg, isZh: false).graph;
        final branch = original.deepCopy()
          ..connections.add(
            PipelineConnection(
              id: 'branch',
              fromNodeId: original.nodes.first.id,
              toNodeId: original.nodes.last.id,
            ),
          );
        final disconnected = original.deepCopy()
          ..nodes.add(
            PipelineNode(id: 'orphan', type: PipelineStepType.audioVolume),
          );
        final control = original.deepCopy();
        control.connections.first.kind = 'control';
        final gate = original.deepCopy();
        gate.nodes[1].gateType = 'and';
        final unknown = original.deepCopy();
        unknown.nodes[1].type = PipelineStepType.unknown;
        final cycle = original.deepCopy();
        cycle.connections.add(
          PipelineConnection(
            id: 'cycle',
            fromNodeId: cycle.nodes.last.id,
            toNodeId: cycle.nodes.first.id,
          ),
        );
        for (final graph in [
          branch,
          disconnected,
          control,
          gate,
          unknown,
          cycle,
        ]) {
          expect(
            () => quickConfigFromGraph(
              graph: graph,
              fileType: QuickFileType.audio,
            ),
            throwsFormatException,
          );
        }
        expect(
          quickConfigFromGraph(
            graph: PipelineGraph(),
            fileType: QuickFileType.audio,
          ).nodes,
          isEmpty,
        );
      },
    );

    test(
      'legacy items continue to compile and disabled items remain disabled',
      () {
        final legacy = QuickConfig.fromJson({
          'id': 'old',
          'file_type': 'audio',
          'items': [
            {
              'key': 'bitrate',
              'params': {'bitrate': '192k'},
            },
            {
              'key': 'sample_rate',
              'enabled': false,
              'params': {'rate': 48000},
            },
          ],
        });
        expect(legacy.nodes, isNull);
        final built = buildGraphFromQuickConfig(legacy, isZh: false);
        expect(built.appliedKeys, ['bitrate']);
        expect(built.graph.nodes[1].params['audio_bitrate'], 192);
        expect(built.graph.nodes[1].params, isNot(contains('sample_rate')));
      },
    );
  });

  testWidgets(
    'first page hides incompatible nodes and supports duplicate additions',
    (tester) async {
      final cfg = _config(QuickFileType.audio);
      QuickConfig? saved;
      await _open(
        tester,
        cfg,
        onSave: (updated) async {
          saved = updated;
        },
      );
      expect(find.byKey(const ValueKey('quick_pick_avProcess')), findsNothing);
      expect(find.byKey(const ValueKey('quick_pick_start')), findsNothing);
      await _tap(tester, const ValueKey('quick_pick_audioVolume'));
      await _tap(tester, const ValueKey('quick_pick_audioVolume'));
      expect(find.text('Sequence (2)'), findsOneWidget);
      await _tap(tester, const ValueKey('quick_save'));
      expect(saved!.nodes!.length, 2);
      expect(saved!.nodes!.first.id, isNot(saved!.nodes!.last.id));
      expect(cfg.nodes, isEmpty);
      expect(find.byType(QuickConfigPage), findsNothing);
    },
  );

  testWidgets(
    'clicking a row reuses the node editor and cancel leaves the original unchanged',
    (tester) async {
      final node = createQuickConfigNode(
        PipelineStepType.audioVolume,
        MediaType.audio,
      )..params['volume_db'] = -6.0;
      final cfg = _config(QuickFileType.audio, [node]);
      var saves = 0;
      await _open(
        tester,
        cfg,
        onSave: (_) async {
          saves++;
        },
      );
      await _tap(tester, ValueKey('quick_node_${node.id}'));
      expect(find.byType(AudioVolumeStepEditor), findsOneWidget);
      final editor = tester.widget<AudioVolumeStepEditor>(
        find.byType(AudioVolumeStepEditor),
      );
      editor.params['volume_db'] = -12.0;
      editor.onChanged();
      await tester.pump();
      await _tap(tester, const ValueKey('quick_close'));
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(node.params['volume_db'], -6.0);
    },
  );

  testWidgets(
    'reordering a conversion detects incompatible successors and blocks saving',
    (tester) async {
      final extract = createQuickConfigNode(
        PipelineStepType.extractAudio,
        MediaType.video,
      );
      final volume = createQuickConfigNode(
        PipelineStepType.audioVolume,
        MediaType.audio,
      );
      await _open(tester, _config(QuickFileType.video, [extract, volume]));
      await _tap(tester, ValueKey('quick_up_${volume.id}'));
      final save = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('quick_save')),
      );
      expect(save.onPressed, isNull);
      expect(find.textContaining('is incompatible with'), findsOneWidget);
      expect(find.byKey(const ValueKey('quick_pick_avProcess')), findsNothing);
      await _tap(tester, ValueKey('quick_down_${volume.id}'));
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('quick_save')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'save and queue waits for persistence, prevents duplicate clicks and forwards the same chain',
    (tester) async {
      final saved = Completer<void>();
      final events = <String>[];
      final node = createQuickConfigNode(
        PipelineStepType.audioVolume,
        MediaType.audio,
      );
      await _open(
        tester,
        _config(QuickFileType.audio, [node]),
        onSave: (_) {
          events.add('save');
          return saved.future;
        },
        onExecute: (updated, graph) async {
          events.add('queue');
          expect(updated.nodes!.single.id, node.id);
          expect(graph.nodes[1].id, node.id);
        },
      );
      await tester.tap(find.byKey(const ValueKey('quick_execute')));
      await tester.pump();
      expect(events, ['save']);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('quick_execute')))
            .onPressed,
        isNull,
      );
      saved.complete();
      await tester.pumpAndSettle();
      expect(events, ['save', 'queue']);
      expect(find.byType(QuickConfigPage), findsNothing);
    },
  );

  testWidgets('save failures stay editable without queuing', (tester) async {
    var queued = false;
    await _open(
      tester,
      _config(QuickFileType.audio, [
        createQuickConfigNode(PipelineStepType.audioVolume, MediaType.audio),
      ]),
      onSave: (_) async {
        throw StateError('storage unavailable');
      },
      onExecute: (_, _) async {
        queued = true;
      },
    );
    await _tap(tester, const ValueKey('quick_execute'));
    expect(find.textContaining('Could not save:'), findsOneWidget);
    expect(queued, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('quick_execute')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('unconfigured crop is editable but cannot save or queue', (
    tester,
  ) async {
    var saves = 0;
    var queues = 0;
    await _open(
      tester,
      _config(QuickFileType.image),
      onSave: (_) async {
        saves++;
      },
      onExecute: (_, _) async {
        queues++;
      },
    );
    await _tap(tester, const ValueKey('quick_pick_mediaCrop'));
    expect(
      find.textContaining('needs a positive width and height'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('quick_save')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('quick_execute')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('quick_next')))
          .onPressed,
      isNotNull,
    );
    await _tap(tester, const ValueKey('quick_next'));
    expect(find.text('2 · Configure nodes'), findsOneWidget);
    expect(saves, 0);
    expect(queues, 0);
  });

  testWidgets('selection and action footer fit a narrow viewport', (
    tester,
  ) async {
    await _open(
      tester,
      _config(QuickFileType.audio),
      size: const Size(390, 844),
    );
    await _tap(tester, const ValueKey('quick_pick_audioVolume'));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('quick_save')), findsOneWidget);
    final dialog = tester.getRect(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    expect(dialog.left, greaterThanOrEqualTo(16));
    expect(dialog.right, lessThanOrEqualTo(374));
  });
}
