import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:ffmpegpp_gui/services/ffmpeg_installer.dart';
import 'package:flutter_test/flutter_test.dart';

class _ArchiveFile implements File {
  _ArchiveFile(this.bytes);
  final Uint8List bytes;
  @override
  bool existsSync() => false;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('archive diagnostics count decoding and redact archive paths and entries', () async {
    final archive = Archive()..addFile(ArchiveFile('private-entry.txt', 3, [1, 2, 3]));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final messages = <String>[];
    final trace = DiagnosticTrace(messages.add)..setEnabled(true);
    await IOOverrides.runZoned(() async {
      await expectLater(FfmpegInstaller.importFromZips(
        ffmpegZipPath: 'private-download.zip',
        ffprobeZipPath: 'private-probe.zip',
        onStatus: (_) {},
        onProgress: (_) {},
        trace: trace,
      ), throwsException);
    }, createFile: (_) => _ArchiveFile(bytes));
    final log = messages.join(' ');
    expect(log, contains('method=archive'));
    expect(log, contains('installer.decode'));
    expect(log, contains('entryCount=1'));
    expect(log, contains('success=false'));
    expect(messages.where((line) => line.contains('ffmpeg.install.result')), hasLength(1));
    for (final secret in ['private-download', 'private-probe', 'private-entry']) {
      expect(log, isNot(contains(secret)));
    }
  });

  test('disabled archive diagnostics stay silent on failure', () async {
    final messages = <String>[];
    final trace = DiagnosticTrace(messages.add);
    await IOOverrides.runZoned(() async {
      await expectLater(FfmpegInstaller.importFromZips(
        ffmpegZipPath: 'secret.zip', ffprobeZipPath: 'other-secret.zip',
        onStatus: (_) {}, onProgress: (_) {}, trace: trace,
      ), throwsException);
    }, createFile: (_) => _ArchiveFile(Uint8List(0)));
    expect(messages, isEmpty);
  });
}
