import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:ffmpegpp_gui/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'rejected update URL emits paired failure without sensitive URL',
    () async {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add)..setEnabled(true);
      await expectLater(
        downloadUpdateWithResult(
          'http://private-host/secret.exe?token=PRIVATE_KEY',
          trace: trace,
        ),
        throwsException,
      );
      expect(events.first, contains('update.download.start'));
      expect(
        events.last,
        allOf(
          contains('update.download.result'),
          contains('success=false'),
          contains('phase=validate_url'),
        ),
      );
      expect(events.join(), isNot(contains('PRIVATE_KEY')));
      expect(events.join(), isNot(contains('private-host')));
      expect(events.join(), isNot(contains('secret.exe')));
    },
  );

  test(
    'disabled update diagnostics preserve rejection without output',
    () async {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add);
      await expectLater(
        downloadUpdateWithResult('http://localhost/file.exe', trace: trace),
        throwsException,
      );
      expect(events, isEmpty);
    },
  );
}
