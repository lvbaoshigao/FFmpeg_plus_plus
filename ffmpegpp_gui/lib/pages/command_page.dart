import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/toast.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_top_bar.dart';
import '../platform/app_platform.dart';

class CommandPage extends StatefulWidget {
  const CommandPage({super.key});
  @override
  State<CommandPage> createState() => _CommandPageState();
}

class _CommandPageState extends State<CommandPage> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _outputCtrl = ScrollController();

  final List<_OutputEntry> _outputEntries = [];
  bool _isRunning = false;

  static const _completions = [
    '-i ', '-y ', '-c:v ', '-c:a ', '-b:v ', '-b:a ', '-crf ', '-preset ', '-s ', '-r ',
    '-ss ', '-to ', '-t ', '-vn ', '-an ', '-vf ', '-ac ', '-ar ',
    'libx264', 'libx265', 'h264_nvenc', 'hevc_nvenc', 'copy', 'aac', 'libmp3lame',
    'ultrafast', 'veryfast', 'fast', 'medium', 'slow', 'veryslow',
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }


  bool _handleTab(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.tab) return false;
    final text = _ctrl.text;
    final sel = _ctrl.selection;
    if (!sel.isValid) return false;
    final before = text.substring(0, sel.start);
    final lastSpace = before.lastIndexOf(' ');
    final currentWord = before.substring(lastSpace + 1);
    if (currentWord.isEmpty) return false;
    final match = _completions.where((c) => c.startsWith(currentWord)).toList();
    if (match.isEmpty) return false;
    final completion = match.first;
    final newText = text.substring(0, lastSpace + 1) + completion + text.substring(sel.end);
    setState(() {
      _ctrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: lastSpace + 1 + completion.length),
      );
    });
    return true;
  }

  static List<String> _splitCommand(String cmd) {
    final tokens = <String>[];
    final current = StringBuffer();
    bool inQuote = false;
    String quoteChar = '';
    for (var i = 0; i < cmd.length; i++) {
      final c = cmd[i];
      if (inQuote) {
        if (c == quoteChar) {
          inQuote = false;
        } else {
          current.write(c);
        }
      } else if (c == '"' || c == "'") {
        inQuote = true;
        quoteChar = c;
      } else if (c == ' ' || c == '\t') {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current.clear();
        }
      } else {
        current.write(c);
      }
    }
    if (current.isNotEmpty) tokens.add(current.toString());
    return tokens;
  }


  /// 桌面端执行：解析命令参数，添加到处理队列。
  void _execute() {
    final cmd = _ctrl.text.trim();
    if (cmd.isEmpty) {
      showToast(context, '请输入 FFmpeg 命令', type: ToastType.warning);
      return;
    }

    String? inputPath;
    String? outputPath;
    final parts = _splitCommand(cmd);
    for (int i = 0; i < parts.length; i++) {
      if (parts[i] == '-i' && i + 1 < parts.length) {
        inputPath = parts[i + 1];
      }
    }
    const valueFlags = {
      '-i', '-c', '-c:v', '-c:a', '-c:s', '-codec', '-codec:v', '-codec:a', '-codec:s',
      '-vcodec', '-acodec', '-scodec', '-t', '-to', '-ss', '-fs', '-frames:v', '-frames:a',
      '-vframes', '-aframes', '-b', '-b:v', '-b:a', '-crf', '-r', '-s', '-vf', '-af',
      '-filter', '-filter:v', '-filter:a', '-f', '-format', '-map', '-map:v', '-map:a',
      '-preset', '-tune', '-profile', '-profile:v', '-level', '-pix_fmt', '-ar', '-ac',
      '-ab', '-g', '-q', '-q:v', '-q:a', '-bufsize', '-maxrate', '-minrate', '-movflags',
      '-tag:v', '-metadata', '-aspect', '-threads', '-cpu-used', '-deadline',
    };
    for (int i = parts.length - 1; i >= 0; i--) {
      final tok = parts[i];
      if (tok.isEmpty || tok.startsWith('-')) continue;
      if (i > 0 && valueFlags.contains(parts[i - 1])) continue;
      outputPath = tok;
      break;
    }

    if (inputPath == null || outputPath == null) {
      showToast(context, '无法解析输入/输出文件路径，命令需包含 -i input output', type: ToastType.error);
      return;
    }

    if (!File(inputPath).existsSync()) {
      showToast(context, '输入文件不存在: $inputPath', type: ToastType.error);
      return;
    }

    final state = context.read<AppState>();
    state.addCustomTask(inputPath: inputPath, outputPath: outputPath, command: cmd,
        filename: inputPath.split(RegExp(r'[\/]')).last);
    showToast(context, '已添加到处理队列: ${inputPath.split(RegExp(r'[\/]')).last}', type: ToastType.success);
    _ctrl.clear();
  }


  /// 移动端执行：通过 Process.run 直接执行命令，结果显示在输出区。
  Future<void> _executeMobile() async {
    final cmd = _ctrl.text.trim();
    if (cmd.isEmpty) {
      final s = AppStrings.of(context.read<AppState>().config.language);
      showToast(context, s.cmdInputHint, type: ToastType.warning);
      return;
    }
    if (_isRunning) return;
    setState(() => _isRunning = true);

    _appendOutput('\$ $cmd', isError: false, isCommand: true);

    try {
      final parts = _splitCommand(cmd);
      if (parts.isEmpty) {
        _appendOutput('Empty command', isError: true);
        return;
      }
      final exe = parts[0];
      final args = parts.sublist(1);

      final result = await Process.run(exe, args);

      final stdout = result.stdout.toString();
      final stderr = result.stderr.toString();

      if (stdout.isNotEmpty) {
        for (final line in stdout.split('\n')) {
          if (line.isNotEmpty) _appendOutput(line, isError: false);
        }
      }
      if (stderr.isNotEmpty) {
        for (final line in stderr.split('\n')) {
          if (line.isNotEmpty) _appendOutput(line, isError: true);
        }
      }

      final exitCode = result.exitCode;
      _appendOutput('[exit: $exitCode]', isError: exitCode != 0);
    } catch (e) {
      _appendOutput('Error: $e', isError: true);
    } finally {
      setState(() => _isRunning = false);
      if (_outputCtrl.hasClients) {
        _outputCtrl.jumpTo(_outputCtrl.position.maxScrollExtent);
      }
    }
  }

  void _appendOutput(String text, {required bool isError, bool isCommand = false}) {
    setState(() {
      _outputEntries.add(_OutputEntry(text: text, isError: isError, isCommand: isCommand));
    });
  }

  void _clearOutput() {
    setState(() => _outputEntries.clear());
  }

  void _insertTemplate(String tpl) {
    _ctrl.text = tpl;
    _ctrl.selection = TextSelection.fromPosition(TextPosition(offset: tpl.length));
  }


  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = context.watch<AppState>().config;
    final s = AppStrings.of(cfg.language);
    final zh = s.isZh;

    if (isMobilePlatform) {
      return _buildMobile(context, scheme, s, zh);
    }
    return _buildDesktop(context, scheme, s, zh);
  }

  Widget _buildMobile(BuildContext context, ColorScheme scheme, AppStrings s, bool zh) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(children: [
        MobileSubPageTopBar(
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.terminal_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text(s.navCommand),
          ]),
          actions: [
            IconButton(
              icon: Icon(Icons.delete_outline, size: 20, color: scheme.onSurface),
              tooltip: s.cmdClearOutput,
              onPressed: _clearOutput,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ],
          onBack: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(children: [
              _buildMobileInputArea(scheme, s, zh),
              const SizedBox(height: 10),
              Expanded(child: _buildMobileOutputArea(scheme, s, zh)),
            ]),
          ),
        ),
        SizedBox(height: kMobileNavClearance),
      ]),
    );
  }


  Widget _buildMobileInputArea(ColorScheme scheme, AppStrings s, bool zh) {
    return GlassPanel(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.edit_note, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(s.cmdInput,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
        ]),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withAlpha(120),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
          ),
          child: Focus(
            focusNode: _focus,
            onKeyEvent: (node, event) => _handleTab(event) ? KeyEventResult.handled : KeyEventResult.ignored,
            child: TextField(
              controller: _ctrl,
              maxLines: 3,
              minLines: 1,
              style: TextStyle(fontFamily: AppTheme.monoFont, fontSize: 13, color: scheme.onSurface, height: 1.5),
              onSubmitted: (_) => _executeMobile(),
              decoration: InputDecoration(
                hintText: 'ffmpeg -i input.mp4 -c:v libx264 output.mp4',
                hintStyle: TextStyle(color: scheme.outline.withAlpha(100), fontFamily: AppTheme.monoFont, fontSize: 13),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: _MobileActionButton(
              icon: _isRunning ? Icons.hourglass_empty : Icons.play_arrow,
              label: _isRunning ? '...' : s.cmdExecute,
              color: scheme.primary,
              onTap: _isRunning ? null : _executeMobile,
            ),
          ),
          const SizedBox(width: 8),
          _MobileActionButton(
            icon: Icons.close,
            label: s.cmdClear,
            color: scheme.outline,
            onTap: () => setState(() => _ctrl.clear()),
            compact: true,
          ),
        ]),
      ]),
    );
  }


  Widget _buildMobileOutputArea(ColorScheme scheme, AppStrings s, bool zh) {
    return GlassPanel(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.output, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(s.cmdOutput,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const Spacer(),
          Text('${_outputEntries.length}',
              style: TextStyle(fontSize: 11, color: scheme.outline)),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: _outputEntries.isEmpty
              ? Center(
                  child: Text(s.cmdNoOutput,
                      style: TextStyle(fontSize: 12, color: scheme.outline)),
                )
              : ListView.builder(
                  controller: _outputCtrl,
                  padding: EdgeInsets.zero,
                  itemCount: _outputEntries.length,
                  itemBuilder: (_, i) {
                    final entry = _outputEntries[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 28,
                            padding: const EdgeInsets.only(right: 4, top: 2),
                            child: Text('${i + 1}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                    fontSize: 9,
                                    fontFamily: AppTheme.monoFont,
                                    color: scheme.outline.withAlpha(120))),
                          ),
                          Expanded(
                            child: SelectableText(
                              entry.text,
                              style: TextStyle(
                                fontSize: 12,
                                fontFamily: AppTheme.monoFont,
                                height: 1.5,
                                color: entry.isCommand
                                    ? scheme.primary
                                    : (entry.isError ? scheme.error : scheme.onSurface),
                                fontWeight: entry.isCommand ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }


  Widget _buildDesktop(BuildContext context, ColorScheme scheme, AppStrings s, bool zh) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(children: [
        GlassTopBar(
          title: Row(children: [
            Icon(Icons.terminal_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text(s.navCommand),
          ]),
        ),
        Expanded(child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _wrapCard(scheme, Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.edit_note, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(zh ? '命令输入' : 'Command Input',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                ]),
                const SizedBox(height: 10),
                Container(
                  constraints: const BoxConstraints(maxWidth: 620),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withAlpha(120),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
                  ),
                  child: Focus(
                    focusNode: _focus,
                    onKeyEvent: (node, event) => _handleTab(event) ? KeyEventResult.handled : KeyEventResult.ignored,
                    child: TextField(
                      controller: _ctrl,
                      maxLines: 1,
                      style: TextStyle(fontFamily: AppTheme.monoFont, fontSize: 13, color: scheme.onSurface, height: 1.5),
                      onSubmitted: (_) => _execute(),
                      decoration: InputDecoration(
                        hintText: 'ffmpeg -i input.mp4 -c:v libx264 -b:v 2000k output.mp4',
                        hintStyle: TextStyle(color: scheme.outline.withAlpha(100), fontFamily: AppTheme.monoFont, fontSize: 13),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_ctrl.text.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.close, size: 15),
                                tooltip: zh ? '清除' : 'Clear',
                                onPressed: () => _ctrl.clear(),
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                padding: EdgeInsets.zero,
                              ),
                            const SizedBox(width: 2),
                            Tooltip(
                              message: s.cmdExecute,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: _execute,
                                child: Container(
                                  width: 26, height: 26,
                                  decoration: BoxDecoration(
                                    color: scheme.primary,
                                    shape: BoxShape.circle,
                                    boxShadow: [BoxShadow(color: scheme.primary.withAlpha(80), blurRadius: 6, offset: const Offset(0, 1))],
                                  ),
                                  child: const Icon(Icons.play_arrow, size: 16, color: Colors.white),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            )),
            const SizedBox(height: 12),
            Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _wrapCard(scheme, Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.bolt, size: 15, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text(zh ? '快捷模板' : 'Templates',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
                  ]),
                  const SizedBox(height: 10),
                  Expanded(child: ListView(children: [
                    _templateItem(scheme, zh ? 'H.264 转码' : 'H.264 Transcode', 'ffmpeg -i {input} -c:v libx264 -b:v 2000k -c:a aac {output}', zh),
                    _templateItem(scheme, zh ? 'GPU 加速' : 'GPU Accelerated', 'ffmpeg -i {input} -c:v h264_nvenc -b:v 5000k -c:a copy {output}', zh),
                    _templateItem(scheme, zh ? '烧录字幕' : 'Burn Subtitles', 'ffmpeg -i {input} -vf "subtitles=sub.srt" -c:a copy {output}', zh),
                    _templateItem(scheme, zh ? '缩放分辨率' : 'Scale Resolution', 'ffmpeg -i {input} -s 1280x720 -c:a copy {output}', zh),
                    _templateItem(scheme, zh ? '提取音频' : 'Extract Audio', 'ffmpeg -i {input} -vn -c:a copy {output}.aac', zh),
                    _templateItem(scheme, zh ? '转 GIF' : 'Convert to GIF', 'ffmpeg -i {input} -vf "fps=10,scale=320:-1" {output}.gif', zh),
                    _templateItem(scheme, zh ? '截取片段' : 'Trim Clip', 'ffmpeg -ss 00:00:30 -i {input} -to 00:01:00 -c copy {output}', zh),
                    _templateItem(scheme, zh ? '合并视频' : 'Concat Videos', 'ffmpeg -f concat -safe 0 -i list.txt -c copy {output}', zh),
                    _templateItem(scheme, zh ? 'CRF 质量' : 'CRF Quality', 'ffmpeg -i {input} -c:v libx264 -crf 23 -c:a aac {output}', zh),
                  ])),
                ]),
              ))),
              const SizedBox(width: 12),
              Expanded(child: _wrapCard(scheme, Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.menu_book, size: 15, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text(zh ? '参数参考' : 'Reference',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
                  ]),
                  const SizedBox(height: 10),
                  Expanded(child: ListView(children: [
                    _refGroup(scheme, zh ? '输入输出' : 'I/O', [
                      ('-i <file>', zh ? '输入文件' : 'Input file'),
                      ('-y', zh ? '覆盖输出' : 'Overwrite output'),
                    ]),
                    _refGroup(scheme, zh ? '视频编码' : 'Video', [
                      ('-c:v <codec>', 'libx264 / h264_nvenc / hevc_nvenc / copy'),
                      ('-b:v <rate>', zh ? '视频码率 (如 2000k)' : 'Bitrate (e.g. 2000k)'),
                      ('-crf <n>', zh ? 'CRF 质量 (0-51, 越小越好)' : 'Quality (0-51, lower=better)'),
                      ('-preset <p>', 'ultrafast / fast / medium / slow / veryslow'),
                      ('-s <WxH>', zh ? '分辨率 (如 1920x1080)' : 'Resolution (e.g. 1920x1080)'),
                      ('-r <fps>', zh ? '帧率 (如 30)' : 'Framerate (e.g. 30)'),
                    ]),
                    _refGroup(scheme, zh ? '音频编码' : 'Audio', [
                      ('-c:a <codec>', 'aac / libmp3lame / libopus / copy'),
                      ('-b:a <rate>', zh ? '音频码率 (如 128k)' : 'Bitrate (e.g. 128k)'),
                      ('-ac <n>', zh ? '声道数 (1/2/6)' : 'Channels (1/2/6)'),
                      ('-vn', zh ? '去除视频流' : 'Remove video stream'),
                      ('-an', zh ? '去除音频流' : 'Remove audio stream'),
                    ]),
                    _refGroup(scheme, zh ? '滤镜' : 'Filters', [
                      ('-vf subtitles=...', zh ? '烧录字幕' : 'Burn subtitles'),
                      ('-vf scale=W:H', zh ? '缩放' : 'Scale'),
                      ('-vf fps=N', zh ? '修改帧率' : 'Change FPS'),
                      ('-vf crop=W:H:X:Y', zh ? '裁剪' : 'Crop'),
                    ]),
                    _refGroup(scheme, zh ? '时间控制' : 'Time', [
                      ('-ss HH:MM:SS', zh ? '起始时间' : 'Start time'),
                      ('-to HH:MM:SS', zh ? '结束时间' : 'End time'),
                      ('-t <duration>', zh ? '持续时长' : 'Duration'),
                    ]),
                  ])),
                ]),
              ))),
            ])),
          ]),
        )),
      ]),
    );
  }


  Widget _wrapCard(ColorScheme scheme, Widget child) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface.withAlpha(160),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _templateItem(ColorScheme scheme, String title, String cmd, bool zh) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: scheme.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _insertTemplate(cmd),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(Icons.code, size: 14, color: scheme.primary.withAlpha(180)),
              const SizedBox(width: 8),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurface)),
                const SizedBox(height: 2),
                Text(cmd, style: TextStyle(fontSize: 10, fontFamily: AppTheme.monoFont, color: scheme.outline), maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),
              Icon(Icons.arrow_forward_ios, size: 10, color: scheme.outline.withAlpha(100)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _refGroup(ColorScheme scheme, String title, List<(String, String)> items) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withAlpha(60),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.primary)),
        ),
        const SizedBox(height: 6),
        ...items.map((item) => Padding(
          padding: const EdgeInsets.only(bottom: 3, left: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 140, child: Text(item.$1,
                style: TextStyle(fontSize: 11, fontFamily: AppTheme.monoFont, color: scheme.primary, fontWeight: FontWeight.w500))),
            Expanded(child: Text(item.$2,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))),
          ]),
        )),
      ]),
    );
  }
}


/// 输出条目数据
class _OutputEntry {
  final String text;
  final bool isError;
  final bool isCommand;
  const _OutputEntry({required this.text, required this.isError, this.isCommand = false});
}

/// 移动端操作按钮
class _MobileActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool compact;

  const _MobileActionButton({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: color.withAlpha(30),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 14,
            vertical: 8,
          ),
          child: Row(
            mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: onTap == null ? scheme.outline : color),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: onTap == null ? scheme.outline : color)),
            ],
          ),
        ),
      ),
    );
  }
}

