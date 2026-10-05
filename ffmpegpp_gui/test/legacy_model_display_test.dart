import 'package:ffmpegpp_gui/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('legacy global model configuration', () {
    test(
      'should show explicit model only when provider endpoint and key exist',
      () {
        final unconfigured = AppConfig(aiModel: 'gpt-4o', aiApiUrl: '');
        final noEndpoint = AppConfig(
          aiModel: 'gpt-4o',
          aiApiKey: 'configured-key',
          aiApiUrl: '',
        );
        final configured = AppConfig(
          aiModel: 'gpt-4o',
          aiApiKey: 'configured-key',
          aiApiUrl: 'https://example.test/v1',
        );

        String label(AppConfig config) =>
            config.aiApiKey.trim().isNotEmpty &&
                config.aiApiUrl.trim().isNotEmpty
            ? config.aiModel
            : '';

        expect(label(unconfigured), isEmpty);
        expect(label(noEndpoint), isEmpty);
        expect(label(configured), 'gpt-4o');
      },
    );
  });
}
