import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/multi_window.dart';
import '../theme/app_strings.dart';
import '../theme/app_text_scale.dart';
import '../theme/app_theme.dart';
import '../widgets/gate_symbol_painter.dart';
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
import '../widgets/wallpaper_background.dart';
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
/// 逻辑门的信息与时间触发器参数同样可在这里编辑；端口连线仍由主画布处理。

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
  bool suspended = false;
  String? appDataDir;

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
      case PanelPush.suspend:
        aiSeed = aiApi?.exportMessages() ?? aiSeed;
        aiApi = null;
        suspended = true;
        notifyListeners();
        // Dispose the actual panel before acknowledging the host's hide request.
        await WidgetsBinding.instance.endOfFrame;
        break;
      case PanelPush.reactivate:
        hydrate(a);
        suspended = false;
        notifyListeners();
        break;
      case PanelPush.closeWindow:
        // Reply before native close tears down this engine's method channel.
        unawaited(
          Future<void>.delayed(Duration.zero, () async {
            await closeRequested?.call();
          }),
        );
    }
    return null;
  }

  void hydrate(Map<String, dynamic> snapshot) {
    appDataDir = snapshot['appDataDir'] as String? ?? appDataDir;
    app.hydrate(snapshot);

    final graph = snapshot['graph'];
    if (graph is Map) {
      _nodes = _parseNodes(graph['nodes']);
      _connections = _parseConnections(graph['connections']);
    }

    final tb = snapshot['toolbox'];
    toolbox = tb is List
        ? tb.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : const <Map<String, dynamic>>[];

    final v = snapshot['video'];
    video = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

    final p = snapshot['props'];
    props = p is Map ? Map<String, dynamic>.from(p) : const <String, dynamic>{};

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

  @override
  void dispose() {
    app.dispose();
    super.dispose();
  }

  // ── 回主窗口的动作 ───────────────────────────────────────────────────

  /// 吸附回主栏：主窗口把面板收回应用内，然后要求本窗口关闭。
  ///
  /// AI 面板的对话必须跟着回去：本窗口一销毁，_AiPanelViewState 里的消息就没了，
  /// 而主窗口的抽屉会重新挂载，只能靠这份消息把对话续上。
  Future<void> dockBack() =>
      MultiWindowService.invokeHost(PanelMethod.dockBack, <String, dynamic>{
        'panel': args.panel.id,
        if (args.panel == DetachedPanel.ai)
          'messages': aiApi?.exportMessages() ?? aiSeed,
      });

  /// 某个节点的参数变了（编辑器是**原地改 map** 的，所以直接整份回传）。
  Future<void> pushParams(PipelineNode node) => MultiWindowService.invokeHost(
    PanelMethod.setParams,
    <String, dynamic>{'nodeId': node.id, 'params': node.params},
  );

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

class _DetachedPanelAppState extends State<DetachedPanelApp>
    with WindowListener {
  late final PanelWindowStore _store = PanelWindowStore(widget.args);

  /// 本次关闭是不是我们自己发起的。
  ///
  /// `windowManager.close()` 会走「先解除拦截、再发原生 close」这条路，而原生
  /// close 事件反过来又会触发 [onWindowClose]。没有这个标志就会自己叫自己，
  /// 无限循环。
  bool _closingSelf = false;
  final Set<String> _loadedFonts = <String>{};

  Future<void> _loadConfiguredFont() async {
    final family = _store.config.fontFamily;
    final dir = _store.appDataDir;
    if (family.isEmpty ||
        dir == null ||
        family.contains('/') ||
        family.contains('\\')) {
      return;
    }
    final sep = Platform.pathSeparator;
    for (final root in [
      Directory('$dir${sep}fonts'),
      Directory(
        '${Directory(Platform.resolvedExecutable).parent.path}${sep}fonts',
      ),
    ]) {
      if (!await root.exists()) continue;
      await for (final entry in root.list()) {
        if (entry is! File) continue;
        final filename = entry.uri.pathSegments.last;
        if (filename != '$family.ttf' && filename != '$family.otf') continue;
        if (!_loadedFonts.add(entry.path)) return;
        try {
          final bytes = await entry.readAsBytes();
          final loader = FontLoader(family);
          loader.addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
          if (mounted) setState(() {});
        } catch (_) {
          _loadedFonts.remove(entry.path);
        }
        return;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChanged);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _store.removeListener(_onChanged);
    _store.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
      unawaited(_loadConfiguredFont());
    }
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
        : (_store.isZh
              ? 'FFmpeg++ · 元素 / 属性'
              : 'FFmpeg++ · Elements / Properties');
    try {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      await windowManager.setTitleBarStyle(
        Platform.isLinux ? TitleBarStyle.hidden : TitleBarStyle.normal,
      );
      await windowManager.setMinimumSize(const Size(280, 360));
      await windowManager.setSize(
        Size(
          widget.args.width > 0 ? widget.args.width : (isAi ? 460 : 380),
          widget.args.height > 0 ? widget.args.height : 800,
        ),
      );
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
    if (Platform.isLinux) return;
    // 再通知一次「窗口已消失」，让主窗口清掉 _openWindows 里的登记 ——
    // 否则下次拖出会去 show() 一个已经不存在的窗口。
    await MultiWindowService.invokeHost(PanelMethod.closed, <String, dynamic>{
      'panel': widget.args.panel.id,
    });
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
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final systemScale = mq.textScaler.scale(14.0) / 14.0;
        final appScale = cfg.fontSize / 14.0;
        final scale = (systemScale * appScale).clamp(
          AppTextScale.minScale,
          AppTextScale.maxScale,
        );
        return AppTextScale(
          systemScale: mq.textScaler.scale(14.0) / 14.0,
          appScale: appScale,
          child: MediaQuery(
            data: mq.copyWith(textScaler: TextScaler.linear(scale)),
            child: ChangeNotifierProvider<AppState>.value(
              value: _store.app,
              child: child!,
            ),
          ),
        );
      },
      home: ChangeNotifierProvider<AppState>.value(
        value: _store.app,
        child: Builder(
          builder: (context) => _store.suspended
              ? const SizedBox.shrink()
              : withWallpaper(
                  context,
                  !_store.ready
                      ? const _Connecting()
                      : widget.args.panel == DetachedPanel.ai
                      ? _AiWindow(store: _store)
                      : _PropsWindow(store: _store),
                ),
        ),
      ),
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

/// System-independent title and window actions; closing docks the panel safely.
class _PanelActionBar extends StatefulWidget {
  const _PanelActionBar({required this.store, required this.title});
  final PanelWindowStore store;
  final String title;

  @override
  State<_PanelActionBar> createState() => _PanelActionBarState();
}

class _PanelActionBarState extends State<_PanelActionBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    if (Platform.isLinux) unawaited(_refreshMaximized());
  }

  Future<void> _refreshMaximized() async {
    final value = await windowManager.isMaximized();
    if (mounted) setState(() => _maximized = value);
  }

  @override
  void onWindowMaximize() => unawaited(_refreshMaximized());
  @override
  void onWindowUnmaximize() => unawaited(_refreshMaximized());

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isZh = widget.store.isZh;
    Widget action(IconData icon, String label, VoidCallback callback) =>
        IconButton(
          tooltip: label,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          iconSize: 16,
          onPressed: callback,
          icon: Icon(icon),
        );
    // Window buttons live outside the drag area so their clicks never move it.
    return withoutAppTextScale(
      context,
      Container(
        height: 36,
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withAlpha(60),
          border: Border(
            bottom: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: DragToMoveArea(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: Platform.isLinux
                      ? () => unawaited(_toggleMaximize())
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.open_in_new,
                          size: 13,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            action(
              Icons.close_fullscreen,
              isZh ? '吸附回主窗口' : 'Dock back',
              () => unawaited(widget.store.dockBack()),
            ),
            if (Platform.isLinux) ...[
              action(
                Icons.remove,
                isZh ? '最小化' : 'Minimize',
                () => unawaited(windowManager.minimize()),
              ),
              action(
                _maximized ? Icons.filter_none : Icons.crop_square,
                isZh
                    ? (_maximized ? '还原' : '最大化')
                    : (_maximized ? 'Restore' : 'Maximize'),
                () => unawaited(_toggleMaximize()),
              ),
              action(
                Icons.close,
                isZh ? '关闭并收回面板' : 'Close and dock panel',
                () => unawaited(widget.store.dockBack()),
              ),
            ],
          ],
        ),
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
            child: LayoutBuilder(
              builder: (ctx, cons) {
                const dividerH = 10.0;
                final usable = (cons.maxHeight - dividerH).clamp(0.0, 1e9);
                final minPaneHeight = usable < 180 ? usable / 2 : 90.0;
                final topH = (usable * _fraction).clamp(
                  minPaneHeight,
                  usable - minPaneHeight,
                );
                return Column(
                  children: [
                    SizedBox(height: topH, child: _toolbox(scheme, s)),
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeRow,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragUpdate: (d) {
                          setState(() {
                            _fraction =
                                ((_fraction * usable + d.delta.dy) / usable)
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
              },
            ),
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
              prefixIconConstraints: const BoxConstraints(
                minWidth: 30,
                minHeight: 30,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 8,
              ),
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
      'container' => (
        Icons.folder_special_outlined,
        s.isZh ? '容器' : 'Container',
      ),
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
              Text(
                label,
                style: TextStyle(fontSize: 11, color: scheme.onSurface),
              ),
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
            Icon(
              Icons.touch_app_outlined,
              size: 30,
              color: scheme.outline.withAlpha(80),
            ),
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

  if (node.isGate && node.gate != null) {
    return Builder(
      builder: (context) => node.gate == LogicGateType.timeTrigger
          ? _buildDetachedTimeTrigger(context, store, node, isZh)
          : _buildDetachedGateInfo(context, store, node, isZh),
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
      final containerName = store.props['containerName'] as String?;
      if (containerName != null) {
        return Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            final count =
                (store.props['containerFileCount'] as num?)?.toInt() ?? 0;
            return Container(
              height: 80,
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withAlpha(60),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.folder_special, size: 32, color: scheme.primary),
                  Text(
                    containerName,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '$count ${isZh ? '个文件' : 'files'}',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ],
              ),
            );
          },
        );
      }
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
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  fit: s('fileMediaType') == MediaType.audio.name
                      ? BoxFit.contain
                      : BoxFit.cover,
                ),
              ),
            ),
          if ((thumb == null || !File(thumb).existsSync()) &&
              store.props['isAudioNoCover'] == true)
            Builder(
              builder: (context) => Container(
                height: 100,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withAlpha(80),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.music_note,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
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
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.subtitle:
      editor = SubtitleStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
        embeddedSubtitles: [
          if (v['subtitles'] is List)
            for (final item in (v['subtitles'] as List).whereType<Map>())
              Map<String, dynamic>.from(item),
        ],
      );
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
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.imageConvert:
      editor = ImageConvertStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.audioConvert:
      editor = AudioConvertStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.audioQuality:
      editor = AudioQualityStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.audioSpeed:
      editor = AudioSpeedStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.audioVolume:
      editor = AudioVolumeStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.audioCompressor:
      editor = AudioCompressorStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.audioMetadata:
      editor = AudioMetadataStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
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
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.imageScale:
      editor = ImageScaleStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.imageBrightness:
      editor = ImageBrightnessStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.imageNoise:
      editor = ImageNoiseStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.imageSharpen:
      editor = ImageSharpenStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.imageDenoise:
      editor = ImageDenoiseStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.imageChannelExtract:
      editor = ImageChannelExtractStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
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
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.videoGeometry:
      editor = VideoGeometryStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.videoOverlay:
      editor = VideoOverlayStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.audioFade:
      editor = AudioFadeStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
    case PipelineStepType.imageAdjust:
      editor = ImageAdjustStepEditor(
        key: ValueKey(node.id),
        params: params,
        onChanged: onChanged,
        isZh: isZh,
      );
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
          _PanelActionBar(
            store: store,
            title: s.isZh ? 'AI 助手' : 'AI Assistant',
          ),
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

Widget _buildDetachedGateInfo(
  BuildContext context,
  PanelWindowStore store,
  PipelineNode node,
  bool isZh,
) {
  final scheme = Theme.of(context).colorScheme;
  final gate = node.gate!;
  final iec = store.config.gateStd == 'iec';
  final zh = isZh;

  final (
    String name,
    String desc,
    List<List<String>> truthTable,
  ) = switch (gate) {
    LogicGateType.and => (
      zh ? '与门 (AND)' : 'AND Gate',
      zh ? '所有输入为 1 时输出 1，否则输出 0' : 'Outputs 1 only when ALL inputs are 1',
      [
        [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
        ['0 · 0', '0'],
        ['0 · 1', '0'],
        ['1 · 0', '0'],
        ['1 · 1', '1'],
      ],
    ),
    LogicGateType.or => (
      zh ? '或门 (OR)' : 'OR Gate',
      zh ? '任一输入为 1 时输出 1，否则输出 0' : 'Outputs 1 when ANY input is 1',
      [
        [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
        ['0 · 0', '0'],
        ['0 · 1', '1'],
        ['1 · 0', '1'],
        ['1 · 1', '1'],
      ],
    ),
    LogicGateType.not => (
      zh ? '非门 (NOT)' : 'NOT Gate',
      zh ? '输入取反：输入 1 输出 0，输入 0 输出 1' : 'Inverts the input signal',
      [
        [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
        ['0', '1'],
        ['1', '0'],
      ],
    ),
    LogicGateType.nand => (
      zh ? '与非门 (NAND)' : 'NAND Gate',
      zh
          ? '与门的取反：所有输入为 1 时输出 0，否则输出 1'
          : 'AND then inverted: outputs 0 only when ALL inputs are 1',
      [
        [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
        ['0 · 0', '1'],
        ['0 · 1', '1'],
        ['1 · 0', '1'],
        ['1 · 1', '0'],
      ],
    ),
    LogicGateType.nor => (
      zh ? '或非门 (NOR)' : 'NOR Gate',
      zh
          ? '或门的取反：任一输入为 1 时输出 0，否则输出 1'
          : 'OR then inverted: outputs 0 when ANY input is 1',
      [
        [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
        ['0 · 0', '1'],
        ['0 · 1', '0'],
        ['1 · 0', '0'],
        ['1 · 1', '0'],
      ],
    ),
    LogicGateType.xor => (
      zh ? '异或门 (XOR)' : 'XOR Gate',
      zh
          ? '输入不同时输出 1，相同时输出 0'
          : 'Outputs 1 when inputs differ, 0 when they match',
      [
        [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
        ['0 · 0', '0'],
        ['0 · 1', '1'],
        ['1 · 0', '1'],
        ['1 · 1', '0'],
      ],
    ),
    LogicGateType.xnor => (
      zh ? '同或门 (XNOR)' : 'XNOR Gate',
      zh
          ? '输入相同时输出 1，不同时输出 0'
          : 'Outputs 1 when inputs match, 0 when they differ',
      [
        [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
        ['0 · 0', '1'],
        ['0 · 1', '0'],
        ['1 · 0', '0'],
        ['1 · 1', '1'],
      ],
    ),
    LogicGateType.const1 => (
      zh ? '恒 1 (HIGH)' : 'Constant 1 (HIGH)',
      zh ? '恒定输出 1，无需输入，常用于强制启用下游' : 'Always outputs 1, no inputs needed',
      [
        [zh ? '输出' : 'OUT'],
        ['1'],
      ],
    ),
    LogicGateType.const0 => (
      zh ? '恒 0 (LOW)' : 'Constant 0 (LOW)',
      zh ? '恒定输出 0，无需输入，常用于禁用下游' : 'Always outputs 0, no inputs needed',
      [
        [zh ? '输出' : 'OUT'],
        ['0'],
      ],
    ),
    // [FIX C1] 时间触发器走的是 _buildTimeTriggerEditor（见 _buildStepEditor 的
    // 提前 return），这一支实际不可达。但 switch 必须穷尽枚举，所以保留为
    // **防御性兜底**：真被以别的方式调用到时也应给出可读文案，而不是原来的
    // 空描述 + 空真值表。真值表由 _buildTimeTriggerEditor 负责展示。
    LogicGateType.timeTrigger => (
      zh ? '时间触发器' : 'Time Trigger',
      zh
          ? '系统时间命中设定区间时输出 1，否则输出 0'
          : 'Outputs 1 while the system clock is inside the configured window',
      const [],
    ),
  };

  return SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题 + 符号
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer.withAlpha(160),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.tertiary.withAlpha(100)),
              ),
              child: _gateIcon(gate, iec, scheme, width: 44, height: 44),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.outline,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 12),

        // 端口信息
        _infoRow(
          scheme,
          Icons.login,
          zh ? '输入端口' : 'Inputs',
          gate.isConstant
              ? (zh ? '无（恒值输出）' : 'None (constant output)')
              : '${gate.inputCount} × ${zh ? '红色逻辑端口' : 'red logic port'}',
        ),
        const SizedBox(height: 8),
        _infoRow(
          scheme,
          Icons.logout,
          zh ? '输出端口' : 'Output',
          zh ? '1 × 右侧红色逻辑端口' : '1 × red logic port on the right',
        ),

        // 真值表
        if (truthTable.length > 1) ...[
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Text(
            zh ? '真值表' : 'Truth Table',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Center(child: _truthTable(scheme, truthTable)),
        ],
      ],
    ),
  );
}

Widget _infoRow(ColorScheme scheme, IconData icon, String label, String value) {
  return Row(
    children: [
      Icon(icon, size: 14, color: scheme.primary),
      const SizedBox(width: 6),
      Text(
        label,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      const Spacer(),
      Flexible(
        child: Text(
          value,
          textAlign: TextAlign.right,
          style: TextStyle(fontSize: 12, color: scheme.onSurface),
        ),
      ),
    ],
  );
}

Widget _truthTable(ColorScheme scheme, List<List<String>> rows) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withAlpha(60),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Table(
      columnWidths: const {0: FlexColumnWidth(), 1: FlexColumnWidth()},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder.all(
        color: scheme.outlineVariant.withAlpha(80),
        width: 0.8,
      ),
      children: [
        for (var i = 0; i < rows.length; i++)
          TableRow(
            decoration: BoxDecoration(
              color: i == 0 ? scheme.primaryContainer.withAlpha(120) : null,
            ),
            children: rows[i]
                .map(
                  (cell) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Text(
                      cell,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: i == 0
                            ? scheme.onPrimaryContainer
                            : scheme.onSurface,
                        fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w400,
                        fontFamily: AppTheme.monoFont,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
      ],
    ),
  );
}

DateTime? _parseDate(String s) {
  final parts = s.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

int _parseHM(String hm) {
  final parts = hm.split(':');
  if (parts.length != 2) return -1;
  return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}

Widget _buildDetachedTimeTrigger(
  BuildContext context,
  PanelWindowStore store,
  PipelineNode node,
  bool isZh,
) {
  final scheme = Theme.of(context).colorScheme;
  final now = DateTime.now();
  var dateStr = (node.params['tt_date'] as String?) ?? '';
  final startStr = (node.params['tt_start'] as String?) ?? '09:00';
  final endStr = (node.params['tt_end'] as String?) ?? '';
  final startHM = _parseHM(startStr);
  var startTime = startHM >= 0
      ? TimeOfDay(hour: startHM ~/ 60, minute: startHM % 60)
      : const TimeOfDay(hour: 9, minute: 0);
  final endHM = _parseHM(endStr);
  var endTime = endHM >= 0
      ? TimeOfDay(hour: endHM ~/ 60, minute: endHM % 60)
      : null;

  void doSave() {
    node.params['tt_date'] = dateStr;
    node.params['tt_start'] =
        '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}';
    if (endTime != null) {
      node.params['tt_end'] =
          '${endTime!.hour.toString().padLeft(2, '0')}:${endTime!.minute.toString().padLeft(2, '0')}';
    } else {
      node.params.remove('tt_end');
    }
    unawaited(store.pushParams(node));
  }

  return StatefulBuilder(
    builder: (ctx, setDlg) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 日期卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withAlpha(50),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.primary.withAlpha(60)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.calendar_today_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isZh ? '日期' : 'Date',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      GestureDetector(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: _parseDate(dateStr) ?? now,
                            firstDate: DateTime(now.year - 1),
                            lastDate: DateTime(now.year + 2),
                          );
                          if (picked != null) {
                            setDlg(
                              () => dateStr =
                                  '${picked.year.toString().padLeft(4, '0')}-'
                                  '${picked.month.toString().padLeft(2, '0')}-'
                                  '${picked.day.toString().padLeft(2, '0')}',
                            );
                            doSave();
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surface.withAlpha(160),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            dateStr.isEmpty
                                ? (isZh ? '每天（不限日期）' : 'Every day (no date)')
                                : dateStr,
                            style: TextStyle(
                              fontSize: 12,
                              color: dateStr.isEmpty
                                  ? scheme.outline
                                  : scheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (dateStr.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setDlg(() => dateStr = '');
                      doSave();
                    },
                    tooltip: isZh ? '清除日期' : 'Clear',
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 起始时间卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer.withAlpha(50),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.secondary.withAlpha(60)),
            ),
            child: Row(
              children: [
                Icon(Icons.play_arrow, size: 18, color: scheme.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isZh ? '起始时间' : 'Start Time',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      GestureDetector(
                        onTap: () async {
                          final t = await showTimePicker(
                            context: ctx,
                            initialTime: startTime,
                            initialEntryMode: TimePickerEntryMode.input,
                          );
                          if (t != null) {
                            setDlg(() => startTime = t);
                            doSave();
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surface.withAlpha(160),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.schedule, size: 14),
                              const SizedBox(width: 4),
                              Text(
                                '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 结束时间卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: endTime != null
                  ? scheme.tertiaryContainer.withAlpha(50)
                  : scheme.surfaceContainerHighest.withAlpha(30),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: endTime != null
                    ? scheme.tertiary.withAlpha(60)
                    : scheme.outlineVariant.withAlpha(60),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.stop,
                  size: 18,
                  color: endTime != null ? scheme.tertiary : scheme.outline,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isZh ? '结束时间' : 'End Time',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (endTime == null)
                        GestureDetector(
                          onTap: () {
                            setDlg(
                              () => endTime = TimeOfDay(
                                hour: startTime.hour,
                                minute: (startTime.minute + 1) % 60,
                              ),
                            );
                            doSave();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surface.withAlpha(160),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isZh ? '精确时刻（无结束时间）' : 'Exact moment (no end)',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.outline,
                              ),
                            ),
                          ),
                        )
                      else
                        Row(
                          children: [
                            GestureDetector(
                              onTap: () async {
                                final t = await showTimePicker(
                                  context: ctx,
                                  initialTime: endTime!,
                                  initialEntryMode: TimePickerEntryMode.input,
                                );
                                if (t != null) {
                                  setDlg(() => endTime = t);
                                  doSave();
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.surface.withAlpha(160),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.schedule, size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${endTime!.hour.toString().padLeft(2, '0')}:${endTime!.minute.toString().padLeft(2, '0')}',
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: () {
                                setDlg(() => endTime = null);
                                doSave();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.error.withAlpha(30),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Icon(
                                  Icons.close,
                                  size: 14,
                                  color: scheme.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 说明
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withAlpha(60),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 14, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isZh
                        ? '当系统时间匹配日期和起始时间范围时，输出 1（控制信号高电平），否则输出 0。'
                              '无结束时间时，仅在起始时精确时刻输出 1。'
                        : 'Outputs 1 (control signal HIGH) when system time matches the date and time range. '
                              'Without end time, outputs 1 at the exact start time.',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.outline,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _gateIcon(
  LogicGateType gate,
  bool iec,
  ColorScheme scheme, {
  required double width,
  required double height,
}) {
  if (!iec) {
    final name = switch (gate) {
      LogicGateType.and => 'and',
      LogicGateType.or => 'or',
      LogicGateType.not => 'not',
      LogicGateType.nand => 'nand',
      LogicGateType.nor => 'nor',
      LogicGateType.xor => 'xor',
      LogicGateType.xnor => 'xnor',
      _ => null,
    };
    if (name != null) {
      return SvgPicture.asset(
        'rele/logic_gates/$name.svg',
        width: width,
        height: height,
        colorFilter: ColorFilter.mode(
          scheme.onTertiaryContainer,
          BlendMode.srcIn,
        ),
      );
    }
  }
  return CustomPaint(
    size: Size(width, height),
    painter: GateSymbolPainter(
      gate: gate,
      iec: iec,
      color: scheme.onTertiaryContainer,
    ),
  );
}

class _RemoteAiOps {
  _RemoteAiOps(this.store);

  final PanelWindowStore store;

  static Future<dynamic> _invoke(String method, Map<String, dynamic> args) =>
      MultiWindowService.invokeHost(method, args);

  void apply(List<PipelineNode> nodes, List<PipelineConnection> connections) {
    unawaited(
      _invoke(PanelMethod.graphApply, <String, dynamic>{
        'nodes': [for (final n in nodes) n.toJson()],
        'connections': [for (final c in connections) c.toJson()],
        'merge': false,
      }),
    );
  }

  void merge(List<PipelineNode> nodes, List<PipelineConnection> connections) {
    unawaited(
      _invoke(PanelMethod.graphApply, <String, dynamic>{
        'nodes': [for (final n in nodes) n.toJson()],
        'connections': [for (final c in connections) c.toJson()],
        'merge': true,
      }),
    );
  }

  bool modifyParams(String nodeId, Map<String, dynamic> params) {
    unawaited(
      _invoke(PanelMethod.graphModify, <String, dynamic>{
        'nodeId': nodeId,
        'params': params,
      }),
    );
    return true;
  }

  void clearAll() => unawaited(_invoke(PanelMethod.graphClearAll, const {}));

  void undo() => unawaited(_invoke(PanelMethod.graphUndo, const {}));

  void redo() => unawaited(_invoke(PanelMethod.graphRedo, const {}));

  void save() => unawaited(_invoke(PanelMethod.graphSave, const {}));

  String addNode(String type, double x, double y) {
    final id = const Uuid().v4();
    unawaited(
      _invoke(PanelMethod.addNode, <String, dynamic>{
        'typeId': type,
        'x': x,
        'y': y,
        'nodeId': id,
      }),
    );
    return id;
  }

  String addGate(String gateName, double x, double y) {
    final id = const Uuid().v4();
    unawaited(
      _invoke(PanelMethod.graphAddGate, <String, dynamic>{
        'gate': gateName,
        'x': x,
        'y': y,
        'nodeId': id,
      }),
    );
    return id;
  }

  bool setGateParams(String nodeId, Map<String, dynamic> params) {
    unawaited(
      _invoke(PanelMethod.graphSetGateParams, <String, dynamic>{
        'nodeId': nodeId,
        'params': params,
      }),
    );
    return true;
  }

  void deleteNode(String nodeId) => unawaited(
    _invoke(PanelMethod.graphDeleteNode, <String, dynamic>{'nodeId': nodeId}),
  );

  bool connectNodes(String fromId, String toId) {
    unawaited(
      _invoke(PanelMethod.graphConnect, <String, dynamic>{
        'fromId': fromId,
        'toId': toId,
      }),
    );
    return true;
  }

  bool disconnectNodes(String connId) {
    unawaited(
      _invoke(PanelMethod.graphDisconnect, <String, dynamic>{'connId': connId}),
    );
    return true;
  }

  void cancelTasks() =>
      unawaited(_invoke(PanelMethod.graphCancelTasks, const {}));
}
