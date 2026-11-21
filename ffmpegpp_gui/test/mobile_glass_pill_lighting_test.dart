import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'disabled pill lighting leaves no interior band (${dark ? 'dark' : 'light'})',
      (tester) async {
        final state = AppState();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          state.dispose();
        });
        state.config
          ..pillStyle = 'liquid'
          ..cardOpacity = 1
          ..glassHighlight = 0
          ..glassEdge = 0
          ..glassBlur = 0;
        final capture = GlobalKey();
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: state,
            child: MaterialApp(
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              home: Scaffold(
                body: Center(
                  child: RepaintBoundary(
                    key: capture,
                    child: const ColoredBox(
                      color: Color(0xFFFFFFFF),
                      child: MobileGlassPill(
                        height: 44,
                        padding: EdgeInsets.zero,
                        child: SizedBox(width: 180, height: 44),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await tester.runAsync(
          () => boundary.toImage(pixelRatio: 1),
        );
        addTearDown(() => image!.dispose());
        final data = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        // Sample well inside the pill, away from rounded edges and the shadow.
        for (var channel = 0; channel < 3; channel++) {
          final top = data!.getUint8((12 * image!.width + 35) * 4 + channel);
          final bottom = data.getUint8((31 * image.width + 145) * 4 + channel);
          expect(
            top,
            closeTo(bottom, 1),
            reason:
                'Highlight off must not leave an independent gradient across the content',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
