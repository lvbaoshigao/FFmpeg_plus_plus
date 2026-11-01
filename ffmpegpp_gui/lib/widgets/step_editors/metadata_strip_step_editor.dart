import 'package:flutter/material.dart';

import '../../models/models.dart';
import 'editor_kit.dart';

/// 元数据删除节点编辑器（图片 / 音频 / 视频三合一）。
///
/// 节点本体是「通用节点」：媒体类型由顶部选择器决定，三种类型共用同一个
/// C++ 原生 remove_metadata 执行器（stream copy，不重新编码）。
class MetadataStripStepEditor extends ParamsStepEditor {
  const MetadataStripStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
    this.mediaKind,
  });

  /// 当前选择的媒体类型（决定显示"保留章节"还是"删除封面"）。
  final MediaType? mediaKind;

  @override
  State<MetadataStripStepEditor> createState() => _MetadataStripStepEditorState();
}

class _MetadataStripStepEditorState extends State<MetadataStripStepEditor>
    with StepEditorState<MetadataStripStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'keep_chapters': false, 'remove_cover': false});
  }

  @override
  Widget build(BuildContext context) {
    final zh = this.zh;
    final cs = Theme.of(context).colorScheme;
    final kind = widget.mediaKind;
    final keepChapters = p['keep_chapters'] == true;
    final removeCover = p['remove_cover'] == true;

    return StepEditorScaffold(
      title: zh ? '删除元数据' : 'Remove Metadata',
      infoText: zh
          ? '通过流复制清空容器标签（图片 EXIF/XMP、音频 ID3/标签、视频 tags），\n'
              '不重新编码，画面/音质完全不变，处理速度只受磁盘复制限制。'
          : 'Clears container tags via stream copy (image EXIF/XMP, audio ID3/tags, '
              'video tags). No re-encode, so quality and speed are unaffected.',
      children: [
        if (kind == MediaType.video)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: keepChapters,
            title: Text(zh ? '保留章节信息' : 'Keep chapters',
                style: const TextStyle(fontSize: 12)),
            subtitle: Text(
                zh ? '仅清除 tags，保留视频章节标记' : 'Strip tags but keep chapter marks',
                style: TextStyle(fontSize: 10, color: cs.outline)),
            onChanged: (v) => update('keep_chapters', v == true),
          ),
        if (kind == MediaType.audio)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: removeCover,
            title: Text(zh ? '同时删除封面图' : 'Also remove cover art',
                style: const TextStyle(fontSize: 12)),
            subtitle: Text(
                zh ? '封面是内嵌图片流，不属于 tags' : 'Cover art is an embedded stream, not a tag',
                style: TextStyle(fontSize: 10, color: cs.outline)),
            onChanged: (v) => update('remove_cover', v == true),
          ),
        if (kind == MediaType.image)
          Text(
            zh
                ? '将删除 EXIF（拍摄参数/GPS）、XMP、ICC 等全部元数据。'
                : 'Removes EXIF (camera/GPS), XMP, ICC and all other metadata.',
            style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
          ),
        if (kind == null)
          Text(
            zh ? '请先在上方选择媒体类型。' : 'Pick a media type above first.',
            style: TextStyle(fontSize: 11, color: cs.outline),
          ),
      ],
    );
  }
}
