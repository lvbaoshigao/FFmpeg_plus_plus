import 'dart:async';
import 'dart:io';

import 'package:ffmpegpp_gui/services/bounded_log_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('slow disk bounds both retained characters and entry count', () async {
    final gate = Completer<void>();
    final writes = <(String, String)>[];
    final writer = BoundedLogWriter(
      maxPendingEntries: 4,
      maxPendingChars: 64,
      write: (path, line) async {
        await gate.future;
        writes.add((path, line));
      },
    );
    var accepted = 0;
    for (var i = 0; i < 10000; i++) {
      if (writer.append('first.log', 'entry-$i\n')) accepted++;
      expect(writer.pendingEntries, lessThanOrEqualTo(4));
      expect(writer.pendingChars, lessThanOrEqualTo(64));
    }
    expect(accepted, 4);
    gate.complete();
    await writer.flush();
    expect(writer.pendingEntries, 0);
    expect(writer.pendingChars, 0);
    expect(
      writes.where((entry) => entry.$2.startsWith('entry-')),
      hasLength(4),
    );
    expect(
      writes.where((entry) => entry.$2.contains('Skipped 9996 entries')),
      hasLength(1),
    );
    expect(writer.append('second.log', 'after overload\n'), isTrue);
    await writer.flush();
    expect(writes.last, ('second.log', 'after overload\n'));
  });

  test(
    'retains the in-flight budget while reporting an overloaded disk',
    () async {
      final recordGate = Completer<void>();
      final noticeGate = Completer<void>();
      final noticeStarted = Completer<void>();
      final writer = BoundedLogWriter(
        maxPendingChars: 16,
        write: (_, line) async {
          if (line.startsWith('[log]')) {
            noticeStarted.complete();
            await noticeGate.future;
          } else {
            await recordGate.future;
          }
        },
      );
      writer.append('test.log', 'x' * 16);
      expect(writer.append('test.log', 'overload'), isFalse);
      recordGate.complete();
      await noticeStarted.future;
      expect(writer.pendingChars, 16);
      expect(writer.pendingEntries, 1);
      expect(writer.append('test.log', 'still overloaded'), isFalse);
      noticeGate.complete();
      await writer.flush();
      expect(writer.pendingChars, 0);
      expect(writer.pendingEntries, 0);
    },
  );

  test('shutdown timeout preserves the single bounded drain', () async {
    final gate = Completer<void>();
    var calls = 0;
    final writer = BoundedLogWriter(
      write: (_, _) async {
        calls++;
        await gate.future;
      },
    );
    writer.append('test.log', 'pending');
    await writer.flush(timeout: const Duration(milliseconds: 1));
    expect(calls, 1);
    expect(writer.pendingEntries, 1);
    expect(writer.pendingChars, 7);
    writer.append('test.log', 'next');
    expect(calls, 1);
    gate.complete();
    await writer.flush();
    expect(calls, 2);
    expect(writer.pendingEntries, 0);
    expect(writer.pendingChars, 0);
  });

  test(
    'a locked rotation target still allows appending to the current log',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'log_rotation_failure_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}app.log';
      await File(path).writeAsString('123456789\n');
      // A directory at the backup path deterministically rejects file rename,
      // including on hosts that cannot emulate Windows file-sharing locks.
      await Directory('$path.1').create();
      final writer = BoundedLogWriter(maxFileBytes: 8);
      writer.append(path, 'still recorded\n');
      await writer.flush();
      expect(await File(path).readAsString(), '123456789\nstill recorded\n');
      expect(writer.pendingEntries, 0);
    },
  );

  test('character budget includes the write already in progress', () async {
    final gate = Completer<void>();
    final writer = BoundedLogWriter(
      maxPendingEntries: 100,
      maxPendingChars: 16,
      write: (_, _) => gate.future,
    );
    expect(writer.append('test.log', 'a' * 16), isTrue);
    expect(writer.append('test.log', 'b'), isFalse);
    expect(writer.pendingChars, 16);
    expect(writer.pendingEntries, 1);
    gate.complete();
    await writer.flush();
    expect(writer.pendingChars, 0);
    expect(writer.pendingEntries, 0);
  });

  test(
    'write failures release the budget and allow subsequent records',
    () async {
      var fail = true;
      final writes = <String>[];
      final writer = BoundedLogWriter(
        write: (_, line) async {
          if (fail) throw const FileSystemException('unavailable');
          writes.add(line);
        },
      );
      writer.append('first.log', 'failed');
      await writer.flush();
      expect(writer.pendingChars, 0);
      expect(writer.pendingEntries, 0);
      fail = false;
      writer.append('second.log', 'recovered');
      await writer.flush();
      expect(writes, ['recovered']);
    },
  );

  test('serial appends preserve paths, order, and disk rotation', () async {
    final directory = await Directory.systemTemp.createTemp('bounded_logs_');
    addTearDown(() => directory.delete(recursive: true));
    final path =
        '${directory.path}${Platform.pathSeparator}nested${Platform.pathSeparator}app.log';
    final writer = BoundedLogWriter(maxFileBytes: 8);
    writer.append(path, '123456789\n');
    writer.append(path, 'tail\n');
    await writer.flush();
    expect(await File('$path.1').readAsString(), '123456789\n');
    expect(await File(path).readAsString(), 'tail\n');
    final second = '${directory.path}${Platform.pathSeparator}other.log';
    writer.append(second, 'other\n');
    writer.append(path, 'end\n');
    await writer.flush();
    expect(await File(second).readAsString(), 'other\n');
    expect(await File(path).readAsString(), 'tail\nend\n');
  });
}
