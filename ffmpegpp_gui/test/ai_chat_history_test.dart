import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/services/ai_chat_history.dart';
import 'package:flutter_test/flutter_test.dart';

class _StreamOnlyFile implements File {
  _StreamOnlyFile(this.path, this.openStream);
  @override
  final String path;
  final Stream<List<int>> Function() openStream;
  @override
  Stream<List<int>> openRead([int? start, int? end]) => openStream();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      throw StateError('Listing must never read a whole history file');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HistoryDirectory implements Directory {
  _HistoryDirectory(this.files);
  final List<File> files;
  @override
  String get path => 'history';
  @override
  Future<bool> exists() async => true;
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => Stream.fromIterable(files);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('saveSession overwrites the same file for incremental autosave', () async {
    final dir = await Directory.systemTemp.createTemp('ai_history_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/session.json');
    final first = await AiChatHistory.saveSession(
      title: 'First',
      provider: 'openai',
      model: 'gpt-4o',
      messages: const [
        {'role': 'user', 'content': 'one'},
      ],
      filePath: file.path,
    );
    final second = await AiChatHistory.saveSession(
      title: 'First',
      provider: 'openai',
      model: 'gpt-4o',
      messages: const [
        {'role': 'user', 'content': 'one'},
        {'role': 'assistant', 'content': 'two'},
      ],
      filePath: file.path,
    );
    expect(first, file.path);
    expect(second, file.path);
    final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((decoded['messages'] as List).length, 2);
  });

  test('listing streams large old bodies and returns only scalar summaries', () async {
    var chunksRead = 0;
    final bodyChunk = utf8.encode('x' * (64 * 1024));
    final file = _StreamOnlyFile('history/session_2.json', () async* {
      // Old files may put metadata after messages. Nested misleading metadata
      // and escaped braces/quotes must not become summary fields.
      yield utf8.encode('{"messages":[{"role":"assistant","content":"');
      for (var i = 0; i < 256; i++) {
        chunksRead++;
        yield bodyChunk;
      }
      final blocks = jsonEncode([{'title': 'nested', 'text': r'} \" ['}]);
      yield utf8.encode('","blocks":$blocks}],');
      final metadata = jsonEncode({
        'title': r'旧会话 "标题" \ path',
        'provider': 'openai',
        'model': 'model-a',
        'saved_at': '2026-01-02T03:04:05',
        'total_in': 123,
        'total_out': 456,
      });
      // Split UTF-8 code points and JSON escapes across stream chunks.
      for (final byte in utf8.encode(metadata.substring(1))) {
        yield [byte];
      }
    });
    final sessions = await AiChatHistory.listSessions(
      directory: _HistoryDirectory([file]),
    );
    expect(chunksRead, 256); // 16 MiB body without any full-file read API.
    expect(sessions, hasLength(1));
    expect(sessions.single, {
      'title': r'旧会话 "标题" \ path',
      'provider': 'openai',
      'model': 'model-a',
      'saved_at': '2026-01-02T03:04:05',
      'total_in': 123,
      'total_out': 456,
      '_file': file.path,
    });
    expect(jsonEncode(sessions).length, lessThan(512));
  });

  test('listing skips temporary and truncated files and sorts newest first', () async {
    File session(String name, String json) => _StreamOnlyFile(
      'history/$name', () => Stream.value(utf8.encode(json)),
    );
    final sessions = await AiChatHistory.listSessions(
      directory: _HistoryDirectory([
        session('session_1.json', '{"title":"old","messages":[]}'),
        session('session_3.json', '{"messages":[],"title":"new"}'),
        session('session_4.json.tmp', '{"title":"temporary"}'),
        session('session_5.json.bak', '{"title":"backup"}'),
        session('session_6.json', '{"title":"broken","messages":['),
        session('session_7.json', '{"messages":[}'),
      ]),
    );
    expect(sessions.map((entry) => entry['title']), ['new', 'old']);
    expect(sessions.every((entry) => !entry.containsKey('messages')), isTrue);
  });

  test('cancelling a listing closes the stream and discards partial results', () async {
    var cancelled = false;
    var closed = false;
    var chunksRead = 0;
    final file = _StreamOnlyFile('history/session.json', () async* {
      try {
        chunksRead++;
        yield utf8.encode('{"title":"old","messages":[');
        cancelled = true;
        chunksRead++;
        yield utf8.encode(']}');
        fail('The cancelled file stream must not be drained');
      } finally {
        closed = true;
      }
    });
    expect(await AiChatHistory.listSessions(
      directory: _HistoryDirectory([file]),
      isCancelled: () => cancelled,
    ), isEmpty);
    expect(chunksRead, 2);
    expect(closed, isTrue);
  });

  test('oversized metadata and keys cannot grow a summary buffer', () async {
    File session(String name, String text) => _StreamOnlyFile(
      'history/$name.json', () => Stream.value(utf8.encode(text)),
    );
    final sessions = await AiChatHistory.listSessions(
      directory: _HistoryDirectory([
        session('title', jsonEncode({'title': 't' * 9000, 'messages': []})),
        session('key', jsonEncode({'k' * 9000: 'value', 'messages': []})),
        session('valid', jsonEncode({'title': 'valid', 'messages': []})),
      ]),
    );
    expect(sessions.map((entry) => entry['title']), ['valid']);
  });

  test('loadSession keeps messages, blocks and cumulative tokens on demand', () async {
    final dir = await Directory.systemTemp.createTemp('ai_history_load_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/session.json');
    final data = {
      'title': 'Saved', 'provider': 'openai', 'model': 'model-a',
      'total_in': 901, 'total_out': 902,
      'messages': [
        {'role': 'assistant', 'content': 'answer', 'in': 1, 'out': 2,
          'blocks': [{'type': 'thinking', 'thinking': 'reasoning'}]},
      ],
    };
    await file.writeAsString(jsonEncode(data));
    expect(await AiChatHistory.loadSession(file.path), {...data, '_file': file.path});
    expect(await AiChatHistory.loadSession('${dir.path}/missing.json'), isNull);
  });
}
