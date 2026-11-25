import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:ffmpegpp_gui/services/quick_config_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

PipelineNode _node(
  String id,
  PipelineStepType type, [
  Map<String, dynamic> params = const {},
]) => PipelineNode(id: id, type: type, params: params);

ExecutionPlan _plan(
  List<PipelineNode> nodes, {
  Map<String, dynamic> outputParams = const {},
}) {
  final result = buildGraphFromQuickConfig(
    QuickConfig(
      id: 'serial',
      fileType: QuickFileType.video,
      nodes: nodes,
      outputParams: outputParams,
    ),
    isZh: false,
  );
  expect(GraphExecutor.validateGraph(result.graph), isEmpty);
  return GraphExecutor.resolvePlans(result.graph).single;
}

String _output(ExecutionPlan plan) => GraphExecutor.resolveOutputPath(
  plan,
  VideoFile(id: 'video', filepath: '/source/movie.mp4', filename: 'movie.mp4'),
  AppConfig(defaultOutputDir: '/out'),
);

List<BackendCall> _processing(ExecutionPlan plan, String output) {
  final calls = GraphExecutor.buildBackendCalls(
    plan,
    '/source/movie.mp4',
    output,
  );
  expect(calls, isNotNull, reason: plan.warnings.join('; '));
  return calls!.where((call) => call.action != '_cleanup').toList();
}

void main() {
  group('Serial frame extraction output', () {
    for (final format in ['png', 'jpg', 'webp']) {
      for (final outputFormat in ['keep', 'mp4']) {
        test(
          'retains $format through image edits with $outputFormat output',
          () {
            final outputParams = {
              'format': outputFormat,
              'output_dir': '/custom',
              'naming_mode': 'suffix',
              'naming_value': '_cover',
            };
            final plan = _plan([
              _node('frame', PipelineStepType.frame, {
                'extract_mode': 'single',
                'output_format': format,
                'time': 1.0,
              }),
              _node('scale', PipelineStepType.mediaScale, {
                'media_type': 'image',
                'scale_factor': 0.5,
              }),
              _node('brightness', PipelineStepType.imageBrightness, {
                'brightness': 0.1,
              }),
            ], outputParams: outputParams);
            final output = _output(plan);
            expect(output, '/custom/movie_cover.$format');
            expect(plan.outputNode!.params, outputParams);
            final calls = _processing(plan, output);
            expect(calls.map((call) => call.action), [
              'extract_frame',
              'image_scale',
              'image_brightness',
            ]);
            expect(calls.first.params['input'], '/source/movie.mp4');
            for (var i = 0; i < calls.length; i++) {
              expect(calls[i].params['output'], endsWith('.$format'));
              if (i > 0) {
                expect(calls[i].params['input'], calls[i - 1].params['output']);
              }
            }
            expect(calls.last.params['output'], output);
          },
        );
      }
    }

    test('defaults single-frame output to PNG before a later image edit', () {
      final plan = _plan([
        _node('frame', PipelineStepType.frame),
        _node('brightness', PipelineStepType.imageBrightness, {
          'brightness': 0.1,
        }),
      ]);
      final output = _output(plan);
      expect(output, '/out/movie.png');
      final calls = _processing(plan, output);
      expect(calls.first.params['output'], endsWith('.png'));
      expect(calls.last.params['input'], calls.first.params['output']);
      expect(calls.last.params['output'], output);
    });

    for (final conversion in [
      PipelineStepType.mediaConvert,
      PipelineStepType.imageCompress,
    ]) {
      test('uses later $conversion format through subsequent image edits', () {
        final plan = _plan([
          _node('frame', PipelineStepType.frame, {'output_format': 'png'}),
          _node('convert', conversion, {
            if (conversion == PipelineStepType.mediaConvert)
              'media_type': 'image',
            'output_format': 'webp',
            'quality': 80,
          }),
          _node('brightness', PipelineStepType.imageBrightness, {
            'brightness': 0.1,
          }),
        ]);
        final output = _output(plan);
        expect(output, '/out/movie.webp');
        final calls = _processing(plan, output);
        expect(calls[0].params['output'], endsWith('.png'));
        expect(calls[1].params['input'], calls[0].params['output']);
        expect(calls[1].params['output'], endsWith('.webp'));
        expect(calls[2].params['input'], calls[1].params['output']);
        expect(calls[2].params['output'], output);
      });
    }

    test(
      'keeps explicit video output after synthesizing a frame into video',
      () {
        final plan = _plan(
          [
            _node('frame', PipelineStepType.frame, {'output_format': 'jpg'}),
            _node('synthesis', PipelineStepType.imageToVideo, {
              'output_format': 'mp4',
              'framerate': 30.0,
            }),
            _node('encode', PipelineStepType.avProcess),
          ],
          outputParams: {'format': 'mkv'},
        );
        final output = _output(plan);
        expect(output, '/out/movie.mkv');
        final calls = _processing(plan, output);
        expect(calls[0].params['output'], endsWith('.jpg'));
        expect(calls[1].params['input'], calls[0].params['output']);
        expect(calls[1].params['output'], endsWith('.mp4'));
        expect(calls[2].params['input'], calls[1].params['output']);
        expect(calls[2].params['output'], output);
      },
    );
  });
}
