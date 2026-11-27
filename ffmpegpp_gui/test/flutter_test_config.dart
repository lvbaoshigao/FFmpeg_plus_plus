import 'dart:async';
import 'dart:io';

import 'package:ffmpegpp_gui/services/ai_chat_history.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  late Directory suiteDirectory;
  var nextTest = 0;
  setUpAll(() async {
    suiteDirectory = await Directory.systemTemp.createTemp(
      'ffmpegpp_ai_history_tests_',
    );
    AiChatHistory.directoryOverride = suiteDirectory;
  });
  setUp(() {
    // Preserve the production leaf name for tests with virtual IOOverrides.
    final directory = Directory(
      '${suiteDirectory.path}/test_${nextTest++}/ai_history',
    );
    directory.createSync(recursive: true);
    AiChatHistory.directoryOverride = directory;
  });
  tearDownAll(() async {
    // Keep the override for this isolate's lifetime: late widget callbacks must
    // never fall back to HOME/XDG after cleanup. Each suite has its own root.
    await suiteDirectory.delete(recursive: true);
  });
  await testMain();
}
