import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/theme/app_neutral_surface.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
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

  test('miuix actually changes something visible', () {
    final visual = resolveMobileVisualTheme('miuix', isMobile: true);
    // 圆角是主题切换最直观的差异（中性表面在暗色下只差几个 RGB 点）。
    expect(visual.cardRadius(16), greaterThan(16));
    expect(visual.cardRadius(20), greaterThan(20));
    // 关闭时逐像素不变。
    expect(
      resolveMobileVisualTheme('follow', isMobile: true).cardRadius(16),
      16,
    );
    // High / Highest 必须分两档，否则对话框与卡片同色。
    final themed = visual.applyTo(ThemeData());
    expect(
      themed.colorScheme.surfaceContainerHigh,
      isNot(themed.colorScheme.surfaceContainerLow),
    );
  });

  test('miuix dark modal surfaces stay neutral', () {
    final themed = resolveMobileVisualTheme(
      'miuix',
      isMobile: true,
    ).applyTo(AppTheme.dark());
    for (final surface in [
      themed.dialogTheme.backgroundColor!,
      themed.datePickerTheme.backgroundColor!,
      themed.timePickerTheme.backgroundColor!,
      themed.bottomSheetTheme.backgroundColor!,
    ]) {
      expect(surface.r, surface.g);
      expect(surface.g, surface.b);
    }
  });

  test('miuix modal themes replace date and time picker surfaces', () {
    final base = AppTheme.light();
    final themed = resolveMobileVisualTheme(
      'miuix',
      isMobile: true,
    ).applyTo(base);
    final expected = AppNeutralSurface.cardHigh(
      Brightness.light,
    ).withAlpha(246);

    expect(themed.dialogTheme.backgroundColor, expected);
    expect(themed.datePickerTheme.backgroundColor, expected);
    expect(themed.datePickerTheme.headerBackgroundColor, expected);
    expect(themed.timePickerTheme.backgroundColor, expected);
    expect(themed.datePickerTheme.shape, base.datePickerTheme.shape);
    expect(themed.timePickerTheme.shape, base.timePickerTheme.shape);
  });
}
