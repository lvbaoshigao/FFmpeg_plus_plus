import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/mobile_bottom_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('dragging nav rail from first to last item selects last item', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(120, 420);
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
              alignment: Alignment.centerLeft,
              child: MobileNavRail(
                selectedIndex: 0,
                onSelected: (index) => selected = index,
                placement: MobileNavPlacement.left,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bounds = tester.getRect(find.byType(MobileNavRail));
    final start = Offset(bounds.center.dx, bounds.top + 30);
    final end = Offset(bounds.center.dx, bounds.bottom - 30);
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(end, timeStamp: const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 4);
    await tester.pump(const Duration(seconds: 1));
  });
}
