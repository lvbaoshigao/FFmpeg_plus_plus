import 'dart:async';
import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/frame_preview.dart';
import 'package:ffmpegpp_gui/services/task_process_runner.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakePreviewProcess implements Process {
  _FakePreviewProcess(this.output);

  final String output;
  final Completer<int> _exit = Completer<int>();
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();

  Future<void> succeed() async {
    File(output).writeAsBytesSync([1, 2, 3]);
    _exit.complete(0);
    await Future.wait([_stdout.close(), _stderr.close()]);
  }

  @override
  int get pid => 1;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => throw UnsupportedError('No fake stdin');

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) {
      _exit.complete(-1);
      unawaited(_stdout.close());
      unawaited(_stderr.close());
    }
    return true;
  }
}

void main() {
  test(
    'automatic task concurrency is capped and manual values are clamped',
    () {
      expect(AppState.boundedTaskConcurrencyForTest(0, mobile: true), 2);
      expect(AppState.boundedTaskConcurrencyForTest(0, mobile: false), 4);
      expect(AppState.boundedTaskConcurrencyForTest(1, mobile: false), 1);
      expect(AppState.boundedTaskConcurrencyForTest(8, mobile: false), 8);
      expect(AppState.boundedTaskConcurrencyForTest(999, mobile: false), 8);
    },
  );

  test(
    'task history drops old terminal tasks but keeps active tasks',
    () async {
      final state = AppState();
      addTearDown(state.dispose);
      for (var i = 0; i < 210; i++) {
        state.addTaskForTest(
          TaskInfo(
            id: 'task-$i',
            videoId: '',
            filename: 'file-$i',
            inputPath: '',
            outputPath: '',
            status: i < 205 ? TaskStatus.completed : TaskStatus.pending,
            config: TranscodeConfig(),
          ),
        );
      }

      state.trimTerminalTaskHistoryForTest();

      expect(state.tasks, hasLength(200));
      expect(state.tasks.first.id, 'task-10');
      expect(state.tasks.last.id, 'task-209');
      expect(
        state.tasks.where((task) => task.status == TaskStatus.pending),
        hasLength(5),
      );
    },
  );

  test(
    'frame preview timeout cancels the process and releases its slot',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'preview_timeout_test_',
      );
      final source = File('${temp.path}${Platform.pathSeparator}source.mkv');
      await source.writeAsString('fixture');
      _FakePreviewProcess? process;
      FramePreview.configureForTest(
        maxConcurrent: 1,
        maxQueued: 1,
        timeout: const Duration(milliseconds: 20),
        runner: TaskProcessRunner(
          windows: true,
          killDelay: const Duration(milliseconds: 5),
          starter: (_, arguments) async {
            process = _FakePreviewProcess(arguments.last);
            return process!;
          },
        ),
      );
      addTearDown(() async {
        FramePreview.resetForTest();
        await temp.delete(recursive: true);
      });

      await IOOverrides.runZoned(() async {
        expect(
          await FramePreview.generatePreview(source.path, 0.017, width: 160),
          isNull,
        );
        expect(process, isNotNull);
        expect(FramePreview.activeForTest, 0);
        expect(FramePreview.queuedForTest, 0);
      }, getSystemTempDirectory: () => temp);
    },
  );

  test(
    'frame preview bounds active processes and replaces stale queued work',
    () async {
      final temp = await Directory.systemTemp.createTemp('preview_queue_test_');
      final source = File('${temp.path}${Platform.pathSeparator}source.mkv');
      await source.writeAsString('fixture');
      final started = <_FakePreviewProcess>[];
      final firstTwoStarted = Completer<void>();
      final thirdStarted = Completer<void>();
      final fourthStarted = Completer<void>();
      FramePreview.configureForTest(
        maxConcurrent: 2,
        maxQueued: 2,
        timeout: const Duration(seconds: 5),
        runner: TaskProcessRunner(
          captureLimit: 1024,
          starter: (_, arguments) async {
            final process = _FakePreviewProcess(arguments.last);
            started.add(process);
            if (started.length == 2) firstTwoStarted.complete();
            if (started.length == 3) thirdStarted.complete();
            if (started.length == 4) fourthStarted.complete();
            return process;
          },
        ),
      );
      addTearDown(() async {
        FramePreview.resetForTest();
        await temp.delete(recursive: true);
      });

      await IOOverrides.runZoned(() async {
        final first = FramePreview.generatePreview(
          source.path,
          0.017,
          width: 160,
        );
        final second = FramePreview.generatePreview(
          source.path,
          0.033,
          width: 160,
        );
        await firstTwoStarted.future.timeout(const Duration(seconds: 3));
        final stale = FramePreview.generatePreview(
          source.path,
          0.050,
          width: 160,
        );
        final third = FramePreview.generatePreview(
          source.path,
          0.067,
          width: 160,
        );
        final fourth = FramePreview.generatePreview(
          source.path,
          0.083,
          width: 160,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(FramePreview.activeForTest, 2);
        expect(FramePreview.queuedForTest, 2);
        expect(await stale, isNull);

        await started[0].succeed();
        await thirdStarted.future.timeout(const Duration(seconds: 3));
        await started[1].succeed();
        await fourthStarted.future.timeout(const Duration(seconds: 3));
        await started[2].succeed();
        await started[3].succeed();

        final results = await Future.wait([first, second, third, fourth]);
        expect(results.take(2).every((path) => path != null), isTrue);
        expect(results.skip(2).every((path) => path != null), isTrue);
        expect(FramePreview.activeForTest, 0);
        expect(FramePreview.queuedForTest, 0);
        expect(started, hasLength(4));
      }, getSystemTempDirectory: () => temp);
    },
  );
}
