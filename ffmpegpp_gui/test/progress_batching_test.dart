import 'dart:async';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/backend_client.dart';
import 'package:flutter_test/flutter_test.dart';

// Keep AppState's real public queue/subscription path; only replace the external
// encoder so progress timing and completion are deterministic.
class _ProgressBackend extends BackendClient {
  _ProgressBackend(super.process);

  final updates = StreamController<ProgressUpdate>.broadcast();
  final reply = Completer<Map<String, dynamic>>();
  String? runningTaskId;

  @override
  Stream<ProgressUpdate> get progressStream => updates.stream;

  @override
  Future<Map<String, dynamic>> transcode(
    String taskId, {
    required String input,
    required String output,
    required Map<String, dynamic> options,
  }) {
    runningTaskId = taskId;
    return reply.future;
  }

  void emit(double progress) => updates.add(
    ProgressUpdate.fromJson({'task_id': runningTaskId!, 'progress': progress}),
  );

  void complete() =>
      reply.complete({'success': true, 'data': <String, dynamic>{}});

  @override
  void dispose() {
    unawaited(updates.close());
    super.dispose();
  }
}

class _ProgressState extends AppState {
  late final encoder = _ProgressBackend(pythonProcess);

  @override
  BackendClient get backend => encoder;

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

class _PipelineProgressBackend extends BackendClient {
  _PipelineProgressBackend(super.process);

  final updates = StreamController<ProgressUpdate>.broadcast();
  final replies = List.generate(2, (_) => Completer<Map<String, dynamic>>());
  int callsStarted = 0;
  String? runningTaskId;

  @override
  Stream<ProgressUpdate> get progressStream => updates.stream;

  @override
  Future<Map<String, dynamic>> transcode(
    String taskId, {
    required String input,
    required String output,
    required Map<String, dynamic> options,
  }) {
    runningTaskId = taskId;
    return replies[callsStarted++].future;
  }

  void emit(double progress, String remaining) => updates.add(
    ProgressUpdate.fromJson({
      'task_id': runningTaskId!,
      'progress': progress,
      'remaining': remaining,
    }),
  );

  void complete(int index) =>
      replies[index].complete({'success': true, 'data': <String, dynamic>{}});

  @override
  void dispose() {
    unawaited(updates.close());
    super.dispose();
  }
}

class _PipelineProgressState extends AppState {
  late final encoder = _PipelineProgressBackend(pythonProcess);

  @override
  BackendClient get backend => encoder;

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

Future<_ProgressState> _start(WidgetTester tester) async {
  final state = _ProgressState();
  state.addTaskForTest(
    TaskInfo(
      id: 'progress-task',
      videoId: 'video',
      filename: 'input.mp4',
      inputPath: 'input.mp4',
      outputPath: 'output.mp4',
      config: TranscodeConfig(),
      status: TaskStatus.pending,
    ),
  );
  state.processSingleTask('progress-task');
  await tester.pump();
  expect(state.encoder.runningTaskId, 'progress-task');
  expect(state.tasks.single.status, TaskStatus.processing);
  return state;
}

void main() {
  testWidgets('continuous progress flushes the latest value every 300ms', (
    tester,
  ) async {
    final state = await _start(tester);
    addTearDown(state.dispose);
    final version = state.tasksVersion;

    state.encoder.emit(10);
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.tasks.single.progress, 0);
    state.encoder.emit(20);
    await tester.pump(const Duration(milliseconds: 100));
    state.encoder.emit(30);
    await tester.pump(const Duration(milliseconds: 99));
    expect(state.tasks.single.progress, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      state.tasks.single.progress,
      30,
      reason: 'A continuing stream must not postpone the first batch',
    );
    expect(state.tasksVersion, version + 1);

    state.encoder.emit(40);
    await tester.pump(const Duration(milliseconds: 100));
    state.encoder.emit(50);
    await tester.pump(const Duration(milliseconds: 100));
    state.encoder.emit(60);
    await tester.pump(const Duration(milliseconds: 99));
    expect(state.tasks.single.progress, 30);
    await tester.pump(const Duration(milliseconds: 1));
    expect(state.tasks.single.progress, 60);
    expect(state.tasksVersion, version + 2);

    state.encoder.complete();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    state.dispose();
  });

  testWidgets('pending progress cannot revive a completed task', (
    tester,
  ) async {
    final state = await _start(tester);
    addTearDown(state.dispose);
    state.encoder.emit(45);
    await tester.pump(const Duration(milliseconds: 100));
    state.encoder.complete();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(state.tasks.single.status, TaskStatus.completed);
    expect(state.tasks.single.progress, 100);
    final version = state.tasksVersion;

    await tester.pump(const Duration(milliseconds: 400));
    expect(state.tasks.single.status, TaskStatus.completed);
    expect(state.tasks.single.progress, 100);
    expect(state.tasksVersion, version);
    expect(tester.takeException(), isNull);
    state.dispose();
  });

  testWidgets('disposing cancels the scheduled progress batch', (tester) async {
    final state = await _start(tester);
    var disposed = false;
    addTearDown(() {
      if (!disposed) state.dispose();
    });
    state.encoder.emit(45);
    await tester.pump(const Duration(milliseconds: 100));
    final version = state.tasksVersion;
    state.dispose();
    disposed = true;

    await tester.pump(const Duration(milliseconds: 400));
    expect(
      state.tasks.single.progress,
      0,
      reason: 'Disposal must cancel mutation as well as notifications',
    );
    expect(state.tasksVersion, version);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pipeline drops prior-step batches and clears ETA on transition', (
    tester,
  ) async {
    final state = _PipelineProgressState();
    final finished = Completer<TaskStatus>();
    state.onTaskFinished = (_, status) => finished.complete(status);
    addTearDown(state.dispose);
    state.addTaskForTest(
      TaskInfo(
        id: 'pipeline-progress-task',
        videoId: 'video',
        filename: 'input.mp4',
        inputPath: 'input.mp4',
        outputPath: 'output.mp4',
        config: TranscodeConfig(),
        pipelineCalls: [
          BackendCall(
            action: 'transcode',
            params: {
              'input': 'input.mp4',
              'output': 'first.mp4',
              'options': <String, dynamic>{},
            },
          ),
          BackendCall(
            action: 'transcode',
            params: {
              'input': 'first.mp4',
              'output': 'output.mp4',
              'options': <String, dynamic>{},
            },
          ),
        ],
      ),
    );
    state.processSingleTask('pipeline-progress-task');
    await tester.pump();
    expect(state.encoder.callsStarted, 1);

    state.encoder.emit(40, '00:10');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.tasks.single.remaining, '00:10');

    // Queue a final sample from step A, then advance to B before its batch flush.
    state.encoder.emit(80, '00:01');
    await tester.pump();
    state.encoder.complete(0);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(state.encoder.callsStarted, 2);
    expect(state.tasks.single.currentCallIndex, 1);
    expect(state.tasks.single.remaining, '');

    await tester.pump(const Duration(milliseconds: 300));
    expect(state.tasks.single.currentCallIndex, 1);
    expect(state.tasks.single.callProgresses, [1.0, 0.0]);
    expect(state.tasks.single.progress, 50);
    expect(state.tasks.single.remaining, '');

    state.encoder.emit(25, '00:30');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.tasks.single.callProgresses, [1.0, 0.25]);
    expect(state.tasks.single.progress, 62.5);
    expect(state.tasks.single.remaining, '00:30');

    state.encoder.complete(1);
    // Output-size probing uses real filesystem I/O; drain it alongside fake
    // microtasks before disposing the task's owning state.
    for (var attempt = 0; attempt < 50 && !finished.isCompleted; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(finished.isCompleted, isTrue);
    expect(await finished.future, TaskStatus.completed);
    expect(state.tasks.single.status, TaskStatus.completed);
  });
}
