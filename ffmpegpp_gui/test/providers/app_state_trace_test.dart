import 'dart:async';
import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryConfig extends ConfigService {
  @override
  Future<void> saveTaskHistory(List<Map<String, dynamic>> entries) async {}
}

class _State extends AppState {
  final _memory = _MemoryConfig();
  @override
  ConfigService get configService => _memory;
}

void main() {
  late Directory root;
  late AppState state;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('task_trace_');
    state = _State();
  });
  tearDown(() async {
    state.dispose();
    await root.delete(recursive: true);
  });

  Future<void> execute({required bool enabled, bool retry = false}) async {
    state.config.veryVerboseLogs = enabled;
    state.diagnosticTrace.setEnabled(enabled);
    final input = await File(
      '${root.path}/private-source.wav',
    ).writeAsString('audio');
    state.addTaskForTest(
      TaskInfo(
        id: 'private-task-id',
        videoId: 'video',
        filename: 'private-source.wav',
        inputPath: input.path,
        outputPath: '${root.path}/output.wav',
        config: TranscodeConfig(),
        pipelineCalls: [
          if (retry)
            BackendCall(
              action: 'unknown',
              params: {},
              retries: 1,
              errorPolicy: 'continue',
            ),
          BackendCall(
            action: '_file_copy',
            params: {'input': input.path, 'output': '${root.path}/output.wav'},
          ),
        ],
      ),
    );
    final drained = Completer<void>();
    state.addListener(() {
      if (!state.processing &&
          state.tasks.single.status == TaskStatus.completed &&
          !drained.isCompleted) {
        drained.complete();
      }
    });
    await state.processNextTask();
    await drained.future.timeout(const Duration(seconds: 5));
    expect(await File('${root.path}/output.wav').readAsString(), 'audio');
  }

  test(
    'traces task and step results without requiring ordinary debug mode',
    () async {
      await execute(enabled: true);
      final logs = state.logEntries
          .where((entry) => entry.category == 'trace')
          .map((entry) => entry.message)
          .toList();
      expect(state.config.debugMode, isFalse);
      expect(logs, contains(contains('task.run.start')));
      expect(
        logs,
        contains(
          allOf(
            contains('task.run.result'),
            contains('success=true'),
            contains('status=completed'),
          ),
        ),
      );
      expect(
        logs,
        contains(
          allOf(contains('pipeline.step.result'), contains('success=true')),
        ),
      );
      expect(logs.join(), isNot(contains('private-source')));
      expect(logs.join(), isNot(contains('private-task-id')));
      expect(logs.join(), isNot(contains(root.path)));
    },
  );

  test('ordinary task execution emits no trace while disabled', () async {
    await execute(enabled: false);
    expect(
      state.logEntries.where((entry) => entry.category == 'trace'),
      isEmpty,
    );
  });

  test(
    'records retries and continue policy separately from task success',
    () async {
      await execute(enabled: true, retry: true);
      final logs = state.logEntries.map((entry) => entry.message).toList();
      expect(logs, contains(contains('pipeline.step.retry')));
      expect(
        logs,
        contains(
          allOf(contains('pipeline.step.result'), contains('success=false')),
        ),
      );
      expect(logs, contains(contains('pipeline.step.skip')));
      expect(
        logs,
        contains(allOf(contains('task.run.result'), contains('success=true'))),
      );
    },
  );

  test('disposed state ignores all later log entries', () {
    state.config.debugMode = true;
    state.addLog('before');
    state.dispose();
    final version = state.logVersion;
    state.addLog('after', category: 'error');
    expect(state.logVersion, version);
    expect(
      state.logEntries.map((entry) => entry.message),
      isNot(contains('after')),
    );
    // tearDown owns disposal for the replacement instance.
    state = _State();
  });
}
