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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clr = scheme.onSurface;
    final s = AppStrings.of(context.watch<AppState>().config.language);

    return Scaffold(
      appBar: AppBar(title: Text(s.navCommand)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _ctrl, maxLines: 4,
          style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: clr),
          decoration: InputDecoration(
            hintText: 'ffmpeg -i input.mp4 -c:v libx264 -b:v 2000k output.mp4',
            hintStyle: TextStyle(color: scheme.outline, fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 16),
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
