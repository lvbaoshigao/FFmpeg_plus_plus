import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/services/ai_chat_history.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
