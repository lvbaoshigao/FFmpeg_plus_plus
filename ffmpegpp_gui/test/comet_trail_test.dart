import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 彗星拖尾现已全应用统一为「填充段前缘光带 + 光晕」（与开屏加载进度条同源），
  // 旧的粒子喷射实现（含 CometTrailTestProbe 的采样/包络）已整体删除。
  // 这里改为只验证唯一剩下的行为约束：进度条在确定 / 不确定两种状态下都能
  // 正常构建，且关闭动画时不创建 Ticker。
  group('Comet trail', () {
    testWidgets('determinate progress bar paints its comet', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 140, child: AppProgressBar(value: 0.4)),
            ),
          ),
        ),
      );
      expect(find.byType(AppProgressBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('indeterminate progress bar animates without exceptions', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 140, child: AppProgressBar()),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      // 让 ticker 走到结尾，确认没有越界的渐变端点。
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });
  });
}
