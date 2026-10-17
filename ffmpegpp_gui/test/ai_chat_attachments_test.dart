import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpegpp_gui/services/ai_chat_attachments.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

final class _PathlessFile extends PlatformFile {
  _PathlessFile(this.data, {this.reportedSize});
  final Uint8List data;
  final int? reportedSize;
  @override
  String get name => '../image.png';
  @override
  Uri get uri => Uri.parse('content://picker/image');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => reportedSize;
  @override
  Future<int?> length() async => reportedSize;
  @override
  Future<Uint8List> readAsBytes() async => data;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(data);
}

void main() {
  group('AiChatAttachments', () {
    late Directory directory;
    late AiChatAttachment attachment;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('ai-attachment-test-');
      final file = File('${directory.path}/image.png');
      await file.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);
      attachment = AiChatAttachment(
        name: 'image.png',
        path: file.path,
        size: 8,
        mimeType: 'image/png',
      );
    });
    tearDown(() => directory.delete(recursive: true));
    test('should materialize Android pathless bytes safely', () async {
      final prepared = await AiChatAttachments.prepare(
        _PathlessFile(Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10])),
        supportDirectory: directory,
      );
      expect(prepared.managed, isTrue);
      expect(prepared.path, startsWith('${directory.path}/ai_attachments/'));
      expect(prepared.path, isNot(contains('..')));
      expect(prepared.mimeType, 'image/png');
      expect(await File(prepared.path).length(), 8);
    });
    test('should reject oversized pathless files before reading', () async {
      await expectLater(
        AiChatAttachments.prepare(
          _PathlessFile(
            Uint8List(0),
            reportedSize: AiChatAttachments.maxCopyBytes + 1,
          ),
          supportDirectory: directory,
        ),
        throwsFormatException,
      );
    });
    test('should share inline budget across historical messages', () async {
      final budget = AiAttachmentBudget(remaining: 8);
      final first = await AiChatAttachments.content(
        '',
        [attachment],
        vision: true,
        anthropic: false,
        budget: budget,
      );
      final second = await AiChatAttachments.content(
        '',
        [attachment],
        vision: true,
        anthropic: false,
        budget: budget,
      );
      expect(first, hasLength(2));
      expect(second, hasLength(1));
      expect(budget.remaining, 0);
    });
    test('should persist metadata without base64', () {
      final restored = AiChatAttachment.fromJson(attachment.toJson());
      expect(restored.path, attachment.path);
      expect(jsonEncode(attachment.toJson()), isNot(contains('base64')));
    });
    test('should gate inline images on vision capability', () async {
      final blocks = await AiChatAttachments.content(
        '',
        [attachment],
        vision: false,
        anthropic: false,
      );
      expect(blocks, hasLength(1));
      expect(blocks.single['text'], contains(attachment.path));
    });
    test('should encode OpenAI images with image_url', () async {
      final blocks = await AiChatAttachments.content(
        '',
        [attachment],
        vision: true,
        anthropic: false,
      );
      expect(blocks.last['type'], 'image_url');
      expect(
        (blocks.last['image_url'] as Map)['url'],
        startsWith('data:image/png;base64,'),
      );
    });
    test('should encode Anthropic images with image source blocks', () async {
      final blocks = await AiChatAttachments.content(
        '',
        [attachment],
        vision: true,
        anthropic: true,
      );
      expect(blocks.last['type'], 'image');
      expect((blocks.last['source'] as Map)['media_type'], 'image/png');
    });
    test('should keep missing files as usable metadata', () async {
      await File(attachment.path).delete();
      final blocks = await AiChatAttachments.content(
        'inspect',
        [attachment],
        vision: true,
        anthropic: false,
      );
      expect(blocks, hasLength(1));
      expect(blocks.single['text'], contains('inspect'));
    });
    test('should detect images by bytes rather than extension', () {
      expect(
        AiChatAttachments.imageMime([1, 2, 3]),
        'application/octet-stream',
      );
      expect(AiChatAttachments.imageMime([255, 216, 255]), 'image/jpeg');
    });
  });
}
