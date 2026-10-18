import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../services/shell_open.dart';
import '../services/thumbnail_service.dart';
import '../theme/app_neutral_surface.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_strings.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';
import 'app_slider.dart';
import 'toast.dart';

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

/// 暂停状态文案。
///
/// 为什么不在 AppStrings 里加 paused 词条：主题/文案层不在本次队列改造的
/// 改动范围，而 TaskStatus.paused 必须立刻在所有 switch 里有文案。这里给出
/// 一份共享词条，队列卡片、悬浮卡、详情面板统一引用，避免三处各写一遍中英文。
String taskPausedLabel(bool zh) => zh ? '已暂停' : 'Paused';

/// 迷你节点圆圈里的短标签：中文取前 2 字，英文取 action 前 3 字母大写。
String taskActionAbbr(String action, bool zh) {
  // 无流水线的单步任务在「运行节点视口」里会用一个合成节点（action 为空），
  // 这里兜底文案，避免空字符串 sub- 越界/显示空白圆环。
  if (action.isEmpty) return zh ? '处理' : 'RUN';
  if (zh) {
    final label = taskActionLabel(action, true);
    return label.substring(0, label.length >= 2 ? 2 : label.length);
  }
  return action
      .replaceAll('_', ' ')
      .toUpperCase()
      .substring(0, action.length >= 3 ? 3 : action.length);
}

/// 后端占位值（N/A / unknown / 空）的本地化展示：空值直接不显示；
/// "N/A" 类占位在中文界面显示为「—」，避免英文残留在队列详情里。
String _dashIfNa(String v, bool isZh) {
  final t = v.trim();
  if (t.isEmpty ||
      t.toLowerCase() == 'n/a' ||
      t.toLowerCase() == 'na' ||
      t == '-' ||
      t.toLowerCase() == 'unknown') {
    return isZh ? '—' : 'N/A';
  }
  return t;
}

/// 秒 → `MM:SS` / `HH:MM:SS`（媒体时长展示用）。
String _fmtSeconds(double seconds) {
  if (seconds <= 0 || !seconds.isFinite) return '—';
  final total = seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final sec = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '${two(h)}:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

/// 队列卡片里进度条的高度。
///
/// 不复用全局的 [kAppTrackHeight]（16）：那是**滑块轨道**的规格 —— 滑块需要一根
/// 手指按得住的粗轨道，而队列卡片里是纯展示的进度条，两条 16px 叠起来光轨道就占掉
/// 32px + 间距，整张卡被撑得虚胖（用户反馈「进度条过于宽大」）。
/// 8px 既保住胶囊语义（圆角 = 高度 / 2），又与卡片里 11 / 12px 的文字成比例。
const double kQueueTrackHeight = 8;

/// 分段进度条与当前步骤进度条之间的垂直间距。
///
/// 二者是同一条进度语义的上下两层，3px 的缝隙足矣；用 6~8 会被读成两块互不相干的
/// 指标（改造前是 4，且中间还夹着一条 16px 的下层条，越看越散）。
const double kQueueTrackGap = 3;

/// 队列卡片内文字规格：标签 / 值 / 区块标题三级。
///
/// 抽出来的原因：改造前同一张卡里字号散成 10 / 11 / 12 / 13 四档，而且**标签普遍
/// 比同一行的值小 2px**（10 vs 12），密集信息区看着像没对齐的草稿。统一成三级。
const double kQueueFsLabel = 11;
const double kQueueFsValue = 12;
const double kQueueFsSection = 13;

/// 展开详情里相邻区块的垂直间距。
///
/// 改造前是「有的地方 16、有的地方 8、靠 Divider 撑」，六个区块的节奏完全不一致；
/// 统一成一个常量，靠 _SectionTitle 的字号层级而不是间距差来表达分组关系。
const double kQueuePanelGap = 14;

/// 任务卡片：双进度条 + 可展开的节点微型画布
class TaskCard extends StatelessWidget {
  final TaskInfo task;
  final bool? detailsInSheet;
  const TaskCard({super.key, required this.task, this.detailsInSheet});

  @override
  Widget build(BuildContext context) {
    final sheet = detailsInSheet ?? isMobilePlatform;
    final scheme = Theme.of(context).colorScheme;
    // 不订阅整个 AppState（context.watch）：进度心跳/日志/探测等 notify 会
    // 让每张卡片高频重建。这里只 select 真正影响渲染的两个稳定值（语言、
    // ffmpeg 路径）；任务数据由父级以不可变 TaskInfo 实例传入，任务变化时
    // 父级会传入新实例触发重建。事件回调内用 read（不产生订阅）。
    final language = context.select<AppState, String>((s) => s.config.language);
    final ffmpeg = context.select<AppState, String>((s) => s.config.ffmpegPath);
    final s = AppStrings.of(language);
    final clr = scheme.onSurface;

    String statusLabel() => switch (task.status) {
      TaskStatus.pending => s.pending,
      TaskStatus.processing => s.processing,
      // AppStrings 里没有 paused（主题文件不在本次改动范围），用共享助手取词。
      TaskStatus.paused => taskPausedLabel(s.isZh),
      TaskStatus.completed => s.completed,
      TaskStatus.failed => s.failed,
      TaskStatus.cancelled => s.cancelled,
    };

    // 卡片样式由「主题→样式→卡片样式」（AppConfig.cardStyle）接管
    final cardStyle = context.select<AppState, String>(
      (s) => s.config.cardStyle,
    );
    return AppCard(
      style: cardStyle,
      radius: 12,
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => sheet
                ? showTaskDetailsSheet(context, task.id)
                : context.read<AppState>().toggleTaskExpanded(task.id),
            // 长按删除：终态任务（已完成/失败/已取消）可从列表移除记录，
            // 弹确认框防误触。处理中的任务不允许删除。
            onLongPress: _isTerminal ? () => _confirmRemove(context) : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  // 头部：缩略图 + 「文件名 / 状态」两行左列 + 右侧操作按钮 + 展开箭头。
                  // 原版状态文字（11px）夹在操作按钮和展开箭头中间，窄屏下标题行
                  // 非常拥挤；现在状态连同剩余时间下沉为文件名下的小字行。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 缩略图
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: _ThumbWidget(
                          filepath: task.inputPath,
                          ffmpeg: ffmpeg,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.filename,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: clr,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Icon(
                                  _statusIcon,
                                  size: 13,
                                  color: _statusColor(scheme),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  statusLabel(),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _statusColor(scheme),
                                  ),
                                ),
                                if (task.elapsed.isNotEmpty)
                                  _chip(
                                    Icons.timer_outlined,
                                    '${s.qElapsed}: ${task.elapsed}',
                                    scheme,
                                  ),
                                // 剩余时间紧跟状态：处理中/暂停中有意义（暂停时是
                                // 冻结的预计剩余），等待/终态不占位
                                if (task.status == TaskStatus.processing ||
                                    task.status == TaskStatus.paused) ...[
                                  const SizedBox(width: 8),
                                  _chip(
                                    Icons.timer_outlined,
                                    '${s.remaining}: ${_dashIfNa(task.remaining, s.isZh)}',
                                    scheme,
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (task.status == TaskStatus.pending)
                        IconButton(
                          icon: Icon(
                            Icons.play_circle_filled,
                            color: scheme.primary,
                            size: 22,
                          ),
                          tooltip: s.startProcessing,
                          onPressed: () => context
                              .read<AppState>()
                              .processSingleTask(task.id),
                        ),
                      // 运行中的任务：暂停 + 停止。两个都是紧凑文字按钮，
                      // 移动端卡片宽度有限，放在状态行右侧（不会挤掉文件名）。
                      // 暂停走真实的进程冻结（见 AppState.pauseTask）：如果当前
                      // 没有可冻结的进程，按钮会给出失败提示而不是假装暂停。
                      if (task.status == TaskStatus.processing)
                        TextButton.icon(
                          icon: const Icon(Icons.pause, size: 14),
                          label: Text(
                            s.isZh ? '暂停' : 'Pause',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onPressed: () => _togglePause(context),
                          style: TextButton.styleFrom(
                            foregroundColor: scheme.sem.info,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                        ),
                      if (task.status == TaskStatus.paused)
                        TextButton.icon(
                          icon: const Icon(Icons.play_arrow, size: 14),
                          label: Text(
                            s.isZh ? '继续' : 'Resume',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onPressed: () => _togglePause(context),
                          style: TextButton.styleFrom(
                            foregroundColor: scheme.sem.success,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                        ),
                      if (task.status == TaskStatus.processing ||
                          task.status == TaskStatus.paused)
                        TextButton.icon(
                          icon: const Icon(Icons.stop, size: 14),
                          label: Text(
                            s.isZh ? '停止' : 'Stop',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onPressed: () =>
                              context.read<AppState>().cancelTask(task.id),
                          style: TextButton.styleFrom(
                            foregroundColor: scheme.error,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                        ),
                      if (task.status == TaskStatus.completed) ...[
                        IconButton(
                          icon: const Icon(Icons.folder_open, size: 18),
                          tooltip: s.qOpenFolder,
                          onPressed: () => ShellOpen.reveal(task.outputPath),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.play_circle_outline, size: 18),
                          tooltip: s.qOpenFile,
                          onPressed: () => ShellOpen.path(task.outputPath),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                        ),
                      ],
                      if (task.status == TaskStatus.cancelled ||
                          task.status == TaskStatus.failed)
                        IconButton(
                          icon: Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: scheme.error,
                          ),
                          tooltip: s.isZh ? '移除任务' : 'Remove task',
                          onPressed: () =>
                              context.read<AppState>().removeTask(task.id),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                        ),
                      Icon(
                        sheet
                            ? Icons.open_in_new
                            : task.expanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 20,
                        color: scheme.outline,
                      ),
                    ],
                  ),
                  // 进度区：处理中/已暂停/已完成显示（等待与终态不占位）。
                  // 暂停也要显示：进度条冻结在暂停那一刻的位置，正是用户
                  // 判断「该不该继续」的依据。
                  if (task.status == TaskStatus.processing ||
                      task.status == TaskStatus.paused ||
                      task.status == TaskStatus.completed) ...[
                    const SizedBox(height: 10),
                    // 上层：整体进度（分段）。**只在流水线真的分多段时才画** ——
                    // 单节点任务下它和下面的当前步骤条是同一件事，两条一模一样的长条
                    // 并排只会让人以为是两个不同指标（用户反馈的「宽大又难读」）。
                    if ((task.pipelineCalls?.length ?? 1) > 1) ...[
                      _SegmentedProgressBar(
                        segments: task.pipelineCalls!.length,
                        callProgresses: task.callProgresses,
                        currentCallIndex: task.currentCallIndex,
                        // 8px：见 kQueueTrackHeight —— 不再是滑块的 16px 规格
                        height: kQueueTrackHeight,
                        done: task.status == TaskStatus.completed,
                        paused: task.status == TaskStatus.paused,
                      ),
                      const SizedBox(height: kQueueTrackGap),
                    ],
                    // 下层：当前步骤进度。完成态固定画满（后端可能没为最后一步
                    // 发过进度事件，callProgresses 停在 0 会显示成空条/不确定条）。
                    AppProgressBar(
                      height: kQueueTrackHeight,
                      // 暂停时必须是**确定值**：null 会走不确定（无限滚动）动画，
                      // 看起来像还在干活，与「已冻结」直接矛盾。
                      value: task.status == TaskStatus.completed
                          ? 1.0
                          : task.status == TaskStatus.paused
                          ? (task.callProgresses.isNotEmpty &&
                                    task.currentCallIndex <
                                        task.callProgresses.length
                                ? task.callProgresses[task.currentCallIndex]
                                : (task.progress / 100).clamp(0.0, 1.0))
                          : task.callProgresses.isNotEmpty &&
                                task.currentCallIndex <
                                    task.callProgresses.length
                          ? task.callProgresses[task.currentCallIndex]
                          : null,
                    ),
                    const SizedBox(height: 6),
                    // 速度与百分比同一行。速度为空时左侧留白会让这一行只剩一个孤零零的
                    // 百分比飘在右边，所以补上「步骤 i/n」——它恰好是用户在看进度时
                    // 最想知道、而折叠态里原本看不到的信息。
                    Row(
                      children: [
                        if (task.speed.isNotEmpty)
                          _chip(
                            Icons.speed,
                            _dashIfNa(task.speed, s.isZh),
                            scheme,
                          )
                        else if ((task.pipelineCalls?.length ?? 0) > 1)
                          _chip(
                            Icons.account_tree,
                            '${s.isZh ? '步骤' : 'Step'} ${task.currentCallIndex + 1}/${task.pipelineCalls!.length}',
                            scheme,
                          ),
                        const Spacer(),
                        Text(
                          '${task.progress.toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: kQueueFsValue,
                            fontWeight: FontWeight.w600,
                            color: clr,
                          ),
                        ),
                      ],
                    ),
                  ],
                  // 失败任务：折叠态也直接显示错误摘要，点开卡片可查看完整日志
                  if (task.status == TaskStatus.failed &&
                      task.error != null) ...[
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer.withAlpha(70),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 14,
                            color: scheme.error,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              task.error!,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.error,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (!sheet)
            AnimatedCrossFade(
              firstChild: const SizedBox(width: double.infinity),
              secondChild: _expanded(context, s, scheme),
              crossFadeState: task.expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 250),
            ),
        ],
      ),
    );
  }

  /// 任务是否已到终态（可长按移除记录）。
  bool get _isTerminal =>
      task.status == TaskStatus.completed ||
      task.status == TaskStatus.failed ||
      task.status == TaskStatus.cancelled;

  /// 暂停 / 继续按钮的入口：调用真实的进程冻结 / 解冻。
  ///
  /// 失败（当前没有可冻结的进程）时给出 toast，而不是把状态改成 paused ——
  /// 队列不允许出现「UI 显示已暂停、ffmpeg 还在跑」的假暂停。
  Future<void> _togglePause(BuildContext context) async {
    final state = context.read<AppState>();
    final s = AppStrings.of(state.config.language);
    final wasPaused = task.status == TaskStatus.paused;
    final ok = wasPaused
        ? await state.resumeTask(task.id)
        : await state.pauseTask(task.id);
    if (ok || !context.mounted) return;
    showToast(
      context,
      wasPaused
          ? (s.isZh ? '继续失败：任务进程已结束' : 'Resume failed: process is gone')
          : (s.isZh
                ? '当前无法暂停（没有可冻结的进程）'
                : 'Cannot pause: no freezable process'),
      type: ToastType.warning,
    );
  }

  /// 长按删除确认：只移除列表记录，不删除输出文件。
  void _confirmRemove(BuildContext context) {
    final s = AppStrings.of(context.read<AppState>().config.language);
    final scheme = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(
          s.isZh ? '移除任务记录' : 'Remove Task Record',
          style: TextStyle(color: scheme.onSurface, fontSize: 15),
        ),
        content: Text(
          s.isZh
              ? '从队列中移除「${task.filename}」？（不会删除输出文件）'
              : 'Remove "${task.filename}" from the queue? (Output file is kept)',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text(s.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () {
              Navigator.pop(dCtx);
              context.read<AppState>().removeTask(task.id);
            },
            child: Text(s.isZh ? '移除' : 'Remove'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════
  // 展开详情（2026-09-25 重排）
  //
  // 旧版式是「错误框 → 流水线 → 文件信息 → 技术参数 → 折叠的高级信息」竖直堆叠，
  // 全部用同一种标题（图标 + 13px 文字），区块间距 16/8/靠 Divider 混用，
  // 内嵌块圆角在 6/8/10 之间跳、底色 alpha 在 30/40/60/80 之间跳。
  // 新结构：
  //   ① 概览条（状态 + 进度 + 耗时/时长/速度）—— 点开卡片最先想知道的东西
  //   ② 错误面板（仅失败）
  //   ③ 处理流水线（时间轴：圆环进度 + 连接线 + 序号）
  //   ④ 文件信息（输入/输出，带打开与定位按钮）
  //   ⑤ 技术参数（FPS / 码率 / 大小 / 帧数，按卡片实际宽度算列数）
  //   ⑥ 命令与日志（可折叠，带复制）
  // ═══════════════════════════════════════════

  Widget _expanded(
    BuildContext ctx,
    AppStrings s,
    ColorScheme scheme, {
    bool mobile = false,
  }) {
    final zh = s.language == 'zh';
    final calls = task.pipelineCalls;
    final hasPipeline = calls != null && calls.isNotEmpty;
    final hasLogs =
        task.command != null || task.logLines.isNotEmpty || task.error != null;

    // 移动端（底部详情面板）走另一套排布：顶部是「运行节点视口」，
    // 下面把原有全部字段拆进「基本信息 / 高级」两栏，一个字段都不少。
    // 桌面端保持原来的单列内联展开。
    if (mobile) {
      return _expandedMobile(
        s,
        scheme,
        calls: calls ?? const <BackendCall>[],
        hasPipeline: hasPipeline,
        hasLogs: hasLogs,
      );
    }

    return Padding(
      // 12 与卡片自身的内边距对齐。旧实现外层 12、展开区内层 16，
      // 展开后正文比标题右缩进 4px，整块看着是「歪的」。
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 20),

          // ① 概览
          _SummaryBar(task: task, scheme: scheme, s: s),

          // ② 错误
          if (task.status == TaskStatus.failed && task.error != null) ...[
            const SizedBox(height: kQueuePanelGap),
            _ErrorPanel(message: task.error!, scheme: scheme, s: s),
          ],

          // ③ 流水线
          if (hasPipeline) ...[
            const SizedBox(height: kQueuePanelGap),
            _SectionTitle(
              icon: Icons.account_tree,
              title: s.qPipeline,
              scheme: scheme,
              trailing: _CountBadge(
                text: '${calls.length} ${s.qSteps}',
                scheme: scheme,
              ),
            ),
            const SizedBox(height: 8),
            _PanelBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _NodeTimeline(
                    calls: calls,
                    progresses: task.callProgresses,
                    currentIndex: task.currentCallIndex,
                    status: task.status,
                    zh: zh,
                  ),
                  const SizedBox(height: 10),
                  _PipelineLegend(scheme: scheme, s: s),
                ],
              ),
            ),
          ],

          // ④ 文件信息
          const SizedBox(height: kQueuePanelGap),
          _SectionTitle(
            icon: Icons.folder_outlined,
            title: s.qFileInfo,
            scheme: scheme,
          ),
          const SizedBox(height: 8),
          _FileInfoPanel(task: task, s: s, scheme: scheme),

          // ⑤ 技术参数
          const SizedBox(height: kQueuePanelGap),
          _SectionTitle(icon: Icons.speed, title: s.qTechStats, scheme: scheme),
          const SizedBox(height: 8),
          _StatsGrid(
            stats: [
              (s.qFps, _dashIfNa(task.fps, s.isZh), Icons.videocam_outlined),
              (s.qBitrate, _dashIfNa(task.bitrate, s.isZh), Icons.trending_up),
              (
                s.qSize,
                task.outputSize == null ? s.qNone : task.outputSizeStr,
                Icons.storage,
              ),
              (
                s.qFrames,
                task.frame > 0 ? '${task.frame}' : s.qNone,
                Icons.filter_frames,
              ),
            ],
            scheme: scheme,
          ),

          // ⑥ 命令与日志
          if (hasLogs) ...[
            const SizedBox(height: kQueuePanelGap),
            _LogsPanel(
              command: task.command,
              logLines: task.logLines,
              error: task.error,
              scheme: scheme,
              s: s,
            ),
          ],
        ],
      ),
    );
  }

  /// 移动端详情：顶部「运行节点视口」+ 基本信息 / 高级 两栏。
  ///
  /// 字段与桌面端完全一致（概览、错误、文件信息、技术参数、流水线、命令/日志），
  /// 只是重新分组：左栏 = 基本信息（概览 / 文件 / 技术参数），
  /// 右栏 = 高级（流水线全量节点 / 命令与日志）。
  Widget _expandedMobile(
    AppStrings s,
    ColorScheme scheme, {
    required List<BackendCall> calls,
    required bool hasPipeline,
    required bool hasLogs,
  }) {
    final zh = s.isZh;
    final stats = <(String, String, IconData)>[
      (s.qFps, _dashIfNa(task.fps, zh), Icons.videocam_outlined),
      (s.qBitrate, _dashIfNa(task.bitrate, zh), Icons.trending_up),
      (s.qSize, task.outputSize == null ? s.qNone : task.outputSizeStr, Icons.storage),
      (s.qFrames, task.frame > 0 ? '${task.frame}' : s.qNone, Icons.filter_frames),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 4),
          // ① 运行节点视口：类似地图，放大到正在处理的节点，
          //    且视野必须包含所有运行中的节点（见 RunningNodeViewport）。
          RunningNodeViewport(
            calls: calls,
            progresses: task.callProgresses,
            currentIndex: task.currentCallIndex,
            status: task.status,
            progress: task.progress,
            zh: zh,
          ),
          // ② 错误（仅失败）
          if (task.status == TaskStatus.failed && task.error != null) ...[
            const SizedBox(height: kQueuePanelGap),
            _ErrorPanel(message: task.error!, scheme: scheme, s: s),
          ],
          const SizedBox(height: kQueuePanelGap),
          // ③ 两栏：基本信息 / 高级
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _detailColumn(
                  title: zh ? '基本信息' : 'Basic info',
                  icon: Icons.info_outline,
                  scheme: scheme,
                  children: [
                    _SummaryBar(task: task, scheme: scheme, s: s),
                    const SizedBox(height: 10),
                    _SectionTitle(
                      icon: Icons.folder_outlined,
                      title: s.qFileInfo,
                      scheme: scheme,
                    ),
                    const SizedBox(height: 6),
                    _FileInfoPanel(task: task, s: s, scheme: scheme),
                    const SizedBox(height: 10),
                    _SectionTitle(
                      icon: Icons.speed,
                      title: s.qTechStats,
                      scheme: scheme,
                    ),
                    const SizedBox(height: 6),
                    _StatsGrid(stats: stats, scheme: scheme),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _detailColumn(
                  title: zh ? '高级' : 'Advanced',
                  icon: Icons.tune,
                  scheme: scheme,
                  children: [
                    if (hasPipeline) ...[
                      _SectionTitle(
                        icon: Icons.account_tree,
                        title: s.qPipeline,
                        scheme: scheme,
                        trailing: _CountBadge(
                          text: '${calls.length} ${s.qSteps}',
                          scheme: scheme,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _PanelBox(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _NodeTimeline(
                              calls: calls,
                              progresses: task.callProgresses,
                              currentIndex: task.currentCallIndex,
                              status: task.status,
                              zh: zh,
                            ),
                            const SizedBox(height: 8),
                            _PipelineLegend(scheme: scheme, s: s),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (hasLogs)
                      _LogsPanel(
                        command: task.command,
                        logLines: task.logLines,
                        error: task.error,
                        scheme: scheme,
                        s: s,
                      )
                    else
                      _PanelBox(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          zh ? '暂无命令或日志' : 'No command or logs',
                          style: TextStyle(
                            fontSize: kQueueFsLabel,
                            color: scheme.outline,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 两栏布局里的单栏：栏标题 + 内容（宽度由外层 Expanded 决定）。
  Widget _detailColumn({
    required String title,
    required IconData icon,
    required ColorScheme scheme,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: scheme.primary),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: kQueueFsSection,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }

  Widget _chip(IconData icon, String text, ColorScheme scheme) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 12, color: scheme.outline),
      const SizedBox(width: 3),
      Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        // 11：这个 chip 总是紧挨着 11px 的状态文字/数值出现，10 会明显小一号
        style: TextStyle(fontSize: kQueueFsLabel, color: scheme.outline),
      ),
    ],
  );

  IconData get _statusIcon => switch (task.status) {
    TaskStatus.pending => Icons.schedule,
    TaskStatus.processing => Icons.sync,
    TaskStatus.paused => Icons.pause_circle_outline,
    TaskStatus.completed => Icons.check_circle,
    TaskStatus.failed => Icons.error,
    TaskStatus.cancelled => Icons.cancel,
  };

  // 语义色统一走 AppSemantic：
  // - 原先 `completed => Colors.green`、`cancelled => Colors.orange` 是写死的
  //   Material 原色，换主题色/开 Monet 动态取色时不会跟着变；
  // - 原先 `processing => sc.primary`（品牌色）与本文件里另外三处「处理中 = 琥珀」
  //   （_PipelineLegend 圆点、_SegmentedProgressBar 段、_NodeCircle 圈）自相矛盾，
  //   同一个状态在队列卡里出现两种颜色。这里统一到 warning，
  //   与图例/分段进度条/节点圈完全一致；处理中与已取消同为 warning 层级，
  //   靠图标（sync / cancel）与文案区分。
  Color _statusColor(ColorScheme sc) => switch (task.status) {
    TaskStatus.pending => sc.sem.neutral,
    TaskStatus.processing => sc.sem.warning,
    // 暂停用「信息」色而非警告色：它不是异常，只是用户主动摁下的暂停键。
    TaskStatus.paused => sc.sem.info,
    TaskStatus.completed => sc.sem.success,
    TaskStatus.failed => sc.sem.danger,
    TaskStatus.cancelled => sc.sem.warning,
  };
}

/// Opens the live queue details without changing desktop expansion state.
Future<void> showTaskDetailsSheet(BuildContext context, String taskId) {
  final state = context.read<AppState>();
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    sheetAnimationStyle: reducedMotion ? AnimationStyle.noAnimation : null,
    builder: (_) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: FractionallySizedBox(
        heightFactor: 0.9,
        child: Selector<AppState, (int, String)>(
          selector: (_, state) => (state.tasksVersion, state.config.language),
          builder: (context, _, _) {
            final tasks = context.read<AppState>().tasks;
            final task = tasks.where((task) => task.id == taskId).firstOrNull;
            final zh = context.read<AppState>().config.language == 'zh';
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          task?.filename ?? (zh ? '任务已移除' : 'Task removed'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: zh ? '关闭详情' : 'Close details',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                if (task != null)
                  Expanded(
                    child: SingleChildScrollView(
                      key: ValueKey('task-details-${task.id}'),
                      child: TaskDetails(task: task),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

/// The complete details shared by desktop cards and the mobile sheet.
class TaskDetails extends StatelessWidget {
  const TaskDetails({super.key, required this.task, this.mobile});

  final TaskInfo task;

  /// 强制移动端排布（顶部运行节点视口 + 基本信息/高级两栏）。
  /// null = 自动判定：移动平台或窄窗口（< 700dp）走两栏，桌面宽窗口保持单列。
  /// 显式参数让 widget 测试不必伪造平台。
  final bool? mobile;

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppState, String>(
      (state) => state.config.language,
    );
    final useMobile =
        mobile ??
        (isMobilePlatform || MediaQuery.sizeOf(context).width < 700);
    return TaskCard(task: task)._expanded(
      context,
      AppStrings.of(language),
      Theme.of(context).colorScheme,
      mobile: useMobile,
    );
  }
}

/// 详情里所有内嵌块的统一容器。
///
/// 改造前四个区块各写一遍 decoration：圆角 6 / 8 / 10 三种、底色
/// `surfaceContainerHighest.withAlpha(30 / 40 / 60 / 80)` 四种、描边有的有一半没有。
/// 统一成「10 圆角 + 40 alpha 底 + 70 alpha 细描边」一套语言。
class _PanelBox extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;

  const _PanelBox({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.color,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color:
            color ?? AppNeutralSurface.card(cs.brightness).withAlpha(40),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: borderColor ?? cs.outlineVariant.withAlpha(70),
        ),
      ),
      child: child,
    );
  }
}

/// 章节标题（图标 + 标题 + 右侧可选徽标）。
class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final ColorScheme scheme;
  final Widget? trailing;

  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.scheme,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: kQueueFsLevelTitle,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// 区块标题字号（13）。与 [_SectionTitle] 配套，留成常量方便统一调。
const double kQueueFsLevelTitle = kQueueFsSection;

/// 小徽标：如「12 步骤」。
class _CountBadge extends StatelessWidget {
  final String text;
  final ColorScheme scheme;

  const _CountBadge({required this.text, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withAlpha(18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }
}

/// 概览条：状态 + 进度百分比 + 一行关键指标（耗时 / 总时长 / 速度）。
///
/// 旧版式里「耗时」根本没展示（`elapsed` 字段一直有值但没人用），
/// 「总时长」「大小」埋在技术参数网格里和 FPS、码率同级 —— 用户点开卡片最想知道的
/// 就是「跑了多久、要多长时间」，全部提上来。
class _SummaryBar extends StatelessWidget {
  final TaskInfo task;
  final ColorScheme scheme;
  final AppStrings s;

  const _SummaryBar({
    required this.task,
    required this.scheme,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    final zh = s.isZh;
    final color = switch (task.status) {
      TaskStatus.pending => scheme.sem.neutral,
      TaskStatus.processing => scheme.sem.warning,
      TaskStatus.paused => scheme.sem.info,
      TaskStatus.completed => scheme.sem.success,
      TaskStatus.failed => scheme.sem.danger,
      TaskStatus.cancelled => scheme.sem.warning,
    };
    final icon = switch (task.status) {
      TaskStatus.pending => Icons.schedule,
      TaskStatus.processing => Icons.sync,
      TaskStatus.paused => Icons.pause_circle_outline,
      TaskStatus.completed => Icons.check_circle,
      TaskStatus.failed => Icons.error,
      TaskStatus.cancelled => Icons.cancel,
    };
    final label = switch (task.status) {
      TaskStatus.pending => s.pending,
      TaskStatus.processing => s.processing,
      TaskStatus.paused => taskPausedLabel(zh),
      TaskStatus.completed => s.completed,
      TaskStatus.failed => s.failed,
      TaskStatus.cancelled => s.cancelled,
    };
    final String sub = switch (task.status) {
      TaskStatus.pending => zh ? '等待开始处理' : 'Waiting to start',
      TaskStatus.processing =>
        '${s.remaining} ${_dashIfNa(task.remaining, zh)}',
      TaskStatus.paused => zh
          ? '进程已冻结（CPU 已释放），进度与已编码数据均保留'
          : 'Process frozen (CPU released); progress is preserved',
      TaskStatus.completed =>
        zh ? '输出已写入下方路径' : 'Output written to the path below',
      TaskStatus.failed =>
        zh ? '任务中断，错误详情见下方' : 'Task aborted — see error below',
      TaskStatus.cancelled => zh ? '已被手动取消' : 'Cancelled manually',
    };

    final metrics = <Widget>[];
    if (task.elapsed.trim().isNotEmpty) {
      metrics.add(
        _metric(Icons.timer_outlined, s.qElapsed, _dashIfNa(task.elapsed, zh)),
      );
    }
    if (task.duration != null && task.duration! > 0) {
      metrics.add(
        _metric(Icons.movie_outlined, s.qDuration, _fmtSeconds(task.duration!)),
      );
    }
    if (task.speed.trim().isNotEmpty) {
      metrics.add(
        _metric(Icons.speed, zh ? '速度' : 'Speed', _dashIfNa(task.speed, zh)),
      );
    }

    final showPercent = task.status != TaskStatus.pending;

    return _PanelBox(
      color: color.withAlpha(16),
      borderColor: color.withAlpha(56),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
              if (showPercent)
                Text(
                  '${task.progress.toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            sub,
            style: TextStyle(
              fontSize: kQueueFsLabel,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (metrics.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 14, runSpacing: 6, children: metrics),
          ],
        ],
      ),
    );
  }

  Widget _metric(IconData icon, String label, String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 12, color: scheme.outline),
      const SizedBox(width: 4),
      Text(
        '$label ',
        style: TextStyle(fontSize: kQueueFsLabel, color: scheme.outline),
      ),
      Text(
        value,
        style: TextStyle(
          fontSize: kQueueFsValue,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    ],
  );
}

/// 失败任务的全量错误面板（原「卡片展开区顶部的红框」，抽出成组件）。
class _ErrorPanel extends StatelessWidget {
  final String message;
  final ColorScheme scheme;
  final AppStrings s;

  const _ErrorPanel({
    required this.message,
    required this.scheme,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return _PanelBox(
      color: scheme.errorContainer.withAlpha(60),
      borderColor: scheme.error.withAlpha(80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: scheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.qErrorDetails,
                  style: TextStyle(
                    fontSize: kQueueFsSection,
                    fontWeight: FontWeight.w600,
                    color: scheme.error,
                  ),
                ),
              ),
              _CopyButton(text: message, label: s.qCopy, scheme: scheme),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            message,
            style: TextStyle(
              fontSize: kQueueFsValue,
              color: scheme.onErrorContainer,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 文件信息面板：输入 / 输出各一行，行首是图标 + 标签 + 右侧快捷操作。
///
/// 旧实现是「标签 10px + 路径 11px」两段各写一遍（改一处必漏另一处），而且
/// 路径用的是 `SelectableText(maxLines: 2)` —— **没给 overflow**，超长路径会被硬裁
/// 在中途（出现半个字）。现在：标签与图标对齐同一档、路径超出显示省略号、
/// 完整值挂在 Tooltip 上，并在标签行右侧给出「打开文件夹 / 打开文件」。
class _FileInfoPanel extends StatelessWidget {
  final TaskInfo task;
  final AppStrings s;
  final ColorScheme scheme;

  const _FileInfoPanel({
    required this.task,
    required this.s,
    required this.scheme,
  });

  Widget _pathRow(
    IconData icon,
    String label,
    String path, {
    List<Widget> actions = const [],
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, size: 13, color: scheme.outline),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: kQueueFsLabel,
              color: scheme.outline,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          ...actions,
        ],
      ),
      const SizedBox(height: 3),
      Tooltip(
        message: path,
        child: Text(
          path,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: kQueueFsValue,
            height: 1.4,
            color: scheme.onSurface,
          ),
        ),
      ),
    ],
  );

  Widget _action(
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool enabled = true,
  }) => IconButton(
    icon: Icon(icon, size: 16),
    tooltip: tooltip,
    color: scheme.primary,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    onPressed: enabled ? onTap : null,
  );

  @override
  Widget build(BuildContext context) {
    final done = task.status == TaskStatus.completed;
    return _PanelBox(
      // 一个 SelectionArea 包住两条路径，替代原先两个 SelectableText：
      // 少一层 widget，而且两条路径可以跨行一起选中复制。
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pathRow(
              Icons.login,
              s.qInput,
              task.inputPath,
              actions: [
                _action(
                  Icons.folder_open,
                  s.qOpenFolder,
                  () => ShellOpen.reveal(task.inputPath),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Divider(height: 1, color: scheme.outlineVariant.withAlpha(60)),
            const SizedBox(height: 10),
            _pathRow(
              Icons.logout,
              s.qOutput,
              task.outputPath,
              actions: [
                _action(
                  Icons.folder_open,
                  s.qOpenFolder,
                  () => ShellOpen.reveal(task.outputPath),
                  enabled: done,
                ),
                _action(
                  Icons.open_in_new,
                  s.qOpenFile,
                  () => ShellOpen.path(task.outputPath),
                  enabled: done,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 技术参数网格。
///
/// 列数**按卡片实际宽度**算，不再用 `MediaQuery.sizeOf(context).size.width`：
/// 那是整屏宽度，窗口侧栏 / 分屏下卡片只有 300~400px 宽却仍被判成「桌面 → 3 列」，
/// 每列只剩 100px，值全被省略号吃掉（旧实现的实际 bug）。
class _StatsGrid extends StatelessWidget {
  final List<(String, String, IconData)> stats;
  final ColorScheme scheme;

  const _StatsGrid({required this.stats, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final cols = w < 300 ? 1 : (w < 520 ? 2 : 4);
        const gap = 8.0;
        // -1：Wrap 是按浮点累加判断换行的，正好等于 maxWidth 时会因精度误差多换一行
        final itemW = math.max(80.0, (w - gap * (cols - 1)) / cols - 1);
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final (label, value, icon) in stats)
              SizedBox(
                width: itemW,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: AppNeutralSurface.card(
                      scheme.brightness,
                    ).withAlpha(40),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: scheme.outlineVariant.withAlpha(70),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 15, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: kQueueFsLabel,
                                color: scheme.outline,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              value.isEmpty ? '—' : value,
                              style: TextStyle(
                                fontSize: kQueueFsValue,
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
              ),
          ],
        );
      },
    );
  }
}

/// 流水线颜色图例
class _PipelineLegend extends StatelessWidget {
  final ColorScheme scheme;
  final AppStrings s;

  const _PipelineLegend({required this.scheme, required this.s});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        _LegendItem(color: scheme.sem.neutral, label: s.qLegendPending),
        _LegendItem(color: scheme.sem.warning, label: s.qLegendProcessing),
        // 暂停用信息色（与卡片状态色/视口节点色一致）
        _LegendItem(color: scheme.sem.info, label: taskPausedLabel(s.isZh)),
        _LegendItem(color: scheme.sem.success, label: s.qLegendCompleted),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withAlpha(40),
            border: Border.all(color: color, width: 1.5),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: color)),
      ],
    );
  }
}

/// 命令 / 日志区块（可折叠）。
///
/// 折叠态标题行右侧显示「N 行」与内容类型徽标，展开后每个代码块都带复制按钮 ——
/// 旧实现只能全选整段 `SelectableText` 再手动复制，而日志区是独立滚动的，
/// 在手机上全选一段 200 行的日志几乎做不到。
class _LogsPanel extends StatefulWidget {
  final List<String>? command;
  final List<String> logLines;
  final String? error;
  final ColorScheme scheme;
  final AppStrings s;

  const _LogsPanel({
    this.command,
    required this.logLines,
    this.error,
    required this.scheme,
    required this.s,
  });

  @override
  State<_LogsPanel> createState() => _LogsPanelState();
}

class _LogsPanelState extends State<_LogsPanel> {
  // 失败任务自动展开：用户点开卡片就能直接看到完整 ffmpeg 日志，
  // 不必再手动展开第二级「高级信息」。
  late bool _expanded = widget.error != null;

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final commandText = (widget.command ?? const <String>[]).join(' ').trim();
    final logText = widget.logLines.join('\n').trim();
    final hasCommand = commandText.isNotEmpty;
    final hasLogs = logText.isNotEmpty;

    return _PanelBox(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 16, color: scheme.outline),
                  const SizedBox(width: 6),
                  // 移动端两栏里这一行只有 ~139dp：标题必须可收缩（省略号），
                  // 否则 图标+标题+行数徽标+箭头 会横向溢出（实测 360dp 溢出 4.8px）。
                  Flexible(
                    child: Text(
                      widget.s.qAdvanced,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: kQueueFsSection,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (hasLogs)
                    _CountBadge(
                      text: '${widget.logLines.length} ${widget.s.qLines}',
                      scheme: scheme,
                    ),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: scheme.outline,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CodeBlock(
                    icon: Icons.terminal,
                    title: widget.s.qCommand,
                    content: commandText,
                    emptyHint: widget.s.qNoCommand,
                    scheme: scheme,
                    copyLabel: widget.s.qCopy,
                  ),
                  const SizedBox(height: 10),
                  _CodeBlock(
                    icon: Icons.article_outlined,
                    title: widget.s.qLogs,
                    content: logText,
                    emptyHint: widget.s.qNoLogs,
                    scheme: scheme,
                    copyLabel: widget.s.qCopy,
                    maxHeight: 200,
                  ),
                  // 错误摘要已在上面单独成块（_ErrorPanel），这里仅在无命令/无日志时兜底
                  if (widget.error != null && !hasCommand && !hasLogs) ...[
                    const SizedBox(height: 10),
                    _CodeBlock(
                      icon: Icons.error_outline,
                      title: widget.s.qError,
                      content: widget.error!,
                      emptyHint: widget.s.qNone,
                      scheme: scheme,
                      copyLabel: widget.s.qCopy,
                      isError: true,
                    ),
                  ],
                ],
              ),
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}

/// 等宽代码块（命令 / 日志 / 错误兜底）：标题行 + 可选复制按钮 + 可滚动正文。
class _CodeBlock extends StatelessWidget {
  final IconData icon;
  final String title;
  final String content;
  final String emptyHint;
  final String copyLabel;
  final ColorScheme scheme;
  final bool isError;
  final double? maxHeight;

  const _CodeBlock({
    required this.icon,
    required this.title,
    required this.content,
    required this.emptyHint,
    required this.copyLabel,
    required this.scheme,
    this.isError = false,
    this.maxHeight,
  });

  @override
  Widget build(BuildContext context) {
    final empty = content.isEmpty;
    final accent = isError ? scheme.error : scheme.outline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: accent),
            const SizedBox(width: 5),
            Text(
              title,
              style: TextStyle(
                fontSize: kQueueFsLabel,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
            const Spacer(),
            if (!empty)
              _CopyButton(text: content, label: copyLabel, scheme: scheme),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          constraints: maxHeight != null
              ? BoxConstraints(maxHeight: maxHeight!)
              : null,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isError
                ? scheme.errorContainer.withAlpha(40)
                : AppNeutralSurface.card(scheme.brightness).withAlpha(60),
            borderRadius: BorderRadius.circular(8),
          ),
          child: empty
              ? Text(
                  emptyHint,
                  style: TextStyle(
                    fontSize: kQueueFsLabel,
                    color: scheme.outline,
                  ),
                )
              : SingleChildScrollView(
                  child: SelectableText(
                    content,
                    style: TextStyle(
                      fontFamily: AppTheme.monoFont,
                      // 11：命令 / 日志是这张卡里最需要逐字读的内容，
                      // 比周围的标签还小一号（10）说不过去。
                      fontSize: kQueueFsLabel,
                      color: isError ? scheme.error : scheme.onSurface,
                      height: 1.5,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// 复制到剪贴板 + toast 反馈。
class _CopyButton extends StatelessWidget {
  final String text;
  final String label;
  final ColorScheme scheme;

  const _CopyButton({
    required this.text,
    required this.label,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(
      context.select<AppState, String>((st) => st.config.language),
    );
    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () {
        Clipboard.setData(ClipboardData(text: text));
        showToast(context, s.qCopied, type: ToastType.success);
      },
      icon: const Icon(Icons.copy_all, size: 13),
      label: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}

/// 分段进度条：上层整体进度，每段代表一个节点。
///
/// 外观与全应用滑块 / 进度条统一（胶囊 + 玻璃留空）：整条轨道底下垫**一层**
/// [AppTrackGlass]（不是每段一个 —— 那会为每段建一个 BackdropFilter），
/// 段与段的缝隙正好露出底下那层玻璃；每段的已填充部分是同色胶囊。
class _SegmentedProgressBar extends StatelessWidget {
  final int segments;
  final List<double> callProgresses;
  final int currentCallIndex;
  final double height;

  /// 任务已完成：所有段一律画满 + success 色。
  /// 后端只在「步骤开始」时写 callProgresses，最后一步若没有进度流事件
  /// （快速步骤 / 清理步骤），完成时该段会停在 0 —— 用户反馈的
  /// 「处理完成了但进度条没显示完成」就是这条缝。
  final bool done;

  /// 任务被暂停：未完成段用 info 色而不是「正在跑」的 warning，
  /// 让分段条和卡片状态色说的是同一件事。
  final bool paused;

  const _SegmentedProgressBar({
    required this.segments,
    required this.callProgresses,
    required this.currentCallIndex,
    required this.height,
    this.done = false,
    this.paused = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(height / 2);
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(child: AppTrackGlass(height: height)),
        ),
        Row(
          children: [
            for (int i = 0; i < segments; i++) ...[
              Expanded(
                child: Container(
                  height: height,
                  margin: EdgeInsets.only(right: i < segments - 1 ? 2 : 0),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: done
                        ? 1.0
                        : i < callProgresses.length
                        ? callProgresses[i].clamp(0.0, 1.0)
                        : 0.0,
                    child: Container(
                      decoration: BoxDecoration(
                        // 关键修复：callProgresses 长度可能 < segments（task 刚创建或 pipelineCalls 还没展开），
                        // 直接 callProgresses[i] 会抛 RangeError 把整张 TaskCard 渲染挂掉 → 灰屏。
                        // 越界时按 0.0 处理（pending 灰段）。
                        //
                        // 配色与 _PipelineLegend / _statusColor 完全对齐：未开始 = neutral、
                        // 进行中 = warning、已完成 = success。原先非当前段的兜底色写成
                        // scheme.primary（品牌色），与图例里的「处理中 = 琥珀」不一致。
                        color: done
                            ? scheme.sem.success
                            : i < callProgresses.length
                            ? (i == currentCallIndex && callProgresses[i] < 1.0
                                  ? (paused
                                        ? scheme.sem.info
                                        : scheme.sem.warning)
                                  : callProgresses[i] >= 1.0
                                  ? scheme.sem.success
                                  : (paused
                                        ? scheme.sem.info
                                        : scheme.sem.warning))
                            : scheme.sem.neutral,
                        // 两端全圆角：与滑块/进度条同一种胶囊语言
                        borderRadius: radius,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// 详情顶部「运行节点视口」。
///
/// 交互隐喻来自地图（用户草图：「类似地图：放大至正在处理节点，视野须包括所有
/// 运行节点」）：
///   · 只有一个运行节点时 → 放大（最多 1.25×）并居中到它；
///   · 多个节点同时运行（进度在 0~1 之间 / 当前节点）→ 自动缩小，保证
///     **所有运行节点** 都落在视野内；
///   · 节点很多时按比例继续缩小（不裁剪活动节点），非活动节点自然移出视野。
///
/// 每个节点下方是一条**动态进度条**，随 callProgresses 实时变化；暂停时冻结在
/// 暂停那一刻。视口本身不做常驻动画（队列里可能同时有多张详情），
/// 只在数据变化时重绘。
class RunningNodeViewport extends StatelessWidget {
  const RunningNodeViewport({
    super.key,
    required this.calls,
    required this.progresses,
    required this.currentIndex,
    required this.status,
    this.progress = 0,
    this.zh = true,
    this.height = 104,
  });

  /// 任务的流水线节点；为空表示单步任务（用一个合成节点 + 整体进度展示）。
  final List<BackendCall> calls;
  final List<double> progresses;
  final int currentIndex;
  final TaskStatus status;

  /// 单步 / 非流水线任务的整体进度（0~100）。
  final double progress;
  final bool zh;
  final double height;

  /// 世界坐标：相邻节点中心距 / 节点直径。缩放只作用在这两个量上。
  static const double _worldStep = 82;
  static const double _worldNode = 46;
  static const double _maxScale = 1.25;
  static const double _minScale = 0.12;

  bool get _synthetic => calls.isEmpty;

  double _progressAt(int i) {
    if (_synthetic) return (progress / 100).clamp(0.0, 1.0);
    if (i < progresses.length) return progresses[i].clamp(0.0, 1.0);
    return 0.0;
  }

  /// 需要收进视野的节点下标（升序）。
  List<int> get activeIndices {
    if (calls.isEmpty) return const [0];
    final cur = currentIndex.clamp(0, calls.length - 1);
    final running = <int>[];
    for (int i = 0; i < calls.length; i++) {
      final p = i < progresses.length ? progresses[i] : 0.0;
      if (p > 0 && p < 1) running.add(i);
    }
    if ((status == TaskStatus.processing || status == TaskStatus.paused) &&
        !running.contains(cur)) {
      running.add(cur);
    }
    if (running.isEmpty) {
      // 已完成：所有节点都算「可见」；未开始/已取消：只看当前节点。
      if (status == TaskStatus.completed) {
        return [for (int i = 0; i < calls.length; i++) i];
      }
      return [cur];
    }
    running.sort();
    return running;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = activeIndices;
    final count = _synthetic ? 1 : calls.length;
    final cur = _synthetic ? 0 : currentIndex.clamp(0, count - 1);
    final first = active.first;
    final last = active.last;
    return _PanelBox(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.radar, size: 14, color: scheme.sem.info),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  zh ? '运行节点' : 'Running nodes',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: kQueueFsSection,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (status == TaskStatus.paused) ...[
                Icon(
                  Icons.pause_circle_outline,
                  size: 13,
                  color: scheme.sem.info,
                ),
                const SizedBox(width: 3),
                Text(
                  taskPausedLabel(zh),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: scheme.sem.info,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              _CountBadge(text: '${cur + 1}/$count', scheme: scheme),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final available = math.max(32.0, constraints.maxWidth);
                // 先把所有活动节点收进视野（比例 = 视野宽 / 活动跨度），
                // 再对「放大」设上限，避免单个节点被放大到失真。
                final spanWorld = (last - first) * _worldStep + _worldNode;
                final scale = (available / spanWorld).clamp(
                  _minScale,
                  _maxScale,
                );
                final nodeSize = math.max(_worldNode * scale, 10.0);
                final step = _worldStep * scale;
                final contentWidth = (count - 1) * step + nodeSize;
                // 活动节点整体的中心（内容坐标系）。视口把这一点映射到视野中心，
                // 再对左右边界做钳制：内容比视野窄时整体居中，比视野宽时
                // 不允许把活动节点推出视野。
                final activeCenter = ((first + last) / 2) * step + nodeSize / 2;
                final double leftOrigin;
                if (contentWidth <= available) {
                  leftOrigin = -(available - contentWidth) / 2;
                } else {
                  leftOrigin = (activeCenter - available / 2).clamp(
                    0.0,
                    contentWidth - available,
                  );
                }
                return ClipRect(
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      for (int i = 0; i < count; i++)
                        Positioned(
                          // 内容坐标 i*step 减去视野左边界在内容里的位置
                          left: i * step - leftOrigin,
                          top: 0,
                          width: nodeSize,
                          child: _ViewportNode(
                            key: ValueKey('viewport-node-$i'),
                            call: _synthetic
                                ? BackendCall(action: '', params: const {})
                                : calls[i],
                            progress: _progressAt(i),
                            isCurrent: i == cur,
                            status: status,
                            size: nodeSize,
                            index: i,
                            zh: zh,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 视口里的单个节点：圆环（弧长 = 该节点进度）+ 动态进度条 + 序号。
class _ViewportNode extends StatelessWidget {
  final BackendCall call;
  final double progress;
  final bool isCurrent;
  final TaskStatus status;
  final double size;
  final int index;
  final bool zh;

  const _ViewportNode({
    super.key,
    required this.call,
    required this.progress,
    required this.isCurrent,
    required this.status,
    required this.size,
    required this.index,
    this.zh = true,
  });

  Color _color(ColorScheme scheme) {
    if (status == TaskStatus.completed) return scheme.sem.success;
    if (progress >= 1.0) return scheme.sem.success;
    if (status == TaskStatus.paused && isCurrent) return scheme.sem.info;
    if (status == TaskStatus.cancelled) return scheme.sem.warning;
    if (isCurrent && progress > 0.0 && progress < 1.0) {
      return scheme.sem.warning;
    }
    if (status == TaskStatus.processing && isCurrent) {
      return scheme.sem.warning;
    }
    return scheme.sem.neutral;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _color(scheme);
    final label = taskActionLabel(call.action, zh);
    final abbr = taskActionAbbr(call.action, zh);
    final running = status == TaskStatus.processing || status == TaskStatus.paused;
    return Tooltip(
      message:
          '$label\n${zh ? '进度' : 'Progress'}: ${(progress * 100).toStringAsFixed(0)}%',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _NodeRingPainter(
                color: color,
                progress: progress.clamp(0.0, 1.0),
                emphasise: isCurrent && running,
              ),
              child: Center(
                child: Text(
                  abbr,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontSize: (size * 0.28).clamp(6.0, 16.0),
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          // 动态进度条：值直接来自 callProgresses（暂停时冻结原位）。
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: color.withAlpha(30)),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: ColoredBox(color: color),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${index + 1}',
            maxLines: 1,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: (size * 0.24).clamp(6.0, 11.0),
              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
              color: isCurrent ? color : scheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 节点时间轴：横向滚动展示节点圆环（含进度弧）+ 连接线 + 序号。
///
/// 取代旧的 [_NodeMiniCanvas]（一律实心小圆 + 缩写字，看不出「跑到哪了」）：
/// 每个圆环按该节点的 callProgress 画弧，圆与圆之间用连接线把「上一步已完成」
/// 表达出来，当前节点加粗描边。
class _NodeTimeline extends StatelessWidget {
  final List<BackendCall> calls;
  final List<double> progresses;
  final int currentIndex;
  final TaskStatus status;
  final bool zh;

  const _NodeTimeline({
    required this.calls,
    required this.progresses,
    required this.currentIndex,
    required this.status,
    this.zh = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final size = compact ? 38.0 : 46.0;
    final linkW = compact ? 20.0 : 30.0;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < calls.length; i++) ...[
            _NodeDot(
              call: calls[i],
              progress: i < progresses.length ? progresses[i] : 0.0,
              isCurrent: i == currentIndex,
              status: status,
              size: size,
              index: i,
              zh: zh,
            ),
            if (i < calls.length - 1)
              _NodeLink(
                width: linkW,
                // 连接线对齐圆心：圆本身在 Column 顶部，直接给 top padding
                topInset: size / 2,
                done: (i < progresses.length ? progresses[i] : 0.0) >= 1.0,
                scheme: scheme,
              ),
          ],
        ],
      ),
    );
  }
}

class _NodeLink extends StatelessWidget {
  final double width;
  final double topInset;
  final bool done;
  final ColorScheme scheme;

  const _NodeLink({
    required this.width,
    required this.topInset,
    required this.done,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: topInset - 1, left: 2, right: 2),
      child: Container(
        width: width,
        height: 2,
        decoration: BoxDecoration(
          color: done
              ? scheme.sem.success.withAlpha(160)
              : scheme.outlineVariant.withAlpha(150),
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

/// 节点圆环：底圆 + 进度弧 + 缩写文字 + 序号。
class _NodeDot extends StatelessWidget {
  final BackendCall call;
  final double progress;
  final bool isCurrent;
  final TaskStatus status;
  final double size;
  final int index;
  final bool zh;

  const _NodeDot({
    required this.call,
    required this.progress,
    required this.isCurrent,
    required this.status,
    required this.size,
    required this.index,
    this.zh = true,
  });

  Color _color(ColorScheme scheme) {
    // 与 _statusColor / _PipelineLegend / _ViewportNode 同一套语义色
    if (status == TaskStatus.completed) return scheme.sem.success;
    if (progress >= 1.0) return scheme.sem.success;
    // 暂停中的当前节点用信息色：进度是冻结的，不是正在跑
    if (status == TaskStatus.paused && isCurrent) return scheme.sem.info;
    if (status == TaskStatus.cancelled) return scheme.sem.warning;
    if (isCurrent && progress > 0.0 && progress < 1.0) {
      return scheme.sem.warning;
    }
    if (status == TaskStatus.processing && isCurrent) return scheme.sem.warning;
    return scheme.sem.neutral;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _color(scheme);
    // 节点名本地化：不再把后端英文 action 名（TRANSCODE 等）直接展示给用户
    final label = taskActionLabel(call.action, zh);
    final abbr = taskActionAbbr(call.action, zh);

    return Tooltip(
      message:
          '$label\n${(zh ? AppStrings.zh : AppStrings.en).qProgress}: ${(progress * 100).toStringAsFixed(0)}%',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _NodeRingPainter(
                color: color,
                progress: progress.clamp(0.0, 1.0),
                emphasise:
                    isCurrent &&
                    (status == TaskStatus.processing ||
                        status == TaskStatus.paused),
              ),
              child: Center(
                child: Text(
                  abbr,
                  style: TextStyle(
                    fontSize: size * 0.28,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${index + 1}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
              color: isCurrent ? color : scheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 圆环进度绘制：静态画法，**不做动画** —— 队列里可能同时有几十张卡片，
/// 每个节点一个 `CircularProgressIndicator` 就是几十条无限动画，整页会持续掉帧。
class _NodeRingPainter extends CustomPainter {
  final Color color;
  final double progress;
  final bool emphasise;

  _NodeRingPainter({
    required this.color,
    required this.progress,
    required this.emphasise,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 视口缩放到很小（节点可能只有 10px）时半径会变成负数，钳到 1 保证可绘制。
    final radius = math.max(1.0, size.width / 2 - 2.5);

    // 底
    canvas.drawCircle(center, radius, Paint()..color = color.withAlpha(36));

    if (progress > 0) {
      // 进度弧（从 12 点方向顺时针）
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    } else {
      // 未开始：只有一圈细描边
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withAlpha(170)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

    // 当前节点：外圈再补一层淡描边，与其它节点拉开层级
    if (emphasise) {
      canvas.drawCircle(
        center,
        radius + 2.5,
        Paint()
          ..color = color.withAlpha(70)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }
  }

  @override
  bool shouldRepaint(_NodeRingPainter old) =>
      old.color != color ||
      old.progress != progress ||
      old.emphasise != emphasise;
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

  /// 图片（截图等）不走 ffmpeg 抽帧：移动端 fork+exec 起子进程生成缩略图
  /// 并不稳定（失败时只有占位图标），而 Image.file 可直接解码源文件，
  /// 配合 cacheWidth 限制解码尺寸即可。
  bool get _isImage => detectMediaType(widget.filepath) == MediaType.image;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_isImage) return;
    final p = await ThumbnailService.ensureThumbnail(
      widget.filepath,
      ffmpeg: widget.ffmpeg,
    );
    if (mounted && p != null) setState(() => _path = p);
  }

  @override
  Widget build(BuildContext context) {
    if (_isImage) {
      return Image.file(
        File(widget.filepath),
        width: 40,
        height: 25,
        // 缩略图按显示尺寸 3x 封顶解码（1080p 源 ~8MB/张）
        cacheWidth: 120,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Icon(
          Icons.image_outlined,
          color: Theme.of(context).colorScheme.outline,
          size: 16,
        ),
      );
    }
    if (_path != null) {
      return Image.file(
        File(_path!),
        width: 40,
        height: 25,
        // 缩略图按显示尺寸 3x 封顶解码（1080p 源 ~8MB/张）
        cacheWidth: 120,
        fit: detectMediaType(widget.filepath) == MediaType.audio
            ? BoxFit.contain
            : BoxFit.cover,
      );
    }
    return Icon(
      Icons.music_note,
      color: Theme.of(context).colorScheme.outline,
      size: 16,
    );
  }
}
