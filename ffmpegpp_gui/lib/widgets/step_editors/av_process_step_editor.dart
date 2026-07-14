import 'package:flutter/material.dart';

class AvProcessStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const AvProcessStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<AvProcessStepEditor> createState() => _AvProcessStepEditorState();
}

class _AvProcessStepEditorState extends State<AvProcessStepEditor> {
  static const _gpuCodecs = {
    'CPU': ['libx264', 'libx265', 'libvpx-vp9', 'libaom-av1', 'libsvtav1', 'libx264rgb', 'copy'],
    'NVIDIA': ['h264_nvenc', 'hevc_nvenc', 'av1_nvenc'],
    'AMD': ['h264_amf', 'hevc_amf', 'av1_amf'],
    'Intel': ['h264_qsv', 'hevc_qsv', 'av1_qsv', 'vp9_qsv'],
  };
  static const _codecLabels = {
    'libx264': 'H.264 (x264)',
    'libx265': 'H.265/HEVC (x265)',
    'libvpx-vp9': 'VP9',
    'libaom-av1': 'AV1 (libaom)',
    'libsvtav1': 'AV1 (SVT-AV1)',
    'libx264rgb': 'H.264 RGB',
    'h264_nvenc': 'H.264 (NVENC)',
    'hevc_nvenc': 'H.265 (NVENC)',
    'av1_nvenc': 'AV1 (NVENC)',
    'h264_amf': 'H.264 (AMF)',
    'hevc_amf': 'H.265 (AMF)',
    'av1_amf': 'AV1 (AMF)',
    'h264_qsv': 'H.264 (QSV)',
    'hevc_qsv': 'H.265 (QSV)',
    'av1_qsv': 'AV1 (QSV)',
    'vp9_qsv': 'VP9 (QSV)',
  };
  static String _copyLabel(bool zh) => zh ? '复制流 (不重编码)' : 'Copy Stream';
  static Map<String, String> _audioCodecLabelsFor(bool zh) => {
    'aac': 'AAC',
    'libmp3lame': 'MP3 (LAME)',
    'libopus': 'Opus',
    'libvorbis': 'Vorbis',
    'flac': zh ? 'FLAC (无损)' : 'FLAC (Lossless)',
    'pcm_s16le': 'PCM 16-bit',
    'ac3': zh ? 'AC3 (杜比)' : 'AC3 (Dolby)',
    'eac3': zh ? 'E-AC3 (杜比+)' : 'E-AC3 (Dolby+)',
    'copy': zh ? '复制流' : 'Copy Stream',
  };
  static const _presets = ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'];
  static const _resolutions = ['original', '2160p', '1080p', '720p', '480p', '360p', 'custom'];
  static const _fpsOptions = ['keep', '24', '25', '30', '48', '50', '60', '120', 'custom'];
  static const _audioCodecs = ['aac', 'libmp3lame', 'libopus', 'libvorbis', 'flac', 'pcm_s16le', 'ac3', 'eac3', 'copy'];
  static const _audioBitrates = [64, 96, 128, 160, 192, 256, 320, 512];
  static const _channels = ['keep', '1', '2', '6', '8'];
  static const _pixFmts = ['auto', 'yuv420p', 'yuv422p', 'yuv444p', 'yuv420p10le', 'yuv422p10le', 'nv12', 'p010le', 'rgb24'];

  late TextEditingController _bitrateCtrl, _resWCtrl, _resHCtrl, _fpsCtrl;

  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('video_codec', () => 'libx264');
    p.putIfAbsent('gpu', () => 'CPU');
    p.putIfAbsent('rate_mode', () => 'keep');
    p.putIfAbsent('preset', () => 'medium');
    p.putIfAbsent('resolution', () => 'original');
    p.putIfAbsent('fps', () => 'keep');
    p.putIfAbsent('audio_codec', () => 'aac');
    p.putIfAbsent('audio_channels', () => 'keep');
    p.putIfAbsent('pix_fmt', () => 'auto');
    // 验证 video_codec 是否有效，无效则重置为默认值
    if (!_allCodecs.contains(p['video_codec'])) {
      p['video_codec'] = 'libx264';
    }
    _bitrateCtrl = TextEditingController(text: '${p['video_bitrate'] ?? ''}');
    _resWCtrl = TextEditingController(text: '${p['resolution_w'] ?? ''}');
    _resHCtrl = TextEditingController(text: '${p['resolution_h'] ?? ''}');
    _fpsCtrl = TextEditingController(text: '${p['fps_value'] ?? ''}');
  }

  @override
  void dispose() {
    _bitrateCtrl.dispose(); _resWCtrl.dispose(); _resHCtrl.dispose(); _fpsCtrl.dispose();
    super.dispose();
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  static int _crfMaxForCodec(String codec) {
    if (codec.contains('av1') || codec.contains('vp9') || codec == 'libvpx-vp9' || codec == 'libaom-av1' || codec == 'libsvtav1') return 63;
    return 51; // H.264/H.265
  }

  static const _allCodecs = [
    'libx264', 'libx265', 'libvpx-vp9', 'libaom-av1', 'libsvtav1', 'libx264rgb',
    'h264_nvenc', 'hevc_nvenc', 'av1_nvenc',
    'h264_amf', 'hevc_amf', 'av1_amf',
    'h264_qsv', 'hevc_qsv', 'av1_qsv', 'vp9_qsv',
    'copy',
  ];

  Set<String> get _gpuAccelerated => Set<String>.from(_gpuCodecs[p['gpu']] ?? []);

  InputDecoration _dec(String label) => InputDecoration(
    labelText: label, isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  Widget _dropdown({required String label, required String value, required List<String> items,
      List<String>? itemLabels, required ColorScheme cs, required ValueChanged<String> onChanged}) {
    final safe = items.contains(value) ? value : items.first;
    return DropdownButtonFormField<String>(
      borderRadius: BorderRadius.circular(12),
      value: safe, isExpanded: true, decoration: _dec(label),
      dropdownColor: cs.surface, style: TextStyle(fontSize: 13, color: cs.onSurface),
      items: List.generate(items.length, (i) => DropdownMenuItem(
        value: items[i], child: Text(itemLabels != null ? itemLabels[i] : items[i], style: TextStyle(fontSize: 13, color: cs.onSurface)),
      )),
      onChanged: (v) { if (v != null) onChanged(v); },
    );
  }

  Widget _codecDropdown(ColorScheme cs, bool zh) {
    final gpu = p['gpu'] as String;
    final accel = _gpuAccelerated;
    final current = p['video_codec'] as String;
    final safe = _allCodecs.contains(current) ? current : _allCodecs.first;

    return DropdownButtonFormField<String>(
      borderRadius: BorderRadius.circular(12),
      value: safe, isExpanded: true, decoration: _dec(zh ? '编码器' : 'Codec'),
      dropdownColor: cs.surface, style: TextStyle(fontSize: 13, color: cs.onSurface),
      items: _allCodecs.map((codec) {
        final label = codec == 'copy' ? _copyLabel(zh) : (_codecLabels[codec] ?? codec);
        final isAccel = accel.contains(codec);
        final isCpu = (_gpuCodecs['CPU'] ?? []).contains(codec);
        final isCopy = codec == 'copy';

        String suffix = '';
        Color textColor = cs.onSurface;
        if (gpu != 'CPU' && !isCopy) {
          if (isAccel) {
            suffix = ' ⚡$gpu';
            textColor = cs.primary;
          } else if (isCpu) {
            suffix = ' (CPU)';
            textColor = cs.onSurfaceVariant;
          }
        }

        return DropdownMenuItem(
          value: codec,
          child: Text('$label$suffix', style: TextStyle(fontSize: 13, color: textColor,
              fontWeight: isAccel && gpu != 'CPU' ? FontWeight.w600 : FontWeight.w400)),
        );
      }).toList(),
      onChanged: (v) { if (v != null) _update('video_codec', v); },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '视频' : 'Video', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
        const SizedBox(height: 10),
        _dropdown(label: 'GPU', value: p['gpu'] as String, items: const ['CPU', 'NVIDIA', 'AMD', 'Intel'], cs: cs,
          onChanged: (v) {
            p['gpu'] = v;
            setState(() {}); widget.onChanged();
          }),
        const SizedBox(height: 12),
        _codecDropdown(cs, zh),
        if (p['gpu'] != 'CPU' && !_gpuAccelerated.contains(p['video_codec']) && p['video_codec'] != 'copy')
          Padding(padding: const EdgeInsets.only(top: 4), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: cs.errorContainer.withAlpha(80), borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              Icon(Icons.info_outline, size: 13, color: cs.error),
              const SizedBox(width: 4),
              Expanded(child: Text(
                zh ? '当前编码器不支持 ${p['gpu']} 加速，将使用 CPU 处理' : 'Codec not supported by ${p['gpu']}, will use CPU',
                style: TextStyle(fontSize: 11, color: cs.error),
              )),
            ]),
          )),
        const SizedBox(height: 12),
        _dropdown(label: zh ? '码率模式' : 'Rate Mode', value: p['rate_mode'] as String,
          items: const ['bitrate', 'crf', 'keep'],
          itemLabels: zh ? const ['码率', 'CRF', '保持'] : const ['Bitrate', 'CRF', 'Keep'], cs: cs,
          onChanged: (v) {
            p['rate_mode'] = v;
            if (v == 'bitrate') { p['video_bitrate'] ??= 2000; p.remove('crf'); _bitrateCtrl.text = '${p['video_bitrate']}'; }
            else if (v == 'crf') { p['crf'] ??= 23; p.remove('video_bitrate'); }
            else { p.remove('video_bitrate'); p.remove('crf'); }
            setState(() {}); widget.onChanged();
          }),
        const SizedBox(height: 12),
        if (p['rate_mode'] == 'bitrate')
          Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(
            controller: _bitrateCtrl, keyboardType: TextInputType.number, decoration: _dec(zh ? '码率 (kbps)' : 'Bitrate (kbps)'),
            onChanged: (v) { p['video_bitrate'] = int.tryParse(v); widget.onChanged(); },
          )),
        if (p['rate_mode'] == 'crf')
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CRF: ${p['crf'] ?? 23}', style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Slider(value: (p['crf'] as int? ?? 23).toDouble(), min: 0,
              max: _crfMaxForCodec(p['video_codec'] as String? ?? 'libx264').toDouble(),
              divisions: _crfMaxForCodec(p['video_codec'] as String? ?? 'libx264'),
              label: '${p['crf'] ?? 23}',
              onChanged: (v) => _update('crf', v.round())),
          ])),
        if (p['gpu'] == 'CPU') ...[
          _dropdown(label: 'Preset', value: p['preset'] as String? ?? 'medium', items: _presets, cs: cs,
            onChanged: (v) => _update('preset', v)),
          const SizedBox(height: 12),
        ],
        _dropdown(label: zh ? '像素格式' : 'Pixel Format', value: p['pix_fmt'] as String? ?? 'auto',
          items: _pixFmts,
          itemLabels: [zh ? '自动' : 'Auto', 'YUV 4:2:0 8bit', 'YUV 4:2:2 8bit', 'YUV 4:4:4 8bit', 'YUV 4:2:0 10bit', 'YUV 4:2:2 10bit', 'NV12', 'P010LE (10bit)', 'RGB 24bit'],
          cs: cs, onChanged: (v) => _update('pix_fmt', v)),
        const SizedBox(height: 12),
        _dropdown(label: zh ? '分辨率' : 'Resolution', value: p['resolution'] as String, items: _resolutions,
          itemLabels: zh ? const ['原始', '4K (2160p)', '1080p', '720p', '480p', '360p', '自定义'] : const ['Original', '4K (2160p)', '1080p', '720p', '480p', '360p', 'Custom'],
          cs: cs, onChanged: (v) => _update('resolution', v)),
        if (p['resolution'] == 'custom')
          Padding(padding: const EdgeInsets.only(top: 12), child: Row(children: [
            Expanded(child: TextField(controller: _resWCtrl, keyboardType: TextInputType.number, decoration: _dec('W'),
              onChanged: (v) { p['resolution_w'] = int.tryParse(v); widget.onChanged(); })),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('x', style: TextStyle(color: cs.onSurface))),
            Expanded(child: TextField(controller: _resHCtrl, keyboardType: TextInputType.number, decoration: _dec('H'),
              onChanged: (v) { p['resolution_h'] = int.tryParse(v); widget.onChanged(); })),
          ])),
        const SizedBox(height: 12),
        _dropdown(label: zh ? '帧率' : 'FPS', value: p['fps'] as String, items: _fpsOptions,
          itemLabels: zh ? const ['保持', '24', '25', '30', '48', '50', '60', '120', '自定义'] : const ['Keep', '24', '25', '30', '48', '50', '60', '120', 'Custom'],
          cs: cs, onChanged: (v) => _update('fps', v)),
        if (p['fps'] == 'custom')
          Padding(padding: const EdgeInsets.only(top: 12), child: TextField(
            controller: _fpsCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _dec(zh ? '自定义帧率' : 'Custom FPS'),
            onChanged: (v) { p['fps_value'] = double.tryParse(v); widget.onChanged(); })),

        const SizedBox(height: 8),
        const Divider(),
        const SizedBox(height: 8),
        Text(zh ? '音频' : 'Audio', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
        const SizedBox(height: 10),
        _dropdown(label: zh ? '音频编码' : 'Audio Codec', value: p['audio_codec'] as String? ?? 'aac', items: _audioCodecs,
          itemLabels: _audioCodecs.map((c) => _audioCodecLabelsFor(zh)[c] ?? c).toList(),
          cs: cs, onChanged: (v) => _update('audio_codec', v)),
        const SizedBox(height: 12),
        _dropdown(label: zh ? '音频码率 (kbps)' : 'Audio Bitrate (kbps)',
          value: '${p['audio_bitrate'] ?? ''}',
          items: ['', 'keep', ..._audioBitrates.map((b) => '$b'), 'custom'],
          itemLabels: [zh ? '不指定' : 'Default', zh ? '保持原样' : 'Keep Original', ..._audioBitrates.map((b) => '$b kbps'), zh ? '自定义' : 'Custom'],
          cs: cs, onChanged: (v) {
            if (v == 'keep') { _update('audio_bitrate', -1); }
            else if (v == 'custom') { _update('audio_bitrate', p['audio_bitrate_custom'] ?? 128); }
            else { _update('audio_bitrate', v.isEmpty ? null : int.tryParse(v)); }
          }),
        if (p['audio_bitrate'] != null && !_audioBitrates.contains(p['audio_bitrate']) && p['audio_bitrate'] != -1)
          Padding(padding: const EdgeInsets.only(top: 8), child: TextField(
            controller: TextEditingController(text: '${p['audio_bitrate']}'),
            keyboardType: TextInputType.number,
            decoration: _dec(zh ? '自定义码率 (kbps)' : 'Custom Bitrate (kbps)'),
            onChanged: (v) { final n = int.tryParse(v); if (n != null) { p['audio_bitrate'] = n; widget.onChanged(); } },
          )),
        const SizedBox(height: 12),
        _dropdown(label: zh ? '声道' : 'Channels', value: p['audio_channels'] as String? ?? 'keep', items: _channels,
          itemLabels: zh ? const ['保持', '单声道', '立体声', '5.1 环绕', '7.1 环绕'] : const ['Keep', 'Mono', 'Stereo', '5.1', '7.1'],
          cs: cs, onChanged: (v) => _update('audio_channels', v)),
      ]),
    );
  }
}
