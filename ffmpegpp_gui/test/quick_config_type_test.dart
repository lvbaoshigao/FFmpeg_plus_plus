import 'package:ffmpegpp_gui/models/quick_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QuickFileType parsing', () {
    test('accepts legacy aliases, case, and numeric indices', () {
      expect(QuickFileType.fromJson('IMAGE'), QuickFileType.image);
      expect(QuickFileType.fromJson(' photo '), QuickFileType.image);
      expect(QuickFileType.fromJson('AUDIO'), QuickFileType.audio);
      expect(QuickFileType.fromJson('Movie'), QuickFileType.video);
      expect(QuickFileType.fromJson(0), QuickFileType.video);
      expect(QuickFileType.fromJson(1), QuickFileType.image);
      expect(QuickFileType.fromJson(2), QuickFileType.audio);
      expect(QuickFileType.fromJson(null), isNull);
    });

    test('infers image/audio/video from quick item signatures', () {
      expect(
        inferQuickFileTypeFromMaps([
          {
            'key': 'resize',
            'params': {'w': 1920, 'h': 1080, 'fit': 'contain'},
          },
        ]),
        QuickFileType.image,
      );
      expect(
        inferQuickFileTypeFromMaps([
          {
            'key': 'normalize',
            'params': {'level': -14},
          },
        ]),
        QuickFileType.audio,
      );
      expect(
        inferQuickFileTypeFromMaps([
          {
            'key': 'compress',
            'params': {'quality': 85, 'format': 'jpg'},
          },
        ]),
        QuickFileType.image,
      );
      expect(
        inferQuickFileTypeFromMaps([
          {
            'key': 'compress',
            'params': {'codec': 'h264', 'preset': 'medium'},
          },
        ]),
        QuickFileType.video,
      );
      expect(
        inferQuickFileTypeFromMaps([
          {
            'key': 'subtitle',
            'params': {'burn': true},
          },
        ]),
        QuickFileType.video,
      );
    });

    test('QuickConfig.fromJson infers when file_type is absent', () {
      final cfg = QuickConfig.fromJson({
        'id': 'x',
        'name': 'image preset',
        'items': [
          {
            'key': 'convert_format',
            'params': {'format': 'png'},
          },
        ],
      });
      expect(cfg.fileType, QuickFileType.image);
    });
  });
}
