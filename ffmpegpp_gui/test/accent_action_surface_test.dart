import 'dart:math' as math;

import 'package:ffmpegpp_gui/theme/app_accent_surface.dart';
import 'package:ffmpegpp_gui/theme/app_neutral_surface.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_alert_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 主行动按钮不能再是「整块饱和主题色 + 无描边」：琥珀 / 亮黄主题下那会变成
/// 一块没有边界的荧光色板（用户反馈：按钮始终是黄色的，而且没有任何边框）。
void main() {
  group('Accent action surfaces', () {
    test('fill tints a neutral surface instead of raw primary', () {
      for (final seed in [0xFFFFCC00, 0xFFF59E0B, 0xFF5E6AD2, 0xFF009967]) {
        for (final theme in [
          AppTheme.dark(seedColor: seed),
          AppTheme.light(seedColor: seed),
        ]) {
          final scheme = theme.colorScheme;
          final accent = AppAccentSurface.fromScheme(scheme);
          final neutral = scheme.brightness == Brightness.dark
              ? AppNeutralSurface.darkCardHigh
              : AppNeutralSurface.lightCardHigh;
          expect(accent.fill, isNot(scheme.primary));
          // 与中性卡底同族：色差足够小，不会被读成一块纯色板。
          expect(_channelDistance(accent.fill, neutral), lessThan(80));
          // 明确描边（原先 primary 按钮是 BorderSide.none）。
          expect(accent.border, isNotNull);
          expect(accent.border.a, greaterThan(0));
          expect(accent.foreground, scheme.onSurface);
        }
      }
    });

    testWidgets('primary dialog action gets a tinted fill and a 1px border', (
      tester,
    ) async {
      for (final theme in [AppTheme.dark(), AppTheme.light()]) {
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(theme.brightness),
            theme: theme,
            home: Scaffold(
              body: AppAlertDialog(
                title: const Text('Confirm'),
                actions: [
                  TextButton(onPressed: () {}, child: const Text('Cancel')),
                  FilledButton(onPressed: () {}, child: const Text('Continue')),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Continue'),
        );
        final background = button.style!.backgroundColor!.resolve({})!;
        final border = button.style!.side!.resolve({})!;
        final accent = AppAccentSurface.fromScheme(theme.colorScheme);
        expect(background, accent.fill);
        expect(background, isNot(theme.colorScheme.primary));
        expect(border.color, accent.border);
        expect(border.width, 1);
      }
    });

    testWidgets('amber seed no longer paints a flat saturated yellow action', (
      tester,
    ) async {
      final theme = AppTheme.dark(seedColor: 0xFFFFCC00);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: AppAlertDialog(
              title: const Text('Confirm'),
              actions: [
                TextButton(onPressed: () {}, child: const Text('Cancel')),
                FilledButton(onPressed: () {}, child: const Text('Continue')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'),
      );
      final background = button.style!.backgroundColor!.resolve({})!;
      final primary = theme.colorScheme.primary;
      expect(background, isNot(primary));
      // 底色不再是「整块高饱和黄」：亮度与饱和度都明显低于原来的 primary 板砖
      // （深色主题下 primary 是浅琥珀，直接铺开就是那一片刺眼的黄）。
      expect(
        background.computeLuminance(),
        lessThan(primary.computeLuminance()),
      );
      expect(_saturation(background), lessThan(_saturation(primary)));
      expect(_saturation(background), lessThan(0.5));
    });

    test('picker confirm buttons share the same tinted surface', () {
      for (final theme in [AppTheme.dark(), AppTheme.light()]) {
        final accent = AppAccentSurface.fromScheme(theme.colorScheme);
        for (final picker in [
          theme.datePickerTheme.confirmButtonStyle!,
          theme.timePickerTheme.confirmButtonStyle!,
        ]) {
          expect(picker.backgroundColor!.resolve({}), accent.fill);
          expect(picker.foregroundColor!.resolve({}), accent.foreground);
          final shape = picker.shape!.resolve({})! as RoundedRectangleBorder;
          expect(shape.side.color, accent.border);
        }
      }
    });
  });
}

/// HSV 饱和度（0~1）：用来判断底色是否还是一片「纯色板砖」。
double _saturation(Color c) {
  final maxC = math.max(c.r, math.max(c.g, c.b));
  final minC = math.min(c.r, math.min(c.g, c.b));
  return maxC <= 0 ? 0 : (maxC - minC) / maxC;
}

int _channelDistance(Color a, Color b) => math.max(
  (a.r * 255 - b.r * 255).abs().round(),
  math.max(
    (a.g * 255 - b.g * 255).abs().round(),
    (a.b * 255 - b.b * 255).abs().round(),
  ),
);
