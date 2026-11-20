import 'dart:async';
import 'dart:io';

import 'package:ffmpegpp_gui/services/imported_font_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ffmpegpp-fonts-');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'only the chosen family loads and concurrent requests are shared',
    () async {
      await File('${directory.path}/Chosen.ttf').writeAsBytes([1, 2, 3]);
      await File(
        '${directory.path}/Unused.otf',
      ).writeAsBytes(List.filled(1024, 9));
      final families = <String>[];
      final gate = Completer<void>();
      final loader = ImportedFontLoader(
        register: (family, bytes) async {
          families.add(family);
          expect(bytes, [1, 2, 3]);
          await gate.future;
        },
      );
      final first = loader.ensureLoaded('Chosen', [directory]);
      final second = loader.ensureLoaded('Chosen', [directory]);
      expect(second, same(first));
      gate.complete();
      expect(await first, isTrue);
      expect(await loader.ensureLoaded('Chosen', [directory]), isTrue);
      expect(families, ['Chosen']);
    },
  );

  test('missing faces fall back and failed registration can retry', () async {
    var attempts = 0;
    final loader = ImportedFontLoader(
      register: (_, _) async {
        attempts++;
        if (attempts == 1) throw StateError('temporary registration failure');
      },
    );
    expect(await loader.ensureLoaded('Chosen', [directory]), isFalse);
    await File('${directory.path}/Chosen.otf').writeAsBytes([1]);
    await expectLater(
      loader.ensureLoaded('Chosen', [directory]),
      throwsStateError,
    );
    expect(await loader.ensureLoaded('Chosen', [directory]), isTrue);
    expect(attempts, 2);
    expect(await loader.ensureLoaded('../Chosen', [directory]), isFalse);
    expect(
      await loader.ensureLoaded('..${String.fromCharCode(92)}Chosen', [
        directory,
      ]),
      isFalse,
    );
  });
}
