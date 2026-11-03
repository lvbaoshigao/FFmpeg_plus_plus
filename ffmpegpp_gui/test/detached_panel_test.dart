import 'package:ffmpegpp_gui/services/multi_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('split element and property panels round-trip window arguments', () {
    for (final panel in [DetachedPanel.elements, DetachedPanel.properties]) {
      final args = DetachedWindowArgs(
        panel: panel,
        lang: 'en',
        width: 360,
        height: 780,
      );

      final decoded = DetachedWindowArgs.tryParse(args.encode());
      expect(decoded?.panel, panel);
      expect(decoded?.lang, 'en');
      expect(decoded?.width, 360);
      expect(decoded?.height, 780);
      expect(DetachedPanel.fromId(panel.id), panel);
    }

    expect(DetachedPanel.fromId('props'), DetachedPanel.props);
  });
}
