import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/thumbnail_service.dart';
import '../services/shell_open.dart';
import '../theme/app_strings.dart';
import 'app_card.dart';

/// 后端流水线步骤 action → 本地化名称。
/// 详细进度（节点圆圈、tooltip）不再直接展示英文 action 名。
String taskActionLabel(String action, bool zh) => switch (action) {
  'transcode' => zh ? '转码' : 'Transcode',
  'subtitle' => zh ? '字幕烧录' : 'Subtitle',
  'extract_frame' => zh ? '抽帧' : 'Snapshot',
  'extract_frames_range' => zh ? '区间抽帧' : 'Extract Frames',
  'extract_frames_all' => zh ? '全部抽帧' : 'Extract All Frames',
  'image_convert' => zh ? '图片转换' : 'Image Convert',
  'image_crop' => zh ? '图片裁剪' : 'Image Crop',
  'image_rotate' => zh ? '图片旋转' : 'Image Rotate',
  'image_scale' => zh ? '图片缩放' : 'Image Scale',
  'image_brightness' => zh ? '亮度调节' : 'Brightness',
  'image_noise' => zh ? '添加噪点' : 'Add Noise',
  'image_sharpen' => zh ? '图片锐化' : 'Sharpen',
  'image_denoise' => zh ? '图片降噪' : 'Denoise',
  'image_channel_extract' => zh ? '通道提取' : 'Channel Extract',
  'video_crop' => zh ? '视频裁剪' : 'Video Crop',
  'extract_audio' => zh ? '提取音频' : 'Extract Audio',
  'audio_metadata' => zh ? '元信息编辑' : 'Audio Metadata',
  'concat' => zh ? '合并媒体' : 'Concat',
  'image_sequence' => zh ? '图片合成视频' : 'Image to Video',
  '_file_copy' => zh ? '文件复制' : 'File Copy',
  '_cleanup' => zh ? '清理临时文件' : 'Cleanup',
  _ => zh ? '处理' : 'Process',
};

/// 迷你节点圆圈里的短标签：中文取前 2 字，英文取 action 前 3 字母大写。
String taskActionAbbr(String action, bool zh) {
  if (zh) {
    final label = taskActionLabel(action, true);
    return label.substring(0, label.length >= 2 ? 2 : label.length);
  }
  return action.replaceAll('_', ' ').toUpperCase().substring(0, action.length >= 3 ? 3 : action.length);
}

/// 后端占位值（N/A / unknown / 空）的本地化展示：空值直接不显示；
/// "N/A" 类占位在中文界面显示为「—」，避免英文残留在队列详情里。
String _dashIfNa(String v, bool isZh) {
  final t = v.trim();
  if (t.isEmpty || t.toLowerCase() == 'n/a' || t.toLowerCase() == 'na' || t == '-' || t.toLowerCase() == 'unknown') {
    return isZh ? '—' : 'N/A';
  }
  return t;
}

/// 任务卡片：双进度条 + 可展开的节点微型画布
class TaskCard extends StatelessWidget {
  final TaskInfo task;
  const TaskCard({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 不订阅整个 AppState（context.watch）：进度心跳/日志/探测等 notify 会
    // 让每张卡片高频重建。这里只 select 真正影响渲染的两个稳定值（语言、
    // ffmpeg 路径）；任务数据由父级以不可变 TaskInfo 实例传入，任务变化时
    // 父级会传入新实例触发重建。事件回调内用 read（不产生订阅）。
    final language = context.select<AppState, String>((s) => s.config.language);
    final ffmpeg = context.select<AppState, String>((s) => s.config.ffmpegPath);
    final s = AppStrings.of(language);
    final clr = scheme.onSurface;

    String statusLabel() => switch (task.status) {
      TaskStatus.pending => s.pending, TaskStatus.processing => s.processing,
      TaskStatus.completed => s.completed, TaskStatus.failed => s.failed,
      TaskStatus.cancelled => s.cancelled,
    };

    // 卡片样式由「主题→样式→卡片样式」（AppConfig.cardStyle）接管
    final cardStyle = context.select<AppState, String>((s) => s.config.cardStyle);
    return AppCard(
      style: cardStyle,
      radius: 12,
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.read<AppState>().toggleTaskExpanded(task.id),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(children: [
                // 缩略图
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: _ThumbWidget(filepath: task.inputPath, ffmpeg: ffmpeg),
                ),
                const SizedBox(width: 8),
                Icon(_statusIcon, size: 20, color: _statusColor(scheme)),
                const SizedBox(width: 10),
                Expanded(child: Text(task.filename,
                    style: TextStyle(fontWeight: FontWeight.w600, color: clr),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (task.status == TaskStatus.pending)
                  IconButton(icon: Icon(Icons.play_circle_filled, color: scheme.primary, size: 22),
                      tooltip: s.startProcessing, onPressed: () => context.read<AppState>().processSingleTask(task.id)),
                if (task.status == TaskStatus.processing)
                  TextButton.icon(icon: const Icon(Icons.stop, size: 14),
                      label: Text(s.cancel, style: const TextStyle(fontSize: 11)),
                      onPressed: () => context.read<AppState>().cancelTask(task.id),
                      style: TextButton.styleFrom(foregroundColor: scheme.error,
                          padding: const EdgeInsets.symmetric(horizontal: 6))),
                if (task.status == TaskStatus.completed) ...[
                  IconButton(
                    icon: const Icon(Icons.folder_open, size: 18), tooltip: s.qOpenFolder,
                    onPressed: () => ShellOpen.reveal(task.outputPath),
                    padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
                  IconButton(
                    icon: const Icon(Icons.play_circle_outline, size: 18), tooltip: s.qOpenFile,
                    onPressed: () => ShellOpen.path(task.outputPath),
                    padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
                ],
                if (task.status == TaskStatus.cancelled || task.status == TaskStatus.failed)
                  IconButton(
                    icon: Icon(Icons.delete_outline, size: 18, color: scheme.error), tooltip: s.cancel,
                    onPressed: () => context.read<AppState>().removeTask(task.id),
                    padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
                Text(statusLabel(), style: TextStyle(fontSize: 11, color: _statusColor(scheme))),
                const SizedBox(width: 8),
                Icon(task.expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: scheme.outline),
              ]),
              const SizedBox(height: 8),
              // 双进度条
              if (task.status == TaskStatus.processing || task.status == TaskStatus.completed) ...[
                // 上层：整体进度（分段）
                _SegmentedProgressBar(
                  segments: task.pipelineCalls?.length ?? 1,
                  callProgresses: task.callProgresses,
                  currentCallIndex: task.currentCallIndex,
                  height: 6,
                ),
                const SizedBox(height: 4),
                // 下层：当前步骤进度
                LinearProgressIndicator(
                  value: task.callProgresses.isNotEmpty && task.currentCallIndex < task.callProgresses.length
                      ? task.callProgresses[task.currentCallIndex]
                      : null,
                  minHeight: 3,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ],
              const SizedBox(height: 4),
              Row(children: [
                // 占位值（N/A / 空）统一本地化：中文下显示「—」，避免
                // "Remaining: N/A" 这类混合英文出现在队列详情里。
                _chip(Icons.timer_outlined, '${s.remaining}: ${_dashIfNa(task.remaining, s.isZh)}', scheme),
                const SizedBox(width: 12),
                if (task.speed.isNotEmpty) _chip(Icons.speed, _dashIfNa(task.speed, s.isZh), scheme),
                const Spacer(),
                Text('${task.progress.toStringAsFixed(0)}%', style: TextStyle(fontSize: 12, color: clr)),
              ]),
              // 失败任务：折叠态也直接显示错误摘要，点开卡片可查看完整日志
              if (task.status == TaskStatus.failed && task.error != null) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withAlpha(70),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.error_outline, size: 14, color: scheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        task.error!,
                        style: TextStyle(fontSize: 11, color: scheme.error),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                ),
              ],
            ]),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: _expanded(context, s, clr, scheme),
          crossFadeState: task.expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 250),
        ),
      ]),
    );
  }

  Widget _expanded(BuildContext ctx, AppStrings s, Color clr, ColorScheme scheme) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(height: 24),

      // 失败任务：完整错误信息直接置顶展示（不再只埋在「高级信息」折叠区里），
      // 并自动展开含日志的高级信息区，点开卡片即可排查。
      if (task.status == TaskStatus.failed && task.error != null) ...[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withAlpha(60),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.error.withAlpha(80)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.error_outline, size: 16, color: scheme.error),
              const SizedBox(width: 6),
              Text(s.qErrorDetails,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.error)),
            ]),
            const SizedBox(height: 8),
            SelectableText(task.error!,
                style: TextStyle(fontSize: 12, color: scheme.onErrorContainer, height: 1.4)),
          ]),
        ),
        const SizedBox(height: 16),
      ],

      // 节点流水线区域
      if (task.pipelineCalls != null && task.pipelineCalls!.isNotEmpty) ...[
        _SectionTitle(
          icon: Icons.account_tree,
          title: s.qPipeline,
          scheme: scheme,
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withAlpha(60),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _NodeMiniCanvas(
                calls: task.pipelineCalls!,
                callProgresses: task.callProgresses,
                currentCallIndex: task.currentCallIndex,
                status: task.status,
                zh: s.language == 'zh',
              ),
              const SizedBox(height: 8),
              _PipelineLegend(scheme: scheme, s: s),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
      
      // 文件信息区域
      _SectionTitle(
        icon: Icons.folder,
        title: s.qFileInfo,
        scheme: scheme,
      ),
      const SizedBox(height: 8),
      _FileInfoCard(
        input: task.inputPath,
        output: task.outputPath,
        scheme: scheme,
        s: s,
      ),
      const SizedBox(height: 16),
      
      // 技术参数区域
      _SectionTitle(
        icon: Icons.speed,
        title: s.qTechStats,
        scheme: scheme,
      ),
      const SizedBox(height: 8),
      _StatsGrid(
        stats: [
          (s.qFps, _dashIfNa(task.fps, s.isZh), Icons.videocam),
          (s.qBitrate, _dashIfNa(task.bitrate, s.isZh), Icons.trending_up),
          (s.qSize, task.outputSize == null ? s.qNone : task.outputSizeStr, Icons.storage),
        ],
        scheme: scheme,
      ),
      
      // 高级信息区域（可折叠）
      if (task.command != null || task.logLines.isNotEmpty || task.error != null) ...[
        const SizedBox(height: 16),
        _AdvancedInfoSection(
          command: task.command,
          logLines: task.logLines,
          error: task.error,
          scheme: scheme,
          s: s,
        ),
      ],
    ]),
  );



  Widget _chip(IconData icon, String text, ColorScheme scheme) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 12, color: scheme.outline), const SizedBox(width: 3),
    Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10, color: scheme.outline)),
  ]);

  IconData get _statusIcon => switch (task.status) {
    TaskStatus.pending => Icons.schedule, TaskStatus.processing => Icons.sync,
    TaskStatus.completed => Icons.check_circle, TaskStatus.failed => Icons.error,
    TaskStatus.cancelled => Icons.cancel,
  };

  Color _statusColor(ColorScheme sc) => switch (task.status) {
    TaskStatus.pending => sc.outline, TaskStatus.processing => sc.primary,
    TaskStatus.completed => Colors.green, TaskStatus.failed => sc.error,
    TaskStatus.cancelled => Colors.orange,
  };
}

/// 章节标题
class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final ColorScheme scheme;
  
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.primary),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

/// 流水线颜色图例
class _PipelineLegend extends StatelessWidget {
  final ColorScheme scheme;
  final AppStrings s;

  const _PipelineLegend({
    required this.scheme,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        _LegendItem(
          color: Colors.grey.shade400,
          label: s.qLegendPending,
        ),
        _LegendItem(
          color: Colors.amber,
          label: s.qLegendProcessing,
        ),
        _LegendItem(
          color: Colors.green,
          label: s.qLegendCompleted,
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  
  const _LegendItem({
    required this.color,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withAlpha(40),
            border: Border.all(color: color, width: 1.5),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 10, color: color),
        ),
      ],
    );
  }
}

/// 文件信息卡片
class _FileInfoCard extends StatelessWidget {
  final String input;
  final String output;
  final ColorScheme scheme;
  final AppStrings s;

  const _FileInfoCard({
    required this.input,
    required this.output,
    required this.scheme,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(40),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.input, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Text(
                s.qInput,
                style: TextStyle(fontSize: 10, color: scheme.outline, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            input,
            style: TextStyle(fontSize: 11, color: scheme.onSurface),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.output, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Text(
                s.qOutput,
                style: TextStyle(fontSize: 10, color: scheme.outline, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            output,
            style: TextStyle(fontSize: 11, color: scheme.onSurface),
            maxLines: 2,
          ),
        ],
      ),
    );
  }
}

/// 技术参数网格
class _StatsGrid extends StatelessWidget {
  final List<(String, String, IconData)> stats;
  final ColorScheme scheme;
  
  const _StatsGrid({
    required this.stats,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final crossAxisCount = isMobile ? 1 : 3;
    
    return LayoutBuilder(
      builder: (context, constraints) {
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: stats.map((stat) {
            final (label, value, icon) = stat;
            return SizedBox(
              width: constraints.maxWidth / crossAxisCount - (crossAxisCount > 1 ? 8 : 0),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withAlpha(40),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 16, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: TextStyle(fontSize: 10, color: scheme.outline),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            value.isEmpty ? '-' : value,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

/// 高级信息区域（可折叠）
class _AdvancedInfoSection extends StatefulWidget {
  final List<String>? command;
  final List<String> logLines;
  final String? error;
  final ColorScheme scheme;
  final AppStrings s;

  const _AdvancedInfoSection({
    this.command,
    required this.logLines,
    this.error,
    required this.scheme,
    required this.s,
  });

  @override
  State<_AdvancedInfoSection> createState() => _AdvancedInfoSectionState();
}

class _AdvancedInfoSectionState extends State<_AdvancedInfoSection> {
  // 失败任务自动展开：用户点开卡片就能直接看到完整 ffmpeg 日志，
  // 不必再手动展开第二级「高级信息」。
  late bool _expanded = widget.error != null;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: widget.scheme.surfaceContainerHighest.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.code, size: 14, color: widget.scheme.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.s.qAdvanced,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: widget.scheme.onSurface,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: widget.scheme.outline,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: _buildContent(),
            crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.command != null) ...[
            _InfoBlock(
              icon: Icons.terminal,
              title: widget.s.qCommand,
              content: widget.command!.join(' '),
              scheme: widget.scheme,
              isMonospace: true,
            ),
            const SizedBox(height: 8),
          ],
          if (widget.logLines.isNotEmpty) ...[
            _InfoBlock(
              icon: Icons.article_outlined,
              title: widget.s.qLogs,
              content: widget.logLines.join('\n'),
              scheme: widget.scheme,
              isMonospace: true,
              maxHeight: 160,
            ),
          ],
          // 错误摘要已在卡片展开区顶部展示，这里仅在无日志/命令时兜底显示
          if (widget.error != null && widget.command == null && widget.logLines.isEmpty) ...[
            _InfoBlock(
              icon: Icons.error_outline,
              title: widget.s.qError,
              content: widget.error!,
              scheme: widget.scheme,
              isError: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoBlock extends StatelessWidget {
  final IconData icon;
  final String title;
  final String content;
  final ColorScheme scheme;
  final bool isError;
  final bool isMonospace;
  final double? maxHeight;
  
  const _InfoBlock({
    required this.icon,
    required this.title,
    required this.content,
    required this.scheme,
    this.isError = false,
    this.isMonospace = false,
    this.maxHeight,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 12, color: isError ? scheme.error : scheme.outline),
            const SizedBox(width: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: isError ? scheme.error : scheme.outline,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          constraints: maxHeight != null ? BoxConstraints(maxHeight: maxHeight!) : null,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isError 
                ? scheme.errorContainer.withAlpha(40) 
                : scheme.surfaceContainerHighest.withAlpha(60),
            borderRadius: BorderRadius.circular(4),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              content,
              style: TextStyle(
                fontFamily: isMonospace ? 'monospace' : null,
                fontSize: 10,
                color: isError ? scheme.error : scheme.onSurface,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 分段进度条：上层整体进度，每段代表一个节点
class _SegmentedProgressBar extends StatelessWidget {
  final int segments;
  final List<double> callProgresses;
  final int currentCallIndex;
  final double height;

  const _SegmentedProgressBar({
    required this.segments,
    required this.callProgresses,
    required this.currentCallIndex,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      for (int i = 0; i < segments; i++) ...[
        Expanded(
          child: Container(
            height: height,
            margin: EdgeInsets.only(right: i < segments - 1 ? 2 : 0),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(2),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: i < callProgresses.length ? callProgresses[i].clamp(0.0, 1.0) : 0.0,
              child: Container(
                decoration: BoxDecoration(
                  // 关键修复：callProgresses 长度可能 < segments（task 刚创建或 pipelineCalls 还没展开），
                  // 直接 callProgresses[i] 会抛 RangeError 把整张 TaskCard 渲染挂掉 → 灰屏。
                  // 越界时按 0.0 处理（pending 灰段）。
                  color: i < callProgresses.length
                      ? (i == currentCallIndex && callProgresses[i] < 1.0
                          ? Colors.amber
                          : callProgresses[i] >= 1.0
                              ? Colors.green
                              : scheme.primary)
                      : scheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ],
    ]);
  }
}

/// 节点微型画布：横向滚动展示节点圆圈
class _NodeMiniCanvas extends StatelessWidget {
  final List<BackendCall> calls;
  final List<double> callProgresses;
  final int currentCallIndex;
  final TaskStatus status;
  final bool zh;

  const _NodeMiniCanvas({
    required this.calls,
    required this.callProgresses,
    required this.currentCallIndex,
    required this.status,
    this.zh = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMobile = MediaQuery.of(context).size.width < 600;
    final circleSize = isMobile ? 32.0 : 40.0;
    final spacing = isMobile ? 8.0 : 12.0;

    return Container(
      height: circleSize + 20,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            for (int i = 0; i < calls.length; i++) ...[
              _NodeCircle(
                call: calls[i],
                progress: i < callProgresses.length ? callProgresses[i] : 0.0,
                isCurrent: i == currentCallIndex,
                status: status,
                size: circleSize,
                zh: zh,
              ),
              if (i < calls.length - 1) SizedBox(width: spacing),
            ],
          ],
        ),
      ),
    );
  }
}

/// 节点圆圈：显示节点状态和进度
class _NodeCircle extends StatelessWidget {
  final BackendCall call;
  final double progress;
  final bool isCurrent;
  final TaskStatus status;
  final double size;
  final bool zh;

  const _NodeCircle({
    required this.call,
    required this.progress,
    required this.isCurrent,
    required this.status,
    required this.size,
    this.zh = true,
  });

  Color _getStatusColor(ColorScheme scheme) {
    if (status == TaskStatus.completed) return Colors.green;
    if (progress >= 1.0) return Colors.green;
    if (isCurrent && progress > 0.0 && progress < 1.0) return Colors.amber;
    if (status == TaskStatus.processing && isCurrent) return Colors.amber;
    return Colors.grey.shade400;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _getStatusColor(scheme);
    // 节点名本地化：不再把后端英文 action 名（TRANSCODE 等）直接展示给用户
    final label = taskActionLabel(call.action, zh);
    final abbr = taskActionAbbr(call.action, zh);

    return Tooltip(
      message: '$label\n${(zh ? AppStrings.zh : AppStrings.en).qProgress}: ${(progress * 100).toStringAsFixed(0)}%',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withAlpha(40),
          border: Border.all(color: color, width: 2),
        ),
        child: Center(
          child: Text(
            abbr,
            style: TextStyle(
              fontSize: size * 0.3,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

// 缩略图（生成逻辑统一走 ThumbnailService）
class _ThumbWidget extends StatefulWidget {
  final String filepath;
  final String? ffmpeg;
  const _ThumbWidget({required this.filepath, this.ffmpeg});
  @override
  State<_ThumbWidget> createState() => _ThumbWidgetState();
}
class _ThumbWidgetState extends State<_ThumbWidget> {
  String? _path;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await ThumbnailService.ensureThumbnail(widget.filepath, ffmpeg: widget.ffmpeg);
    if (mounted && p != null) setState(() => _path = p);
  }
  @override
  Widget build(BuildContext context) {
    if (_path != null) {
      return Image.file(File(_path!), width: 40, height: 25,
          fit: detectMediaType(widget.filepath) == MediaType.audio ? BoxFit.contain : BoxFit.cover);
    }
    return Icon(Icons.music_note, color: Theme.of(context).colorScheme.outline, size: 16);
  }
}