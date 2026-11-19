import 'package:ffmpegpp_gui/widgets/tabler_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TablerIcon', () {
    test('should load every bundled SVG and its license', () async {
      for (final glyph in TablerGlyph.values) {
        final bytes = await SvgAssetLoader(glyph.assetName).loadBytes(null);
        expect(bytes.lengthInBytes, greaterThan(0), reason: glyph.assetName);
      }
      final license = await rootBundle.loadString(
        'assets/tabler_icons/LICENSE',
      );
      expect(license, startsWith('MIT License'));
    });

    testWidgets(
      'should inherit theme color, opacity and size in a larger slot',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Center(
              child: IconTheme(
                data: IconThemeData(size: 22, color: Colors.teal, opacity: 0.5),
                child: SizedBox.square(
                  dimension: 30,
                  child: TablerIcon(TablerGlyph.movie),
                ),
              ),
            ),
          ),
        );

        final picture = find.byType(SvgPicture);
        final icon = find.byType(TablerIcon);
        expect(tester.getSize(picture), const Size.square(22));
        expect(tester.getCenter(picture), tester.getCenter(icon));
        expect(
          tester.widget<SvgPicture>(picture).colorFilter,
          ColorFilter.mode(Colors.teal.withValues(alpha: 0.5), BlendMode.srcIn),
        );
      },
    );
  });
}
