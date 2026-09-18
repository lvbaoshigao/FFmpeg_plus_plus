import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/app_card.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/wallpaper_background.dart';
import '../platform/app_platform.dart';

/// 一条广告数据。
///
/// 目前没有任何广告投放（见 [kAds] 为空），因此页面展示「哦先生目前并没有放广告」空状态。
/// 后续接入广告时只需往 [kAds] 里加数据，UI 会自动渲染成卡片列表 ——
/// 页面骨架、样式（壁纸背景 + 玻璃卡片 + 与其它三级页一致的顶栏）都已就位。
class AdItem {
  /// 标题
  final String title;
  /// 简介正文
  final String body;
  /// 可选：点击后打开的链接（空 = 卡片不可点击）
  final String url;

  const AdItem({required this.title, required this.body, this.url = ''});
}

/// 广告投放位（当前为空：暂不增加广告）。
const List<AdItem> kAds = <AdItem>[];

/// 「设置 → 关于 → 广告」三级页面。
///
/// 结构与 CreditsPage（引用页）保持一致：有壁纸铺壁纸 + 背景不透明度遮罩，
/// 移动端用 MobileSubPageTopBar，桌面端用 GlassTopBar；内容卡片统一走 AppCard，
/// 因此会跟随「主题 → 样式 → 卡片样式」的全局设置，不需要单独一套 UI。
class AdsPage extends StatelessWidget {
  const AdsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = AppStrings.of(context.select<AppState, String>((st) => st.config.language));
    final cardStyle = context.select<AppState, String>((st) => st.config.cardStyle);

    final title = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.campaign_outlined, size: 20, color: scheme.primary),
      const SizedBox(width: 8),
      Text(s.isZh ? '广告' : 'Ads'),
    ]);

    return withWallpaper(context, Scaffold(
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
          child: kAds.isEmpty
              ? _emptyState(context, scheme, s)
              : ListView.separated(
                  // 开窗卡所在列表必须关：子项若被自动套上 RepaintBoundary，
                  // 滚动时会直接复用旧图层平移，卡内壁纸跟着卡走（见 app_card 的
                  // _WallpaperWindowPainter）。
                  addRepaintBoundaries: false,
                  padding: isMobilePlatform
                      ? MobileUi.subListPadding(top: 10, bottom: 24)
                      : const EdgeInsets.fromLTRB(16, 10, 16, 24),
                  itemCount: kAds.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (ctx, i) => AppCard(
                    style: cardStyle,
                    radius: 14,
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(kAds[i].title,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                      const SizedBox(height: 6),
                      Text(kAds[i].body,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant, height: 1.4)),
                      if (kAds[i].url.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(kAds[i].url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: scheme.primary)),
                      ],
                    ]),
                  ),
                ),
        ),
      ]),
    ));
  }

  /// 空状态：暂无广告内容（用户要求「没有广告显示哦先生目前并没有放广告」）。
  /// 用 AppCard 承载，样式与其它三级页的卡片完全一致。
  Widget _emptyState(BuildContext context, ColorScheme scheme, AppStrings s) {
    final cardStyle = context.select<AppState, String>((st) => st.config.cardStyle);
    return Center(
      child: Padding(
        padding: isMobilePlatform
            ? MobileUi.subListPadding(top: 8, bottom: 24)
            : const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: AppCard(
          style: cardStyle,
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.inbox_outlined, size: 46, color: scheme.outline.withAlpha(140)),
            const SizedBox(height: 14),
            Text(s.isZh ? '哦先生目前并没有放广告' : 'Nothing here yet',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface)),
            const SizedBox(height: 6),
            Text(
                s.isZh ? '暂时没有广告内容' : 'No ads available for now',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.outline)),
          ]),
        ),
      ),
    );
  }
}
