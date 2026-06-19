import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

class CommandPage extends StatefulWidget {
  const CommandPage({super.key});
  @override
  State<CommandPage> createState() => _CommandPageState();
}

class _CommandPageState extends State<CommandPage> {
  final _ctrl = TextEditingController();
  bool _expanded = true;

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  void _execute() {
    final cmd = _ctrl.text.trim();
    if (cmd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入 FFmpeg 命令'), backgroundColor: Colors.orange));
      return;
    }

    // 解析命令中的输入输出文件
    String? inputPath;
    String? outputPath;
    final parts = cmd.split(' ');
    for (int i = 0; i < parts.length; i++) {
      if (parts[i] == '-i' && i + 1 < parts.length) {
        inputPath = parts[i + 1].replaceAll('"', '');
      }
    }
    // 最后一个非 - 开头的参数是输出文件
    for (int i = parts.length - 1; i >= 0; i--) {
      if (!parts[i].startsWith('-') && parts[i].isNotEmpty) {
        outputPath = parts[i].replaceAll('"', '');
        break;
      }
    }

    if (inputPath == null || outputPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法解析输入/输出文件路径，命令需包含 -i input output'), backgroundColor: Colors.red));
      return;
    }

    if (!File(inputPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('输入文件不存在: $inputPath'), backgroundColor: Colors.red));
      return;
    }

    // 添加到处理队列
    final state = context.read<AppState>();
    state.addCustomTask(
      inputPath: inputPath,
      outputPath: outputPath,
      command: cmd,
      filename: inputPath.split(RegExp(r'[\\/]')).last,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已添加到处理队列: ${inputPath.split(RegExp(r'[\\/]')).last}'), backgroundColor: Colors.green));

    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clr = scheme.onSurface;
    final s = AppStrings.of(context.watch<AppState>().config.language);

    return Scaffold(
      appBar: AppBar(title: Text(s.navCommand)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // ── 命令输入框 + 发送按钮 ──
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: TextField(controller: _ctrl, maxLines: 4,
            style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: clr),
            decoration: InputDecoration(
              hintText: 'ffmpeg -i input.mp4 -c:v libx264 -b:v 2000k output.mp4',
              hintStyle: TextStyle(color: scheme.outline, fontFamily: 'monospace'),
              border: const OutlineInputBorder(),
            ),
          )),
          const SizedBox(width: 8),
          FloatingActionButton(
            onPressed: _execute,
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            mini: true,
            child: const Icon(Icons.send),
          ),
        ]),
        const SizedBox(height: 16),

        // ── 命令参考 ──
        Card(
          child: ExpansionTile(
            title: Text(s.cmdRef, style: TextStyle(color: clr)),
            initiallyExpanded: _expanded,
            onExpansionChanged: (v) => _expanded = v,
            children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                _sec(scheme, s.cmdExamples, [
                  'ffmpeg -i {input} -c:v libx264 -b:v 2000k -c:a aac {output}',
                  'ffmpeg -i {input} -c:v h264_nvenc -b:v 5000k {output}',
                  'ffmpeg -i {input} -vf "subtitles=sub.srt" {output}',
                  'ffmpeg -i {input} -s 1280x720 -r 30 {output}',
                ]),
                _sec(scheme, s.cmdParams, [
                  '-i <file>        Input file',
                  '-c:v <codec>     Video codec (libx264, h264_nvenc...)',
                  '-b:v <rate>      Video bitrate (e.g. 2000k)',
                  '-s <WxH>         Resolution (e.g. 1920x1080)',
                  '-r <fps>         Framerate (e.g. 30)',
                  '-c:a <codec>     Audio codec (aac, mp3, copy)',
                  '-b:a <rate>      Audio bitrate (e.g. 128k)',
                  '-ac <n>          Channels (1/2/6)',
                  '-vf <filter>     Video filter (e.g. subtitles=...)',
                  '-preset <name>   Preset (ultrafast~veryslow)',
                  '-crf <n>         CRF quality (0-51)',
                  '-y               Overwrite output',
                ]),
                _sec(scheme, s.cmdPlaceholders, [s.cmdPlaceholderDesc]),
              ])),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _sec(ColorScheme sc, String title, List<String> lines) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sc.primary)),
      const SizedBox(height: 4),
      ...lines.map((l) => Padding(padding: const EdgeInsets.only(top: 2),
          child: Text(l, style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: sc.onSurface)))),
    ]),
  );
}
