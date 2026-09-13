import 'package:flutter/material.dart';

import '../platform/app_platform.dart';

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
///   搜索时整体淡出缩放，同一颗搜索药丸从 44px「变长」到 200px 并水平居中。
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
  static const double barInsetH = 8;
  /// 顶栏距安全区上沿
  static const double barInsetTop = 6;
  /// 顶栏底部留白
  static const double barInsetBottom = 6;

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

  /// 内容区从顶栏下方开始的额外留白：
  /// 顶栏内容高度（44）+ 上 6 + 下 6 ≈ 56，取整 60 作为滚动内容起点偏移。
  static const double contentTop = 60;

  /// 主 Tab 页滚动内容左右内边距（项目 / 队列 / 配置库 / 设置）
  static const double pagePaddingH = 8;
  /// 二级页面滚动内容左右内边距（命令 / 日志 / 容器 / AI 等）
  static const double subPagePaddingH = 12;

  /// 主 Tab 页滚动内容起始顶部偏移（安全区 + 顶栏高度）。
  static double pageTopPadding(BuildContext context) =>
      MediaQuery.of(context).padding.top + contentTop;

  /// 顶栏标题文字样式（16 / w600 / onSurface）。
  static TextStyle titleStyle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    );
  }

  /// 主 Tab 页列表内边距：左右 8、上 8、下让出悬浮底部导航。
  static EdgeInsets mainListPadding({double top = 8}) =>
      EdgeInsets.fromLTRB(pagePaddingH, top, pagePaddingH, kMobileNavClearance);

  /// 二级页面列表内边距：左右 12、上 4、下 24。
  static EdgeInsets subListPadding({double top = 4, double bottom = 24}) =>
      EdgeInsets.fromLTRB(subPagePaddingH, top, subPagePaddingH, bottom);
}
