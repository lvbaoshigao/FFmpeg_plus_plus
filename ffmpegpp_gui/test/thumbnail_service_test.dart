import 'dart:async';
import 'dart:io';

import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:ffmpegpp_gui/services/task_process_runner.dart';
import 'package:ffmpegpp_gui/services/thumbnail_service.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeProcess implements Process {
  _FakeProcess(this.output);

  final String output;
  final exited = Completer<int>();
  final terminated = Completer<void>();
  final killed = Completer<void>();
  final out = StreamController<List<int>>();
  final err = StreamController<List<int>>();

  void succeed() {
    File(output).writeAsBytesSync([1, 2, 3]);
    exited.complete(0);
    unawaited(out.close());
    unawaited(err.close());
  }

  @override
  int get pid => 1;

  @override
  Future<int> get exitCode => exited.future;

  @override
  Stream<List<int>> get stdout => out.stream;

  @override
  Stream<List<int>> get stderr => err.stream;

  @override
  IOSink get stdin => throw UnsupportedError('No fake stdin');

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (signal == ProcessSignal.sigterm && !terminated.isCompleted) {
      terminated.complete();
    } else if (signal == ProcessSignal.sigkill && !killed.isCompleted) {
      killed.complete();
    }
    return true;
  }
}

Future<T> _result<T>(Future<T> value) =>
    value.timeout(const Duration(seconds: 5));

void main() {
  group('ThumbnailService', () {
    late Directory cache;
    setUp(() async {
      cache = await Directory.systemTemp.createTemp('thumbnail_test_');
    });
    tearDown(() async {
      await cache.delete(recursive: true);
    });

    test('disabled diagnostics emit nothing on a cache hit', () async {
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add);
      final cached = File('${cache.path}${Platform.pathSeparator}ffmpegpp_thumb_${ThumbnailService.stableHash('private.mp4')}.jpg');
      await cached.writeAsBytes([1, 2, 3]);
      final service = ThumbnailService.forTesting(
        cacheDirectory: cache,
        runner: TaskProcessRunner(starter: (_, _) async => throw StateError('unexpected launch')),
      );
      expect(await service.requestThumbnail('private.mp4', trace: trace), cached.path);
      expect(messages, isEmpty);
    });

    test('should share an in-flight request and bound uncached work', () async {
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add)..setEnabled(true);
      final launches = List.generate(2, (_) => Completer<_FakeProcess>());
      final arguments = <List<String>>[];
      var started = 0;
      final service = ThumbnailService.forTesting(
        cacheDirectory: cache,
        maxConcurrent: 1,
        maxQueued: 1,
        runner: TaskProcessRunner(
          starter: (_, args) async {
            final process = _FakeProcess(args.last);
            arguments.add(args);
            launches[started++].complete(process);
            return process;
          },
        ),
      );

      final first = service.requestThumbnail('one.mp4', trace: trace);
      final firstProcess = await _result(launches[0].future);
      final second = service.requestThumbnail('cover.mp3', trace: trace);
      expect(service.requestThumbnail('one.mp4', isAudio: false, trace: trace), same(first));
      expect(
        service.requestThumbnail('cover.mp3', isAudio: true, trace: trace),
        same(second),
      );
      expect(await _result(service.requestThumbnail('overflow.mp4', trace: trace)), isNull);
      expect(started, 1);
      firstProcess.succeed();

      final firstPath = await _result(first);
      expect(firstPath, endsWith('.jpg'));
      expect(await File(firstPath!).readAsBytes(), [1, 2, 3]);
      final secondProcess = await _result(launches[1].future);
      secondProcess.succeed();
      expect(await _result(second), endsWith('_cover.jpg'));
      expect(
        arguments.last,
        containsAllInOrder([
          '-an',
          '-vf',
          startsWith('scale=176:108:force_original_aspect_ratio=decrease'),
        ]),
      );
      final cached = service.requestThumbnail('one.mp4', trace: trace);
      expect(cached, isNot(same(first)));
      expect(await _result(cached), firstPath);
      expect(started, 2);
      final log = messages.join(' ');
      for (final event in ['thumbnail.coalesce', 'thumbnail.queue', 'thumbnail.queue.reject', 'thumbnail.cache.hit', 'thumbnail.ffmpeg.exit']) {
        expect(log, contains(event));
      }
      expect(log, contains('exitCode=0'));
      expect(log, contains('active=1'));
      expect(log, isNot(contains('one.mp4')));
      expect(log, isNot(contains('cover.mp3')));
      expect(log, isNot(contains(cache.path)));
    });

    test(
      'should drain a timed-out process before releasing its slot',
      () async {
        final messages = <String>[];
        final trace = DiagnosticTrace(messages.add)..setEnabled(true);
        final firstLaunch = Completer<_FakeProcess>();
        var started = 0;
        final service = ThumbnailService.forTesting(
          cacheDirectory: cache,
          maxConcurrent: 1,
          timeout: const Duration(milliseconds: 100),
          runner: TaskProcessRunner(
            windows: true,
            killDelay: const Duration(milliseconds: 10),
            starter: (_, args) async {
              final process = _FakeProcess(args.last);
              if (started++ == 0) {
                firstLaunch.complete(process);
              } else {
                process.succeed();
              }
              return process;
            },
          ),
        );

        final first = service.requestThumbnail('stalled.mp4', trace: trace);
        final process = await _result(firstLaunch.future);
        final queued = service.requestThumbnail('queued.mp4');
        File(process.output).writeAsStringSync('incomplete image');
        await _result(process.terminated.future);
        await _result(process.killed.future);
        process.exited.complete(-9);
        await _result(process.out.close());
        expect(started, 1, reason: 'Stderr has not finished draining');
        await _result(process.err.close());

        expect(await _result(first), isNull);
        expect(File(process.output).existsSync(), isFalse);
        expect(await _result(queued), isNotNull);
        final retried = service.requestThumbnail('stalled.mp4', trace: trace);
        expect(retried, isNot(same(first)));
        final path = await _result(retried);
        expect(path, isNotNull);
        expect(await File(path!).readAsBytes(), [1, 2, 3]);
        expect(started, 3);
        final log = messages.join(' ');
        expect(log, contains('thumbnail.timeout'));
        expect(log, contains('failureType=timeout'));
        expect(log, contains('cancelled=true'));
        expect(log, isNot(contains('stalled.mp4')));
      },
    );
  });
}
