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

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const _presets = [
    ('Linear Purple', 0xFF5E6AD2), ('Ocean Blue', 0xFF3B82F6),
    ('Emerald', 0xFF10B981), ('Amber', 0xFFF59E0B),
    ('Rose', 0xFFEF4444), ('Cyan', 0xFF06B6D4), ('Violet', 0xFF8B5CF6),
  ];
  static const _sysFonts = [
    ('System Default', ''),
    // ── 中文字体 ──
    ('微软雅黑', 'Microsoft YaHei'), ('黑体', 'SimHei'), ('宋体', 'SimSun'),
    ('楷体', 'KaiTi'), ('仿宋', 'FangSong'), ('微軟正黑體', 'Microsoft JhengHei'),
    ('新細明體', 'MingLiU'), ('新宋体', 'NSimSun'), ('標楷體', 'DFKai-SB'),
    ('华文中宋', 'STZhongsong'), ('华文彩云', 'STCaiyun'), ('华文行楷', 'STXingkai'),
    ('华文细黑', 'STXihei'), ('隶书', 'LiSu'), ('幼圆', 'YouYuan'),
    // ── 英文字体 ──
    ('Arial', 'Arial'), ('Arial Black', 'Arial Black'), ('Bahnschrift', 'Bahnschrift'),
    ('Calibri', 'Calibri'), ('Calibri Light', 'Calibri Light'),
    ('Cambria', 'Cambria'), ('Candara', 'Candara'), ('Candara Light', 'Candara Light'),
    ('Comic Sans MS', 'Comic Sans MS'), ('Consolas', 'Consolas'),
    ('Constantia', 'Constantia'), ('Corbel', 'Corbel'), ('Corbel Light', 'Corbel Light'),
    ('Courier New', 'Courier New'), ('Ebrima', 'Ebrima'),
    ('Franklin Gothic', 'Franklin Gothic Medium'), ('Gabriola', 'Gabriola'),
    ('Georgia', 'Georgia'), ('Impact', 'Impact'), ('Ink Free', 'Ink Free'),
    ('Javanese Text', 'Javanese Text'), ('Leelawadee UI', 'Leelawadee UI'),
    ('Lucida Console', 'Lucida Console'), ('Lucida Sans Unicode', 'Lucida Sans Unicode'),
    ('Malgun Gothic', 'Malgun Gothic'), ('Marlett', 'Marlett'),
    ('Microsoft Himalaya', 'Microsoft Himalaya'), ('Microsoft JhengHei', 'Microsoft JhengHei'),
    ('Microsoft New Tai Lue', 'Microsoft New Tai Lue'), ('Microsoft PhagsPa', 'Microsoft PhagsPa'),
    ('Microsoft Tai Le', 'Microsoft Tai Le'), ('Microsoft YaHei', 'Microsoft YaHei'),
    ('MingLiU-ExtB', 'MingLiU-ExtB'), ('Mongolian Baiti', 'Mongolian Baiti'),
    ('MS Gothic', 'MS Gothic'), ('MV Boli', 'MV Boli'), ('Myanmar Text', 'Myanmar Text'),
    ('Nirmala UI', 'Nirmala UI'), ('Palatino Linotype', 'Palatino Linotype'),
    ('Segoe MDL2 Assets', 'Segoe MDL2 Assets'), ('Segoe Print', 'Segoe Print'),
    ('Segoe Script', 'Segoe Script'), ('Segoe UI', 'Segoe UI'),
    ('Segoe UI Black', 'Segoe UI Black'), ('Segoe UI Emoji', 'Segoe UI Emoji'),
    ('Segoe UI Historic', 'Segoe UI Historic'), ('Segoe UI Light', 'Segoe UI Light'),
    ('Segoe UI Semibold', 'Segoe UI Semibold'), ('Segoe UI Semilight', 'Segoe UI Semilight'),
    ('Segoe UI Symbol', 'Segoe UI Symbol'), ('Sitka', 'Sitka'),
    ('Sylfaen', 'Sylfaen'), ('Tahoma', 'Tahoma'),
    ('Times New Roman', 'Times New Roman'), ('Trebuchet MS', 'Trebuchet MS'),
    ('Verdana', 'Verdana'), ('Webdings', 'Webdings'), ('Wingdings', 'Wingdings'),
    ('Yu Gothic', 'Yu Gothic'), ('Yu Gothic UI', 'Yu Gothic UI'),
    // ── 第三方 ──
    ('Noto Sans', 'Noto Sans'), ('Noto Serif', 'Noto Serif'),
    ('Noto Sans CJK SC', 'Noto Sans CJK SC'), ('Noto Serif CJK SC', 'Noto Serif CJK SC'),
    ('Source Han Sans CN', 'Source Han Sans CN'), ('Source Han Serif CN', 'Source Han Serif CN'),
    ('思源黑体', 'Source Han Sans CN'), ('思源宋体', 'Source Han Serif CN'),
    ('Droid Sans', 'Droid Sans'), ('Roboto', 'Roboto'), ('Open Sans', 'Open Sans'),
    ('Lato', 'Lato'), ('Montserrat', 'Montserrat'), ('Oswald', 'Oswald'),
    ('Raleway', 'Raleway'), ('Ubuntu', 'Ubuntu'), ('Fira Code', 'Fira Code'),
    ('JetBrains Mono', 'JetBrains Mono'),
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
                                  state.updateConfig((c) => c..backgroundImage = r.files.first.path!);
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
                  Row(children: [
                    Expanded(child: TextField(
                      controller: TextEditingController(text: cfg.fontFamily),
                      style: TextStyle(fontSize: 13, color: clr),
                      decoration: const InputDecoration(isDense: false, hintText: 'Font name...'),
                      onChanged: (v) => state.updateConfig((c) => c..fontFamily = v),
                    )),
                    PopupMenuButton<String>(icon: const Icon(Icons.arrow_drop_down),
                        onSelected: (v) => state.updateConfig((c) => c..fontFamily = v),
                        itemBuilder: (_) => _sysFonts.map((f) => PopupMenuItem<String>(
                            value: f.$2, child: Text(f.$1, style: TextStyle(fontFamily: f.$2.isNotEmpty ? f.$2 : null)))).toList()),
                    IconButton(icon: const Icon(Icons.file_open), tooltip: s.importFont,
                        onPressed: () => _pickFont(context, state)),
                  ]),
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

                // ── About ──
                _glass(context, s.aboutTitle, [
                  Center(child: Column(children: [
                    const SizedBox(height: 4),
                    ClipRRect(borderRadius: BorderRadius.circular(12),
                        child: Image.asset('rele/icon.png', width: 48, height: 48, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(Icons.play_circle_fill, size: 48, color: scheme.primary))),
                    const SizedBox(height: 8),
                    Text('FFmpeg++', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: scheme.primary)),
                    Text('v1.5.1', style: TextStyle(fontSize: 12, color: scheme.outline)),
                    const SizedBox(height: 12),
                  ])),
                  const SizedBox(height: 4),
                  _infoRow(s.aboutVersion, 'v1.5.1', scheme),
                  _infoRow(s.aboutBuildDate, '2026-06-07', scheme),
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
      Expanded(child: TextField(
        controller: TextEditingController(text: value),
        style: TextStyle(fontSize: 13, color: scheme.onSurface),
        decoration: InputDecoration(labelText: label, isDense: false, labelStyle: TextStyle(fontSize: 11, color: scheme.outline)),
        onChanged: onChange,
      )),
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

    final path = r.files.first.path!;
    final fileName = path.split(RegExp(r'[\\/]')).last;
    final defaultName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');

    if (!ctx.mounted) return;
    final nameCtrl = TextEditingController(text: defaultName);
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('导入字体 / Import Font'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('输入字体族名称（Font Family Name）：',
              style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          TextField(controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Font Family', hintText: 'e.g. Microsoft YaHei', isDense: true)),
          const SizedBox(height: 8),
          Text('提示：名称通常显示在字体预览窗口标题栏，\n如 "华文黑体"、"HYWenHei" 等，不是文件名。',
              style: TextStyle(fontSize: 11, color: Theme.of(ctx).colorScheme.outline)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('应用')),
        ],
      ),
    );

    if (confirmed == true && nameCtrl.text.trim().isNotEmpty) {
      final fontName = nameCtrl.text.trim();
      // 热加载字体：用 FontLoader 动态加载，无需重启
      try {
        final fontLoader = FontLoader(fontName);
        final fontFile = File(path);
        if (await fontFile.exists()) {
          final bytes = await fontFile.readAsBytes();
          fontLoader.addFont(Future.value(ByteData.view(bytes.buffer)));
          await fontLoader.load();
          // 字体已加载到引擎，立即应用
          state.updateConfig((c) => c..fontFamily = fontName);
          if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text('字体 "$fontName" 已加载并应用'),
              duration: const Duration(seconds: 3)));
        }
      } catch (e) {
        // 回退：仅设置名称，需要系统已安装该字体
        state.updateConfig((c) => c..fontFamily = fontName);
        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text('热加载失败: $e\n已设置字体名，如系统已安装该字体则生效'),
            duration: const Duration(seconds: 5)));
      }
    }
  }

  static Future<void> _pickColor(BuildContext ctx, AppState state) async {
    final picked = await showDialog<Color>(context: ctx, builder: (_) => _CP(initial: Color(state.config.themeColor)));
    if (picked != null) state.updateConfig((c) => c..themeColor = picked.toARGB32());
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
  Map<String, List<String>> _features = {};
  bool _featuresLoading = false;

  @override
  void initState() {
    super.initState();
    _found = widget.state.envOk;
    _version = widget.state.ffmpegVersion;
    _path = widget.state.config.ffmpegPath;
    if (_found && widget.state.featuresDetected) {
      _features = widget.state.ffmpegFeatures;
    }
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
      await _loadFeatures();
    } else {
      widget.state.addLog('FFmpeg not found', category: 'error');
    }
  }

  Future<void> _loadFeatures() async {
    setState(() => _featuresLoading = true);
    await widget.state.queryFeatures();
    if (!mounted) return;
    setState(() {
      _features = widget.state.ffmpegFeatures;
      _featuresLoading = false;
    });
  }

  Future<void> _browseFfmpeg() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['exe'], dialogTitle: 'Select ffmpeg.exe',
    );
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;
    final exePath = r.files.first.path!;
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
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('FFmpeg found at: $dir\n已添加到用户环境变量 PATH'), duration: const Duration(seconds: 3)));
        await _loadFeatures();
      } else {
        setState(() => _checking = false);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('所选文件不是有效的 ffmpeg.exe'), backgroundColor: Colors.red));
      }
    } catch (e) {
      setState(() => _checking = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('检测失败: $e'), backgroundColor: Colors.red));
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
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.search, size: 18),
            label: Text(isZh ? '检测 FFmpeg' : 'Detect FFmpeg', style: const TextStyle(fontSize: 12)),
            onPressed: _detect,
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 14),
            label: Text(isZh ? '手动选择' : 'Manual Select', style: const TextStyle(fontSize: 11)),
            onPressed: _browseFfmpeg,
          ),
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
      // Found: status + features
      final featureWidgets = <Widget>[
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
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: 14), label: Text(s.recheck, style: const TextStyle(fontSize: 11)),
            onPressed: _detect)),
      ];

      if (_featuresLoading) {
        featureWidgets.addAll([
          const SizedBox(height: 8),
          Row(children: [
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text(isZh ? '正在查询支持的功能...' : 'Querying supported features...', style: TextStyle(fontSize: 11, color: scheme.outline)),
          ]),
        ]);
      } else if (_features.isNotEmpty) {
        featureWidgets.addAll([
          Divider(color: scheme.outline.withAlpha(60)),
          const SizedBox(height: 4),
          Text(isZh ? '支持的功能' : 'Supported Features', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.primary)),
          const SizedBox(height: 6),
          DefaultTabController(
            length: _features.length,
            child: Column(children: [
              TabBar(isScrollable: true, tabAlignment: TabAlignment.start,
                  labelStyle: const TextStyle(fontSize: 11), unselectedLabelStyle: const TextStyle(fontSize: 11),
                  tabs: _features.keys.map((k) {
                    final label = k.startsWith('codec_') ? k.replaceFirst('codec_', '${isZh ? "编码" : "Codec"} ') : k;
                    return Tab(text: '$label (${_features[k]!.length})');
                  }).toList()),
              SizedBox(height: 180, child: TabBarView(
                children: _features.keys.map((k) => ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _features[k]!.length,
                  itemBuilder: (_, i) => Padding(padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(_features[k]![i], style: TextStyle(fontSize: 10, fontFamily: 'Consolas', color: scheme.onSurface))),
                )).toList(),
              )),
            ]),
          ),
        ]);
      }

      featureWidgets.addAll([
        const SizedBox(height: 8),
        Wrap(spacing: 4, runSpacing: 4, children: [
          _link('ffmpeg.org', 'https://ffmpeg.org'),
          _link('gyan.dev', 'https://github.com/AnimMouse/ffmpeg-stable-autobuild'),
          _link('BtbN', 'https://github.com/BtbN/FFmpeg-Builds/releases'),
        ]),
      ]);

      card = _card(scheme, glass, cardAlpha, cfg, s.ffmpegSettings, featureWidgets);
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
  const _CP({required this.initial});
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
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Custom Color'),
    content: SizedBox(width: 260, child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(height: 60, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8))),
      const SizedBox(height: 10),
      _sl('Hue', _h, 0, 360, (v) => setState(() => _h = v)),
      _sl('Sat', _s, 0, 1, (v) => setState(() => _s = v)),
      _sl('Val', _v, 0, 1, (v) => setState(() => _v = v)),
      Text('#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, c), child: const Text('Select')),
    ],
  );

  Widget _sl(String l, double v, double min, double max, ValueChanged<double> cb) => Row(children: [
    SizedBox(width: 30, child: Text(l, style: const TextStyle(fontSize: 10))),
    Expanded(child: Slider(value: v, min: min, max: max, onChanged: cb)),
  ]);
}
