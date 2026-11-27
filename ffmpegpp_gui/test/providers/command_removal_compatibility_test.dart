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

Future<void> _runTask(AppState state, TaskInfo task) async {
  state.addTaskForTest(task);
  final finished = Completer<void>();
  void onChange() {
    if (!state.processing &&
        state.tasks.single.status != TaskStatus.pending &&
        !finished.isCompleted) {
      finished.complete();
    }
  }

  state.addListener(onChange);
  try {
    await state.processNextTask();
    await finished.future.timeout(const Duration(seconds: 5));
  } finally {
    state.removeListener(onChange);
  }
}

void main() {
  test('default bindings omit the removed command navigation', () {
    expect(AppConfig().keyBindings, isNot(contains('nav_command')));
  });

  test(
    'saved bindings drop obsolete command navigation and retain custom keys',
    () {
      final bindings = <String, List<String>>{
        'nav_command': ['Alt', 'C'],
        'nav_projects': ['Alt', 'P'],
        'nav_settings': ['Control', '7'],
        'project_search': ['F3'],
        'custom_action': ['Shift', 'F9'],
      };
      final config = AppConfig.fromJson({'key_bindings': bindings});
      final expected = Map<String, List<String>>.from(bindings)
        ..remove('nav_command');
      expect(config.keyBindings, expected);
      expect(AppConfig.fromJson(config.toJson()).keyBindings, expected);
      expect(AppConfig(keyBindings: bindings).keyBindings, expected);
      expect(
        bindings,
        contains('nav_command'),
        reason: 'do not mutate the caller map',
      );
    },
  );

  test('command metadata cannot execute a task without a workflow', () async {
    final root = await Directory.systemTemp.createTemp('removed_command_');
    final state = _State();
    state.config.language = 'en';
    try {
      await _runTask(
        state,
        TaskInfo(
          id: 'saved-command',
          videoId: '',
          filename: 'input.mp4',
          inputPath: '${root.path}/input.mp4',
          outputPath: '${root.path}/untouched/output.mp4',
          config: TranscodeConfig(),
          command: const ['ffmpeg', '-version'],
        ),
      );
      expect(state.tasks.single.status, TaskStatus.failed);
      expect(
        state.tasks.single.error,
        contains('Task has no executable workflow'),
      );
      expect(await Directory('${root.path}/untouched').exists(), isFalse);
    } finally {
      state.dispose();
      await root.delete(recursive: true);
    }
  });

  test(
    'structured pipelines run with command metadata and no video id',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'pipeline_command_log_',
      );
      final input = await File('${root.path}/input.txt').writeAsString('media');
      final output = File('${root.path}/output.txt');
      final state = _State();
      try {
        final task = TaskInfo.fromJson(
          TaskInfo(
            id: 'pipeline',
            videoId: '',
            filename: 'input.txt',
            inputPath: input.path,
            outputPath: output.path,
            config: TranscodeConfig(),
            command: const ['retained', 'execution', 'log'],
            pipelineCalls: [
              BackendCall(
                action: '_file_copy',
                params: {'input': input.path, 'output': output.path},
              ),
            ],
          ).toJson(),
        );
        expect(task.command, ['retained', 'execution', 'log']);
        await _runTask(state, task);
        expect(state.tasks.single.status, TaskStatus.completed);
        expect(await output.readAsString(), 'media');
      } finally {
        state.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
