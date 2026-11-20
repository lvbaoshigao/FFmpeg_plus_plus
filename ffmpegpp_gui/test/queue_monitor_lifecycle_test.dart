import 'dart:async';

import 'package:ffmpegpp_gui/pages/queue_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/system_monitor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Map<String, dynamic> _stats(double cpu) => {
  'cpuPercent': cpu,
  'ramUsedGb': 2.0,
  'ramTotalGb': 8.0,
  'gpuPercent': -1.0,
  'gpuName': '',
};

void main() {
  group('SystemMonitor', () {
    testWidgets('should cancel sampling and reject a previous run result', (
      tester,
    ) async {
      final reads = <Completer<Map<String, dynamic>?>>[];
      final monitor = SystemMonitor(
        readNativeStats: () {
          final read = Completer<Map<String, dynamic>?>();
          reads.add(read);
          return read.future;
        },
      );
      addTearDown(monitor.stop);

      monitor
        ..start()
        ..start();
      expect(reads, hasLength(1));
      monitor
        ..stop()
        ..stop();
      await tester.pump(const Duration(seconds: 3));
      expect(reads, hasLength(1));

      monitor.start();
      reads.single.complete(_stats(91));
      await tester.pump();
      expect(monitor.cpuPercent, 0);
      await tester.pump(const Duration(milliseconds: 120));
      expect(reads, hasLength(2));
      reads.last.complete(_stats(46));
      await tester.pump();
      expect(monitor.cpuPercent, 46);

      // Stop before the second warm-up; the test clock must have no timers left.
      monitor.stop();
    });
  });

  group('QueuePage monitor', () {
    testWidgets('should stop a retained hidden page and refresh on return', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      state.config
        ..language = 'en'
        ..menuStyle = 'gray';
      addTearDown(state.dispose);

      var samples = 0;
      var cpu = 27.0;
      final monitor = SystemMonitor(
        readNativeStats: () async {
          samples++;
          return _stats(cpu);
        },
      );
      final queue = QueuePage(monitor: monitor);
      Widget tree(bool visible) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: TickerMode(enabled: visible, child: queue)),
      );

      await tester.pumpWidget(tree(false));
      await tester.pump(const Duration(seconds: 3));
      expect(samples, 0);

      await tester.pumpWidget(tree(true));
      await tester.pump(const Duration(seconds: 2));
      expect(samples, greaterThan(0));
      expect(find.text('27%'), findsOneWidget);
      final queueElement = tester.element(find.byWidget(queue));

      await tester.pumpWidget(tree(false));
      final samplesBeforeHide = samples;
      // An updated value must not be rendered by the hidden refresh timer.
      monitor.cpuPercent = 73;
      await tester.pump(const Duration(seconds: 6));
      expect(samples, samplesBeforeHide);
      expect(find.text('73%'), findsNothing);

      cpu = 42;
      await tester.pumpWidget(tree(true));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.element(find.byWidget(queue)), same(queueElement));
      expect(samples, greaterThan(samplesBeforeHide));
      expect(find.text('42%'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      final samplesBeforeDispose = samples;
      await tester.pump(const Duration(seconds: 3));
      expect(samples, samplesBeforeDispose);
      expect(tester.takeException(), isNull);
    });
  });
}
