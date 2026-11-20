import 'package:ffmpegpp_gui/app.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _PageLedger {
  final requested = <int>[];
  final mounted = <int, _ProbePageState>{};
  final disposed = <int>[];
}

class _ProbePage extends StatefulWidget {
  const _ProbePage({super.key, required this.index, required this.ledger});
  final int index;
  final _PageLedger ledger;
  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage>
    with SingleTickerProviderStateMixin {
  final input = TextEditingController();
  late final AnimationController ticker;
  int ticks = 0;
  @override
  void initState() {
    super.initState();
    widget.ledger.mounted[widget.index] = this;
    ticker =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..addListener(() => ticks++)
          ..repeat();
  }

  @override
  void dispose() {
    ticker.dispose();
    input.dispose();
    widget.ledger.disposed.add(widget.index);
    if (identical(widget.ledger.mounted[widget.index], this)) {
      widget.ledger.mounted.remove(widget.index);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('Destination ${widget.index}'),
      TextField(key: ValueKey('input-${widget.index}'), controller: input),
    ],
  );
}

Future<AppState> _mount(
  WidgetTester tester,
  _PageLedger ledger, {
  required bool mobile,
  bool noPreload = false,
}) async {
  tester.view.physicalSize = mobile
      ? const Size(400, 800)
      : const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState();
  state.config
    ..language = 'en'
    ..autoCheckUpdate = false
    ..noPreload = noPreload
    ..navStyle = 'gray'
    ..cardStyle = 'gray'
    ..menuStyle = 'gray'
    ..pillStyle = 'gray';
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AppShell(
          mobile: mobile,
          pageBuilder: (context, index) {
            ledger.requested.add(index);
            return _ProbePage(
              key: ValueKey('destination-$index'),
              index: index,
              ledger: ledger,
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return state;
}

Future<void> _navigate(WidgetTester tester, AppState state, int index) async {
  state.selectNav(index);
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}

void main() {
  for (final mobile in [false, true]) {
    group('AppShell ${mobile ? "mobile" : "desktop"} page cache', () {
      if (mobile) {
        testWidgets(
          'should apply noPreload safely while a page swipe is active',
          (tester) async {
            final ledger = _PageLedger();
            final state = await _mount(tester, ledger, mobile: true);
            final home = ledger.mounted[0]!;
            final viewport = tester.getRect(find.byType(PageView));
            final drag = await tester.startGesture(viewport.center);
            await drag.moveBy(Offset(-viewport.width * 0.65, 0));
            await tester.pump();
            await state.updateConfig((config) => config..noPreload = true);
            await tester.pump();
            expect(ledger.mounted[0], same(home));
            expect(tester.takeException(), isNull);
            await drag.up();
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            await tester.pump();
            await tester.pump();
            expect(state.selectedNav, 1);
            expect(ledger.mounted.keys, [1]);
            expect(tester.takeException(), isNull);
          },
        );
      }

      testWidgets('should mount only home even after idle startup frames', (
        tester,
      ) async {
        final ledger = _PageLedger();
        await _mount(tester, ledger, mobile: mobile);
        await tester.pump(const Duration(seconds: 2));
        expect(ledger.requested, [0]);
        expect(ledger.mounted.keys, [0]);
        expect(ledger.disposed, isEmpty);
        if (mobile) {
          expect(
            tester.widget<PageView>(find.byType(PageView)).childrenDelegate,
            isA<SliverChildBuilderDelegate>(),
          );
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'should preserve two recent states and silence hidden tickers',
        (tester) async {
          final ledger = _PageLedger();
          final state = await _mount(tester, ledger, mobile: mobile);
          final home = ledger.mounted[0]!;
          await tester.enterText(
            find.byKey(const ValueKey('input-0')),
            'unsaved input',
          );
          await _navigate(tester, state, 1);
          expect(ledger.mounted.keys, containsAll([0, 1]));
          final hiddenTicks = home.ticks;
          await tester.pump(const Duration(milliseconds: 200));
          expect(home.ticks, hiddenTicks);
          await _navigate(tester, state, 0);
          expect(ledger.mounted[0], same(home));
          expect(home.input.text, 'unsaved input');
          expect(home.ticks, greaterThan(hiddenTicks));
          expect(state.selectedNav, 0);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'should evict the oldest focused page after visiting a third destination',
        (tester) async {
          final ledger = _PageLedger();
          final state = await _mount(tester, ledger, mobile: mobile);
          final home = ledger.mounted[0]!;
          final homeField = find.byKey(const ValueKey('input-0'));
          await tester.enterText(homeField, 'home draft');
          final homeInput = tester.widget<EditableText>(
            find.descendant(of: homeField, matching: find.byType(EditableText)),
          );
          expect(homeInput.focusNode.hasFocus, isTrue);
          await _navigate(tester, state, 1);
          expect(ledger.mounted[0], same(home));
          expect(home.input.text, 'home draft');
          expect(homeInput.focusNode.hasFocus, isFalse);
          await _navigate(tester, state, 3);
          expect(ledger.mounted.keys.toSet(), {1, 3});
          expect(ledger.disposed, contains(0));
          expect(home.mounted, isFalse);
          final currentField = find.byKey(const ValueKey('input-3'));
          await tester.enterText(currentField, 'current draft');
          final currentInput = tester.widget<EditableText>(
            find.descendant(
              of: currentField,
              matching: find.byType(EditableText),
            ),
          );
          expect(currentInput.focusNode.hasFocus, isTrue);
          final current = ledger.mounted[3];
          await _navigate(tester, state, 4);
          expect(ledger.mounted.length, 2);
          expect(ledger.mounted[3], same(current));
          expect(ledger.disposed, contains(1));
          expect(state.selectedNav, 4);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'should release inactive pages on pressure and preserve active input',
        (tester) async {
          final ledger = _PageLedger();
          final state = await _mount(tester, ledger, mobile: mobile);
          await _navigate(tester, state, 1);
          final current = ledger.mounted[1]!;
          await tester.enterText(
            find.byKey(const ValueKey('input-1')),
            'active draft',
          );
          tester.binding.handleMemoryPressure();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(ledger.mounted.keys, [1]);
          expect(ledger.disposed, contains(0));
          expect(ledger.mounted[1], same(current));
          expect(current.input.text, 'active draft');
          expect(state.selectedNav, 1);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('should retain only current content with noPreload enabled', (
        tester,
      ) async {
        final ledger = _PageLedger();
        final state = await _mount(
          tester,
          ledger,
          mobile: mobile,
          noPreload: true,
        );
        await _navigate(tester, state, 1);
        expect(ledger.mounted.keys, [1]);
        expect(ledger.disposed, contains(0));
        await _navigate(tester, state, 3);
        expect(ledger.mounted.keys, [3]);
        expect(ledger.disposed, contains(1));
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'should apply noPreload live and never restart background warming',
        (tester) async {
          final ledger = _PageLedger();
          final state = await _mount(tester, ledger, mobile: mobile);
          await _navigate(tester, state, 1);
          final current = ledger.mounted[1];
          await state.updateConfig((config) => config..noPreload = true);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(ledger.mounted.keys, [1]);
          expect(ledger.mounted[1], same(current));
          final built = List<int>.of(ledger.requested);
          await state.updateConfig((config) => config..noPreload = false);
          await tester.pump(const Duration(seconds: 2));
          expect(ledger.requested, built);
          expect(ledger.mounted.keys, [1]);
          await _navigate(tester, state, 3);
          expect(ledger.mounted.keys.toSet(), {1, 3});
          expect(tester.takeException(), isNull);
        },
      );
    });
  }
}
