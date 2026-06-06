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
      resolutionW: v.resolutionW ?? widget.video.width,
      resolutionH: v.resolutionH ?? widget.video.height,
      audioCodec: v.audioCodec, audioBitrate: v.audioBitrate, audioChannels: v.audioChannels,
      subtitleEnabled: v.subtitleEnabled, subtitleSource: v.subtitleSource,
      subtitleFile: v.subtitleFile, subtitleIndex: v.subtitleIndex,
      outputFormat: v.outputFormat, namingMode: v.namingMode, namingValue: v.namingValue,
    );
    _fpsValue = v.framerate;
    // 判断当前分辨率预设
    if (v.resolutionW == widget.video.width && v.resolutionH == widget.video.height) {
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
    if (_cfg.namingMode == 'suffix') _tf(sc, s.cfgSuffix, _cfg.namingValue, (v) => _cfg.namingValue = v),
    if (_cfg.namingMode == 'custom') _tf(sc, s.cfgFilename, _cfg.namingValue, (v) => _cfg.namingValue = v),
    Padding(padding: const EdgeInsets.only(top: 8), child: Text('→ ${_previewPath()}',
        style: TextStyle(fontSize: 10, color: sc.outline, fontFamily: 'monospace'))),
  ]);

  String _previewPath() {
    final base = widget.video.filename.replaceAll(RegExp(r'\.[^.]+$'), '');
    final ext = _cfg.outputFormat == 'keep' ? widget.video.filepath.split('.').last : _cfg.outputFormat;
    if (_cfg.namingMode == 'keep') return '$base.$ext';
    if (_cfg.namingMode == 'suffix') return '$base${_cfg.namingValue}.$ext';
    return '${_cfg.namingValue}.$ext';
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
      _dd(sc, s.cfgRate, _cfg.crf == null ? 'bitrate' : 'crf', ['bitrate', 'crf'],
          [s.cfgBitrate, s.cfgCrf], (v) => setState(() => _cfg.crf = v == 'crf' ? 23 : null)),
      if (_cfg.crf != null)
        _sl(sc, s.cfgCrf, _cfg.crf!, 0, 51, (v) => setState(() => _cfg.crf = v))
      else
        _num(sc, s.cfgBitrate, _cfg.videoBitrate, (v) => setState(() => _cfg.videoBitrate = v)),
      if (_cfg.gpu == 'CPU')
        _dd(sc, 'Preset', _cfg.preset, ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'],
            ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'],
            (v) => setState(() => _cfg.preset = v)),
      // 分辨率预设（自定义时才显示 W/H）
      _dd(sc, s.cfgRes, _resPreset, ['original', '2160p', '1080p', '720p', '480p', 'custom'],
          [s.cfgResOrig, s.cfgRes4k, s.cfgRes1080p, s.cfgRes720p, s.cfgRes480p, s.cfgResCustom], (v) {
        setState(() => _resPreset = v);
        final m = {'2160p': (3840, 2160), '1080p': (1920, 1080), '720p': (1280, 720), '480p': (854, 480)};
        if (v == 'original') { _cfg.resolutionW = widget.video.width; _cfg.resolutionH = widget.video.height; }
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
  Widget _audTab(AppStrings s, ColorScheme sc) {
    final aVals = _audioCodecs.values.toList();
    final aLabels = _audioCodecs.keys.toList();
    return ListView(children: [
      _dd(sc, s.cfgAudioCodec, _cfg.audioCodec, aVals, aLabels,
          (v) => setState(() => _cfg.audioCodec = v)),
      _num(sc, s.cfgAudioBitrate, _cfg.audioBitrate, (v) => setState(() => _cfg.audioBitrate = v)),
      _dd(sc, s.cfgChannels, '${_cfg.audioChannels ?? 'keep'}', ['keep', '1', '2', '6'],
          [s.cfgChKeep, s.cfgChMono, s.cfgChStereo, s.cfgCh51],
          (v) => setState(() { _cfg.audioChannels = v == 'keep' ? null : int.tryParse(v); })),
    ]);
  }

  // ═══ Subtitle ═══
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
    ],
  ]);

  // ═══ Helpers ═══
  Widget _dd(ColorScheme sc, String l, String v, List<String> vals, List<String> labels, ValueChanged<String> cb) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
        SizedBox(width: 64, child: Text(l, style: TextStyle(fontSize: 12, color: sc.onSurface))),
        Expanded(child: DropdownButtonFormField<String>(
            value: vals.contains(v) ? v : vals.first, isDense: true,
            style: TextStyle(fontSize: 12, color: sc.onSurface), dropdownColor: sc.surface,
            items: List.generate(vals.length, (i) => DropdownMenuItem(value: vals[i],
                child: Text(labels[i], style: TextStyle(fontSize: 12, color: sc.onSurface)))),
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

  Future<void> _pickSub() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['srt', 'ass', 'ssa', 'sub', 'vtt']);
    if (r != null && r.files.isNotEmpty && r.files.first.path != null) setState(() => _cfg.subtitleFile = r.files.first.path!);
  }
}
