import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../services/system_monitor.dart';
// 控件高度档位令牌：顶栏几颗动作按钮统一按 regular 档取高度与图标尺寸
import '../theme/app_control_size.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_glass_pill.dart';
// 生效的菜单栏位置（底部 ↔ 左右竖排导轨）：列表底部留白随之在 96 / 20 间切换
import '../widgets/mobile_nav_scope.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/task_card.dart';

/// 队列页刷新依赖：任务列表版本号（已含节流）+ 界面语言。
/// 不再用 Consumer 订阅整个 AppState——日志/探测/配置等无关 notify
/// 不再触发队列页重建。
class _QueueKey {
  final int tasksVersion;
  final String language;
  const _QueueKey(this.tasksVersion, this.language);
  @override
  bool operator ==(Object other) =>
      other is _QueueKey &&
      other.tasksVersion == tasksVersion &&
      other.language == language;
  @override
  int get hashCode => Object.hash(tasksVersion, language);
}

class QueuePage extends StatefulWidget {
  const QueuePage({super.key});
  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  final _monitor = SystemMonitor();

  @override
  void initState() {
    super.initState();
    _monitor.start();
  }

  @override
  void dispose() {
    _monitor.stop();
    super.dispose();
  }

  /// 任务卡片的 widget 实例缓存（按列表下标）。
  /// TaskInfo 是 immutable（copyWith 生成新实例），任务实例未变时直接复用
  /// 旧的 widget 实例——Element.updateChild 对 identical 的 widget 跳过
  /// 重建，进度心跳只重建真正变化了的卡片，而不是整列。
  final List<TaskCard> _taskCardWidgets = [];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Selector<AppState, _QueueKey>(
      selector: (_, s) => _QueueKey(s.tasksVersion, s.config.language),
      builder: (context, _, _) {
        final state = context.read<AppState>();
        // 构建期取一次快照：下面「空态判断 / 长度 / 逐项取卡片」共读 4 次。
        // tasks 已是零拷贝视图（见 AppState.tasks），但显式取一次更直白，
        // 也避免将来有人把 getter 改回 List.unmodifiable 时又退化成 4 次拷贝。
        final tasks = state.tasks;
        final s = AppStrings.of(state.config.language);
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(children: [
            // 全屏可滚动的内容（移动端顶部留出药丸空间）
            isMobilePlatform
                ? Padding(
                    padding: EdgeInsets.only(top: MobileUi.pageTopPadding(context)),
                    child: tasks.isEmpty
                        ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.inbox_outlined, size: 64, color: scheme.outline),
                            const SizedBox(height: 16),
                            Text(s.emptyQueue, style: TextStyle(fontSize: 16, color: scheme.outline)),
                            const SizedBox(height: 8),
                            Text(s.emptyQueueHint, style: TextStyle(fontSize: 13, color: scheme.outline)),
                          ]))
                        : ListView.builder(
                            // 开窗卡所在列表必须关（见 app_card 的
                            // _WallpaperWindowPainter）
                            addRepaintBoundaries: false,
                            padding: MobileUi.mainListPadding(
                                placement: MobileNavPlacementScope.of(context)),
                            itemCount: tasks.length,
                            itemBuilder: (_, i) => _taskCardFor(tasks, i),
                          ),
                  )
                : Column(children: [
                    GlassTopBar(
                      // 桌面顶栏高度固定 56：标题单行省略，大字号下不会折行顶出栏外
                      title: Text(s.navQueue, maxLines: 1, overflow: TextOverflow.ellipsis),
                      actions: _buildActions(scheme, state, s),
                    ),
                    Expanded(
                      child: tasks.isEmpty
                          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.inbox_outlined, size: 64, color: scheme.outline),
                              const SizedBox(height: 16),
                              Text(s.emptyQueue, style: TextStyle(fontSize: 16, color: scheme.outline)),
                              const SizedBox(height: 8),
                              Text(s.emptyQueueHint, style: TextStyle(fontSize: 13, color: scheme.outline)),
                            ]))
                          : RepaintBoundary(
                              child: ListView.builder(
                                // 开窗卡所在列表必须关（见 app_card 的
                                // _WallpaperWindowPainter）
                                addRepaintBoundaries: false,
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                                itemCount: tasks.length,
                                itemBuilder: (_, i) => _taskCardFor(tasks, i),
                              ),
                            ),
                    ),
                  ]),
            // 移动端顶栏浮层（不影响滚动）
            if (isMobilePlatform)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildMobileTopBar(scheme, state, s),
              ),
          ]),
        );
      },
    );
  }

  /// 取第 i 个任务的卡片 widget：任务实例未变时复用缓存的 widget 实例
  /// （框架对 identical 的 widget 跳过重建），进度心跳下只有真正变化的
  /// 卡片会重建，而不是整列 20~50 张卡片每 300ms 全量重建。
  ///
  /// [tasks] 由调用方传入构建期取好的同一份快照（见 build 内注释）。
  TaskCard _taskCardFor(List<TaskInfo> tasks, int i) {
    // 任务列表缩短时裁掉尾部缓存
    if (_taskCardWidgets.length > tasks.length) {
      _taskCardWidgets.removeRange(tasks.length, _taskCardWidgets.length);
    }
    final task = tasks[i];
    if (i < _taskCardWidgets.length && identical(_taskCardWidgets[i].task, task)) {
      return _taskCardWidgets[i];
    }
    final card = TaskCard(key: ValueKey(task.id), task: task);
    // 关键修复：不能用 `_taskCardWidgets.length = i + 1` 扩容——非空类型
    // List 的 length= 会以 null 填充新槽位，运行时抛
    // 「type 'Null' is not a subtype of type 'TaskCard'」，队列页只要有任务
    // 就构建失败 → 整页白屏。必须用 add / 下标赋值。
    if (i >= _taskCardWidgets.length) {
      _taskCardWidgets.add(card);
    } else {
      _taskCardWidgets[i] = card;
    }
    return card;
  }

  Widget _monitorBar(ColorScheme scheme, AppState state) {
    return _MonitorWidget(monitor: _monitor, scheme: scheme);
  }

  /// 顶栏操作按钮 + 资源占用（桌面端与移动端共用同一份逻辑）。
  /// 按钮文字统一单行省略：顶栏高度固定，字号调大时折行会把整条顶栏撑高
  /// （按钮本身宽度由内容决定，纯文本按钮最容易在窄窗口下折成两行）。
  ///
  /// 四颗按钮统一走 [AppControlSize.regular]（高 32 / 图标 16 / 圆角 8）：
  /// 改造前三颗是主题默认高度、图标 16 / 18 / 16 / 16 三种，「开始处理」还比
  /// 旁边两颗高出一档，并排看像不是一个组的。
  List<Widget> _buildActions(ColorScheme scheme, AppState state, AppStrings s) {
    const size = AppControlSize.regular;
    return [
      if (state.processing)
        OutlinedButton.icon(
            style: size.buttonStyle(),
            icon: Icon(Icons.stop, size: size.iconSize),
            label: Text(s.cancelAll, maxLines: 1, overflow: TextOverflow.ellipsis),
            onPressed: () => state.cancelProcessing())
      else ...[
        if (state.tasks.any((t) => t.status == TaskStatus.pending))
          FilledButton.icon(
              style: size.buttonStyle(filled: true),
              icon: Icon(Icons.play_arrow, size: size.iconSize),
              label: Text(s.startProcessing, maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: () => state.processAllTasks()),
        if (state.tasks.any((t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed || t.status == TaskStatus.cancelled))
          TextButton.icon(
              style: size.buttonStyle(),
              icon: Icon(Icons.cleaning_services_outlined, size: size.iconSize),
              label: Text(s.clearCompleted, maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: () => state.clearCompletedTasks()),
        if (state.tasks.isNotEmpty)
          TextButton.icon(
              style: size.buttonStyle(),
              icon: Icon(Icons.delete_sweep, size: size.iconSize),
              label: Text(s.clearAll, maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: () => state.clearAllTasks()),
      ],
      // 紧凑资源占用（顶栏右侧，小尺寸）
      const SizedBox(width: 8),
      Padding(
        padding: const EdgeInsets.only(right: 12),
        child: _monitorBar(scheme, state),
      ),
    ];
  }

  /// 移动端顶栏操作（紧凑圆形图标按钮，无文字）：与项目页/配置库页共用
  /// [MobileGlassPillAction]（34×34、图标 19、透明涟漪），不再本页自绘一份。
  /// 「停止」用 error 色，与项目页删除按钮一致。
  List<Widget> _buildMobileActions(ColorScheme scheme, AppState state, AppStrings s) {
    return [
      if (state.processing)
        MobileGlassPillAction(
          icon: Icons.stop,
          tooltip: s.cancelAll,
          color: scheme.error,
          onTap: () => state.cancelProcessing(),
        ),
      if (!state.processing && state.tasks.any((t) => t.status == TaskStatus.pending))
        MobileGlassPillAction(
          icon: Icons.play_arrow,
          tooltip: s.startProcessing,
          color: scheme.onSurface,
          onTap: () => state.processAllTasks(),
        ),
      if (state.tasks.any((t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed || t.status == TaskStatus.cancelled))
        MobileGlassPillAction(
          icon: Icons.cleaning_services_outlined,
          tooltip: s.clearCompleted,
          color: scheme.onSurface,
          onTap: () => state.clearCompletedTasks(),
        ),
      if (state.tasks.isNotEmpty)
        MobileGlassPillAction(
          icon: Icons.delete_sweep,
          tooltip: s.clearAll,
          color: scheme.onSurface,
          onTap: () => state.clearAllTasks(),
        ),
      // 紧凑资源占用（CPU/内存/GPU）：左右各 4px 由药丸内边距承担，
      // 与 34×34 圆形按钮垂直居中对齐（不再额外加 SizedBox）。
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: _monitorBar(scheme, state),
      ),
    ];
  }

  /// 移动端顶栏：统一走 [MobilePillTopBar]（标题药丸 + 操作药丸 + 安全区
  /// 内边距全部由顶栏提供），不再本页拼 Row/Flexible/Align/FittedBox。
  Widget _buildMobileTopBar(ColorScheme scheme, AppState state, AppStrings s) {
    return MobilePillTopBar(
      // 药丸高度固定：标题单行省略（顶栏内部已有 DefaultTextStyle.maxLines 兜底）
      title: Text(s.navQueue, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: _buildMobileActions(scheme, state, s),
      // 主界面不折叠（用户要求「主界面不要搞...了」）：队列页的操作项固定且不多，
      // 挤在同一颗药丸里比收进「…」更好点。
      collapseActions: false,
    );
  }
}

class _MonitorWidget extends StatefulWidget {
  final SystemMonitor monitor;
  final ColorScheme scheme;
  const _MonitorWidget({required this.monitor, required this.scheme});
  @override
  State<_MonitorWidget> createState() => _MonitorWidgetState();
}

class _MonitorWidgetState extends State<_MonitorWidget> {
  Timer? _refreshTimer;
  // 上次渲染的指标快照：仅在数值真正变化时才 setState，
  // 避免空闲/数值稳定时每 2 秒无条件重建（长任务期间累积无谓 build）。
  String? _lastSnapshot;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final snap = _snapshot();
      // [FIX L-13] 在状态变化时更新快照并触发重建，移出 build() 避免 build 副作用
      if (snap != _lastSnapshot) {
        _lastSnapshot = snap;
        setState(() {});
      }
    });
  }

  /// 把当前指标压成一个可比较的字符串（仅用于变更检测）。
  String _snapshot() {
    final m = widget.monitor;
    return '${m.cpuPercent.toStringAsFixed(0)}|${m.ramUsedGb.toStringAsFixed(1)}'
        '|${m.ramPercent.toStringAsFixed(0)}|${m.gpuPercent.toStringAsFixed(0)}';
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.monitor;
    final sc = widget.scheme;
    // 紧凑小尺寸：仅图标 + 数值，适合放在顶栏右侧
    // -1 表示读取失败（Android SELinux 拦截 /proc），显示 "--" 避免误导为 0%
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _mini(Icons.memory, m.cpuPercent < 0 ? '--' : '${m.cpuPercent.toStringAsFixed(0)}%', m.cpuPercent < 0 ? 0 : m.cpuPercent / 100, sc),
      const SizedBox(width: 8),
      _mini(Icons.storage, m.ramUsedGb < 0 ? '--' : '${m.ramUsedGb.toStringAsFixed(1)}G', m.ramPercent < 0 ? 0 : m.ramPercent / 100, sc),
      // GPU：始终显示（修复：Android 上部分机型拿不到占用率时整块不渲染，
      // 用户以为队列界面缺少 GPU 信息；现在统一显示，读不到时为 "--"，
      // 长按可看探测到的 GPU 型号）。
      const SizedBox(width: 8),
      Tooltip(
        message: m.gpuName.isEmpty
            ? (Platform.isAndroid ? 'GPU 占用率不可用' : 'GPU')
            : '${m.gpuName} ${m.gpuPercent < 0 ? '' : '· ${m.gpuPercent.toStringAsFixed(0)}%'}',
        child: _mini(Icons.videocam, m.gpuPercent < 0 ? '--' : '${m.gpuPercent.toStringAsFixed(0)}%', m.gpuPercent < 0 ? 0 : m.gpuPercent / 100, sc),
      ),
    ]);
  }

  /// 迷你指标：彩色图标 + 等宽数值。
  Widget _mini(IconData icon, String value, double progress, ColorScheme scheme) {
    // 占用率三档：>80% 危险、>50% 警告、否则正常。原先写死 Colors.red /
    // Colors.orange，不随主题色变化（且这两个 tone 50 原色在深色底上过亮）。
    final color = progress > 0.8
        ? scheme.sem.danger
        : progress > 0.5
            ? scheme.sem.warning
            : scheme.sem.info;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(value, style: TextStyle(fontSize: 10, color: scheme.onSurface, fontFamily: AppTheme.monoFont, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
