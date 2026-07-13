import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

class AudioMetadataStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;
  const AudioMetadataStepEditor({super.key, required this.params, required this.onChanged, this.isZh = true});
  @override
  State<AudioMetadataStepEditor> createState() => _AudioMetadataStepEditorState();
}

class _AudioMetadataStepEditorState extends State<AudioMetadataStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('cover_path', () => '');
    p.putIfAbsent('lyrics_path', () => '');
    p.putIfAbsent('remove_cover', () => false);
    p.putIfAbsent('remove_lyrics', () => false);
  }

  void _update(String key, dynamic value) { setState(() => p[key] = value); widget.onChanged(); }

  Future<void> _pickCover() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp'],
    );
    if (result != null && result.files.single.path != null) {
      _update('cover_path', result.files.single.path!);
      _update('remove_cover', false);
    }
  }

  Future<void> _pickLyrics() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['lrc', 'txt', 'srt'],
    );
    if (result != null && result.files.single.path != null) {
      _update('lyrics_path', result.files.single.path!);
      _update('remove_lyrics', false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final coverPath = p['cover_path'] as String? ?? '';
    final lyricsPath = p['lyrics_path'] as String? ?? '';
    final removeCover = p['remove_cover'] as bool? ?? false;
    final removeLyrics = p['remove_lyrics'] as bool? ?? false;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '元信息编辑' : 'Metadata Editor',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        // ── 封面 ──
        Text(zh ? '封面图片' : 'Cover Art', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 8),
        if (coverPath.isNotEmpty && !removeCover) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: File(coverPath).existsSync()
                ? Image.file(File(coverPath), width: double.infinity, height: 120, fit: BoxFit.contain)
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
                onPressed: () => _update('cover_path', ''), constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Checkbox(value: removeCover, onChanged: (v) { _update('remove_cover', v ?? false); if (v == true) _update('cover_path', ''); },
              visualDensity: VisualDensity.compact),
          Text(zh ? '删除现有封面' : 'Remove existing cover', style: TextStyle(fontSize: 12, color: cs.onSurface)),
        ]),

        const SizedBox(height: 16),
        Divider(color: cs.outlineVariant.withAlpha(60)),
        const SizedBox(height: 12),

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
                onPressed: () => _update('lyrics_path', ''), constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Checkbox(value: removeLyrics, onChanged: (v) { _update('remove_lyrics', v ?? false); if (v == true) _update('lyrics_path', ''); },
              visualDensity: VisualDensity.compact),
          Text(zh ? '删除现有歌词' : 'Remove existing lyrics', style: TextStyle(fontSize: 12, color: cs.onSurface)),
        ]),

        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: cs.surfaceContainerHighest.withAlpha(60), borderRadius: BorderRadius.circular(8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 14, color: cs.outline),
            const SizedBox(width: 8),
            Expanded(child: Text(
              zh ? '支持嵌入封面图片（JPG/PNG）和歌词文件（LRC/TXT）。\n封面将作为 attached_pic 写入，歌词作为元数据嵌入。'
                 : 'Embed cover art (JPG/PNG) and lyrics (LRC/TXT).\nCover is written as attached_pic, lyrics as metadata.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
