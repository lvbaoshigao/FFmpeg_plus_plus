import 'package:ffmpegpp_gui/app.dart';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/log_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/wallpaper_background.dart';
import 'package:ffmpegpp_gui/widgets/window_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _LogState extends AppState {
  @override
  final List<LogEntry> logEntries = [];
}

void main() {
  group('LogPage', () {
    late AppState state;

    setUp(() {
      state = _LogState();
      state.config
        ..autoCheckUpdate = false
        ..language = 'en'
        ..cardStyle = 'gray'
        ..menuStyle = 'gray';
    });
    tearDown(() => state.dispose());

    Future<void> showPage(WidgetTester tester, Widget page) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(home: page),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('should use only the desktop shell window chrome', (
      tester,
    ) async {
      state.config.veryVerboseLogs = true;
      state.selectNav(5);
      await showPage(tester, const AppShell(mobile: false));
      final slots = tester.widgetList<CachedPageSlot>(
        find.byType(CachedPageSlot, skipOffstage: false),
      );
      expect(state.selectedNav, 5);
      expect(slots.where((slot) => slot.active).single.child, isA<LogPage>());
      expect(find.byType(LogPage, skipOffstage: false), findsOneWidget);
      expect(find.byType(WallpaperBackground), findsOneWidget);
      expect(
        find.byType(WindowChromeBar),
        usesWindowChrome ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('should keep the window chrome for a standalone route', (
      tester,
    ) async {
      await showPage(tester, const LogPage());
      expect(find.byType(WallpaperBackground), findsOneWidget);
      expect(
        find.byType(WindowChromeBar),
        usesWindowChrome ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('should filter diagnostic entries separately from errors', (
      tester,
    ) async {
      final timestamp = DateTime(2026);
      state.logEntries.addAll([
        LogEntry(
          timestamp: timestamp,
          message: '[process] start',
          category: 'trace',
        ),
        LogEntry(
          timestamp: timestamp,
          message: 'An unrelated failure',
          category: 'error',
        ),
      ]);
      await showPage(tester, const LogPage());
      expect(find.text('[process] start'), findsOneWidget);
      expect(find.text('An unrelated failure'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilterChip, 'Trace'));
      await tester.pumpAndSettle();
      expect(find.text('[process] start'), findsOneWidget);
      expect(find.text('An unrelated failure'), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}
