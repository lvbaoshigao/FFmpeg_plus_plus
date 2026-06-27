import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/masonry_grid.dart';
import '../widgets/install_dialog.dart';
import '../widgets/font_picker.dart';
import '../services/ffmpeg_installer.dart';

/// 获取用户数据目录（%APPDATA%/FFmpeg++/），避免 Program Files 权限问题
String _userDataDir() {
  return '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}/FFmpeg++';
}

/// 复制文件到用户数据目录下的子文件夹，返回新路径（失败返回 null）
Future<String?> _copyToAppDir(String srcPath, String subDir) async {
  try {
    final targetDir = Directory('${_userDataDir()}/$subDir');
    if (!targetDir.existsSync()) targetDir.createSync(recursive: true);
    final fileName = srcPath.split(RegExp(r'[\\/]')).last;
    final destPath = '${targetDir.path}/$fileName';
    final srcFile = File(srcPath);
    if (srcFile.existsSync()) {
      await srcFile.copy(destPath);
      return destPath;
    }
  } catch (_) {}
  return null;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const _presets = [
    ('Linear Purple', 0xFF5E6AD2), ('Ocean Blue', 0xFF3B82F6),
    ('Emerald', 0xFF10B981), ('Amber', 0xFFF59E0B),
    ('Rose', 0xFFEF4444), ('Cyan', 0xFF06B6D4), ('Violet', 0xFF8B5CF6),
  ];

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final cfg = state.config;
        final s = AppStrings.of(cfg.language);
        final scheme = Theme.of(context).colorScheme;
        final clr = scheme.onSurface;

        return Scaffold(
          appBar: AppBar(title: Text(s.settingsTitle)),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: MasonryGrid(
              columns: 2,
              spacing: 12,
              runSpacing: 12,
              children: [
                // ── Appearance ──
                _glass(context, s.appearance, [
                  SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                      title: Text(s.darkMode, style: TextStyle(color: clr)),
                      value: state.darkMode,
                      onChanged: (v) => state.toggleDarkMode(v)),
                  SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                      title: Text(s.qGlass, style: TextStyle(color: clr)),
                      subtitle: Text(s.qGlassHint, style: TextStyle(fontSize: 11, color: scheme.outline)),
                      value: cfg.glassEffect,
                      onChanged: (v) => state.updateConfig((c) => c..glassEffect = v)),
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
                                  final srcPath = r.files.first.path!;
                                  // 复制到程序目录
                                  final copied = await _copyToAppDir(srcPath, 'background');
                                  state.updateConfig((c) => c..backgroundImage = copied ?? srcPath);
                                }
                              }, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24)),
                        ])),
                    if (cfg.backgroundImage.isNotEmpty)
                      Row(children: [
                        Text('${s.bgOpacity}: ${(cfg.backgroundOpacity * 100).round()}%',
                            style: TextStyle(color: clr, fontSize: 11)),
                        Expanded(child: Slider(
                            value: cfg.backgroundOpacity, min: 0.0, max: 1.0, divisions: 100,
                            onChanged: (v) => state.updateConfig((c) => c..backgroundOpacity = v))),
                      ]),
                  if (cfg.glassEffect)
                    Row(children: [
                      Text('${s.cardOpacity}: ${(cfg.cardOpacity * 100).round()}%',
                          style: TextStyle(color: clr, fontSize: 11)),
                      Expanded(child: Slider(
                          value: cfg.cardOpacity, min: 0.1, max: 1.0, divisions: 90,
                          onChanged: (v) => state.updateConfig((c) => c..cardOpacity = v))),
                    ]),
                  Text(s.accentColor, style: TextStyle(color: clr, fontSize: 12)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    ..._presets.map((p) => _dot(scheme, cfg.themeColor == p.$2, Color(p.$2), p.$1,
                        () => state.updateConfig((c) => c..themeColor = p.$2))),
                    _rainbow(scheme, () => _pickColor(context, state)),
                  ]),
                ]),

                // ── Language ──
                _glass(context, s.language, [
                  Text(s.languageInterface, style: TextStyle(color: clr, fontSize: 12)),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'zh', label: Text('中文')),
                      ButtonSegment(value: 'en', label: Text('English')),
                    ],
                    selected: {cfg.language},
                    onSelectionChanged: (v) => state.updateConfig((c) => c..language = v.first),
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  ),
                ]),

                // ── Font ──
                _glass(context, s.font, [
                  FontPicker(
                    currentFont: cfg.fontFamily,
                    language: cfg.language,
                    showImport: true,
                    onImport: () => _pickFont(context, state),
                    onSelected: (v) => state.updateConfig((c) => c..fontFamily = v),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Text('${s.fontSize}: ${cfg.fontSize.round()}', style: TextStyle(color: clr, fontSize: 12)),
                    Expanded(child: Slider(value: cfg.fontSize, min: 10, max: 21, divisions: 11,
                        onChanged: (v) => state.updateConfig((c) => c..fontSize = v))),
                  ]),
                  Text(s.qWeight, style: TextStyle(color: clr, fontSize: 12)),
                  SegmentedButton<int>(
                    segments: List.generate(AppConfig.fontWeightLabels.length, (i) =>
                        ButtonSegment(value: i, label: Text(AppConfig.fontWeightLabels[i], style: const TextStyle(fontSize: 10)))),
                    selected: {cfg.fontWeightIndex},
                    onSelectionChanged: (v) => state.updateConfig((c) => c..fontWeightIndex = v.first),
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  ),
                ]),

                // ── FFmpeg ──
                _FfmpegCard(state: state),

                // ── Output ──
                _glass(context, s.output, [
                  _pf(context, s.outputDir, cfg.defaultOutputDir,
                      (v) => state.updateConfig((c) => c..defaultOutputDir = v),
                      () async {
                        final d = await FilePicker.platform.getDirectoryPath();
                        if (d != null) state.updateConfig((c) => c..defaultOutputDir = d);
                      }),
                  const SizedBox(height: 8),
                  _pf(context, s.intermediateDir, cfg.intermediateDir,
                      (v) => state.updateConfig((c) => c..intermediateDir = v),
                      () async {
                        final d = await FilePicker.platform.getDirectoryPath();
                        if (d != null) state.updateConfig((c) => c..intermediateDir = d);
                      }),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(s.intermediateHint, style: TextStyle(fontSize: 11, color: scheme.outline)),
                  ),
                ]),

                // ── 编辑模式 ──
                _glass(context, s.isZh ? '编辑模式' : 'Editor Mode', [
                  RadioListTile<bool>(
                    dense: true, contentPadding: EdgeInsets.zero,
                    title: Text(s.isZh ? '节点编辑器 (新)' : 'Node Editor (New)', style: TextStyle(color: clr, fontSize: 13)),
                    subtitle: Text(s.isZh ? '蓝图式节点画布，可处理复杂的多步骤逻辑' : 'Blueprint-style canvas for complex multi-step logic', style: TextStyle(fontSize: 11, color: scheme.outline)),
                    value: true,
                    groupValue: cfg.useNodeEditor,
                    onChanged: (v) => state.updateConfig((c) => c..useNodeEditor = true),
                  ),
                  RadioListTile<bool>(
                    dense: true, contentPadding: EdgeInsets.zero,
                    title: Text(s.isZh ? '传统模式' : 'Classic Mode', style: TextStyle(color: clr, fontSize: 13)),
                    subtitle: Text(s.isZh ? '傻瓜式操作，适合简单的视频处理任务' : 'Simple step-by-step, ideal for basic tasks', style: TextStyle(fontSize: 11, color: scheme.outline)),
                    value: false,
                    groupValue: cfg.useNodeEditor,
                    onChanged: (v) => state.updateConfig((c) => c..useNodeEditor = false),
                  ),
                ]),

                // ── Debug ──
                _glass(context, s.dDebug, [
                  SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                      title: Text(s.dDebugMode, style: TextStyle(color: clr, fontSize: 13)),
                      value: cfg.debugMode,
                      onChanged: (v) => state.updateConfig((c) => c..debugMode = v)),
                  SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                      title: Text(s.dSaveLogs, style: TextStyle(color: clr, fontSize: 13)),
                      value: cfg.saveLogs,
                      onChanged: (v) => state.updateConfig((c) => c..saveLogs = v)),
                  if (cfg.saveLogs)
                    _pf(context, s.dLogPath, cfg.logSavePath,
                        (v) => state.updateConfig((c) => c..logSavePath = v),
                        () async {
                          final d = await FilePicker.platform.getDirectoryPath();
                          if (d != null) state.updateConfig((c) => c..logSavePath = d);
                        }),
                ]),

                // ── Cache ──
                _glass(context, s.isZh ? '缓存' : 'Cache', [
                  SizedBox(width: double.infinity, child: OutlinedButton.icon(
                    icon: Icon(Icons.delete_sweep, size: 18, color: scheme.error),
                    label: Text(s.isZh ? '清除缓存' : 'Clear Cache', style: TextStyle(fontSize: 12, color: scheme.onSurface)),
                    onPressed: () => _clearCache(context, state, scheme, s),
                  )),
                  Text(s.isZh ? '清除已导入的字体文件和背景图片' : 'Clear imported fonts and background images',
                      style: TextStyle(fontSize: 10, color: scheme.outline)),
                ]),

                // ── About ──
                _glass(context, s.aboutTitle, [
                  Center(child: Column(children: [
                    const SizedBox(height: 4),
                    ClipRRect(borderRadius: BorderRadius.circular(12),
                        child: Image.asset('rele/icon.png', width: 48, height: 48, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(Icons.play_circle_fill, size: 48, color: scheme.primary))),
                    const SizedBox(height: 8),
                    Text('FFmpeg++', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: scheme.primary)),
                    Text('v3.2.0', style: TextStyle(fontSize: 12, color: scheme.outline)),
                    const SizedBox(height: 12),
                  ])),
                  const SizedBox(height: 4),
                  _infoRow(s.aboutVersion, 'v3.2.0', scheme),
                  _infoRow(s.aboutBuildDate, '2026-06-27', scheme),
                  _infoRow(s.aboutBlog, 'blog-clstone.netlify.app', scheme),
                  _infoRow(s.aboutGithub, 'github.com/pity-Fox/FFmpeg_plus_plus', scheme),
                  _infoRow(s.aboutSponsor, '', scheme, trailing: TextButton.icon(
                      icon: const Icon(Icons.volunteer_activism, size: 14),
                      label: Text(s.aboutSponsorBtn, style: const TextStyle(fontSize: 11)),
                      onPressed: () => _showSponsor(context, scheme, s))),
                  const SizedBox(height: 8),
                  Wrap(spacing: 4, runSpacing: 4, children: [
                    _link(s.aboutBlogLink, 'https://blog-clstone.netlify.app/'),
                    _link('GitHub', 'https://github.com/pity-Fox/FFmpeg_plus_plus'),
                  ]),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Card wrapper ──
  static Widget _glass(BuildContext ctx, String title, List<Widget> children) {
    final scheme = Theme.of(ctx).colorScheme;
    final cfg = ctx.read<AppState>().config;
    final glass = cfg.glassEffect;
    final cardAlpha = (cfg.cardOpacity * 255).round().clamp(0, 255);
    final inner = Card(
      elevation: glass ? 4 : 0,
      shadowColor: glass ? scheme.shadow : null,
      color: glass ? scheme.surface.withAlpha(cardAlpha) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: glass ? BorderSide(color: scheme.outlineVariant.withAlpha(60), width: 1) : BorderSide.none,
      ),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
        const SizedBox(height: 8), ...children,
      ])),
    );
    if (!glass) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6), child: inner),
    );
  }

  static Widget _pf(BuildContext ctx, String label, String value, ValueChanged<String> onChange, VoidCallback onBrowse) {
    final scheme = Theme.of(ctx).colorScheme;
    return Row(children: [
      Expanded(child: _PathField(value: value, label: label, scheme: scheme, onChange: onChange)),
      const SizedBox(width: 4),
      IconButton(icon: Icon(Icons.folder_open, size: 20, color: scheme.primary), onPressed: onBrowse, padding: const EdgeInsets.all(8)),
    ]);
  }

  static Widget _dot(ColorScheme sc, bool sel, Color c, String tip, VoidCallback onTap) =>
      GestureDetector(onTap: onTap, child: Tooltip(message: tip, child: Container(
        width: 24, height: 24,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle,
            border: Border.all(color: sel ? sc.onSurface : Colors.transparent, width: 2),
            boxShadow: sel ? [BoxShadow(color: c.withAlpha(80), blurRadius: 4)] : null),
        child: sel ? const Icon(Icons.check, size: 12, color: Colors.white) : null)));

  static Widget _rainbow(ColorScheme sc, VoidCallback onTap) =>
      GestureDetector(onTap: onTap, child: Container(
        width: 24, height: 24,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: sc.outline, width: 1),
            gradient: const SweepGradient(colors: [Colors.red, Colors.yellow, Colors.green, Colors.cyan, Colors.blue, Colors.purple, Colors.red])),
        child: const Icon(Icons.add, size: 12, color: Colors.white)));

  static Future<void> _pickFont(BuildContext ctx, AppState state) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['ttf', 'otf']);
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;

    final path = r.files.first.path;
    if (path == null) return;
    final fileName = path.split(RegExp(r'[\\/]')).last;
    final fontName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final isZh = state.config.language == 'zh';

    // 复制字体文件到程序目录 fonts/ 子文件夹
    final copiedPath = await _copyToAppDir(path, 'fonts');
    final fontFilePath = copiedPath ?? path;

    // 热加载字体：用 FontLoader 动态加载，无需重启，无需弹窗
    try {
      final fontLoader = FontLoader(fontName);
      final fontFile = File(fontFilePath);
      if (await fontFile.exists()) {
        final bytes = await fontFile.readAsBytes();
        fontLoader.addFont(Future.value(ByteData.view(bytes.buffer)));
        await fontLoader.load();
        state.updateConfig((c) => c..fontFamily = fontName);
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text(isZh ? '字体 "$fontName" 已加载并应用' : 'Font "$fontName" loaded and applied'),
              duration: const Duration(seconds: 2)));
        }
      }
    } catch (e) {
      state.updateConfig((c) => c..fontFamily = fontName);
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text(isZh ? '热加载失败: $e' : 'Load failed: $e'),
            duration: const Duration(seconds: 3)));
      }
    }
  }

  static Future<void> _clearCache(BuildContext ctx, AppState state, ColorScheme scheme, AppStrings s) async {
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (_) => AlertDialog(
        title: Text(s.isZh ? '确认清除缓存' : 'Confirm Clear Cache'),
        content: Text(s.isZh
            ? '将清除已导入的字体文件和背景图片。\n清除后需要重新选择字体和背景。\n\n确定继续？'
            : 'This will clear imported fonts and background images.\nYou will need to re-select them.\n\nContinue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.isZh ? '取消' : 'Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: scheme.error),
              child: Text(s.isZh ? '清除' : 'Clear')),
        ],
      ),
    );
    if (confirmed != true || !ctx.mounted) return;
    try {
      final dataDir = _userDataDir();
      // 清除字体缓存
      final fontsDir = Directory('$dataDir/fonts');
      if (fontsDir.existsSync()) {
        for (final f in fontsDir.listSync().whereType<File>()) {
          try { f.deleteSync(); } catch (_) {}
        }
      }
      // 清除背景缓存
      final bgDir = Directory('$dataDir/background');
      if (bgDir.existsSync()) {
        for (final f in bgDir.listSync().whereType<File>()) {
          try { f.deleteSync(); } catch (_) {}
        }
      }
      // 重置配置中的背景
      state.updateConfig((c) => c..backgroundImage = '');
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text(s.isZh ? '缓存已清除' : 'Cache cleared'),
            duration: const Duration(seconds: 2)));
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text(s.isZh ? '清除失败: $e' : 'Clear failed: $e'),
            duration: const Duration(seconds: 3)));
      }
    }
  }

  static Future<void> _pickColor(BuildContext ctx, AppState state) async {
    final isZh = state.config.language == 'zh';
    final picked = await showDialog<Color>(context: ctx, builder: (_) => _CP(initial: Color(state.config.themeColor), isZh: isZh));
    if (picked != null) {
      state.updateConfig((c) => c..themeColor = picked.toARGB32());
    }
  }

  static Widget _infoRow(String label, String value, ColorScheme scheme, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      SizedBox(width: 70, child: Text(label, style: TextStyle(fontSize: 11, color: scheme.outline))),
      if (trailing != null) Expanded(child: trailing)
      else Expanded(child: Text(value, style: TextStyle(fontSize: 11, color: scheme.onSurface))),
    ]),
  );

  static void _showSponsor(BuildContext ctx, ColorScheme scheme, AppStrings s) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: Text(s.aboutSponsor, style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w700, fontSize: 18)),
        content: SizedBox(width: 480, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(s.aboutThanks, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
          const SizedBox(height: 12),
          Text(s.aboutZoomHint, style: TextStyle(fontSize: 10, color: scheme.outline)),
          const SizedBox(height: 12),
          // 水平排列两个收款码
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Expanded(child: _qrImage(ctx, 'rele/wx.png', s.aboutWxTitle, scheme)),
            const SizedBox(width: 16),
            Expanded(child: _qrImage(ctx, 'rele/zfb.jpg', s.aboutZfbTitle, scheme)),
          ]),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.aboutClose)),
        ],
      ),
    );
  }

  static Widget _qrImage(BuildContext ctx, String asset, String label, ColorScheme scheme) {
    return GestureDetector(
      onTap: () => _showFullImage(ctx, asset, scheme),
      child: Column(children: [
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
        const SizedBox(height: 8),
        ClipRRect(borderRadius: BorderRadius.circular(8),
            child: Image.asset(asset, height: 160, fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Container(height: 160, alignment: Alignment.center,
                    child: Text('加载失败', style: TextStyle(color: scheme.outline))))),
      ]),
    );
  }

  static void _showFullImage(BuildContext ctx, String asset, ColorScheme scheme) {
    showDialog(
      context: ctx,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: InteractiveViewer(
            minScale: 0.5, maxScale: 4.0,
            child: ClipRRect(borderRadius: BorderRadius.circular(12),
                child: Image.asset(asset, fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Container(
                        padding: const EdgeInsets.all(32),
                        child: Text('加载失败', style: TextStyle(color: scheme.outline))))),
          ),
        ),
      ),
    );
  }

  static Widget _link(String label, String url) => SizedBox(height: 22, child: OutlinedButton(
      onPressed: () => Process.run('cmd', ['/c', 'start', url]),
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, visualDensity: VisualDensity.compact),
      child: Text(label, style: const TextStyle(fontSize: 9))));
}

// ═══════════════════════════════════════════
// FFmpeg detection card with feature tabs
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
  void initState() {
    super.initState();
    _syncState();
  }

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
    if (_found) {
      widget.state.addLog('FFmpeg detected: $_version', category: 'ffmpeg');
    } else {
      widget.state.addLog('FFmpeg not found', category: 'error');
    }
  }

  Future<void> _browseFfmpeg() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['exe'], dialogTitle: context.read<AppState>().config.language == 'zh' ? '选择 ffmpeg.exe' : 'Select ffmpeg.exe',
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
        setState(() { _found = true; _version = versionLine; _path = exePath; _checking = false; });
        widget.state.updateConfig((c) => c..ffmpegPath = exePath..ffprobePath = '$dir\\ffprobe.exe');
        await _addToPath(dir);
        widget.state.addLog('FFmpeg configured: $_version', category: 'ffmpeg');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('FFmpeg found at: $dir\n已添加到用户环境变量 PATH'), duration: const Duration(seconds: 3)));
        }
      } else {
        setState(() => _checking = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('所选文件不是有效的 ffmpeg.exe'), backgroundColor: Colors.red));
        }
      }
    } catch (e) {
      setState(() => _checking = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('检测失败: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _addToPath(String dir) async {
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
          content: Text(
            isZh ? '将删除程序目录下的 ffmpeg.exe 和 ffprobe.exe，确定？'
                 : 'Delete ffmpeg.exe and ffprobe.exe from the app directory?',
            style: TextStyle(fontSize: 13, color: s.onSurface),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
                child: Text(isZh ? '取消' : 'Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: s.error),
              child: Text(isZh ? '删除' : 'Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    FfmpegInstaller.uninstall();
    widget.state.updateConfig((c) => c..ffmpegPath = ''..ffprobePath = '');
    setState(() { _found = false; _version = ''; _path = ''; });
    widget.state.addLog('已删除程序目录下的 FFmpeg', category: 'info');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isZh ? 'FFmpeg 已删除' : 'FFmpeg deleted')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = widget.state.config;
    final s = AppStrings.of(cfg.language);
    final isZh = cfg.language == 'zh';
    final glass = cfg.glassEffect;
    final cardAlpha = (cfg.cardOpacity * 255).round().clamp(0, 255);

    Widget card;
    if (!_found && !_checking) {
      // Initial: just detect button
      card = _card(scheme, glass, cardAlpha, cfg, s.ffmpegSettings, [
        Center(child: Column(children: [
          Icon(Icons.warning_amber, size: 32, color: Colors.orange),
          const SizedBox(height: 8),
          Text(s.ffmpegNotFound, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.orange)),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.download, size: 18),
            label: Text(isZh ? '自动安装 FFmpeg' : 'Install FFmpeg', style: const TextStyle(fontSize: 13)),
            onPressed: () async {
              final ok = await FfmpegInstallDialog.show(context);
              if (ok == true) _detect();
            },
          ),
          const SizedBox(height: 8),
          Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.search, size: 16),
              label: Text(isZh ? '检测' : 'Detect', style: const TextStyle(fontSize: 11)),
              onPressed: _detect,
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              icon: const Icon(Icons.folder_open, size: 14),
              label: Text(isZh ? '手动选择' : 'Manual', style: const TextStyle(fontSize: 11)),
              onPressed: _browseFfmpeg,
            ),
          ]),
        ])),
        const SizedBox(height: 4),
        Wrap(spacing: 4, runSpacing: 4, alignment: WrapAlignment.center, children: [
          _link('ffmpeg.org', 'https://ffmpeg.org'),
          _link('gyan.dev', 'https://github.com/AnimMouse/ffmpeg-stable-autobuild'),
          _link('BtbN', 'https://github.com/BtbN/FFmpeg-Builds/releases'),
        ]),
      ]);
    } else if (_checking) {
      card = _card(scheme, glass, cardAlpha, cfg, s.ffmpegSettings, [
        const SizedBox(height: 12),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 8),
        Center(child: Text(isZh ? '正在检测...' : 'Detecting...', style: TextStyle(fontSize: 12, color: scheme.outline))),
      ]);
    } else {
      // Found: show version + optional delete for bundled ffmpeg
      final isBundled = FfmpegInstaller.isInstalled &&
          _path.isNotEmpty && _path.startsWith(Directory(Platform.resolvedExecutable).parent.path);
      card = _card(scheme, glass, cardAlpha, cfg, s.ffmpegSettings, [
        Row(children: [
          const Icon(Icons.check_circle, size: 16, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(child: Text(s.ffmpegFound, style: TextStyle(fontSize: 13, color: Colors.green, fontWeight: FontWeight.w600))),
        ]),
        if (_version.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4, bottom: 6),
              child: Text(_version, style: TextStyle(fontSize: 10, color: scheme.outline), maxLines: 2, overflow: TextOverflow.ellipsis)),
        if (_path.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 6),
              child: Text(_path, style: TextStyle(fontSize: 9, color: scheme.outline.withAlpha(150)), maxLines: 2, overflow: TextOverflow.ellipsis)),
        Row(children: [
          Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: 14), label: Text(s.recheck, style: const TextStyle(fontSize: 11)),
              onPressed: _detect)),
          if (isBundled) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: Icon(Icons.delete_outline, size: 14, color: scheme.error),
              label: Text(isZh ? '删除' : 'Delete', style: TextStyle(fontSize: 11, color: scheme.error)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: scheme.error.withAlpha(120)),
              ),
              onPressed: () => _confirmDelete(isZh),
            ),
          ],
        ]),
        const SizedBox(height: 4),
        Wrap(spacing: 4, runSpacing: 4, children: [
          _link('ffmpeg.org', 'https://ffmpeg.org'),
          _link('gyan.dev', 'https://github.com/AnimMouse/ffmpeg-stable-autobuild'),
          _link('BtbN', 'https://github.com/BtbN/FFmpeg-Builds/releases'),
        ]),
      ]);
    }

    return card;
  }

  Widget _card(ColorScheme scheme, bool glass, int cardAlpha, AppConfig cfg, String title, List<Widget> children) {
    final inner = Card(
      elevation: glass ? 4 : 0,
      shadowColor: glass ? scheme.shadow : null,
      color: glass ? scheme.surface.withAlpha(cardAlpha) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: glass ? BorderSide(color: scheme.outlineVariant.withAlpha(60), width: 1) : BorderSide.none,
      ),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
        const SizedBox(height: 8), ...children,
      ])),
    );
    if (!glass) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6), child: inner),
    );
  }

  static Widget _link(String label, String url) => SizedBox(height: 22, child: OutlinedButton(
      onPressed: () => Process.run('cmd', ['/c', 'start', url]),
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, visualDensity: VisualDensity.compact),
      child: Text(label, style: const TextStyle(fontSize: 9))));
}

// ═══════════════════════════════════════════
// Color picker
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
