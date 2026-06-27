import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/ffmpeg_installer.dart';

const _ffmpegUrl = 'https://wwbrq.lanzouv.com/iTF9n3sb937c';
const _ffprobeUrl = 'https://wwbrq.lanzouv.com/itEOt3t5yogh';

class FfmpegInstallDialog extends StatefulWidget {
  const FfmpegInstallDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(context: context, barrierDismissible: false,
        builder: (_) => const FfmpegInstallDialog());
  }

  @override
  State<FfmpegInstallDialog> createState() => _FfmpegInstallDialogState();
}

class _FfmpegInstallDialogState extends State<FfmpegInstallDialog> {
  String _step = 'choose';
  String _status = '';
  double _progress = 0;
  String? _error;
  bool _slowWarning = false;
  final _logs = <String>[];

  // 蓝奏云分步状态
  String? _ffmpegZipPath;
  String? _ffprobeZipPath;

  void _log(String msg) {
    _logs.add(msg);
    if (_logs.length > 100) _logs.removeAt(0);
  }

  Future<void> _startWinget() async {
    setState(() { _step = 'winget'; _status = '准备 winget...'; _progress = 0; _error = null; _slowWarning = false; });
    try {
      await FfmpegInstaller.installViaWinget(
        onStatus: (s) { _log(s); if (mounted) setState(() => _status = s); },
        onProgress: (p) { if (mounted) setState(() => _progress = p); },
        onSpeedWarning: (slow) { if (mounted) setState(() => _slowWarning = slow); },
      );
      if (mounted) setState(() => _step = 'done');
    } catch (e) {
      _log('错误: $e');
      if (mounted) setState(() { _step = 'error'; _error = '$e'; });
    }
  }

  void _startLanzou() {
    setState(() { _step = 'lanzou'; _ffmpegZipPath = null; _ffprobeZipPath = null; });
  }

  Future<void> _openBrowser(String url) async {
    await Process.run('cmd', ['/c', 'start', url], runInShell: true);
  }

  Future<void> _pickFile(bool isFFmpeg) async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['zip'],
      dialogTitle: isFFmpeg ? '选择下载好的 ffmpeg.zip' : '选择下载好的 ffprobe.zip',
    );
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;
    final path = r.files.first.path!;
    final size = File(path).lengthSync();
    if (size < 1000000) {
      setState(() => _status = '文件太小 (${(size / 1024).toStringAsFixed(0)}KB)，请确认是否下载完整');
      return;
    }
    setState(() {
      if (isFFmpeg) {
        _ffmpegZipPath = path;
        _status = 'ffmpeg.zip 已选择 (${(size / 1024 / 1024).toStringAsFixed(1)}MB)';
      } else {
        _ffprobeZipPath = path;
        _status = 'ffprobe.zip 已选择 (${(size / 1024 / 1024).toStringAsFixed(1)}MB)';
      }
    });
  }

  Future<void> _doImport() async {
    if (_ffmpegZipPath == null || _ffprobeZipPath == null) return;
    setState(() { _step = 'importing'; _status = '正在解压...'; _progress = 0; });
    try {
      await FfmpegInstaller.importFromZips(
        ffmpegZipPath: _ffmpegZipPath!,
        ffprobeZipPath: _ffprobeZipPath!,
        onStatus: (s) { _log(s); if (mounted) setState(() => _status = s); },
        onProgress: (p) { if (mounted) setState(() => _progress = p); },
      );
      if (mounted) setState(() => _step = 'done');
    } catch (e) {
      _log('错误: $e');
      if (mounted) setState(() { _step = 'error'; _error = '$e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        Icon(_titleIcon, size: 22, color: _titleColor(scheme)),
        const SizedBox(width: 8),
        Text(_title, style: TextStyle(fontSize: 16, color: scheme.onSurface)),
      ]),
      content: SizedBox(width: 480, child: _buildContent(scheme)),
      actions: _buildActions(scheme),
    );
  }

  IconData get _titleIcon => switch (_step) { 'done' => Icons.check_circle, 'error' => Icons.error, _ => Icons.download };
  Color _titleColor(ColorScheme s) => switch (_step) { 'done' => Colors.green, 'error' => s.error, _ => s.primary };
  String get _title => switch (_step) {
    'choose' => '安装 FFmpeg', 'winget' => '正在安装...', 'lanzou' => '蓝奏云下载',
    'importing' => '正在导入...', 'done' => '安装完成', 'error' => '安装失败', _ => '',
  };

  Widget _buildContent(ColorScheme scheme) => switch (_step) {
    'choose' => _buildChoose(scheme),
    'winget' || 'importing' => _buildProgress(scheme),
    'lanzou' => _buildLanzouGuide(scheme),
    'done' => _buildDone(scheme),
    'error' => _buildError(scheme),
    _ => const SizedBox.shrink(),
  };

  Widget _buildChoose(ColorScheme scheme) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('未检测到 FFmpeg，需要安装后才能处理视频。\n请选择安装方式：',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
      const SizedBox(height: 16),
      _methodCard(scheme, Icons.terminal, 'Winget 自动安装',
          '通过 Windows 包管理器自动下载安装\n自动配置环境变量，全局可用', '全自动', _startWinget),
      const SizedBox(height: 8),
      _methodCard(scheme, Icons.cloud_download, '蓝奏云手动下载',
          '从国内蓝奏云网盘下载（速度快，无需梯子）\n需手动下载两个文件后导入', '国内推荐', _startLanzou),
    ]);
  }

  Widget _methodCard(ColorScheme scheme, IconData icon, String title, String desc, String tag, VoidCallback onTap) {
    return Material(
      color: scheme.surfaceContainerHighest.withAlpha(80),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(borderRadius: BorderRadius.circular(10), onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
          Container(width: 40, height: 40,
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 20, color: scheme.onPrimaryContainer)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              const SizedBox(width: 6),
              Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(4)),
                child: Text(tag, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: scheme.primary))),
            ]),
            const SizedBox(height: 4),
            Text(desc, style: TextStyle(fontSize: 11, color: scheme.outline)),
          ])),
          Icon(Icons.arrow_forward_ios, size: 14, color: scheme.outline),
        ]))),
    );
  }

  // ── 蓝奏云分步引导 ──

  Widget _buildLanzouGuide(ColorScheme scheme) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 步骤指示器
      _stepIndicator(scheme),
      const SizedBox(height: 16),

      // 第一步：下载 ffmpeg
      _fileCard(scheme,
        step: 1,
        name: 'ffmpeg.zip',
        desc: 'FFmpeg 视频处理核心程序（约 69MB）',
        url: _ffmpegUrl,
        selectedPath: _ffmpegZipPath,
        onDownload: () => _openBrowser(_ffmpegUrl),
        onPick: () => _pickFile(true),
      ),
      const SizedBox(height: 10),

      // 第二步：下载 ffprobe
      _fileCard(scheme,
        step: 2,
        name: 'ffprobe.zip',
        desc: 'FFprobe 视频信息探测工具（约 69MB）',
        url: _ffprobeUrl,
        selectedPath: _ffprobeZipPath,
        onDownload: () => _openBrowser(_ffprobeUrl),
        onPick: () => _pickFile(false),
      ),
      const SizedBox(height: 12),

      // 状态
      if (_status.isNotEmpty)
        Padding(padding: const EdgeInsets.only(bottom: 8),
          child: Text(_status, style: TextStyle(fontSize: 11, color: scheme.outline))),

      // 导入按钮
      SizedBox(width: double.infinity, child: FilledButton.icon(
        onPressed: (_ffmpegZipPath != null && _ffprobeZipPath != null) ? _doImport : null,
        icon: const Icon(Icons.install_desktop, size: 18),
        label: Text(_ffmpegZipPath != null && _ffprobeZipPath != null
            ? '安装到程序目录' : '请先下载并选择两个文件'),
      )),

      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withAlpha(40), borderRadius: BorderRadius.circular(6)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline, size: 13, color: scheme.outline),
          const SizedBox(width: 6),
          Expanded(child: Text(
            '下载页面点击「普通下载」或「立即下载」按钮即可\n安装后的文件可在设置中删除',
            style: TextStyle(fontSize: 10, color: scheme.outline, height: 1.4),
          )),
        ]),
      ),
    ]);
  }

  Widget _stepIndicator(ColorScheme scheme) {
    final step1Done = _ffmpegZipPath != null;
    final step2Done = _ffprobeZipPath != null;
    return Row(children: [
      _dot(scheme, step1Done, '1'),
      Expanded(child: Container(height: 2, color: step1Done ? scheme.primary : scheme.outlineVariant.withAlpha(80))),
      _dot(scheme, step2Done, '2'),
      Expanded(child: Container(height: 2, color: step2Done ? scheme.primary : scheme.outlineVariant.withAlpha(80))),
      _dot(scheme, step1Done && step2Done, '3'),
    ]);
  }

  Widget _dot(ColorScheme scheme, bool done, String label) {
    return Container(
      width: 24, height: 24,
      decoration: BoxDecoration(shape: BoxShape.circle,
        color: done ? scheme.primary : scheme.surfaceContainerHighest,
        border: Border.all(color: done ? scheme.primary : scheme.outlineVariant, width: 1.5)),
      child: Center(child: done
        ? Icon(Icons.check, size: 14, color: scheme.onPrimary)
        : Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant))),
    );
  }

  Widget _fileCard(ColorScheme scheme, {
    required int step, required String name, required String desc,
    required String url, required String? selectedPath,
    required VoidCallback onDownload, required VoidCallback onPick,
  }) {
    final done = selectedPath != null;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: done ? scheme.primaryContainer.withAlpha(30) : scheme.surfaceContainerHighest.withAlpha(60),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: done ? scheme.primary.withAlpha(60) : scheme.outlineVariant.withAlpha(50)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(done ? Icons.check_circle : Icons.download, size: 16,
              color: done ? Colors.green : scheme.primary),
          const SizedBox(width: 6),
          Text(name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const Spacer(),
          if (done)
            Text('已选择', style: TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        Text(desc, style: TextStyle(fontSize: 11, color: scheme.outline)),
        if (done)
          Padding(padding: const EdgeInsets.only(top: 4),
            child: Text(selectedPath!, style: TextStyle(fontSize: 9, color: scheme.outline, fontFamily: 'Consolas'),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(height: 8),
        Row(children: [
          OutlinedButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.open_in_browser, size: 16),
            label: Text(done ? '重新下载' : '打开下载页', style: const TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: onPick,
            icon: const Icon(Icons.folder_open, size: 16),
            label: Text(done ? '重新选择' : '选择已下载的文件', style: const TextStyle(fontSize: 12)),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
          ),
        ]),
      ]),
    );
  }

  // ── 通用 ──

  Widget _buildProgress(ColorScheme scheme) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      LinearProgressIndicator(value: _progress, borderRadius: BorderRadius.circular(4)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Text(_status, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant), maxLines: 2, overflow: TextOverflow.ellipsis)),
        Text('${(_progress * 100).toInt()}%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
      ]),
      if (_slowWarning) ...[
        const SizedBox(height: 8),
        Container(padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: Colors.orange.withAlpha(30), borderRadius: BorderRadius.circular(6)),
          child: Row(children: [
            const Icon(Icons.warning_amber, size: 14, color: Colors.orange),
            const SizedBox(width: 6),
            Expanded(child: Text('下载速度较慢，建议取消后切换到蓝奏云下载',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade800))),
          ])),
      ],
      const SizedBox(height: 12),
      Container(height: 80, padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withAlpha(60), borderRadius: BorderRadius.circular(8)),
        child: ListView.builder(reverse: true, itemCount: _logs.length,
          itemBuilder: (_, i) => Text(_logs[_logs.length - 1 - i],
              style: TextStyle(fontSize: 10, fontFamily: 'Consolas', color: scheme.outline)))),
    ]);
  }

  Widget _buildDone(ColorScheme scheme) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.check_circle, size: 48, color: Colors.green),
      const SizedBox(height: 12),
      Text('FFmpeg 安装成功！', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface)),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withAlpha(60), borderRadius: BorderRadius.circular(8)),
        child: Column(children: [
          _pathRow(scheme, 'ffmpeg', FfmpegInstaller.ffmpegPath),
          const SizedBox(height: 4),
          _pathRow(scheme, 'ffprobe', FfmpegInstaller.ffprobePath),
        ]),
      ),
    ]);
  }

  Widget _pathRow(ColorScheme scheme, String label, String path) {
    final exists = File(path).existsSync();
    return Row(children: [
      Icon(exists ? Icons.check : Icons.close, size: 14, color: exists ? Colors.green : scheme.error),
      const SizedBox(width: 6),
      Text('$label: ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onSurface)),
      Expanded(child: Text(path, style: TextStyle(fontSize: 10, fontFamily: 'Consolas', color: scheme.outline),
          overflow: TextOverflow.ellipsis)),
    ]);
  }

  Widget _buildError(ColorScheme scheme) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: scheme.errorContainer.withAlpha(60), borderRadius: BorderRadius.circular(8)),
        child: Text(_error ?? '未知错误', style: TextStyle(fontSize: 12, color: scheme.onErrorContainer))),
      const SizedBox(height: 12),
      Text('• 尝试另一种安装方式\n• 手动安装 FFmpeg 并添加到 PATH',
          style: TextStyle(fontSize: 12, color: scheme.outline)),
    ]);
  }

  List<Widget> _buildActions(ColorScheme scheme) => switch (_step) {
    'choose' => [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消'))],
    'winget' || 'importing' => [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消'))],
    'lanzou' => [
      TextButton(onPressed: () => setState(() => _step = 'choose'), child: const Text('返回')),
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
    ],
    'done' => [FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('完成'))],
    'error' => [
      TextButton(onPressed: () => setState(() => _step = 'choose'), child: const Text('重试')),
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('关闭')),
    ],
    _ => [],
  };
}
