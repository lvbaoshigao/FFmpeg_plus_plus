import 'package:ffmpegpp_gui/theme/app_accent_surface.dart';
import 'package:ffmpegpp_gui/theme/app_neutral_surface.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_alert_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder _dialogSurface() => find.descendant(
  of: find.byType(Dialog),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Material && widget.shape == AppTheme.dark().dialogTheme.shape,
  ),
);

void main() {
  group('AppTheme dialog visuals', () {
    test(
      'uses a legible layered dialog surface and shared rounded picker shapes',
      () {
        for (final theme in [AppTheme.dark(), AppTheme.light()]) {
          final dialog = theme.dialogTheme;
          final shape = dialog.shape! as RoundedRectangleBorder;
          final radius = shape.borderRadius.resolve(TextDirection.ltr).topLeft;

          expect(radius, const Radius.circular(28));
          expect(dialog.backgroundColor!.a, greaterThan(0.9));
          expect(dialog.surfaceTintColor, Colors.transparent);
          expect(dialog.titleTextStyle!.fontSize, greaterThanOrEqualTo(18));
          expect(
            dialog.titleTextStyle!.fontWeight!.value,
            greaterThanOrEqualTo(FontWeight.w600.value),
          );
          expect(
            dialog.contentTextStyle!.color,
            theme.colorScheme.onSurfaceVariant,
          );
          expect(dialog.constraints!.maxWidth, 560);

          expect(theme.datePickerTheme.backgroundColor, dialog.backgroundColor);
          expect(theme.datePickerTheme.shape, dialog.shape);
          expect(
            theme.datePickerTheme.cancelButtonStyle!.backgroundColor!.resolve(
              {},
            ),
            theme.colorScheme.surfaceContainerHighest,
          );
          // 确认按钮走「主题色克制着色」，不再是满色 primary。
          expect(
            theme.datePickerTheme.confirmButtonStyle!.backgroundColor!.resolve(
              {},
            ),
            AppAccentSurface.fromScheme(theme.colorScheme).fill,
          );
          expect(theme.timePickerTheme.backgroundColor, dialog.backgroundColor);
          expect(theme.timePickerTheme.shape, dialog.shape);
          expect(
            theme.timePickerTheme.cancelButtonStyle!.backgroundColor!.resolve(
              {},
            ),
            theme.colorScheme.surfaceContainerHighest,
          );
          expect(
            theme.timePickerTheme.confirmButtonStyle!.backgroundColor!.resolve(
              {},
            ),
            AppAccentSurface.fromScheme(theme.colorScheme).fill,
          );
          final hourText =
              theme.timePickerTheme.hourMinuteTextColor! as WidgetStateColor;
          expect(
            hourText.resolve({WidgetState.selected}),
            theme.colorScheme.onPrimary,
          );
          expect(hourText.resolve({}), theme.colorScheme.onSurface);
          final periodText =
              theme.timePickerTheme.dayPeriodTextColor! as WidgetStateColor;
          expect(
            periodText.resolve({WidgetState.selected}),
            theme.colorScheme.onPrimary,
          );
          expect(periodText.resolve({}), theme.colorScheme.onSurfaceVariant);
        }
      },
    );

    test('dark glass modal chrome stays neutral without a warm cast', () {
      for (final effect in ['liquid', 'blur']) {
        final theme = AppTheme.dark(glassEffect: effect);
        final surface = theme.dialogTheme.backgroundColor!;
        expect(surface.r, surface.g);
        expect(surface.g, surface.b);
        expect(surface.a, lessThan(1));
        final rim =
            (theme.dialogTheme.shape! as RoundedRectangleBorder).side.color;
        expect(rim.r, rim.g);
        expect(rim.g, rim.b);
        expect(theme.datePickerTheme.backgroundColor, surface);
        expect(theme.timePickerTheme.backgroundColor, surface);
        expect(theme.bottomSheetTheme.backgroundColor, surface);
      }
      const control = AppNeutralSurface.darkControl;
      expect(control.r, control.g);
      expect(control.g, control.b);
    });

    testWidgets('keeps Material visuals on iPhone, Android, and desktop', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      for (final (size, platform) in [
        (const Size(320, 720), TargetPlatform.android),
        (const Size(390, 844), TargetPlatform.iOS),
        (const Size(412, 915), TargetPlatform.android),
        (const Size(1440, 900), TargetPlatform.macOS),
      ]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey((size, platform)),
            theme: AppTheme.dark().copyWith(platform: platform),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AppAlertDialog(
                      title: const Text('Warning'),
                      content: Builder(
                        builder: (context) => Text(
                          'Material platform: ${Theme.of(context).platform.name}',
                        ),
                      ),
                      actions: const [
                        TextButton(onPressed: null, child: Text('Cancel')),
                        FilledButton(onPressed: null, child: Text('Continue')),
                      ],
                    ),
                  ),
                  child: const Text('Open warning'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open warning'));
        await tester.pumpAndSettle();

        expect(find.text('Warning'), findsOneWidget);
        expect(
          find.text('Material platform: ${platform.name}'),
          findsOneWidget,
        );
        final dialog = tester.getRect(_dialogSurface());
        if (size.width <= 500) {
          expect(dialog.width, lessThan(size.width));
          expect(dialog.width, greaterThan(250));
        } else {
          expect(dialog.width, lessThanOrEqualTo(560));
        }
        expect(
          tester.getSize(find.widgetWithText(TextButton, 'Cancel')).height,
          greaterThanOrEqualTo(44),
        );
        expect(
          tester.getSize(find.widgetWithText(FilledButton, 'Continue')).height,
          greaterThanOrEqualTo(44),
        );
        final cancel = tester.getRect(
          find.widgetWithText(TextButton, 'Cancel'),
        );
        final primary = tester.getRect(
          find.widgetWithText(FilledButton, 'Continue'),
        );
        expect(cancel.width, closeTo(primary.width, .01));
        expect(cancel.top, closeTo(primary.top, .01));
        expect(cancel.right, lessThan(primary.left));
        expect(
          Theme.of(tester.element(find.text('Open warning'))).platform,
          platform,
        );
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('wraps CJK large-text actions without overflow', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 720);
      for (final labels in [
        const ['继续'],
        const ['取消', '继续'],
        const ['取消操作', '继续执行', '查看详情', '更多信息'],
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AppAlertDialog(
                      title: const Text('提示'),
                      content: const Text('请仔细确认此操作的内容和结果。'),
                      actions: [
                        for (final label in labels)
                          TextButton(onPressed: null, child: Text(label)),
                      ],
                    ),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();

        expect(
          MediaQuery.textScalerOf(
            tester.element(find.byType(AppAlertDialog)),
          ).scale(10),
          20,
        );
        for (var index = 0; index < labels.length; index++) {
          final action = find.widgetWithText(TextButton, labels[index]);
          expect(action, findsOneWidget);
          expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
          if (index > 0) {
            final previous = tester.getRect(
              find.widgetWithText(TextButton, labels[index - 1]),
            );
            expect(tester.getRect(action).top, greaterThan(previous.bottom));
          }
        }
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('preserves async action callback, result, and button type', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      final navigatorKey = GlobalKey<NavigatorState>();
      Future<bool?>? dialogResult;
      var callbackCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                dialogResult = showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AppAlertDialog(
                    title: const Text('Confirm'),
                    actions: [
                      TextButton(
                        onPressed: () async {
                          await Future<void>.delayed(Duration.zero);
                          callbackCount++;
                          Navigator.of(dialogContext).pop(true);
                        },
                        child: const Text('Accept'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Accept'), findsOneWidget);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(callbackCount, 1);
      expect(await dialogResult, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps barrier cancellation and back results intact', (
      tester,
    ) async {
      Future<bool?>? result;
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                result = showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => AppAlertDialog(
                    semanticLabel: 'Confirmation',
                    title: const Text('Keep open'),
                    actions: [
                      TextButton(
                        onPressed: () => calls++,
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('Open protected alert'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open protected alert'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Keep open'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'keeps cancel neutral, primary themed, and destructive distinct',
      (tester) async {
        final theme = AppTheme.dark();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: AppAlertDialog(
                title: const Text('Actions'),
                actions: [
                  const TextButton(onPressed: null, child: Text('Cancel')),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () {},
                    child: const Text('Delete'),
                  ),
                  const AppDialogAction(
                    role: AppDialogActionRole.primary,
                    child: OutlinedButton(
                      onPressed: null,
                      child: Text('Continue'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final cancel = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Cancel'),
        );
        final destructive = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Delete'),
        );
        final primary = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Continue'),
        );
        expect(
          cancel.style!.backgroundColor!.resolve({}),
          AppNeutralSurface.darkControl,
        );
        expect(
          destructive.style!.backgroundColor!.resolve({}),
          theme.colorScheme.error,
        );
        final accent = AppAccentSurface.fromScheme(theme.colorScheme);
        expect(primary.style!.backgroundColor!.resolve({}), accent.fill);
        expect(primary.style!.backgroundColor!.resolve({}), isNot(accent.fill.withValues(alpha: 0.55)));
        expect(
          primary.style!.backgroundColor!.resolve({WidgetState.disabled}),
          isNot(theme.colorScheme.primary),
        );
        expect(primary.onPressed, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('scrolls complete alert above keyboard at large text', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 560);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      Future<bool?>? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2.6)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  result = showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AppAlertDialog(
                      title: const Text('保存修改'),
                      content: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('请确认修改后的内容，然后继续保存。'),
                          TextField(autofocus: true),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('继续保存'),
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('Open compact'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open compact'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(_dialogSurface()).bottom, lessThanOrEqualTo(260));
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('继续保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续保存'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('preserves explicitly wide editor constraints', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AppAlertDialog(
                  constraints: BoxConstraints(maxWidth: 720),
                  content: SizedBox(width: 660, height: 100),
                ),
              ),
              child: const Text('Open wide editor'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open wide editor'));
      await tester.pumpAndSettle();
      expect(tester.getSize(_dialogSurface()).width, greaterThan(560));
      expect(tester.takeException(), isNull);
    });
  });
}
