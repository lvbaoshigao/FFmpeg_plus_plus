import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// A local attachment reference. Bytes are never serialized into history.
final class AiChatAttachment {
  const AiChatAttachment({
    required this.name,
    required this.path,
    required this.size,
    required this.mimeType,
    this.managed = false,
  });
  final String name;
  final String path;
  final int size;
  final String mimeType;
  final bool managed;
  bool get isImage => mimeType.startsWith('image/');
  Map<String, dynamic> toJson() => {
    'type': 'attachment',
    'name': name,
    'path': path,
    'size': size,
    'mimeType': mimeType,
    'managed': managed,
  };
  factory AiChatAttachment.fromJson(Map<String, dynamic> json) =>
      AiChatAttachment(
        name: json['name'] as String? ?? 'File',
        path: json['path'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        managed: json['managed'] == true,
      );
}

/// Request-wide raw-image budget shared across historical messages.
final class AiAttachmentBudget {
  AiAttachmentBudget({this.remaining = AiChatAttachments.maxInlineBytes});
  int remaining;
}

/// Prepares local references, not server uploads. Sent copies remain available
/// for history and detached-window handoff; only unsent copies may be removed.
final class AiChatAttachments {
  static const maxCount = 8;
  static const maxImageBytes = 8 * 1024 * 1024;
  static const maxInlineBytes = 20 * 1024 * 1024;
  static const maxCopyBytes = 64 * 1024 * 1024;

  static String imageMime(List<int> bytes) {
    bool starts(List<int> magic) =>
        bytes.length >= magic.length &&
        List.generate(
          magic.length,
          (i) => bytes[i] == magic[i],
        ).every((v) => v);
    if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return 'image/png';
    if (starts([255, 216, 255])) return 'image/jpeg';
    if (starts([71, 73, 70, 56])) return 'image/gif';
    if (bytes.length >= 12 &&
        starts([82, 73, 70, 70]) &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
    return 'application/octet-stream';
  }

  static Future<Uint8List> _readBounded(
    Stream<List<int>> stream,
    int limit,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > limit) {
        throw const FormatException('Attachment exceeds the size limit.');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Future<AiChatAttachment> prepare(
    PlatformFile picked, {
    Directory? supportDirectory,
  }) async {
    var path = picked.path;
    var managed = false;
    if (path == null || path.isEmpty || path.startsWith('content://')) {
      if ((picked.lengthSync() ?? 0) > maxCopyBytes) {
        throw const FormatException('Pathless files must be at most 64 MiB.');
      }
      final data = await _readBounded(picked.readAsByteStream(), maxCopyBytes);
      final base = supportDirectory ?? await getApplicationSupportDirectory();
      // UUID-only names prevent traversal from picker-supplied display names.
      final owned = Directory(
        '${base.path}${Platform.pathSeparator}ai_attachments',
      );
      await owned.create(recursive: true);
      path = '${owned.path}${Platform.pathSeparator}${const Uuid().v4()}';
      await File(path).writeAsBytes(data, flush: true);
      managed = true;
    }
    final file = File(path);
    final size = await file.length();
    final head = await _readBounded(
      file.openRead(0, size < 12 ? size : 12),
      12,
    );
    return AiChatAttachment(
      name: picked.name,
      path: path,
      size: size,
      mimeType: imageMime(head),
      managed: managed,
    );
  }

  static Future<void> discard(AiChatAttachment attachment) async {
    if (!attachment.managed) return;
    final base = await getApplicationSupportDirectory();
    final root =
        '${base.path}${Platform.pathSeparator}ai_attachments${Platform.pathSeparator}';
    if (!attachment.path.startsWith(root)) return;
    try {
      await File(attachment.path).delete();
    } on FileSystemException {
      /* Already removed. */
    }
  }

  static List<AiChatAttachment> fromBlocks(
    List<Map<String, dynamic>>? blocks,
  ) => [
    for (final block in blocks ?? <Map<String, dynamic>>[])
      if (block['type'] == 'attachment') AiChatAttachment.fromJson(block),
  ];

  static Future<List<Map<String, dynamic>>> content(
    String text,
    List<AiChatAttachment> attachments, {
    required bool vision,
    required bool anthropic,
    AiAttachmentBudget? budget,
  }) async {
    final blocks = <Map<String, dynamic>>[];
    final metadata = attachments
        .map(
          (a) => jsonEncode({
            'name': a.name,
            'local_path': a.path,
            'bytes': a.size,
            'mime_type': a.mimeType,
          }),
        )
        .join('\n');
    blocks.add({
      'type': 'text',
      'text': [
        if (text.isNotEmpty) text,
        if (attachments.isNotEmpty)
          'Local attachments (not uploaded; use existing tools to inspect paths):\n$metadata',
      ].join('\n\n'),
    });
    final available = budget ?? AiAttachmentBudget();
    for (final attachment in attachments) {
      if (!vision || !attachment.isImage || attachment.size > maxImageBytes) {
        continue;
      }
      try {
        final data = await _readBounded(
          File(attachment.path).openRead(),
          maxImageBytes,
        );
        final mime = imageMime(data);
        if (!mime.startsWith('image/') || data.length > available.remaining) {
          continue;
        }
        available.remaining -= data.length;
        final encoded = base64Encode(data);
        blocks.add(
          anthropic
              ? {
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': mime,
                    'data': encoded,
                  },
                }
              : {
                  'type': 'image_url',
                  'image_url': {'url': 'data:$mime;base64,$encoded'},
                },
        );
      } on FileSystemException {
        /* History may reference a removed local file. */
      } on FormatException {
        /* File grew after picking; metadata remains usable. */
      }
    }
    return blocks;
  }
}
