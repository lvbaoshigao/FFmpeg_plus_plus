import 'package:flutter/material.dart';

import '../platform/app_platform.dart';
import '../widgets/mobile_nav_scope.dart';

/// ═══════════════════════════════════════════════════════════════════════════
/// 移动端统一设计语言 · 尺寸与样式令牌
/// （以「主界面」lib/pages/project_page.dart 为基准抽取）
///
/// 本文件只放常量与纯函数，不依赖任何 widget，避免与
/// widgets/mobile_glass_pill.dart 形成循环 import。
/// 组件实现见 widgets/mobile_ui.dart。
///
/// 视觉语言三条主线：
/// * 顶栏 = 悬浮玻璃药丸（**不是**全宽模糊条）：左标题药丸 + 右操作药丸；
///   搜索时其它药丸淡出，同一颗搜索药丸向中央展开；
/// * 药丸规格：高 44、圆角 22、标题内边距 14、操作内边距 6；药丸内动作按钮
///   为 34×34 圆形，滑动涟漪透明。
/// * 内容左右内边距：主 Tab 页 8，二级页 12；底部统一让出 [kMobileNavClearance]。
///
/// 页面不应再自行拼装上述尺寸/结构，直接引用本文件令牌。
/// ═══════════════════════════════════════════════════════════════════════════
class MobileUi {
  const MobileUi._();

  // ── 顶栏（MobilePillTopBar / MobileSubPageTopBar 共用） ──
  /// 顶栏距屏幕左右边缘
  static const double barInsetH = 14;

  /// 顶栏距安全区上沿
  static const double barInsetTop = 8;

  /// 顶栏底部留白
  static const double barInsetBottom = 8;

  /// 药丸标准高度
  static const double pillHeight = 44;

  /// 药丸标准圆角（= 高的一半，正圆端）
  static const double pillRadius = pillHeight / 2;

  /// 标题药丸水平内边距
  static const double titlePillPadH = 14;

  /// 操作药丸水平内边距
  static const double actionsPillPadH = 6;

  /// 药丸内圆形动作按钮直径
  static const double actionButtonSize = 34;

  /// 动作按钮图标尺寸
  static const double actionIconSize = 19;

  /// 搜索药丸展开后的宽度（MobileSearchPill 的默认宽度）。
  static const double searchPillWidth = 200;

  /// 分离的玻璃药丸之间留出可见的背景。
  static const double pillGap = 10;

  /// 底部导航的外边距与最大宽度，不把导航拉成通栏面板。
  static const double navInsetH = 24;
  static const double navMaxWidth = 420;
  static const double navBottomGap = 8;

  /// 根据系统文字大小扩展顶栏，不反向缩小文字。
  static double pillHeightOf(BuildContext context) {
    final lineHeight = MediaQuery.textScalerOf(context).scale(16) * 1.3;
    return (lineHeight + 16).clamp(pillHeight, double.infinity);
  }

  /// 与自适应顶栏匹配的内容起点。
  static double contentTopOf(BuildContext context) =>
      barInsetTop + pillHeightOf(context) + barInsetBottom + 4;

  /// 主 Tab 页滚动内容左右内边距（项目 / 队列 / 配置库 / 设置）
  static const double pagePaddingH = 8;

  /// 二级页面滚动内容左右内边距（命令 / 日志 / 容器 / AI 等）
  static const double subPagePaddingH = 12;

  /// 主 Tab 页滚动内容起始顶部偏移（安全区 + 顶栏高度）。
  static double pageTopPadding(BuildContext context) =>
      MediaQuery.paddingOf(context).top + contentTopOf(context);

  /// 顶栏标题文字样式（16 / w600 / onSurface）。
  static TextStyle titleStyle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    );
  }

  /// 主 Tab 页列表内边距：左右 8、上 8、下按导航位置留白。
  ///
  /// [placement] 由调用方从 [MobileNavPlacementScope.of] 取（那是**必填**的依赖
  /// 来源：菜单栏位置变化时页面会重建）。底部形态让出 [kMobileNavClearance]；
  /// 左侧 / 右侧竖排导轨与内容并排、不遮挡内容，只留 [kMobileNavSideClearance]。
  static EdgeInsets mainListPadding({
    BuildContext? context,
    double top = 8,
    MobileNavPlacement placement = MobileNavPlacement.bottom,
  }) => EdgeInsets.fromLTRB(
    pagePaddingH,
    top,
    pagePaddingH,
    navClearanceFor(placement, context: context),
  );

  /// 主导航占据的纵向（底部）留白。
  static double navClearanceFor(
    MobileNavPlacement placement, {
    BuildContext? context,
  }) {
    if (placement != MobileNavPlacement.bottom) {
      return kMobileNavSideClearance;
    }
    return context == null
        ? kMobileNavClearance
        : mobileNavClearanceOf(context);
  }

  /// 二级页面列表内边距：左右 12、上 4、下 24。
  static EdgeInsets subListPadding({double top = 4, double bottom = 24}) =>
      EdgeInsets.fromLTRB(subPagePaddingH, top, subPagePaddingH, bottom);
}
