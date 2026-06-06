import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const _presets = [
    ('Linear Purple', 0xFF5E6AD2), ('Ocean Blue', 0xFF3B82F6),
    ('Emerald', 0xFF10B981), ('Amber', 0xFFF59E0B),
    ('Rose', 0xFFEF4444), ('Cyan', 0xFF06B6D4), ('Violet', 0xFF8B5CF6),
  ];
  static const _sysFonts = [
    ('System Default', ''),
    // 中文
    ('Microsoft YaHei', 'Microsoft YaHei'), ('SimHei', 'SimHei'), ('SimSun', 'SimSun'),
    ('KaiTi', 'KaiTi'), ('FangSong', 'FangSong'), ('Microsoft JhengHei', 'Microsoft JhengHei'),
    ('MingLiU', 'MingLiU'), ('NSimSun', 'NSimSun'), ('DFKai-SB', 'DFKai-SB'),
    // 英文
    ('Arial', 'Arial'), ('Arial Black', 'Arial Black'), ('Calibri', 'Calibri'),
    ('Cambria', 'Cambria'), ('Candara', 'Candara'), ('Comic Sans MS', 'Comic Sans MS'),
    ('Consolas', 'Consolas'), ('Constantia', 'Constantia'), ('Corbel', 'Corbel'),
    ('Courier New', 'Courier New'), ('Ebrima', 'Ebrima'), ('Georgia', 'Georgia'),
    ('Impact', 'Impact'), ('Ink Free', 'Ink Free'), ('Lucida Console', 'Lucida Console'),
    ('Lucida Sans', 'Lucida Sans Unicode'), ('Malgun Gothic', 'Malgun Gothic'),
    ('Palatino Linotype', 'Palatino Linotype'), ('Segoe Print', 'Segoe Print'),
    ('Segoe Script', 'Segoe Script'), ('Segoe UI', 'Segoe UI'),
    ('Segoe UI Light', 'Segoe UI Light'), ('Segoe UI Semibold', 'Segoe UI Semibold'),
    ('Tahoma', 'Tahoma'), ('Times New Roman', 'Times New Roman'),
    ('Trebuchet MS', 'Trebuchet MS'), ('Verdana', 'Verdana'),
    ('Franklin Gothic', 'Franklin Gothic Medium'), ('Gabriola', 'Gabriola'),
    ('HoloLens MDL2 Assets', 'HoloLens MDL2 Assets'), ('Javanese Text', 'Javanese Text'),
    ('Leelawadee UI', 'Leelawadee UI'), ('MS Gothic', 'MS Gothic'),
    ('MV Boli', 'MV Boli'), ('Myanmar Text', 'Myanmar Text'),
    ('Nirmala UI', 'Nirmala UI'), ('Sitka', 'Sitka'),
    ('Sylfaen', 'Sylfaen'), ('Webdings', 'Webdings'), ('Wingdings', 'Wingdings'),
    ('Yu Gothic', 'Yu Gothic'), ('Noto Sans', 'Noto Sans'), ('Noto Serif', 'Noto Serif'),
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
            child: Column(children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _glass(context, s.appearance, [
                  SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                      title: Text(s.darkMode, style: TextStyle(color: clr)), value: state.darkMode,
                      onChanged: (v) => state.toggleDarkMode(v)),
                  SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                      title: Text(s.qGlass, style: TextStyle(color: clr)),
                      subtitle: Text(s.qGlassHint, style: TextStyle(fontSize: 11, color: scheme.outline)),
                      value: cfg.glassEffect,
                      onChanged: (v) => state.updateConfig((c) => c..glassEffect = v)),
                  // 背景图片（仅3D开启时可见）
                  if (cfg.glassEffect) ...[
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
                        ]),
                    ),
                    if (cfg.backgroundImage.isNotEmpty)
                      Row(children: [
                        Text('${s.bgOpacity}: ${(cfg.backgroundOpacity * 100).round()}%',
                            style: TextStyle(color: clr, fontSize: 11)),
                        Expanded(child: Slider(
                            value: cfg.backgroundOpacity, min: 0.0, max: 1.0, divisions: 100,
                            onChanged: (v) => state.updateConfig((c) => c..backgroundOpacity = v))),
                      ]),
                  ],
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
                ])),
                const SizedBox(width: 12),
                Expanded(child: _glass(context, s.language, [
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
                ])),
              ]),
              const SizedBox(height: 8),

              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _glass(context, s.font, [
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
                ])),
                const SizedBox(width: 12),
                Expanded(child: _glass(context, s.ffmpegSettings, [
                  Row(children: [
                    Icon(state.envOk ? Icons.check_circle : Icons.error, size: 14,
                        color: state.envOk ? Colors.green : scheme.error),
                    const SizedBox(width: 4),
                    Expanded(child: Text(state.envOk ? s.ffmpegFound : s.ffmpegNotFound,
                        style: TextStyle(color: clr, fontSize: 11))),
                    SizedBox(height: 26, child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.refresh, size: 12), label: Text(s.recheck, style: const TextStyle(fontSize: 10)),
                        onPressed: () async {
                          await state.recheckEnv();
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(state.envOk ? s.ffmpegFound : s.ffmpegNotFound)));
                        },
                        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), visualDensity: VisualDensity.compact))),
                  ]),
                  if (state.envOk && state.ffmpegVersion.isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 2, bottom: 4),
                        child: Text(state.ffmpegVersion, style: TextStyle(fontSize: 9, color: scheme.outline))),
                  const SizedBox(height: 8),
                  _pr(context, 'ffmpeg', cfg.ffmpegPath, (v) => state.updateConfig((c) => c..ffmpegPath = v)),
                  const SizedBox(height: 4),
                  _pr(context, 'ffprobe', cfg.ffprobePath, (v) => state.updateConfig((c) => c..ffprobePath = v)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 4, runSpacing: 4, children: [
                    _link('ffmpeg.org', 'https://ffmpeg.org'),
                    _link('gyan.dev', 'https://github.com/AnimMouse/ffmpeg-stable-autobuild'),
                    _link('BtbN', 'https://github.com/BtbN/FFmpeg-Builds/releases'),
                  ]),
                ])),
              ]),
              const SizedBox(height: 8),

              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _glass(context, s.output, [
                  _pf(context, s.outputDir, cfg.defaultOutputDir,
                      (v) => state.updateConfig((c) => c..defaultOutputDir = v),
                      () async {
                        final d = await FilePicker.platform.getDirectoryPath();
                        if (d != null) state.updateConfig((c) => c..defaultOutputDir = d);
                      }),
                ])),
                const SizedBox(width: 12),
                Expanded(child: _glass(context, s.dDebug, [
                  SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                      title: Text(s.dDebugMode, style: TextStyle(color: clr, fontSize: 13)), value: cfg.debugMode,
                      onChanged: (v) => state.updateConfig((c) => c..debugMode = v)),
                  SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
                      title: Text(s.dSaveLogs, style: TextStyle(color: clr, fontSize: 13)), value: cfg.saveLogs,
                      onChanged: (v) => state.updateConfig((c) => c..saveLogs = v)),
                  if (cfg.saveLogs)
                    _pf(context, s.dLogPath, cfg.logSavePath,
                        (v) => state.updateConfig((c) => c..logSavePath = v),
                        () async {
                          final d = await FilePicker.platform.getDirectoryPath();
                          if (d != null) state.updateConfig((c) => c..logSavePath = d);
                        }),
                ])),
              ]),
              const SizedBox(height: 24),
              Center(child: Text(s.swFooter,
                  style: TextStyle(fontSize: 10, color: scheme.outline.withAlpha(100)), textAlign: TextAlign.center)),
            ]),
          ),
        );
      },
    );
  }

  // ── 3D 选项卡效果 ──
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
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: inner,
      ),
    );
  }

  static Widget _pr(BuildContext ctx, String label, String value, ValueChanged<String> onChange) {
    final scheme = Theme.of(ctx).colorScheme;
    return Row(children: [
      SizedBox(width: 55, child: Text(label, style: TextStyle(fontSize: 10, color: scheme.outline))),
      Expanded(child: TextField(
        controller: TextEditingController(text: value),
        style: TextStyle(fontSize: 12, color: scheme.onSurface),
        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
        onChanged: onChange,
      )),
      IconButton(icon: Icon(Icons.folder_open, size: 16, color: scheme.primary),
          onPressed: () async {
            final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['exe', '', 'bat', 'cmd']);
            if (r != null && r.files.isNotEmpty && r.files.first.path != null) onChange(r.files.first.path!);
          }, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24)),
    ]);
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

  static Widget _link(String label, String url) => SizedBox(height: 22, child: OutlinedButton(
      onPressed: () => Process.run('cmd', ['/c', 'start', url]),
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, visualDensity: VisualDensity.compact),
      child: Text(label, style: const TextStyle(fontSize: 9))));

  static Future<void> _pickFont(BuildContext ctx, AppState state) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['ttf', 'otf']);
    if (r != null && r.files.isNotEmpty && r.files.first.path != null) {
      final path = r.files.first.path!;
      final name = path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');
      state.updateConfig((c) => c..fontFamily = name);
      // 打开字体文件让 Windows 安装
      Process.run('cmd', ['/c', 'start', '', path]);
      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text('Opening font: "$name" — click Install in the preview window, then restart the app'),
          duration: const Duration(seconds: 5)));
    }
  }

  static Future<void> _pickColor(BuildContext ctx, AppState state) async {
    final picked = await showDialog<Color>(context: ctx, builder: (_) => _CP(initial: Color(state.config.themeColor)));
    if (picked != null) state.updateConfig((c) => c..themeColor = picked.toARGB32());
  }
}

class _CP extends StatefulWidget { final Color initial; const _CP({required this.initial}); @override State<_CP> createState() => _CPState(); }
class _CPState extends State<_CP> {
  late double _h,_s,_v;
  @override void initState() { super.initState(); final h = HSVColor.fromColor(widget.initial); _h=h.hue;_s=h.saturation;_v=h.value; }
  Color get c => HSVColor.fromAHSV(1,_h,_s,_v).toColor();
  @override Widget build(BuildContext context) => AlertDialog(
    title: const Text('Custom Color'),
    content: SizedBox(width:260,child:Column(mainAxisSize:MainAxisSize.min,children:[
      Container(height:60,decoration:BoxDecoration(color:c,borderRadius:BorderRadius.circular(8))),
      const SizedBox(height:10),
      _sl('Hue',_h,0,360,(v)=>setState(()=>_h=v)), _sl('Sat',_s,0,1,(v)=>setState(()=>_s=v)), _sl('Val',_v,0,1,(v)=>setState(()=>_v=v)),
      Text('#${c.toARGB32().toRadixString(16).padLeft(8,'0').substring(2).toUpperCase()}',style:const TextStyle(fontFamily:'monospace',fontSize:11)),
    ])),
    actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(context,c),child:const Text('Select'))],
  );
  Widget _sl(String l,double v,double min,double max,ValueChanged<double> cb)=>Row(children:[
    SizedBox(width:30,child:Text(l,style:const TextStyle(fontSize:10))),Expanded(child:Slider(value:v,min:min,max:max,onChanged:cb))]);
}
