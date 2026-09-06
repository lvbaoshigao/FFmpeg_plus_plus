import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'editor_kit.dart';

class AudioMetadataStepEditor extends ParamsStepEditor {
  const AudioMetadataStepEditor({super.key, required super.params, required super.onChanged, super.isZh = true});
  @override
  State<AudioMetadataStepEditor> createState() => _AudioMetadataStepEditorState();
}

class _AudioMetadataStepEditorState extends State<AudioMetadataStepEditor> with StepEditorState<AudioMetadataStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'cover_path': '', 'lyrics_path': '', 'remove_cover': false, 'remove_lyrics': false});
  }

  Future<void> _pickCover() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp'],
    );
    if (result != null && result.files.single.path != null) {
      if (!mounted) return;
      update('cover_path', result.files.single.path!);
      update('remove_cover', false);
    }
  }

  Future<void> _pickLyrics() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['lrc', 'txt', 'srt'],
    );
    if (result != null && result.files.single.path != null) {
      if (!mounted) return;
      update('lyrics_path', result.files.single.path!);
      update('remove_lyrics', false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final coverPath = p['cover_path'] as String? ?? '';
    final lyricsPath = p['lyrics_path'] as String? ?? '';
    final removeCover = p['remove_cover'] as bool? ?? false;
    final removeLyrics = p['remove_lyrics'] as bool? ?? false;

    return StepEditorScaffold(
      title: zh ? '元信息编辑' : 'Metadata Editor',
      infoText: zh ? '支持嵌入封面图片（JPG/PNG）和歌词文件（LRC/TXT）。\n封面将作为 attached_pic 写入，歌词作为元数据嵌入。'
                   : 'Embed cover art (JPG/PNG) and lyrics (LRC/TXT).\nCover is written as attached_pic, lyrics as metadata.',
      children: [
        // ── 封面 ──
        Text(zh ? '封面图片' : 'Cover Art', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 8),
        if (coverPath.isNotEmpty && !removeCover) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: File(coverPath).existsSync()
                ? Image.file(File(coverPath), width: double.infinity, height: 120, cacheWidth: 720, fit: BoxFit.contain)
                : Container(height: 60, color: cs.errorContainer, child: Center(
                    child: Text(zh ? '文件不存在' : 'File not found', style: TextStyle(fontSize: 11, color: cs.error)))),
          ),
          const SizedBox(height: 4),
          Text(coverPath.split('/').last.split('\\').last,
              style: TextStyle(fontSize: 10, color: cs.outline), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
        ],
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: removeCover ? null : _pickCover,
            icon: const Icon(Icons.image, size: 16),
            label: Text(coverPath.isEmpty ? (zh ? '选择封面' : 'Select Cover') : (zh ? '更换封面' : 'Change Cover'),
                style: const TextStyle(fontSize: 12)),
          )),
          const SizedBox(width: 8),
          if (coverPath.isNotEmpty && !removeCover)
            IconButton(icon: Icon(Icons.close, size: 18, color: cs.error), tooltip: zh ? '移除' : 'Remove',
                onPressed: () => update('cover_path', ''), constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Checkbox(value: removeCover, onChanged: (v) { update('remove_cover', v ?? false); if (v == true) update('cover_path', ''); },
              visualDensity: VisualDensity.compact),
          Text(zh ? '删除现有封面' : 'Remove existing cover', style: TextStyle(fontSize: 12, color: cs.onSurface)),
        ]),

        const SizedBox(height: 8),
        Divider(color: cs.outlineVariant.withAlpha(60)),
        const SizedBox(height: 8),

        // ── 歌词 ──
        Text(zh ? '歌词文件' : 'Lyrics File', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 8),
        if (lyricsPath.isNotEmpty && !removeLyrics) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: cs.surfaceContainerHighest.withAlpha(60), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(Icons.lyrics, size: 16, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(lyricsPath.split('/').last.split('\\').last,
                  style: TextStyle(fontSize: 11, color: cs.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
          const SizedBox(height: 4),
        ],
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: removeLyrics ? null : _pickLyrics,
            icon: const Icon(Icons.lyrics, size: 16),
            label: Text(lyricsPath.isEmpty ? (zh ? '选择歌词' : 'Select Lyrics') : (zh ? '更换歌词' : 'Change Lyrics'),
                style: const TextStyle(fontSize: 12)),
          )),
          const SizedBox(width: 8),
          if (lyricsPath.isNotEmpty && !removeLyrics)
            IconButton(icon: Icon(Icons.close, size: 18, color: cs.error), tooltip: zh ? '移除' : 'Remove',
                onPressed: () => update('lyrics_path', ''), constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Checkbox(value: removeLyrics, onChanged: (v) { update('remove_lyrics', v ?? false); if (v == true) update('lyrics_path', ''); },
              visualDensity: VisualDensity.compact),
          Text(zh ? '删除现有歌词' : 'Remove existing lyrics', style: TextStyle(fontSize: 12, color: cs.onSurface)),
        ]),
      ],
    );
  }
}
