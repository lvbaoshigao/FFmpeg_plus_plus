import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../services/frame_preview.dart';

class ClipStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final String videoPath;
  final double videoDuration;
  final bool isZh;

  const ClipStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    required this.videoPath,
    required this.videoDuration,
    this.isZh = true,
  });

  @override
  State<ClipStepEditor> createState() => _ClipStepEditorState();
}

class _ClipStepEditorState extends State<ClipStepEditor> {
  late TextEditingController _startCtrl;
  late TextEditingController _endCtrl;
  String? _previewPath;
  Timer? _debounceTimer;

  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('start_time', () => 0.0);
    p.putIfAbsent('end_time', () => widget.videoDuration);
    _startCtrl = TextEditingController(text: _formatTime(p['start_time'] as double));
    _endCtrl = TextEditingController(text: _formatTime(p['end_time'] as double));
    _generatePreview();
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  String _formatTime(double s) {
    final totalMs = (s * 1000).round();
    final h = totalMs ~/ 3600000;
    final m = (totalMs % 3600000) ~/ 60000;
    final sec = (totalMs % 60000) ~/ 1000;
    final ms = totalMs % 1000;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${sec.toString().padLeft(2, '0')}.'
        '${ms.toString().padLeft(3, '0')}';
  }

  double _parseTime(String s) {
    try {
      final parts = s.split(':');
      if (parts.length != 3) return 0;
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final secParts = parts[2].split('.');
      final sec = int.parse(secParts[0]);
      final ms = secParts.length > 1 ? int.parse(secParts[1].padRight(3, '0').substring(0, 3)) : 0;
      return h * 3600.0 + m * 60.0 + sec + ms / 1000.0;
    } catch (_) {
      return 0;
    }
  }

  void _debouncedPreview() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), _generatePreview);
  }

  Future<void> _generatePreview() async {
    final path = await FramePreview.generatePreview(
      widget.videoPath,
      p['start_time'] as double,
      width: 480,
    );
    if (mounted) {
      setState(() => _previewPath = path);
    }
  }

  InputDecoration _inputDecoration(String label) => InputDecoration(
        labelText: label,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final zh = widget.isZh;
    final dur = widget.videoDuration;
    final start = (p['start_time'] as double).clamp(0.0, dur);
    final end = (p['end_time'] as double).clamp(start, dur);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 320,
                height: 180,
                color: Colors.black,
                child: _previewPath != null && File(_previewPath!).existsSync()
                    ? Image.file(
                        File(_previewPath!),
                        fit: BoxFit.contain,
                        width: 320,
                        height: 180,
                      )
                    : Center(
                        child: Icon(Icons.image, size: 48, color: cs.outline),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _startCtrl,
                    decoration: _inputDecoration(zh ? '开始时间' : 'Start Time'),
                    style: TextStyle(fontSize: 13, color: cs.onSurface, fontFamily: 'monospace'),
                    onChanged: (v) {
                      final t = _parseTime(v).clamp(0.0, dur);
                      p['start_time'] = t;
                      if (t > (p['end_time'] as double)) {
                        p['end_time'] = t;
                        _endCtrl.text = _formatTime(t);
                      }
                      setState(() {});
                      widget.onChanged();
                      _debouncedPreview();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _endCtrl,
                    decoration: _inputDecoration(zh ? '结束时间' : 'End Time'),
                    style: TextStyle(fontSize: 13, color: cs.onSurface, fontFamily: 'monospace'),
                    onChanged: (v) {
                      final t = _parseTime(v).clamp(0.0, dur);
                      p['end_time'] = t;
                      if (t < (p['start_time'] as double)) {
                        p['start_time'] = t;
                        _startCtrl.text = _formatTime(t);
                      }
                      setState(() {});
                      widget.onChanged();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            RangeSlider(
              values: RangeValues(start, end),
              min: 0,
              max: dur > 0 ? dur : 1,
              labels: RangeLabels(_formatTime(start), _formatTime(end)),
              onChanged: (v) {
                p['start_time'] = v.start;
                p['end_time'] = v.end;
                _startCtrl.text = _formatTime(v.start);
                _endCtrl.text = _formatTime(v.end);
                setState(() {});
                widget.onChanged();
                _debouncedPreview();
              },
            ),
            const SizedBox(height: 8),
            Text(
              '${zh ? "时长" : "Duration"}: ${_formatTime(end - start)}',
              style: TextStyle(fontSize: 13, color: cs.outline),
            ),
          ],
        ),
      ),
    );
  }
}
