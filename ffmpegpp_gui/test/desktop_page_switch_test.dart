import 'package:ffmpegpp_gui/app.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _TickingPage extends StatefulWidget {
  const _TickingPage({super.key});
  @override
  State<_TickingPage> createState() => _TickingPageState();
}

class _TickingPageState extends State<_TickingPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  int ticks = 0;
  @override
  void initState() {
    super.initState();
    controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..addListener(() => ticks++)
          ..repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('hidden cached slots silence tickers and preserve page State', (
    tester,
  ) async {
    final key = GlobalKey<_TickingPageState>();
    Widget tree(bool active) => MaterialApp(
      home: IndexedStack(
        index: active ? 0 : 1,
        children: [
          CachedPageSlot(
            key: const ValueKey(0),
            active: active,
            child: _TickingPage(key: key),
          ),
          CachedPageSlot(
            key: const ValueKey(1),
            active: !active,
            child: const SizedBox(),
          ),
        ],
      ),
    );
    await tester.pumpWidget(tree(true));
    await tester.pump(const Duration(milliseconds: 50));
    final page = key.currentState!;
    expect(page.ticks, greaterThan(0));
    await tester.pumpWidget(tree(false));
    final hiddenTicks = page.ticks;
    await tester.pump(const Duration(milliseconds: 100));
    expect(page.ticks, hiddenTicks);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(tree(true));
    await tester.pump(const Duration(milliseconds: 50));
    expect(key.currentState, same(page));
    expect(page.ticks, greaterThan(hiddenTicks));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  testWidgets('desktop settings keeps one pane across rapid section switches', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.config.cardStyle = 'gray';
    state.config.menuStyle = 'gray';
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    final panes = find.byWidgetPredicate(
      (w) =>
          w is SingleChildScrollView &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('pane_'),
    );
    expect(panes, findsOneWidget);
    for (final section in ['advanced', 'processing', 'general', 'advanced']) {
      final icon = find.byKey(ValueKey('${section}_false')).first;
      await tester.tap(
        find.ancestor(of: icon, matching: find.byType(InkWell)).first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(panes, findsOneWidget);
      expect(find.byKey(ValueKey('pane_$section')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'preload');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(TextButton, Icons.my_location).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pane_advanced')), findsOneWidget);
    expect(panes, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
