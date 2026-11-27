import 'dart:io';

import 'package:ffmpegpp_gui/services/ai_chat_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'widget persistence uses the test directory for every operation',
    (tester) async {
      await tester.runAsync(() async {
        final directory = AiChatHistory.directoryOverride!;
        expect(await directory.list().toList(), isEmpty);
        final path = await AiChatHistory.saveSession(
          title: 'An ordinary conversation',
          provider: 'openai',
          model: 'model-a',
          messages: const [
            {'role': 'user', 'content': 'Hello'},
          ],
        );
        expect(path, isNotNull);
        expect(File(path!).parent.path, directory.path);
        expect((await AiChatHistory.listSessions()).single['_file'], path);
        expect(
          (await AiChatHistory.loadSession(path))?['title'],
          'An ordinary conversation',
        );
        await AiChatHistory.deleteSession(path);
        expect(await File(path).exists(), isFalse);

        await AiChatHistory.saveSession(
          title: 'Another conversation',
          provider: 'openai',
          model: 'model-a',
          messages: const [],
        );
        await AiChatHistory.clearAll();
        expect(await directory.list().toList(), isEmpty);
      });
    },
  );

  String? previousDirectory;
  for (var index = 0; index < 2; index++) {
    testWidgets(
      'widget test $index starts with an independent empty directory',
      (tester) async {
        await tester.runAsync(() async {
          final directory = AiChatHistory.directoryOverride!;
          expect(directory.path, isNot(previousDirectory));
          expect(await directory.list().toList(), isEmpty);
          await File(
            '${directory.path}/previous_test_marker',
          ).writeAsString('test');
          previousDirectory = directory.path;
        });
      },
    );
  }

  test('listing preserves custom PRIVATE_ provider and model names', () async {
    final directory = AiChatHistory.directoryOverride!;
    final paths = <String>[];
    for (final title in ['PRIVATE_HISTORY', 'PRIVITE_HISTORY']) {
      for (final metadata in [
        ('PRIVATE_CUSTOM_PROVIDER', 'PRIVATE_MODEL'),
        ('PRIVATE_PROVIDER', 'PRIVATE_CUSTOM_MODEL'),
        ('PRIVATE_PROVIDER_CUSTOM', 'PRIVATE_MODEL_CUSTOM'),
      ]) {
        final path = await AiChatHistory.saveSession(
          title: title,
          provider: metadata.$1,
          model: metadata.$2,
          messages: const [
            {'role': 'user', 'content': 'An ordinary saved conversation'},
          ],
          filePath: '${directory.path}/custom_${paths.length}.json',
        );
        expect(path, isNotNull);
        paths.add(path!);
      }
    }
    final originals = <String, String>{
      for (final path in paths) path: await File(path).readAsString(),
    };

    final summaries = await AiChatHistory.listSessions();
    expect(
      summaries.map((summary) => summary['_file']),
      unorderedEquals(paths),
    );
    for (final path in paths) {
      expect(await File(path).readAsString(), originals[path]);
      final loaded = await AiChatHistory.loadSession(path);
      final summary = summaries.singleWhere((entry) => entry['_file'] == path);
      expect(loaded?['title'], summary['title']);
      expect(loaded?['provider'], summary['provider']);
      expect(loaded?['model'], summary['model']);
      expect(loaded?['messages'], [
        {'role': 'user', 'content': 'An ordinary saved conversation'},
      ]);
    }
  });

  test('identical diagnostic metadata does not hide other content', () async {
    const attachment = {
      'type': 'attachment',
      'name': 'PRIVATE_FILE',
      'path': 'PRIVATE_PATH',
      'size': 12,
      'mimeType': 'application/octet-stream',
    };
    const user = {
      'role': 'user',
      'content': 'PRIVATE_HISTORY',
      'blocks': [attachment],
    };
    const assistant = {'role': 'assistant', 'content': 'PRIVATE_ANSWER'};
    final bodies = <List<Map<String, dynamic>>>[
      [],
      [
        {'role': 'user', 'content': 'My own conversation'},
        assistant,
      ],
      [
        {'role': 'user', 'content': 'PRIVATE_HISTORY'},
        assistant,
      ],
      [
        user,
        {'role': 'assistant', 'content': 'My own answer'},
      ],
      [
        {
          ...user,
          'blocks': [
            {...attachment, 'path': 'my-own-file'},
          ],
        },
        assistant,
      ],
      [
        user,
        {...assistant, 'role': 'user'},
      ],
      [
        user,
        assistant,
        {'role': 'user', 'content': 'x' * (65 * 1024)},
      ],
    ];
    final directory = AiChatHistory.directoryOverride!;
    final originals = <String, String>{};
    for (final title in ['PRIVATE_HISTORY', 'PRIVITE_HISTORY']) {
      for (final messages in bodies) {
        final path = await AiChatHistory.saveSession(
          title: title,
          provider: 'PRIVATE_PROVIDER',
          model: 'PRIVATE_MODEL',
          messages: messages,
          filePath: '${directory.path}/ordinary_${originals.length}.json',
        );
        expect(path, isNotNull);
        originals[path!] = await File(path).readAsString();
      }
    }

    final summaries = await AiChatHistory.listSessions();
    expect(
      summaries.map((summary) => summary['_file']),
      unorderedEquals(originals.keys),
    );
    expect(summaries.every((entry) => !entry.containsKey('messages')), isTrue);
    for (final entry in originals.entries) {
      expect(await File(entry.key).readAsString(), entry.value);
      expect(await AiChatHistory.loadSession(entry.key), isNotNull);
    }
  });

  test('an in-flight save retains its captured directory', () async {
    final original = AiChatHistory.directoryOverride!;
    final other = Directory('${original.path}/next_directory');
    final pending = AiChatHistory.saveSession(
      title: 'Captured destination',
      provider: 'openai',
      model: 'model-a',
      messages: const [],
    );
    AiChatHistory.directoryOverride = other;
    addTearDown(() => AiChatHistory.directoryOverride = original);
    final path = await pending;
    expect(path, isNotNull);
    expect(File(path!).parent.path, original.path);
    expect(await other.exists(), isFalse);
  });
}
