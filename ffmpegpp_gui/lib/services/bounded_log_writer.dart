import 'dart:collection';
import 'dart:io';

/// Serial disk logging with a bounded backlog, including the in-flight record.
/// Slow or unavailable disks must not keep an unbounded chain of log closures.
final class BoundedLogWriter {
  BoundedLogWriter({
    this.maxPendingEntries = 256,
    this.maxPendingChars = 512 * 1024,
    this.maxFileBytes = 10 * 1024 * 1024,
    Future<void> Function(String path, String line)? write,
  }) : assert(maxPendingEntries > 0),
       assert(maxPendingChars > 0),
       _writeOverride = write;

  final int maxPendingEntries;
  // UTF-16 code units; at most two bytes of string storage per code unit.
  final int maxPendingChars;
  final int maxFileBytes;
  final Future<void> Function(String, String)? _writeOverride;
  final _queue = Queue<({String path, String line})>();
  Future<void>? _drainFuture;
  int _pendingEntries = 0;
  int _pendingChars = 0;
  int _dropped = 0;
  String? _readyDirectory;

  int get pendingEntries => _pendingEntries;
  int get pendingChars => _pendingChars;

  /// Returns false when overloaded. The disk log receives a loss notice once
  /// the current write completes; rejected records themselves are not retained.
  bool append(String path, String line) {
    if (_pendingEntries >= maxPendingEntries ||
        _pendingChars + line.length > maxPendingChars) {
      _dropped++;
      return false;
    }
    _queue.addLast((path: path, line: line));
    _pendingEntries++;
    _pendingChars += line.length;
    _drainFuture ??= _drain();
    return true;
  }

  /// A bounded shutdown wait leaves the one existing drain running; it never
  /// starts a second writer or releases its retained-record accounting early.
  Future<void> flush({Duration? timeout}) {
    final pending = _drainFuture ?? Future<void>.value();
    return timeout == null
        ? pending
        : pending.timeout(timeout, onTimeout: () {});
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty) {
        final entry = _queue.removeFirst();
        try {
          await _write(entry.path, entry.line);
        } catch (_) {
          _readyDirectory = null;
        }
        if (_dropped > 0) {
          final count = _dropped;
          _dropped = 0;
          try {
            await _write(
              entry.path,
              '[log] Skipped $count entries: disk logging backlog limit reached.\n',
            );
          } catch (_) {
            _readyDirectory = null;
          }
        }
        // Keep the record accounted while its loss notice is in flight too.
        _pendingEntries--;
        _pendingChars -= entry.line.length;
      }
    } finally {
      _drainFuture = null;
    }
  }

  Future<void> _write(String path, String line) async {
    final write = _writeOverride;
    if (write != null) {
      await write(path, line);
      return;
    }
    final file = File(path);
    final directory = file.parent;
    if (_readyDirectory != directory.path) {
      await directory.create(recursive: true);
      _readyDirectory = directory.path;
    }
    if (await file.exists() && await file.length() > maxFileBytes) {
      try {
        final rotated = File('$path.1');
        if (await rotated.exists()) await rotated.delete();
        await file.rename(rotated.path);
      } on FileSystemException {
        // Windows log viewers may lock the backup. Preserve the old fallback:
        // keep appending rather than silently lose every record until unlock.
      }
    }
    await file.writeAsString(line, mode: FileMode.append);
  }
}
