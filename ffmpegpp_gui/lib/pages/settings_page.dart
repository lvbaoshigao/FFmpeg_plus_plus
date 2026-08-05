import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/masonry_grid.dart';
import '../widgets/install_dialog.dart';
import 'keybinding_page.dart';
import '../widgets/font_picker.dart';
import '../services/ffmpeg_installer.dart';
import '../services/update_service.dart' as updater;
import '../services/shell_open.dart';
import '../widgets/toast.dart';
import '../widgets/glass_panel.dart';

final _s = Platform.pathSeparator;

/// 获取用户数据目录，避免 Program Files 权限问题
String _userDataDir() {
  if (Platform.isWindows) {
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

/// 用系统默认浏览器打开链接。见 [ShellOpen] 里关于 `cmd /c start` 注入的说明。
Future<void> openExternalUrl(String url) => ShellOpen.url(url);

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

  /// 被折叠起来的分区 id。默认全部展开。
  final Set<String> _collapsed = <String>{};

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
        _CardDef(
          id: 'shortcuts',
          title: (s) => s.cardShortcuts,
          keywords: ['快捷键', '键位', '按键', '热键', 'shortcut', 'keybinding',
              'keyboard', 'hotkey', 'key'],
          build: _buildShortcuts,
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
              actions: [
                if (visible.isNotEmpty && searching == false)
                  IconButton(
                    icon: Icon(allCollapsed ? Icons.unfold_more : Icons.unfold_less,
                        size: 19, color: scheme.outline),
                    tooltip: allCollapsed ? s.setExpandAll : s.setCollapseAll,
                    onPressed: () => _setAllCollapsed(!allCollapsed),
                  ),
                _searchField(scheme, s),
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
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.topCenter,
                                  child: (!searching && _collapsed.contains(sec.id))
                                      ? const SizedBox(width: double.infinity, height: 0)
                                      : Padding(
                                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                                          child: MasonryGrid(
                                            columns: cols,
                                            spacing: 12,
                                            runSpacing: 12,
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

  Widget _searchField(ColorScheme scheme, AppStrings s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: SizedBox(
          width: 260,
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
    return ClipRect(
      child: Material(
        color: scheme.surface.withAlpha(pinned ? 234 : 90),
        child: InkWell(
            onTap: onToggle,
            child: _headerTooltip(
              // 搜索中不能折叠，此时不挂 tooltip（空字符串会弹空气泡）
              onToggle == null ? null : toggleTooltip,
              SizedBox(
                height: 42,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 18, 0),
                  child: Row(children: [
                    AnimatedRotation(
                      turns: collapsed ? -0.25 : 0, // 展开朝下，折叠朝右
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: Icon(Icons.expand_more,
                          size: 18,
                          color: onToggle == null ? scheme.outline.withAlpha(90) : scheme.primary),
                    ),
                    const SizedBox(width: 4),
                    Icon(icon, size: 15, color: scheme.primary),
                    const SizedBox(width: 7),
                    Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.9,
                        color: scheme.primary,
                      ),
                    ),
                    // 折叠时提示里面还有几项，避免看起来像空分区
                    if (collapsed) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                        decoration: BoxDecoration(
                          color: scheme.primary.withAlpha(30),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text('$count',
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w600, color: scheme.primary)),
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
  Widget build(BuildContext context) => Row(children: [
        Text(widget.label(_current), style: widget.labelStyle),
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

Widget _buildTheme(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final scheme = Theme.of(ctx).colorScheme;
  final clr = scheme.onSurface;
  return _glass(ctx, state, s.cardTheme, [
    SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
        title: Text(s.darkMode, style: TextStyle(color: clr)),
        value: state.darkMode,
        onChanged: (v) => state.toggleDarkMode(v)),
    const SizedBox(height: 4),
    Text(s.accentColor, style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 8),
    Wrap(spacing: 8, runSpacing: 8, children: [
      ..._presets.map((p) => _dot(scheme, cfg.themeColor == p.$2, Color(p.$2), p.$1,
          () => state.updateConfig((c) => c..themeColor = p.$2))),
      _rainbow(scheme, () => _pickColor(ctx, state)),
    ]),
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
                final r = await FilePicker.platform.pickFiles(
                    type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp']);
                if (r != null && r.files.isNotEmpty && r.files.first.path != null) {
                  final copied = await _copyToAppDir(r.files.first.path!, 'background');
                  state.updateConfig((c) => c..backgroundImage = copied ?? r.files.first.path!);
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
      value: cfg.cardOpacity, min: 0.1, max: 1.0, divisions: 90,
      label: (v) => '${s.cardOpacity}: ${(v * 100).round()}%',
      labelStyle: TextStyle(color: clr, fontSize: 11),
      onCommit: (v) => state.updateConfig((c) => c..cardOpacity = v),
    ),
  ]);
}

Widget _buildLanguage(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final clr = Theme.of(ctx).colorScheme.onSurface;
  return _glass(ctx, state, s.language, [
    Text(s.languageInterface, style: TextStyle(color: clr, fontSize: 12)),
    const SizedBox(height: 6),
    SegmentedButton<String>(
      segments: const [ButtonSegment(value: 'zh', label: Text('中文')), ButtonSegment(value: 'en', label: Text('English'))],
      selected: {cfg.language},
      onSelectionChanged: (v) => state.updateConfig((c) => c..language = v.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    ),
  ]);
}

Widget _buildFont(BuildContext ctx, AppState state) {
  final cfg = state.config;
  final s = AppStrings.of(cfg.language);
  final clr = Theme.of(ctx).colorScheme.onSurface;
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
    SegmentedButton<int>(
      segments: List.generate(AppConfig.fontWeightLabels.length, (i) =>
          ButtonSegment(value: i, label: Text(AppConfig.fontWeightLabels[i], style: const TextStyle(fontSize: 10)))),
      selected: {cfg.fontWeightIndex},
      onSelectionChanged: (v) => state.updateConfig((c) => c..fontWeightIndex = v.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
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
    RadioGroup<bool>(
      groupValue: cfg.useNodeEditor,
      onChanged: (v) => state.updateConfig((c) => c..useNodeEditor = true),
      child: Column(children: [
        RadioListTile<bool>(dense: true, contentPadding: EdgeInsets.zero,
            title: Text(s.isZh ? '节点编辑器 (新)' : 'Node Editor (New)', style: TextStyle(color: clr, fontSize: 13)),
            subtitle: Text(s.isZh ? '蓝图式节点画布，可处理复杂的多步骤逻辑' : 'Blueprint-style canvas for complex multi-step logic', style: TextStyle(fontSize: 11, color: scheme.outline)),
            value: true),
        RadioListTile<bool>(dense: true, contentPadding: EdgeInsets.zero,
            title: Text(s.isZh ? '传统模式' : 'Classic Mode', style: TextStyle(color: clr, fontSize: 13)),
            subtitle: Text(s.isZh ? '傻瓜式操作，适合简单的视频处理任务' : 'Simple step-by-step, ideal for basic tasks', style: TextStyle(fontSize: 11, color: scheme.outline)),
            value: false),
      ]),
    ),
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

Widget _buildAbout(BuildContext ctx, AppState state) {
  final s = AppStrings.of(state.config.language);
  final scheme = Theme.of(ctx).colorScheme;
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
    _infoRow(s.aboutGithub, 'github.com/pity-Fox/FFmpeg_plus_plus', scheme),
    const SizedBox(height: 10),
    Row(children: [
      Expanded(child: _iosButton(icon: Icons.volunteer_activism, label: s.aboutSponsorBtn,
          color: scheme.primary, bg: scheme.primaryContainer, onTap: () => _showSponsor(ctx, scheme, s))),
      const SizedBox(width: 8),
      Expanded(child: _iosButton(icon: Icons.system_update, label: s.checkUpdate,
          color: scheme.onSecondaryContainer, bg: scheme.secondaryContainer, onTap: () => _checkForUpdate(ctx, s))),
    ]),
    const SizedBox(height: 10),
    Wrap(spacing: 4, runSpacing: 4, children: [
      _link(s.aboutBlogLink, 'https://blog-clstone.netlify.app/'),
      _link('GitHub', 'https://github.com/pity-Fox/FFmpeg_plus_plus'),
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
    builder: (bCtx) {
      return StatefulBuilder(builder: (ctx2, setDState) {
        final cfg = state.config;
        final scheme = Theme.of(ctx2).colorScheme;
        final clr = scheme.onSurface;
        final cardColor = scheme.surface.withAlpha((cfg.cardOpacity * 255).round().clamp(0, 255));

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
          builder: (_, scrollCtrl) => Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
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
                  // ── Connection ──
                  section(s.aiConnection, Icons.cloud_outlined, [
                    Text(s.aiProvider, style: TextStyle(color: clr, fontSize: 12)),
                    const SizedBox(height: 6),
                    SegmentedButton<String>(
                      segments: const [ButtonSegment(value: 'openai', label: Text('OpenAI')), ButtonSegment(value: 'anthropic', label: Text('Anthropic'))],
                      selected: {cfg.aiProvider},
                      onSelectionChanged: (v) {
                        final provider = v.first;
                        state.updateConfig((c) {
                          c.aiProvider = provider;
                          if (provider == 'anthropic' && c.aiApiUrl == 'https://api.openai.com/v1/chat/completions') {
                            c.aiApiUrl = 'https://api.anthropic.com/v1/messages';
                            c.aiModel = _kDefaultAnthropicModel;
                          } else if (provider == 'openai' && c.aiApiUrl == 'https://api.anthropic.com/v1/messages') {
                            c.aiApiUrl = 'https://api.openai.com/v1/chat/completions';
                            c.aiModel = 'gpt-4o';
                          }
                          return c;
                        });
                        setDState(() {});
                      },
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    ),
                    const SizedBox(height: 10),
                    _McpTextField(value: cfg.aiApiKey, label: s.aiApiKey, scheme: scheme, obscure: true,
                        onChange: (v) => state.updateConfig((c) => c..aiApiKey = v)),
                    const SizedBox(height: 8),
                    _McpTextField(value: cfg.aiApiUrl, label: s.aiApiUrl, scheme: scheme,
                        onChange: (v) => state.updateConfig((c) => c..aiApiUrl = v)),
                    const SizedBox(height: 8),
                    _McpTextField(value: cfg.aiModel, label: s.aiModel, scheme: scheme,
                        onChange: (v) => state.updateConfig((c) => c..aiModel = v)),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: _iosButton(icon: Icons.wifi_tethering, label: s.aiPing,
                          color: scheme.primary, bg: scheme.primaryContainer,
                          onTap: () => _pingAi(ctx, state, s))),
                      const SizedBox(width: 8),
                      Expanded(child: _iosButton(icon: Icons.list, label: s.aiListModels,
                          color: scheme.onSecondaryContainer, bg: scheme.secondaryContainer,
                          onTap: () => _listAiModels(ctx, state, s, onPicked: () => setDState(() {})))),
                    ]),
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
                  ]),
                  // ── Advanced ──
                  section(s.aiAdvanced, Icons.tune_outlined, [
                    Text(s.aiGraphModeLabel, style: TextStyle(color: clr, fontSize: 12)),
                    const SizedBox(height: 6),
                    SegmentedButton<String>(
                      segments: [ButtonSegment(value: 'redo', label: Text(s.aiGraphModeRedo)), ButtonSegment(value: 'modify', label: Text(s.aiGraphModeModify))],
                      selected: {cfg.aiGraphMode},
                      onSelectionChanged: (v) { state.updateConfig((c) => c..aiGraphMode = v.first); setDState(() {}); },
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    ),
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

// ═══════════════════════════════════════════
// 通用小部件
// ═══════════════════════════════════════════

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

Widget _glass(BuildContext ctx, AppState state, String title, List<Widget> children) {
  final scheme = Theme.of(ctx).colorScheme;
  final cfg = state.config;
  final cardAlpha = (cfg.cardOpacity * 255).round().clamp(0, 255);
  final inner = Card(
    elevation: 4,
    shadowColor: scheme.shadow,
    color: scheme.surface.withAlpha(cardAlpha),
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: scheme.outlineVariant.withAlpha(60), width: 1),
    ),
    child: Padding(padding: const EdgeInsets.all(14), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
      const SizedBox(height: 8), ...children,
    ])),
  );

  // 没有背景图时卡片后面只是一块纯色，模糊纯色的结果还是同一块纯色——
  // 画面完全没变，却要为每张卡片多跑一遍 BackdropFilter（本页 14 张）。
  // 所以只在真正有背景图可糊的时候才加这一层。
  if (cfg.backgroundImage.isEmpty) {
    return ClipRRect(borderRadius: BorderRadius.circular(14), child: inner);
  }
  return ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6), child: inner),
  );
}

Widget _pf(BuildContext ctx, String label, String value, ValueChanged<String> onChange, VoidCallback onBrowse) {
  final scheme = Theme.of(ctx).colorScheme;
  return Row(children: [
    Expanded(child: _PathField(value: value, label: label, scheme: scheme, onChange: onChange)),
    const SizedBox(width: 4),
    IconButton(icon: Icon(Icons.folder_open, size: 20, color: scheme.primary), onPressed: onBrowse, padding: const EdgeInsets.all(8)),
  ]);
}

Widget _dot(ColorScheme sc, bool sel, Color c, String tip, VoidCallback onTap) =>
    GestureDetector(onTap: onTap, child: Tooltip(message: tip, child: Container(
      width: 24, height: 24,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle,
          border: Border.all(color: sel ? sc.onSurface : Colors.transparent, width: 2),
          boxShadow: sel ? [BoxShadow(color: c.withAlpha(80), blurRadius: 4)] : null),
      child: sel ? const Icon(Icons.check, size: 12, color: Colors.white) : null)));

Widget _rainbow(ColorScheme sc, VoidCallback onTap) =>
    GestureDetector(onTap: onTap, child: Container(
      width: 24, height: 24,
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: sc.outline, width: 1),
          gradient: const SweepGradient(colors: [Colors.red, Colors.yellow, Colors.green, Colors.cyan, Colors.blue, Colors.purple, Colors.red])),
      child: const Icon(Icons.add, size: 12, color: Colors.white)));

Widget _infoRow(String label, String value, ColorScheme scheme, {Widget? trailing}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 2),
  child: Row(children: [
    SizedBox(width: 70, child: Text(label, style: TextStyle(fontSize: 11, color: scheme.outline))),
    if (trailing != null) Expanded(child: trailing)
    else Expanded(child: Text(value, style: TextStyle(fontSize: 11, color: scheme.onSurface))),
  ]),
);

Widget _link(String label, String url) => SizedBox(height: 22, child: OutlinedButton(
    onPressed: () => openExternalUrl(url),
    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, visualDensity: VisualDensity.compact),
    child: Text(label, style: const TextStyle(fontSize: 9))));

// ═══════════════════════════════════════════
// 动作
// ═══════════════════════════════════════════

/// 供应商切到 Anthropic 时填入的默认模型。
const _kDefaultAnthropicModel = 'claude-opus-5';

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
    state.updateConfig((c) => c..fontFamily = fontName);
    if (ctx.mounted) showToast(ctx, isZh ? '热加载失败: $e' : 'Load failed: $e', type: ToastType.error);
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
            openExternalUrl(result.downloadUrl ?? 'https://github.com/pity-Fox/FFmpeg_plus_plus/releases/latest');
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
  final picked = await showDialog<Color>(context: ctx, builder: (_) => _CP(initial: Color(state.config.themeColor), isZh: isZh));
  if (picked != null) state.updateConfig((c) => c..themeColor = picked.toARGB32());
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
      await Process.run('setx', ['Path', existingPath.isEmpty ? dir : '$existingPath;$dir']);
    } catch (_) {}
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

class _CP extends StatefulWidget {
  final Color initial;
  final bool isZh;
  const _CP({required this.initial, required this.isZh});
  @override
  State<_CP> createState() => _CPState();
}

class _CPState extends State<_CP> {
  late double _h, _s, _v;
  @override
  void initState() {
    super.initState();
    final h = HSVColor.fromColor(widget.initial);
    _h = h.hue; _s = h.saturation; _v = h.value;
  }

  Color get c => HSVColor.fromAHSV(1, _h, _s, _v).toColor();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(fontSize: 10, color: scheme.onSurface);
    return AlertDialog(
      title: Text(widget.isZh ? '自定义颜色' : 'Custom Color', style: TextStyle(color: scheme.onSurface)),
      content: SizedBox(width: 260, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(height: 60, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8))),
        const SizedBox(height: 10),
        _sl(widget.isZh ? '色相' : 'Hue', _h, 0, 360, labelStyle, (v) => setState(() => _h = v)),
        _sl(widget.isZh ? '饱和' : 'Sat', _s, 0, 1, labelStyle, (v) => setState(() => _s = v)),
        _sl(widget.isZh ? '明度' : 'Val', _v, 0, 1, labelStyle, (v) => setState(() => _v = v)),
        Text('#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
            style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: scheme.onSurface)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(widget.isZh ? '取消' : 'Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, c), child: Text(widget.isZh ? '选择' : 'Select')),
      ],
    );
  }

  Widget _sl(String l, double v, double min, double max, TextStyle labelStyle, ValueChanged<double> cb) => Row(children: [
    SizedBox(width: 30, child: Text(l, style: labelStyle)),
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
    style: TextStyle(fontSize: 13, color: widget.scheme.onSurface),
    decoration: InputDecoration(labelText: widget.label, isDense: false, labelStyle: TextStyle(fontSize: 11, color: widget.scheme.outline)),
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
