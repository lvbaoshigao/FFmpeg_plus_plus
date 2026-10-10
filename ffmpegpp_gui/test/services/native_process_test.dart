import 'dart:io';

import 'package:ffmpegpp_gui/services/native_process.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NativeProcessManager', () {
    late NativeProcessManager process;

    setUp(() => process = NativeProcessManager());
    tearDown(() => process.dispose());

    test('should report a missing backend without waiting for ready', () async {
      await expectLater(
        process.start('/missing/ffmpegpp/libffmpegpp.so'),
        throwsArgumentError,
      );
      expect(process.isRunning, isFalse);
      final ready = await process.waitForReady().timeout(
        const Duration(seconds: 1),
      );
      expect(ready['type'], 'error');
      expect(ready['error'], contains('libffmpegpp.so'));
    });

    final library = Platform.environment['FFMPEGPP_TEST_LIBRARY'];
    test(
      'should start the bundled backend, check the environment and restart',
      () async {
        for (var attempt = 0; attempt < 2; attempt++) {
          await process.start(library!);
          final ready = await process.waitForReady(
            timeout: const Duration(seconds: 5),
          );
          expect(ready['type'], 'ready');
          await process.start(library);
          expect((await process.waitForReady())['type'], 'ready');
          final environment = await process.requestWithTimeout('check_env', 10);
          expect(environment['success'], isTrue);
          expect(environment['data']['all_ok'], isTrue);
          await process.shutdown();
          expect(process.isRunning, isFalse);
        }
      },
      skip: library == null
          ? 'Set FFMPEGPP_TEST_LIBRARY to the built library.'
          : false,
    );
  });
}
