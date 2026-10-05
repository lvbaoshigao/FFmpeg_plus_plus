import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/mobile_bottom_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('dragging nav mask from first to last item selects last item', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 120);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig((c) => c..navStyle = 'gray');
    var selected = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MobileBottomNav(
                selectedIndex: 0,
                onSelected: (index) => selected = index,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bounds = tester.getRect(find.byType(MobileBottomNav));
    final start = Offset(bounds.left + 30, bounds.center.dy);
    final end = Offset(bounds.right - 30, bounds.center.dy);
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(end, timeStamp: const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 4);
    await tester.pump(const Duration(seconds: 1));
  });
}
