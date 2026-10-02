import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/multi_window.dart';
import '../theme/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/node_icons.dart';
import '../widgets/step_editors/audio_compressor_step_editor.dart';
import '../widgets/step_editors/audio_convert_step_editor.dart';
import '../widgets/step_editors/audio_fade_step_editor.dart';
import '../widgets/step_editors/audio_metadata_step_editor.dart';
import '../widgets/step_editors/audio_quality_step_editor.dart';
import '../widgets/step_editors/audio_speed_step_editor.dart';
import '../widgets/step_editors/audio_volume_step_editor.dart';
import '../widgets/step_editors/av_process_step_editor.dart';
import '../widgets/step_editors/clip_step_editor.dart';
import '../widgets/step_editors/concat_media_step_editor.dart';
import '../widgets/step_editors/extract_audio_step_editor.dart';
import '../widgets/step_editors/frame_step_editor.dart';
import '../widgets/step_editors/generic_step_editor.dart';
import '../widgets/step_editors/image_adjust_step_editor.dart';
import '../widgets/step_editors/image_brightness_step_editor.dart';
import '../widgets/step_editors/image_channel_extract_step_editor.dart';
import '../widgets/step_editors/image_convert_step_editor.dart';
import '../widgets/step_editors/image_crop_step_editor.dart';
import '../widgets/step_editors/image_denoise_step_editor.dart';
import '../widgets/step_editors/image_noise_step_editor.dart';
import '../widgets/step_editors/image_rotate_step_editor.dart';
import '../widgets/step_editors/image_scale_step_editor.dart';
import '../widgets/step_editors/image_sharpen_step_editor.dart';
import '../widgets/step_editors/image_to_video_step_editor.dart';
import '../widgets/step_editors/output_step_editor.dart';
import '../widgets/step_editors/speed_step_editor.dart';
import '../widgets/step_editors/start_step_editor.dart';
import '../widgets/step_editors/subtitle_step_editor.dart';
import '../widgets/step_editors/video_crop_step_editor.dart';
import '../widgets/step_editors/video_filter_step_editor.dart';
import '../widgets/step_editors/video_geometry_step_editor.dart';
import '../widgets/step_editors/video_overlay_step_editor.dart';
import 'pipeline_editor_page.dart' show AiPanelApi, AiPanelView;

/// ════════════════════════════════════════════════════════════════════════
/// 独立面板窗口（真正脱离主窗口的系统窗口）的 UI
/// ════════════════════════════════════════════════════════════════════════
///
/// 本进程是**独立的 Flutter 引擎**：没有 AppState、没有画布、没有后端。
/// 一切数据都来自主窗口的推送（见 services/multi_window.dart 的协议说明），
/// 一切修改都回推给主窗口执行。
///
/// 能复用的就复用：
///  * 属性编辑器直接用 `lib/widgets/step_editors/*` 的同一批 widget；
///  * AI 面板直接用 `AiPanelView`（它就是靠 `context.read<AppState>()` 取数的，
///    这里用 MirrorAppState 顶上，UI 一行都不用改）。
/// 不能复用的（必须在主窗口做，因为依赖画布交互）：逻辑门 / 时间触发器的
/// 编辑器（它内部要拖端口、命中测试、连线）与元素工具箱里的逻辑块/逻辑门。

/// 面板窗口里的数据总线：镜像 AppState + 主窗口推来的快照。
class PanelWindowStore extends ChangeNotifier {
  PanelWindowStore(this.args);

  final DetachedWindowArgs args;

  /// AI 面板内部固定是 `context.read<AppState>()`，所以镜像必须是 AppState
  /// 的子类（见 MirrorAppState 的说明）。
  late final MirrorAppState app = MirrorAppState(send: _send);

  static Future<dynamic> _send(String method, [Map<String, dynamic>? a]) =>
      MultiWindowService.invokeHost(method, a);

  AppConfig get config => app.config;
  bool get isZh => config.language == 'zh';
  AppStrings get strings => AppStrings.of(config.language);

  List<PipelineNode> _nodes = const <PipelineNode>[];
  List<PipelineConnection> _connections = const <PipelineConnection>[];

  List<PipelineNode> get nodes => _nodes;
  List<PipelineConnection> get connections => _connections;

  /// 当前选中节点（属性窗口的主体）。
  PipelineNode? selected;

  /// 元素清单（主窗口按「显示可用」算好的描述符）。
  List<Map<String, dynamic>> toolbox = const <Map<String, dynamic>>[];

  /// 源文件信息（步骤编辑器要用的视频/图片元数据）。
  Map<String, dynamic> video = const <String, dynamic>{};

  /// 属性窗口专用的补充字段（缩略图、输出名、源图路径等）。
  Map<String, dynamic> props = const <String, dynamic>{};

  /// 大图路径（start 节点的缩略图；与主窗口共用同一份磁盘文件）。
  String? get thumbPath => props['thumbPath'] as String?;

  /// 交接过来的 AI 会话消息。
  List<Map<String, dynamic>> aiSeed = const <Map<String, dynamic>>[];

  /// 本窗口里 AI 面板的窄接口。由 [_AiWindow] 在面板就绪后回填，
  /// 「吸附回主窗口」时用它把对话原样交还 —— 否则一收回去对话就断档了。
  AiPanelApi? aiApi;

  /// 宿主要求关窗时的动作，由 [_DetachedPanelAppState] 注入。
  ///
  /// 关窗逻辑不能写在这里：它要用 window_manager，还要区分「用户点的 X」与
  /// 「我们自己发起的关闭」（见 _closeSelf 的说明）。
  Future<void> Function()? closeRequested;

  bool _ready = false;
  bool get ready => _ready;

  /// 向主窗口报到并取首份快照。
  Future<void> bootstrap() async {
    final snap = await MultiWindowService.invokeHost(
      PanelMethod.ready,
      <String, dynamic>{'panel': args.panel.id},
    );
    if (snap is Map) hydrate(Map<String, dynamic>.from(snap));
    _ready = true;
    notifyListeners();
  }

  /// 主窗口推消息进来。
  Future<dynamic> onPush(String method, Map<String, dynamic> a) async {
    switch (method) {
      case PanelPush.snapshot:
        hydrate(a);
        break;
      case PanelPush.nodeParams:
        // 主窗口改了参数（可能是 AI 改的）：就地刷新选中的那个节点
        final id = a['nodeId'] as String?;
        final params = a['params'];
        final node = selected;
        if (id != null && params is Map && node != null && node.id == id) {
          node.params
            ..clear()
            ..addAll(Map<String, dynamic>.from(params));
          notifyListeners();
        }
        break;
      case PanelPush.aiSession:
        final list = a['messages'];
        aiSeed = list is List
            ? list
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
            : const <Map<String, dynamic>>[];
        notifyListeners();
        break;
      case PanelPush.closeWindow:
        // 主窗口要求关掉本窗口（吸附回主栏的收尾动作）。
        await closeRequested?.call();
    }
    return null;
  }

  void hydrate(Map<String, dynamic> snapshot) {
    app.hydrate(snapshot);

    final graph = snapshot['graph'];
    if (graph is Map) {
      _nodes = _parseNodes(graph['nodes']);
      _connections = _parseConnections(graph['connections']);
    }

    final tb = snapshot['toolbox'];
    toolbox = tb is List
        ? tb
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : const <Map<String, dynamic>>[];

    final v = snapshot['video'];
    video = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

    final p = snapshot['props'];
    props =
        p is Map ? Map<String, dynamic>.from(p) : const <String, dynamic>{};

    final sel = snapshot['selection'];
    selected = sel is Map
        ? PipelineNode.fromJson(Map<String, dynamic>.from(sel))
        : null;

    final ai = snapshot['ai'];
    if (ai is Map) {
      final session = ai['session'];
      if (session is List) {
        aiSeed = session
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }
    notifyListeners();
  }

  static List<PipelineNode> _parseNodes(Object? raw) {
    if (raw is! List) return const <PipelineNode>[];
    final out = <PipelineNode>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        out.add(PipelineNode.fromJson(Map<String, dynamic>.from(item)));
      } catch (_) {}
    }
    return out;
  }

  static List<PipelineConnection> _parseConnections(Object? raw) {
    if (raw is! List) return const <PipelineConnection>[];
    final out = <PipelineConnection>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        out.add(PipelineConnection.fromJson(Map<String, dynamic>.from(item)));
      } catch (_) {}
    }
    return out;
  }

  // ── 回主窗口的动作 ───────────────────────────────────────────────────

  /// 吸附回主栏：主窗口把面板收回应用内，然后要求本窗口关闭。
  ///
  /// AI 面板的对话必须跟着回去：本窗口一销毁，_AiPanelViewState 里的消息就没了，
  /// 而主窗口的抽屉会重新挂载，只能靠这份消息把对话续上。
  Future<void> dockBack() =>
      MultiWindowService.invokeHost(PanelMethod.dockBack, <String, dynamic>{
        'panel': args.panel.id,
        if (args.panel == DetachedPanel.ai) 'messages': aiApi?.exportMessages(),
      });

  /// 某个节点的参数变了（编辑器是**原地改 map** 的，所以直接整份回传）。
  Future<void> pushParams(PipelineNode node) =>
      MultiWindowService.invokeHost(PanelMethod.setParams, <String, dynamic>{
        'nodeId': node.id,
        'params': node.params,
      });

  /// 在画布上加一个节点。id 在本地生成后一并回传，主窗口按这个 id 建节点 ——
  /// 否则主窗口自己生成 id，本窗口拿不到返回值（通道是异步的，而工具箱点按
  /// 需要同步拿到 id）。
  Future<void> addNode(String typeId) {
    final id = const Uuid().v4();
    return MultiWindowService.invokeHost(PanelMethod.addNode, <String, dynamic>{
      'typeId': typeId,
      'nodeId': id,
    });
  }
}

/// 由 main.dart 在检测到「本进程是面板窗口」时调用。
Future<void> runDetachedPanelWindow(DetachedWindowArgs args) async {
  runApp(DetachedPanelApp(args: args));
}

class DetachedPanelApp extends StatefulWidget {
  const DetachedPanelApp({super.key, required this.args});

  final DetachedWindowArgs args;

  @override
  State<DetachedPanelApp> createState() => _DetachedPanelAppState();
}

class _DetachedPanelAppState extends State<DetachedPanelApp> with WindowListener {
  late final PanelWindowStore _store = PanelWindowStore(widget.args);

  /// 本次关闭是不是我们自己发起的。
  ///
  /// `windowManager.close()` 会走「先解除拦截、再发原生 close」这条路，而原生
  /// close 事件反过来又会触发 [onWindowClose]。没有这个标志就会自己叫自己，
  /// 无限循环。
  bool _closingSelf = false;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChanged);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _store.removeListener(_onChanged);
    _store.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 关闭本窗口。
  ///
  /// **绝不能用 `windowManager.destroy()`**：那在 Windows 上是
  /// `PostQuitMessage(0)`、在 macOS 上是 `NSApp.terminate(nil)` —— 而子窗口与
  /// 主窗口共用同一个平台线程 / 同一个 NSApplication。从子窗口调用会把**整个
  /// 应用**一起退掉，主窗口瞬间消失。
  ///
  /// 正确做法是「先解除关窗拦截，再发原生 close」：Windows 走子窗口自己的
  /// WM_CLOSE→DestroyWindow，macOS 走 performClose，Linux 走 gtk_window_close，
  /// 三边都只销毁这一个窗口。
  Future<void> _closeSelf() async {
    if (_closingSelf) return;
    _closingSelf = true;
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    try {
      await windowManager.close();
    } catch (_) {}
  }

  Future<void> _bootstrap() async {
    _store.closeRequested = _closeSelf;
    await _installChrome();
    // 先注册「主窗口 → 本窗口」的接收口，再报到要快照 —— 否则主窗口推来的
    // 第一条消息会因为 handler 还没注册而丢失。
    await MultiWindowService.installGuest(_store.onPush);
    await _store.bootstrap();
  }

  Future<void> _installChrome() async {
    final isAi = widget.args.panel == DetachedPanel.ai;
    final title = isAi
        ? (_store.isZh ? 'FFmpeg++ · AI 助手' : 'FFmpeg++ · AI Assistant')
        : (_store.isZh ? 'FFmpeg++ · 元素 / 属性' : 'FFmpeg++ · Elements / Properties');
    try {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      if (!Platform.isLinux) {
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      }
      await windowManager.setMinimumSize(const Size(280, 360));
      await windowManager.setSize(Size(
        widget.args.width > 0 ? widget.args.width : (isAi ? 460 : 380),
        widget.args.height > 0 ? widget.args.height : 800,
      ));
      await windowManager.setTitle(title);
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    // 原生 close 事件既可能来自用户点 X，也可能来自我们自己的 _closeSelf()。
    // 后者不需要（也不能）再走一遍「收回 + 通知」，直接让窗口死掉即可。
    if (_closingSelf) return;
    // 用户点了系统标题栏的 X：语义与「吸附回主窗口」完全一致 —— 面板收回应用内
    // （AI 会话一并交还），本窗口随即关闭。绝不允许出现「面板既不在主窗口、
    // 窗口也没了」的死状态。
    await _store.dockBack();
    // 再通知一次「窗口已消失」，让主窗口清掉 _openWindows 里的登记 ——
    // 否则下次拖出会去 show() 一个已经不存在的窗口。
    await MultiWindowService.invokeHost(
      PanelMethod.closed,
      <String, dynamic>{'panel': widget.args.panel.id},
    );
    await _closeSelf();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _store.config;
    return MaterialApp(
      key: const ValueKey('detached-panel'),
      title: 'FFmpeg++',
      debugShowCheckedModeBanner: false,
      locale: Locale(_store.isZh ? 'zh' : 'en'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // 与主窗口同一套主题工厂：玻璃/配色/字体设置跟随主窗口。
      theme: AppTheme.light(
        seedColor: cfg.themeColor,
        fontFamily: cfg.fontFamily,
        fontSize: cfg.fontSize,
        fontWeight: cfg.fontWeightValue,
        predictiveBack: false,
        glassEffect: cfg.glassEffect,
      ),
      darkTheme: AppTheme.dark(
        seedColor: cfg.themeColor,
        fontFamily: cfg.fontFamily,
        fontSize: cfg.fontSize,
        fontWeight: cfg.fontWeightValue,
        predictiveBack: false,
        glassEffect: cfg.glassEffect,
      ),
      themeMode: cfg.darkMode ? ThemeMode.dark : ThemeMode.light,
      home: !_store.ready
          ? const _Connecting()
          : widget.args.panel == DetachedPanel.ai
              ? _AiWindow(store: _store)
              : _PropsWindow(store: _store),
    );
  }
}

class _Connecting extends StatelessWidget {
  const _Connecting();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

/// 面板窗口顶部动作条：标题 + 「吸附回主栏」。

/// 关闭动作交给系统标题栏的 X（会走 [WindowManagerListener.onWindowClose]），
/// 效果同样是「面板收回应用内」，避免出现面板两边都不在的死状态。
class _PanelActionBar extends StatelessWidget {
  const _PanelActionBar({required this.store, required this.title});

  final PanelWindowStore store;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isZh = store.isZh;
    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withAlpha(60),
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.open_in_new, size: 13, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          Tooltip(
            message: isZh ? '吸附回主窗口' : 'Dock back',
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => unawaited(store.dockBack()),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close_fullscreen,
                    size: 14, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          // 不再单独放「关闭」按钮：把面板窗口直接关掉而不收回应用内，会让面板
          // 进入「主窗口没有、窗口也没了」的死状态；系统标题栏的 X 会走
          // onWindowClose，那里的语义同样是「收回应用内」。一个动作就够。
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 元素 / 属性 面板
// ══════════════════════════════════════════════════════════════════════════

class _PropsWindow extends StatefulWidget {
  const _PropsWindow({required this.store});

  final PanelWindowStore store;

  @override
  State<_PropsWindow> createState() => _PropsWindowState();
}

class _PropsWindowState extends State<_PropsWindow> {
  final TextEditingController _search = TextEditingController();
  double _fraction = 0.42;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final scheme = Theme.of(context).colorScheme;
    final s = store.strings;
    return Scaffold(
      body: Column(
        children: [
          _PanelActionBar(
            store: store,
            title: s.isZh ? '元素 / 属性' : 'Elements / Properties',
          ),
          Expanded(
            child: LayoutBuilder(builder: (ctx, cons) {
              const dividerH = 10.0;
              final usable = (cons.maxHeight - dividerH).clamp(0.0, 1e9);
              final topH = (usable * _fraction).clamp(90.0, usable - 90.0);
              return Column(
                children: [
                  SizedBox(height: topH, child: _toolbox(scheme, s)),
                  MouseRegion(
                    cursor: SystemMouseCursors.resizeRow,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (d) {
                        setState(() {
                          _fraction = ((_fraction * usable + d.delta.dy) / usable)
                              .clamp(0.12, 0.88);
                        });
                      },
                      child: Container(
                        height: dividerH,
                        color: Colors.transparent,
                        child: Center(
                          child: Container(
                            width: 44,
                            height: 4,
                            decoration: BoxDecoration(
                              color: scheme.primary.withAlpha(90),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: _properties(scheme, s)),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _toolbox(ColorScheme scheme, AppStrings s) {
    final store = widget.store;
    final query = _search.text.trim().toLowerCase();
    final all = store.toolbox;
    final items = query.isEmpty
        ? all
        : all.where((e) {
            final label = (e['label'] as String? ?? '').toLowerCase();
            final labelEn = (e['labelEn'] as String? ?? '').toLowerCase();
            final id = (e['id'] as String? ?? '').toLowerCase();
            return label.contains(query) ||
                labelEn.contains(query) ||
                id.contains(query);
          }).toList();

    // 分组：保持主窗口给出的顺序，仅在相邻同组之间插一次标题。
    final children = <Widget>[];
    String? lastGroup;
    for (final e in items) {
      final group = e['group'] as String? ?? 'video';
      if (group != lastGroup) {
        children.add(_groupLabel(scheme, group, s));
        lastGroup = group;
      }
      children.add(_chip(scheme, s, e));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              hintText: s.isZh ? '搜索元素' : 'Search elements',
              hintStyle: TextStyle(fontSize: 12, color: scheme.outline),
              prefixIcon: Icon(Icons.search, size: 15, color: scheme.outline),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 30, minHeight: 30),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
            ),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text(
                    s.isZh ? '没有匹配的元素' : 'No matching element',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Wrap(spacing: 4, runSpacing: 4, children: children),
                ),
        ),
      ],
    );
  }

  Widget _groupLabel(ColorScheme scheme, String group, AppStrings s) {
    final (IconData icon, String label) = switch (group) {
      'fav' => (Icons.star, s.isZh ? '收藏' : 'Favourites'),
      'recent' => (Icons.history, s.isZh ? '最近使用' : 'Recent'),
      'io' => (Icons.import_export, s.isZh ? '输入 / 输出' : 'Input / Output'),
      'generic' => (Icons.category_outlined, s.isZh ? '通用' : 'General'),
      'audio' => (Icons.audiotrack_outlined, s.isZh ? '音频' : 'Audio'),
      'image' => (Icons.image_outlined, s.isZh ? '图片' : 'Image'),
      'container' => (Icons.folder_special_outlined, s.isZh ? '容器' : 'Container'),
      _ => (Icons.videocam_outlined, s.isZh ? '视频' : 'Video'),
    };
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 2),
        child: Row(
          children: [
            Icon(icon, size: 12, color: scheme.outline),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: scheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(ColorScheme scheme, AppStrings s, Map<String, dynamic> e) {
    final type = stepTypeFromId(e['id'] as String? ?? '');
    final tag = e['tag'] as String? ?? '';
    final label = s.isZh
        ? (e['label'] as String? ?? type.name)
        : (e['labelEn'] as String? ?? type.name);
    return Tooltip(
      message: s.isZh ? '点按添加到画布' : 'Click to add to canvas',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => unawaited(widget.store.addNode(type.name)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: nodeAccentColor(type, scheme).withAlpha(180),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(stepIconFor(type), size: 13, color: scheme.onSurface),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 11, color: scheme.onSurface)),
              if (tag.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  tag,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: scheme.outline,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _properties(ColorScheme scheme, AppStrings s) {
    final store = widget.store;
    final node = store.selected;
    if (node == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined,
                size: 30, color: scheme.outline.withAlpha(80)),
            const SizedBox(height: 8),
            Text(
              s.isZh ? '在主窗口选中节点后在此编辑' : 'Select a node to edit here',
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _nodeHeader(scheme, s, node),
          const SizedBox(height: 6),
          buildDetachedNodeEditor(store, node),
        ],
      ),
    );
  }

  Widget _nodeHeader(ColorScheme scheme, AppStrings s, PipelineNode node) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withAlpha(60),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            node.isGate ? Icons.rule : stepIconFor(node.type),
            size: 15,
            color: scheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              node.isGate
                  ? (node.gate?.name ?? 'gate')
                  : (s.isZh ? node.label : node.labelEn),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          Text(
            node.id.length > 6 ? node.id.substring(0, 6) : node.id,
            style: TextStyle(fontSize: 9, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 属性编辑器（复用 lib/widgets/step_editors/* 的同一批 widget）
// ══════════════════════════════════════════════════════════════════════════

/// 节点属性编辑器。
///
/// 与主窗口 `_buildStepEditor` 的 switch **逐分支对应**：这里不重新实现任何
/// 参数语义，只是把同一个 step editor 装配起来。新增节点类型时两处都要加
/// （主窗口那份在 pipeline_editor_page.dart 的 `_buildStepEditor`）。
Widget buildDetachedNodeEditor(PanelWindowStore store, PipelineNode node) {
  final isZh = store.isZh;
  final v = store.video;
  final params = node.params;
  void onChanged() => unawaited(store.pushParams(node));

  // ── 逻辑门：其编辑器依赖画布端口拖拽/命中测试，只能留在主窗口 ──
  if (node.isGate) {
    return _DetachedNotice(
      title: isZh ? '逻辑门节点' : 'Logic gate node',
      body: isZh
          ? '逻辑门 / 时间触发器的编辑器需要画布交互（拖端口、连线、命中测试），'
              '只能在主窗口内编辑。请点上方「吸附回主窗口」继续。'
          : 'Gate / time-trigger editors need canvas interaction (port drag, '
              'connections, hit testing) and are only available in the main window.',
    );
  }

  String s(Object? key, [String fallback = '']) {
    final value = v[key];
    return value is String ? value : fallback;
  }

  num n(Object? key) {
    final value = v[key];
    return value is num ? value : 0;
  }

  Widget editor;
  switch (node.type) {
    case PipelineStepType.start:
      final thumb = store.thumbPath;
      editor = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (thumb != null && File(thumb).existsSync())
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(thumb),
                  width: double.infinity,
                  height: 140,
                  cacheWidth: 720,
                  fit: s('fileMediaType') == MediaType.audio.name
                      ? BoxFit.contain
                      : BoxFit.cover,
                ),
              ),
            ),
          StartStepEditor(
            filename: s('filename'),
            resolution: s('resolution'),
            durationStr: s('durationStr'),
            sizeMb: n('sizeMb').toDouble(),
            codec: s('codec'),
            pixFmt: s('pixFmt'),
            audioCodec: s('audioCodec'),
            audioChannels: n('audioChannels').toInt(),
            isZh: isZh,
          ),
        ],
      );
    case PipelineStepType.output:
      editor = OutputStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
        sourceFilename: store.props['outputName'] as String? ?? s('filename'),
        defaultOutputDir: store.config.defaultOutputDir,
      );
    case PipelineStepType.avProcess:
      editor = AvProcessStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.subtitle:
      editor = SubtitleStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.clip:
      editor = ClipStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        videoPath: s('filepath'),
        videoDuration: n('duration').toDouble(),
        isZh: isZh,
      );
    case PipelineStepType.frame:
      editor = FrameStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        videoPath: s('filepath'),
        videoDuration: n('duration').toDouble(),
        isZh: isZh,
      );
    case PipelineStepType.speed:
      editor = SpeedStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.imageConvert:
      editor = ImageConvertStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.audioConvert:
      editor = AudioConvertStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.audioQuality:
      editor = AudioQualityStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.audioSpeed:
      editor = AudioSpeedStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.audioVolume:
      editor = AudioVolumeStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.audioCompressor:
      editor = AudioCompressorStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.audioMetadata:
      editor = AudioMetadataStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.extractAudio:
      editor = ExtractAudioStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        videoPath: s('filepath'),
        videoDuration: n('duration').toDouble(),
        isZh: isZh,
      );
    case PipelineStepType.concatMedia:
      editor = ConcatMediaStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
        containerFileCount:
            (store.props['containerFileCount'] as num?)?.toInt() ?? 0,
      );
    case PipelineStepType.imageToVideo:
      editor = ImageToVideoStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
        containerFileCount:
            (store.props['containerFileCount'] as num?)?.toInt() ?? 0,
      );
    case PipelineStepType.imageCrop:
      editor = ImageCropStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
        sourceImagePath: store.props['sourceImagePath'] as String?,
      );
    case PipelineStepType.imageRotate:
      editor = ImageRotateStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.imageScale:
      editor = ImageScaleStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.imageBrightness:
      editor = ImageBrightnessStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.imageNoise:
      editor = ImageNoiseStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.imageSharpen:
      editor = ImageSharpenStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.imageDenoise:
      editor = ImageDenoiseStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.imageChannelExtract:
      editor = ImageChannelExtractStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.videoCrop:
      editor = VideoCropStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        videoPath: s('filepath'),
        videoWidth: n('width').toInt(),
        videoHeight: n('height').toInt(),
        fps: n('fps').toDouble(),
        isZh: isZh,
      );
    case PipelineStepType.videoFilter:
      editor = VideoFilterStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.videoGeometry:
      editor = VideoGeometryStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.videoOverlay:
      editor = VideoOverlayStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.audioFade:
      editor = AudioFadeStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.imageAdjust:
      editor = ImageAdjustStepEditor(
          key: ValueKey(node.id), params: params, onChanged: onChanged, isZh: isZh);
    case PipelineStepType.mediaConvert:
    case PipelineStepType.mediaScale:
    case PipelineStepType.mediaCrop:
    case PipelineStepType.mediaRotate:
    case PipelineStepType.mediaColor:
    case PipelineStepType.mediaSharpen:
    case PipelineStepType.mediaOverlay:
      // 通用节点：媒体类型必选，按类型复用既有编辑器
      editor = GenericMediaStepEditor(
        key: ValueKey(node.id),
        node: node,
        onChanged: onChanged,
        isZh: isZh,
        videoPath: s('filepath'),
        videoDuration: n('duration').toDouble(),
        videoWidth: n('width').toInt(),
        videoHeight: n('height').toInt(),
        fps: n('fps').toDouble(),
        sourceImagePath: store.props['sourceImagePath'] as String?,
      );
    case PipelineStepType.unknown:
      editor = _DetachedNotice(
        title: isZh ? '未知节点类型' : 'Unknown node type',
        body: isZh
            ? '节点类型 ID：${node.unknownTypeId ?? '?'}（可编辑/保存/导出，但不能用于转码）'
            : 'Node type ID: ${node.unknownTypeId ?? '?'}',
      );
  }
  return editor;
}

class _DetachedNotice extends StatelessWidget {
  const _DetachedNotice({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(60),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withAlpha(70)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 15, color: scheme.outline),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(body, style: TextStyle(fontSize: 11, color: scheme.outline)),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// AI 面板窗口
// ══════════════════════════════════════════════════════════════════════════

class _AiWindow extends StatelessWidget {
  const _AiWindow({required this.store});

  final PanelWindowStore store;

  @override
  Widget build(BuildContext context) {
    final ops = _RemoteAiOps(store);
    final s = store.strings;
    return Scaffold(
      body: Column(
        children: [
          _PanelActionBar(store: store, title: s.isZh ? 'AI 助手' : 'AI Assistant'),
          Expanded(
            // AI 面板内部固定 `context.read<AppState>()`，这里用镜像实例顶上：
            // 面板 UI 一行都不用改，数据来自主窗口的推送。
            child: ChangeNotifierProvider<AppState>.value(
              value: store.app,
              child: AiPanelView(
                strings: s,
                existingNodes: store.nodes,
                existingConnections: store.connections,
                initialMessages: store.aiSeed,
                // 把窄接口交回来：dockBack / 关窗时要导出会话交还主窗口
                onApiReady: (api) => store.aiApi = api,
                hideHeader: true,
                onApplyGraph: ops.apply,
                onMergeGraph: ops.merge,
                onModifyNodeParams: ops.modifyParams,
                onClearAll: ops.clearAll,
                onUndo: ops.undo,
                onRedo: ops.redo,
                onSave: ops.save,
                onAddNode: ops.addNode,
                onAddGate: ops.addGate,
                onSetGateParams: ops.setGateParams,
                onDeleteNode: ops.deleteNode,
                onConnectNodes: ops.connectNodes,
                onDisconnectNodes: ops.disconnectNodes,
                onCancelTasks: ops.cancelTasks,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 把 AI 面板的图操作回调转发给主窗口。
///
/// 面板的回调签名是**同步**的（`bool Function(...)` / `String Function(...)`），
/// 而通道是异步的。这里的原则：
///  * 需要返回 id 的（加节点 / 加逻辑门）—— id 在本地生成后随请求一起回传，
///    主窗口按这个 id 建节点，于是「本地返回值」与「主窗口真实 id」一致；
///  * 需要返回 bool 的 —— 交回主窗口校验，这里返回 true（乐观）。失败时主
///    窗口会写日志，但 AI 这一轮拿不到 false。这是独立窗口的已知取舍。
class _RemoteAiOps {
  _RemoteAiOps(this.store);

  final PanelWindowStore store;

  static Future<dynamic> _invoke(String method, Map<String, dynamic> args) =>
      MultiWindowService.invokeHost(method, args);

  void apply(List<PipelineNode> nodes, List<PipelineConnection> connections) {
    unawaited(_invoke(PanelMethod.graphApply, <String, dynamic>{
      'nodes': [for (final n in nodes) n.toJson()],
      'connections': [for (final c in connections) c.toJson()],
      'merge': false,
    }));
  }

  void merge(List<PipelineNode> nodes, List<PipelineConnection> connections) {
    unawaited(_invoke(PanelMethod.graphApply, <String, dynamic>{
      'nodes': [for (final n in nodes) n.toJson()],
      'connections': [for (final c in connections) c.toJson()],
      'merge': true,
    }));
  }

  bool modifyParams(String nodeId, Map<String, dynamic> params) {
    unawaited(_invoke(PanelMethod.graphModify,
        <String, dynamic>{'nodeId': nodeId, 'params': params}));
    return true;
  }

  void clearAll() => unawaited(_invoke(PanelMethod.graphClearAll, const {}));

  void undo() => unawaited(_invoke(PanelMethod.graphUndo, const {}));

  void redo() => unawaited(_invoke(PanelMethod.graphRedo, const {}));

  void save() => unawaited(_invoke(PanelMethod.graphSave, const {}));

  String addNode(String type, double x, double y) {
    final id = const Uuid().v4();
    unawaited(_invoke(PanelMethod.addNode,
        <String, dynamic>{'typeId': type, 'x': x, 'y': y, 'nodeId': id}));
    return id;
  }

  String addGate(String gateName, double x, double y) {
    final id = const Uuid().v4();
    unawaited(_invoke(PanelMethod.graphAddGate,
        <String, dynamic>{'gate': gateName, 'x': x, 'y': y, 'nodeId': id}));
    return id;
  }

  bool setGateParams(String nodeId, Map<String, dynamic> params) {
    unawaited(_invoke(PanelMethod.graphSetGateParams,
        <String, dynamic>{'nodeId': nodeId, 'params': params}));
    return true;
  }

  void deleteNode(String nodeId) => unawaited(_invoke(
      PanelMethod.graphDeleteNode, <String, dynamic>{'nodeId': nodeId}));

  bool connectNodes(String fromId, String toId) {
    unawaited(_invoke(PanelMethod.graphConnect,
        <String, dynamic>{'fromId': fromId, 'toId': toId}));
    return true;
  }

  bool disconnectNodes(String connId) {
    unawaited(_invoke(
        PanelMethod.graphDisconnect, <String, dynamic>{'connId': connId}));
    return true;
  }

  void cancelTasks() => unawaited(_invoke(PanelMethod.graphCancelTasks, const {}));
}
