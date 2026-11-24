import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/services/ai_credential_store.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:flutter_test/flutter_test.dart';

class _Credentials extends AiCredentialStore {
  _Credentials({this.migrationOk = true});
  final bool migrationOk;
  int restores = 0;
  @override
  Future<void> restore(AppConfig config) async {
    restores++;
  }

  @override
  Future<bool> save(AppConfig config, {bool migrationOnly = false}) async =>
      !migrationOnly || migrationOk;
}

void main() {
  late Directory root;
  late List<String> events;
  late DiagnosticTrace trace;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('config_trace_');
    events = <String>[];
    trace = DiagnosticTrace(events.add);
  });
  tearDown(() async {
    trace.dispose();
    await root.delete(recursive: true);
  });
  ConfigService create({
    AiCredentialStore? credentials,
    Future<Directory> Function()? supportDirectory,
  }) => ConfigService(
    credentialStore: credentials ?? _Credentials(),
    trace: trace,
    supportDirectory: supportDirectory ?? () async => root,
  );
  Future<File> file(String name) async {
    final dir = Directory('${root.path}${Platform.pathSeparator}ffmpegpp_gui');
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  String result(String op) =>
      events.singleWhere((e) => e.startsWith('$op.result '));

  test('settings toggle enables trace before credential restore', () async {
    await (await file(
      'settings.json',
    )).writeAsString(jsonEncode({'very_verbose_logs': true}));
    final credentials = _Credentials();
    final config = create(credentials: credentials);
    expect(trace.enabled, isFalse);
    await config.load();
    expect(config.config.veryVerboseLogs, isTrue);
    expect(trace.enabled, isTrue);
    expect(credentials.restores, 1);
    expect(result('storage.credential_restore'), contains('success=true'));
  });

  test('missing library and task history are successful empty reads', () async {
    trace.setEnabled(true);
    final config = create();
    expect(await config.loadLibrary(), isEmpty);
    expect(await config.loadTaskHistory(), isEmpty);
    expect(result('storage.library_load'), contains('reason=missing'));
    expect(result('storage.library_load'), contains('success=true'));
    expect(result('storage.task_history_load'), contains('reason=missing'));
    expect(result('storage.task_history_load'), contains('success=true'));
  });

  test('load skips and counts malformed entries', () async {
    trace.setEnabled(true);
    await (await file('config_library.json')).writeAsString(
      jsonEncode([
        {'ok': true},
        'bad',
        4,
      ]),
    );
    await (await file('task_history.json')).writeAsString(
      jsonEncode([
        {'ok': true},
        false,
      ]),
    );
    final config = create();
    expect(await config.loadLibrary(), hasLength(1));
    expect(await config.loadTaskHistory(), hasLength(1));
    expect(result('storage.library_load'), contains('skippedCount=2'));
    expect(result('storage.task_history_load'), contains('skippedCount=1'));
  });

  test('library/history writes preserve payload and trace counts', () async {
    trace.setEnabled(true);
    final config = create();
    final library = <Map<String, dynamic>>[
      {'kind': 'preset'},
    ];
    final history = <Map<String, dynamic>>[
      {'status': 'completed'},
    ];
    await config.saveLibrary(library);
    await config.saveTaskHistory(history);
    expect(
      jsonDecode(await (await file('config_library.json')).readAsString()),
      library,
    );
    expect(
      jsonDecode(await (await file('task_history.json')).readAsString()),
      history,
    );
    expect(result('storage.library_save'), contains('itemCount=1'));
    expect(result('storage.task_history_save'), contains('success=true'));
  });

  test(
    'settings directory failure reports error type without message',
    () async {
      trace.setEnabled(true);
      final config = create(
        supportDirectory: () async => throw StateError('private path'),
      );
      await config.load();
      expect(result('storage.settings_load'), contains('errorType=StateError'));
      expect(events.join(' '), isNot(contains('private path')));
    },
  );

  test('legacy migration failure is visible without secret material', () async {
    await (await file('settings.json')).writeAsString(
      jsonEncode({
        'very_verbose_logs': true,
        'ai_api_key': 'private-secret-value',
      }),
    );
    final config = create(credentials: _Credentials(migrationOk: false));
    await config.load();
    expect(
      result('storage.settings_migration'),
      contains('reason=migration_failed'),
    );
    expect(
      result('storage.settings_load'),
      contains('reason=migration_failed'),
    );
    expect(events.join(' '), isNot(contains('private-secret-value')));
  });
}
