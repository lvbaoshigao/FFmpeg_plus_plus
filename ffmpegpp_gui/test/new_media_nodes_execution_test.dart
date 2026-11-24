import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/audio_visualization.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:ffmpegpp_gui/services/task_process_runner.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FinishedProcess implements Process {
  _FinishedProcess(this.code);
  final int code;
  @override
  int get pid => 123;
  @override
  Future<int> get exitCode async => code;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => code == 0
      ? const Stream.empty()
      : Stream.value(utf8.encode('test failure'));
  @override
  IOSink get stdin =>
      throw UnsupportedError('No stdin for a completed process');
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

PipelineGraph _graph(
  List<PipelineNode> operations, {
  String media = 'audio',
  Map<String, dynamic> outputParams = const {},
}) {
  final nodes = [
    PipelineNode(
      id: 'source',
      type: PipelineStepType.start,
      params: {'file_media_type': media},
    ),
    ...operations,
    PipelineNode(
      id: 'output',
      type: PipelineStepType.output,
      params: outputParams,
    ),
  ];
  return PipelineGraph(
    nodes: nodes,
    connections: [
      for (var i = 1; i < nodes.length; i++)
        PipelineConnection(
          id: 'c$i',
          fromNodeId: nodes[i - 1].id,
          toNodeId: nodes[i].id,
        ),
    ],
  );
}

PipelineNode _node(
  PipelineStepType type, {
  String id = 'operation',
  Map<String, dynamic> params = const {},
}) => PipelineNode(id: id, type: type, params: params);

List<BackendCall> _calls(
  PipelineGraph graph, {
  String input = '/tmp/source.wav',
  String output = '/tmp/result.png',
}) {
  expect(GraphExecutor.validateGraph(graph), isEmpty);
  final plan = GraphExecutor.resolvePlans(graph).single;
  final calls = GraphExecutor.buildBackendCalls(plan, input, output);
  expect(calls, isNotNull, reason: plan.warnings.join('; '));
  return calls!;
}

const _visualizers = [
  PipelineStepType.audioSpectrum,
  PipelineStepType.audioWaveform,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GraphExecutor new media nodes', () {
    for (final type in _visualizers) {
      for (final (requested, extension) in [
        ('png', 'png'),
        ('jpg', 'jpg'),
        ('JPEG', 'jpg'),
        ('webp', 'webp'),
      ]) {
        test('should plan $type as one $extension image', () {
          final graph = _graph(
            [
              _node(
                type,
                params: {
                  'width': 320,
                  'height': 192,
                  'output_format': requested,
                },
              ),
            ],
            outputParams: {'format': 'mp4'},
          );
          final plan = GraphExecutor.resolvePlans(graph).single;
          final output = GraphExecutor.resolveOutputPath(
            plan,
            VideoFile(
              id: 'v',
              filepath: '/source/song.wav',
              filename: 'song.wav',
              fileMediaType: MediaType.audio,
            ),
            AppConfig(defaultOutputDir: '/out'),
          );
          expect(
            output.replaceAll(r'\', '/'),
            '/out/song${type == PipelineStepType.audioSpectrum ? '_spectrum' : '_waveform'}.$extension',
          );
          final call = _calls(graph, output: output).single;
          expect(
            call.action,
            type == PipelineStepType.audioSpectrum
                ? 'audio_spectrum'
                : 'audio_waveform',
          );
          expect(call.params['output'], output);
          expect(call.params['width'], 320);
          expect(call.params['height'], 192);
          expect(call.params['output_format'], extension);
        });
      }
    }

    test(
      'should retain the actual image suffix through chained operations and cleanup',
      () {
        final graph = _graph([
          _node(
            PipelineStepType.audioSpectrum,
            id: 'spectrum',
            params: {'output_format': 'jpeg'},
          ),
          _node(
            PipelineStepType.imageScale,
            id: 'scale',
            params: {'scale_factor': 0.5},
          ),
          _node(
            PipelineStepType.imageCompress,
            id: 'compress',
            params: {'output_format': 'webp'},
          ),
        ]);
        final calls = _calls(graph, output: '/tmp/final.webp');
        final processing = calls
            .where((call) => call.action != '_cleanup')
            .toList();
        final paths = processing
            .take(2)
            .map((call) => call.params['output'])
            .toList();
        expect(paths, everyElement(endsWith('.jpg')));
        expect(processing[1].params['input'], paths[0]);
        expect(processing[2].params['input'], paths[1]);
        expect(processing.last.params['output'], '/tmp/final.webp');
        expect(
          calls
              .where((call) => call.action == '_cleanup')
              .map((call) => call.params['path']),
          unorderedEquals(paths),
        );
        final other = _calls(graph, output: '/tmp/final.webp');
        expect(other.first.params['output'], isNot(paths.first));
      },
    );

    test('should reject image-only input to an audio visualization', () {
      expect(
        GraphExecutor.validateGraph(
          _graph([_node(PipelineStepType.audioSpectrum)], media: 'image'),
        ),
        isNotEmpty,
      );
    });

    for (final type in [
      PipelineStepType.audioReverse,
      PipelineStepType.audioEqualizer,
    ]) {
      test('should encode $type for the actual audio output container', () {
        final call = _calls(
          _graph([_node(type)]),
          input: '/tmp/song.mp3',
          output: '/tmp/reversed.wav',
        ).single;
        final options = call.params['options'] as Map<String, dynamic>;
        expect(call.action, 'transcode');
        expect(options['video_codec'], 'none');
        expect(options['audio_codec'], 'pcm_s16le');
        expect(options['af_filters'], isNotEmpty);
        if (type == PipelineStepType.audioReverse) {
          expect(options['af_filters'], ['areverse', 'asetpts=PTS-STARTPTS']);
        }
      });
    }

    test(
      'should clamp three EQ bands and ignore non-numeric filter fragments',
      () {
        final call = _calls(
          _graph([
            _node(
              PipelineStepType.audioEqualizer,
              params: {
                'bass_db': -999,
                'mid_db': double.infinity,
                'treble_db': '1;amovie=bad',
              },
            ),
          ]),
          output: '/tmp/result.flac',
        ).single;
        final options = call.params['options'] as Map<String, dynamic>;
        expect(options['audio_codec'], 'flac');
        expect(options['af_filters'], [
          'equalizer=f=100:t=o:w=1:g=-12.00',
          'equalizer=f=1000:t=o:w=1:g=0.00',
          'equalizer=f=8000:t=o:w=1:g=0.00',
        ]);
      },
    );

    test('should reverse video and audio together with timestamps reset', () {
      final call = _calls(
        _graph([_node(PipelineStepType.videoReverse)], media: 'video'),
        input: '/tmp/source.mp4',
        output: '/tmp/reversed.mp4',
      ).single;
      final options = call.params['options'] as Map<String, dynamic>;
      expect(options['vf_filters'], ['reverse', 'setpts=PTS-STARTPTS']);
      expect(options['af_filters'], ['areverse', 'asetpts=PTS-STARTPTS']);
      expect(options['audio_codec'], 'aac');
    });

    test(
      'should defer video fade timing until the actual input is available',
      () {
        final call = _calls(
          _graph([_node(PipelineStepType.videoFade)], media: 'video'),
          input: '/tmp/clip.mp4',
          output: '/tmp/faded.mp4',
        ).single;
        expect(call.action, 'video_fade');
        expect(call.params['fade_in'], 2);
        expect(call.params['fade_out'], 2);
        expect(call.params['fade_out_start'], 0);
        expect(GraphExecutor.videoFadeFilters(call.params, duration: 5), [
          'fade=t=in:st=0:d=2.000',
          'fade=t=out:st=3.000:d=2.000',
        ]);
        expect(GraphExecutor.videoFadeFilters(call.params, duration: 0.5), [
          'fade=t=in:st=0:d=0.500',
          'fade=t=out:st=0.000:d=0.500',
        ]);
        expect(
          () => GraphExecutor.videoFadeFilters(call.params),
          throwsFormatException,
        );
        expect(
          GraphExecutor.videoFadeFilters({
            'fade_in': 0,
            'fade_out': 1,
            'fade_out_start': 4,
          }),
          ['fade=t=out:st=4.000:d=1.000'],
        );
        expect(
          GraphExecutor.videoFadeFilters({'fade_in': 0, 'fade_out': 0}),
          isEmpty,
        );
      },
    );
  });

  group('New media execution review boundaries', () {
    late Directory directory;
    setUp(() {
      directory = Directory.systemTemp.createTempSync('ffmpegpp_node_review_');
    });
    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    String resolved(PipelineGraph graph) => GraphExecutor.resolveOutputPath(
      GraphExecutor.resolvePlans(graph).single,
      VideoFile(
        id: 'v',
        filepath: '${directory.path}/song.wav',
        filename: 'song.wav',
        fileMediaType: MediaType.audio,
      ),
      AppConfig(defaultOutputDir: directory.path),
    );

    test('should preserve covers and distinguish default visualizer names', () {
      final cover = File('${directory.path}/song.png')
        ..writeAsStringSync('cover');
      final spectrum = _graph([_node(PipelineStepType.audioSpectrum)]);
      final waveform = _graph([_node(PipelineStepType.audioWaveform)]);
      expect(
        File(resolved(spectrum)).uri,
        directory.uri.resolve('song_spectrum.png'),
      );
      expect(
        File(resolved(waveform)).uri,
        directory.uri.resolve('song_waveform.png'),
      );
      File(resolved(spectrum)).writeAsStringSync('existing spectrum');
      expect(
        File(resolved(spectrum)).uri,
        directory.uri.resolve('song_spectrum_2.png'),
      );
      expect(cover.readAsStringSync(), 'cover');
    });

    test('should reserve the true final suffix and respect explicit names', () {
      final graph = _graph(
        [
          _node(PipelineStepType.audioSpectrum, id: 'viz'),
          _node(
            PipelineStepType.imageConvert,
            id: 'convert',
            params: {'output_format': 'webp'},
          ),
        ],
        outputParams: {'naming_mode': 'custom', 'naming_value': 'cover.jpg'},
      );
      final output = resolved(graph);
      expect(File(output).uri, directory.uri.resolve('cover.webp'));
      final call = _calls(
        graph,
        output: output,
      ).where((call) => call.action != '_cleanup').last;
      expect(call.params['output'], output);
      expect(
        File(AudioVisualization.uniqueOutput(output, [output])).uri,
        directory.uri.resolve('cover_2.webp'),
      );
      File(output).writeAsStringSync('existing');
      expect(File(resolved(graph)).uri, directory.uri.resolve('cover_2.webp'));
    });

    test('should retain explicit video container after image synthesis', () {
      final graph = _graph(
        [
          _node(PipelineStepType.audioWaveform, id: 'wave'),
          _node(PipelineStepType.imageToVideo, id: 'movie'),
          _node(PipelineStepType.videoFade, id: 'fade'),
        ],
        outputParams: {'format': 'mkv'},
      );
      final output = resolved(graph);
      expect(output, endsWith('.mkv'));
      expect(
        _calls(
          graph,
          output: output,
        ).where((c) => c.action != '_cleanup').last.params['output'],
        output,
      );
    });

    test('should use compatible WebM codecs at both stages of a chain', () {
      for (final finalFormat in ['webm', 'mp4']) {
        final graph = _graph([
          _node(PipelineStepType.videoReverse, id: 'reverse'),
          _node(PipelineStepType.videoFade, id: 'fade'),
        ], media: 'video');
        final calls = _calls(
          graph,
          input: '/source/in.webm',
          output: '/output/out.$finalFormat',
        ).where((call) => call.action != '_cleanup').toList();
        final first = calls.first.params['options'] as Map;
        final last = calls.last.params['options'] as Map;
        expect(first['video_codec'], 'libvpx-vp9');
        expect(first['audio_codec'], 'libopus');
        expect(
          last['video_codec'],
          finalFormat == 'webm' ? 'libvpx-vp9' : 'h264',
        );
        expect(last['audio_codec'], finalFormat == 'webm' ? 'libopus' : 'aac');
      }
    });

    test('should normalize raw numeric strings and padded format values', () {
      final config = AudioVisualization.fromParams({
        'width': '640',
        'height': ' 480 ',
        'output_format': ' WEBP ',
      });
      expect((config.width, config.height, config.format), (640, 480, 'webp'));
      final eq = _calls(
        _graph([
          _node(
            PipelineStepType.audioEqualizer,
            params: {'bass_db': ' 6 ', 'mid_db': '-2.5', 'treble_db': '20'},
          ),
        ]),
        output: '/tmp/output.ac3',
      ).single;
      final opts = eq.params['options'] as Map;
      expect(opts['audio_codec'], 'ac3');
      expect(opts['af_filters'], [
        'equalizer=f=100:t=o:w=1:g=6.00',
        'equalizer=f=1000:t=o:w=1:g=-2.50',
        'equalizer=f=8000:t=o:w=1:g=12.00',
      ]);
      expect(
        GraphExecutor.videoFadeFilters({
          'fade_in': '0',
          'fade_out': '0.5',
        }, duration: 1),
        ['fade=t=out:st=0.500:d=0.500'],
      );
    });

    test(
      'should use video stream duration and preserve all reversed audio offsets',
      () {
        final timeline = VideoTimeline.fromProbe({
          'format': {'duration': '4'},
          'streams': [
            {
              'index': 0,
              'codec_type': 'video',
              'start_time': '0',
              'duration': '1',
            },
            {
              'index': 1,
              'codec_type': 'audio',
              'start_time': '0.1',
              'duration': '0.4',
            },
            {
              'index': 2,
              'codec_type': 'audio',
              'start_time': '0.4',
              'duration': '0.3',
            },
          ],
        });
        expect(timeline.videoDuration, 1);
        final args = timeline.reverseArguments(
          input: '/tmp/in.mkv',
          output: '/tmp/out.webm',
          options: GraphExecutor.videoOptionsForPath('/tmp/out.webm'),
        );
        final graph = args[args.indexOf('-filter_complex') + 1];
        expect(
          graph,
          contains('[0:1]areverse,asetpts=PTS-STARTPTS+0.500000/TB[a0]'),
        );
        expect(
          graph,
          contains('[0:2]areverse,asetpts=PTS-STARTPTS+0.300000/TB[a1]'),
        );
        expect(
          args,
          containsAllInOrder(['-map', '[v]', '-map', '[a0]', '-map', '[a1]']),
        );
        final unknown = VideoTimeline.fromProbe({
          'streams': [
            {'index': 0, 'codec_type': 'video'},
          ],
        });
        expect(
          () => unknown.reverseArguments(
            input: 'in.mkv',
            output: 'out.mkv',
            options: {},
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'should exclusively publish and preserve an output occupied after planning',
      () async {
        final staged = File('${directory.path}/private.png')
          ..writeAsStringSync('new');
        final destination = AudioVisualization.uniqueOutput(
          '${directory.path}/public.png',
          [],
        );
        final sentinel = File(destination)..writeAsStringSync('late cover');
        await expectLater(
          AudioVisualization.publish(staged.path, destination),
          throwsA(isA<FileSystemException>()),
        );
        expect(sentinel.readAsStringSync(), 'late cover');
        final cancelled = '${directory.path}/cancelled.png';
        var checks = 0;
        await expectLater(
          AudioVisualization.publish(
            staged.path,
            cancelled,
            checkCancelled: () {
              if (++checks == 2) throw const TaskProcessCancelled();
            },
          ),
          throwsA(isA<TaskProcessCancelled>()),
        );
        expect(File(cancelled).existsSync(), isFalse);
      },
    );
  });

  group('AppState protected visualization outputs', () {
    late Directory directory;
    setUp(() {
      directory = Directory.systemTemp.createTempSync(
        'ffmpegpp_viz_protection_',
      );
    });
    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    test(
      'should reserve final formats across repeated queues and same stems',
      () {
        final state = AppState()
          ..setTaskProcessRunnerForTest(TaskProcessRunner());
        addTearDown(state.dispose);
        state.config.defaultOutputDir = directory.path;
        final graph = _graph([
          _node(PipelineStepType.audioSpectrum, id: 'spectrum'),
          _node(
            PipelineStepType.imageConvert,
            id: 'convert',
            params: {'output_format': 'webp'},
          ),
        ]);
        for (final parent in ['one', 'one', 'two']) {
          state.addGraphTasksForTest(
            VideoFile(
              id: parent,
              filepath: '${directory.path}/$parent/song.wav',
              filename: 'song.wav',
              fileMediaType: MediaType.audio,
              pipelineGraph: graph,
            ),
          );
        }
        expect(state.tasks.map((task) => File(task.outputPath).uri), [
          directory.uri.resolve('song_spectrum.webp'),
          directory.uri.resolve('song_spectrum_2.webp'),
          directory.uri.resolve('song_spectrum_3.webp'),
        ]);
        for (final task in state.tasks) {
          expect(
            task.pipelineCalls!
                .where((c) => c.action != '_cleanup')
                .last
                .params['output'],
            task.outputPath,
          );
        }
      },
    );

    for (final lateArrival in [false, true]) {
      test(
        'should preserve a target occupied ${lateArrival ? "during execution" : "after queuing"}',
        () async {
          final target = '${directory.path}/output.png';
          final finished = Completer<TaskStatus>();
          var launches = 0;
          final state = AppState()
            ..setTaskProcessRunnerForTest(
              TaskProcessRunner(
                starter: (_, args) async {
                  launches++;
                  File(target).writeAsStringSync('late user file');
                  File(args.last).writeAsStringSync('new private output');
                  return _FinishedProcess(0);
                },
              ),
            )
            ..onTaskFinished = (_, status) => finished.complete(status);
          addTearDown(state.dispose);
          state.addTaskForTest(
            TaskInfo(
              id: 'late',
              videoId: 'v',
              filename: 'in.wav',
              inputPath: '${directory.path}/input.wav',
              outputPath: target,
              config: TranscodeConfig(),
              pipelineCalls: [
                BackendCall(
                  action: 'audio_spectrum',
                  params: {
                    'input': '${directory.path}/input.wav',
                    'output': target,
                  },
                ),
              ],
            ),
          );
          if (!lateArrival) File(target).writeAsStringSync('late user file');
          await state.processNextTask();
          expect(
            await finished.future.timeout(const Duration(seconds: 5)),
            TaskStatus.failed,
          );
          expect(File(target).readAsStringSync(), 'late user file');
          expect(launches, lateArrival ? 1 : 0);
        },
      );
    }

    test(
      'should never cleanup a pre-existing public loop intermediate on failure',
      () async {
        final target = '${directory.path}/output.png';
        final oldLoop = File('${directory.path}/output_loop_1.png')
          ..writeAsStringSync('old user image');
        final finished = Completer<TaskStatus>();
        final state = AppState()
          ..setTaskProcessRunnerForTest(
            TaskProcessRunner(starter: (_, args) async => _FinishedProcess(1)),
          )
          ..onTaskFinished = (_, status) => finished.complete(status);
        addTearDown(state.dispose);
        state.addTaskForTest(
          TaskInfo(
            id: 'loop',
            videoId: 'v',
            filename: 'in.wav',
            inputPath: '${directory.path}/in.wav',
            outputPath: target,
            config: TranscodeConfig(),
            pipelineCalls: [
              BackendCall(
                action: 'audio_spectrum',
                loopCount: 2,
                blockId: 'loop',
                params: {'input': '${directory.path}/in.wav', 'output': target},
              ),
            ],
          ),
        );
        await state.processNextTask();
        expect(
          await finished.future.timeout(const Duration(seconds: 5)),
          TaskStatus.failed,
        );
        expect(oldLoop.readAsStringSync(), 'old user image');
        expect(File(target).existsSync(), isFalse);
      },
    );

    test('should reject duplicate new types in a parallel execution step', () {
      final one = _node(PipelineStepType.audioSpectrum, id: 'one');
      final two = _node(PipelineStepType.audioSpectrum, id: 'two');
      final graph = _graph([one, two]);
      final plan = ExecutionPlan(
        startNode: graph.nodes.first,
        graph: graph,
        steps: [
          ExecutionStep('audio_spectrum', [one, two]),
        ],
      );
      expect(
        GraphExecutor.buildBackendCalls(plan, 'in.wav', 'out.png'),
        isNull,
      );
      expect(plan.warnings.join(), contains('并行'));
    });
  });

  group('Delayed video and directory planning', () {
    test(
      'should apply fades relative to delayed video and preserve ten-bit output',
      () {
        final timeline = VideoTimeline.fromProbe({
          'format': {'start_time': '0'},
          'streams': [
            {
              'index': 0,
              'codec_type': 'video',
              'start_time': '0.5',
              'duration': '1',
              'pix_fmt': 'yuv420p10le',
            },
            {
              'index': 1,
              'codec_type': 'audio',
              'start_time': '0',
              'duration': '4',
            },
          ],
        });
        final filters = GraphExecutor.videoFadeFilters(
          {'fade_in': '.25', 'fade_out': '.25'},
          duration: timeline.videoDuration,
          startTime: timeline.videoFilterStart,
        );
        expect(filters, [
          'fade=t=in:st=0.500:d=0.250',
          'fade=t=out:st=1.250:d=0.250',
        ]);
        final args = VideoTimeline.fadeArguments(
          input: 'in.mkv',
          output: 'out.webm',
          filters: filters,
          options: GraphExecutor.videoOptionsForPath('out.webm'),
          sourcePixelFormat: timeline.pixelFormat,
        );
        expect(args[args.indexOf('-pix_fmt') + 1], 'yuv420p10le');
      },
    );

    test('should reserve and rewrite frame-directory outputs consistently', () {
      final dir = Directory.systemTemp.createTempSync('ffmpegpp_viz_dirs_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final graph = _graph([
        _node(PipelineStepType.audioWaveform, id: 'wave'),
        _node(PipelineStepType.imageToVideo, id: 'video'),
        _node(
          PipelineStepType.frame,
          id: 'frames',
          params: {'extract_mode': 'all'},
        ),
      ]);
      final state = AppState()
        ..setTaskProcessRunnerForTest(TaskProcessRunner());
      addTearDown(state.dispose);
      state.config.defaultOutputDir = dir.path;
      for (var i = 0; i < 2; i++) {
        state.addGraphTasksForTest(
          VideoFile(
            id: 'v',
            filepath: '${dir.path}/tone.wav',
            filename: 'tone.wav',
            fileMediaType: MediaType.audio,
            pipelineGraph: graph,
          ),
        );
      }
      expect(state.tasks, hasLength(2));
      expect(state.tasks[0].outputPath, isNot(state.tasks[1].outputPath));
      for (final task in state.tasks) {
        final last = task.pipelineCalls!.lastWhere(
          (call) => call.action != '_cleanup',
        );
        expect(last.params['output_dir'], task.outputPath);
      }
    });
  });

  group('AudioVisualization safe argv', () {
    test(
      'should bound dimensions and normalize malformed imported parameters',
      () {
        final bounded = AudioVisualization.fromParams({
          'width': -10,
          'height': 100000,
          'output_format': 'png;movie=bad',
        });
        expect(
          (bounded.width, bounded.height, bounded.format),
          (64, 4096, 'png'),
        );
        final fallback = AudioVisualization.fromParams({
          'width': double.nan,
          'height': '64:movie=bad',
        });
        expect((fallback.width, fallback.height), (1280, 720));
      },
    );

    test(
      'should preserve quoted paths, map audio and write exactly one image',
      () {
        final config = AudioVisualization.fromParams({'output_format': 'webp'});
        final root = Directory.systemTemp.absolute.path;
        final input = '$root${Platform.pathSeparator}' r'audio $(literal) "a".wav';
        final output = '$root${Platform.pathSeparator}result %03d.webp';
        final args = config.arguments(
          input: input,
          output: output,
          waveform: true,
        );
        expect(args[args.indexOf('-i') + 1], input);
        expect(args.last, output);
        expect(
          args[args.indexOf('-filter_complex') + 1],
          startsWith('[0:a:0]showwavespic='),
        );
        expect(args[args.indexOf('-frames:v') + 1], '1');
        expect(args[args.indexOf('-update') + 1], '1');
        expect(args[args.indexOf('-c:v') + 1], 'libwebp');
      },
    );

    test(
      'should replace extensions without consuming dotted parent directories',
      () {
        expect(
          AudioVisualization.withExtension('/tmp/parent.v1/result', 'png'),
          '/tmp/parent.v1/result.png',
        );
        expect(
          AudioVisualization.withExtension(r'C:\parent.v1\result.wav', 'jpg'),
          r'C:\parent.v1\result.jpg',
        );
      },
    );
  });

  group('AppState audio visualization execution', () {
    test(
      'should retry using argv and publish the actual single-image path',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'ffmpegpp_visualization_dispatch_',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final planned = '${directory.path}/image %03d.wav';
        final actual = AudioVisualization.withExtension(planned, 'webp');
        final launches = <List<String>>[];
        final finished = Completer<TaskStatus>();
        final state = AppState()
          ..setTaskProcessRunnerForTest(
            TaskProcessRunner(
              starter: (_, args) async {
                launches.add(args);
                if (launches.length == 1) return _FinishedProcess(1);
                File(args.last).writeAsBytesSync([1, 2, 3]);
                return _FinishedProcess(0);
              },
            ),
          )
          ..onTaskFinished = (_, status) => finished.complete(status);
        addTearDown(state.dispose);
        state.addTaskForTest(
          TaskInfo(
            id: 'visualize',
            videoId: 'v',
            filename: 'tone.wav',
            inputPath: '${directory.path}/source.wav',
            outputPath: planned,
            config: TranscodeConfig(),
            pipelineCalls: [
              BackendCall(
                action: 'audio_spectrum',
                retries: 1,
                params: {
                  'input': '${directory.path}/source.wav',
                  'output': planned,
                  'output_format': 'webp',
                  'width': 160,
                  'height': 96,
                },
              ),
            ],
          ),
        );
        await state.processNextTask();
        expect(
          await finished.future.timeout(const Duration(seconds: 5)),
          TaskStatus.completed,
        );
        expect(launches, hasLength(2));
        expect(
          launches.last[launches.last.indexOf('-filter_complex') + 1],
          startsWith('[0:a:0]showspectrumpic='),
        );
        expect(launches.last.last, endsWith('.webp'));
        expect(launches.last.last, isNot(actual));
        expect(launches.last.last, contains('ffmpegpp_visualization_'));
        expect(state.tasks.single.outputPath, actual);
        expect(state.tasks.single.outputSize, 3);
      },
    );
  });

  final ffmpeg = Platform.environment['FFMPEGPP_MEDIA_TEST_FFMPEG'];
  final ffprobe = Platform.environment['FFMPEGPP_MEDIA_TEST_FFPROBE'];
  group(
    'Real FFmpeg new media nodes',
    () {
      late Directory directory;
      late String audio;
      setUp(() async {
        directory = await Directory.systemTemp.createTemp(
          'ffmpegpp_media_nodes_',
        );
        audio = '${directory.path}/tone "quoted" %03d.wav';
        final result = await Process.run(ffmpeg!, [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:duration=0.3',
          '-y',
          audio,
        ]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
      });
      tearDown(() async => directory.delete(recursive: true));

      for (final waveform in [false, true]) {
        for (final format in ['png', 'jpg', 'webp']) {
          test(
            'should generate one ${waveform ? "waveform" : "spectrum"} $format image',
            () async {
              final config = AudioVisualization.fromParams({
                'width': 160,
                'height': 96,
                'output_format': format,
              });
              final output = '${directory.path}/output %03d.$format';
              final result = await Process.run(
                ffmpeg!,
                config.arguments(
                  input: audio,
                  output: output,
                  waveform: waveform,
                ),
              );
              expect(result.exitCode, 0, reason: result.stderr.toString());
              final probe = await Process.run(ffprobe!, [
                '-v',
                'error',
                '-f',
                'image2',
                '-pattern_type',
                'none',
                '-show_streams',
                '-of',
                'json',
                output,
              ]);
              expect(probe.exitCode, 0, reason: probe.stderr.toString());
              final stream =
                  (jsonDecode(probe.stdout as String)['streams'] as List).single
                      as Map;
              expect(stream['width'], 160);
              expect(stream['height'], 96);
              expect(stream['codec_type'], 'video');
              expect(stream['codec_name'], switch (format) {
                'jpg' => 'mjpeg',
                'webp' => 'webp',
                _ => 'png',
              });
              expect(await File(output).length(), greaterThan(0));
            },
          );
        }
      }

      for (final type in [
        PipelineStepType.audioReverse,
        PipelineStepType.audioEqualizer,
      ]) {
        test('should apply $type to a tiny PCM input', () async {
          final output = '${directory.path}/processed.wav';
          final call = _calls(
            _graph([
              _node(type, params: {'mid_db': 6}),
            ]),
            input: audio,
            output: output,
          ).single;
          final options = call.params['options'] as Map<String, dynamic>;
          final result = await Process.run(ffmpeg!, [
            '-v',
            'error',
            '-y',
            '-i',
            audio,
            '-vn',
            '-af',
            (options['af_filters'] as List).join(','),
            '-c:a',
            options['audio_codec'] as String,
            output,
          ]);
          expect(result.exitCode, 0, reason: result.stderr.toString());
          Future<List<int>> pcm(String path) async {
            final decoded = await Process.run(ffmpeg, [
              '-v',
              'error',
              '-i',
              path,
              '-f',
              's16le',
              '-c:a',
              'pcm_s16le',
              '-',
            ], stdoutEncoding: null);
            expect(decoded.exitCode, 0, reason: decoded.stderr.toString());
            final bytes = decoded.stdout as List<int>;
            return [
              for (var i = 0; i < bytes.length; i += 2)
                bytes[i] | (bytes[i + 1] << 8),
            ];
          }

          final before = await pcm(audio);
          final after = await pcm(output);
          expect(after, hasLength(before.length));
          if (type == PipelineStepType.audioReverse) {
            expect(after, before.reversed.toList());
          } else {
            expect(after, isNot(equals(before)));
          }
        });
      }

      for (final hasAudio in [false, true]) {
        test(
          'should reverse and fade a tiny video with audio=$hasAudio',
          () async {
            final input = '${directory.path}/video.mkv';
            final generated = await Process.run(ffmpeg!, [
              '-v',
              'error',
              '-y',
              '-f',
              'lavfi',
              '-i',
              'testsrc=s=64x64:r=4:d=0.5',
              if (hasAudio) ...['-i', audio],
              '-c:v',
              'ffv1',
              '-threads:v',
              '1',
              if (hasAudio) ...['-c:a', 'pcm_s16le'],
              input,
            ]);
            expect(generated.exitCode, 0, reason: generated.stderr.toString());
            for (final type in [
              PipelineStepType.videoReverse,
              PipelineStepType.videoFade,
            ]) {
              final output = '${directory.path}/${type.name}.mp4';
              final call = _calls(
                _graph([_node(type)], media: 'video'),
                input: input,
                output: output,
              ).single;
              final options = call.params['options'] as Map<String, dynamic>;
              final filters = type == PipelineStepType.videoFade
                  ? GraphExecutor.videoFadeFilters(call.params, duration: 0.5)
                  : (options['vf_filters'] as List).cast<String>();
              final result = await Process.run(ffmpeg, [
                '-v',
                'error',
                '-y',
                '-i',
                input,
                '-vf',
                filters.join(','),
                if (options['af_filters'] case final List filters) ...[
                  '-af',
                  filters.join(','),
                ],
                '-c:v',
                'libx264',
                '-pix_fmt',
                'yuv420p',
                '-threads:v',
                '1',
                '-c:a',
                options['audio_codec'] as String,
                output,
              ]);
              expect(result.exitCode, 0, reason: result.stderr.toString());
              final probe = await Process.run(ffprobe!, [
                '-v',
                'error',
                '-show_streams',
                '-of',
                'json',
                output,
              ]);
              expect(probe.exitCode, 0, reason: probe.stderr.toString());
              final streams =
                  jsonDecode(probe.stdout as String)['streams'] as List;
              expect(
                streams.where((stream) => stream['codec_type'] == 'video'),
                hasLength(1),
              );
              expect(
                streams.where((stream) => stream['codec_type'] == 'audio'),
                hasLength(hasAudio ? 1 : 0),
              );
            }
          },
        );
      }

      test(
        'should fade on the video duration and retain delayed multi-audio through WebM',
        () async {
          Future<void> ff(List<String> args) async {
            final result = await Process.run(ffmpeg!, ['-v', 'error', ...args]);
            expect(result.exitCode, 0, reason: result.stderr.toString());
          }

          Future<Map<String, dynamic>> probe(String input) async {
            final result = await Process.run(ffprobe!, [
              '-v',
              'error',
              '-show_streams',
              '-show_format',
              '-of',
              'json',
              input,
            ]);
            expect(result.exitCode, 0, reason: result.stderr.toString());
            return jsonDecode(result.stdout as String) as Map<String, dynamic>;
          }

          final longAudio = '${directory.path}/long_audio.mkv';
          await ff([
            '-f',
            'lavfi',
            '-i',
            'color=c=white:s=64x64:r=10:d=1',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:duration=4',
            '-c:v',
            'ffv1',
            '-c:a',
            'pcm_s16le',
            '-threads:v',
            '1',
            '-y',
            longAudio,
          ]);
          final timeline = VideoTimeline.fromProbe(await probe(longAudio));
          expect(timeline.videoDuration, closeTo(1, .02));
          final faded = '${directory.path}/faded.mp4';
          await ff(
            VideoTimeline.fadeArguments(
              input: longAudio,
              output: faded,
              filters: GraphExecutor.videoFadeFilters({
                'fade_in': 0,
                'fade_out': .5,
              }, duration: timeline.videoDuration),
              options: GraphExecutor.videoOptionsForPath(faded),
            ),
          );
          final raw = await Process.run(ffmpeg!, [
            '-v',
            'error',
            '-ss',
            '0.9',
            '-i',
            faded,
            '-frames:v',
            '1',
            '-pix_fmt',
            'gray',
            '-f',
            'rawvideo',
            '-',
          ], stdoutEncoding: null);
          final pixels = raw.stdout as List<int>;
          expect(raw.exitCode, 0, reason: raw.stderr.toString());
          expect(pixels, isNotEmpty);
          expect(pixels.reduce((a, b) => a + b) / pixels.length, lessThan(90));
          final input = '${directory.path}/delayed.mkv';
          await ff([
            '-f',
            'lavfi',
            '-i',
            'testsrc=s=64x64:r=10:d=1',
            '-itsoffset',
            '0.1',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:duration=0.4',
            '-itsoffset',
            '0.4',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=880:duration=0.3',
            '-map',
            '0:v',
            '-map',
            '1:a',
            '-map',
            '2:a',
            '-c:v',
            'ffv1',
            '-c:a',
            'pcm_s16le',
            '-threads:v',
            '1',
            '-y',
            input,
          ]);
          final timing = VideoTimeline.fromProbe(await probe(input));
          final webm = '${directory.path}/reversed.webm';
          await ff(
            timing.reverseArguments(
              input: input,
              output: webm,
              options: GraphExecutor.videoOptionsForPath(webm),
            ),
          );
          final outputTimeline = VideoTimeline.fromProbe(await probe(webm));
          expect(outputTimeline.audio, hasLength(2));
          for (var i = 0; i < timing.audio.length; i++) {
            final expected =
                1 - timing.audio[i].start - timing.audio[i].duration!;
            expect(outputTimeline.audio[i].start, closeTo(expected, .04));
          }
          final finalMp4 = '${directory.path}/after_webm.mp4';
          final finished = Completer<TaskStatus>();
          final state = AppState()
            ..config.ffmpegPath = ffmpeg
            ..config.ffprobePath = ffprobe!
            ..setTaskProcessRunnerForTest(TaskProcessRunner())
            ..onTaskFinished = (_, status) => finished.complete(status);
          addTearDown(state.dispose);
          final calls = _calls(
            _graph([
              _node(PipelineStepType.videoReverse, id: 'reverse'),
              _node(
                PipelineStepType.videoFade,
                id: 'fade',
                params: {'fade_in': 0, 'fade_out': .2},
              ),
            ], media: 'video'),
            input: webm,
            output: finalMp4,
          );
          state.addTaskForTest(
            TaskInfo(
              id: 'webm_chain',
              videoId: 'v',
              filename: 'input.webm',
              inputPath: webm,
              outputPath: finalMp4,
              config: TranscodeConfig(),
              pipelineCalls: calls,
            ),
          );
          await state.processNextTask();
          expect(
            await finished.future.timeout(const Duration(seconds: 30)),
            TaskStatus.completed,
            reason: state.tasks.single.error,
          );
          expect(
            (await probe(
              finalMp4,
            ))['streams'].where((s) => s['codec_type'] == 'audio'),
            hasLength(2),
          );
        },
      );

      test('should retain ten-bit video in the local WebM runner', () async {
        final input = '${directory.path}/ten_bit.mkv';
        final generated = await Process.run(ffmpeg!, [
          '-v',
          'error',
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=white:s=64x64:r=10:d=1',
          '-vf',
          'format=yuv420p10le',
          '-c:v',
          'ffv1',
          '-threads:v',
          '1',
          input,
        ]);
        expect(generated.exitCode, 0, reason: generated.stderr.toString());
        final probed = await Process.run(ffprobe!, [
          '-v',
          'error',
          '-show_streams',
          '-show_format',
          '-of',
          'json',
          input,
        ]);
        final timing = VideoTimeline.fromProbe(
          jsonDecode(probed.stdout as String) as Map<String, dynamic>,
        );
        final output = '${directory.path}/ten_bit.webm';
        final converted = await Process.run(
          ffmpeg,
          timing.reverseArguments(
            input: input,
            output: output,
            options: GraphExecutor.videoOptionsForPath(output),
          ),
        );
        expect(converted.exitCode, 0, reason: converted.stderr.toString());
        final checked = await Process.run(ffprobe, [
          '-v',
          'error',
          '-show_streams',
          '-of',
          'json',
          output,
        ]);
        expect(
          (jsonDecode(checked.stdout as String)['streams'] as List)
              .single['pix_fmt'],
          'yuv420p10le',
        );
      });

      test(
        'should run visualization and image conversion with real paths and cleanup',
        () async {
          final graph = _graph([
            _node(
              PipelineStepType.audioWaveform,
              id: 'wave',
              params: {'width': 160, 'height': 96},
            ),
            _node(
              PipelineStepType.imageConvert,
              id: 'convert',
              params: {'output_format': 'webp'},
            ),
          ]);
          final output = '${directory.path}/converted.webp';
          final calls = _calls(graph, input: audio, output: output);
          final finished = Completer<TaskStatus>();
          final state = AppState()
            ..config.ffmpegPath = ffmpeg!
            ..config.ffprobePath = ffprobe!
            ..setTaskProcessRunnerForTest(TaskProcessRunner())
            ..onTaskFinished = (_, status) => finished.complete(status);
          addTearDown(state.dispose);
          state.addTaskForTest(
            TaskInfo(
              id: 'image-chain',
              videoId: 'v',
              filename: 'tone.wav',
              inputPath: audio,
              outputPath: output,
              config: TranscodeConfig(),
              pipelineCalls: calls,
            ),
          );
          await state.processNextTask();
          expect(
            await finished.future.timeout(const Duration(seconds: 20)),
            TaskStatus.completed,
            reason: state.tasks.single.error,
          );
          expect(state.tasks.single.outputPath, output);
          expect(state.tasks.single.outputSize, await File(output).length());
          for (final call in calls.where((call) => call.action == '_cleanup')) {
            expect(File(call.params['path'] as String).existsSync(), isFalse);
          }
        },
      );
    },
    skip: ffmpeg == null || ffprobe == null
        ? 'Set FFMPEGPP_MEDIA_TEST_FFMPEG and FFMPEGPP_MEDIA_TEST_FFPROBE for tiny real-media checks.'
        : false,
  );
}
