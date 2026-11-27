import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/quick_config_pipeline.dart';
import '../theme/app_strings.dart';
import '../widgets/app_alert_dialog.dart';
import '../widgets/step_editors/audio_compressor_step_editor.dart';
import '../widgets/step_editors/audio_convert_step_editor.dart';
import '../widgets/step_editors/audio_denoise_step_editor.dart';
import '../widgets/step_editors/audio_equalizer_step_editor.dart';
import '../widgets/step_editors/audio_fade_step_editor.dart';
import '../widgets/step_editors/audio_metadata_step_editor.dart';
import '../widgets/step_editors/audio_noise_gate_step_editor.dart';
import '../widgets/step_editors/audio_normalize_step_editor.dart';
import '../widgets/step_editors/audio_quality_step_editor.dart';
import '../widgets/step_editors/audio_reverse_step_editor.dart';
import '../widgets/step_editors/audio_silence_trim_step_editor.dart';
import '../widgets/step_editors/audio_spectrum_step_editor.dart';
import '../widgets/step_editors/audio_speed_step_editor.dart';
import '../widgets/step_editors/audio_volume_step_editor.dart';
import '../widgets/step_editors/audio_waveform_step_editor.dart';
import '../widgets/step_editors/av_process_step_editor.dart';
import '../widgets/step_editors/clip_step_editor.dart';
import '../widgets/step_editors/concat_media_step_editor.dart';
import '../widgets/step_editors/extract_audio_step_editor.dart';
import '../widgets/step_editors/frame_step_editor.dart';
import '../widgets/step_editors/generic_step_editor.dart';
import '../widgets/step_editors/image_adjust_step_editor.dart';
import '../widgets/step_editors/image_brightness_step_editor.dart';
import '../widgets/step_editors/image_channel_extract_step_editor.dart';
import '../widgets/step_editors/image_compress_step_editor.dart';
import '../widgets/step_editors/image_convert_step_editor.dart';
import '../widgets/step_editors/image_crop_step_editor.dart';
import '../widgets/step_editors/image_denoise_step_editor.dart';
import '../widgets/step_editors/image_noise_step_editor.dart';
import '../widgets/step_editors/image_rotate_step_editor.dart';
import '../widgets/step_editors/image_scale_step_editor.dart';
import '../widgets/step_editors/image_sharpen_step_editor.dart';
import '../widgets/step_editors/image_to_video_step_editor.dart';
import '../widgets/step_editors/speed_step_editor.dart';
import '../widgets/step_editors/subtitle_step_editor.dart';
import '../widgets/step_editors/video_crop_step_editor.dart';
import '../widgets/step_editors/video_deinterlace_step_editor.dart';
import '../widgets/step_editors/video_fade_step_editor.dart';
import '../widgets/step_editors/video_filter_step_editor.dart';
import '../widgets/step_editors/video_frame_rate_step_editor.dart';
import '../widgets/step_editors/video_geometry_step_editor.dart';
import '../widgets/step_editors/video_overlay_step_editor.dart';
import '../widgets/step_editors/video_reverse_step_editor.dart';

/// 单文件快捷配置向导。第一页选择有序处理节点，点击一行打开原节点参数编辑器。
///
/// onSave 完成后才执行 onExecute；后者由项目入口负责入队，页面不持有全局任务状态。
/// 通过 video 提供裁剪/帧预览/内嵌字幕信息；省略时可编辑保存的配置库模板。
class QuickConfigPage extends StatefulWidget {
  const QuickConfigPage({
    super.key,
    required this.config,
    required this.onSave,
    this.video,
    this.isZh,
    this.onExecute,
  });

  final QuickConfig config;
  final Future<void> Function(QuickConfig updated) onSave;
  final VideoFile? video;
  final bool? isZh;
  final Future<void> Function(QuickConfig updated, PipelineGraph graph)?
  onExecute;

  @override
  State<QuickConfigPage> createState() => _QuickConfigPageState();
}

class _QuickConfigPageState extends State<QuickConfigPage> {
  late final QuickConfig _config;
  bool _initialized = false;
  bool _dirty = false;
  bool _saving = false;
  bool _closing = false;
  bool _editing = false;
  String? _selectedId;
  String? _error;
  List<String> _legacyNotes = const [];

  List<PipelineNode> get _nodes => _config.nodes!;
  bool get _isZh =>
      widget.isZh ??
      AppStrings.of(context.read<AppState>().config.language).isZh;
  String _text(String zh, String en) => _isZh ? zh : en;
  String _label(PipelineNode node) => _isZh ? node.label : node.labelEn;

  @override
  void initState() {
    super.initState();
    _config = widget.config.deepCopy();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    if (_config.nodes == null) {
      // 旧配置仍按原映射读取，原 items 完整留在工作副本里。
      final legacy = buildGraphFromQuickConfig(_config, isZh: _isZh);
      _legacyNotes = legacy.skippedNotes;
      _config.nodes = legacy.graph.nodes
          .where(
            (node) =>
                node.type != PipelineStepType.start &&
                node.type != PipelineStepType.output,
          )
          .map((node) => node.deepCopy())
          .toList();
    }
    if (_nodes.isNotEmpty) _selectedId = _nodes.first.id;
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      _dirty = true;
      _error = null;
    });
  }

  void _add(PipelineStepType type) {
    final media = _nodes.isEmpty
        ? quickMediaType(_config.fileType)
        : _nodes.last.outputType!;
    setState(() {
      final node = createQuickConfigNode(type, media);
      _nodes.add(node);
      _selectedId = node.id;
      _dirty = true;
      _error = null;
    });
  }

  void _remove(int index) {
    setState(() {
      final removed = _nodes.removeAt(index);
      if (_selectedId == removed.id) {
        _selectedId = _nodes.isEmpty ? null : _nodes.last.id;
      }
      _dirty = true;
      _error = null;
    });
  }

  void _move(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _nodes.length) return;
    setState(() {
      final node = _nodes.removeAt(index);
      _nodes.insert(target, node);
      _dirty = true;
      _error = null;
    });
  }

  void _openNode(PipelineNode node) => setState(() {
    _selectedId = node.id;
    _editing = true;
  });

  Future<void> _save({bool execute = false}) async {
    if (_saving || _nodes.isEmpty) return;
    FocusScope.of(context).unfocus();
    final errors = [
      ...validateQuickConfigNodes(_config, isZh: _isZh),
      ...validateQuickConfigParameters(_config, isZh: _isZh),
    ];
    if (errors.isNotEmpty) {
      setState(() => _error = errors.join('\n'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    var saved = false;
    try {
      final snapshot = _config.deepCopy()..updatedAt = DateTime.now();
      final result = buildGraphFromQuickConfig(snapshot, isZh: _isZh);
      await widget.onSave(snapshot.deepCopy());
      saved = true;
      if (!mounted) return;
      _dirty = false;
      if (execute) await widget.onExecute!(snapshot.deepCopy(), result.graph);
      if (!mounted) return;
      _close(snapshot);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = saved
            ? _text(
                '配置已保存，加入队列失败：$error',
                'Configuration saved; could not queue: $error',
              )
            : _text('保存失败：$error', 'Could not save: $error'),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _close([QuickConfig? result]) {
    setState(() => _closing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  Future<void> _requestClose() async {
    if (_saving) return;
    if (!_dirty) {
      _close();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (ctx) => AppAlertDialog(
        title: Text(_text('放弃更改？', 'Discard changes?')),
        content: Text(
          _text(
            '尚未保存的节点与参数将被丢弃。',
            'Unsaved nodes and settings will be discarded.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_text('继续编辑', 'Keep editing')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_text('放弃', 'Discard')),
          ),
        ],
      ),
    );
    if (discard == true && mounted) _close();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    final errors = [
      ...validateQuickConfigNodes(_config, isZh: _isZh),
      ...validateQuickConfigParameters(_config, isZh: _isZh),
    ];
    final canSave = _nodes.isNotEmpty && errors.isEmpty && !_saving;
    final availableHeight =
        media.size.height -
        media.viewInsets.bottom -
        media.padding.vertical -
        32;
    final dialogHeight = math.min(740.0, math.max(0.0, availableHeight));
    final compactViewport =
        availableHeight < 460 || media.textScaler.scale(14) >= 20;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _text('快捷配置向导', 'Quick configuration'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '${_config.fileType.label(_isZh)}${widget.video != null
                      ? ' · ${widget.video!.filename}'
                      : _config.name.isNotEmpty
                      ? ' · ${_config.name}'
                      : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('quick_close'),
            onPressed: _saving ? null : _requestClose,
            tooltip: _text('关闭', 'Close'),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
    final stepLabel = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Text(
        _editing
            ? _text('2 · 配置处理节点', '2 · Configure nodes')
            : _text('1 · 选择处理节点', '1 · Select nodes'),
        style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
      ),
    );
    final messages = <Widget>[
      if (_legacyNotes.isNotEmpty)
        _notice(_legacyNotes.join('\n'), warning: false),
      if (_error != null || errors.isNotEmpty)
        _notice(_error ?? errors.join('\n'), warning: true),
    ];
    final flow = AbsorbPointer(
      absorbing: _saving,
      child: _editing
          ? _buildDetails(scrollable: !compactViewport)
          : _buildSelection(scrollable: !compactViewport),
    );
    final footer = Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (_editing)
            TextButton.icon(
              key: const ValueKey('quick_add_node'),
              onPressed: _saving
                  ? null
                  : () => setState(() => _editing = false),
              icon: const Icon(Icons.playlist_add),
              label: Text(_text('选择节点', 'Select nodes')),
            )
          else
            OutlinedButton.icon(
              key: const ValueKey('quick_next'),
              onPressed:
                  _saving ||
                      _nodes.isEmpty ||
                      validateQuickConfigNodes(_config, isZh: _isZh).isNotEmpty
                  ? null
                  : () => setState(() {
                      _selectedId ??= _nodes.first.id;
                      _editing = true;
                    }),
              icon: const Icon(Icons.tune),
              label: Text(_text('下一步', 'Next')),
            ),
          OutlinedButton.icon(
            key: const ValueKey('quick_save'),
            onPressed: canSave ? _save : null,
            icon: const Icon(Icons.save_outlined),
            label: Text(_text('保存', 'Save')),
          ),
          if (widget.onExecute != null)
            FilledButton.icon(
              key: const ValueKey('quick_execute'),
              onPressed: canSave ? () => _save(execute: true) : null,
              icon: const Icon(Icons.play_arrow),
              label: Text(_text('保存并入队', 'Save & queue')),
            ),
        ],
      ),
    );
    final layout = compactViewport
        ? SingleChildScrollView(
            key: const ValueKey('quick_compact_scroll'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                stepLabel,
                const Divider(height: 1),
                ...messages,
                flow,
                const Divider(height: 1),
                footer,
              ],
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              stepLabel,
              const Divider(height: 1),
              ...messages,
              Expanded(child: flow),
              const Divider(height: 1),
              footer,
            ],
          );

    return PopScope(
      canPop: _closing || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) _requestClose();
      },
      child: Dialog(
        insetAnimationDuration: media.disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 100),
        insetPadding: EdgeInsets.all(media.size.width < 600 ? 16 : 24),
        constraints: const BoxConstraints(maxWidth: 980),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: math.min(980.0, media.size.width - 16),
          height: dialogHeight,
          child: layout,
        ),
      ),
    );
  }

  Widget _notice(String text, {required bool warning}) => ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: 96),
    child: SingleChildScrollView(
      child: Container(
        width: double.infinity,
        color: warning
            ? Theme.of(context).colorScheme.errorContainer
            : Theme.of(context).colorScheme.secondaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: warning
                ? Theme.of(context).colorScheme.onErrorContainer
                : Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    ),
  );

  Widget _buildSelection({bool scrollable = true}) => LayoutBuilder(
    builder: (context, bounds) {
      if (bounds.maxWidth < 700) {
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildChain(),
            const SizedBox(height: 20),
            _buildCatalog(),
          ],
        );
        return scrollable
            ? SingleChildScrollView(
                key: const ValueKey('quick_selection'),
                padding: const EdgeInsets.all(16),
                child: content,
              )
            : Padding(
                key: const ValueKey('quick_selection'),
                padding: const EdgeInsets.all(16),
                child: content,
              );
      }
      if (scrollable) {
        return Row(
          key: const ValueKey('quick_selection'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _buildCatalog(),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _buildChain(),
              ),
            ),
          ],
        );
      }
      return Row(
        key: const ValueKey('quick_selection'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _buildCatalog(),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _buildChain(),
            ),
          ),
        ],
      );
    },
  );

  Widget _buildCatalog() {
    final types = availableQuickNodeTypes(_config.fileType, nodes: _nodes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _text('可用节点', 'Available nodes'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          _text(
            '点击添加，可重复添加。不兼容的节点已自动隐藏。',
            'Tap to add; repeat any node. Incompatible nodes are hidden.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (types.isEmpty)
          Text(
            _text(
              '请先修正右侧流程中的不兼容节点。',
              'Resolve the incompatible nodes in the sequence first.',
            ),
          ),
        for (final type in types)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: OutlinedButton(
              key: ValueKey('quick_pick_${type.name}'),
              onPressed: () => _add(type),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.add_circle_outline, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_label(PipelineNode(id: '', type: type))),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildChain() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        _text('处理顺序（${_nodes.length}）', 'Sequence (${_nodes.length})'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 6),
      Text(
        _text(
          '按列表从上到下串行执行。点击节点编辑参数。',
          'Runs serially from top to bottom. Tap a node to edit its settings.',
        ),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      if (_nodes.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(_text('添加第一个处理节点', 'Add your first processing node')),
        ),
      for (final (index, node) in _nodes.indexed)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                key: ValueKey('quick_node_${node.id}'),
                leading: CircleAvatar(radius: 16, child: Text('${index + 1}')),
                title: Text(
                  _label(node),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(node.mediaTag, maxLines: 1),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openNode(node),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    key: ValueKey('quick_up_${node.id}'),
                    tooltip: _text('上移', 'Move up'),
                    onPressed: index == 0 ? null : () => _move(index, -1),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                  ),
                  IconButton(
                    key: ValueKey('quick_down_${node.id}'),
                    tooltip: _text('下移', 'Move down'),
                    onPressed: index == _nodes.length - 1
                        ? null
                        : () => _move(index, 1),
                    icon: const Icon(Icons.arrow_downward, size: 18),
                  ),
                  IconButton(
                    key: ValueKey('quick_remove_${node.id}'),
                    tooltip: _text('移除', 'Remove'),
                    onPressed: () => _remove(index),
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );

  Widget _buildDetails({bool scrollable = true}) {
    final index = _nodes.indexWhere((node) => node.id == _selectedId);
    if (index < 0) return const SizedBox.shrink();
    final node = _nodes[index];
    final editor = _buildNodeEditor(node);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: _text('上一个节点', 'Previous node'),
                onPressed: index == 0
                    ? null
                    : () => _openNode(_nodes[index - 1]),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '${index + 1}/${_nodes.length} · ${_label(node)}',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                tooltip: _text('下一个节点', 'Next node'),
                onPressed: index == _nodes.length - 1
                    ? null
                    : () => _openNode(_nodes[index + 1]),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        if (scrollable)
          Expanded(
            child: SingleChildScrollView(
              key: ValueKey('quick_editor_${node.id}'),
              child: editor,
            ),
          )
        else
          Padding(
            key: ValueKey('quick_editor_${node.id}'),
            padding: const EdgeInsets.all(16),
            child: editor,
          ),
      ],
    );
  }

  Widget _buildNodeEditor(PipelineNode node) {
    final isZh = _isZh;
    final onChanged = _changed;
    Widget editor;
    switch (node.type) {
      case PipelineStepType.avProcess:
        editor = AvProcessStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.subtitle:
        editor = SubtitleStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
          embeddedSubtitles: widget.video?.subtitles ?? const [],
        );
      case PipelineStepType.clip:
        editor = ClipStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          videoPath: widget.video?.filepath ?? '',
          videoDuration: widget.video?.duration ?? 0,
          isZh: isZh,
        );
      case PipelineStepType.frame:
        editor = FrameStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          videoPath: widget.video?.filepath ?? '',
          videoDuration: widget.video?.duration ?? 0,
          isZh: isZh,
        );
      case PipelineStepType.speed:
        editor = SpeedStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.imageConvert:
        editor = ImageConvertStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioConvert:
        editor = AudioConvertStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioQuality:
        editor = AudioQualityStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioSpeed:
        editor = AudioSpeedStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioVolume:
        editor = AudioVolumeStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioCompressor:
        editor = AudioCompressorStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioMetadata:
        editor = AudioMetadataStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.extractAudio:
        editor = ExtractAudioStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
          videoPath: widget.video?.filepath ?? '',
          videoDuration: widget.video?.duration ?? 0,
        );
      case PipelineStepType.concatMedia:
        editor = ConcatMediaStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
          containerFileCount: 1,
        );
      case PipelineStepType.imageToVideo:
        editor = ImageToVideoStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
          containerFileCount: 1,
        );
      case PipelineStepType.imageCrop:
        editor = ImageCropStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
          sourceImagePath: widget.video?.fileMediaType == MediaType.image
              ? widget.video?.filepath
              : null,
        );
      case PipelineStepType.imageRotate:
        editor = ImageRotateStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.imageScale:
        editor = ImageScaleStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.imageBrightness:
        editor = ImageBrightnessStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.imageNoise:
        editor = ImageNoiseStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.imageSharpen:
        editor = ImageSharpenStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.imageDenoise:
        editor = ImageDenoiseStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.imageChannelExtract:
        editor = ImageChannelExtractStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.videoCrop:
        editor = VideoCropStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
          videoPath: widget.video?.filepath ?? '',
          videoWidth: widget.video?.width ?? 0,
          videoHeight: widget.video?.height ?? 0,
          fps: widget.video?.fps ?? 0,
        );
      case PipelineStepType.videoFilter:
        editor = VideoFilterStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.videoGeometry:
        editor = VideoGeometryStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.videoOverlay:
        editor = VideoOverlayStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioFade:
        editor = AudioFadeStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioSpectrum:
        editor = AudioSpectrumStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioWaveform:
        editor = AudioWaveformStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioReverse:
        editor = AudioReverseStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.videoReverse:
        editor = VideoReverseStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioEqualizer:
        editor = AudioEqualizerStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.videoFade:
        editor = VideoFadeStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.imageAdjust:
        editor = ImageAdjustStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.imageCompress:
        editor = ImageCompressStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioNormalize:
        editor = AudioNormalizeStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioNoiseGate:
        editor = AudioNoiseGateStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.videoFrameRate:
        editor = VideoFrameRateStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioDenoise:
        editor = AudioDenoiseStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.audioSilenceTrim:
        editor = AudioSilenceTrimStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.videoDeinterlace:
        editor = VideoDeinterlaceStepEditor(
          key: ValueKey(node.id),
          params: node.params,
          onChanged: onChanged,
          isZh: isZh,
        );
      case PipelineStepType.metadataStrip:
      case PipelineStepType.mediaConvert:
      case PipelineStepType.mediaScale:
      case PipelineStepType.mediaCrop:
      case PipelineStepType.mediaRotate:
      case PipelineStepType.mediaColor:
      case PipelineStepType.mediaSharpen:
      case PipelineStepType.mediaOverlay:
        // 通用节点：媒体类型必选（属性面板顶部选择器），按类型复用既有编辑器
        editor = GenericMediaStepEditor(
          key: ValueKey(node.id),
          node: node,
          onChanged: onChanged,
          isZh: isZh,
          videoPath: widget.video?.filepath ?? '',
          videoDuration: widget.video?.duration ?? 0,
          videoWidth: widget.video?.width ?? 0,
          videoHeight: widget.video?.height ?? 0,
          fps: widget.video?.fps ?? 0,
          sourceImagePath: widget.video?.fileMediaType == MediaType.image
              ? widget.video?.filepath
              : null,
        );
      case PipelineStepType.start:
      case PipelineStepType.output:
      case PipelineStepType.plugin:
      case PipelineStepType.unknown:
        editor = Text(
          _text(
            '此节点不支持快捷配置。',
            'This node is not supported in quick configuration.',
          ),
        );
    }
    return editor;
  }
}
