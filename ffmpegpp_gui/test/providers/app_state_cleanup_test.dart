import 'dart:async';
import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/task_process_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppState', () {
    test('should retain a cancelled run until workspace cleanup ends', () async {
      final root = await Directory.systemTemp.createTemp('pipeline_cleanup_');
      addTearDown(() => root.delete(recursive: true));
      final publicOutput = File('${root.path}/output.png');
      final input = await File('${root.path}/source.wav').writeAsString('audio');
      final stagedOutput = Completer<File>();
      final processExit = Completer<int>();
      final deleting = Completer<void>();
      final finishDelete = Completer<void>();
      final drained = Completer<void>();
      final state = AppState()
        ..setTaskProcessRunnerForTest(
          TaskProcessRunner(
            starter: (_, args) async {
              final staged = await File(args.last).writeAsString('partial');
              stagedOutput.complete(staged);
              return _ControlledProcess(processExit.future);
            },
          ),
        );
      state.config.maxConcurrentTasks = 1;
      addTearDown(state.dispose);
      addTearDown(() {
        if (!processExit.isCompleted) processExit.complete(0);
        if (!finishDelete.isCompleted) finishDelete.complete();
      });
      state.addTaskForTest(
        _task('visualizer', input.path, publicOutput.path, 'audio_spectrum'),
      );
      final nextOutput = File('${root.path}/next.wav');
      state.addTaskForTest(
        _task('next', input.path, nextOutput.path, '_file_copy'),
      );
      state.addListener(() {
        if (!state.processing &&
            state.tasks.last.status == TaskStatus.completed &&
            !drained.isCompleted) {
          drained.complete();
        }
      });

      const deadline = Duration(seconds: 5);
      await IOOverrides.runZoned(
        () async {
          await state.processNextTask();
          final staged = await stagedOutput.future.timeout(deadline);
          state.cancelTask('visualizer');
          processExit.complete(0);
          await deleting.future.timeout(deadline);

          expect(state.isTaskRunActiveForTest('visualizer'), isTrue);
          expect(state.tasks.first.status, TaskStatus.cancelled);
          expect(state.tasks.last.status, TaskStatus.pending);
          expect(await staged.exists(), isTrue);
          expect(await publicOutput.exists(), isFalse);

          finishDelete.complete();
          await drained.future.timeout(deadline);
          expect(await staged.parent.exists(), isFalse);
          expect(await publicOutput.exists(), isFalse);
          expect(state.tasks.first.status, TaskStatus.cancelled);
          expect(await nextOutput.readAsString(), 'audio');
        },
        getSystemTempDirectory: () => _GatedTempRoot(root, deleting, finishDelete),
      );
    });
  });
}

TaskInfo _task(String id, String input, String output, String action) => TaskInfo(
  id: id,
  videoId: id,
  filename: 'source.wav',
  inputPath: input,
  outputPath: output,
  config: TranscodeConfig(),
  pipelineCalls: [
    BackendCall(action: action, params: {'input': input, 'output': output}),
  ],
);

final class _GatedTempRoot implements Directory {
  _GatedTempRoot(this.directory, this.deleting, this.finishDelete);

  final Directory directory;
  final Completer<void> deleting;
  final Completer<void> finishDelete;

  @override
  Future<Directory> createTemp([String? prefix]) async => _GatedWorkspace(
    await directory.createTemp(prefix),
    deleting,
    finishDelete.future,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _GatedWorkspace implements Directory {
  _GatedWorkspace(this.directory, this.deleting, this.finishDelete);

  final Directory directory;
  final Completer<void> deleting;
  final Future<void> finishDelete;

  @override
  String get path => directory.path;

  @override
  Future<bool> exists() => directory.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    deleting.complete();
    await finishDelete;
    return directory.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ControlledProcess implements Process {
  _ControlledProcess(this.exitCode);

  @override
  final Future<int> exitCode;

  @override
  int get pid => 1;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => throw UnsupportedError('No stdin for this process');

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
