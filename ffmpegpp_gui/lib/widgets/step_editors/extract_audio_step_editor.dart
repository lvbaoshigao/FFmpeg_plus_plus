import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

class ExtractAudioStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final String videoPath;
  final double videoDuration;
  final bool isZh;

  const ExtractAudioStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    required this.videoPath,
    required this.videoDuration,
    this.isZh = true,
  });

  @override
  State<ExtractAudioStepEditor> createState() => _ExtractAudioStepEditorState();
}

class _ExtractAudioStepEditorState extends State<ExtractAudioStepEditor> {
  Map<String, dynamic> get p => widget.params;

  static const _codecs = ['copy', 'aac', 'libmp3lame', 'libopus', 'libvorbis', 'flac', 'pcm_s16le'];
  static const _codecLabels = ['Copy (原始)', 'AAC', 'MP3 (LAME)', 'Opus', 'Vorbis', 'FLAC', 'PCM 16-bit'];
  static const _codecLabelsEn = ['Copy (original)', 'AAC', 'MP3 (LAME)', 'Opus', 'Vorbis', 'FLAC', 'PCM 16-bit'];
  static const _formats = ['m4a', 'mp3', 'ogg', 'flac', 'wav'];

  late TextEditingController _startCtrl;
  late TextEditingController _endCtrl;
  AudioPlayer? _player;
  bool _isPlaying = false;
  bool _isExtracting = false;
  StreamSubscription? _playerSub;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('extract_mode', () => 'full');
    p.putIfAbsent('audio_codec', () => 'copy');
    p.putIfAbsent('output_format', () => 'm4a');
    _migrateStringTimes();
    p.putIfAbsent('start_time', () => 0.0);
    p.putIfAbsent('end_time', () => widget.videoDuration);
    _startCtrl = TextEditingController(text: _formatTime(_startVal));
    _endCtrl = TextEditingController(text: _formatTime(_endVal));
  }

  void _migrateStringTimes() {
    if (p['start_time'] is String) {
      final s = p['start_time'] as String;
      p['start_time'] = s.isEmpty ? 0.0 : (_parseTime(s) ?? 0.0);
    }
    if (p['end_time'] is String) {
      final s = p['end_time'] as String;
      p['end_time'] = s.isEmpty ? widget.videoDuration : (_parseTime(s) ?? widget.videoDuration);
    }
  }

  double get _startVal => (p['start_time'] as num?)?.toDouble() ?? 0.0;
  double get _endVal => (p['end_time'] as num?)?.toDouble() ?? widget.videoDuration;

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    _playerSub?.cancel();
    _player?.dispose();
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

  double? _parseTime(String s) {
    try {
      final parts = s.split(':');
      if (parts.length != 3) return double.tryParse(s);
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final secParts = parts[2].split('.');
      final sec = int.parse(secParts[0]);
      final ms = secParts.length > 1 ? int.parse(secParts[1].padRight(3, '0').substring(0, 3)) : 0;
      return h * 3600.0 + m * 60.0 + sec + ms / 1000.0;
    } catch (_) {
      return double.tryParse(s);
    }
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  Future<void> _playPreview() async {
    if (_isExtracting) return;
    setState(() => _isExtracting = true);

    final start = _startVal;
    final end = _endVal;
    final hash = '${widget.videoPath.hashCode}_${(start * 10).round()}_${(end * 10).round()}';
    final tmpPath = '${Directory.systemTemp.path}${Platform.pathSeparator}ffmpegpp_audio_preview_$hash.m4a';

    try {
      if (!File(tmpPath).existsSync()) {
        final result = await Process.run('ffmpeg', [
          '-y', '-ss', start.toString(), '-to', end.toString(),
          '-i', widget.videoPath,
          '-vn', '-acodec', 'copy',
          tmpPath,
        ]);
        if (result.exitCode != 0 || !File(tmpPath).existsSync()) {
          if (mounted) setState(() => _isExtracting = false);
          return;
        }
      }

      _player?.dispose();
      final player = AudioPlayer();
      _player = player;
      await player.setFilePath(tmpPath);
      _playerSub?.cancel();
      _playerSub = player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          if (mounted) setState(() => _isPlaying = false);
        }
      });
      await player.play();
      if (mounted) setState(() { _isPlaying = true; _isExtracting = false; });
    } catch (_) {
      if (mounted) setState(() => _isExtracting = false);
    }
  }

  Future<void> _stopPreview() async {
    await _player?.stop();
    if (mounted) setState(() => _isPlaying = false);
  }

  InputDecoration _dec(String label) => InputDecoration(
    labelText: label, isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final mode = p['extract_mode'] as String? ?? 'full';
    final codec = p['audio_codec'] as String? ?? 'copy';
    final fmt = p['output_format'] as String? ?? 'm4a';
    final labels = zh ? _codecLabels : _codecLabelsEn;
    final dur = widget.videoDuration;
    final start = _startVal.clamp(0.0, dur);
    final end = _endVal.clamp(start, dur);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '从视频提取音频' : 'Extract Audio from Video',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'full', label: Text(zh ? '完整提取' : 'Full', style: const TextStyle(fontSize: 12))),
            ButtonSegment(value: 'clip', label: Text(zh ? '片段提取' : 'Clip', style: const TextStyle(fontSize: 12))),
          ],
          selected: {mode},
          onSelectionChanged: (v) {
            _update('extract_mode', v.first);
            if (v.first == 'full') _stopPreview();
          },
          style: ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 12),

        if (mode == 'clip') ...[
          Row(children: [
            Expanded(child: TextFormField(
              controller: _startCtrl,
              decoration: _dec(zh ? '开始时间' : 'Start Time'),
              style: TextStyle(fontSize: 13, color: cs.onSurface, fontFamily: 'monospace'),
              onChanged: (v) {
                final parsed = _parseTime(v);
                if (parsed == null) return;
                final t = parsed.clamp(0.0, dur);
                p['start_time'] = t;
                if (t > _endVal) {
                  p['end_time'] = t;
                  _endCtrl.text = _formatTime(t);
                }
                setState(() {});
                widget.onChanged();
              },
            )),
            const SizedBox(width: 12),
            Expanded(child: TextFormField(
              controller: _endCtrl,
              decoration: _dec(zh ? '结束时间' : 'End Time'),
              style: TextStyle(fontSize: 13, color: cs.onSurface, fontFamily: 'monospace'),
              onChanged: (v) {
                final parsed = _parseTime(v);
                if (parsed == null) return;
                final t = parsed.clamp(0.0, dur);
                p['end_time'] = t;
                if (t < _startVal) {
                  p['start_time'] = t;
                  _startCtrl.text = _formatTime(t);
                }
                setState(() {});
                widget.onChanged();
              },
            )),
          ]),
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
            },
          ),

          Row(children: [
            Text(
              '${zh ? "时长" : "Duration"}: ${_formatTime(end - start)}',
              style: TextStyle(fontSize: 13, color: cs.outline),
            ),
            const Spacer(),
            if (_isExtracting)
              SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary))
            else
              IconButton(
                icon: Icon(_isPlaying ? Icons.stop_circle : Icons.play_circle, size: 28, color: cs.primary),
                tooltip: _isPlaying ? (zh ? '停止' : 'Stop') : (zh ? '预览' : 'Preview'),
                onPressed: _isPlaying ? _stopPreview : _playPreview,
              ),
          ]),
          const SizedBox(height: 12),
        ],

        DropdownButtonFormField<String>(
          borderRadius: BorderRadius.circular(12),
          value: _formats.contains(fmt) ? fmt : _formats.first,
          isExpanded: true,
          decoration: _dec(zh ? '输出格式' : 'Output Format'),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: _formats.map((f) => DropdownMenuItem(
            value: f, child: Text(f.toUpperCase(), style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )).toList(),
          onChanged: (v) { if (v != null) _update('output_format', v); },
        ),
        const SizedBox(height: 12),

        DropdownButtonFormField<String>(
          borderRadius: BorderRadius.circular(12),
          value: _codecs.contains(codec) ? codec : _codecs.first,
          isExpanded: true,
          decoration: _dec(zh ? '编码器' : 'Codec'),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: List.generate(_codecs.length, (i) => DropdownMenuItem(
            value: _codecs[i],
            child: Text(labels[i], style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )),
          onChanged: (v) { if (v != null) _update('audio_codec', v); },
        ),
        const SizedBox(height: 16),

        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withAlpha(60),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 14, color: cs.outline),
            const SizedBox(width: 8),
            Expanded(child: Text(
              zh ? '选择 Copy 编码器可无损提取原始音频流。\n选择其他编码器将重新编码音频。'
                 : 'Select "Copy" codec to extract original audio losslessly.\nOther codecs will re-encode the audio.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ])),
    );
  }
}
