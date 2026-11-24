import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'balance fallback records endpoint outcomes without values or credentials',
    () async {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add)..setEnabled(true);
      final profile = AiProfile(
        apiUrl: 'https://private.example/v1/chat/completions',
        apiKey: 'PRIVATE_KEY',
      );
      final result = await http.runWithClient(
        () => fetchAiBalance(profile, trace: trace),
        () => MockClient(
          (request) async => request.url.path.endsWith('credit_grants')
              ? http.Response('PRIVATE_ERROR', 404)
              : http.Response('{"data":{"quota":123456789}}', 200),
        ),
      );
      expect(result, isNotNull);
      expect(events, contains(contains('ai.balance.endpoint')));
      expect(
        events,
        contains(
          allOf(contains('ai.balance.result'), contains('success=true')),
        ),
      );
      expect(events.join(), isNot(contains('PRIVATE')));
      expect(events.join(), isNot(contains('private.example')));
      expect(events.join(), isNot(contains('123456789')));
    },
  );

  test(
    'unavailable balance records failure while preserving null result',
    () async {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add)..setEnabled(true);
      final result = await http.runWithClient(
        () => fetchAiBalance(AiProfile(apiKey: 'secret'), trace: trace),
        () => MockClient(
          (_) async => throw http.ClientException('private error'),
        ),
      );
      expect(result, isNull);
      expect(
        events.last,
        allOf(contains('ai.balance.result'), contains('success=false')),
      );
      expect(events.join(), isNot(contains('private error')));
    },
  );

  test(
    'balance request emits no trace when diagnostics are disabled',
    () async {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add);
      final result = await http.runWithClient(
        () => fetchAiBalance(AiProfile(apiKey: 'secret'), trace: trace),
        () => MockClient(
          (_) async => http.Response('{"total_available":10}', 200),
        ),
      );
      expect(result, isNotNull);
      expect(events, isEmpty);
    },
  );
}
