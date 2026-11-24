import 'dart:io';

import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:ffmpegpp_gui/services/ffmpeg_installer.dart';
import 'package:ffmpegpp_gui/services/frame_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FramePreview', () {
    test('diagnostics stay silent while disabled and redact invalid inputs', () async {
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add);
      expect(await FramePreview.generatePreview('private-source.mp4', -1, trace: trace), isNull);
      expect(messages, isEmpty);
      trace.setEnabled(true);
      expect(await FramePreview.generateFullFrame('private-source.mp4', double.nan, trace: trace), isNull);
      expect(messages.where((line) => line.contains('frame.preview.result')), hasLength(1));
      expect(messages.join(' '), contains('failureType=invalid_time'));
      expect(messages.join(' '), isNot(contains('private-source')));
      expect(messages.join(' '), isNot(contains('NaN')));
    });

    test('missing source produces a paired diagnostic without its path', () async {
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add)..setEnabled(true);
      final temp = await Directory.systemTemp.createTemp('preview_missing_');
      addTearDown(() => temp.delete(recursive: true));
      expect(await FramePreview.generatePreview('${temp.path}${Platform.pathSeparator}private.mp4', 0, trace: trace), isNull);
      expect(messages.where((line) => line.contains('frame.preview.start')), hasLength(1));
      expect(messages.where((line) => line.contains('frame.preview.result')), hasLength(1));
      expect(messages.join(' '), contains('success=false'));
      expect(messages.join(' '), isNot(contains(temp.path)));
    });
    test('should keep adjacent frames distinct and reuse identical requests', () async {
      final temp = await Directory.systemTemp.createTemp('fpp_preview_test_');
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add)..setEnabled(true);
      final previous = FfmpegInstaller.configuredFfmpeg;
      final ffmpeg = Platform.environment['FFMPEGPP_TEST_FFMPEG']!;
      FfmpegInstaller.configuredFfmpeg = ffmpeg;
      addTearDown(() async {
        FfmpegInstaller.configuredFfmpeg = previous;
        await temp.delete(recursive: true);
      });

      await IOOverrides.runZoned(() async {
        final input = '${temp.path}${Platform.pathSeparator}source.mkv';
        final fixture = await Process.run(ffmpeg, [
          '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=60',
          '-t', '0.25', '-c:v', 'ffv1', input,
        ]);
        expect(fixture.exitCode, 0, reason: fixture.stderr.toString());

        final paths = await Future.wait([
          FramePreview.generatePreview(input, 0.017, width: 160, trace: trace),
          FramePreview.generatePreview(input, 0.017, width: 160, trace: trace),
        ]);
        expect(paths.first, isNotNull);
        expect(paths.last, paths.first);
        expect(await FramePreview.generatePreview(input, 0.017, width: 160, trace: trace), paths.first);
        final log = messages.join(' ');
        expect(log, contains('frame.preview.coalesce'));
        expect(log, contains('frame.preview.cache.hit'));
        expect(log, contains('exitCode=0'));
        expect(log, contains('processMs='));
        expect(log, isNot(contains(input)));
        expect(log, isNot(contains(paths.first!)));
        final adjacent = await FramePreview.generatePreview(input, 0.033, width: 160);
        expect(adjacent, isNotNull);
        expect(adjacent, isNot(paths.first));
        for (final path in [paths.first!, adjacent!]) {
          final bytes = await File(path).readAsBytes();
          expect(bytes.take(2), [0xff, 0xd8]);
          expect(bytes.skip(bytes.length - 2), [0xff, 0xd9]);
        }
      }, getSystemTempDirectory: () => temp);
    }, skip: Platform.environment['FFMPEGPP_TEST_FFMPEG'] == null
        ? 'Set FFMPEGPP_TEST_FFMPEG to the FFmpeg binary.'
        : false);
  });
}
