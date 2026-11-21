import 'package:ffmpegpp_gui/app.dart' show smoothRoute;
import 'package:ffmpegpp_gui/theme/app_page_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _front = ValueKey('front');
const _back = ValueKey('back');

Future<void> _gesture(
  WidgetTester tester,
  String method, {
  double progress = 0,
  SwipeEdge edge = SwipeEdge.left,
  bool button = false,
}) async {
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, <String, dynamic>{
      'touchOffset': button
          ? null
          : <double>[edge == SwipeEdge.left ? 5 : width - 5, 300],
      'progress': progress,
      'swipeEdge': edge.index,
    })),
    (_) {},
  );
}

Future<(GlobalKey<NavigatorState>, PageRoute<void>)> _mount(WidgetTester tester, {bool smooth = false, bool predictive = true, bool reduced = false, bool canPop = true}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(MaterialApp(
    navigatorKey: navigator,
    theme: ThemeData(platform: TargetPlatform.android, pageTransitionsTheme: PageTransitionsTheme(builders: {
      TargetPlatform.android: AppPageTransitionsBuilder(predictiveBack: predictive),
    })),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduced), child: child!),
    home: const SizedBox.expand(key: _back),
  ));
  final page = PopScope(canPop: canPop, child: const SizedBox.expand(key: _front));
  final route = (smooth ? smoothRoute<void>(page) : MaterialPageRoute<void>(builder: (_) => page, allowSnapshotting: false)) as PageRoute<void>;
  navigator.currentState!.push(route);
  await tester.pumpAndSettle();
  return (navigator, route);
}

double _x(WidgetTester tester, Key key) => tester.getTopLeft(find.byKey(key, skipOffstage: false)).dx;

void main() {
  for (final smooth in [false, true]) {
    final label = smooth ? 'smoothRoute' : 'theme route';
    testWidgets('$label disabling prediction during cancellation releases exactly once', (tester) async {
      final (navigator, route) = await _mount(tester, smooth: smooth);
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', progress: .6);
      await tester.pump();
      await _gesture(tester, 'cancelBackGesture');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(route.animation!.isAnimating, isTrue);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        themeAnimationDuration: Duration.zero,
        theme: ThemeData(platform: TargetPlatform.android,
          pageTransitionsTheme: const PageTransitionsTheme(builders: {
            TargetPlatform.android: AppPageTransitionsBuilder(predictiveBack: false),
          })),
        home: const SizedBox.expand(key: _back),
      ));
      expect(route.isActive, isTrue, reason: 'Only the detector was replaced; its route/controller must survive');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'SDK cancellation and detector disposal must not both decrement the Navigator gesture counter');
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      expect(route.animation!.value, 1);
    });
    testWidgets('$label predictive updates follow full-width progress from either edge', (tester) async {
      final (navigator, route) = await _mount(tester, smooth: smooth);
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      for (final edge in SwipeEdge.values) {
        await _gesture(tester, 'startBackGesture', edge: edge);
        await tester.pump();
        expect(navigator.currentState!.userGestureInProgress, isTrue);
        for (final progress in [.15, .6, .3]) {
          await _gesture(tester, 'updateBackGestureProgress', progress: progress, edge: edge);
          await tester.pump();
          expect(route.animation!.value, closeTo(1 - progress, 1e-6));
          final direction = edge == SwipeEdge.left ? 1.0 : -1.0;
          expect(_x(tester, _front), closeTo(width * progress * direction, .01));
          expect(_x(tester, _back), closeTo(-width * .04 * (1 - progress), .01));
        }
        await _gesture(tester, 'cancelBackGesture');
        await tester.pumpAndSettle();
        expect(_x(tester, _front), 0);
        expect(navigator.currentState!.userGestureInProgress, isFalse);
      }
    });

    testWidgets('$label commit continues from the last drag frame to fully offscreen', (tester) async {
      final (navigator, route) = await _mount(tester, smooth: smooth);
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', progress: .15);
      await tester.pump();
      final before = route.animation!.value;
      final beforeX = _x(tester, _front);
      await _gesture(tester, 'commitBackGesture');
      expect(route.animation!.value, closeTo(before, 1e-6), reason: 'commit must not restart at upperBound');
      await tester.pump();
      expect(_x(tester, _front), closeTo(beforeX, .01));
      var previous = beforeX;
      while (route.animation!.value > .05) {
        await tester.pump(const Duration(milliseconds: 8));
        if (!find.byKey(_front).evaluate().isNotEmpty) break;
        final x = _x(tester, _front);
        expect(x, greaterThanOrEqualTo(previous));
        expect(x, closeTo(width * (1 - route.animation!.value), .01));
        expect(_x(tester, _back), closeTo(-width * .04 * route.animation!.value, .01));
        previous = x;
      }
      expect(previous, greaterThan(width * .9));
      await tester.pumpAndSettle();
      expect(find.byKey(_front), findsNothing);
      expect(_x(tester, _back), 0);
      expect(navigator.currentState!.userGestureInProgress, isFalse);
    });

    testWidgets('$label cancellation returns continuously without popping', (tester) async {
      final (navigator, route) = await _mount(tester, smooth: smooth);
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', progress: .6);
      await tester.pump();
      await _gesture(tester, 'cancelBackGesture');
      expect(route.animation!.value, closeTo(.4, 1e-6));
      await tester.pump();
      expect(_x(tester, _front), closeTo(width * .6, .01));
      var previous = width * .6;
      while (route.animation!.value < 1) {
        await tester.pump(const Duration(milliseconds: 16));
        final x = _x(tester, _front);
        expect(x, lessThanOrEqualTo(previous + .01));
        expect(x, closeTo(width * (1 - route.animation!.value), .01));
        previous = x;
      }
      expect(route.isCurrent, isTrue);
      expect(_x(tester, _front), 0);
      expect(navigator.currentState!.userGestureInProgress, isFalse);
    });

    testWidgets('$label disabled prediction retains ordinary push and pop', (tester) async {
      final (navigator, route) = await _mount(tester, smooth: smooth, predictive: false);
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', progress: .6);
      await tester.pump();
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      expect(route.animation!.value, 1);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(_x(tester, _front), closeTo(width * .06 * (1 - route.animation!.value), .01));
      await tester.pumpAndSettle();
      expect(find.byKey(_front), findsNothing);
    });

    testWidgets('$label reduced motion disables displacement but completes predictive pop', (tester) async {
      final (navigator, route) = await _mount(tester, smooth: smooth, reduced: true);
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', progress: .4);
      await tester.pump();
      expect(route.animation!.value, closeTo(.6, 1e-6));
      expect(_x(tester, _front), 0);
      expect(_x(tester, _back), 0);
      await _gesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.byKey(_front), findsNothing);
      expect(navigator.currentState!.userGestureInProgress, isFalse);
    });

    testWidgets('$label route removal during cancellation releases gesture ownership', (tester) async {
      final (navigator, route) = await _mount(tester, smooth: smooth);
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', progress: .6);
      await tester.pump();
      await _gesture(tester, 'cancelBackGesture');
      navigator.currentState!.removeRoute(route);
      await tester.pumpAndSettle();
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$label ordinary push uses small slide and live secondary animation', (tester) async {
      final (navigator, _) = await _mount(tester, smooth: smooth);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      const page = SizedBox.expand(key: _front);
      final route = (smooth ? smoothRoute<void>(page) : MaterialPageRoute<void>(builder: (_) => page, allowSnapshotting: false)) as PageRoute<void>;
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(_x(tester, _front), closeTo(width * .06 * (1 - route.animation!.value), .01));
      expect(_x(tester, _back), closeTo(-width * .04 * route.animation!.value, .01));
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      await tester.pumpAndSettle();
    });

    testWidgets('$label zero and full-progress terminal events release gesture ownership', (tester) async {
      for (final progress in [0.0, 1.0]) {
        final (navigator, route) = await _mount(tester, smooth: smooth);
        await _gesture(tester, 'startBackGesture');
        await _gesture(tester, 'updateBackGestureProgress', progress: progress);
        await tester.pump();
        await _gesture(tester, 'cancelBackGesture');
        await tester.pumpAndSettle();
        expect(route.isCurrent, isTrue);
        expect(navigator.currentState!.userGestureInProgress, isFalse);
        await _gesture(tester, 'startBackGesture');
        await _gesture(tester, 'updateBackGestureProgress', progress: progress);
        await _gesture(tester, 'commitBackGesture');
        await tester.pumpAndSettle();
        expect(find.byKey(_front), findsNothing);
        expect(navigator.currentState!.userGestureInProgress, isFalse);
      }
    });

    testWidgets('$label PopScope protection and button events are not claimed', (tester) async {
      final (navigator, route) = await _mount(tester, smooth: smooth, canPop: false);
      await _gesture(tester, 'startBackGesture');
      await _gesture(tester, 'updateBackGestureProgress', progress: .6);
      await tester.pump();
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      expect(route.animation!.value, 1);
      await _mount(tester, smooth: smooth);
      await _gesture(tester, 'startBackGesture', button: true);
      await tester.pump();
      expect(_x(tester, _front), 0);
    });
  }
}
