import 'package:ffmpegpp_gui/services/progress_feature_availability.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('progress feature settings visibility', () {
    test(
      'hides the Super Island setting when the ROM lacks island support',
      () {
        expect(shouldShowSuperIslandProgressSetting(null), isFalse);
        expect(shouldShowSuperIslandProgressSetting({}), isFalse);
        expect(
          shouldShowSuperIslandProgressSetting({'islandSupported': false}),
          isFalse,
        );
        expect(
          shouldShowSuperIslandProgressSetting({'islandSupported': true}),
          isTrue,
        );
      },
    );

    test('shows Fluid Cloud only on ColorOS with a visible provider', () {
      expect(shouldShowFluidCloudProgressSetting(null), isFalse);
      expect(
        shouldShowFluidCloudProgressSetting({
          'colorOs': true,
          'intentShareAvailable': true,
        }),
        isTrue,
      );
      expect(
        shouldShowFluidCloudProgressSetting({
          'colorOs': false,
          'intentShareAvailable': true,
          'integrationConfigured': true,
        }),
        isFalse,
      );
      expect(
        shouldShowFluidCloudProgressSetting({
          'colorOs': true,
          'intentShareAvailable': false,
          'integrationConfigured': true,
        }),
        isFalse,
      );
    });

    test(
      'requires approved release integration identifiers before enabling',
      () {
        expect(isFluidCloudIntegrationConfigured(null), isFalse);
        expect(isFluidCloudIntegrationConfigured({}), isFalse);
        expect(
          isFluidCloudIntegrationConfigured({'integrationConfigured': false}),
          isFalse,
        );
        expect(
          isFluidCloudIntegrationConfigured({'integrationConfigured': true}),
          isTrue,
        );
      },
    );
  });
}
