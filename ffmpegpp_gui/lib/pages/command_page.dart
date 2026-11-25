import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/adaptive_top_bar.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_glass_pill.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/toast.dart';
import '../widgets/wallpaper_background.dart';
// Linux 自绘窗口修饰（CSD）：全屏路由页统一套 WindowChrome。
import '../widgets/window_chrome.dart';

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
    '-i ',
    '-y ',
    '-c:v ',
    '-c:a ',
    '-b:v ',
    '-b:a ',
    '-crf ',
    '-preset ',
    '-s ',
    '-r ',
    '-ss ',
    '-to ',
    '-t ',
    '-vn ',
    '-an ',
    '-vf ',
    '-ac ',
    '-ar ',
    'libx264',
    'libx265',
    'h264_nvenc',
    'hevc_nvenc',
    'copy',
    'aac',
    'libmp3lame',
    'ultrafast',
    'veryfast',
    'fast',
    'medium',
    'slow',
    'veryslow',
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _outputCtrl.dispose();
    super.dispose();
  }

  bool _handleTab(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.tab ||
        HardwareKeyboard.instance.isShiftPressed) {
      return false;
    }
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
    if (completion == currentWord) return false;
    final newText =
        text.substring(0, lastSpace + 1) + completion + text.substring(sel.end);
    setState(() {
      _ctrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: lastSpace + 1 + completion.length,
        ),
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
    final state = context.read<AppState>();
    final zh = AppStrings.of(state.config.language).isZh;
    final cmd = _ctrl.text.trim();
    if (cmd.isEmpty) {
      showToast(
        context,
        zh ? '请输入 FFmpeg 命令' : 'Enter an FFmpeg command.',
        type: ToastType.warning,
      );
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
      '-i',
      '-c',
      '-c:v',
      '-c:a',
      '-c:s',
      '-codec',
      '-codec:v',
      '-codec:a',
      '-codec:s',
      '-vcodec',
      '-acodec',
      '-scodec',
      '-t',
      '-to',
      '-ss',
      '-fs',
      '-frames:v',
      '-frames:a',
      '-vframes',
      '-aframes',
      '-b',
      '-b:v',
      '-b:a',
      '-crf',
      '-r',
      '-s',
      '-vf',
      '-af',
      '-filter',
      '-filter:v',
      '-filter:a',
      '-f',
      '-format',
      '-map',
      '-map:v',
      '-map:a',
      '-preset',
      '-tune',
      '-profile',
      '-profile:v',
      '-level',
      '-pix_fmt',
      '-ar',
      '-ac',
      '-ab',
      '-g',
      '-q',
      '-q:v',
      '-q:a',
      '-bufsize',
      '-maxrate',
      '-minrate',
      '-movflags',
      '-tag:v',
      '-metadata',
      '-aspect',
      '-threads',
      '-cpu-used',
      '-deadline',
    };
    for (int i = parts.length - 1; i >= 0; i--) {
      final tok = parts[i];
      if (tok.isEmpty || tok.startsWith('-')) continue;
      if (i > 0 && valueFlags.contains(parts[i - 1])) continue;
      outputPath = tok;
      break;
    }

    if (inputPath == null || outputPath == null) {
      showToast(
        context,
        zh
            ? '请使用 -i 指定输入文件，并在命令末尾填写输出文件。'
            : 'Use -i to specify the input file and put the output file last.',
        type: ToastType.error,
      );
      return;
    }

    if (!File(inputPath).existsSync()) {
      showToast(
        context,
        zh ? '输入文件不存在：$inputPath' : 'Input file not found: $inputPath',
        type: ToastType.error,
      );
      return;
    }

    final filename = inputPath.split(RegExp(r'[/\\]')).last;
    state.addCustomTask(
      inputPath: inputPath,
      outputPath: outputPath,
      command: cmd,
      filename: filename,
    );
    final queuedMessage = zh ? '已加入处理队列：$filename' : 'Queued: $filename';
    _appendEntries([
      _OutputEntry(text: '\$ $cmd', isError: false, isCommand: true),
      _OutputEntry(text: queuedMessage, isError: false),
    ]);
    _scrollOutputToEnd();
    showToast(context, queuedMessage, type: ToastType.success);
    _ctrl.clear();
  }

  /// 移动端执行：通过 Process.run 直接执行命令，结果显示在输出区。
  /// 安全限制：仅允许 ffmpeg/ffprobe 开头的命令，防止任意命令执行。
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
      // 安全校验：仅允许 ffmpeg/ffprobe 开头的命令（basename 匹配）
      final exeBase = exe.split(RegExp(r'[/\\]')).last.toLowerCase();
      if (exeBase != 'ffmpeg' &&
          exeBase != 'ffmpeg.exe' &&
          exeBase != 'ffprobe' &&
          exeBase != 'ffprobe.exe') {
        _appendOutput(
          'Security: only ffmpeg/ffprobe commands are allowed',
          isError: true,
        );
        return;
      }
      final args = parts.sublist(1);

      final trace = context.read<AppState>().diagnosticTrace;
      final watch = trace.enabled ? (Stopwatch()..start()) : null;
      trace.record(
        'process.start',
        operation: 'mobile_command',
        argumentCount: args.length,
      );
      ProcessResult result;
      try {
        result = await Process.run(exe, args);
      } catch (_) {
        trace.record(
          'process.finish',
          operation: 'mobile_command',
          elapsedMs: watch?.elapsedMilliseconds,
          success: false,
        );
        rethrow;
      }
      trace.record(
        'process.finish',
        operation: 'mobile_command',
        elapsedMs: watch?.elapsedMilliseconds,
        exitCode: result.exitCode,
        success: result.exitCode == 0,
      );
      if (!mounted) return;

      final stdout = result.stdout.toString();
      final stderr = result.stderr.toString();

      // 批量收集后一次 setState：原实现对每行调用一次 _appendOutput（每次
      // 一次 setState），`ffmpeg -h full` 这类数千行输出会累计数千次调用。
      // 若将来改为流式 stdout.listen，逐行 setState 会变成真正的逐帧重建，
      // 这里统一改为批量提交，从结构上消除该隐患。
      final batch = <_OutputEntry>[];
      if (stdout.isNotEmpty) {
        for (final line in stdout.split('\n')) {
          if (line.isNotEmpty) {
            batch.add(_OutputEntry(text: line, isError: false));
          }
        }
      }
      if (stderr.isNotEmpty) {
        for (final line in stderr.split('\n')) {
          if (line.isNotEmpty) {
            batch.add(_OutputEntry(text: line, isError: true));
          }
        }
      }
      batch.add(
        _OutputEntry(
          text: '[exit: ${result.exitCode}]',
          isError: result.exitCode != 0,
        ),
      );
      _appendEntries(batch);
    } catch (e) {
      if (mounted) _appendOutput('Error: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isRunning = false);
        _scrollOutputToEnd();
      }
    }
  }

  /// 输出条数上限：与日志页一致的有界策略，避免反复执行长输出命令导致
  /// _outputEntries 无限增长（每条目持有文本对象，永不释放）。
  static const int _maxOutputEntries = 5000;

  /// 批量追加输出条目（一次 setState + 一次裁剪）。
  void _appendEntries(List<_OutputEntry> entries) {
    if (entries.isEmpty) return;
    setState(() {
      _outputEntries.addAll(entries);
      if (_outputEntries.length > _maxOutputEntries) {
        _outputEntries.removeRange(
          0,
          _outputEntries.length - _maxOutputEntries,
        );
      }
    });
  }

  void _appendOutput(
    String text, {
    required bool isError,
    bool isCommand = false,
  }) {
    _appendEntries([
      _OutputEntry(text: text, isError: isError, isCommand: isCommand),
    ]);
  }

  void _scrollOutputToEnd() {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_outputCtrl.hasClients) return;
      final end = _outputCtrl.position.maxScrollExtent;
      if (reduceMotion) {
        _outputCtrl.jumpTo(end);
        return;
      }
      _outputCtrl.animateTo(
        end,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _clearOutput() {
    setState(() => _outputEntries.clear());
  }

  void _insertTemplate(String tpl) {
    _ctrl.text = tpl;
    _ctrl.selection = TextSelection.collapsed(offset: tpl.length);
    _focus.requestFocus();
    final input = _focus.context;
    if (input != null) Scrollable.ensureVisible(input);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = AppStrings.of(
      context.select<AppState, String>((st) => st.config.language),
    );
    final zh = s.isZh;

    if (isMobilePlatform) {
      return _buildMobile(context, scheme, s, zh);
    }
    return _buildDesktop(scheme, s, zh);
  }

  Widget _buildMobile(
    BuildContext context,
    ColorScheme scheme,
    AppStrings s,
    bool zh,
  ) {
    // 命令页经 Navigator.push 单独路由，不在根壁纸 Stack 内；统一交给
    // withWallpaper 铺「主题底色 + 壁纸 + 遮罩」，与其它二级页保持一致。
    // Linux 客户端修饰（CSD）：路由页统一套 WindowChrome，且必须放在
    // withWallpaper 的**内层**（标题栏玻璃要采样壁纸，见 window_chrome.dart）。
    return withWallpaper(
      context,
      WindowChrome(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // 移动端沉浸：药丸顶栏浮在内容上，内容整体置于底层（顶部让出
          // 顶栏高度，见 ImmersiveTopBar），不再被顶栏截断。
          body: ImmersiveTopBar(
            bar: MobileSubPageTopBar(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.terminal_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(s.navCommand, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              actions: [
                // 与主界面动作药丸一致的 34×34 紧凑圆形按钮（替换原 36×36 的 Material IconButton）
                MobileGlassPillAction(
                  icon: Icons.delete_outline,
                  tooltip: s.cmdClearOutput,
                  color: scheme.error,
                  onTap: _clearOutput,
                ),
              ],
              onBack: () => Navigator.of(context).maybePop(),
            ),
            child: Padding(
              padding: EdgeInsets.only(
                top: ImmersiveTopBar.insetOf(context) + 8,
                left: MobileUi.subPagePaddingH,
                right: MobileUi.subPagePaddingH,
                bottom: 8 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                children: [
                  _buildMobileInputArea(scheme, s, zh),
                  const SizedBox(height: 10),
                  Expanded(child: _buildMobileOutputArea(scheme, s, zh)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileInputArea(ColorScheme scheme, AppStrings s, bool zh) {
    return AppCard(
      style: context.read<AppState>().config.cardStyle,
      radius: 12,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.edit_note, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                s.cmdInput,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withAlpha(120),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
            ),
            child: Focus(
              focusNode: _focus,
              onKeyEvent: (node, event) => _handleTab(event)
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored,
              child: TextField(
                controller: _ctrl,
                maxLines: 3,
                minLines: 1,
                style: TextStyle(
                  fontFamily: AppTheme.monoFont,
                  fontSize: 13,
                  color: scheme.onSurface,
                  height: 1.5,
                ),
                onSubmitted: (_) => _executeMobile(),
                decoration: InputDecoration(
                  hintText: 'ffmpeg -i input.mp4 -c:v libx264 output.mp4',
                  hintStyle: TextStyle(
                    color: scheme.outline.withAlpha(100),
                    fontFamily: AppTheme.monoFont,
                    fontSize: 13,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 与项目页/队列页一致：由 AppTheme 统一 FilledButton / OutlinedButton
          // （radius 8、padding 20×12），不再自绘 Material 圆角块。
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isRunning ? null : _executeMobile,
                  icon: Icon(
                    _isRunning ? Icons.hourglass_empty : Icons.play_arrow,
                    size: 18,
                  ),
                  label: Text(_isRunning ? '...' : s.cmdExecute),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => setState(() => _ctrl.clear()),
                icon: const Icon(Icons.close, size: 16),
                label: Text(s.cmdClear),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMobileOutputArea(ColorScheme scheme, AppStrings s, bool zh) {
    return AppCard(
      style: context.read<AppState>().config.cardStyle,
      radius: 12,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.output, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                s.cmdOutput,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '${_outputEntries.length}',
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _outputEntries.isEmpty
                ? Center(
                    child: Text(
                      s.cmdNoOutput,
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
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
                              child: Text(
                                '${i + 1}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontFamily: AppTheme.monoFont,
                                  color: scheme.outline.withAlpha(120),
                                ),
                              ),
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
                                      : (entry.isError
                                            ? scheme.error
                                            : scheme.onSurface),
                                  fontWeight: entry.isCommand
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktop(ColorScheme scheme, AppStrings s, bool zh) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          AdaptiveTopBar(
            expandedBuilder: (_) => GlassTopBar(
              title: Row(
                children: [
                  Icon(
                    Icons.terminal_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(s.navCommand, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
            compactBuilder: (_) => MobilePillTopBar(
              title: Text(s.navCommand),
              actions: [
                MobileGlassPillAction(
                  icon: Icons.delete_outline,
                  tooltip: s.cmdClearOutput,
                  color: scheme.error,
                  onTap: _clearOutput,
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final textScale =
                    MediaQuery.textScalerOf(context).scale(16) / 16;
                final useWorkbench =
                    constraints.maxWidth >= 960 &&
                    constraints.maxHeight >= 620 &&
                    textScale < 1.35;

                if (useWorkbench) {
                  final referenceWidth = (constraints.maxWidth * 0.31).clamp(
                    310.0,
                    405.0,
                  );
                  return Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 7,
                          child: Column(
                            children: [
                              _buildDesktopInputCard(scheme, s, zh),
                              const SizedBox(height: 14),
                              Expanded(
                                child: _buildDesktopActivityArea(scheme, zh),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: referenceWidth,
                          child: Column(
                            children: [
                              Expanded(
                                child: _buildDesktopTemplates(
                                  scheme,
                                  zh,
                                  scrollable: true,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Expanded(
                                child: _buildDesktopReference(
                                  scheme,
                                  zh,
                                  scrollable: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }

                final activityHeight = (280 * textScale).clamp(280.0, 520.0);
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1180),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildDesktopInputCard(scheme, s, zh),
                          const SizedBox(height: 14),
                          SizedBox(
                            height: activityHeight,
                            child: _buildDesktopActivityArea(scheme, zh),
                          ),
                          const SizedBox(height: 14),
                          _buildDesktopTemplates(scheme, zh, scrollable: false),
                          const SizedBox(height: 14),
                          _buildDesktopReference(scheme, zh, scrollable: false),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopInputCard(ColorScheme scheme, AppStrings s, bool zh) {
    return GlassPanel(
      radius: 12,
      blur: 6,
      tintAlpha: 160,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.edit_note, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.cmdInput,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        zh
                            ? '按 Tab 补全参数，按 Enter 加入队列。'
                            : 'Press Tab to complete an option or Enter to queue.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Focus(
              skipTraversal: true,
              onKeyEvent: (node, event) => _handleTab(event)
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored,
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                maxLines: 1,
                textInputAction: TextInputAction.go,
                style: TextStyle(
                  fontFamily: AppTheme.monoFont,
                  fontSize: 15,
                  color: scheme.onSurface,
                  height: 1.5,
                ),
                onSubmitted: (_) => _execute(),
                decoration: InputDecoration(
                  labelText: zh ? 'FFmpeg 命令' : 'FFmpeg command',
                  hintText:
                      'ffmpeg -i input.mp4 -c:v libx264 -b:v 2000k output.mp4',
                  hintStyle: TextStyle(
                    color: scheme.outline,
                    fontFamily: AppTheme.monoFont,
                    fontSize: 13,
                  ),
                  prefixIcon: Icon(Icons.terminal, color: scheme.primary),
                  suffixIcon: IconButton(
                    tooltip: zh ? '清除命令' : 'Clear command',
                    onPressed: () => _ctrl.clear(),
                    icon: const Icon(Icons.close),
                  ),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withAlpha(105),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 17,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: scheme.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: scheme.outlineVariant.withAlpha(150),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: scheme.primary, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.icon(
                onPressed: _execute,
                icon: const Icon(Icons.playlist_add),
                label: Text(zh ? '加入队列' : 'Add to queue'),
                style: FilledButton.styleFrom(minimumSize: const Size(148, 48)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopActivityArea(ColorScheme scheme, bool zh) {
    final count = _outputEntries.length;
    return GlassPanel(
      radius: 12,
      blur: 6,
      tintAlpha: 160,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              spacing: 8,
              children: [
                Icon(
                  Icons.receipt_long_outlined,
                  size: 19,
                  color: scheme.primary,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        zh ? '命令记录' : 'Command activity',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      if (count > 0)
                        Text(
                          zh ? '$count 条' : '$count entries',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: zh ? '清空记录' : 'Clear activity',
                  onPressed: count == 0 ? null : _clearOutput,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: count == 0
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.terminal,
                              size: 30,
                              color: scheme.outline,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              zh ? '还没有命令记录' : 'No command activity yet',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: scheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              zh
                                  ? '添加到处理队列的命令会显示在这里。'
                                  : 'Commands added to the processing queue will appear here.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _outputCtrl,
                      padding: const EdgeInsets.fromLTRB(4, 8, 10, 12),
                      itemCount: count,
                      itemBuilder: (context, index) {
                        final entry = _outputEntries[index];
                        return Padding(
                          padding: EdgeInsets.only(
                            top: entry.isCommand && index > 0 ? 8 : 0,
                            bottom: 6,
                          ),
                          child: SelectableText(
                            entry.text,
                            style: TextStyle(
                              fontSize: 13,
                              fontFamily: AppTheme.monoFont,
                              height: 1.5,
                              color: entry.isCommand
                                  ? scheme.primary
                                  : (entry.isError
                                        ? scheme.error
                                        : scheme.onSurface),
                              fontWeight: entry.isCommand
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopTemplates(
    ColorScheme scheme,
    bool zh, {
    required bool scrollable,
  }) {
    final templates = [
      _templateItem(
        scheme,
        zh ? 'H.264 转码' : 'H.264 Transcode',
        'ffmpeg -i {input} -c:v libx264 -b:v 2000k -c:a aac {output}',
      ),
      _templateItem(
        scheme,
        zh ? 'GPU 加速' : 'GPU Accelerated',
        'ffmpeg -i {input} -c:v h264_nvenc -b:v 5000k -c:a copy {output}',
      ),
      _templateItem(
        scheme,
        zh ? '烧录字幕' : 'Burn Subtitles',
        'ffmpeg -i {input} -vf "subtitles=sub.srt" -c:a copy {output}',
      ),
      _templateItem(
        scheme,
        zh ? '缩放分辨率' : 'Scale Resolution',
        'ffmpeg -i {input} -s 1280x720 -c:a copy {output}',
      ),
      _templateItem(
        scheme,
        zh ? '提取音频' : 'Extract Audio',
        'ffmpeg -i {input} -vn -c:a copy {output}.aac',
      ),
      _templateItem(
        scheme,
        zh ? '转 GIF' : 'Convert to GIF',
        'ffmpeg -i {input} -vf "fps=10,scale=320:-1" {output}.gif',
      ),
      _templateItem(
        scheme,
        zh ? '截取片段' : 'Trim Clip',
        'ffmpeg -ss 00:00:30 -i {input} -to 00:01:00 -c copy {output}',
      ),
      _templateItem(
        scheme,
        zh ? '合并视频' : 'Concat Videos',
        'ffmpeg -f concat -safe 0 -i list.txt -c copy {output}',
      ),
      _templateItem(
        scheme,
        zh ? 'CRF 质量' : 'CRF Quality',
        'ffmpeg -i {input} -c:v libx264 -crf 23 -c:a aac {output}',
      ),
    ];

    return GlassPanel(
      radius: 12,
      blur: 6,
      tintAlpha: 160,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt, size: 18, color: scheme.primary),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    zh ? '快捷模板' : 'Quick templates',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (scrollable)
              Expanded(
                child: ListView(padding: EdgeInsets.zero, children: templates),
              )
            else
              Column(children: templates),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopReference(
    ColorScheme scheme,
    bool zh, {
    required bool scrollable,
  }) {
    final groups = [
      _refGroup(scheme, zh ? '输入输出' : 'I/O', [
        ('-i <file>', zh ? '输入文件' : 'Input file'),
        ('-y', zh ? '覆盖输出' : 'Overwrite output'),
      ]),
      _refGroup(scheme, zh ? '视频编码' : 'Video', [
        ('-c:v <codec>', 'libx264 / h264_nvenc / hevc_nvenc / copy'),
        ('-b:v <rate>', zh ? '视频码率 (如 2000k)' : 'Bitrate (e.g. 2000k)'),
        (
          '-crf <n>',
          zh ? 'CRF 质量 (0-51, 越小越好)' : 'Quality (0-51, lower=better)',
        ),
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
    ];

    return GlassPanel(
      radius: 12,
      blur: 6,
      tintAlpha: 160,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.menu_book, size: 18, color: scheme.primary),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    zh ? '参数参考' : 'Option reference',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (scrollable)
              Expanded(
                child: ListView(padding: EdgeInsets.zero, children: groups),
              )
            else
              Column(children: groups),
          ],
        ),
      ),
    );
  }

  Widget _templateItem(ColorScheme scheme, String title, String cmd) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: scheme.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _insertTemplate(cmd),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            child: Row(
              children: [
                Icon(
                  Icons.code,
                  size: 16,
                  color: scheme.primary.withAlpha(190),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        cmd,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: AppTheme.monoFont,
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 11,
                  color: scheme.outline.withAlpha(140),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _refGroup(
    ColorScheme scheme,
    String title,
    List<(String, String)> items,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withAlpha(70),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ...items.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Text(
                      item.$1,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: AppTheme.monoFont,
                        color: scheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 6,
                    child: Text(
                      item.$2,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 输出条目数据
class _OutputEntry {
  final String text;
  final bool isError;
  final bool isCommand;
  const _OutputEntry({
    required this.text,
    required this.isError,
    this.isCommand = false,
  });
}
