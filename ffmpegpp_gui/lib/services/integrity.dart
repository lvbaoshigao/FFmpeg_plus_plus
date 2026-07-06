import 'dart:io';
import 'package:crypto/crypto.dart';

/// 启动完整性校验：验证关键资源文件 MD5，不匹配则跳过（不闪退）
class IntegrityCheck {
  static const _expectedMd5 = {
    'icon.png': '5493df3e8d4afef9d6a479fd97715cb5',
    'wx.png': '1775d9410c7dc0679f64f9211c810979',
    'zfb.jpg': '405c5edd469221d63c56e9bb6d284387',
  };

  static Future<bool> verify() async {
    try {
      final exeDir = Directory(Platform.resolvedExecutable).parent;
      final candidates = [
        '${exeDir.path}/data/flutter_assets/rele',
        '${exeDir.path}/../data/flutter_assets/rele',
        '${exeDir.path}/../../data/flutter_assets/rele',
      ];
      String? dir;
      for (final c in candidates) {
        if (Directory(c).existsSync()) {
          dir = c;
          break;
        }
      }
      if (dir == null) return false;

      for (final entry in _expectedMd5.entries) {
        final file = File('$dir/${entry.key}');
        if (!await file.exists()) return false;
        final bytes = await file.readAsBytes();
        final actual = md5.convert(bytes).toString();
        if (actual != entry.value) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
