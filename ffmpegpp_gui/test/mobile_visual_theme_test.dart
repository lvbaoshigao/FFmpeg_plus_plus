import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/theme/mobile_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile theme defaults and tolerates invalid persisted values', () {
    expect(AppConfig().mobileTheme, 'follow');
    for (final value in [null, 42, 'unknown', false]) {
      expect(AppConfig.fromJson({'mobile_theme': value}).mobileTheme, 'follow');
    }
    final config = AppConfig()..mobileTheme = 'miuix';
    final before = config.toJson();
    expect(before['mobile_theme'], 'miuix');
    expect(AppConfig.fromJson(before).mobileTheme, 'miuix');
    config.mobileTheme = 'follow';
    final after = config.toJson()..remove('mobile_theme');
    expect(after, Map.of(before)..remove('mobile_theme'));
  });
  test('resolver preserves desktop and follow themes exactly', () {
    final base = ThemeData();
    for (final mobile in [true, false]) {
      expect(
        resolveMobileVisualTheme('follow', isMobile: mobile).applyTo(base),
        same(base),
      );
    }
    expect(
      resolveMobileVisualTheme('miuix', isMobile: false).applyTo(base),
      same(base),
    );
    expect(resolveMobileVisualTheme('bad', isMobile: true).enabled, isFalse);
  });
  test(
    'mobile surfaces are neutral while accent font and errors are preserved',
    () {
      for (final brightness in Brightness.values) {
        final base = ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.red,
            brightness: brightness,
          ),
          fontFamily: 'TestFont',
        );
        final visual = resolveMobileVisualTheme('miuix', isMobile: true);
        final themed = visual.applyTo(base);
        expect(themed.colorScheme.primary, base.colorScheme.primary);
        expect(themed.colorScheme.error, base.colorScheme.error);
        expect(themed.textTheme, base.textTheme);
        final surface = themed.colorScheme.surface;
        expect(surface.r, surface.g);
        expect(surface.g, surface.b);
        expect(themed.extension<MobileVisualTheme>(), same(visual));
        expect(visual.menuRadius, greaterThan(12));
        expect(visual.copyWith(enabled: false).enabled, isFalse);
        expect(visual.lerp(visual, 0.5).enabled, isTrue);
      }
    },
  );
}
