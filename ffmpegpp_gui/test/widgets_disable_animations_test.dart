import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:provider/provider.dart';
import 'package:ffmpegpp_gui/widgets/animated_popup.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:ffmpegpp_gui/widgets/mobile_top_bar.dart';
import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:ffmpegpp_gui/widgets/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness extends StatefulWidget {
  const _Harness({required this.child});

  final Widget child;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool animationsDisabled = true;

  void toggleMotion() => setState(() {
    animationsDisabled = !animationsDisabled;
  });

  final _state = AppState()
    ..config.language = 'en'
    ..config.cardStyle = 'gray'
    ..config.glassEffect = 'gray';

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider<AppState>.value(
    value: _state,
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: animationsDisabled),
        child: child!,
      ),
      home: Scaffold(
        body: Column(
          children: [
            TextButton(
              key: const ValueKey('toggle-motion'),
              onPressed: toggleMotion,
              child: const Text('Toggle motion'),
            ),
            Expanded(child: Center(child: widget.child)),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'circular loader stops, resumes and keeps indeterminate semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const _Harness(
          child: AppCircularProgressIndicator(semanticsLabel: 'Loading'),
        ),
      );
      await tester.pumpAndSettle();
      final loader = find.byType(AppCircularProgressIndicator);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        0.75,
      );
      expect(tester.getSemantics(loader).label, 'Loading');
      expect(tester.getSemantics(loader).value, isEmpty);
      expect(
        tester.getSemantics(loader).getSemanticsData().role,
        SemanticsRole.loadingSpinner,
      );
      expect(tester.binding.transientCallbackCount, 0);

      await tester.tap(find.byKey(const ValueKey('toggle-motion')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        isNull,
      );
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await tester.tap(find.byKey(const ValueKey('toggle-motion')));
      await tester.pumpAndSettle();
      expect(tester.getSemantics(loader).value, isEmpty);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'OptionMenuBar opens and hides immediately with motion disabled',
    (tester) async {
      await tester.pumpWidget(
        const _Harness(
          child: SizedBox(
            width: 220,
            child: OptionMenuBar<String>(
              value: 'a',
              items: [OptionItem('a', 'Alpha'), OptionItem('b', 'Beta')],
              onChanged: _ignoreString,
            ),
          ),
        ),
      );

      await tester.tap(find.byType(OptionMenuBar<String>));
      await tester.pump();
      expect(find.text('Beta'), findsOneWidget);

      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(find.text('Beta'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ScaleMenuButton closes its overlay without a transition', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _Harness(
        child: ScaleMenuButton<String>(
          icon: Icons.more_vert,
          items: [OptionItem('edit', 'Edit')],
          onSelected: _ignoreString,
        ),
      ),
    );

    await tester.tap(find.byType(ScaleMenuButton<String>));
    await tester.pump();
    expect(find.text('Edit'), findsOneWidget);
    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(find.text('Edit'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'MobilePillBarLayout snaps expanded overflow and tracks runtime changes',
    (tester) async {
      await tester.pumpWidget(
        const _Harness(
          child: SizedBox(
            width: 300,
            child: MobilePillBarLayout(
              titlePill: Text('Title'),
              inlineActionLimit: 0,
              actions: [Text('Action')],
            ),
          ),
        ),
      );

      final more = find.byTooltip('More actions');
      expect(more, findsOneWidget);
      await tester.tap(more);
      await tester.pump();
      expect(find.byTooltip('Collapse'), findsOneWidget);
      final offsets = tester.widgetList<SlideTransition>(
        find.byType(SlideTransition),
      );
      expect(
        offsets.map((transition) => transition.position.value.dy),
        everyElement(0),
      );

      tester.state<_HarnessState>(find.byType(_Harness)).toggleMotion();
      await tester.pump();
      await tester.tap(find.byTooltip('Collapse'));
      await tester.pump();
      expect(find.byTooltip('More actions'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AppProgressBar static indeterminate state keeps spinner semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const _Harness(
          child: AppProgressBar(value: null, semanticsLabel: 'Loading'),
        ),
      );

      final node = tester.getSemantics(find.byType(AppProgressBar));
      expect(node.label, 'Loading');
      expect(node.value, isEmpty);
      expect(node.hasFlag(SemanticsFlag.hasImplicitScrolling), isFalse);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('showAnimatedMenu skips its route transition when disabled', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(child: _PopupMenuButton()));
    await tester.tap(find.text('Open menu'));
    await tester.pump();
    expect(find.text('Entry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop toast is visible immediately when animations are disabled',
    (tester) async {
      await tester.pumpWidget(const _Harness(child: _ToastButton()));
      await tester.tap(find.text('Show toast'));
      await tester.pump();
      expect(find.text('Instant toast'), findsOneWidget);
      final fadeAncestors = find.ancestor(
        of: find.text('Instant toast'),
        matching: find.byType(FadeTransition),
      );
      expect(fadeAncestors, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _PopupMenuButton extends StatelessWidget {
  const _PopupMenuButton();

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => showAnimatedMenu<void>(
      context: context,
      position: const Offset(40, 40),
      items: const [
        AnimatedMenuEntry(value: null, child: Text('Entry'), onTap: _ignore),
      ],
    ),
    child: const Text('Open menu'),
  );
}

class _ToastButton extends StatelessWidget {
  const _ToastButton();

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => showToast(context, 'Instant toast'),
    child: const Text('Show toast'),
  );
}

void _ignore() {}
void _ignoreString(String _) {}
