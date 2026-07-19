import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../services/frame_preview.dart';

class FrameStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final String videoPath;
  final double videoDuration;
  final bool isZh;

  const FrameStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    required this.videoPath,
    required this.videoDuration,
    this.isZh = true,
  });

  @override
  State<FrameStepEditor> createState() => _FrameStepEditorState();
}

class _FrameStepEditorState extends State<FrameStepEditor> {
  late TextEditingController _timeCtrl, _startCtrl, _endCtrl, _fpsCtrl;
  String? _previewPath;
  Timer? _debounceTimer;
  bool _loading = false;

  static const _formats = ['png', 'jpg', 'bmp'];

  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('time', () => 0.0);
    p.putIfAbsent('output_format', () => 'png');
    p.putIfAbsent('extract_mode', () => 'single');
    p.putIfAbsent('range_start', () => 0.0);
    p.putIfAbsent('range_end', () => widget.videoDuration);
    p.putIfAbsent('fps_rate', () => 1.0);
    _timeCtrl = TextEditingController(text: _fmt((p['time'] as num?)?.toDouble() ?? 0.0));
    _startCtrl = TextEditingController(text: _fmt((p['range_start'] as num?)?.toDouble() ?? 0.0));
    _endCtrl = TextEditingController(text: _fmt((p['range_end'] as num?)?.toDouble() ?? widget.videoDuration));
    _fpsCtrl = TextEditingController(text: '${(p['fps_rate'] as num?)?.toDouble() ?? 1.0}');
    _generatePreview();
  }

  @override
  void dispose() {
    _timeCtrl.dispose(); _startCtrl.dispose(); _endCtrl.dispose(); _fpsCtrl.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  String _fmt(double s) {
    final ms = (s * 1000).round();
    return '${(ms ~/ 3600000).toString().padLeft(2, '0')}:'
        '${((ms % 3600000) ~/ 60000).toString().padLeft(2, '0')}:'
        '${((ms % 60000) ~/ 1000).toString().padLeft(2, '0')}.'
        '${(ms % 1000).toString().padLeft(3, '0')}';
  }

  double _parse(String s) {
    try {
      final parts = s.split(':');
      if (parts.length != 3) return 0;
      final secParts = parts[2].split('.');
      return int.parse(parts[0]) * 3600.0 + int.parse(parts[1]) * 60.0 +
          int.parse(secParts[0]) + (secParts.length > 1 ? int.parse(secParts[1].padRight(3, '0').substring(0, 3)) / 1000.0 : 0);
    } catch (_) { return 0; }
  }

  void _debounced() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), _generatePreview);
  }

  Future<void> _generatePreview() async {
    setState(() => _loading = true);
    final t = p['extract_mode'] == 'single' ? (p['time'] as num?)?.toDouble() ?? 0.0 : (p['range_start'] as num?)?.toDouble() ?? 0.0;
    final path = await FramePreview.generatePreview(widget.videoPath, t, width: 640);
    if (mounted) setState(() { _previewPath = path; _loading = false; });
  }

  void _updateTime(double t) {
    final c = t.clamp(0.0, widget.videoDuration);
    p['time'] = c;
    _timeCtrl.text = _fmt(c);
    setState(() {}); widget.onChanged(); _debounced();
  }


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final dur = widget.videoDuration;
    final mode = p['extract_mode'] as String? ?? 'single';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '提取模式' : 'Mode', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'single', label: Text(zh ? '单帧' : 'Single', style: const TextStyle(fontSize: 12)), icon: const Icon(Icons.photo_camera, size: 14)),
            ButtonSegment(value: 'range', label: Text(zh ? '范围' : 'Range', style: const TextStyle(fontSize: 12)), icon: const Icon(Icons.burst_mode, size: 14)),
            ButtonSegment(value: 'all', label: Text(zh ? '全部' : 'All', style: const TextStyle(fontSize: 12)), icon: const Icon(Icons.video_library, size: 14)),
          ],
          selected: {mode},
          onSelectionChanged: (v) {
            setState(() => p['extract_mode'] = v.first);
            widget.onChanged();
            _generatePreview();
          },
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 12),

        // 预览
        Center(child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 270),
            color: Colors.black,
            child: Stack(alignment: Alignment.center, children: [
              if (_previewPath != null && File(_previewPath!).existsSync())
                Image.file(File(_previewPath!), fit: BoxFit.contain, width: 480, height: 270, gaplessPlayback: true),
              if (_previewPath == null && !_loading)
                Icon(Icons.photo_camera_outlined, size: 48, color: cs.outline.withAlpha(100)),
              if (_loading)
                SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
            ]),
          ),
        )),
        const SizedBox(height: 12),

        if (mode == 'single') ..._buildSingleMode(cs, zh, dur),
        if (mode == 'range') ..._buildRangeMode(cs, zh, dur),
        if (mode == 'all') ..._buildAllMode(cs, zh, dur),

        const SizedBox(height: 12),
        Row(children: [
          SizedBox(width: 120, child: DropdownButtonFormField<String>(
            borderRadius: BorderRadius.circular(12),
            value: p['output_format'] as String? ?? 'png', isExpanded: true,
            decoration: InputDecoration(labelText: zh ? '格式' : 'Format'),
            dropdownColor: cs.surface, style: TextStyle(fontSize: 13, color: cs.onSurface),
            items: _formats.map((f) => DropdownMenuItem(value: f, child: Text(f.toUpperCase(), style: TextStyle(fontSize: 13, color: cs.onSurface)))).toList(),
            onChanged: (v) { if (v != null) { setState(() => p['output_format'] = v); widget.onChanged(); } },
          )),
          const SizedBox(width: 12),
          if (mode != 'single')
            Expanded(child: Text(
              zh ? '多帧提取将创建文件夹存放结果' : 'Multi-frame: results saved to a folder',
              style: TextStyle(fontSize: 11, color: cs.outline),
            )),
        ]),
      ]),
    );
  }

  List<Widget> _buildSingleMode(ColorScheme cs, bool zh, double dur) {
    final time = ((p['time'] as num?)?.toDouble() ?? 0.0).clamp(0.0, dur);
    return [
      SliderTheme(
        data: SliderTheme.of(context).copyWith(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
        child: Slider(value: time, min: 0, max: dur > 0 ? dur : 1, onChanged: _updateTime),
      ),
      Row(children: [
        Expanded(child: TextFormField(controller: _timeCtrl,
          decoration: InputDecoration(labelText: zh ? '提取时间' : 'Time').copyWith(prefixIcon: const Icon(Icons.access_time, size: 18)),
          style: TextStyle(fontSize: 13, color: cs.onSurface, fontFamily: 'monospace'),
          onChanged: (v) => _updateTime(_parse(v)),
        )),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        FilledButton.tonalIcon(onPressed: () => _updateTime((time - 1 / 30).clamp(0, dur)),
          icon: const Icon(Icons.skip_previous, size: 16), label: Text(zh ? '上一帧' : 'Prev', style: const TextStyle(fontSize: 12))),
        const SizedBox(width: 8),
        FilledButton.tonalIcon(onPressed: () => _updateTime((time + 1 / 30).clamp(0, dur)),
          icon: const Icon(Icons.skip_next, size: 16), label: Text(zh ? '下一帧' : 'Next', style: const TextStyle(fontSize: 12))),
        const SizedBox(width: 8),
        FilledButton.tonalIcon(onPressed: _generatePreview,
          icon: const Icon(Icons.refresh, size: 16), label: Text(zh ? '刷新' : 'Refresh', style: const TextStyle(fontSize: 12))),
      ]),
    ];
  }

  List<Widget> _buildRangeMode(ColorScheme cs, bool zh, double dur) {
    final rs = ((p['range_start'] as num?)?.toDouble() ?? 0.0).clamp(0.0, dur);
    final re = ((p['range_end'] as num?)?.toDouble() ?? dur).clamp(0.0, dur);
    final fpsRate = (p['fps_rate'] as num?)?.toDouble() ?? 1.0;
    final frameCount = re > rs ? ((re - rs) * fpsRate).ceil() : 0;
    return [
      RangeSlider(
        values: RangeValues(rs, re), min: 0, max: dur > 0 ? dur : 1,
        onChanged: (v) {
          setState(() { p['range_start'] = v.start; p['range_end'] = v.end;
            _startCtrl.text = _fmt(v.start); _endCtrl.text = _fmt(v.end); });
          widget.onChanged(); _debounced();
        },
      ),
      Row(children: [
        Expanded(child: TextFormField(controller: _startCtrl,
          decoration: InputDecoration(labelText: zh ? '起始' : 'Start'),
          style: TextStyle(fontSize: 13, color: cs.onSurface, fontFamily: 'monospace'),
          onChanged: (v) { p['range_start'] = _parse(v).clamp(0, dur); widget.onChanged(); _debounced(); },
        )),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('→', style: TextStyle(color: cs.outline))),
        Expanded(child: TextFormField(controller: _endCtrl,
          decoration: InputDecoration(labelText: zh ? '结束' : 'End'),
          style: TextStyle(fontSize: 13, color: cs.onSurface, fontFamily: 'monospace'),
          onChanged: (v) { p['range_end'] = _parse(v).clamp(0, dur); widget.onChanged(); },
        )),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Text(zh ? '提取帧率: ' : 'FPS: ', style: TextStyle(fontSize: 13, color: cs.onSurface)),
        SizedBox(width: 80, child: TextFormField(
          controller: _fpsCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'fps'), style: TextStyle(fontSize: 13, color: cs.onSurface),
          onChanged: (v) { p['fps_rate'] = double.tryParse(v) ?? 1.0; setState(() {}); widget.onChanged(); },
        )),
        const SizedBox(width: 12),
        Text(zh ? '≈ $frameCount 帧' : '≈ $frameCount frames', style: TextStyle(fontSize: 12, color: cs.outline)),
      ]),
    ];
  }

  List<Widget> _buildAllMode(ColorScheme cs, bool zh, double dur) {
    final fpsRate = (p['fps_rate'] as num?)?.toDouble() ?? 1.0;
    final totalFrames = (dur * fpsRate).ceil();
    return [
      Row(children: [
        Text(zh ? '提取帧率: ' : 'FPS: ', style: TextStyle(fontSize: 13, color: cs.onSurface)),
        SizedBox(width: 80, child: TextFormField(
          controller: _fpsCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'fps'), style: TextStyle(fontSize: 13, color: cs.onSurface),
          onChanged: (v) { p['fps_rate'] = double.tryParse(v) ?? 1.0; setState(() {}); widget.onChanged(); },
        )),
        const SizedBox(width: 12),
        Text(zh ? '≈ $totalFrames 帧 (${dur.toStringAsFixed(1)}s)' : '≈ $totalFrames frames (${dur.toStringAsFixed(1)}s)',
          style: TextStyle(fontSize: 12, color: cs.outline)),
      ]),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: cs.tertiaryContainer.withAlpha(60), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Icon(Icons.info_outline, size: 14, color: cs.tertiary),
          const SizedBox(width: 6),
          Expanded(child: Text(
            zh ? '将提取视频全部帧并保存到以视频名命名的文件夹中' : 'All frames will be saved to a folder named after the video',
            style: TextStyle(fontSize: 11, color: cs.onSurface),
          )),
        ]),
      ),
    ];
  }
}
