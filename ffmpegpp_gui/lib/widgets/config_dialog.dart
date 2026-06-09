import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

class ConfigDialog extends StatefulWidget {
  final VideoFile video;
  final ValueChanged<TranscodeConfig> onSave;
  const ConfigDialog({super.key, required this.video, required this.onSave});
  @override
  State<ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<ConfigDialog> with SingleTickerProviderStateMixin {
  late TranscodeConfig _cfg;
  late TabController _tab;
  String _resPreset = 'original'; // 追踪分辨率预设选择
  double? _fpsValue; // null=保持原帧率

  static const _fpsOptions = [null, 24.0, 23.976, 25.0, 30.0, 29.97, 50.0, 60.0, 59.94, 120.0, 240.0];
  static const _fpsLabels = ['Keep', '24', '23.976', '25', '30', '29.97', '50', '60', '59.94', '120', '240'];

  // GPU → 兼容 codec（硬件加速排最前，默认选第一个）
  static const _gpuCodecSuffix = {
    'CPU':    ['libx264', 'libx265', 'libaom-av1', 'libvpx-vp9', 'mpeg4', 'prores_ks', 'ffv1', 'copy'],
    'NVIDIA': ['h264_nvenc', 'hevc_nvenc', 'av1_nvenc', 'libx264', 'libx265', 'libaom-av1', 'libvpx-vp9', 'mpeg4', 'prores_ks', 'ffv1', 'copy'],
    'AMD':    ['h264_amf', 'hevc_amf', 'av1_amf', 'libx264', 'libx265', 'libaom-av1', 'libvpx-vp9', 'mpeg4', 'prores_ks', 'ffv1', 'copy'],
    'Intel':  ['h264_qsv', 'hevc_qsv', 'av1_qsv', 'libx264', 'libx265', 'libaom-av1', 'libvpx-vp9', 'mpeg4', 'prores_ks', 'ffv1', 'copy'],
  };
  // 标记哪些是硬件编码器
  static const _hwCodecs = {
    'h264_nvenc', 'hevc_nvenc', 'av1_nvenc',
    'h264_amf', 'hevc_amf', 'av1_amf',
    'h264_qsv', 'hevc_qsv', 'av1_qsv',
  };
  bool get _isHwCodec => _hwCodecs.contains(_cfg.videoCodec);
  static const _codecGroups = {
    'libx264': 'H.264', 'h264_nvenc': 'H.264', 'h264_amf': 'H.264', 'h264_qsv': 'H.264',
    'libx265': 'H.265/HEVC', 'hevc_nvenc': 'H.265', 'hevc_amf': 'H.265', 'hevc_qsv': 'H.265',
    'libaom-av1': 'AV1', 'av1_nvenc': 'AV1', 'av1_amf': 'AV1', 'av1_qsv': 'AV1',
    'libvpx-vp9': 'VP9', 'mpeg4': 'MPEG-4', 'prores_ks': 'ProRes', 'ffv1': 'FFV1', 'copy': 'Copy',
  };

  List<String> _compatibleCodecs() => _gpuCodecSuffix[_cfg.gpu] ?? _gpuCodecSuffix['CPU']!;
  List<String> _codecLabels(List<String> codecs) => codecs.map((c) =>
      '${_hwCodecs.contains(c) ? "⚡ " : ""}${_codecGroups[c] ?? 'Other'}: $c').toList();
  static const _audioCodecs = {
    'AAC': 'aac', 'MP3 (LAME)': 'libmp3lame', 'Opus': 'libopus',
    'FLAC (lossless)': 'flac', 'Copy stream': 'copy',
  };

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    final v = widget.video.config;
    // 确保默认 codec 与 GPU 兼容
    final defCodecs = _gpuCodecSuffix[v.gpu] ?? _gpuCodecSuffix['CPU']!;
    final initCodec = defCodecs.contains(v.videoCodec) ? v.videoCodec : defCodecs.first;

    _cfg = TranscodeConfig(
      videoCodec: initCodec, gpu: v.gpu, preset: v.preset, crf: v.crf,
      videoBitrate: v.videoBitrate, framerate: v.framerate,
      resolutionW: v.resolutionW, resolutionH: v.resolutionH,
      audioCodec: v.audioCodec, audioBitrate: v.audioBitrate, audioChannels: v.audioChannels,
      subtitleEnabled: v.subtitleEnabled, subtitleSource: v.subtitleSource,
      subtitleFile: v.subtitleFile, subtitleIndex: v.subtitleIndex,
      subtitleFontName: v.subtitleFontName, subtitleFontSize: v.subtitleFontSize,
      subtitleFontColor: v.subtitleFontColor, subtitleOutlineWidth: v.subtitleOutlineWidth,
      subtitleOutlineColor: v.subtitleOutlineColor,
      outputFormat: v.outputFormat, namingMode: v.namingMode, namingValue: v.namingValue,
    );
    _fpsValue = v.framerate;
    // 判断当前分辨率预设（null = 保持原分辨率）
    if (v.resolutionW == null && v.resolutionH == null) {
      _resPreset = 'original';
    } else if (v.resolutionW == 3840 && v.resolutionH == 2160) {
      _resPreset = '2160p';
    } else if (v.resolutionW == 1920 && v.resolutionH == 1080) {
      _resPreset = '1080p';
    } else if (v.resolutionW == 1280 && v.resolutionH == 720) {
      _resPreset = '720p';
    } else if (v.resolutionW == 854 && v.resolutionH == 480) {
      _resPreset = '480p';
    } else {
      _resPreset = 'custom';
    }
  }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = AppStrings.of(context.read<AppState>().config.language);

    return AlertDialog(
      title: Text('${s.editTitle} — ${widget.video.filename}',
          style: theme.textTheme.titleMedium?.copyWith(color: scheme.onSurface)),
      content: SizedBox(width: 520, height: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TabBar(controller: _tab, tabAlignment: TabAlignment.fill, tabs: [
          Tab(text: s.tabOutput), Tab(text: s.tabVideo), Tab(text: s.tabAudio), Tab(text: s.tabSubtitle),
        ]),
        Expanded(child: TabBarView(controller: _tab, children: [
          _outTab(s, scheme), _vidTab(s, scheme), _audTab(s, scheme), _subTab(s, scheme),
        ])),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
        FilledButton(onPressed: () { widget.onSave(_cfg); Navigator.pop(context); }, child: Text(s.saveConfig)),
      ],
    );
  }

  // ═══ Output ═══
  Widget _outTab(AppStrings s, ColorScheme sc) => ListView(children: [
    _dd(sc, s.cfgFormat, _cfg.outputFormat, ['keep', 'mp4', 'mkv', 'mov', 'avi', 'webm'],
        [s.cfgFormatKeep, 'MP4', 'MKV', 'MOV', 'AVI', 'WEBM'], (v) => setState(() => _cfg.outputFormat = v)),
    _dd(sc, s.cfgNaming, _cfg.namingMode, ['keep', 'suffix', 'custom'],
        [s.cfgNamingKeep, s.cfgNamingSuffix, s.cfgNamingCustom], (v) => setState(() => _cfg.namingMode = v)),
    if (_cfg.namingMode == 'suffix') _tf(sc, s.cfgSuffix, _cfg.namingValue, (v) => setState(() => _cfg.namingValue = v)),
    if (_cfg.namingMode == 'custom') _tf(sc, s.cfgFilename, _cfg.namingValue, (v) => setState(() => _cfg.namingValue = v)),
    Padding(padding: const EdgeInsets.only(top: 8), child: Text('→ ${_previewPath()}',
        style: TextStyle(fontSize: 10, color: sc.outline, fontFamily: 'monospace'))),
  ]);

  String _previewPath() {
    final base = widget.video.filename.replaceAll(RegExp(r'\.[^.]+$'), '');
    final ext = _cfg.outputFormat == 'keep' ? widget.video.filepath.split('.').last : _cfg.outputFormat;
    if (_cfg.namingMode == 'keep') return '$base.$ext';
    if (_cfg.namingMode == 'suffix') return '$base${_cfg.namingValue}.$ext';
    // custom: user enters full filename (with or without extension)
    final custom = _cfg.namingValue;
    if (custom.contains('.')) return custom; // already has extension
    return '$custom.$ext';
  }

  // ═══ Video ═══
  Widget _vidTab(AppStrings s, ColorScheme sc) {
    final codecs = _compatibleCodecs();
    final labels = _codecLabels(codecs);
    // 确保当前 codec 在兼容列表中
    if (!codecs.contains(_cfg.videoCodec)) {
      _cfg.videoCodec = codecs.first;
    }

    return ListView(children: [
      _dd(sc, s.cfgCodec, _cfg.videoCodec, codecs, labels,
          (v) => setState(() => _cfg.videoCodec = v)),
      _dd(sc, s.cfgGpu, _cfg.gpu, ['CPU', 'NVIDIA', 'AMD', 'Intel'],
          ['CPU', 'NVIDIA', 'AMD', 'Intel'], (v) => setState(() {
        _cfg.gpu = v;
        // GPU 变化时自动选第一个（硬件）编码器
        final codecs = _compatibleCodecs();
        _cfg.videoCodec = codecs.first;
      })),
      _dd(sc, s.cfgRate,
          _cfg.crf != null ? 'crf' : (_cfg.videoBitrate != null ? 'bitrate' : 'keep'),
          ['bitrate', 'crf', 'keep'],
          [s.cfgBitrate, s.cfgCrf, s.cfgRateKeep],
          (v) => setState(() {
            if (v == 'crf') { _cfg.crf = 23; _cfg.videoBitrate = null; }
            else if (v == 'bitrate') { _cfg.crf = null; _cfg.videoBitrate = 2000; }
            else { _cfg.crf = null; _cfg.videoBitrate = null; }
          })),
      if (_cfg.crf != null)
        _sl(sc, s.cfgCrf, _cfg.crf!, 0, 51, (v) => setState(() => _cfg.crf = v))
      else if (_cfg.videoBitrate != null)
        _num(sc, s.cfgBitrate, _cfg.videoBitrate!, (v) => setState(() => _cfg.videoBitrate = v)),
      if (_cfg.gpu == 'CPU')
        _dd(sc, 'Preset', _cfg.preset, ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'],
            ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'],
            (v) => setState(() => _cfg.preset = v)),
      // 分辨率预设（自定义时才显示 W/H）
      _dd(sc, s.cfgRes, _resPreset, ['original', '2160p', '1080p', '720p', '480p', 'custom'],
          [s.cfgResOrig, s.cfgRes4k, s.cfgRes1080p, s.cfgRes720p, s.cfgRes480p, s.cfgResCustom], (v) {
        setState(() => _resPreset = v);
        final m = {'2160p': (3840, 2160), '1080p': (1920, 1080), '720p': (1280, 720), '480p': (854, 480)};
        if (v == 'original') { _cfg.resolutionW = null; _cfg.resolutionH = null; }
        else if (m.containsKey(v)) { final (w, h) = m[v]!; _cfg.resolutionW = w; _cfg.resolutionH = h; }
      }),
      if (_resPreset == 'custom')
        Row(children: [
          SizedBox(width: 72, child: _nf(sc, 'W', '${_cfg.resolutionW ?? widget.video.width}',
              (x) => setState(() => _cfg.resolutionW = int.tryParse(x)))),
          Text(' × ', style: TextStyle(color: sc.onSurface)),
          SizedBox(width: 72, child: _nf(sc, 'H', '${_cfg.resolutionH ?? widget.video.height}',
              (x) => setState(() => _cfg.resolutionH = int.tryParse(x)))),
        ]),
      // FPS: 10 个固定选项 + Keep
      _dd(sc, s.cfgFps,
          _fpsValue == null ? 'keep' : _fpsValue!.toString(),
          _fpsOptions.map((f) => f?.toString() ?? 'keep').toList(),
          _fpsLabels.toList(), (v) => setState(() {
        _fpsValue = v == 'keep' ? null : double.tryParse(v);
        _cfg.framerate = _fpsValue;
      })),
    ]);
  }

  // ═══ Audio ═══
  static const _audBitratePresets = [null, 64, 96, 128, 160, 192, 256, 320];
  static const _audBitrateLabels = ['Keep (original)', '64 kbps', '96 kbps', '128 kbps', '160 kbps', '192 kbps', '256 kbps', '320 kbps'];

  Widget _audTab(AppStrings s, ColorScheme sc) {
    final aVals = _audioCodecs.values.toList();
    final aLabels = _audioCodecs.keys.toList();
    return ListView(children: [
      _dd(sc, s.cfgAudioCodec, _cfg.audioCodec, aVals, aLabels,
          (v) => setState(() => _cfg.audioCodec = v)),
      _dd(sc, s.cfgAudioBitrate,
          '${_cfg.audioBitrate ?? 'keep'}',
          _audBitratePresets.map((p) => '${p ?? 'keep'}').toList(),
          _audBitrateLabels.toList(),
          (v) => setState(() => _cfg.audioBitrate = v == 'keep' ? null : int.tryParse(v))),
      _dd(sc, s.cfgChannels, '${_cfg.audioChannels ?? 'keep'}', ['keep', '1', '2', '6'],
          [s.cfgChKeep, s.cfgChMono, s.cfgChStereo, s.cfgCh51],
          (v) => setState(() { _cfg.audioChannels = v == 'keep' ? null : int.tryParse(v); })),
    ]);
  }

  // ═══ Subtitle ═══
  // 常用字体列表
  static const _subtitleFonts = [
    'Arial', 'Microsoft YaHei', 'SimHei', 'SimSun', 'KaiTi',
    'Consolas', 'Segoe UI', 'Tahoma', 'Times New Roman', 'Verdana',
    'Noto Sans CJK SC', 'Source Han Sans CN', 'Roboto', 'Open Sans',
  ];

  Widget _subTab(AppStrings s, ColorScheme sc) => ListView(children: [
    SwitchListTile(title: Text(s.cfgBurn, style: TextStyle(color: sc.onSurface)),
        value: _cfg.subtitleEnabled, onChanged: (v) => setState(() => _cfg.subtitleEnabled = v),
        contentPadding: EdgeInsets.zero, dense: true),
    if (_cfg.subtitleEnabled) ...[
      _dd(sc, s.cfgSubSource, _cfg.subtitleSource, ['external', 'embedded'],
          [s.cfgSubExternal, s.cfgSubEmbedded], (v) => setState(() => _cfg.subtitleSource = v)),
      if (_cfg.subtitleSource == 'external')
        ListTile(
          title: Text(_cfg.subtitleFile ?? s.cfgSubNotSel, style: TextStyle(fontSize: 12, color: sc.onSurface)),
          trailing: Icon(Icons.folder_open, size: 16, color: sc.onSurface),
          onTap: _pickSub, dense: true, contentPadding: EdgeInsets.zero,
        ),
      const Divider(),
      // ── 字幕样式 — 两列布局 ──
      Text(s.cfgSubStyle, style: TextStyle(fontSize: 11, color: sc.outline)),
      const SizedBox(height: 6),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 左列：字体 + 大小
        Expanded(child: Column(children: [
          _dd(sc, s.cfgSubFont, _cfg.subtitleFontName, _subtitleFonts, _subtitleFonts,
              (v) => setState(() => _cfg.subtitleFontName = v)),
          _sl(sc, s.cfgSubSize, _cfg.subtitleFontSize, 12, 72, (v) => setState(() => _cfg.subtitleFontSize = v)),
        ])),
        const SizedBox(width: 12),
        // 右列：描边 + 颜色
        Expanded(child: Column(children: [
          _sl(sc, s.cfgSubOutline, _cfg.subtitleOutlineWidth, 0, 8, (v) => setState(() => _cfg.subtitleOutlineWidth = v)),
          _colorRow(sc, s.cfgSubColor, _cfg.subtitleFontColor, (v) => setState(() => _cfg.subtitleFontColor = v)),
          _colorRow(sc, s.cfgSubOutlineColor, _cfg.subtitleOutlineColor, (v) => setState(() => _cfg.subtitleOutlineColor = v)),
        ])),
      ]),
    ],
  ]);

  // ═══ Helpers ═══
  Widget _dd(ColorScheme sc, String l, String v, List<String> vals, List<String> labels, ValueChanged<String> cb) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
        SizedBox(width: 50, child: Text(l, style: TextStyle(fontSize: 11, color: sc.onSurface), overflow: TextOverflow.ellipsis)),
        Expanded(child: DropdownButtonFormField<String>(
            value: vals.contains(v) ? v : vals.first, isDense: true, isExpanded: true,
            style: TextStyle(fontSize: 12, color: sc.onSurface), dropdownColor: sc.surface,
            menuMaxHeight: 300,
            items: List.generate(vals.length, (i) => DropdownMenuItem(value: vals[i],
                child: Text(labels[i], style: TextStyle(fontSize: 11, color: sc.onSurface), overflow: TextOverflow.ellipsis))),
            onChanged: (x) { if (x != null) cb(x); },
            decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: sc.outline.withAlpha(120)))))),
      ]));

  Widget _sl(ColorScheme sc, String l, int v, int min, int max, ValueChanged<int> cb) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
        SizedBox(width: 64, child: Text(l, style: TextStyle(fontSize: 12, color: sc.onSurface))),
        Expanded(child: Slider(value: v.toDouble(), min: min.toDouble(), max: max.toDouble(),
            divisions: max - min, label: '$v', onChanged: (x) => cb(x.round()))),
        SizedBox(width: 26, child: Text('$v', textAlign: TextAlign.end, style: TextStyle(fontSize: 12, color: sc.onSurface))),
      ]));

  Widget _num(ColorScheme sc, String l, int v, ValueChanged<int> cb) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
        SizedBox(width: 64, child: Text(l, style: TextStyle(fontSize: 12, color: sc.onSurface))),
        SizedBox(width: 72, child: TextField(
            controller: TextEditingController(text: '$v'), style: TextStyle(fontSize: 12, color: sc.onSurface),
            keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true),
            onChanged: (x) { final n = int.tryParse(x); if (n != null) cb(n); })),
      ]));

  Widget _nf(ColorScheme sc, String label, String v, ValueChanged<String> cb) => TextField(
      controller: TextEditingController(text: v), style: TextStyle(fontSize: 12, color: sc.onSurface),
      keyboardType: TextInputType.number, decoration: InputDecoration(labelText: label, isDense: true,
          labelStyle: TextStyle(color: sc.outline)), onChanged: cb);

  Widget _tf(ColorScheme sc, String l, String v, ValueChanged<String> cb) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
        SizedBox(width: 64, child: Text(l, style: TextStyle(fontSize: 12, color: sc.onSurface))),
        Expanded(child: TextField(controller: TextEditingController(text: v),
            style: TextStyle(fontSize: 12, color: sc.onSurface),
            decoration: InputDecoration(isDense: true, enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: sc.outline.withAlpha(120)))),
            onChanged: cb)),
      ]));

  Widget _colorRow(ColorScheme sc, String label, String hexValue, ValueChanged<String> cb) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
        SizedBox(width: 50, child: Text(label, style: TextStyle(fontSize: 11, color: sc.onSurface))),
        Expanded(child: TextField(
            controller: TextEditingController(text: hexValue),
            style: TextStyle(fontSize: 12, color: sc.onSurface),
            decoration: InputDecoration(isDense: true, hintText: '#FFFFFF',
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: sc.outline.withAlpha(120)))),
            onChanged: cb)),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () async {
            final initial = _hexToColor(hexValue);
            final picked = await showDialog<Color>(context: context, builder: (_) => _ColorPicker(initial: initial));
            if (picked != null) {
              final hex = '#${picked.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
              cb(hex);
            }
          },
          child: Container(width: 24, height: 24,
            decoration: BoxDecoration(color: _hexToColor(hexValue), borderRadius: BorderRadius.circular(4),
                border: Border.all(color: sc.outline.withAlpha(120)))),
        ),
      ]));

  static Color _hexToColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.tryParse(hex, radix: 16) ?? 0xFFFFFFFF);
  }

  Future<void> _pickSub() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['srt', 'ass', 'ssa', 'sub', 'vtt']);
    if (r != null && r.files.isNotEmpty && r.files.first.path != null) setState(() => _cfg.subtitleFile = r.files.first.path!);
  }
}

// 简单的 HSV 颜色选择器
class _ColorPicker extends StatefulWidget {
  final Color initial;
  const _ColorPicker({required this.initial});
  @override
  State<_ColorPicker> createState() => _ColorPickerState();
}
class _ColorPickerState extends State<_ColorPicker> {
  late double _h, _s, _v;
  @override void initState() { super.initState(); final c = HSVColor.fromColor(widget.initial); _h = c.hue; _s = c.saturation; _v = c.value; }
  Color get c => HSVColor.fromAHSV(1, _h, _s, _v).toColor();
  @override Widget build(BuildContext context) => AlertDialog(
    title: const Text('Select Color'),
    content: SizedBox(width: 260, child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(height: 50, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8))),
      const SizedBox(height: 10),
      _sl('H', _h, 0, 360, (v) => setState(() => _h = v)),
      _sl('S', _s, 0, 1, (v) => setState(() => _s = v)),
      _sl('V', _v, 0, 1, (v) => setState(() => _v = v)),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, c), child: const Text('OK')),
    ],
  );
  Widget _sl(String l, double v, double min, double max, ValueChanged<double> cb) => Row(children: [
    SizedBox(width: 20, child: Text(l, style: const TextStyle(fontSize: 10))),
    Expanded(child: Slider(value: v, min: min, max: max, onChanged: cb)),
  ]);
}
