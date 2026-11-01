import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 媒体功能节点回归测试：图片压缩 / 响度标准化 / 噪声门 / 帧率转换。
///
/// 覆盖三层：
///   1. 节点语义（中英文名、输入输出媒体类型）；
///   2. 执行计划 → BackendCall 的参数生成（后端真正拿到的命令参数）；
///   3. 输出扩展名推导（图片压缩换格式时不写错后缀）。

PipelineNode _node(String id, PipelineStepType t, {Map<String, dynamic>? params}) =>
    PipelineNode(id: id, type: t, params: params ?? {});

PipelineGraph _graph({
  required PipelineStepType type,
  required String mediaType,
  Map<String, dynamic>? params,
}) {
  final nodes = [
    _node('S', PipelineStepType.start, params: {'file_media_type': mediaType}),
    _node('N', type, params: params),
    _node('O', PipelineStepType.output),
  ];
  final conns = [
    PipelineConnection(id: 'c1', fromNodeId: 'S', toNodeId: 'N'),
    PipelineConnection(id: 'c2', fromNodeId: 'N', toNodeId: 'O'),
  ];
  return PipelineGraph(nodes: nodes, connections: conns);
}

List<BackendCall> _build(
  PipelineGraph g, {
  String input = '/tmp/in.mp4',
  String output = '/tmp/out.mp4',
}) {
  final plans = GraphExecutor.resolvePlans(g);
  expect(plans, isNotEmpty, reason: '应解析出至少一个执行计划');
  final calls = GraphExecutor.buildBackendCalls(plans.first, input, output);
  expect(calls, isNotNull,
      reason: '计划构建应成功，告警=${plans.first.warnings.join('；')}');
  return calls!;
}

BackendCall _firstStep(List<BackendCall> calls) =>
    calls.firstWhere((c) => c.action != '_cleanup');

void main() {
  group('节点语义与序列化稳定性', () {
    test('中英文名称齐全', () {
      final zh = _node('1', PipelineStepType.imageCompress).label;
      final en = _node('1', PipelineStepType.imageCompress).labelEn;
      expect(zh, '图片压缩');
      expect(en, 'Image Compress');

      expect(_node('1', PipelineStepType.audioNormalize).label, '响度标准化');
      expect(_node('1', PipelineStepType.audioNormalize).labelEn, 'Loudness Normalize');

      expect(_node('1', PipelineStepType.audioNoiseGate).label, '音频噪声门');
      expect(_node('1', PipelineStepType.audioNoiseGate).labelEn, 'Noise Gate');

      expect(_node('1', PipelineStepType.videoFrameRate).label, '帧率转换');
      expect(_node('1', PipelineStepType.videoFrameRate).labelEn, 'Frame Rate');

      expect(_node('1', PipelineStepType.metadataStrip).label, '元数据删除');
      expect(_node('1', PipelineStepType.metadataStrip).labelEn, 'Metadata Strip');

      expect(_node('1', PipelineStepType.audioDenoise).label, '音频降噪');
      expect(_node('1', PipelineStepType.audioDenoise).labelEn, 'Audio Denoise');

      expect(_node('1', PipelineStepType.audioSilenceTrim).label, '静音裁剪');
      expect(_node('1', PipelineStepType.audioSilenceTrim).labelEn, 'Silence Trim');

      expect(_node('1', PipelineStepType.videoDeinterlace).label, '视频去隔行');
      expect(_node('1', PipelineStepType.videoDeinterlace).labelEn, 'Deinterlace');
    });

    test('输入/输出媒体类型正确', () {
      final image = _node('1', PipelineStepType.imageCompress);
      expect(image.inputTypes, {MediaType.image});
      expect(image.outputType, MediaType.image);

      for (final t in [PipelineStepType.audioNormalize, PipelineStepType.audioNoiseGate]) {
        final n = _node('1', t);
        expect(n.inputTypes, {MediaType.audio}, reason: t.name);
        expect(n.outputType, MediaType.audio, reason: t.name);
      }

      for (final t in [PipelineStepType.videoFrameRate, PipelineStepType.videoDeinterlace]) {
        final n = _node('1', t);
        expect(n.inputTypes, {MediaType.video}, reason: t.name);
        expect(n.outputType, MediaType.video, reason: t.name);
      }

      for (final t in [PipelineStepType.audioDenoise, PipelineStepType.audioSilenceTrim]) {
        final n = _node('1', t);
        expect(n.inputTypes, {MediaType.audio}, reason: t.name);
        expect(n.outputType, MediaType.audio, reason: t.name);
      }

      // 元数据删除是通用节点：媒体类型由 media_type 决定
      final meta = _node('1', PipelineStepType.metadataStrip, params: {'media_type': 'image'});
      expect(meta.inputTypes, {MediaType.image});
      expect(meta.outputType, MediaType.image);
      expect(meta.mediaKind, MediaType.image);
    });

    test('新枚举值追加在 output 之后，未打乱既有索引', () {
      // 既有节点顺序 = 旧配置文件/后端 node_registry 的索引依据，不能被插入
      expect(PipelineStepType.start.index, 0);
      expect(PipelineStepType.output.index, 37);
      expect(PipelineStepType.imageCompress.index, 38);
      expect(PipelineStepType.audioNormalize.index, 39);
      expect(PipelineStepType.audioNoiseGate.index, 40);
      expect(PipelineStepType.videoFrameRate.index, 41);
      expect(PipelineStepType.metadataStrip.index, 42);
      expect(PipelineStepType.audioDenoise.index, 43);
      expect(PipelineStepType.audioSilenceTrim.index, 44);
      expect(PipelineStepType.videoDeinterlace.index, 45);
      expect(PipelineStepType.unknown.index, 46);
    });
  });

  group('图片压缩执行计划', () {
    test('指定 webp+质量时产出 image_compress 并改后缀', () {
      final g = _graph(
        type: PipelineStepType.imageCompress,
        mediaType: 'image',
        params: {'output_format': 'webp', 'quality': 55},
      );
      final calls = _build(g, input: '/tmp/in.png', output: '/tmp/out.png');
      final call = _firstStep(calls);
      expect(call.action, 'image_compress');
      expect(call.params['input'], '/tmp/in.png');
      expect(call.params['output'], '/tmp/out.webp');
      expect(call.params['quality'], 55);
    });

    test('keep 格式沿用 .jpeg 后缀，输出路径与实际文件一致', () {
      final g = _graph(
        type: PipelineStepType.imageCompress,
        mediaType: 'image',
        params: {'output_format': 'keep', 'quality': 60},
      );
      final calls = _build(g, input: '/tmp/in.jpeg', output: '/tmp/out.jpeg');
      expect(_firstStep(calls).params['output'], '/tmp/out.jpeg');

      final plans = GraphExecutor.resolvePlans(g);
      final video = VideoFile(
        id: 'v',
        filepath: '/media/src/photo.jpeg',
        filename: 'photo.jpeg',
        fileMediaType: MediaType.image,
      );
      final out = GraphExecutor.resolveOutputPath(
        plans.first,
        video,
        AppConfig(defaultOutputDir: '/tmp/outdir'),
      );
      expect(out, '/tmp/outdir/photo.jpeg');
    });

    test('keep 格式沿用源扩展名（png 输入 → png 输出）并提示质量无效', () {
      final g = _graph(
        type: PipelineStepType.imageCompress,
        mediaType: 'image',
        params: {'output_format': 'keep', 'quality': 30},
      );
      final plans = GraphExecutor.resolvePlans(g);
      final calls = GraphExecutor.buildBackendCalls(
        plans.first,
        '/tmp/in.png',
        '/tmp/out.png',
      )!;
      final call = _firstStep(calls);
      expect(call.params['output'], '/tmp/out.png');
      expect(plans.first.warnings.join('；'), contains('PNG'));
    });
  });

  group('音频节点执行计划', () {
    test('响度标准化生成 loudnorm 滤镜并保留音频编码', () {
      final g = _graph(
        type: PipelineStepType.audioNormalize,
        mediaType: 'audio',
        params: {'target_i': -14.0, 'target_tp': -1.0, 'target_lra': 9.0},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.m4a', output: '/tmp/out.m4a'));
      expect(call.action, 'transcode');
      final opts = call.params['options'] as Map<String, dynamic>;
      expect(opts['video_codec'], 'none');
      expect(opts['audio_codec'], 'aac');
      expect(opts['af_filters'], ['loudnorm=I=-14.0:TP=-1.0:LRA=9.0']);
    });

    test('噪声门把 dB 阈值换算成 agate 的线性 threshold', () {
      final g = _graph(
        type: PipelineStepType.audioNoiseGate,
        mediaType: 'audio',
        params: {'threshold_db': -30.0, 'ratio': 3.0, 'attack': 10.0, 'release': 200.0},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.wav', output: '/tmp/out.wav'));
      final opts = call.params['options'] as Map<String, dynamic>;
      expect(opts['video_codec'], 'none');
      expect(opts['audio_codec'], 'pcm_s16le');
      final filters = opts['af_filters'] as List;
      // 10^(-30/20) ≈ 0.0316
      expect(filters.single, 'agate=threshold=0.0316:ratio=3.0:attack=10:release=200');
    });

    test('噪声门参数越界时被钳制，不会生成非法滤镜', () {
      final g = _graph(
        type: PipelineStepType.audioNoiseGate,
        mediaType: 'audio',
        params: {'threshold_db': 999.0, 'ratio': -5.0, 'attack': -1.0, 'release': 1e9},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.mp3', output: '/tmp/out.mp3'));
      final filters = (call.params['options'] as Map<String, dynamic>)['af_filters'] as List;
      expect(filters.single, 'agate=threshold=1.0000:ratio=1.0:attack=0:release=9000');
    });
  });

  group('视频帧率转换执行计划', () {
    test('下发 framerate 并 copy 音频', () {
      final g = _graph(
        type: PipelineStepType.videoFrameRate,
        mediaType: 'video',
        params: {'fps': 60.0},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.mp4', output: '/tmp/out.mp4'));
      expect(call.action, 'transcode');
      final opts = call.params['options'] as Map<String, dynamic>;
      expect(opts['framerate'], 60.0);
      expect(opts['video_codec'], 'h264');
      expect(opts['audio_codec'], 'copy');
    });

    test('对中间产物链式传递（非末步使用临时路径）', () {
      final nodes = [
        _node('S', PipelineStepType.start, params: {'file_media_type': 'video'}),
        _node('N1', PipelineStepType.videoFrameRate, params: {'fps': 24.0}),
        _node('N2', PipelineStepType.videoFrameRate, params: {'fps': 30.0}),
        _node('O', PipelineStepType.output),
      ];
      final conns = [
        PipelineConnection(id: 'c1', fromNodeId: 'S', toNodeId: 'N1'),
        PipelineConnection(id: 'c2', fromNodeId: 'N1', toNodeId: 'N2'),
        PipelineConnection(id: 'c3', fromNodeId: 'N2', toNodeId: 'O'),
      ];
      final g = PipelineGraph(nodes: nodes, connections: conns);
      final calls = _build(g, input: '/tmp/in.mp4', output: '/tmp/out.mp4');
      final steps = calls.where((c) => c.action != '_cleanup').toList();
      expect(steps.length, 2);
      expect(steps[0].params['output'], isNot('/tmp/out.mp4'));
      expect(steps[1].params['input'], steps[0].params['output']);
      expect(steps[1].params['output'], '/tmp/out.mp4');
    });
  });

  group('元数据删除（图片/音频/视频三合一）', () {
    test('视频：走原生 metadata_strip，透传保留章节选项', () {
      final g = _graph(
        type: PipelineStepType.metadataStrip,
        mediaType: 'video',
        params: {'media_type': 'video', 'keep_chapters': true},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.mp4', output: '/tmp/out.mp4'));
      expect(call.action, 'metadata_strip');
      expect(call.params['input'], '/tmp/in.mp4');
      expect(call.params['output'], '/tmp/out.mp4');
      expect(call.params['keep_chapters'], true);
      expect(call.params['remove_cover'], false);
    });

    test('音频：透传删除封面开关', () {
      final g = _graph(
        type: PipelineStepType.metadataStrip,
        mediaType: 'audio',
        params: {'media_type': 'audio', 'remove_cover': true},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.m4a', output: '/tmp/out.m4a'));
      expect(call.action, 'metadata_strip');
      expect(call.params['remove_cover'], true);
    });

    test('图片：同一 action、同一扩展名，不需要编码参数', () {
      final g = _graph(
        type: PipelineStepType.metadataStrip,
        mediaType: 'image',
        params: {'media_type': 'image'},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.jpg', output: '/tmp/out.jpg'));
      expect(call.action, 'metadata_strip');
      expect(call.params['output'], '/tmp/out.jpg');
      expect(call.params.containsKey('options'), isFalse);
    });
  });

  group('音频降噪与静音裁剪', () {
    test('降噪生成 afftdn 滤镜并保留音频编码', () {
      final g = _graph(
        type: PipelineStepType.audioDenoise,
        mediaType: 'audio',
        params: {'noise_reduction': 15.0, 'noise_floor': -35.0},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.m4a', output: '/tmp/out.m4a'));
      expect(call.action, 'transcode');
      final opts = call.params['options'] as Map<String, dynamic>;
      expect(opts['video_codec'], 'none');
      expect(opts['audio_codec'], 'aac');
      expect(opts['af_filters'], ['afftdn=nr=15.00:nf=-35']);
    });

    test('静音裁剪：首尾模式生成完整 silenceremove 链', () {
      final g = _graph(
        type: PipelineStepType.audioSilenceTrim,
        mediaType: 'audio',
        params: {'mode': 'both', 'threshold_db': -40.0, 'min_duration': 0.1},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.wav', output: '/tmp/out.wav'));
      final opts = call.params['options'] as Map<String, dynamic>;
      expect(opts['af_filters'], [
        'silenceremove=start_periods=1:start_threshold=-40.0dB:start_silence=0.10'
            ':stop_periods=-1:stop_threshold=-40.0dB:stop_silence=0.10',
      ]);
    });

    test('静音裁剪：只裁开头时不下发 stop_* 参数', () {
      final g = _graph(
        type: PipelineStepType.audioSilenceTrim,
        mediaType: 'audio',
        params: {'mode': 'leading', 'threshold_db': -35.0, 'min_duration': 0.2},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.wav', output: '/tmp/out.wav'));
      final filter = ((call.params['options'] as Map<String, dynamic>)['af_filters'] as List).single as String;
      expect(filter, contains('start_periods=1'));
      expect(filter, isNot(contains('stop_periods')));
    });
  });

  group('视频去隔行', () {
    test('生成 yadif 滤镜并 copy 音频', () {
      final g = _graph(
        type: PipelineStepType.videoDeinterlace,
        mediaType: 'video',
        params: {'mode': 1, 'parity': 0},
      );
      final call = _firstStep(_build(g, input: '/tmp/in.mp4', output: '/tmp/out.mp4'));
      expect(call.action, 'transcode');
      final opts = call.params['options'] as Map<String, dynamic>;
      expect(opts['vf_filters'], ['yadif=mode=1:parity=0:deint=0']);
      expect(opts['audio_codec'], 'copy');
      expect(opts['video_codec'], 'h264');
    });
  });

  group('输出路径推导', () {
    test('图片压缩显式换格式时输出文件后缀同步', () {
      final g = _graph(
        type: PipelineStepType.imageCompress,
        mediaType: 'image',
        params: {'output_format': 'webp', 'quality': 60},
      );
      final plans = GraphExecutor.resolvePlans(g);
      final video = VideoFile(
        id: 'v',
        filepath: '/media/src/photo.png',
        filename: 'photo.png',
        fileMediaType: MediaType.image,
      );
      final out = GraphExecutor.resolveOutputPath(
        plans.first,
        video,
        AppConfig(defaultOutputDir: '/tmp/outdir'),
      );
      expect(out, '/tmp/outdir/photo.webp');
    });

    test('图片压缩 keep 格式沿用源后缀', () {
      final g = _graph(
        type: PipelineStepType.imageCompress,
        mediaType: 'image',
        params: {'output_format': 'keep'},
      );
      final plans = GraphExecutor.resolvePlans(g);
      final video = VideoFile(
        id: 'v',
        filepath: '/media/src/photo.jpg',
        filename: 'photo.jpg',
        fileMediaType: MediaType.image,
      );
      final out = GraphExecutor.resolveOutputPath(
        plans.first,
        video,
        AppConfig(defaultOutputDir: '/tmp/outdir'),
      );
      expect(out, '/tmp/outdir/photo.jpg');
    });
  });
}
