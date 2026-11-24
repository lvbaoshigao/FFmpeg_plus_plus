import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../services/shell_open.dart';
import '../theme/app_strings.dart';
import '../widgets/app_card.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/wallpaper_background.dart';
// Linux 自绘窗口修饰（CSD）：全屏路由页统一套 WindowChrome。
import '../widgets/window_chrome.dart';

/// 「引用」页：列出本应用使用的第三方开源项目并致谢。
class CreditsPage extends StatelessWidget {
  const CreditsPage({super.key});

  static const _projects = [
    (
      name: 'tabler-icons',
      license: 'MIT License',
      descZh: '桌面与移动端主导航、管线节点（含独立面板）及 IEEE 逻辑门使用的线框 SVG 图标。',
      descEn:
          'Outline SVG icons for desktop and mobile navigation, pipeline '
          'nodes (including detached panels), and IEEE logic gates.',
      url: 'https://github.com/tabler/tabler-icons',
    ),
    (
      name: 'oc_liquid_glass',
      license: 'MIT License',
      descZh: '在支持的设备上为卡片、面板和移动端胶囊控件提供 GPU 液态玻璃效果。',
      descEn:
          'GPU liquid-glass effects for cards, panels, and mobile pill '
          'controls on supported devices.',
      url: 'https://github.com/heyarny/oc_liquid_glass',
    ),
    (
      name: 'liquid_glass_widgets',
      license: 'MIT License',
      descZh: '为桌面端卡片和面板提供轻量液态玻璃材质。',
      descEn: 'Lightweight liquid-glass material for desktop cards and panels.',
      url: 'https://github.com/sdegenaar/liquid_glass_widgets',
    ),
    (
      name: 'liquid_glass_tab_bar',
      license: 'MIT License',
      descZh: '用于移动端液态玻璃底栏和子页面标签切换。',
      descEn: 'Liquid-glass bottom navigation and tab switching on mobile.',
      url: 'https://github.com/KananTaghili/liquid_glass_tab_bar',
    ),
    (
      name: 'liquid_glass_renderer',
      license: 'MIT License',
      descZh: '为液态玻璃底栏提供折射渲染。本项目使用带 Windows 与 Linux 着色器兼容补丁的版本。',
      descEn:
          'Refraction rendering for the liquid-glass tab bar. This app '
          'uses a version patched for shader compatibility on Windows and Linux.',
      url: 'https://pub.dev/packages/liquid_glass_renderer',
    ),
    (
      name: 'flutter_svg',
      license: 'MIT License',
      descZh: '用于加载和渲染 Tabler 图标、逻辑门及 AI 服务商标识等 SVG 资源。',
      descEn:
          'Loads and renders SVG assets such as Tabler icons, logic gates, '
          'and AI provider logos.',
      url: 'https://pub.dev/packages/flutter_svg',
    ),
  ];

  /// 与其它二级页（容器详情等）一致：有壁纸铺壁纸，无壁纸至少铺一层不透明
  /// 主题底色。修复点：此前本页 Scaffold 透明且外层没有铺任何背景，
  /// 与其它二级页（容器详情等）一致：有壁纸铺壁纸，无壁纸至少铺一层不透明
  /// 主题底色（实现统一在 widgets/wallpaper_background.dart）。
  Widget _withWallpaper(BuildContext context, Widget child) =>
      withWallpaper(context, child);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = AppStrings.of(
      context.select<AppState, String>((st) => st.config.language),
    );

    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.favorite_outline, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Text(s.aboutReferencesTitle),
      ],
    );

    // Linux 客户端修饰（CSD）：二级 / 三级全屏路由统一套 WindowChrome。
    // 顺序：WindowChrome 必须在 _withWallpaper（壁纸 Stack）的**内层** —— 标题栏
    // 玻璃用 BackdropFilter 采样同一棵树里更早绘制的像素；套在外面只会透出窗口
    // 底色。不传 title / onBack：本页自带顶栏与返回键。
    // 内容区提取：移动端沉浸（ImmersiveTopBar，条目钻到药丸顶栏底下）与
    // 桌面端 Column 布局共用同一棵内容树。移动端列表顶部留白必须含顶栏高度
    // （ImmersiveTopBar.insetOf），否则首屏第一条被药丸压住。
    final Widget content = Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isMobilePlatform ? double.infinity : 960,
        ),
        child: ListView(
          // 开窗卡所在列表必须关（见 app_card 的 _WallpaperWindowPainter）
          addRepaintBoundaries: false,
          padding: isMobilePlatform
              ? MobileUi.subListPadding(
                  top: ImmersiveTopBar.insetOf(context) + 8,
                  bottom: 24,
                )
              : const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(
              s.aboutReferencesIntro,
              style: TextStyle(fontSize: 13, color: scheme.outline),
            ),
            for (final project in _projects) ...[
              const SizedBox(height: 14),
              _projectCard(
                context,
                scheme,
                s,
                name: project.name,
                license: project.license,
                desc: s.isZh ? project.descZh : project.descEn,
                url: project.url,
              ),
            ],
          ],
        ),
      ),
    );

    return _withWallpaper(
      context,
      WindowChrome(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // 移动端：沉浸式浮动药丸顶栏（滚动条目从底下穿过）；
          // 桌面端：保持 Column + GlassTopBar 不变。
          body: isMobilePlatform
              ? ImmersiveTopBar(
                  bar: MobileSubPageTopBar(
                    title: title,
                    onBack: () => Navigator.of(context).maybePop(),
                  ),
                  child: content,
                )
              : Column(
                  children: [
                    GlassTopBar(
                      title: title,
                      actions: [
                        IconButton(
                          tooltip: s.aboutClose,
                          icon: Icon(
                            Icons.close,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      ],
                    ),
                    Expanded(child: content),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _projectCard(
    BuildContext context,
    ColorScheme scheme,
    AppStrings s, {
    required String name,
    required String license,
    required String desc,
    required String url,
  }) {
    // 卡片统一走 AppCard（跟随 主题→样式→卡片样式 cfg.cardStyle），
    // 不再本页手写 BoxDecoration（此前与项目页/设置页的卡片语言不一致）。
    return AppCard(
      style: context.select<AppState, String>((s) => s.config.cardStyle),
      radius: 14,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.category_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer.withAlpha(140),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  license,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            desc,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.link, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText(
                  url,
                  style: TextStyle(fontSize: 12, color: scheme.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => ShellOpen.url(url),
              icon: const Icon(Icons.open_in_new, size: 15),
              label: Text(s.isZh ? '打开' : 'Open'),
            ),
          ),
        ],
      ),
    );
  }
}
