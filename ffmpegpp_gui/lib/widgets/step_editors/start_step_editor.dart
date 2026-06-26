import 'package:flutter/material.dart';

class StartStepEditor extends StatelessWidget {
  final String filename;
  final String resolution;
  final String durationStr;
  final double sizeMb;
  final String codec;
  final String pixFmt;
  final String audioCodec;
  final int audioChannels;
  final bool isZh;

  const StartStepEditor({
    super.key,
    required this.filename,
    this.resolution = '',
    this.durationStr = '',
    this.sizeMb = 0,
    this.codec = '',
    this.pixFmt = '',
    this.audioCodec = '',
    this.audioChannels = 0,
    this.isZh = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.play_circle_outline, size: 36, color: scheme.primary),
        const SizedBox(height: 12),
        Text(
          isZh ? '源文件信息' : 'Source File Info',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface),
        ),
        const SizedBox(height: 16),
        _row(isZh ? '文件名' : 'Filename', filename, scheme),
        _row(isZh ? '分辨率' : 'Resolution', resolution, scheme),
        _row(isZh ? '时长' : 'Duration', durationStr, scheme),
        _row(isZh ? '大小' : 'Size', '${sizeMb.toStringAsFixed(1)} MB', scheme),
        _row(isZh ? '视频编码' : 'Video Codec', codec, scheme),
        _row(isZh ? '像素格式' : 'Pixel Format', pixFmt, scheme),
        _row(isZh ? '音频编码' : 'Audio Codec', audioCodec, scheme),
        _row(isZh ? '音频声道' : 'Audio Channels', '$audioChannels', scheme),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withAlpha(40),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            isZh ? '这是处理流程的起点，下方添加处理步骤来编辑视频' : 'This is the starting point. Add processing steps below.',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
        ),
      ]),
    );
  }

  Widget _row(String label, String value, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(
          width: 80,
          child: Text(label, style: TextStyle(fontSize: 12, color: scheme.outline)),
        ),
        Expanded(
          child: Text(value, style: TextStyle(fontSize: 13, color: scheme.onSurface, fontFamily: 'monospace')),
        ),
      ]),
    );
  }
}
