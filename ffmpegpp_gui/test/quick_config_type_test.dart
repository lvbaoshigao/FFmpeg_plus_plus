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

  group('QuickConfig node persistence', () {
    test('empty node mode stays distinct from legacy items', () {
      final cfg = QuickConfig(
        id: 'nodes',
        fileType: QuickFileType.audio,
        nodes: [],
      );
      expect(QuickConfig.fromJson(cfg.toJson()).nodes, isEmpty);
      expect(QuickConfig.fromJson({'id': 'legacy'}).nodes, isNull);
    });

    test('nodes, repeated types and boundary params round trip', () {
      final json = <String, dynamic>{
        'id': 'round-trip',
        'file_type': 'audio',
        'nodes': [
          {
            'id': 'a',
            'type': 'audioVolume',
            'params': {'volume_db': -6.0},
          },
          {
            'id': 'b',
            'type': 'audioVolume',
            'params': {'volume_db': 3.0},
          },
        ],
        'input_params': {'file_media_type': 'audio'},
        'output_params': {'output_dir': '/keep', 'output_format': 'flac'},
      };
      final restored = QuickConfig.fromJson(
        QuickConfig.fromJson(json).toJson(),
      );
      expect(restored.nodes!.map((node) => node.id), ['a', 'b']);
      expect(restored.nodes!.map((node) => node.params['volume_db']), [
        -6.0,
        3.0,
      ]);
      expect(restored.inputParams, json['input_params']);
      expect(restored.outputParams, json['output_params']);
    });

    test('deep copies isolate nested legacy and node parameters', () {
      final cfg = QuickConfig.fromJson({
        'id': 'copy',
        'items': [
          {
            'key': 'x',
            'params': {
              'nested': [1],
            },
          },
        ],
        'nodes': [
          {
            'id': 'node',
            'type': 'audioVolume',
            'params': {
              'nested': [2],
            },
          },
        ],
        'output_params': {
          'nested': [3],
        },
      });
      final copy = cfg.deepCopy();
      (copy.items.first.params['nested'] as List)[0] = 9;
      (copy.nodes!.first.params['nested'] as List)[0] = 9;
      (copy.outputParams['nested'] as List)[0] = 9;
      expect(cfg.items.first.params['nested'], [1]);
      expect(cfg.nodes!.first.params['nested'], [2]);
      expect(cfg.outputParams['nested'], [3]);
    });

    test('malformed node entries cannot silently truncate a saved chain', () {
      expect(
        () => QuickConfig.fromJson({
          'nodes': [123],
        }),
        throwsA(isA<TypeError>()),
      );
    });
  });
}
