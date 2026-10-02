import 'package:flutter/material.dart';

import '../services/fppx2_service.dart';
import '../widgets/toast.dart';

/// 「输入口令」对话框 —— 导入加密 .fppx 时使用。
///
/// 按 fppx-v2 格式规范 §6.9：
/// * 口令错误时对话框**保持打开**并显示错误文案（"口令错误，或文件已损坏 / 被篡改"），
///   用户可直接重试；
/// * 点「取消」返回 null，调用方给「已取消」提示，**不当错误弹**；
/// * 口令不落盘、不进日志、不回显在错误信息里。
class FppxPasswordDialog extends StatefulWidget {
  const FppxPasswordDialog({
    super.key,
    required this.zh,
    required this.attempt,
  });

  final bool zh;

  /// 尝试用口令打开文件；返回 null 表示成功（对话框自行关闭），
  /// 返回非空文案表示失败并展示该文案。
  final Future<String?> Function(String password) attempt;

  @override
  State<FppxPasswordDialog> createState() => _FppxPasswordDialogState();
}

class _FppxPasswordDialogState extends State<FppxPasswordDialog> {
  final TextEditingController _ctrl = TextEditingController();
  String? _err;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final zh = widget.zh;
    if (_ctrl.text.isEmpty) {
      setState(() => _err = zh ? '口令不能为空' : 'Password cannot be empty');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    final err = await widget.attempt(_ctrl.text);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, _ctrl.text);
      return;
    }
    setState(() {
      _busy = false;
      _err = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final zh = widget.zh;
    return AlertDialog(
      title: Row(children: [
        Icon(Icons.lock_outline, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Text(zh ? '输入配置口令' : 'Enter Password',
            style: TextStyle(color: scheme.onSurface)),
      ]),
      content: SizedBox(
        width: 340,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  zh
                      ? '该配置文件已加密，请输入口令以解密并打开。'
                      : 'This config file is encrypted. Enter the password to open it.',
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              TextField(
                controller: _ctrl,
                autofocus: true,
                obscureText: true,
                enabled: !_busy,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: zh ? '口令' : 'Password',
                  labelStyle: TextStyle(color: scheme.onSurfaceVariant),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  isDense: true,
                ),
                style: TextStyle(fontSize: 13, color: scheme.onSurface),
              ),
              if (_err != null) ...[
                const SizedBox(height: 10),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.error_outline, size: 14, color: scheme.error),
                  const SizedBox(width: 4),
                  Expanded(
                      child: Text(_err!, style: TextStyle(fontSize: 12, color: scheme.error))),
                ]),
              ],
            ]),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(zh ? '取消' : 'Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(zh ? '解密并打开' : 'Unlock'),
        ),
      ],
    );
  }
}

/// 导入 .fppx 并自动处理加密口令流程（三个导入入口共用）。
///
/// 首次不带口令调用：C++ 端若发现文件已加密会返回 `need_password`（不是错误），
/// 这里再弹 [FppxPasswordDialog]，用户提交后带口令重调。
///
/// 返回 null 表示导入已中止（用户取消，或需要口令而用户放弃）；
/// 返回结果对象的 `success == false` 表示真实失败（调用方照常展示 errors）。
Future<FppxImportResult?> importFppxWithPassword(
  BuildContext context,
  FppxService svc,
  String path, {
  bool force = false,
  bool zh = true,
}) async {
  final first = await svc.importFile(path, force: force);
  if (!context.mounted) return null;
  if (!first.needsPassword) return first;

  FppxImportResult? unlocked;
  final used = await showDialog<String>(
    context: context,
    // 不用点遮罩关闭：必须显式选择「取消」或「解密并打开」
    barrierDismissible: false,
    builder: (_) => FppxPasswordDialog(
      zh: zh,
      attempt: (pw) async {
        final r = await svc.importFile(path, force: force, password: pw);
        if (r.success) {
          unlocked = r;
          return null;
        }
        if (r.errors.isNotEmpty) return r.errors.join('\n');
        return r.error ??
            (zh ? '口令错误，或文件已损坏 / 被篡改' : 'Wrong password, or the file is corrupted');
      },
    ),
  );
  if (!context.mounted) return null;
  if (used == null) {
    showToast(context, zh ? '已取消' : 'Cancelled', type: ToastType.info);
    return null;
  }
  return unlocked;
}
