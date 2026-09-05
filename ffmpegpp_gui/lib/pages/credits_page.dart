import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../app.dart' show wallpaperImageProvider;
import '../platform/app_platform.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_top_bar.dart';
import '../services/shell_open.dart';

/// 「引用」页：列出本应用使用的第三方开源项目并致谢。
class CreditsPage extends StatelessWidget {
  const CreditsPage({super.key});

  /// 与其它二级页（容器详情等）一致：有壁纸铺壁纸，无壁纸至少铺一层不透明
  /// 主题底色。修复点：此前本页 Scaffold 透明且外层没有铺任何背景，
  /// 在移动端（页面直接 push 出新路由、底下不是壁纸 Stack）会露出系统
  /// 窗口黑底 → 整页黑屏、文字不可见。
  Widget _withWallpaper(BuildContext context, Widget child) {
    final cfg = context.watch<AppState>().config;
    final bg = cfg.backgroundImage;
    final scheme = Theme.of(context).colorScheme;
    final base = Positioned.fill(child: Container(color: scheme.surface));
    if (bg.isEmpty || !File(bg).existsSync()) {
      return Stack(children: [base, child]);
    }
    final a = ((1.0 - cfg.backgroundOpacity) * 220).round().clamp(20, 240);
    return Stack(children: [
      base,
      // 统一走 wallpaperImageProvider 按物理分辨率降采样解码
      Positioned.fill(child: Image(
        image: wallpaperImageProvider(
            bg,
            MediaQuery.sizeOf(context).width,
            MediaQuery.sizeOf(context).height,
            MediaQuery.devicePixelRatioOf(context)),
        fit: BoxFit.cover,
      )),
      Positioned.fill(child: Container(color: scheme.surface.withAlpha(a))),
      Theme(data: Theme.of(context).copyWith(
        scaffoldBackgroundColor: Colors.transparent,
      ), child: child),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = AppStrings.of(context.watch<AppState>().config.language);

    final title = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.favorite_outline, size: 20, color: scheme.primary),
      const SizedBox(width: 8),
      Text(s.aboutReferencesTitle),
    ]);

    return _withWallpaper(context, Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(children: [
        isMobilePlatform
            ? MobileSubPageTopBar(title: title, onBack: () => Navigator.of(context).maybePop())
            : GlassTopBar(
                title: title,
                actions: [
                  IconButton(
                    tooltip: s.aboutClose,
                    icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text(s.aboutReferencesIntro,
                  style: TextStyle(fontSize: 13, color: scheme.outline)),
              const SizedBox(height: 14),
              _projectCard(scheme, s,
                  name: 'tabler-icons',
                  license: 'MIT License',
                  desc: s.isZh
                      ? '逻辑门矢量图标（节点编辑器 IEEE 逻辑门符号）'
                      : 'Vector logic-gate icons (IEEE gate symbols in the node editor)',
                  url: 'https://github.com/tabler/tabler-icons'),
            ],
          ),
        ),
      ]),
    ));
  }

  Widget _projectCard(ColorScheme scheme, AppStrings s,
      {required String name, required String license, required String desc, required String url}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.category_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(name,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: scheme.onSurface))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withAlpha(140),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(license,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: scheme.onTertiaryContainer)),
          ),
        ]),
        const SizedBox(height: 8),
        Text(desc, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: 12),
        Row(children: [
          Icon(Icons.link, size: 14, color: scheme.outline),
          const SizedBox(width: 6),
          Expanded(child: SelectableText(url,
              style: TextStyle(fontSize: 12, color: scheme.primary))),
        ]),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => ShellOpen.url(url),
            icon: const Icon(Icons.open_in_new, size: 15),
            label: Text(s.isZh ? '打开' : 'Open'),
          ),
        ),
      ]),
    );
  }
}
