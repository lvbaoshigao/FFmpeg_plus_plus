import 'dart:io';
import 'package:flutter/services.dart';

/// 统一的"用系统默认程序打开"入口。
///
/// 之前各处直接用 `Process.run('cmd', ['/c', 'start', x])`：cmd 会重新解析参数，
/// 把 `&` `|` `^` 当作命令分隔符。而这里的 x 既可能是更新接口返回的远端 URL，
/// 也可能是用户的输出文件名（Windows 文件名里 `&` 完全合法），
/// 于是 `视频 & calc.mp4` 这种名字就会被当成命令执行。
///
/// rundll32 url.dll,FileProtocolHandler 不经过 shell，URL 和本地文件都能处理。
/// Android 上没有 xdg-open/cmd：URL 走 ACTION_VIEW，本地文件走 FileProvider。
class ShellOpen {
  static const MethodChannel _androidChannel = MethodChannel('ffmpegpp/android');

  /// 打开一个 http/https 链接。非 http(s) 一律拒绝。
  static Future<void> url(String raw) async {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasAuthority) return;
    if (uri.scheme != 'http' && uri.scheme != 'https') return;
    await _launch(uri.toString());
  }

  /// 用默认程序打开本地文件/目录。
  static Future<void> path(String p) async {
    if (p.trim().isEmpty) return;
    await _launch(p);
  }

  /// 在文件管理器中定位到某个文件。
  static Future<void> reveal(String p) async {
    if (p.trim().isEmpty) return;
    try {
      if (Platform.isWindows) {
        // explorer 直接收参数，不过 shell
        await Process.start('explorer', ['/select,$p']);
      } else if (Platform.isMacOS) {
        await Process.start('open', ['-R', p]);
      } else if (Platform.isAndroid) {
        // Android：原生侧优先让系统文件管理器打开到目标所在的具体目录；
        // 目标在应用私有目录（DocumentsUI 无权浏览）时回退为直接打开文件本身，
        // 保证「点击后能跳到处理好的视频」而不是只进「文件」APP 首页。
        try {
          await _androidChannel.invokeMethod('revealFile', {'path': p});
        } catch (_) {
          // 原生方法不存在（旧原生壳热重载）等：退回打开所在目录
          await _openFile(File(p).parent.path);
        }
      } else {
        await Process.start('xdg-open', [File(p).parent.path]);
      }
    } catch (_) {}
  }

  static Future<void> _launch(String target) async {
    try {
      if (Platform.isAndroid) {
        // 走 MainActivity 的 MethodChannel：URL 用 ACTION_VIEW，
        // 本地路径用 FileProvider 生成 content:// 避免 FileUriExposedException
        final f = File(target);
        if (await f.exists()) {
          await _openFile(target);
        } else {
          await _androidChannel.invokeMethod('openUrl', {'url': target});
        }
      } else if (Platform.isWindows) {
        await Process.start('rundll32', ['url.dll,FileProtocolHandler', target]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [target]);
      } else {
        await Process.start('xdg-open', [target]);
      }
    } catch (_) {}
  }

  static Future<void> _openFile(String path) async {
    try {
      await _androidChannel.invokeMethod('openFile', {'path': path});
    } catch (_) {}
  }
}
