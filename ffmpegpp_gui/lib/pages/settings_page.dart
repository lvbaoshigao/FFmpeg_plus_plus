import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/masonry_grid.dart';
import '../widgets/install_dialog.dart';
import 'keybinding_page.dart';
import 'command_page.dart';
import 'log_page.dart';
import 'credits_page.dart';
import '../platform/app_platform.dart';
import '../widgets/font_picker.dart';
import '../services/ffmpeg_installer.dart';
import '../services/update_service.dart' as updater;
import '../services/shell_open.dart';
import '../widgets/toast.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_glass_pill.dart';
import '../widgets/mobile_top_bar.dart';
import '../app.dart' show wallpaperImageProvider;

final _s = Platform.pathSeparator;

/// 应用文档目录（Android 持久化，避免 systemTemp 被系统清空）
String _androidAppDir() => _cachedAppDir;
String _cachedAppDir = '${Directory.systemTemp.path}${_s}FFmpeg++';
bool _appDirInit = false;

/// 初始化 Android 应用文档目录（在 SettingsPage 首次构建时调用）
Future<void> _ensureAndroidAppDir() async {
  if (_appDirInit) return;
  _appDirInit = true;
  try {
    final dir = await getApplicationDocumentsDirectory();
    _cachedAppDir = '${dir.path}${_s}FFmpeg++';
  } catch (_) {}
}

/// 获取用户数据目录，避免 Program Files 权限问题
String _userDataDir() {
  if (Platform.isAndroid) {
    // Android：使用 path_provider 的应用文档目录（持久化，不会被系统清空）
    return _androidAppDir();
  } else if (Platform.isWindows) {
    return '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}${_s}FFmpeg++';
  } else if (Platform.isMacOS) {
    return '${Platform.environment['HOME'] ?? '/tmp'}/Library/Application Support/FFmpeg++';
  } else {
    final base = Platform.environment['XDG_DATA_HOME'] ??
        '${Platform.environment['HOME'] ?? '/tmp'}$_s.local${_s}share';
    return '$base${_s}FFmpeg++';
  }
}

/// 复制文件到用户数据目录下的子文件夹，返回新路径（失败返回 null）
Future<String?> _copyToAppDir(String srcPath, String subDir) async {
  try {
    final targetDir = Directory('${_userDataDir()}$_s$subDir');
    if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
    final fileName = srcPath.split(RegExp(r'[\\/]')).last;
    final destPath = '${targetDir.path}$_s$fileName';
    final srcFile = File(srcPath);
    if (srcFile.existsSync()) {
      await srcFile.copy(destPath);
      return destPath;
    }
  } catch (_) {}
  return null;
}

/// 壁纸优化复制：识别屏幕分辨率，若原图大于屏幕分辨率则先解码缩放到
/// 屏幕大小并重编码为 PNG 再保存 —— 减小体积、避免大图导致添加后卡死/
/// 内存暴涨。返回保存路径（失败回退为普通复制）。
///
/// [maxW]/[maxH] 为目标物理像素分辨率，调用方在 async 前从 View 同步取得，
/// 避免 BuildContext 跨 async gap。
Future<String?> _copyBackgroundOptimized(String srcPath, int maxW, int maxH) async {
  try {
    final srcFile = File(srcPath);
    if (!srcFile.existsSync()) return null;
    final bytes = await srcFile.readAsBytes();

    // 用 dart:ui 解码原图，获取实际尺寸
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final srcW = image.width;
    final srcH = image.height;
    codec.dispose();

    // 原图小于等于屏幕分辨率：无需缩放，直接走普通复制
    if (srcW <= maxW && srcH <= maxH) {
      image.dispose();
      return await _copyToAppDir(srcPath, 'background');
    }

    // 等比缩放到屏幕分辨率内（长边对齐），scale 单一化确保两个方向缩放一致、绝不拉伸
    final scale = math.min(maxW / srcW, maxH / srcH);
    final targetW = math.max(1, (srcW * scale).round());
    final targetH = math.max(1, (srcH * scale).round());

    // 缩放 + 编码（高质量重采样避免下采样变糊；PNG 无损）
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(scale, scale);
    canvas.drawImage(image, ui.Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.high);
    final picture = recorder.endRecording();
    final resized = await picture.toImage(targetW, targetH);
    picture.dispose();
    image.dispose();

    final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    resized.dispose();
    if (byteData == null) return await _copyToAppDir(srcPath, 'background');

    // 保存为 .png（与原文件名区分，避免覆盖源图）
    final targetDir = Directory('${_userDataDir()}$_s${'background'}');
    if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
    final baseName = srcPath.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');
    final destPath = '${targetDir.path}$_s${baseName}_opt.png';
    await File(destPath).writeAsBytes(byteData.buffer.asUint8List(), flush: true);
    return destPath;
  } catch (_) {
    // 解码/缩放失败（如超大图内存不足）：回退普通复制
    return await _copyToAppDir(srcPath, 'background');
  }
}

/// 从内存字节保存背景图（Android 11+ content:// URI 场景：picker 返回 bytes 而非路径）。
/// 解码后用 [maxW]/[maxH] 限制最大尺寸，重编码为 PNG 存入应用文档目录。
Future<String?> _saveBackgroundBytes(Uint8List bytes, String fileName, int maxW, int maxH) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final srcW = image.width;
    final srcH = image.height;
    codec.dispose();

    // 原图小于等于屏幕分辨率：直接保存原始字节
    if (srcW <= maxW && srcH <= maxH) {
      image.dispose();
      return await _saveRawBackground(bytes, fileName);
    }

    // 等比缩放到屏幕分辨率内（长边对齐），scale 单一化确保两个方向缩放一致、绝不拉伸
    final scale = math.min(maxW / srcW, maxH / srcH);
    final targetW = math.max(1, (srcW * scale).round());
    final targetH = math.max(1, (srcH * scale).round());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(scale, scale);
    canvas.drawImage(image, ui.Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.high);
    final picture = recorder.endRecording();
    final resized = await picture.toImage(targetW, targetH);
    picture.dispose();
    image.dispose();

    final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    resized.dispose();
    if (byteData == null) return await _saveRawBackground(bytes, fileName);
    return await _saveRawBackground(byteData.buffer.asUint8List(), '${fileName}_opt');
  } catch (_) {
    return await _saveRawBackground(bytes, fileName);
  }
}

/// 把背景字节直接写入应用文档目录 background/ 下，返回绝对路径（失败返回 null）
Future<String?> _saveRawBackground(Uint8List bytes, String name) async {
  try {
    final targetDir = Directory('${_userDataDir()}$_s${'background'}');
    if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
    final safeName = name.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final destPath = '${targetDir.path}$_s$safeName';
    if (!File(destPath).existsSync() || !_sameBytes(destPath, bytes)) {
      await File(destPath).writeAsBytes(bytes, flush: true);
    }
    return destPath;
  } catch (_) {
    return null;
  }
}

/// 快速判断目标文件内容是否与字节一致（避免重复写盘）
bool _sameBytes(String path, Uint8List bytes) {
  try {
    final f = File(path);
    if (!f.existsSync()) return false;
    // 先比较长度（快速路径），再比较内容（避免同长度不同文件被误判）
    if (f.lengthSync() != bytes.length) return false;
    final existing = f.readAsBytesSync();
    for (int i = 0; i < bytes.length; i++) {
      if (existing[i] != bytes[i]) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// 用系统默认浏览器打开链接。见 [ShellOpen] 里关于 `cmd /c start` 注入的说明。
Future<void> openExternalUrl(String url) => ShellOpen.url(url);

/// 二级设置页也铺设壁纸背景（与主界面一致），避免返回手势/过渡时露出黑底或主题色底。
/// 无壁纸时直接返回 child（透明 Scaffold 自行透出上层背景）。
Widget _withWallpaper(BuildContext ctx, AppState state, Widget child) {
  final bg = state.config.backgroundImage;
  if (bg.isEmpty || !File(bg).existsSync()) return child;
  final scheme = Theme.of(ctx).colorScheme;
  final op = state.config.backgroundOpacity.clamp(0.0, 1.0);
  final a = ((1.0 - op) * 220).round().clamp(20, 240);
  final size = MediaQuery.sizeOf(ctx);
  final dpr = MediaQuery.devicePixelRatioOf(ctx);
  return Stack(children: [
    Positioned.fill(child: Image(
      image: wallpaperImageProvider(bg, size.width, size.height, dpr),
      fit: BoxFit.cover,
      errorBuilder: (_, a, b) => const SizedBox.shrink(),
    )),
    Positioned.fill(child: Container(color: scheme.surface.withAlpha(a))),
    Theme(
      data: Theme.of(ctx).copyWith(scaffoldBackgroundColor: Colors.transparent),
      child: child,
    ),
  ]);
}

// ═══════════════════════════════════════════
// 设置项元数据 —— 分区 / 卡片 / 搜索关键字
// ═══════════════════════════════════════════

class _CardDef {
  final String id;
  final String Function(AppStrings) title;

  /// 额外的搜索关键字（中英文都写，全小写）。卡片标题会自动并入搜索范围。
  final List<String> keywords;
  final Widget Function(BuildContext, AppState) build;

  const _CardDef({
    required this.id,
    required this.title,
    required this.keywords,
    required this.build,
  });

  /// 中英文标题 + 关键字都参与匹配，这样无论界面当前是哪种语言，
  /// 输入 "font" 或 "字体" 都能命中同一张卡片。
  bool matches(String query) {
    if (query.isEmpty) return true;
    if (title(AppStrings.zh).toLowerCase().contains(query)) return true;
    if (title(AppStrings.en).toLowerCase().contains(query)) return true;
    for (final k in keywords) {
      if (k.contains(query)) return true;
    }
    return false;
  }
}

class _SectionDef {
  final String id;
  final String Function(AppStrings) title;
  final IconData icon;
  final List<_CardDef> cards;
  const _SectionDef({required this.id, required this.title, required this.icon, required this.cards});
}

// ═══════════════════════════════════════════
// 设置页
// ═══════════════════════════════════════════

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  static void showUpdateDialogStatic(BuildContext ctx, AppStrings s, updater.UpdateResult result) {
    _showUpdateDialog(ctx, s, result);
  }

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';
  /// 移动端搜索是否展开（内联展开在顶栏下方，而非弹出对话框）。
  bool _searchExpanded = false;

  /// 被折叠起来的分区 id。默认全部展开。
  final Set<String> _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    if (isAndroidPlatform) _ensureAndroidAppDir();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _query = '');
  }

  void _toggleSection(String id) {
    setState(() {
      if (!_collapsed.remove(id)) _collapsed.add(id);
    });
  }

  void _setAllCollapsed(bool collapsed) {
    setState(() {
      _collapsed.clear();
      if (collapsed) _collapsed.addAll(_sections.map((s) => s.id));
    });
  }

  static final List<_SectionDef> _sections = [
    _SectionDef(
      id: 'appearance',
      title: (s) => s.secAppearance,
      icon: Icons.palette_outlined,
      cards: [
        _CardDef(
          id: 'theme',
          title: (s) => s.cardTheme,
          keywords: ['深色', '暗色', '浅色', 'dark', 'light', 'mode', '模式',
              '主题色', '强调色', '颜色', 'accent', 'color', 'theme'],
          build: _buildTheme,
        ),
        _CardDef(
          id: 'background',
          title: (s) => s.cardBackground,
          keywords: ['背景', '壁纸', '图片', 'background', 'wallpaper', 'image',
              '不透明度', '透明', 'opacity', '卡片', 'card', 'blur', '毛玻璃'],
          build: _buildBackground,
        ),
        _CardDef(
          id: 'font',
          title: (s) => s.font,
          keywords: ['字体', '字号', '字重', 'font', 'size', 'weight',
              'typeface', '导入', 'import', '大小'],
          build: _buildFont,
        ),
        _CardDef(
          id: 'language',
          title: (s) => s.language,
          keywords: ['语言', '界面', '中文', 'language', 'english', 'chinese',
              'interface', 'locale', 'i18n'],
          build: _buildLanguage,
        ),
      ],
    ),
    _SectionDef(
      id: 'processing',
      title: (s) => s.secProcessing,
      icon: Icons.movie_filter_outlined,
      cards: [
        // 移动端 ffmpeg/ffprobe 已内置在 APK（jniLibs），无需展示安装/路径设置
        if (!isMobilePlatform)
          _CardDef(
            id: 'ffmpeg',
            title: (s) => s.ffmpegSettings,
            keywords: ['ffmpeg', 'ffprobe', '编码', 'codec', '安装', 'install',
                '检测', 'detect', '路径', 'path', '下载', 'download'],
            build: (ctx, state) => _FfmpegCard(state: state),
          ),
        _CardDef(
          id: 'output',
          title: (s) => s.output,
          keywords: ['输出', '目录', '文件夹', 'output', 'directory', 'folder',
              '中间', 'intermediate', '临时', 'temp', 'path', '路径'],
          build: _buildOutput,
        ),
        _CardDef(
          id: 'tasks',
          title: (s) => s.cardTasks,
          keywords: ['任务', '并发', '同时', '线程', 'task', 'concurrent',
              'parallel', 'thread', '解析', 'probe', '通知', 'notification',
              '队列', 'queue'],
          build: _buildTasks,
        ),
      ],
    ),
    _SectionDef(
      id: 'editor',
      title: (s) => s.secEditor,
      icon: Icons.account_tree_outlined,
      cards: [
        _CardDef(
          id: 'editorMode',
          title: (s) => s.cardEditorMode,
          keywords: ['编辑', '编辑器', '节点', '画布', '蓝图', '传统',
              'editor', 'node', 'canvas', 'blueprint', 'classic', 'mode', '模式'],
          build: _buildEditorMode,
        ),
        // 移动端无物理键盘，快捷键编辑无意义 —— 隐藏该设置项
        if (!isMobilePlatform)
          _CardDef(
            id: 'shortcuts',
            title: (s) => s.cardShortcuts,
            keywords: ['快捷键', '键位', '按键', '热键', 'shortcut', 'keybinding',
                'keyboard', 'hotkey', 'key'],
            build: _buildShortcuts,
          ),
        _CardDef(
          id: 'autosave',
          title: (s) => s.cardAutosave,
          keywords: ['自动保存', '草稿', '恢复', 'autosave', 'draft', 'autosave',
              'auto', 'save', '恢复'],
          build: _buildAutosave,
        ),
      ],
    ),
    // 移动端专用：命令与日志从底部导航移入设置（避免底部元素过多）
    if (isMobilePlatform)
      _SectionDef(
        id: 'tools',
        title: (s) => s.isZh ? '工具' : 'Tools',
        icon: Icons.handyman_outlined,
        cards: [
          _CardDef(
            id: 'command',
            title: (s) => s.navCommand,
            keywords: ['命令', 'ffmpeg', 'command', 'terminal', '终端', '执行', 'run', '模板', 'template'],
            build: _buildMobileCommandEntry,
          ),
          _CardDef(
            id: 'logs',
            title: (s) => s.qLogs,
            keywords: ['日志', 'log', 'logs', '输出', 'output', '进度', 'progress', '调试', 'debug'],
            build: _buildMobileLogsEntry,
          ),
        ],
      ),
    _SectionDef(
      id: 'ai',
      title: (s) => s.secAi,
      icon: Icons.auto_awesome_outlined,
      cards: [
        _CardDef(
          id: 'ai',
          title: (s) => s.mcpTitle,
          keywords: ['ai', 'mcp', '模型', 'model', 'api', 'key', 'token',
              'openai', 'anthropic', 'claude', 'gpt', '提示词', 'prompt',
              '权限', 'permission', '助手', 'assistant', '端口', 'port', '服务'],
          build: _buildMcpAi,
        ),
      ],
    ),
    _SectionDef(
      id: 'advanced',
      title: (s) => s.secAdvanced,
      icon: Icons.tune_outlined,
      cards: [
        // 预测式返回手势（仅 Android 端）
        if (isAndroidPlatform)
          _CardDef(
            id: 'predictiveBack',
            title: (s) => s.predictiveBack,
            keywords: ['返回', '手势', '预测', '侧滑', 'back', 'gesture',
                'predictive', 'swipe', '返回动画', '系统', 'system'],
            build: _buildPredictiveBack,
          ),
        _CardDef(
          id: 'update',
          title: (s) => s.cardUpdate,
          keywords: ['更新', '升级', '版本', 'update', 'upgrade', 'version',
              '自动', 'auto', 'check', '检查'],
          build: _buildUpdate,
        ),
        _CardDef(
          id: 'debug',
          title: (s) => s.dDebug,
          keywords: ['调试', '日志', '诊断', 'debug', 'log', 'logs',
              'verbose', 'diagnostic', '保存', 'save'],
          build: _buildDebug,
        ),
        _CardDef(
          id: 'cache',
          title: (s) => s.cardCache,
          keywords: ['缓存', '清除', '清理', '删除', 'cache', 'clear',
              'clean', 'cleanup', 'purge', 'reset'],
          build: _buildCache,
        ),
      ],
    ),
    _SectionDef(
      id: 'about',
      title: (s) => s.secAbout,
      icon: Icons.info_outline,
      cards: [
        _CardDef(
          id: 'about',
          title: (s) => s.aboutTitle,
          keywords: ['关于', '版本', '赞助', '捐赠', '许可', 'about', 'version',
              'sponsor', 'donate', 'license', 'github', 'blog', '作者', 'author'],
          build: _buildAbout,
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final s = AppStrings.of(state.config.language);
        final scheme = Theme.of(context).colorScheme;

        if (isMobilePlatform) {
          // ═══════════════════════════════════════
          // 移动端独立设置界面
          // ═══════════════════════════════════════
          final query = _query.trim().toLowerCase();
          final searching = query.isNotEmpty;
          final visible = <(_SectionDef, List<_CardDef>)>[];
          for (final sec in _sections) {
            final hits = sec.cards.where((c) => c.matches(query)).toList();
            if (hits.isNotEmpty) visible.add((sec, hits));
          }

          return Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(children: [
              // 全屏可滚动的设置列表（顶部留出药丸空间）
              // RepaintBoundary 防止边界滚动时 BackdropFilter 失效导致模糊消失
              if (visible.isEmpty && searching)
                _emptyState(scheme, s)
              else
                RepaintBoundary(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(6, MediaQuery.of(context).padding.top + 60, 6, kMobileNavClearance),
                    children: [
                      for (final (sec, cards) in visible)
                        _buildMobileSection(sec, cards, context, state, scheme, s),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              // 顶部药丸浮层（不影响滚动）
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildMobileTopBar(s, scheme),
              ),
            ]),
          );
        }

        // ═══════════════════════════════════════
        // 桌面端原有设置界面
        // ═══════════════════════════════════════
        final query = _query.trim().toLowerCase();
        final searching = query.isNotEmpty;

        // 只保留有命中卡片的分区
        final visible = <(_SectionDef, List<_CardDef>)>[];
        for (final sec in _sections) {
          final hits = sec.cards.where((c) => c.matches(query)).toList();
          if (hits.isNotEmpty) visible.add((sec, hits));
        }
        final allCollapsed = _collapsed.length >= _sections.length;

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(children: [
            GlassTopBar(
              title: Text(s.settingsTitle),
              center: _searchField(scheme, s),
              actions: [
                if (visible.isNotEmpty && searching == false)
                  IconButton(
                    icon: Icon(allCollapsed ? Icons.unfold_more : Icons.unfold_less,
                        size: 19, color: scheme.outline),
                    tooltip: allCollapsed ? s.setExpandAll : s.setCollapseAll,
                    onPressed: () => _setAllCollapsed(!allCollapsed),
                  ),
              ],
            ),
            Expanded(
              child: visible.isEmpty
                  ? _emptyState(scheme, s)
                  : LayoutBuilder(builder: (ctx, cons) {
                      // 窄窗口单列，宽窗口最多三列
                      final cols = cons.maxWidth < 640 ? 1 : (cons.maxWidth < 1100 ? 2 : 3);
                      return CustomScrollView(
                        slivers: [
                          for (final (sec, cards) in visible)
                            SliverMainAxisGroup(slivers: [
                              SliverPersistentHeader(
                                pinned: true,
                                delegate: _SectionHeaderDelegate(
                                  title: sec.title(s),
                                  icon: sec.icon,
                                  scheme: scheme,
                                  // 搜索时强制展开，否则命中的卡片会被折叠状态藏起来
                                  collapsed: !searching && _collapsed.contains(sec.id),
                                  count: cards.length,
                                  toggleTooltip: _collapsed.contains(sec.id) ? s.setExpand : s.setCollapse,
                                  onToggle: searching ? null : () => _toggleSection(sec.id),
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: AnimatedSize(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.topCenter,
                                  child: (!searching && _collapsed.contains(sec.id))
                                      ? const SizedBox(width: double.infinity, height: 0)
                                      : AnimatedOpacity(
                                          duration: const Duration(milliseconds: 220),
                                          curve: Curves.easeOut,
                                          opacity: 1,
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                                            child: MasonryGrid(
                                              columns: cols,
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                for (final c in cards)
                                                  RepaintBoundary(
                                                    key: ValueKey(c.id),
                                                    child: c.build(ctx, state),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                            ]),
                          const SliverToBoxAdapter(child: SizedBox(height: 24)),
                        ],
                      );
                    }),
            ),
          ]),
        );
      },
    );
  }

  // ── 移动端专用 ──

  /// 移动端顶栏：液态玻璃药丸——左标题药丸 + 右搜索药丸；
  /// 点击搜索后使用 AnimatedContainer 平滑展开，无卡顿。
  Widget _buildMobileTopBar(AppStrings s, ColorScheme scheme) {
    final safeTop = MediaQuery.of(context).padding.top;
    final searching = _searchExpanded;

    // 顶栏改成 Stack：常规层（左标题药丸 + 右搜索按钮药丸）搜索时整体淡出+缩放
    // （仍占位），让搜索药丸能真正水平居中；搜索药丸单独叠一层，常态 44px
    // 折叠、搜索时 AnimatedSize「变长」到 200px 并水平居中。宽度固定 200，
    // 不再用 Expanded 把输入框撑满整行。
    return Padding(
      padding: EdgeInsets.fromLTRB(8, safeTop + 6, 8, 6),
      child: Stack(alignment: Alignment.center, children: [
        // 常规状态：左标题药丸 + 右搜索按钮药丸
        AnimatedOpacity(
          opacity: searching ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 220),
          child: AnimatedScale(
            scale: searching ? 0.9 : 1.0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: IgnorePointer(
              ignoring: searching,
              child: Padding(
                padding: const EdgeInsets.only(top: 0, bottom: 6),
                child: Row(children: [
                  MobileGlassPill(
                    radius: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    pressable: true,
                    child: Text(s.settingsTitle,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                  ),
                  const Spacer(),
                  MobileGlassPill(
                    radius: 22,
                    padding: EdgeInsets.zero,
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: IconButton(
                        icon: Icon(Icons.search, size: 20, color: scheme.onSurface),
                        tooltip: s.setSearchHint,
                        onPressed: () {
                          setState(() => _searchExpanded = true);
                          WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
        // 搜索状态：同一搜索药丸从 44px「变长」到 200px（AnimatedSize）并水平居中
        AnimatedOpacity(
          opacity: searching ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 220),
          child: IgnorePointer(
            ignoring: !searching,
            child: Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 6),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                alignment: Alignment.center,
                child: searching
                    ? MobileGlassPill(
                        radius: 22,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                        child: _buildSearchField(s, scheme),
                      )
                    : const SizedBox(width: 44, height: 44),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  /// 搜索输入框：嵌在 MobileGlassPill 内部，不再使用 Material outline 边框。
  /// Material3 TextField 在 focus 时会按 theme primary 画下划线；显式清空所有
  /// border（focused / enabled / disabled / hovered），只保留液态玻璃药丸作为容器。
  Widget _buildSearchField(AppStrings s, ColorScheme scheme) {
    return SizedBox(
      width: 200,
      height: 44,
      child: Row(children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: Icon(
            Icons.search,
            key: const ValueKey('settings-search-icon'),
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
            cursorColor: scheme.onSurfaceVariant,
            decoration: InputDecoration(
              hintText: s.setSearchHint,
              hintStyle: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
              // 彻底清掉所有状态下的主题色边框：液态玻璃药丸本身就是容器，
              // 不再让 Material3 给一个 primary 色的下划线 / 轮廓。
              border: InputBorder.none,
              focusedBorder: InputBorder.none,
              enabledBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              isCollapsed: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 13),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        // 关闭按钮
        IconButton(
          icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
          tooltip: s.setClearSearch,
          onPressed: () {
            setState(() {
              _searchExpanded = false;
              _searchCtrl.clear();
              _query = '';
            });
            _searchFocus.unfocus();
          },
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        const SizedBox(width: 4),
      ]),
    );
  }

  /// 移动端设置分区：Android 16 原生设置风格 —— 小号字重标题，
  /// 无图标、无着色，仅灰色文字（onSurfaceVariant），下方为卡片项。
  /// Android 16 风格移动端分区：一级菜单只展示「标题在左、开关/箭头在右」的
  /// 设置行，统一放在一张圆角卡片内，条目间用细分隔线；具体设置项进入二级菜单。
  Widget _buildMobileSection(
    _SectionDef sec,
    List<_CardDef> cards,
    BuildContext context,
    AppState state,
    ColorScheme scheme,
    AppStrings s,
  ) {
    final rows = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      rows.add(_buildMobileRow(cards[i], context, state, scheme, s));
      if (i < cards.length - 1) {
        rows.add(Divider(
          height: 0.5,
          thickness: 0.5,
          indent: 16,
          endIndent: 16,
          color: scheme.outlineVariant.withAlpha(60),
        ));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
        child: Text(sec.title(s), style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
          letterSpacing: 0.3,
        )),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 7),
        // 设置项卡片：遵循玻璃效果配置（liquid/blur/none）与卡片不透明度。
        child: GlassPanel(
          radius: 18,
          padding: EdgeInsets.zero,
          child: Column(children: rows),
        ),
      ),
    ]);
  }

  /// 一条设置行：左标题，右侧开关 / 分段切换 / 箭头（进入二级菜单）。
  Widget _buildMobileRow(
    _CardDef c, BuildContext context, AppState state, ColorScheme scheme, AppStrings s) {
    final title = c.title(s);

    // 纯开关：直接在一级菜单右侧放 Switch
    if (c.id == 'predictiveBack') {
      final cfg = state.config;
      return SwitchListTile(
        value: cfg.predictiveBack,
        onChanged: (v) => state.updateConfig((cc) => cc..predictiveBack = v),
        title: Text(title, style: TextStyle(fontSize: 14, color: scheme.onSurface)),
        subtitle: Text(s.predictiveBackHint,
            style: TextStyle(fontSize: 11, color: scheme.outline)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      );
    }

    // 语言：一级菜单右侧放紧凑的中/EN 分段切换
    if (c.id == 'language') {
      return _mobileLanguageRow(state, scheme);
    }

    // 命令 / 日志：直接进入对应页面（它们的「内容」本身就是入口，不套二级页）
    return ListTile(
      title: Text(title, style: TextStyle(fontSize: 14, color: scheme.onSurface)),
      trailing: Icon(Icons.chevron_right, size: 20, color: scheme.outline),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      onTap: () {
        if (c.id == 'command') {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const SafeArea(child: CommandPage())));
        } else if (c.id == 'logs') {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const SafeArea(child: LogPage())));
        } else {
          _pushMobileSubPage(context, title, c.build);
        }
      },
    );
  }

  /// 语言行：左边「语言」标题，右边中文 / EN 紧凑分段切换。
  Widget _mobileLanguageRow(AppState state, ColorScheme scheme) {
    final cfg = state.config;
    return ListTile(
      title: Text(AppStrings.of(cfg.language).language,
          style: TextStyle(fontSize: 14, color: scheme.onSurface)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      trailing: SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'zh', label: Text('中文', style: TextStyle(fontSize: 12))),
          ButtonSegment(value: 'en', label: Text('EN', style: TextStyle(fontSize: 12))),
        ],
        selected: {cfg.language},
        onSelectionChanged: (sel) {
          if (sel.isNotEmpty) state.updateConfig((c) => c..language = sel.first);
        },
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  /// 二级设置页：全屏（覆盖底部导航栏），顶部返回栏 + 可滚动内容。
  void _pushMobileSubPage(
    BuildContext context, String title, Widget Function(BuildContext, AppState) contentBuilder) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (ctx) => Consumer<AppState>(
        builder: (ctx2, state, _) => _withWallpaper(
          ctx2,
          state,
          Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(children: [
            MobileSubPageTopBar(
              title: Text(title),
              onBack: () => Navigator.of(ctx2).maybePop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(0, 12, 0, 48),
                children: [contentBuilder(ctx2, state)],
              ),
            ),
          ]),
          ),
        ),
      ),
    ));
  }

  Widget _searchField(ColorScheme scheme, AppStrings s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: LayoutBuilder(builder: (ctx, cons) => SizedBox(
          width: math.min(260.0, cons.maxWidth * 0.62),
          height: 38,
          child: TextField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            style: TextStyle(fontSize: 13, color: scheme.onSurface),
            textAlignVertical: TextAlignVertical.center,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: s.setSearchHint,
              hintStyle: TextStyle(fontSize: 13, color: scheme.outline),
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withAlpha(90),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              prefixIcon: Icon(Icons.search, size: 17, color: scheme.outline),
              prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: Icon(Icons.close, size: 15, color: scheme.outline),
                      tooltip: s.setClearSearch,
                      onPressed: _clearSearch,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(19),
                borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(19),
                borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(19),
                borderSide: BorderSide(color: scheme.primary.withAlpha(160), width: 1.4),
              ),
            ),
          ),
        ),
        ),
      );

  Widget _emptyState(ColorScheme scheme, AppStrings s) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.search_off, size: 44, color: scheme.outline.withAlpha(140)),
          const SizedBox(height: 12),
          Text(s.setNoMatch, style: TextStyle(fontSize: 14, color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(s.setNoMatchHint, style: TextStyle(fontSize: 11, color: scheme.outline)),
          const SizedBox(height: 14),
          TextButton.icon(
            icon: const Icon(Icons.close, size: 15),
            label: Text(s.setClearSearch, style: const TextStyle(fontSize: 12)),
            onPressed: _clearSearch,
          ),
        ]),
      );
}

/// 分区标题，滚动时吸顶；点击整行可折叠/展开该分区。
class _SectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String title;
  final IconData icon;
  final ColorScheme scheme;
  final bool collapsed;
  final int count;
  final String toggleTooltip;
  final VoidCallback? onToggle;

  const _SectionHeaderDelegate({
    required this.title,
    required this.icon,
    required this.scheme,
    required this.collapsed,
    required this.count,
    required this.toggleTooltip,
    required this.onToggle,
  });

  @override
  double get minExtent => 42;
  @override
  double get maxExtent => 42;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final pinned = shrinkOffset > 0 || overlapsContent;
    // 这里原来套了一层 BackdropFilter(sigma 12)。分区标题是 pinned 的，滚动时每一帧
    // 都要重新对整条宽度做一次高斯模糊，是本页滚动最贵的一笔开销。
    // 吸顶时把底色调到接近不透明即可保证文字可读，视觉差别几乎看不出来。
    // 背景透明度用 AnimatedContainer 过渡，避免吸顶/折叠瞬间跳变造成割裂感。
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        color: scheme.surface.withAlpha(pinned ? 234 : 90),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            // 悬停/点击涟漪用圆角矩形，避免整条长方形的高亮
            customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            onTap: onToggle,
            child: _headerTooltip(
              // 搜索中不能折叠，此时不挂 tooltip（空字符串会弹空气泡）
              onToggle == null ? null : toggleTooltip,
              SizedBox(
                height: 42,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 18, 0),
                  child: Row(children: [
                    // 折叠箭头：旋转 + 透明度统一由同一段动画驱动，
                    // 与下方 AnimatedSize 的时长/曲线保持一致，消除割裂感。
                    AnimatedRotation(
                      turns: collapsed ? -0.25 : 0, // 展开朝下，折叠朝右
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: onToggle == null ? 0.35 : 1,
                        duration: const Duration(milliseconds: 160),
                        child: Icon(Icons.expand_more,
                            size: 18,
                            color: onToggle == null ? scheme.outline.withAlpha(90) : scheme.primary),
                      ),
                    ),
                    const SizedBox(width: 4),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                      child: Icon(icon, key: ValueKey(icon), size: 15, color: scheme.primary),
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        title.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                    // 折叠时提示里面还有几项，避免看起来像空分区
                    if (collapsed) ...[
                      const SizedBox(width: 8),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        transitionBuilder: (child, anim) =>
                            ScaleTransition(scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack), child: child),
                        child: Container(
                          key: ValueKey('count_$count'),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.primary.withAlpha(30),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text('$count',
                              style: TextStyle(
                                  fontSize: 10, fontWeight: FontWeight.w600, color: scheme.primary)),
                        ),
                      ),
                    ],
                    const SizedBox(width: 10),
                    Expanded(child: Divider(color: scheme.outlineVariant.withAlpha(70), height: 1)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_SectionHeaderDelegate old) =>
      old.title != title ||
      old.icon != icon ||
      old.scheme != scheme ||
      old.collapsed != collapsed ||
      old.count != count ||
      old.toggleTooltip != toggleTooltip ||
      (old.onToggle == null) != (onToggle == null);
}

/// message 为 null 时不套 Tooltip —— 空字符串会弹出一个空气泡。
Widget _headerTooltip(String? message, Widget child) => message == null
    ? child
    : Tooltip(
        message: message,
        waitDuration: const Duration(milliseconds: 600),
        child: child,
      );

/// 带标签的滑块，拖动时对写入全局配置做节流。
///
/// 原来 `onChanged` 直接调 `state.updateConfig`，而它会 `notifyListeners()`，
/// 于是拖一次滑块 = 每秒 60 次整棵树重建（设置页有十几张卡片）。
/// 这里把滑块位置和标签放在本地 state 里做到即时跟手，全局配置最多每 40ms 推一次，
/// 松手时再补一次精确值——预览照样是实时的，重建次数少了三分之二。

/// 设置卡片容器。
/// 移动端：Android 16 原生设置风格 —— 低对比度主题色卡片（surfaceContainerLow），
/// 无玻璃光效，仅简洁的圆角 + 细边框 + 弱阴影，清晰易读。
/// 桌面端：保持原有玻璃效果（liquid/blur/none）与透明度。
Widget _glass(BuildContext ctx, AppState state, String title, List<Widget> children) {
  final scheme = Theme.of(ctx).colorScheme;
  if (isMobilePlatform) {
    final effect = state.config.glassEffect;
    if (effect == 'liquid' || effect == 'blur') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
        child: GlassPanel(
          radius: 16,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );
    }
    // none 模式：Android 16 原生设置卡片风格
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant.withAlpha(50), width: 0.6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(10),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const SizedBox(height: 10),
          ...children,
        ]),
      ),
    );
  }
  return GlassPanel(
    radius: 20,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary)),
      const SizedBox(height: 8),
      ...children,
    ]),
  );
}

/// 路径字段（标签 + 输入框 + 浏览按钮）
Widget _pf(BuildContext ctx, String label, String value, ValueChanged<String> onChange, VoidCallback onBrowse) {
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 12, color: clr)),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(child: _PathField(value: value, label: '', scheme: scheme, onChange: onChange)),
        const SizedBox(width: 6),
        OutlinedButton(
          onPressed: onBrowse,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
          child: const Icon(Icons.folder_open, size: 16),
        ),
      ]),
    ]),
  );
}

/// 链接按钮
/// 小号链接（博客/GitHub 等），不再是占满全宽的大按钮。
Widget _link(String label, String url) => TextButton.icon(
  onPressed: () => openExternalUrl(url),
  icon: const Icon(Icons.open_in_new, size: 12),
  label: Text(label, style: const TextStyle(fontSize: 11)),
  style: TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    minimumSize: const Size(0, 28),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    foregroundColor: const Color(0xFF5E6AD2),
  ),
);

/// 信息行（关于页）
Widget _infoRow(String label, String value, ColorScheme scheme, {Widget? trailing}) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Row(children: [
    Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
    ?trailing,
    Flexible(
      child: Tooltip(message: value, child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.onSurface, fontWeight: FontWeight.w500)),
      ),
    ),
  ]),
);

/// iOS 风格按钮
Widget _iosButton({
  required IconData icon, required String label,
  required Color color, required Color bg, required VoidCallback onTap,
}) => Material(
  color: bg,
  borderRadius: BorderRadius.circular(14),
  child: InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Flexible(child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
            overflow: TextOverflow.ellipsis)),
      ]),
    ),
  ),
);

/// 主题色圆点
Widget _dot(ColorScheme sc, bool sel, Color c, String tip, VoidCallback onTap) => Tooltip(
  message: tip,
  child: GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 28, height: 28,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(
          color: sel ? sc.primary : Colors.transparent,
          width: 3,
        ),
      ),
      child: sel ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
    ),
  ),
);

/// 自定义取色入口按钮（内联于 _buildTheme，见其 Wrap 实现）


class _SettingSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double) label;
  final TextStyle labelStyle;
  final ValueChanged<double> onCommit;

  const _SettingSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.labelStyle,
    required this.onCommit,
    this.divisions,
  });

  @override
  State<_SettingSlider> createState() => _SettingSliderState();
}

class _SettingSliderState extends State<_SettingSlider> {
  static const _minInterval = Duration(milliseconds: 40);

  double? _dragValue;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  double get _current => _dragValue ?? widget.value;

  void _onChanged(double v) {
    setState(() => _dragValue = v);
    final now = DateTime.now();
    if (now.difference(_lastPush) >= _minInterval) {
      _lastPush = now;
      widget.onCommit(v);
    }
  }

  void _onChangeEnd(double v) {
    // 最终值必须无条件写一次，否则节流可能把最后一次移动吞掉
    widget.onCommit(v);
    setState(() => _dragValue = null);
  }

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        // 大字号下标签不再被右侧 Slider 挤没：允许换行到两行并在必要时收缩
        Flexible(
          child: Text(widget.label(_current), maxLines: 2, overflow: TextOverflow.ellipsis, style: widget.labelStyle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Slider(
            value: _current.clamp(widget.min, widget.max),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            onChanged: _onChanged,
            onChangeEnd: _onChangeEnd,
          ),
        ),
      ]);
}

// ═══════════════════════════════════════════
// 各设置卡片
// ═══════════════════════════════════════════

const _presets = [
  ('Linear Purple', 0xFF5E6AD2), ('Ocean Blue', 0xFF3B82F6),
  ('Emerald', 0xFF10B981), ('Amber', 0xFFF59E0B),
  ('Rose', 0xFFEF4444), ('Cyan', 0xFF06B6D4), ('Violet', 0xFF8B5CF6),
];

const _kDefaultAnthropicModel = 'claude-3-5-sonnet-20241022';

/// 询问模式下可选"无需确认"的操作（显示名, 内部 key）。
const _askSkipOptions = <(String, String)>[
  ('保存', 'save'),
  ('撤销/重做', 'undo_redo'),
  ('错误检查', 'error_check'),
  ('清空画布', 'clear_all'),
  ('工具执行', 'tools'),
];

Widget _buildTheme(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;

  // 移动端与桌面端一致：直接内联展示主题设置项（不再经过一级入口再弹窗）。
  return _glass(ctx, state, s.cardTheme, [
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.darkMode, style: TextStyle(color: clr)),
        value: state.darkMode,
        onChanged: (v) => state.toggleDarkMode(v)),
    // Android Monet 动态取色（跟随系统壁纸）
    if (isMobilePlatform)
      SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
          title: Text(s.isZh ? '动态取色（Monet）' : 'Dynamic color (Monet)',
              style: TextStyle(color: clr, fontSize: 13)),
          subtitle: Text(s.isZh ? '跟随系统壁纸生成主题色，参考 Android 16 Material You'
              : 'Theme colors derived from your wallpaper (Android 16 Material You)',
              style: TextStyle(fontSize: 11, color: scheme.outline)),
          value: cfg.useDynamicColor,
          onChanged: (v) => state.updateConfig((c) => c..useDynamicColor = v)),
    const SizedBox(height: 4),
    Text(s.accentColor, style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 8),
    Wrap(spacing: 8, runSpacing: 8, children: [
      ..._presets.map((p) => _dot(scheme, cfg.themeColor == p.$2 && cfg.themeColor2 < 0, Color(p.$2), p.$1,
          () => state.updateConfig((c) => c..themeColor = p.$2..themeColor2 = -1))),
      // 自定义取色：若已设渐变色则显示渐变圆点，点击进入渐变/纯色设置
      GestureDetector(
        onTap: () => _pickColor(ctx, state),
        child: Tooltip(
          message: cfg.themeColor2 >= 0 ? (state.config.language == 'zh' ? '当前渐变色' : 'Current gradient') : (state.config.language == 'zh' ? '自定义（支持渐变）' : 'Custom (gradient)'),
          child: Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: cfg.themeColor2 >= 0
                  ? LinearGradient(colors: [Color(cfg.themeColor), Color(cfg.themeColor2)], begin: Alignment.topLeft, end: Alignment.bottomRight)
                  : const LinearGradient(colors: [Color(0xFFFF5F6D), Color(0xFFFFC371), Color(0xFF36D1DC), Color(0xFF5B86E5)]),
              border: Border.all(color: cfg.themeColor2 >= 0 ? scheme.primary : scheme.outlineVariant.withAlpha(80), width: cfg.themeColor2 >= 0 ? 2 : 1),
            ),
            child: const Icon(Icons.add, size: 14, color: Colors.white),
          ),
        ),
      ),
    ]),
    const SizedBox(height: 10),
    // 逻辑门符号标准：ANSI/IEEE 或 IEC
    Text(s.isZh ? '逻辑门符号标准' : 'Logic Gate Standard', style: TextStyle(fontSize: 12, color: clr)),
    const SizedBox(height: 6),
    SegmentedButton<String>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: 'ansi', label: Text('ANSI/IEEE', style: TextStyle(fontSize: 11))),
        ButtonSegment(value: 'iec', label: Text('IEC', style: TextStyle(fontSize: 11))),
      ],
      selected: {cfg.gateStd},
      onSelectionChanged: (v) => state.updateConfig((c) => c..gateStd = v.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    ),
  ]);
}

/// 移动端设置 → 工具 → 命令：进入命令页
Widget _buildMobileCommandEntry(BuildContext ctx, AppState state) {
  final scheme = Theme.of(ctx).colorScheme;
  final s = AppStrings.of(state.config.language);
  return _glass(ctx, state, s.navCommand, [
    ListTile(
      dense: true, contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.terminal_outlined, color: scheme.primary, size: 22),
      title: Text(s.isZh ? '手动执行 FFmpeg 命令' : 'Run custom FFmpeg commands',
          style: TextStyle(fontSize: 13, color: scheme.onSurface)),
      subtitle: Text(s.isZh ? '命令输入 + 快捷模板 + 参数参考'
          : 'Manual input + quick templates + parameter reference',
          style: TextStyle(fontSize: 11, color: scheme.outline)),
      trailing: Icon(Icons.chevron_right, color: scheme.outline),
      onTap: () => Navigator.of(ctx).push(
          MaterialPageRoute(builder: (_) => SafeArea(child: const CommandPage()))),
    ),
  ]);
}

/// 移动端设置 → 工具 → 日志：进入日志页
Widget _buildMobileLogsEntry(BuildContext ctx, AppState state) {
  final scheme = Theme.of(ctx).colorScheme;
  final s = AppStrings.of(state.config.language);
  return _glass(ctx, state, s.qLogs, [
    ListTile(
      dense: true, contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.terminal, color: scheme.primary, size: 22),
      title: Text(s.isZh ? '查看运行日志' : 'View runtime logs',
          style: TextStyle(fontSize: 13, color: scheme.onSurface)),
      subtitle: Text(s.isZh ? '后端输出、FFmpeg 进度与错误信息'
          : 'Backend output, FFmpeg progress and errors',
          style: TextStyle(fontSize: 11, color: scheme.outline)),
      trailing: Icon(Icons.chevron_right, color: scheme.outline),
      onTap: () => Navigator.of(ctx).push(
          MaterialPageRoute(builder: (_) => SafeArea(child: const LogPage()))),
    ),
  ]);
}

/// 预测式返回手势开关（Android，仅安卓端展示）。
Widget _buildPredictiveBack(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.predictiveBack, [
    SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(s.isZh ? '启用预测式返回手势' : 'Enable predictive back gesture',
          style: TextStyle(color: clr, fontSize: 13)),
      subtitle: Text(s.predictiveBackHint,
          style: TextStyle(fontSize: 11, color: scheme.outline)),
      value: cfg.predictiveBack,
      onChanged: (v) => state.updateConfig((c) => c..predictiveBack = v),
    ),
  ]);
}

Widget _buildBackground(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.cardBackground, [
    ListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.bgTitle, style: TextStyle(color: clr, fontSize: 13)),
        subtitle: Text(cfg.backgroundImage.isEmpty ? s.bgNone : cfg.backgroundImage.split(RegExp(r'[\\/]')).last,
            style: TextStyle(fontSize: 11, color: scheme.outline)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (cfg.backgroundImage.isNotEmpty)
            IconButton(icon: Icon(Icons.close, size: 16, color: scheme.error),
                onPressed: () => state.updateConfig((c) => c..backgroundImage = ''),
                padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24)),
          IconButton(icon: Icon(Icons.image, size: 18, color: scheme.primary),
              onPressed: () async {
                // 先同步取屏幕物理分辨率（在第一个 await 之前，避免跨 async gap）
                final view = View.of(ctx);
                final dpr = view.devicePixelRatio;
                final logical = view.physicalSize / dpr;
                final maxW = (logical.width * dpr).ceil();
                final maxH = (logical.height * dpr).ceil();
                final r = await FilePicker.platform.pickFiles(
                    type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp'],
                    // 仅 Android 需要内存字节（content:// URI 无法用 File 读取）
                    withData: isAndroidPlatform);
                if (r != null && r.files.isNotEmpty) {
                  final file = r.files.first;
                  final path = file.path;
                  // Android 11+: content:// URI 无法用 File 读写，优先用内存字节；
                  // 其余平台用磁盘路径（节省内存）。
                  final useBytes = (path == null || path.startsWith('content://')) && file.bytes != null;
                  if (useBytes) {
                    final saved = await _saveBackgroundBytes(file.bytes!, file.name, maxW, maxH);
                    if (saved != null) {
                      state.updateConfig((c) => c..backgroundImage = saved);
                    }
                  } else if (path != null) {
                    // 大图自动压缩到屏幕分辨率，避免体积过大导致卡死
                    final copied = await _copyBackgroundOptimized(path, maxW, maxH);
                    state.updateConfig((c) => c..backgroundImage = copied ?? path);
                  }
                }
              }, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24)),
        ])),
    if (cfg.backgroundImage.isNotEmpty)
      _SettingSlider(
        value: cfg.backgroundOpacity, min: 0.0, max: 1.0, divisions: 100,
        label: (v) => '${s.bgOpacity}: ${(v * 100).round()}%',
        labelStyle: TextStyle(color: clr, fontSize: 11),
        onCommit: (v) => state.updateConfig((c) => c..backgroundOpacity = v),
      ),
    _SettingSlider(
      value: cfg.cardOpacity, min: 0.0, max: 1.0, divisions: 100,
      label: (v) => '${s.cardOpacity}: ${(v * 100).round()}%',
      labelStyle: TextStyle(color: clr, fontSize: 11),
      onCommit: (v) => state.updateConfig((c) => c..cardOpacity = v),
    ),
    const SizedBox(height: 6),
    // 玻璃效果选择
    Text(s.glassEffectLabel, style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 6),
    SegmentedButton<String>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(value: 'liquid', icon: const Icon(Icons.water_drop_outlined, size: 14), label: Text(s.glassLiquid, style: const TextStyle(fontSize: 11))),
        ButtonSegment(value: 'blur', icon: const Icon(Icons.blur_on_outlined, size: 14), label: Text(s.glassBlur, style: const TextStyle(fontSize: 11))),
        ButtonSegment(value: 'none', icon: const Icon(Icons.crop_square_outlined, size: 14), label: Text(s.glassNone, style: const TextStyle(fontSize: 11))),
      ],
      selected: {cfg.glassEffect},
      onSelectionChanged: (v) => state.updateConfig((c) => c..glassEffect = v.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    ),
    // 仅「液态玻璃」生效时显示：设置项改用更易读的毛玻璃背景
    if (cfg.glassEffect == 'liquid') ...[
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.settingsFrostedGlass, style: TextStyle(color: clr, fontSize: 12)),
          const SizedBox(height: 2),
          Text(s.settingsFrostedGlassHint, style: TextStyle(fontSize: 10, color: scheme.outline)),
        ])),
        Switch(
          value: cfg.settingsFrostedGlass,
          onChanged: (v) => state.updateConfig((c) => c..settingsFrostedGlass = v),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ]),
    ],
    const SizedBox(height: 10),
    // 遵循主题色：玻璃/卡片底色统一使用主题色
    Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.glassFollowTheme, style: TextStyle(color: clr, fontSize: 12)),
        const SizedBox(height: 2),
        Text(s.glassFollowThemeHint, style: TextStyle(fontSize: 10, color: scheme.outline)),
      ])),
      Switch(
        value: cfg.glassFollowTheme,
        onChanged: (v) => state.updateConfig((c) => c..glassFollowTheme = v),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ]),
    const SizedBox(height: 10),
    // 画布背景：跟随全局 / 灰色 / 黑色 / 白色
    Text(s.canvasBgLabel, style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 6),
    SegmentedButton<String>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(value: 'global', label: Text(s.isZh ? '跟随全局' : 'Follow', style: const TextStyle(fontSize: 11))),
        ButtonSegment(value: 'gray', icon: const Icon(Icons.grid_4x4, size: 12), label: Text(s.isZh ? '灰色' : 'Gray', style: const TextStyle(fontSize: 11))),
        ButtonSegment(value: 'black', label: Text(s.isZh ? '黑色' : 'Black', style: const TextStyle(fontSize: 11))),
        ButtonSegment(value: 'white', label: Text(s.isZh ? '白色' : 'White', style: const TextStyle(fontSize: 11))),
      ],
      selected: {cfg.canvasBg},
      onSelectionChanged: (v) => state.updateConfig((c) => c..canvasBg = v.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    ),
  ]);
}

Widget _buildLanguage(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;

  if (isMobilePlatform) {
    // 移动端：全宽单选（与其它设置项等长），避免下拉菜单宽度过短。
    return _glass(ctx, state, s.language, [
      RadioGroup<String>(
        groupValue: cfg.language,
        onChanged: (v) {
          if (v != null) state.updateConfig((c) => c..language = v);
        },
        child: Column(children: [
          RadioListTile<String>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('中文 (简体)', style: TextStyle(fontSize: 13, color: clr)),
            value: 'zh',
          ),
          RadioListTile<String>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('English', style: TextStyle(fontSize: 13, color: clr)),
            value: 'en',
          ),
        ]),
      ),
    ]);
  }

  return _glass(ctx, state, s.language, [
    Text(s.languageInterface, style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 6),
    DropdownMenu<String>(
      initialSelection: cfg.language,
      requestFocusOnTap: false,
      textStyle: TextStyle(fontSize: 12, color: clr),
      // 不覆盖 menuStyle/inputDecorationTheme：沿用全局主题（圆角 22 玻璃菜单 + 主题化圆角输入框）
      dropdownMenuEntries: [
        DropdownMenuEntry(value: 'zh', label: '中文 (简体)'),
        DropdownMenuEntry(value: 'en', label: 'English'),
      ],
      onSelected: (v) { if (v != null) state.updateConfig((c) => c..language = v); },
      leadingIcon: Icon(Icons.language, size: 15, color: scheme.primary),
    ),
  ]);
}

Widget _buildFont(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;

  if (isMobilePlatform) {
    // 移动端：只保留「系统字体」与「导入字体」两个选项，不再展示字体列表。
    return _glass(ctx, state, s.font, [
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.text_fields, size: 20, color: scheme.onSurfaceVariant),
        title: Text(s.isZh ? '系统字体（默认）' : 'System font (default)',
            style: TextStyle(fontSize: 13, color: clr)),
        trailing: cfg.fontFamily.isEmpty
            ? Icon(Icons.check_circle, size: 19, color: scheme.primary)
            : const SizedBox(width: 19),
        onTap: () => state.updateConfig((c) => c..fontFamily = ''),
      ),
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.upload_file_outlined, size: 20, color: scheme.onSurfaceVariant),
        title: Text(s.isZh ? '导入字体' : 'Import font',
            style: TextStyle(fontSize: 13, color: clr)),
        subtitle: cfg.fontFamily.isEmpty
            ? null
            : Text(cfg.fontFamily,
                style: TextStyle(fontSize: 11, color: scheme.outline),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
        trailing: cfg.fontFamily.isNotEmpty
            ? Icon(Icons.check_circle, size: 19, color: scheme.primary)
            : Icon(Icons.chevron_right, size: 19, color: scheme.outline),
        onTap: () => _pickFont(ctx, state),
      ),
      const Divider(height: 12, color: Colors.transparent),
      _SettingSlider(
        value: cfg.fontSize, min: 10, max: 21, divisions: 11,
        label: (v) => '${s.fontSize}: ${v.round()}',
        labelStyle: TextStyle(color: clr, fontSize: 12),
        onCommit: (v) => state.updateConfig((c) => c..fontSize = v),
      ),
      Text(s.qWeight, style: TextStyle(color: clr, fontSize: 12)),
      const SizedBox(height: 6),
      // 字重：中文下拉选择（避免英文标签换行且已汉化）
      DropdownMenu<int>(
        initialSelection: cfg.fontWeightIndex,
        requestFocusOnTap: false,
        textStyle: TextStyle(fontSize: 12, color: clr),
        dropdownMenuEntries: const [
          DropdownMenuEntry(value: 0, label: '细体 (Light)'),
          DropdownMenuEntry(value: 1, label: '常规 (Regular)'),
          DropdownMenuEntry(value: 2, label: '中等 (Medium)'),
          DropdownMenuEntry(value: 3, label: '半粗 (SemiBold)'),
          DropdownMenuEntry(value: 4, label: '粗体 (Bold)'),
        ],
        onSelected: (v) { if (v != null) state.updateConfig((c) => c..fontWeightIndex = v); },
      ),
    ]);
  }

  return _glass(ctx, state, s.font, [
    FontPicker(currentFont: cfg.fontFamily, language: cfg.language, showImport: true,
        onImport: () => _pickFont(ctx, state),
        onSelected: (v) => state.updateConfig((c) => c..fontFamily = v)),
    const SizedBox(height: 10),
    _SettingSlider(
      value: cfg.fontSize, min: 10, max: 21, divisions: 11,
      label: (v) => '${s.fontSize}: ${v.round()}',
      labelStyle: TextStyle(color: clr, fontSize: 12),
      onCommit: (v) => state.updateConfig((c) => c..fontSize = v),
    ),
    Text(s.qWeight, style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 6),
    // 字重：中文下拉选择（避免英文标签换行且已汉化）
    DropdownMenu<int>(
      initialSelection: cfg.fontWeightIndex,
      requestFocusOnTap: false,
      textStyle: TextStyle(fontSize: 12, color: clr),
      // 不覆盖 menuStyle/inputDecorationTheme：沿用全局主题（圆角 22 玻璃菜单 + 主题化圆角输入框）
      dropdownMenuEntries: const [
        DropdownMenuEntry(value: 0, label: '细体 (Light)'),
        DropdownMenuEntry(value: 1, label: '常规 (Regular)'),
        DropdownMenuEntry(value: 2, label: '中等 (Medium)'),
        DropdownMenuEntry(value: 3, label: '半粗 (SemiBold)'),
        DropdownMenuEntry(value: 4, label: '粗体 (Bold)'),
      ],
      onSelected: (v) { if (v != null) state.updateConfig((c) => c..fontWeightIndex = v); },
    ),
  ]);
}

Widget _buildOutput(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  return _glass(ctx, state, s.output, [
    _pf(ctx, s.outputDir, cfg.defaultOutputDir,
        (v) => state.updateConfig((c) => c..defaultOutputDir = v),
        () async { final d = await FilePicker.platform.getDirectoryPath(); if (d != null) state.updateConfig((c) => c..defaultOutputDir = d); }),
    const SizedBox(height: 8),
    _pf(ctx, s.intermediateDir, cfg.intermediateDir,
        (v) => state.updateConfig((c) => c..intermediateDir = v),
        () async { final d = await FilePicker.platform.getDirectoryPath(); if (d != null) state.updateConfig((c) => c..intermediateDir = d); }),
    Padding(padding: const EdgeInsets.only(top: 2),
        child: Text(s.intermediateHint, style: TextStyle(fontSize: 11, color: scheme.outline))),
  ]);
}

Widget _buildEditorMode(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.cardEditorMode, [
    RadioGroup<int>(
      groupValue: cfg.editMode,  // 0=node editor, 1=quick mode, 2=traditional
      onChanged: (v) { if (v != null) state.updateConfig((c) => c..editMode = v); },
      child: Column(children: [
        // node editor (value: 0, title: '节点编辑器')
        RadioListTile<int>(dense: true, contentPadding: EdgeInsets.zero,
            title: Text(s.isZh ? '节点编辑器' : 'Node Editor', style: TextStyle(color: clr, fontSize: 13)),
            subtitle: Text(s.isZh ? '蓝图式节点画布，可处理复杂的多步骤逻辑' : 'Blueprint-style canvas for complex multi-step logic', style: TextStyle(fontSize: 11, color: scheme.outline)),
            value: 0),
        // quick mode (value: 1)
        RadioListTile<int>(dense: true, contentPadding: EdgeInsets.zero,
            title: Text(s.isZh ? '快速模式' : 'Quick Mode', style: TextStyle(color: clr, fontSize: 13)),
            subtitle: Text(s.isZh ? '选择文件后快速配置处理参数，适配不同文件类型（视频/图片/音频）' : 'Quickly configure processing after selecting a file, supports different file types (video/image/audio)', style: TextStyle(fontSize: 11, color: scheme.outline)),
            value: 1),
        // traditional mode (value: 2)
        RadioListTile<int>(dense: true, contentPadding: EdgeInsets.zero,
            title: Text(s.isZh ? '传统模式（即将弃用）' : 'Classic Mode (Deprecated)', style: TextStyle(color: clr, fontSize: 13)),
            subtitle: Text(s.isZh ? '傻瓜式操作，适合简单的视频处理任务。此功能将在不久后弃用，建议使用节点编辑器（即将弃用）' : 'Simple step-by-step for basic tasks. Will be deprecated soon, use Node Editor instead (Deprecated)', style: TextStyle(fontSize: 11, color: scheme.outline)),
            value: 2),
      ]),
    ),
  ]);
}

Widget _buildAutosave(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.cardAutosave, [
    if (isMobilePlatform) ...[
      SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
          title: Text(s.isZh ? '节点编辑器横屏' : 'Landscape node editor', style: TextStyle(color: clr, fontSize: 13)),
          subtitle: Text(s.isZh ? '进入节点编辑器时默认横屏显示，画布更宽（移动端）' : 'Open the node editor in landscape by default for a wider canvas (mobile)',
              style: TextStyle(fontSize: 11, color: scheme.outline)),
          value: cfg.useNodeEditorLandscape,
          onChanged: (v) => state.updateConfig((c) => c..useNodeEditorLandscape = v)),
      const Divider(height: 4, color: Colors.transparent),
    ],
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.isZh ? '启用节点编辑器自动保存' : 'Enable editor autosave', style: TextStyle(color: clr, fontSize: 13)),
        subtitle: Text(s.isZh ? '编辑节点画布时定期保存草稿，异常退出后可恢复' : 'Periodically save drafts while editing; restore after abnormal exit',
            style: TextStyle(fontSize: 11, color: scheme.outline)),
        value: cfg.autosaveEnabled,
        onChanged: (v) => state.updateConfig((c) => c..autosaveEnabled = v)),
    const SizedBox(height: 6),
    Text(s.isZh ? '保存间隔' : 'Save Interval', style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 8),
    DropdownButtonFormField<int>(borderRadius: BorderRadius.circular(12), initialValue: cfg.autosaveIntervalSec, isDense: true, isExpanded: true,
        style: TextStyle(fontSize: 12, color: clr), dropdownColor: scheme.surface,
        decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
        items: [
          for (final sec in [10, 30, 60, 120, 300])
            DropdownMenuItem(value: sec, child: Text(sec < 60
                ? (s.isZh ? '$sec 秒' : '$sec s')
                : (s.isZh ? '${sec ~/ 60} 分钟' : '${sec ~/ 60} min'))),
        ],
        onChanged: (v) { if (v != null) state.updateConfig((c) => c..autosaveIntervalSec = v); }),
    const SizedBox(height: 4),
    Text(s.isZh ? '停止操作后多久自动保存一次' : 'How long after edits stop before autosaving', style: TextStyle(fontSize: 10, color: scheme.outline)),
  ]);
}

Widget _buildShortcuts(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.cardShortcuts, [
    ListTile(dense: true, contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.keyboard, size: 20, color: scheme.primary),
        title: Text(s.isZh ? '快捷键配置' : 'Keyboard Shortcuts', style: TextStyle(color: clr, fontSize: 13)),
        subtitle: Text(s.isZh ? '配置画布和基本操作快捷键' : 'Configure canvas and basic shortcuts', style: TextStyle(fontSize: 11, color: scheme.outline)),
        trailing: Icon(Icons.chevron_right, size: 18, color: scheme.outline),
        onTap: () => showKeybindingDialog(ctx, isZh: s.isZh)),
  ]);
}

Widget _buildTasks(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.cardTasks, [
    Text(s.isZh ? '同时启用任务数' : 'Concurrent Tasks', style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 8),
    DropdownButtonFormField<int>(borderRadius: BorderRadius.circular(12), initialValue: cfg.maxConcurrentTasks, isDense: true, isExpanded: true,
        style: TextStyle(fontSize: 12, color: clr), dropdownColor: scheme.surface,
        decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
        items: [
          ...List.generate(8, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
          DropdownMenuItem(value: 0, child: Text(s.isZh ? '不限制' : 'Unlimited')),
        ],
        onChanged: (v) { if (v != null) state.updateConfig((c) => c..maxConcurrentTasks = v); }),
    const SizedBox(height: 4),
    Text(s.isZh ? '控制队列中同时处理的任务数量' : 'Controls how many tasks run in parallel', style: TextStyle(fontSize: 10, color: scheme.outline)),
    const SizedBox(height: 12),
    Text(s.isZh ? '解析线程数' : 'Probe Threads', style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 8),
    DropdownButtonFormField<int>(borderRadius: BorderRadius.circular(12), initialValue: cfg.probeThreads, isDense: true, isExpanded: true,
        style: TextStyle(fontSize: 12, color: clr), dropdownColor: scheme.surface,
        decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
        items: List.generate(8, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
        onChanged: (v) { if (v != null) state.updateConfig((c) => c..probeThreads = v); }),
    const SizedBox(height: 4),
    Text(s.isZh ? '添加文件时同时解析的线程数，增大可加快批量导入速度' : 'Number of concurrent probe threads when importing files', style: TextStyle(fontSize: 10, color: scheme.outline)),
    const SizedBox(height: 8),
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.isZh ? '任务完成系统通知' : 'Task completion notification', style: TextStyle(color: clr, fontSize: 13)),
        subtitle: Text(s.isZh ? '每个任务完成时发送系统通知' : 'Send system notification when each task finishes', style: TextStyle(fontSize: 11, color: scheme.outline)),
        value: cfg.enableSystemNotification,
        onChanged: (v) => state.updateConfig((c) => c..enableSystemNotification = v)),
  ]);
}

Widget _buildUpdate(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  // 移动端：桌面版在线更新机制不适用（APK 分发）
  if (isMobilePlatform) {
    return _glass(ctx, state, s.cardUpdate, [
      ListTile(dense: true, contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.smartphone, color: scheme.primary, size: 22),
        title: Text(s.isZh ? 'Android 版本更新' : 'Android App Updates',
            style: TextStyle(fontSize: 13, color: clr)),
        subtitle: Text(s.isZh ? '移动端通过 APK 分发，请关注项目发布页获取新版本'
            : 'Distributed via APK — check the project release page for new versions',
            style: TextStyle(fontSize: 11, color: scheme.outline)),
      ),
      const SizedBox(height: 4),
      Wrap(spacing: 4, runSpacing: 4, children: [
        _link('GitHub', 'https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases'),
      ]),
    ]);
  }
  return _glass(ctx, state, s.cardUpdate, [
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.isZh ? '启动时自动检查更新' : 'Auto-check updates on startup', style: TextStyle(color: clr, fontSize: 13)),
        subtitle: Text(s.isZh ? '静默检查，仅在有新版本时通知' : 'Silent check, notifies only when new version available', style: TextStyle(fontSize: 11, color: scheme.outline)),
        value: cfg.autoCheckUpdate,
        onChanged: (v) => state.updateConfig((c) => c..autoCheckUpdate = v)),
    const SizedBox(height: 6),
    SizedBox(width: double.infinity, child: _iosButton(
        icon: Icons.system_update, label: s.checkUpdate,
        color: scheme.onSecondaryContainer, bg: scheme.secondaryContainer,
        onTap: () => _checkForUpdate(ctx, s))),
  ]);
}

Widget _buildDebug(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final clr = Theme.of(ctx).colorScheme.onSurface;
  return _glass(ctx, state, s.dDebug, [
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.dDebugMode, style: TextStyle(color: clr, fontSize: 13)),
        value: cfg.debugMode, onChanged: (v) => state.updateConfig((c) => c..debugMode = v)),
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.dSaveLogs, style: TextStyle(color: clr, fontSize: 13)),
        value: cfg.saveLogs, onChanged: (v) => state.updateConfig((c) => c..saveLogs = v)),
    if (cfg.saveLogs)
      _pf(ctx, s.dLogPath, cfg.logSavePath,
          (v) => state.updateConfig((c) => c..logSavePath = v),
          () async { final d = await FilePicker.platform.getDirectoryPath(); if (d != null) state.updateConfig((c) => c..logSavePath = d); }),
  ]);
}

Widget _buildCache(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  final scheme = Theme.of(ctx).colorScheme;
  return _glass(ctx, state, s.cardCache, [
    SizedBox(width: double.infinity, child: Material(
      color: scheme.errorContainer.withAlpha(100),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => _clearCache(ctx, state, scheme, s),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.delete_sweep_rounded, size: 20, color: scheme.error),
            const SizedBox(width: 8),
            Text(s.isZh ? '清除缓存' : 'Clear Cache', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.error)),
          ]),
        ),
      ),
    )),
    const SizedBox(height: 6),
    Text(s.isZh ? '清除已导入的字体文件和背景图片' : 'Clear imported fonts and background images', style: TextStyle(fontSize: 10, color: scheme.outline)),
  ]);
}

void _openCredits(BuildContext ctx) {
  Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => SafeArea(child: const CreditsPage())));
}

Widget _buildAbout(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  final scheme = Theme.of(ctx).colorScheme;
  if (isMobilePlatform) {
    // 移动端：顶部图标 + 软件名 + 版本 + 检查更新按钮，下方为版本信息/链接/赞助。
    return _glass(ctx, state, s.aboutTitle, [
      Center(child: Column(children: [
        const SizedBox(height: 4),
        ClipRRect(borderRadius: BorderRadius.circular(16),
            child: Image.asset('rele/icon.png', width: 72, height: 72, fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(Icons.play_circle_fill, size: 72, color: scheme.primary))),
        const SizedBox(height: 10),
        Text('FFmpeg++', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: scheme.primary)),
        const SizedBox(height: 2),
        Text('v${updater.currentVersion}', style: TextStyle(fontSize: 13, color: scheme.outline)),
        const SizedBox(height: 14),
        SizedBox(width: double.infinity,
            child: _iosButton(icon: Icons.system_update, label: s.checkUpdate,
                color: scheme.onSecondaryContainer, bg: scheme.secondaryContainer,
                onTap: () => _checkForUpdate(ctx, s))),
      ])),
      const SizedBox(height: 14),
      const Divider(height: 1),
      const SizedBox(height: 10),
      ListTile(
        dense: true, contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.info_outline, size: 20, color: scheme.primary),
        title: Text(s.aboutVersion, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        trailing: Text('v${updater.currentVersion}',
            style: TextStyle(fontSize: 13, color: scheme.outline, fontWeight: FontWeight.w500)),
      ),
      ListTile(
        dense: true, contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.code, size: 20, color: scheme.primary),
        title: Text(s.aboutGithub, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        trailing: const Icon(Icons.open_in_new, size: 16),
        onTap: () => openExternalUrl('https://github.com/lvbaoshigao/FFmpeg_plus_plus'),
      ),
      ListTile(
        dense: true, contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.article_outlined, size: 20, color: scheme.primary),
        title: Text(s.aboutBlog, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        trailing: const Icon(Icons.open_in_new, size: 16),
        onTap: () => openExternalUrl('https://blog-clstone.netlify.app/'),
      ),
      ListTile(
        dense: true, contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.volunteer_activism, size: 20, color: scheme.primary),
        title: Text(s.aboutSponsor, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => _showSponsor(ctx, scheme, s),
      ),
      ListTile(
        dense: true, contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.favorite_outline, size: 20, color: scheme.primary),
        title: Text(s.aboutReferences, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => _openCredits(ctx),
      ),
    ]);
  }
  return _glass(ctx, state, s.aboutTitle, [
    Center(child: Column(children: [
      const SizedBox(height: 4),
      ClipRRect(borderRadius: BorderRadius.circular(12),
          child: Image.asset('rele/icon.png', width: 48, height: 48, fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(Icons.play_circle_fill, size: 48, color: scheme.primary))),
      const SizedBox(height: 8),
      Text('FFmpeg++', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: scheme.primary)),
      Text('v${updater.currentVersion}', style: TextStyle(fontSize: 12, color: scheme.outline)),
      const SizedBox(height: 12),
    ])),
    const SizedBox(height: 4),
    _infoRow(s.aboutVersion, 'v${updater.currentVersion}', scheme),
    _infoRow(s.aboutBuildDate, '2026-08-05', scheme),
    _infoRow(s.aboutBlog, 'blog-clstone.netlify.app', scheme),
    _infoRow(s.aboutGithub, 'github.com/lvbaoshigao/FFmpeg_plus_plus', scheme),
    const SizedBox(height: 10),
    Row(children: [
      Expanded(child: _iosButton(icon: Icons.volunteer_activism, label: s.aboutSponsorBtn,
          color: scheme.primary, bg: scheme.primaryContainer, onTap: () => _showSponsor(ctx, scheme, s))),
      const SizedBox(width: 8),
      Expanded(child: _iosButton(icon: Icons.system_update, label: s.checkUpdate,
          color: scheme.onSecondaryContainer, bg: scheme.secondaryContainer,
          onTap: isMobilePlatform
              ? () => openExternalUrl('https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases')
              : () => _checkForUpdate(ctx, s))),
    ]),
    const SizedBox(height: 8),
    SizedBox(width: double.infinity, child: _iosButton(
        icon: Icons.favorite_outline, label: s.aboutReferences,
        color: scheme.onSurface, bg: scheme.surfaceContainerHighest.withAlpha(100),
        onTap: () => _openCredits(ctx))),
    const SizedBox(height: 10),
    Wrap(spacing: 4, runSpacing: 4, children: [
      _link(s.aboutBlogLink, 'https://blog-clstone.netlify.app/'),
      _link('GitHub', 'https://github.com/lvbaoshigao/FFmpeg_plus_plus'),
    ]),
  ]);
}

Widget _buildMcpAi(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.mcpTitle, [
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.mcpEnable, style: TextStyle(color: clr)),
        subtitle: cfg.mcpEnabled
            ? Text(
                state.mcpError != null
                    ? state.mcpError!
                    : state.mcpRunning ? (s.isZh ? '运行中' : 'Running') : (s.isZh ? '已停止' : 'Stopped'),
                style: TextStyle(fontSize: 10, color: state.mcpError != null ? scheme.error : state.mcpRunning ? Colors.green : scheme.outline))
            : null,
        value: cfg.mcpEnabled,
        onChanged: (v) => state.toggleMcpServer(v)),
    if (cfg.mcpEnabled)
      Row(children: [
        Text('${s.mcpPort}: ', style: TextStyle(color: clr, fontSize: 12)),
        SizedBox(width: 80, child: _McpTextField(
          value: cfg.mcpPort.toString(), label: '', scheme: scheme,
          onChange: (v) {
            final port = int.tryParse(v);
            if (port != null && port > 0 && port < 65536) {
              state.updateConfig((c) => c..mcpPort = port);
            }
          },
        )),
        const SizedBox(width: 6),
        SizedBox(height: 30, child: FilledButton.tonalIcon(
          icon: const Icon(Icons.refresh, size: 14),
          label: Text(s.isZh ? '应用' : 'Apply', style: const TextStyle(fontSize: 11)),
          onPressed: () async {
            state.mcpError = null;
            await state.stopMcpServer();
            await state.startMcpServer();
          },
        )),
      ]),
    if (cfg.mcpEnabled && state.mcpRunning && state.mcpToken != null)
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: SelectableText(
          '${s.isZh ? '局域网访问令牌' : 'LAN access token'}: ${state.mcpToken}',
          style: TextStyle(fontSize: 11, color: scheme.primary, fontWeight: FontWeight.w600),
        ),
      ),
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.isZh ? '允许 MCP 写入' : 'Allow MCP Write', style: TextStyle(color: clr, fontSize: 12)),
        subtitle: Text(s.isZh ? '关闭时 MCP 只能读取画布/文件，所有修改操作会被拒绝' : 'When off, MCP can only read the canvas/files; all write actions are rejected',
            style: TextStyle(fontSize: 10, color: scheme.outline)),
        value: cfg.mcpAllowWrite,
        onChanged: (v) => state.updateConfig((c) => c..mcpAllowWrite = v)),
    const SizedBox(height: 8),
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.aiEnable, style: TextStyle(color: clr)),
        value: cfg.aiEnabled,
        onChanged: (v) => state.updateConfig((c) => c..aiEnabled = v)),
    if (cfg.aiEnabled)
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          icon: const Icon(Icons.tune, size: 16),
          label: Text(s.aiMoreOptions, style: const TextStyle(fontSize: 12)),
          onPressed: () => _showAiSettingsDialog(ctx, state, s),
        ),
      ),
  ]);
}

void _showAiSettingsDialog(BuildContext ctx, AppState state, AppStrings s) {
  final zh = s.isZh;
  showModalBottomSheet(
    context: ctx,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // 限制最大宽度并居中：宽屏下 AI 设置面板不再拉满整屏
    constraints: const BoxConstraints(maxWidth: 880),
    builder: (bCtx) {
      // 持久状态（闭包捕获，StatefulBuilder 重建时保留）：
      // 当前选中的配置 id + 正在编辑的草稿（null=尚未开始编辑）
      String selProfileId = state.config.aiProfiles.isNotEmpty
          ? (state.config.activeAiProfileId.isNotEmpty
              ? state.config.activeAiProfileId
              : state.config.aiProfiles.first.id)
          : '';
      AiProfile? draft;
      bool showPreset = false;
      return StatefulBuilder(builder: (ctx2, setDState) {
        final cfg = state.config;
        final scheme = Theme.of(ctx2).colorScheme;
        final clr = scheme.onSurface;
        final cardColor = scheme.surface.withAlpha((cfg.cardOpacity * 255).round().clamp(0, 255));

        // 当前编辑对象：优先草稿，其次从列表取
        AiProfile? selected() {
          if (draft != null) return draft;
          for (final pr in cfg.aiProfiles) {
            if (pr.id == selProfileId) return pr;
          }
          return null;
        }

        Widget section(String title, IconData icon, List<Widget> children) => Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
          ),
          child: Padding(padding: const EdgeInsets.all(14), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
              ]),
              const SizedBox(height: 10),
              ...children,
            ],
          )),
        );

        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (_, scrollCtrl) => GlassPanel(
            radius: 20,
            child: Column(children: [
              const SizedBox(height: 8),
              Container(width: 36, height: 4, decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(children: [
                  Text(s.aiSettings, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: clr)),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(bCtx), child: Text(zh ? '完成' : 'Done')),
                ]),
              ),
              Expanded(child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  // ── AI 配置（左右分区：左列表 / 右详情） ──
                  section(zh ? 'AI 配置' : 'AI Profiles', Icons.folder_shared_outlined, [
                    SizedBox(
                      height: 300,
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        // ══ 左：配置列表 ══
                        Container(
                          width: 170,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest.withAlpha(50),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: scheme.outlineVariant.withAlpha(50)),
                          ),
                          child: Column(children: [
                            Expanded(
                              child: cfg.aiProfiles.isEmpty
                                  ? Center(child: Text(zh ? '暂无配置' : 'No profiles',
                                      style: TextStyle(fontSize: 11, color: scheme.outline)))
                                  : ListView.builder(
                                      padding: const EdgeInsets.symmetric(vertical: 4),
                                      itemCount: cfg.aiProfiles.length,
                                      itemBuilder: (_, i) {
                                        final pr = cfg.aiProfiles[i];
                                        final isSel = pr.id == selProfileId;
                                        return InkWell(
                                          onTap: () { selProfileId = pr.id; draft = null; showPreset = false; setDState(() {}); },
                                          child: Container(
                                            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: isSel ? scheme.primaryContainer.withAlpha(120) : Colors.transparent,
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Row(children: [
                                              Icon(
                                                pr.enabled
                                                    ? (isSel ? Icons.radio_button_checked : Icons.cloud_outlined)
                                                    : Icons.cloud_off_outlined,
                                                size: 13,
                                                color: isSel ? scheme.primary : (pr.enabled ? scheme.outline : scheme.outline.withAlpha(60)),
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(child: Text(pr.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                                                      color: isSel ? scheme.primary : (pr.enabled ? clr : scheme.outline)))),
                                            ]),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                            Divider(height: 1, color: scheme.outlineVariant.withAlpha(40)),
                            // 新建配置
                            InkWell(
                              onTap: () {
                                final np = AiProfile(name: zh ? '新配置' : 'New Profile');
                                // 只建本地草稿，点"保存"才落库。
                                // 原实现立即 updateConfig 持久化，不保存就关闭对话框会留下幽灵配置。
                                selProfileId = np.id; draft = np; showPreset = true;
                                setDState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                  const Icon(Icons.add, size: 14, color: Color(0xFF5E6AD2)),
                                  const SizedBox(width: 4),
                                  Text(zh ? '新建配置' : 'New Profile',
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF5E6AD2))),
                                ]),
                              ),
                            ),
                          ]),
                        ),
                        const SizedBox(width: 12),
                        // ══ 右：配置详情 ══
                        Expanded(
                          child: selected() == null
                              ? Center(child: Text(zh ? '选择或新建一个配置' : 'Select or create a profile',
                                  style: TextStyle(fontSize: 11, color: scheme.outline)))
                              : _buildProfileDetail(ctx, state, setDState, scheme, clr, s, zh, selected()!, selProfileId, draft, showPreset, () {
                                  selProfileId = cfg.aiProfiles.isNotEmpty ? cfg.aiProfiles.first.id : '';
                                  draft = null;
                                  setDState(() {});
                                }),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 8),
                  ]),

                  // ── Permissions ──
                  section(s.aiPermissions, Icons.security_outlined, [
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiReadAccess, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiReadAccessDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiReadAccess,
                        onChanged: (v) { state.updateConfig((c) => c..aiReadAccess = v); setDState(() {}); }),
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiWriteAccess, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiWriteAccessDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiWriteAccess,
                        onChanged: (v) { state.updateConfig((c) => c..aiWriteAccess = v); setDState(() {}); }),
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiAutoExecute, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiAutoExecuteDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiAutoExecute,
                        onChanged: (v) { state.updateConfig((c) => c..aiAutoExecute = v); setDState(() {}); }),
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiAllowAsk, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiAllowAskDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiAllowAsk,
                        onChanged: (v) { state.updateConfig((c) => c..aiAllowAsk = v); setDState(() {}); }),
                  ]),
                  // ── Advanced ──
                  section(s.aiAdvanced, Icons.tune_outlined, [
                    Text(s.aiGraphModeLabel, style: TextStyle(color: clr, fontSize: 12)),
                    const SizedBox(height: 6),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: [ButtonSegment(value: 'redo', label: Text(s.aiGraphModeRedo)), ButtonSegment(value: 'modify', label: Text(s.aiGraphModeModify))],
                      selected: {cfg.aiGraphMode},
                      onSelectionChanged: (v) { state.updateConfig((c) => c..aiGraphMode = v.first); setDState(() {}); },
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiShowThinking, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiShowThinkingDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiShowThinking,
                        onChanged: (v) { state.updateConfig((c) => c..aiShowThinking = v); setDState(() {}); }),
                    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                        title: Text(s.aiAutoTitleLabel, style: TextStyle(color: clr, fontSize: 12)),
                        subtitle: Text(s.aiAutoTitleDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                        value: cfg.aiAutoTitle,
                        onChanged: (v) { state.updateConfig((c) => c..aiAutoTitle = v); setDState(() {}); }),
                    if (cfg.aiAutoTitle) ...[
                      const SizedBox(height: 4),
                      Text(s.aiTitlePromptLabel, style: TextStyle(color: clr, fontSize: 12)),
                      const SizedBox(height: 6),
                      _McpTextField(
                        value: cfg.aiTitlePrompt,
                        label: '',
                        hint: s.isZh ? '标题生成提示词（可改写）' : 'Title prompt (editable)',
                        scheme: scheme,
                        minLines: 2,
                        maxLines: 4,
                        onChange: (v) => state.updateConfig((c) => c..aiTitlePrompt = v),
                      ),
                    ],
                    const SizedBox(height: 4),
                    // 会话模式：自动批准 / 询问
                    Text(s.aiApproveModeLabel, style: TextStyle(color: clr, fontSize: 12)),
                    const SizedBox(height: 6),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: 'ask', label: Text(s.aiApproveModeAsk, style: const TextStyle(fontSize: 11))),
                        ButtonSegment(value: 'auto', label: Text(s.aiApproveModeAuto, style: const TextStyle(fontSize: 11))),
                      ],
                      selected: {cfg.aiApproveMode},
                      onSelectionChanged: (v) { state.updateConfig((c) => c..aiApproveMode = v.first); setDState(() {}); },
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    ),
                    const SizedBox(height: 6),
                    Text(s.aiApproveModeDesc, style: TextStyle(color: scheme.outline, fontSize: 10)),
                    const SizedBox(height: 12),
                    // 询问模式下无需确认的操作
                    Text(s.aiAskSkipLabel, style: TextStyle(color: clr, fontSize: 12)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final op in _askSkipOptions)
                        FilterChip(
                          label: Text(op.$1, style: const TextStyle(fontSize: 11)),
                          selected: cfg.aiAskSkipTools.contains(op.$2),
                          visualDensity: VisualDensity.compact,
                          onSelected: (sel) {
                            state.updateConfig((c) {
                              final set = c.aiAskSkipTools.toSet();
                              if (sel) { set.add(op.$2); } else { set.remove(op.$2); }
                              c.aiAskSkipTools = set.toList();
                              return c;
                            });
                            setDState(() {});
                          },
                        ),
                    ]),
                    const SizedBox(height: 12),
                    Text(s.aiCustomPrompt, style: TextStyle(color: clr, fontSize: 12)),
                    const SizedBox(height: 6),
                    // 用有状态的字段持有 controller：这里原先每次 setDState 都会新建一个
                    // TextEditingController，导致光标跳回开头、根本没法连续输入。
                    _McpTextField(
                      value: cfg.aiSystemPrompt,
                      label: '',
                      hint: s.aiCustomPromptHint,
                      scheme: scheme,
                      minLines: 3,
                      maxLines: 5,
                      onChange: (v) => state.updateConfig((c) => c..aiSystemPrompt = v),
                    ),
                  ]),
                ],
              )),
            ]),
          ),
        );
      });
    },
  );
}

/// 弹出 AI 配置编辑表单（新建或编辑现有配置）。
/// 对 AiProfile 应用供应商预设（一键填充端点/模型/上下文）。
void _applyProfilePreset(AiProfile c, String preset) {
  switch (preset) {
    case 'openai':
      c.provider = 'openai';
      c.apiUrl = 'https://api.openai.com/v1/chat/completions';
      c.model = 'gpt-4o';
      c.contextWindow = 128000;
    case 'anthropic':
      c.provider = 'anthropic';
      c.apiUrl = 'https://api.anthropic.com/v1/messages';
      c.model = _kDefaultAnthropicModel;
      c.contextWindow = 200000;
    case 'deepseek':
      c.provider = 'openai';
      c.apiUrl = 'https://api.deepseek.com/v1/chat/completions';
      c.model = 'deepseek-chat';
      c.contextWindow = 64000;
    case 'ollama':
      c.provider = 'openai';
      c.apiUrl = 'http://localhost:11434/v1/chat/completions';
      c.model = 'llama3';
      c.contextWindow = 8192;
  }
}

/// 右侧配置详情：编辑选中配置的全部字段（含供应商预设）。
Widget _buildProfileDetail(
  BuildContext ctx,
  AppState state,
  StateSetter setDState,
  ColorScheme scheme,
  Color clr,
  AppStrings s,
  bool zh,
  AiProfile profile,
  String selProfileId,
  AiProfile? draft,
  bool showPreset,
  VoidCallback onDeleted,
) {
  // 用 Key 保持编辑中草稿的 controller 稳定
  Widget field(String label, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 12, color: clr)),
      const SizedBox(height: 4),
      child,
    ]),
  );

  return SingleChildScrollView(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 供应商预设（新建/编辑都可一键填充）
      if (showPreset) ...[
        field(zh ? '供应商预设（一键填充）' : 'Provider Preset', DropdownButtonFormField<String>(
          initialValue: profile.provider == 'anthropic' ? 'anthropic'
              : profile.apiUrl.contains('deepseek') ? 'deepseek'
              : profile.apiUrl.contains('localhost') || profile.apiUrl.contains('11434') ? 'ollama'
              : 'openai',
          isDense: true,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          style: TextStyle(fontSize: 12, color: clr),
          items: const [
            DropdownMenuItem(value: 'openai', child: Text('OpenAI', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: 'anthropic', child: Text('Anthropic (Claude)', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: 'ollama', child: Text('Ollama (本地)', style: TextStyle(fontSize: 12))),
          ],
          onChanged: (preset) {
            if (preset == null) return;
            _applyProfilePreset(profile, preset);
            setDState(() {});
          },
        )),
        const SizedBox(height: 8),
      ],
      // 配置名
      field(zh ? '配置名' : 'Name', _ProfileTextField(
        value: profile.name,
        onChange: (v) { profile.name = v; },
      )),
      // 协议
      field(zh ? '请求方式 / 协议' : 'Protocol', SegmentedButton<String>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: 'openai', label: Text(zh ? 'OpenAI 兼容' : 'OpenAI', style: const TextStyle(fontSize: 11))),
          ButtonSegment(value: 'anthropic', label: Text('Anthropic', style: const TextStyle(fontSize: 11))),
        ],
        selected: {profile.provider},
        onSelectionChanged: (v) { profile.provider = v.first; setDState(() {}); },
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
      )),
      const SizedBox(height: 10),
      // API Key（可切换显示/隐藏）
      field(s.aiApiKey, _McpTextField(
        value: profile.apiKey,
        label: '',
        scheme: scheme,
        obscure: true,
        onChange: (v) { profile.apiKey = v; },
      )),
      // Base URL
      field(s.aiApiUrl, _ProfileTextField(
        value: profile.apiUrl,
        onChange: (v) { profile.apiUrl = v; },
      )),
      // 模型
      field(s.aiModel, _ProfileTextField(
        value: profile.model,
        onChange: (v) { profile.model = v; },
      )),
      // 上下文窗口
      field(zh ? '上下文窗口 (token)' : 'Context Window (tokens)', _ProfileTextField(
        value: profile.contextWindow.toString(),
        keyboardType: TextInputType.number,
        onChange: (v) { final n = int.tryParse(v); if (n != null && n >= 1000) profile.contextWindow = n; },
      )),
      // 最大输出
      field(zh ? '最大输出 token' : 'Max Output Tokens', _ProfileTextField(
        value: profile.maxTokens.toString(),
        keyboardType: TextInputType.number,
        onChange: (v) { final n = int.tryParse(v); if (n != null && n > 0) profile.maxTokens = n; },
      )),
      // 温度
      field(zh ? '温度 (0-2)' : 'Temperature (0-2)', _ProfileTextField(
        value: profile.temperature.toStringAsFixed(1),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChange: (v) { final t = double.tryParse(v); if (t != null && t >= 0 && t <= 2) profile.temperature = t; },
      )),
      // 操作按钮
      Row(children: [
        Expanded(child: FilledButton.icon(
          icon: const Icon(Icons.save_outlined, size: 16),
          label: Text(zh ? '保存' : 'Save', style: const TextStyle(fontSize: 12)),
          onPressed: () {
            final name = profile.name.trim();
            if (name.isEmpty) {
              showToast(ctx, zh ? '配置名不能为空' : 'Name is required', type: ToastType.error);
              return;
            }
            // 落库（编辑已有项或新项）
            state.updateConfig((c) {
              final i = c.aiProfiles.indexWhere((e) => e.id == profile.id);
              if (i >= 0) {
                c.aiProfiles[i] = profile;
              } else {
                c.aiProfiles.add(profile);
              }
              if (c.activeAiProfileId.isEmpty) c.activeAiProfileId = profile.id;
              return c;
            });
            showToast(ctx, zh ? '配置已保存' : 'Profile saved', type: ToastType.success);
          },
        )),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          icon: Icon(
            state.config.activeAiProfileId == profile.id ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 16,
          ),
          label: Text(zh ? '设为当前' : 'Use', style: const TextStyle(fontSize: 12)),
          onPressed: () {
            state.updateConfig((c) { c.activeAiProfileId = profile.id; return c; });
            setDState(() {});
          },
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _iosButton(icon: Icons.wifi_tethering, label: s.aiPing,
            color: scheme.primary, bg: scheme.primaryContainer,
            onTap: () {
              // 把当前配置临时同步到默认字段，供测试函数使用
              state.updateConfig((c) {
                c.aiApiKey = profile.apiKey;
                c.aiApiUrl = profile.apiUrl;
                c.aiProvider = profile.provider;
                return c;
              }).ignore();
              _pingAi(ctx, state, s);
            })),
        const SizedBox(width: 8),
        Expanded(child: _iosButton(icon: Icons.list, label: s.aiListModels,
            color: scheme.onSecondaryContainer, bg: scheme.secondaryContainer,
            onTap: () {
              state.updateConfig((c) {
                c.aiApiKey = profile.apiKey;
                c.aiApiUrl = profile.apiUrl;
                c.aiProvider = profile.provider;
                return c;
              }).ignore();
              _listAiModels(ctx, state, s, onPicked: () => setDState(() {}));
            })),
      ]),
      if (draft != null) ...[
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          icon: const Icon(Icons.delete_outline, size: 16),
          label: Text(zh ? '删除此配置' : 'Delete this profile', style: const TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
          onPressed: () {
            state.updateConfig((c) {
              c.aiProfiles.removeWhere((e) => e.id == profile.id);
              if (c.activeAiProfileId == profile.id) c.activeAiProfileId = '';
              return c;
            });
            onDeleted();
          },
        )),
      ],
    ]),
  );
}

/// Anthropic 的 /v1/models 拿不到时的兜底列表。
const _kKnownAnthropicModels = [
  'claude-opus-5',
  'claude-sonnet-5',
  'claude-haiku-4-5',
];

String _httpReason(int code) => switch (code) {
  400 => 'Bad Request',
  401 => 'Unauthorized (check API Key)',
  403 => 'Forbidden',
  404 => 'Not Found (check API URL)',
  429 => 'Too Many Requests',
  500 => 'Server Error',
  502 => 'Bad Gateway',
  503 => 'Service Unavailable',
  _ => 'Error',
};

Future<void> _pingAi(BuildContext ctx, AppState state, AppStrings s) async {
  final cfg = state.config;
  if (cfg.aiApiKey.isEmpty) {
    if (ctx.mounted) showToast(ctx, s.aiNotConfigured, type: ToastType.warning);
    return;
  }
  final baseUrl = cfg.aiApiUrl.replaceAll(RegExp(r'/chat/completions$|/messages$'), '');
  final modelsUrl = baseUrl.endsWith('/v1') ? '$baseUrl/models' : '$baseUrl/v1/models';
  state.addLog('[AI] Ping $modelsUrl ...', category: 'info');
  try {
    final uri = Uri.parse(modelsUrl);
    final headers = <String, String>{};
    if (cfg.aiProvider == 'anthropic') {
      headers['x-api-key'] = cfg.aiApiKey;
      headers['anthropic-version'] = '2023-06-01';
    } else {
      headers['Authorization'] = 'Bearer ${cfg.aiApiKey}';
    }
    final sw = Stopwatch()..start();
    final resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
    sw.stop();
    final ms = sw.elapsedMilliseconds;
    final ok = resp.statusCode >= 200 && resp.statusCode < 400;
    state.addLog('[AI] Ping ${ok ? "OK" : "FAIL"}: ${resp.statusCode}, ${ms}ms', category: ok ? 'info' : 'error');
    if (ctx.mounted) showToast(ctx, ok ? '${resp.statusCode} OK — ${ms}ms' : 'HTTP ${resp.statusCode} ${_httpReason(resp.statusCode)}', type: ok ? ToastType.success : ToastType.error);
  } catch (e) {
    state.addLog('[AI] Ping failed: $e', category: 'error');
    if (ctx.mounted) showToast(ctx, 'Error: $e', type: ToastType.error);
  }
}

Future<void> _listAiModels(BuildContext ctx, AppState state, AppStrings s, {VoidCallback? onPicked}) async {
  final cfg = state.config;
  if (cfg.aiApiKey.isEmpty) {
    if (ctx.mounted) showToast(ctx, s.aiNotConfigured, type: ToastType.warning);
    return;
  }
  state.addLog('[AI] 获取模型列表...', category: 'info');
  try {
    final headers = <String, String>{};
    if (cfg.aiProvider == 'anthropic') {
      final baseUrl = cfg.aiApiUrl.replaceAll(RegExp(r'/messages$'), '');
      final modelsUrl = baseUrl.endsWith('/v1') ? '$baseUrl/models' : '$baseUrl/v1/models';
      headers['x-api-key'] = cfg.aiApiKey;
      headers['anthropic-version'] = '2023-06-01';
      final resp = await http.get(Uri.parse(modelsUrl), headers: headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final models = (data['data'] as List?)?.map((m) => m['id'] as String).toList() ?? [];
        models.sort();
        state.addLog('[AI] Anthropic 获取到 ${models.length} 个模型', category: 'info');
        if (ctx.mounted) _showModelPicker(ctx, state, models, s, onPicked);
      } else {
        state.addLog('[AI] Anthropic models endpoint unavailable (${resp.statusCode}), using known models', category: 'info');
        if (ctx.mounted) _showModelPicker(ctx, state, List.of(_kKnownAnthropicModels), s, onPicked);
      }
      return;
    }
    // OpenAI-compatible: GET /v1/models
    final baseUrl = cfg.aiApiUrl.replaceAll(RegExp(r'/chat/completions$'), '');
    headers['Authorization'] = 'Bearer ${cfg.aiApiKey}';
    final resp = await http.get(Uri.parse('$baseUrl/models'), headers: headers).timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      final models = (data['data'] as List?)?.map((m) => m['id'] as String).toList() ?? [];
      models.sort();
      state.addLog('[AI] 获取到 ${models.length} 个模型', category: 'info');
      if (ctx.mounted) _showModelPicker(ctx, state, models, s, onPicked);
    } else {
      state.addLog('[AI] 获取模型失败: ${resp.statusCode}', category: 'error');
      if (ctx.mounted) showToast(ctx, 'HTTP ${resp.statusCode}', type: ToastType.error);
    }
  } catch (e) {
    state.addLog('[AI] 获取模型失败: $e', category: 'error');
    if (ctx.mounted) showToast(ctx, 'Error: $e', type: ToastType.error);
  }
}

void _showModelPicker(BuildContext ctx, AppState state, List<String> models, AppStrings s, VoidCallback? onPicked) {
  if (models.isEmpty) {
    showToast(ctx, s.isZh ? '未找到模型' : 'No models found', type: ToastType.warning);
    return;
  }
  showDialog(context: ctx, builder: (dCtx) {
    final scheme = Theme.of(dCtx).colorScheme;
    return AlertDialog(
      title: Text(s.aiListModels, style: TextStyle(color: scheme.onSurface, fontSize: 15)),
      content: SizedBox(
        width: 300, height: 400,
        child: ListView.builder(
          itemCount: models.length,
          itemBuilder: (_, i) => ListTile(
            dense: true,
            title: Text(models[i], style: TextStyle(fontSize: 12, color: scheme.onSurface)),
            selected: models[i] == state.config.aiModel,
            selectedTileColor: scheme.primaryContainer.withAlpha(60),
            onTap: () {
              state.updateConfig((c) => c..aiModel = models[i]);
              state.addLog('[AI] 已选择模型: ${models[i]}', category: 'info');
              Navigator.pop(dCtx);
              onPicked?.call();
              showToast(ctx, '${s.isZh ? "已选择" : "Selected"}: ${models[i]}', type: ToastType.success);
            },
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(s.close))],
    );
  });
}

Future<void> _pickFont(BuildContext ctx, AppState state) async {
  final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['ttf', 'otf']);
  if (r == null || r.files.isEmpty || r.files.first.path == null) return;
  final path = r.files.first.path;
  if (path == null) return;
  final fileName = path.split(RegExp(r'[\\/]')).last;
  final fontName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
  final isZh = state.config.language == 'zh';
  final copiedPath = await _copyToAppDir(path, 'fonts');
  final fontFilePath = copiedPath ?? path;
  try {
    final fontLoader = FontLoader(fontName);
    final fontFile = File(fontFilePath);
    if (await fontFile.exists()) {
      final bytes = await fontFile.readAsBytes();
      fontLoader.addFont(Future.value(ByteData.view(bytes.buffer)));
      await fontLoader.load();
      state.updateConfig((c) => c..fontFamily = fontName);
      if (ctx.mounted) showToast(ctx, isZh ? '字体 "$fontName" 已加载并应用' : 'Font "$fontName" loaded and applied', type: ToastType.success);
    }
  } catch (e) {
    // 加载失败不设置 fontFamily（否则全局文本回退到坏字体）
    if (ctx.mounted) showToast(ctx, isZh ? '字体加载失败: $e' : 'Font load failed: $e', type: ToastType.error);
  }
}

Future<void> _clearCache(BuildContext ctx, AppState state, ColorScheme scheme, AppStrings s) async {
  final confirmed = await showDialog<bool>(
    context: ctx,
    builder: (dCtx) => AlertDialog(
      title: Text(s.isZh ? '确认清除缓存' : 'Confirm Clear Cache', style: TextStyle(color: scheme.onSurface)),
      content: Text(s.isZh ? '将清除已导入的字体文件和背景图片。\n清除后需要重新选择字体和背景。\n\n确定继续？'
          : 'This will clear imported fonts and background images.\nYou will need to re-select them.\n\nContinue?',
          style: TextStyle(color: scheme.onSurface)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(s.isZh ? '取消' : 'Cancel')),
        FilledButton(onPressed: () => Navigator.pop(dCtx, true),
            style: FilledButton.styleFrom(backgroundColor: scheme.error), child: Text(s.isZh ? '清除' : 'Clear')),
      ],
    ),
  );
  if (confirmed != true || !ctx.mounted) return;
  try {
    final dataDir = _userDataDir();
    // 记下被删掉的字体名：如果当前正在用其中之一，就回退到系统默认字体，
    // 否则 fontFamily 会一直指向一个已经不存在的字体。
    final removedFonts = <String>{};
    for (final sub in ['fonts', 'background']) {
      final dir = Directory('$dataDir$_s$sub');
      if (dir.existsSync()) {
        for (final f in dir.listSync().whereType<File>()) {
          if (sub == 'fonts') {
            removedFonts.add(f.path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), ''));
          }
          try { f.deleteSync(); } catch (_) {}
        }
      }
    }
    state.updateConfig((c) {
      c.backgroundImage = '';
      if (removedFonts.contains(c.fontFamily)) c.fontFamily = AppConfig.defaultFontFamily;
      return c;
    });
    if (ctx.mounted) showToast(ctx, s.isZh ? '缓存已清除' : 'Cache cleared', type: ToastType.success);
  } catch (e) {
    if (ctx.mounted) showToast(ctx, s.isZh ? '清除失败: $e' : 'Clear failed: $e', type: ToastType.error);
  }
}

Future<void> _checkForUpdate(BuildContext ctx, AppStrings s) async {
  showToast(ctx, s.checking, type: ToastType.info);
  final result = await updater.checkForUpdate(preferLanzou: s.isZh);
  if (!ctx.mounted) return;
  if (result.error != null && !result.hasUpdate) {
    showToast(ctx, s.updateFailed, type: ToastType.error);
    return;
  }
  if (!result.hasUpdate) {
    showToast(ctx, '${s.alreadyLatest} (v${updater.currentVersion})', type: ToastType.success);
    return;
  }
  _showUpdateDialog(ctx, s, result);
}

void _showUpdateDialog(BuildContext ctx, AppStrings s, updater.UpdateResult result) {
  final scheme = Theme.of(ctx).colorScheme;
  final isGithub = result.source == updater.UpdateSource.github;
  showDialog(
    context: ctx,
    builder: (dCtx) => AlertDialog(
      icon: Icon(Icons.system_update, color: scheme.primary, size: 32),
      title: Text(s.updateAvailable, style: TextStyle(color: scheme.onSurface)),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.isZh ? '新版本: v${result.remoteVersion}\n当前版本: v${updater.currentVersion}'
            : 'New: v${result.remoteVersion}\nCurrent: v${updater.currentVersion}', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        if (result.password != null && result.password!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.key, size: 14, color: scheme.primary),
            const SizedBox(width: 4),
            Text(s.isZh ? '提取密码: ' : 'Password: ', style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
            SelectableText(result.password!, style: TextStyle(fontSize: 13, color: scheme.onSurface, fontWeight: FontWeight.bold)),
          ]),
        ],
        const SizedBox(height: 12),
        Text(s.isZh ? '更新日志:' : 'Release Notes:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
        const SizedBox(height: 4),
        if (result.releaseNotes != null && result.releaseNotes!.isNotEmpty)
          ConstrainedBox(constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(child: Text(result.releaseNotes!, style: TextStyle(fontSize: 11, color: scheme.onSurface))))
        else
          Text(result.releaseNotesError
              ? (s.isZh ? '无法获取更新日志 (GitHub 连接失败)' : 'Failed to get release notes (GitHub connection failed)')
              : (s.isZh ? '暂无更新日志' : 'No release notes available'),
              style: TextStyle(fontSize: 11, color: scheme.outline, fontStyle: FontStyle.italic)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(s.aboutClose)),
        if (isGithub && result.downloadUrl != null)
          FilledButton(onPressed: () { Navigator.pop(dCtx); _downloadAndInstall(ctx, s, result.downloadUrl!); },
              child: Text(s.isZh ? '自动更新' : 'Auto Update'))
        else
          FilledButton(onPressed: () {
            Navigator.pop(dCtx);
            openExternalUrl(result.downloadUrl ?? 'https://github.com/lvbaoshigao/FFmpeg_plus_plus/releases/latest');
          }, child: Text(s.goDownload)),
      ],
    ),
  );
}

Future<void> _downloadAndInstall(BuildContext ctx, AppStrings s, String url) async {
  final scheme = Theme.of(ctx).colorScheme;
  final progressNotifier = ValueNotifier<double>(0);
  final statusNotifier = ValueNotifier<String>(s.isZh ? '准备下载...' : 'Preparing...');
  var dialogOpen = true;
  showDialog(context: ctx, barrierDismissible: false,
    builder: (_) => PopScope(canPop: false, child: AlertDialog(
      title: Text(s.isZh ? '下载更新' : 'Downloading Update', style: TextStyle(color: scheme.onSurface)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        ValueListenableBuilder<double>(valueListenable: progressNotifier,
            builder: (_, v, _) => LinearProgressIndicator(value: v > 0 ? v : null)),
        const SizedBox(height: 8),
        ValueListenableBuilder<String>(valueListenable: statusNotifier,
            builder: (_, v, _) => Text(v, style: TextStyle(fontSize: 11, color: scheme.outline))),
      ]),
    )),
  ).whenComplete(() => dialogOpen = false);
  try {
    final filePath = await updater.downloadUpdate(url, onProgress: (received, total) {
      if (total > 0) {
        progressNotifier.value = received / total;
        statusNotifier.value = '${(received / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} MB';
      }
    });
    if (!ctx.mounted) return;
    if (dialogOpen) Navigator.pop(ctx);
    await updater.installAndRestart(filePath);
  } catch (e) {
    if (ctx.mounted) {
      if (dialogOpen) Navigator.pop(ctx);
      showToast(ctx, '${s.updateFailed}: $e', type: ToastType.error);
    }
  } finally {
    progressNotifier.dispose();
    statusNotifier.dispose();
  }
}

Future<void> _pickColor(BuildContext ctx, AppState state) async {
  final isZh = state.config.language == 'zh';
  final cp = _CP(
    initial: Color(state.config.themeColor),
    initial2: state.config.themeColor2 >= 0 ? Color(state.config.themeColor2) : null,
    isZh: isZh,
  );
  // 移动端：底部弹层（全宽、自滚动），避免固定 320px 弹窗在窄屏上挤压出下划线/裁切伪影
  final res = isMobilePlatform
      ? await showModalBottomSheet<_GradResult>(
          context: ctx,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => SafeArea(top: false, child: cp),
        )
      : await showDialog<_GradResult>(context: ctx, builder: (_) => Center(
          child: SizedBox(width: 320, child: cp),
        ));
  if (res == null) return;
  state.updateConfig((c) => c..themeColor = res.c1..themeColor2 = res.c2 ?? -1);
}

void _showSponsor(BuildContext ctx, ColorScheme scheme, AppStrings s) {
  showDialog(context: ctx, builder: (dCtx) => AlertDialog(
    title: Text(s.aboutSponsor, style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w700, fontSize: 18)),
    content: SizedBox(width: 480, child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(s.aboutThanks, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
      const SizedBox(height: 12),
      Text(s.aboutZoomHint, style: TextStyle(fontSize: 10, color: scheme.outline)),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Expanded(child: _qrImage(ctx, 'rele/wx.png', s.aboutWxTitle, scheme)),
        const SizedBox(width: 16),
        Expanded(child: _qrImage(ctx, 'rele/zfb.jpg', s.aboutZfbTitle, scheme)),
      ]),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(s.aboutClose))],
  ));
}

Widget _qrImage(BuildContext ctx, String asset, String label, ColorScheme scheme) => GestureDetector(
  onTap: () => _showFullImage(ctx, asset, scheme),
  child: Column(children: [
    Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
    const SizedBox(height: 8),
    ClipRRect(borderRadius: BorderRadius.circular(8),
        child: Image.asset(asset, height: 160, fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Container(height: 160, alignment: Alignment.center,
                child: Text('加载失败', style: TextStyle(color: scheme.outline))))),
  ]),
);

void _showFullImage(BuildContext ctx, String asset, ColorScheme scheme) {
  showDialog(context: ctx, builder: (dCtx) => Dialog(
    backgroundColor: Colors.transparent,
    child: GestureDetector(onTap: () => Navigator.pop(dCtx),
      child: InteractiveViewer(minScale: 0.5, maxScale: 4.0,
        child: ClipRRect(borderRadius: BorderRadius.circular(12),
            child: Image.asset(asset, fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Container(padding: const EdgeInsets.all(32),
                    child: Text('加载失败', style: TextStyle(color: scheme.outline)))))),
    ),
  ));
}

// ═══════════════════════════════════════════
// FFmpeg 检测卡片
// ═══════════════════════════════════════════

class _FfmpegCard extends StatefulWidget {
  final AppState state;
  const _FfmpegCard({required this.state});
  @override
  State<_FfmpegCard> createState() => _FfmpegCardState();
}

class _FfmpegCardState extends State<_FfmpegCard> {
  bool _checking = false;
  bool _found = false;
  String _version = '';
  String _path = '';

  @override
  void initState() { super.initState(); _syncState(); }

  @override
  void didUpdateWidget(_FfmpegCard old) {
    super.didUpdateWidget(old);
    if (!_checking) _syncState();
  }

  void _syncState() {
    _found = widget.state.envOk;
    _version = widget.state.ffmpegVersion;
    _path = widget.state.config.ffmpegPath;
  }

  Future<void> _detect() async {
    setState(() => _checking = true);
    await widget.state.recheckEnv();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _found = widget.state.envOk;
      _version = widget.state.ffmpegVersion;
      _path = widget.state.config.ffmpegPath;
    });
    widget.state.addLog(_found ? 'FFmpeg detected: $_version' : 'FFmpeg not found', category: _found ? 'ffmpeg' : 'error');
  }

  Future<void> _browseFfmpeg() async {
    final isZh = widget.state.config.language == 'zh';
    final r = await FilePicker.platform.pickFiles(
      type: Platform.isWindows ? FileType.custom : FileType.any,
      allowedExtensions: Platform.isWindows ? ['exe'] : null,
      dialogTitle: isZh ? '选择 ffmpeg' : 'Select ffmpeg',
    );
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;
    final exePath = r.files.first.path;
    if (exePath == null) return;
    setState(() => _checking = true);
    try {
      final result = await Process.run(exePath, ['-version'], runInShell: false);
      if (result.exitCode == 0 && result.stdout.toString().contains('ffmpeg version')) {
        final versionLine = result.stdout.toString().split('\n').first;
        final dir = exePath.replaceAll(RegExp(r'[\\/][^\\/]+$'), '');
        final ffprobeName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
        if (!mounted) return;
        setState(() { _found = true; _version = versionLine; _path = exePath; _checking = false; });
        widget.state.updateConfig((c) => c..ffmpegPath = exePath..ffprobePath = '$dir${Platform.pathSeparator}$ffprobeName');
        widget.state.backend.setPaths(ffmpeg: exePath, ffprobe: '$dir${Platform.pathSeparator}$ffprobeName');
        if (Platform.isWindows) await _addToPath(dir);
        widget.state.addLog('FFmpeg configured: $_version', category: 'ffmpeg');
        if (mounted) showToast(context, 'FFmpeg found at: $dir', type: ToastType.success);
      } else {
        if (!mounted) return;
        setState(() => _checking = false);
        showToast(context, isZh ? '所选文件不是有效的 ffmpeg' : 'Selected file is not a valid ffmpeg', type: ToastType.error);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _checking = false);
      showToast(context, isZh ? '检测失败: $e' : 'Detection failed: $e', type: ToastType.error);
    }
  }

  Future<void> _addToPath(String dir) async {
    if (!Platform.isWindows) return;
    final isZh = widget.state.config.language == 'zh';
    try {
      final regResult = await Process.run('cmd', ['/c', 'echo %PATH%']);
      if (regResult.stdout.toString().contains(dir)) return;
      final regResult2 = await Process.run('reg', ['query', r'HKCU\Environment', '/v', 'Path']);
      var existingPath = '';
      if (regResult2.exitCode == 0) {
        for (final line in regResult2.stdout.toString().split('\n')) {
          if (line.contains('Path') && line.contains('REG_')) {
            existingPath = line.split('REG_').last.trim().replaceFirst(RegExp(r'^\w+\s+'), '');
            break;
          }
        }
      }
      existingPath = existingPath.trim();
      if (existingPath.contains(dir)) return;
      // 只有 reg 查询成功且现有 PATH 非空时才追加；否则跳过，避免覆盖用户 PATH
      if (regResult2.exitCode != 0 || existingPath.isEmpty) {
        if (mounted) showToast(context, isZh ? '读取 PATH 失败，已跳过添加到系统 PATH' : 'Failed to read PATH, skipped adding', type: ToastType.error);
        return;
      }
      final newPath = '$existingPath;$dir';
      if (newPath.length > 1024) {
        if (mounted) showToast(context, isZh ? 'PATH 过长（超过 1024 字符），已跳过' : 'PATH too long (>1024 chars), skipped', type: ToastType.warning);
        return;
      }
      await Process.run('setx', ['Path', newPath]);
    } catch (e) {
      if (mounted) showToast(context, isZh ? '添加到系统 PATH 失败: $e' : 'Failed to add to PATH: $e', type: ToastType.error);
    }
  }

  Future<void> _confirmDelete(bool isZh) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final s = Theme.of(ctx).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.delete_forever, color: s.error, size: 32),
          title: Text(isZh ? '删除 FFmpeg' : 'Delete FFmpeg'),
          content: Text(isZh ? '将删除程序目录下的 ffmpeg.exe 和 ffprobe.exe，确定？'
              : 'Delete ffmpeg.exe and ffprobe.exe from the app directory?', style: TextStyle(fontSize: 13, color: s.onSurface)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(isZh ? '取消' : 'Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: s.error),
                child: Text(isZh ? '删除' : 'Delete')),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    FfmpegInstaller.uninstall();
    widget.state.updateConfig((c) => c..ffmpegPath = ''..ffprobePath = '');
    setState(() { _found = false; _version = ''; _path = ''; });
    widget.state.addLog('已删除程序目录下的 FFmpeg', category: 'info');
    if (mounted) showToast(context, isZh ? 'FFmpeg 已删除' : 'FFmpeg deleted', type: ToastType.info);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = widget.state.config;
    final s = AppStrings.of(cfg.language);
    final isZh = cfg.language == 'zh';

    // 移动端：FFmpeg 已内置在 APK 中（jniLibs），无需安装/选择/删除
    if (isMobilePlatform) {
      return _glass(context, widget.state, s.ffmpegSettings, [
        Row(children: [
          Icon(Icons.check_circle, size: 16, color: _found ? Colors.green : Colors.orange),
          const SizedBox(width: 8),
          Expanded(child: Text(
              _found ? s.ffmpegFound : (isZh ? '内置 FFmpeg 加载中…' : 'Bundled FFmpeg loading…'),
              style: TextStyle(fontSize: 13,
                  color: _found ? Colors.green : Colors.orange,
                  fontWeight: FontWeight.w600))),
        ]),
        if (_version.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4, bottom: 6),
              child: Text(_version, style: TextStyle(fontSize: 10, color: scheme.outline),
                  maxLines: 2, overflow: TextOverflow.ellipsis)),
        if (_path.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 6),
              child: Text(_path, style: TextStyle(fontSize: 9, color: scheme.outline.withAlpha(150)),
                  maxLines: 2, overflow: TextOverflow.ellipsis)),
        Row(children: [
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.refresh, size: 14),
              label: Text(s.recheck, style: const TextStyle(fontSize: 11)), onPressed: _detect)),
        ]),
        const SizedBox(height: 4),
        Text(isZh ? '移动端已内置 FFmpeg 库，无需额外安装'
            : 'FFmpeg is bundled with the app on mobile — no installation needed',
            style: TextStyle(fontSize: 10, color: scheme.outline)),
      ]);
    }

    if (!_found && !_checking) {
      return _glass(context, widget.state, s.ffmpegSettings, [
        Center(child: Column(children: [
          const Icon(Icons.warning_amber, size: 32, color: Colors.orange),
          const SizedBox(height: 8),
          Text(s.ffmpegNotFound, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.orange)),
          const SizedBox(height: 12),
          FilledButton.icon(icon: const Icon(Icons.download, size: 18),
              label: Text(isZh ? '自动安装 FFmpeg' : 'Install FFmpeg', style: const TextStyle(fontSize: 13)),
              onPressed: () async { final ok = await FfmpegInstallDialog.show(context); if (ok == true) _detect(); }),
          const SizedBox(height: 8),
          Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton.tonalIcon(icon: const Icon(Icons.search, size: 16),
                label: Text(isZh ? '检测' : 'Detect', style: const TextStyle(fontSize: 11)), onPressed: _detect),
            const SizedBox(width: 8),
            TextButton.icon(icon: const Icon(Icons.folder_open, size: 14),
                label: Text(isZh ? '手动选择' : 'Manual', style: const TextStyle(fontSize: 11)), onPressed: _browseFfmpeg),
          ]),
        ])),
        const SizedBox(height: 4),
        Wrap(spacing: 4, runSpacing: 4, alignment: WrapAlignment.center, children: _ffmpegLinks),
      ]);
    }

    if (_checking) {
      return _glass(context, widget.state, s.ffmpegSettings, [
        const SizedBox(height: 12),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 8),
        Center(child: Text(isZh ? '正在检测...' : 'Detecting...', style: TextStyle(fontSize: 12, color: scheme.outline))),
      ]);
    }

    final isBundled = FfmpegInstaller.isInstalled &&
        _path.isNotEmpty && _path.startsWith(Directory(Platform.resolvedExecutable).parent.path);
    return _glass(context, widget.state, s.ffmpegSettings, [
      Row(children: [
        const Icon(Icons.check_circle, size: 16, color: Colors.green),
        const SizedBox(width: 8),
        Expanded(child: Text(s.ffmpegFound, style: const TextStyle(fontSize: 13, color: Colors.green, fontWeight: FontWeight.w600))),
      ]),
      if (_version.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Text(_version, style: TextStyle(fontSize: 10, color: scheme.outline), maxLines: 2, overflow: TextOverflow.ellipsis)),
      if (_path.isNotEmpty)
        Padding(padding: const EdgeInsets.only(bottom: 6),
            child: Text(_path, style: TextStyle(fontSize: 9, color: scheme.outline.withAlpha(150)), maxLines: 2, overflow: TextOverflow.ellipsis)),
      Row(children: [
        Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.refresh, size: 14),
            label: Text(s.recheck, style: const TextStyle(fontSize: 11)), onPressed: _detect)),
        if (isBundled) ...[
          const SizedBox(width: 8),
          OutlinedButton.icon(icon: Icon(Icons.delete_outline, size: 14, color: scheme.error),
              label: Text(isZh ? '删除' : 'Delete', style: TextStyle(fontSize: 11, color: scheme.error)),
              style: OutlinedButton.styleFrom(side: BorderSide(color: scheme.error.withAlpha(120))),
              onPressed: () => _confirmDelete(isZh)),
        ],
      ]),
      const SizedBox(height: 4),
      Wrap(spacing: 4, runSpacing: 4, children: _ffmpegLinks),
    ]);
  }

  static List<Widget> get _ffmpegLinks => [
    _link('ffmpeg.org', 'https://ffmpeg.org'),
    _link('gyan.dev', 'https://github.com/AnimMouse/ffmpeg-stable-autobuild'),
    _link('BtbN', 'https://github.com/BtbN/FFmpeg-Builds/releases'),
  ];
}

// ═══════════════════════════════════════════
// 取色器
// ═══════════════════════════════════════════

/// 渐变主题色选择结果：c1=起色，c2 为 null 表示纯色主题
class _GradResult {
  final int c1;
  final int? c2;
  _GradResult(this.c1, this.c2);
}

/// 主题渐变色预设（起色, 止色, 名称）
const _gradPresets = <(int, int, String)>[
  (0xFF5E6AD2, 0xFF8B5CF6, '紫罗兰'),
  (0xFF3B82F6, 0xFF06B6D4, '海洋'),
  (0xFF10B981, 0xFF84CC16, '翡翠'),
  (0xFFF59E0B, 0xFFEF4444, '熔岩'),
  (0xFFEC4899, 0xFFF97316, '日落'),
  (0xFF8B5CF6, 0xFFEC4899, '霓虹'),
  (0xFF64748B, 0xFF0EA5E9, '钢蓝'),
  (0xFF111827, 0xFF5E6AD2, '夜幕'),
];

class _CP extends StatefulWidget {
  final Color initial;
  final Color? initial2;
  final bool isZh;
  const _CP({required this.initial, required this.isZh, this.initial2});
  @override
  State<_CP> createState() => _CPState();
}

class _CPState extends State<_CP> {
  late double _h1, _s1, _v1;
  late double _h2, _s2, _v2;
  // null = 纯色主题；非 null = 渐变主题
  bool _gradEnabled;

  _CPState() : _gradEnabled = false;

  @override
  void initState() {
    super.initState();
    final h1 = HSVColor.fromColor(widget.initial);
    _h1 = h1.hue; _s1 = h1.saturation; _v1 = h1.value;
    if (widget.initial2 != null) {
      _gradEnabled = true;
      final h2 = HSVColor.fromColor(widget.initial2!);
      _h2 = h2.hue; _s2 = h2.saturation; _v2 = h2.value;
    } else {
      _gradEnabled = false;
      final h2 = HSVColor.fromColor(widget.initial);
      _h2 = h2.hue + 20; _s2 = h2.saturation; _v2 = h2.value;
    }
  }

  Color get c1 => HSVColor.fromAHSV(1, _h1, _s1, _v1).toColor();
  Color get c2 => HSVColor.fromAHSV(1, _h2, _s2, _v2).toColor();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    const sectionHint = TextStyle(fontSize: 10, color: Color(0xFF9AA0A6));
    // 液态玻璃：跟随全局玻璃配置（液态/模糊/无效果），主题着色跟随 glassFollowTheme
    return GlassPanel(
      radius: 18,
      blur: 14,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 560),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(Icons.palette_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(widget.isZh ? '主题颜色' : 'Theme Color',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Icon(Icons.close, size: 18, color: scheme.outline),
              ),
            ]),
            const SizedBox(height: 12),
            // 预览：纯色或渐变
            Container(height: 44, width: double.infinity, alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _gradEnabled ? null : c1,
                gradient: _gradEnabled
                    ? LinearGradient(colors: [c1, c2], begin: Alignment.topLeft, end: Alignment.bottomRight)
                    : null,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
              ),
              child: Text(_gradEnabled ? (widget.isZh ? '渐变' : 'Gradient') : (widget.isZh ? '纯色' : 'Solid'),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
            ),
            const SizedBox(height: 12),
            // 是否使用渐变色（通俗开关）
            Row(children: [
              Icon(Icons.auto_awesome, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.isZh ? '使用渐变色' : 'Use gradient',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface))),
              Switch(
                value: _gradEnabled,
                onChanged: (v) => setState(() => _gradEnabled = v),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ]),
            const SizedBox(height: 12),
            // 常用色板（单色 / 渐变通用）
            Text(widget.isZh ? '常用颜色' : 'Common colors', style: labelStyle),
            const SizedBox(height: 8),
            if (_gradEnabled)
              Wrap(spacing: 8, runSpacing: 8, children: _gradPresets.map((g) {
                final selected = g.$1 == c1.toARGB32() && g.$2 == c2.toARGB32();
                return GestureDetector(
                  onTap: () {
                    final h1 = HSVColor.fromColor(Color(g.$1));
                    final h2 = HSVColor.fromColor(Color(g.$2));
                    setState(() { _h1 = h1.hue; _s1 = h1.saturation; _v1 = h1.value; _h2 = h2.hue; _s2 = h2.saturation; _v2 = h2.value; _gradEnabled = true; });
                  },
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Color(g.$1), Color(g.$2)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                      shape: BoxShape.circle,
                      border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant.withAlpha(90), width: selected ? 3 : 1),
                    ),
                  ),
                );
              }).toList())
            else
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final preset in const [
                  0xFF5E6AD2, 0xFF3B82F6, 0xFF06B6D4, 0xFF10B981, 0xFF84CC16,
                  0xFFF59E0B, 0xFFF97316, 0xFFEF4444, 0xFFEC4899, 0xFF8B5CF6,
                  0xFF64748B, 0xFF000000, 0xFFFFFFFF, 0xFFF8FAFC,
                ])
                  GestureDetector(
                    onTap: () {
                      final hsv = HSVColor.fromColor(Color(preset));
                      setState(() { _h1 = hsv.hue; _s1 = hsv.saturation; _v1 = hsv.value; });
                    },
                    child: Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                        color: Color(preset),
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
                      ),
                      child: preset == c1.toARGB32() ? const Icon(Icons.check, size: 13, color: Colors.white) : null,
                    ),
                  ),
              ]),
            const SizedBox(height: 12),
            // 自定义微调
            Text(widget.isZh ? '自定义微调' : 'Fine-tune', style: labelStyle),
            Text(widget.isZh ? '用色相 / 饱和度 / 明度精确调整颜色' : 'Adjust hue / saturation / value precisely',
                style: sectionHint),
            const SizedBox(height: 4),
            _colorRow(c1, [
              _sl('H', _h1, 0, 360, (v) => setState(() => _h1 = v)),
              _sl('S', _s1, 0, 1, (v) => setState(() => _s1 = v)),
              _sl('V', _v1, 0, 1, (v) => setState(() => _v1 = v)),
            ]),
            if (_gradEnabled) ...[
              const SizedBox(height: 6),
              Text(widget.isZh ? '第二种颜色（渐变终点）' : 'Second color (end of gradient)', style: labelStyle),
              const SizedBox(height: 4),
              _colorRow(c2, [
                _sl('H', _h2, 0, 360, (v) => setState(() => _h2 = v)),
                _sl('S', _s2, 0, 1, (v) => setState(() => _s2 = v)),
                _sl('V', _v2, 0, 1, (v) => setState(() => _v2 = v)),
              ]),
            ],
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text('#${_hex(c1)}${_gradEnabled ? ' → #${_hex(c2)}' : ''}',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: scheme.onSurfaceVariant))),
              TextButton(onPressed: () => Navigator.pop(context), child: Text(widget.isZh ? '取消' : 'Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(context,
                    _GradResult(c1.toARGB32(), _gradEnabled ? c2.toARGB32() : null)),
                child: Text(widget.isZh ? '选择' : 'Select'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  String _hex(Color c) => c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

  Widget _colorRow(Color swatch, List<Widget> sliders) {
    return Row(children: [
      Container(width: 22, height: 22, decoration: BoxDecoration(
        color: swatch, shape: BoxShape.circle, border: Border.all(color: Color(0x33000000)))), 
      const SizedBox(width: 8),
      Expanded(child: Column(children: sliders)),
    ]);
  }

  Widget _sl(String l, double v, double min, double max, ValueChanged<double> cb) => Row(children: [
    SizedBox(width: 12, child: Text(l, style: TextStyle(fontSize: 10))),
    Expanded(child: Slider(value: v, min: min, max: max, onChanged: cb)),
  ]);
}

class _PathField extends StatefulWidget {
  final String value;
  final String label;
  final ColorScheme scheme;
  final ValueChanged<String> onChange;
  const _PathField({required this.value, required this.label, required this.scheme, required this.onChange});
  @override
  State<_PathField> createState() => _PathFieldState();
}

class _PathFieldState extends State<_PathField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_PathField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _ctrl.text != widget.value) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _ctrl,
    style: const TextStyle(fontSize: 12),
    decoration: InputDecoration(
      labelText: widget.label.isEmpty ? null : widget.label,
      isDense: true,
      border: const OutlineInputBorder(),
      labelStyle: TextStyle(fontSize: 11, color: widget.scheme.outline),
    ),
    onChanged: widget.onChange,
  );
}

class _McpTextField extends StatefulWidget {
  final String value;
  final String label;
  final String? hint;
  final ColorScheme scheme;
  final bool obscure;
  final int minLines;
  final int maxLines;
  final ValueChanged<String> onChange;
  const _McpTextField({
    required this.value,
    required this.label,
    required this.scheme,
    this.hint,
    this.obscure = false,
    this.minLines = 1,
    this.maxLines = 1,
    required this.onChange,
  });
  @override
  State<_McpTextField> createState() => _McpTextFieldState();
}

class _McpTextFieldState extends State<_McpTextField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.value);
  bool _hidden = true;

  @override
  void didUpdateWidget(_McpTextField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _ctrl.text != widget.value) _ctrl.text = widget.value;
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final obscuring = widget.obscure && _hidden;
    return TextField(
      controller: _ctrl,
      obscureText: obscuring,
      minLines: obscuring ? 1 : widget.minLines,
      maxLines: obscuring ? 1 : widget.maxLines,
      style: TextStyle(fontSize: 13, color: widget.scheme.onSurface),
      decoration: InputDecoration(
        labelText: widget.label.isEmpty ? null : widget.label,
        hintText: widget.hint,
        hintStyle: widget.hint == null ? null : TextStyle(fontSize: 11, color: widget.scheme.outline),
        isDense: true,
        alignLabelWithHint: widget.maxLines > 1,
        labelStyle: TextStyle(fontSize: 11, color: widget.scheme.outline),
        suffixIcon: widget.obscure ? IconButton(
          icon: Icon(_hidden ? Icons.visibility_off : Icons.visibility, size: 16, color: widget.scheme.outline),
          onPressed: () => setState(() => _hidden = !_hidden),
          padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        ) : null,
      ),
      onChanged: widget.onChange,
    );
  }
}

class _ProfileTextField extends StatefulWidget {
  final String value;
  final TextInputType? keyboardType;
  final ValueChanged<String> onChange;
  const _ProfileTextField({required this.value, this.keyboardType, required this.onChange});
  @override
  State<_ProfileTextField> createState() => _ProfileTextFieldState();
}

class _ProfileTextFieldState extends State<_ProfileTextField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_ProfileTextField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _ctrl.text != widget.value) _ctrl.text = widget.value;
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _ctrl,
    keyboardType: widget.keyboardType,
    style: const TextStyle(fontSize: 12),
    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
    onChanged: widget.onChange,
  );
}
