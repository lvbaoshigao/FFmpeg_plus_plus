import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_text_scale.dart';
import '../theme/mobile_visual_theme.dart';
import 'liquid_glass_fallback.dart';
import '../platform/app_platform.dart';
import 'selection_highlight.dart';

/// 统一的「菜单栏选项」控件 —— 融合两处参考样式：
/// * 触发按钮：设置→任务卡片下拉菜单的外观（圆角描边、紧凑高度、展开/收起动画）；
/// * 行内选中段：使用全局选中材质；浮层列表保留轻底色与尾部对勾。
///
/// 两种形态（同一组件，按 [expandable] 切换）：
/// * expandable: false —— 行内分段药丸（替代 SegmentedButton），适合 2~4 个短选项；
/// * expandable: true  —— 一个按钮，点开在 Overlay 上展开选项列表
///   （替代 DropdownMenu / RadioListTile 单选组），选中即回调并收起。
///
/// 浮层动效（用户要求「缩放展开」而不是老式下拉）：
/// 面板从锚点角 0.97 → 1.0 缩放，200ms easeOutCubic，收起 160ms 反向
/// （无回弹过冲）。条目为现代菜单行：尾部对勾 + 微弱底色，不做药丸填充。
class OptionItem<T> {
  final T value;
  final String label;
  final String? subtitle;
  final String? groupLabel;
  final IconData? icon;

  /// 自定义前置控件（品牌 SVG logo 之类）—— 有它时优先于 [icon]。
  final Widget? leading;

  /// 危险操作（删除等）：文字/图标用 error 色。
  final bool danger;

  /// 额外的搜索关键词（label/subtitle 之外，例如英文名、别名）。
  final String? keywords;

  /// 条目文字颜色（null = 跟随主题的 onSurfaceVariant；选中时仍用主题色）。
  /// 供「硬编编码器标紫 / 软编标灰」这类语义分组使用。
  final Color? textColor;

  /// 条目文字字重（null = 跟随主题 bodyMedium；选中时仍加粗）。
  final FontWeight? fontWeight;

  const OptionItem(
    this.value,
    this.label, {
    this.subtitle,
    this.groupLabel,
    this.icon,
    this.leading,
    this.danger = false,
    this.keywords,
    this.textColor,
    this.fontWeight,
  });

  /// 搜索匹配：忽略空格/连字符/下划线/点/斜杠/冒号，避免
  /// 「deepseek chat」搜不到「deepseek-chat」。
  bool matchesQuery(String query) {
    final needle = _normalizeForSearch(query);
    if (needle.isEmpty) return true;
    return _normalizeForSearch(label).contains(needle) ||
        _normalizeForSearch(subtitle ?? '').contains(needle) ||
        _normalizeForSearch(groupLabel ?? '').contains(needle) ||
        _normalizeForSearch(keywords ?? '').contains(needle);
  }
}

final _searchSeparators = RegExp(r'[\s\-_./:（）()]');

String _normalizeForSearch(String value) =>
    value.toLowerCase().replaceAll(_searchSeparators, '');

/// 菜单面板的**有效**圆角：面板本身与列表里的选中/高亮行必须共用它，
/// 否则「菜单 20~22、行高亮 8」两套圆角在玻璃档下会明显不一致。
///
/// 移动端玻璃档会把圆角抬到至少 22（液态 / 毛玻璃 / 高光三档，且非高对比）；
/// 其余情况（桌面端、主题 / 灰色实色、高对比）保持调用方给的 base。
double _effectiveMenuRadius(
  BuildContext context,
  String appearance,
  double base,
) {
  final glass =
      appearance == 'liquid' ||
      appearance == 'frosted' ||
      appearance == 'highlight';
  return isMobilePlatform && glass && !MediaQuery.highContrastOf(context)
      ? math.max(base, 22.0)
      : base;
}

/// 浮层面板的公共外观。OptionMenuBar 与 ScaleMenuButton 共用，
/// 保证「所有下拉/弹出菜单」视觉统一。
///
/// 菜单用中性材质承托文字，主题色仅用于状态标记。
/// 液态档保留透射、方向性边缘光；毛玻璃偏哑光，高光档有柔和镜面。
Widget optionMenuPanel({
  required BuildContext context,
  required ColorScheme scheme,
  required Widget child,
  required String appearance,
  double radius = 14,
  GlassTuning tuning = const GlassTuning(),
  bool gpuGlass = false,
  // 展开 / 收起动画进行中传 false：动画帧里不跑实时背景模糊 / shader，
  // 只画着色底（缩放 + 每帧重采样背景是下拉菜单掉帧的主因）；落定后恢复。
  bool liveGlass = true,
}) {
  final dark = scheme.brightness == Brightness.dark;
  final mobile = isMobilePlatform;
  final highContrast = MediaQuery.highContrastOf(context);
  final effectsReduced = mobile && mobileGlassEffectsReducedOf(context);
  final liquid = appearance == 'liquid';
  final frosted = appearance == 'frosted';
  final highlight = appearance == 'highlight';
  final glass = liquid || frosted || highlight;
  final neutral = neutralGray(scheme.surface);
  // Tinted Glass Menu：浅色用盐雾白 #EFF5F2（暖白 / 灰绿），深色用中性烟灰；
  // 主题色只留给选中标记，菜单文字始终是墨色 / onSurface。
  // 以下「着色玻璃菜单」调整仅作用于移动端；桌面端保持原有外观。
  final menuTint = mobile && !dark ? const Color(0xFFEFF5F2) : neutral;
  // 菜单与浮层圆角 22–28；纯色 / 高对比保持调用方给的圆角。
  // 与列表行高亮圆角同一来源，见 [_effectiveMenuRadius]。
  final menuRadius = _effectiveMenuRadius(context, appearance, radius);
  final baseSigma = liquid
      ? tunedGlassSigma(mobile ? 10 : 6, tuning)
      : tunedGlassSigma(frosted ? 8 : (highlight ? 4 : 0), tuning);
  final sigma = highContrast || effectsReduced || !liveGlass
      ? 0.0
      : mobile
      ? mobileGlassSigma(baseSigma)
      : baseSigma;
  final useGpuGlass = liveGlass && gpuGlass && !highContrast && !effectsReduced;
  // 菜单比悬浮药丸更不透明（规范 Tinted glass ≈ 0.86），短标签在任意背景上
  // 都清楚；旧 liquid 0.42 / 0.50 会让背后的文字透进菜单。
  final baseFill = mobile
      ? (liquid
            ? menuTint.withAlpha(tunedGlassAlpha(dark ? 196 : 219, tuning))
            : frosted
            ? menuTint.withAlpha(tunedGlassAlpha(dark ? 216 : 228, tuning))
            : highlight
            ? menuTint.withAlpha(tunedGlassAlpha(dark ? 176 : 190, tuning))
            : appearance == 'gray'
            ? neutral
            : scheme.surface)
      : liquid
      ? neutral.withAlpha(tunedGlassAlpha(dark ? 108 : 128, tuning))
      : frosted
      ? Color.lerp(
          neutral,
          harmonizedAccent(scheme, 0.7),
          0.12,
        )!.withAlpha(tunedGlassAlpha(dark ? 216 : 228, tuning))
      : highlight
      ? neutral.withAlpha(tunedGlassAlpha(dark ? 176 : 190, tuning))
      : appearance == 'gray'
      ? neutral
      : scheme.surface;
  final restingFill = mobile && glass
      ? baseFill.withValues(
          alpha: effectsReduced ? 1 : math.max(baseFill.a, 0.86),
        )
      : glass && highContrast
      ? neutral
      : baseFill;
  // 动画帧没有背景模糊：桌面低浓度玻璃临时加浓，避免背后文字清晰透出。
  final fill = !liveGlass && glass && !mobile
      ? restingFill.withValues(alpha: math.max(restingFill.a, 0.62))
      : restingFill;
  final r = BorderRadius.circular(menuRadius);
  final light = tuning.highlight.clamp(0.0, 1.6);
  final position = tuning.lightPos.clamp(0.0, 1.0);
  final lightAngle = -3 * math.pi / 4 + position * math.pi;
  final begin = Alignment(math.cos(lightAngle), math.sin(lightAngle));
  final end = Alignment(-begin.x, -begin.y);
  // 斜向光泽本来就只画在桌面端，桌面外观不变。
  final sheen = !mobile && (liquid || highlight)
      ? LinearGradient(
          begin: begin,
          end: end,
          colors: [
            Colors.white.withValues(alpha: (highlight ? 0.22 : 0.14) * light),
            Colors.white.withValues(alpha: 0.015 * light),
            Colors.transparent,
            Colors.white.withValues(alpha: 0.04 * light),
          ],
          stops: const [0, 0.24, 0.72, 1],
        )
      : null;
  // Material is the tint layer and ink host; the rim never paints over text.
  Widget panel = Material(
    color: useGpuGlass && liquid ? Colors.transparent : fill,
    child: DecoratedBox(
      decoration: BoxDecoration(gradient: sheen),
      child: CustomPaint(
        foregroundPainter: _MenuRimPainter(
          radius: menuRadius,
          topGlint: mobile,
          glass: glass,
          highContrast: highContrast,
          color: highContrast
              ? scheme.onSurface
              : (glass ? Colors.white : scheme.outlineVariant),
          strength: highContrast
              ? 1
              : (glass ? tuning.edge.clamp(0.0, 2.0) : 1),
          begin: begin,
          end: end,
        ),
        child: child,
      ),
    ),
  );
  if (useGpuGlass && liquid) {
    panel = OCLiquidGlassGroup(
      settings: liquidGlassSettingsFor(tuning),
      child: OCLiquidGlass(borderRadius: menuRadius, color: fill, child: panel),
    );
  } else if (liquid && mobile) {
    if (sigma > 0) {
      panel = ClipRRect(
        borderRadius: r,
        child: BackdropFilter(filter: cachedGlassBlur(sigma), child: panel),
      );
    }
  } else if (liquid && liveGlass) {
    panel = LiquidGlassBackdrop(
      borderRadius: r,
      sigma: sigma,
      tuning: tuning,
      child: panel,
    );
  } else if (sigma > 0) {
    panel = BackdropFilter(filter: cachedGlassBlur(sigma), child: panel);
  }
  return DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: r,
      boxShadow: [
        // Transient panel：0 16px 40px rgba(19,37,41,0.18)；深色场景加深。
        BoxShadow(
          color: glass && mobile
              ? (dark
                    ? Colors.black.withValues(alpha: 0.32)
                    : const Color(0xFF132529).withValues(alpha: 0.18))
              : Colors.black.withValues(alpha: dark ? 0.20 : 0.10),
          blurRadius: glass ? (mobile ? 40 : 24) : 16,
          spreadRadius: glass && mobile ? -6 : -4,
          offset: Offset(0, glass && mobile ? 16 : 8),
        ),
      ],
    ),
    child: ClipRRect(borderRadius: r, child: panel),
  );
}

/// The reflected edge is directional, rather than an opaque black/color frame.
class _MenuRimPainter extends CustomPainter {
  const _MenuRimPainter({
    required this.radius,
    required this.glass,
    this.topGlint = false,
    required this.highContrast,
    required this.color,
    required this.strength,
    required this.begin,
    required this.end,
  });
  final double radius;
  final bool glass;

  /// 移动端：只在顶部留一条细高光；桌面端保持原来的方向性整圈边缘光。
  final bool topGlint;
  final bool highContrast;
  final Color color;
  final double strength;
  final Alignment begin;
  final Alignment end;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strength <= 0) return;
    final rect = (Offset.zero & size).deflate(0.5);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 1.5 : (glass ? 0.85 : 0.6);
    if (highContrast) {
      paint.color = color;
    } else if (glass && !topGlint) {
      paint.shader = LinearGradient(
        begin: begin,
        end: end,
        colors: [
          color.withValues(alpha: (0.48 * strength).clamp(0.0, 0.9)),
          color.withValues(alpha: 0.035 * strength),
          color.withValues(alpha: 0.24 * strength),
        ],
        stops: const [0, 0.48, 1],
      ).createShader(rect);
    } else if (glass) {
      // 顶部一条细高光（inset 0 1px 0 rgba(255,255,255,0.78)），沿圆角淡出；
      // 两侧与底部只留极淡的结构边，避免整圈发光框。
      final fade = size.height <= 0
          ? 0.2
          : (radius / size.height).clamp(0.08, 0.45);
      paint.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: (0.78 * strength).clamp(0.0, 0.9)),
          color.withValues(alpha: 0.10 * strength),
          color.withValues(alpha: 0.06 * strength),
        ],
        stops: [0, fade, 1],
      ).createShader(rect);
    } else {
      paint.color = color.withValues(alpha: 0.32);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(math.max(0, radius - 0.5))),
      paint,
    );
  }

  @override
  bool shouldRepaint(_MenuRimPainter old) =>
      old.radius != radius ||
      old.glass != glass ||
      old.topGlint != topGlint ||
      old.highContrast != highContrast ||
      old.color != color ||
      old.strength != strength ||
      old.begin != begin ||
      old.end != end;
}

/// 展开列表行（菜单模式条目）—— 设置页左侧主菜单条目的同款动画。
///
/// [highlighted] 只在键盘导航时生效（鼠标用户看到的样式与以前完全一致）。
/// [OptionItem.icon] 为 null 时**不占位**：旧实现用 Icons.circle_outlined 兜底，
/// 导致「模型选择框左边一直有个圆圈」（用户反馈），这里彻底去掉兜底图标。
Widget _optionRow<T>({
  required BuildContext context,
  required OptionItem<T> item,
  required bool selected,
  required bool highlighted,
  required VoidCallback onTap,
  required double menuRadius,
  int? labelMaxLines = 2,
}) {
  final scheme = Theme.of(context).colorScheme;
  final accent = item.danger ? scheme.error : scheme.primary;
  return Semantics(
    selected: selected,
    button: true,
    // 左右 margin 由调用方（列表项）加在 InkWell 外面：高亮底色、hover 与
    // 溅墨（InkWell）轮廓完全重合，不会出现「底色比水波窄 8px」的错位。
    child: InkWell(
      // 行高亮圆角与菜单面板圆角同一来源（_effectiveMenuRadius），
      // 不再写死 8 / 12 两个互不相同的值。
      borderRadius: BorderRadius.circular(menuRadius),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          // 现代菜单行范式（Notion / Ant / Headless）：整行微底色，不做药丸。
          // 选中靠尾部对勾 + 极淡主题色染，悬停/键盘高亮用中性微底色。
          borderRadius: BorderRadius.circular(menuRadius),
          color: selected
              ? scheme.onSurface.withAlpha(14)
              : (highlighted
                    ? scheme.onSurface.withAlpha(12)
                    : Colors.transparent),
        ),
        child: Row(
          children: [
            if (item.leading != null) ...[
              SizedBox(
                width: 20,
                height: 20,
                child: Center(child: item.leading!),
              ),
              const SizedBox(width: 10),
            ] else if (item.icon != null) ...[
              SizedBox(
                width: 20,
                height: 20,
                child: Icon(
                  item.icon,
                  size: 16,
                  color: item.danger ? scheme.error : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    maxLines: labelMaxLines,
                    softWrap: true,
                    overflow: labelMaxLines == null
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: _menuLabelStyle(context, item, selected),
                  ),
                  if (item.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.3,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Reserve the checkmark width so all labels wrap consistently.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, anim) =>
                  FadeTransition(opacity: anim, child: child),
              child: selected
                  ? Icon(
                      Icons.check_rounded,
                      key: const ValueKey('check'),
                      size: 16,
                      color: accent,
                    )
                  : const SizedBox(
                      width: 16,
                      height: 16,
                      key: ValueKey('none'),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

bool _sameOptionItems<T>(List<OptionItem<T>> a, List<OptionItem<T>> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x.value != y.value ||
        x.label != y.label ||
        x.subtitle != y.subtitle ||
        x.groupLabel != y.groupLabel ||
        x.icon != y.icon ||
        (x.leading == null) != (y.leading == null) ||
        x.danger != y.danger ||
        x.fontWeight != y.fontWeight ||
        x.textColor != y.textColor ||
        x.keywords != y.keywords) {
      return false;
    }
  }
  return true;
}

/// A variable-height, lazy list shared by selection and action menus.
/// Text extents are cached for this menu so keyboard jumps work off-screen too.
class _MenuOptionList<T> extends StatefulWidget {
  const _MenuOptionList({
    super.key,
    required this.items,
    required this.onPick,
    required this.menuRadius,
    this.selectedIndex = -1,
    this.highlightedIndex,
    this.labelMaxLines = 2,
    this.emptyLabel = '',
  });
  final List<OptionItem<T>> items;
  final ValueChanged<OptionItem<T>> onPick;
  final double menuRadius;
  final int selectedIndex;
  final int? highlightedIndex;
  final int? labelMaxLines;
  final String emptyLabel;

  @override
  State<_MenuOptionList<T>> createState() => _MenuOptionListState<T>();
}

class _MenuOptionListState<T> extends State<_MenuOptionList<T>> {
  final _scroll = ScrollController();
  int _revealSerial = 0;
  final Map<int, double> _heights = {};
  double _width = 0;
  TextScaler? _scaler;
  TextStyle? _baseStyle;
  TextDirection? _direction;
  (bool, double?, double?, double?, Locale?, TextHeightBehavior?)?
  _textOverrides;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _MenuOptionList<T> old) {
    super.didUpdateWidget(old);
    final itemsChanged = !_sameOptionItems(old.items, widget.items);
    if (itemsChanged ||
        old.labelMaxLines != widget.labelMaxLines ||
        old.selectedIndex != widget.selectedIndex) {
      _heights.clear();
    }
    final changed = old.highlightedIndex != widget.highlightedIndex;
    if (changed || itemsChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final index = widget.highlightedIndex;
        if (index != null) {
          reveal(index);
        } else if (itemsChanged && _scroll.hasClients) {
          _scroll.jumpTo(0);
        }
      });
    }
  }

  bool _startsGroup(int index) =>
      widget.items[index].groupLabel != null &&
      (index == 0 ||
          widget.items[index - 1].groupLabel != widget.items[index].groupLabel);

  double _textHeight(
    String text,
    TextStyle style,
    double width,
    int? maxLines,
  ) {
    final overrides = _textOverrides!;
    final effective = _baseStyle!
        .merge(style)
        .merge(
          TextStyle(
            fontWeight: overrides.$1 ? FontWeight.bold : null,
            height: overrides.$2,
            letterSpacing: overrides.$3,
            wordSpacing: overrides.$4,
          ),
        );
    final painter = TextPainter(
      text: TextSpan(text: text, style: effective),
      textDirection: _direction!,
      textScaler: _scaler!,
      locale: overrides.$5,
      textHeightBehavior: overrides.$6,
      maxLines: maxLines,
    )..layout(maxWidth: math.max(1, width));
    final height = painter.height;
    painter.dispose();
    return height;
  }

  double _groupHeight(int index) => !_startsGroup(index)
      ? 0
      : 12 +
            _textHeight(
              widget.items[index].groupLabel!,
              const TextStyle(
                fontSize: 10.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
              ),
              _width - 24,
              1,
            );

  double _height(int index) => _heights.putIfAbsent(index, () {
    final item = widget.items[index];
    final hasIcon = item.icon != null || item.leading != null;
    final available = _width - 54 - (hasIcon ? 30 : 0);
    final style = _menuLabelStyle(context, item, index == widget.selectedIndex);
    var textHeight = _textHeight(
      item.label,
      style,
      available,
      widget.labelMaxLines,
    );
    if (item.subtitle != null) {
      textHeight +=
          2 +
          _textHeight(
            item.subtitle!,
            const TextStyle(fontSize: 10, height: 1.3),
            available,
            1,
          );
    }
    // 移动端菜单行至少 44px 可触高度（规范 menu rows ≥ 44px）。
    final minRow = isMobilePlatform ? 44.0 : 38.0;
    return _groupHeight(index) +
        math.max(minRow, textHeight + 16).ceilToDouble();
  });

  void reveal(int index) {
    if (!_scroll.hasClients ||
        index < 0 ||
        index >= widget.items.length ||
        _width <= 0) {
      return;
    }
    var top = 4.0;
    for (var i = 0; i < index; i++) {
      top += _height(i);
    }
    final bottom = top + _height(index);
    final position = _scroll.position;
    final offset =
        _height(index) > position.viewportDimension || top < position.pixels
        ? top
        : bottom > position.pixels + position.viewportDimension
        ? bottom - position.viewportDimension
        : position.pixels;
    final target = math.max(0.0, offset);
    final serial = ++_revealSerial;
    // maxScrollExtent is only an average-based estimate before these variable
    // rows have been laid out. Clamping to it can strand a late selected model.
    // Our measured prefix is an exact offset; let the sliver lay out that target.
    _scroll.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || serial != _revealSerial || !_scroll.hasClients) return;
      // Cancel any ballistic correction created using the old estimated range.
      // Target rows now supply the refreshed scroll metrics.
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final base = DefaultTextStyle.of(context).style;
      final direction = Directionality.of(context);
      final overrides = (
        MediaQuery.boldTextOf(context),
        MediaQuery.maybeLineHeightScaleFactorOverrideOf(context),
        MediaQuery.maybeLetterSpacingOverrideOf(context),
        MediaQuery.maybeWordSpacingOverrideOf(context),
        Localizations.maybeLocaleOf(context),
        DefaultTextStyle.of(context).textHeightBehavior ??
            DefaultTextHeightBehavior.maybeOf(context),
      );
      if (_width != constraints.maxWidth ||
          _textOverrides != overrides ||
          _scaler != scaler ||
          _baseStyle != base ||
          _direction != direction) {
        _heights.clear();
        _width = constraints.maxWidth;
        _scaler = scaler;
        _baseStyle = base;
        _direction = direction;
        _textOverrides = overrides;
      }
      final empty = widget.items.isEmpty;
      return ListView.builder(
        controller: _scroll,
        shrinkWrap: true,
        primary: false,
        padding: const EdgeInsets.symmetric(vertical: 4),
        scrollCacheExtent: const ScrollCacheExtent.pixels(80),
        itemCount: empty ? 1 : widget.items.length,
        // Extents are text-aware; a long identifier never gets a fixed row height.
        itemExtentBuilder: empty ? null : (i, _) => _height(i),
        itemBuilder: (context, row) {
          if (empty) {
            return Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                widget.emptyLabel,
                style: const TextStyle(fontSize: 12),
              ),
            );
          }
          final i = row;
          final item = widget.items[i];
          return SizedBox(
            height: _height(i),
            child: Column(
              children: [
                if (_startsGroup(i))
                  SizedBox(
                    height: _groupHeight(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          item.groupLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    child: _optionRow<T>(
                      context: context,
                      item: item,
                      selected: i == widget.selectedIndex,
                      highlighted: i == widget.highlightedIndex,
                      menuRadius: widget.menuRadius,
                      labelMaxLines: widget.labelMaxLines,
                      onTap: () => widget.onPick(item),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

TextStyle _menuLabelStyle<T>(
  BuildContext context,
  OptionItem<T> item,
  bool selected,
) {
  final scheme = Theme.of(context).colorScheme;
  return TextStyle(
    fontSize: 12.5,
    height: 1.35,
    fontWeight: selected
        ? FontWeight.w600
        : (item.fontWeight ??
              Theme.of(context).textTheme.bodyMedium?.fontWeight ??
              FontWeight.w400),
    color: item.danger ? scheme.error : (item.textColor ?? scheme.onSurface),
  );
}

class OptionMenuBar<T> extends StatefulWidget {
  final List<OptionItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;

  /// expandable（按钮+展开列表）模式：触发按钮左侧的说明文字（可空）
  final String? label;
  final IconData? leadingIcon;

  /// 触发按钮上的自定义前置控件（例如当前模型对应的品牌 SVG logo）。
  final Widget? leadingWidget;

  /// false = 行内分段药丸；true = 按钮 + 展开选项列表
  final bool expandable;
  final double triggerHeight;

  /// 浮层内显示搜索框（条目多时用，例如模型列表）。
  ///
  /// 只对「条目多 / 名称长」的菜单开启；2~4 个短选项的菜单不加搜索框
  /// （用户要求：选项少的下拉菜单不要搜索框）。
  final bool searchable;
  final String? searchHint;

  /// 搜索无结果时的提示文案（null = 中文默认「无匹配项」）。
  ///
  /// 共享控件不写死语言：英文界面由调用点传 "No matches"。
  final String? emptyLabel;

  /// 浮层固定宽度（null = 跟随触发按钮宽度）。
  ///
  /// 模型选择这类「触发按钮很窄、条目很长」的场景传 320~360，
  /// 让长模型名不再被 200px 截断成省略号。
  final double? menuWidth;

  /// Null allows full wrapping, useful for long model identifiers.
  final int? itemLabelMaxLines;
  final int triggerMaxLines;

  const OptionMenuBar({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.label,
    this.leadingIcon,
    this.leadingWidget,
    this.expandable = true,
    this.triggerHeight = 38,
    this.searchable = false,
    this.searchHint,
    this.emptyLabel,
    this.menuWidth,
    this.itemLabelMaxLines = 2,
    this.triggerMaxLines = 1,
  });

  @override
  State<OptionMenuBar<T>> createState() => _OptionMenuBarState<T>();
}

class _OptionMenuBarState<T> extends State<OptionMenuBar<T>>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  /// 浮层控制器：展开的选项列表挂在 Overlay 上（不参与宿主卡的布局）。
  final OverlayPortalController _portal = OverlayPortalController();

  /// 触发按钮与浮层之间的定位链接（滚动时浮层自动跟随按钮）。
  final LayerLink _link = LayerLink();

  /// 触发按钮宽度：浮层与按钮等宽（由 LayoutBuilder 写入）。
  double _triggerWidth = 200;

  String _dropdownAppearance = 'theme';

  /// 键盘高亮项下标（null = 还没开始键盘导航，例如纯鼠标打开）。
  int? _highlightIndex;

  /// 搜索关键字（仅 OptionMenuBar.searchable 生效）。
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  final _listKey = GlobalKey<_MenuOptionListState<T>>();

  /// 浮层从锚点方向缩放，200ms；文字不做额外的离屏透明度动画。
  ///
  /// 必须是 late final + 在 initState 里赋值：若写成 late final ... =
  /// AnimationController(...) 的惰性初始化，从未展开过的实例会在 dispose
  /// 里才第一次建 Ticker —— 那时 element 已 defunct，
  /// TickerMode.getNotifier(context) 的 dependOnInheritedWidgetOfExactType
  /// 会直接抛断言。
  late final AnimationController _ovCtrl;

  /// Keep one curve for this state; transforms animate without rebuilding rows.
  late final CurvedAnimation _ovCurve;
  late final Animation<double> _ovScale;

  /// 浮层收起动画结束后再真正卸载的宽限时长（略大于 reverseDuration，
  /// 否则尾帧会被 `_portal.hide()` 截断）。
  static const Duration _overlayHideDelay = Duration(milliseconds: 200);

  static const Duration _overlayOpenDuration = Duration(milliseconds: 200);
  static const Duration _overlayCloseDuration = Duration(milliseconds: 160);

  @override
  void initState() {
    super.initState();
    _ovCtrl = AnimationController(
      vsync: this,
      duration: _overlayOpenDuration,
      reverseDuration: _overlayCloseDuration,
    );
    _ovCurve = CurvedAnimation(
      parent: _ovCtrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _ovScale = Tween<double>(begin: 0.97, end: 1.0).animate(_ovCurve);
    _ovCtrl.addStatusListener(_onOverlayStatus);
  }

  /// 动画落定（完全展开）才开启实时玻璃，见 optionMenuPanel(liveGlass:)。
  final ValueNotifier<bool> _ovSettled = ValueNotifier<bool>(false);

  /// 落定时玻璃层结构会变（加 / 去 BackdropFilter）：用 GlobalKey 把内容整体
  /// 搬过去，列表滚动位置与搜索框焦点不丢。
  final GlobalKey _ovContentKey = GlobalKey();

  void _onOverlayStatus(AnimationStatus status) {
    _ovSettled.value = status == AnimationStatus.completed;
  }

  @override
  void didUpdateWidget(covariant OptionMenuBar<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部改掉选中值 -> 重置键盘高亮，否则 ↑/↓ 会从旧下标继续走。
    // 旧方案是让调用点把 value 塞进 ValueKey 强制重建 State
    // （ai_settings_mobile 的 _AiDropdown），代价是收起动画中途被卸载。
    if (widget.value != oldWidget.value) _highlightIndex = null;
  }

  @override
  void dispose() {
    _ovCurve.dispose();
    _ovCtrl.dispose();
    _ovSettled.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  String? _filteredQuery;
  List<OptionItem<T>>? _filteredSource;
  List<OptionItem<T>> _filteredItems = [];

  /// Search only when the query or source changes, not on each arrow key.
  List<OptionItem<T>> get _visibleItems {
    if (!widget.searchable || _query.trim().isEmpty) return widget.items;
    if (_filteredQuery != _query ||
        (_filteredSource == null ||
            !_sameOptionItems(_filteredSource!, widget.items))) {
      _filteredQuery = _query;
      _filteredSource = widget.items;
      _filteredItems = widget.items
          .where((it) => it.matchesQuery(_query))
          .toList();
    }
    return _filteredItems;
  }

  /// 当前选中项下标（没有匹配项时为 -1）。
  int _selectedIndex([List<OptionItem<T>>? items]) =>
      (items ?? _visibleItems).indexWhere(_selected);

  /// 展开浮层（箭头旋转动画由 _expanded 驱动，浮层本身由 _ovCtrl 驱动）。
  void _open() {
    _portal.show();
    _query = '';
    _searchCtrl.clear();
    final items = _visibleItems;
    // 打开时不做键盘高亮（用户反馈「点击性质的选择框默认框住第一个」）：
    // 选中态已由对勾 + 微底色表达，预置高亮会「框住」一行造成误选错觉。
    // ↑/↓ 首次按下时才显示高亮（落在当前选中项上，见 _moveHighlight）。
    setState(() {
      _expanded = true;
      _highlightIndex = null;
    });
    _ovCtrl.forward(from: 0);
    // 选中项可能在滚动区之外：等浮层首帧布局完成后把它滚进可视区，
    // 否则长列表里看不到「现在选的是什么」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureSelectedVisible(items);
    });
  }

  /// 展开/收起浮层。
  ///
  /// 判定用 _expanded 而不是 _portal.isShowing：收起动画期间浮层仍在
  /// Overlay 上（等动画播完才 hide），此时用户再点一下应当「重新展开」，
  /// 而不是被当成第二次收起。
  void _toggle() {
    if (_expanded) {
      _close();
      return;
    }
    _open();
  }

  /// Lazy rows can be unmounted; reveal by measured extents instead of keys.
  void _ensureHighlightVisible() {
    final index = _highlightIndex;
    if (index != null) _listKey.currentState?.reveal(index);
  }

  void _ensureSelectedVisible(List<OptionItem<T>> items) {
    final index = _selectedIndex(items);
    if (index >= 0) _listKey.currentState?.reveal(index);
  }

  /// 收起（先播收起动画，动画结束才真正把浮层从 Overlay 上卸载）。
  void _close() {
    if (!mounted) return;
    if (_expanded || _highlightIndex != null) {
      setState(() {
        _expanded = false;
        _highlightIndex = null;
      });
    }
    if (!_portal.isShowing) {
      _resetSearch();
      return;
    }
    _ovCtrl.reverse();
    // 不用 TickerFuture.whenComplete：动画被打断（用户马上又点开）时
    // TickerFuture 会以 TickerCanceled 结束，未处理的错误会冒泡到 Zone。
    // 用一个延迟回调 + 状态复查，既能等到动画播完，又天然支持「打断」。
    Future.delayed(_overlayHideDelay, () {
      if (!mounted || _expanded) return; // 已被重新展开
      if (_portal.isShowing) _portal.hide();
      // 搜索词必须等收起动画播完再清：清得太早，浮层还在淡出，
      // 列表会从过滤结果闪回全量。
      _resetSearch();
    });
  }

  /// 清空搜索态。收起动画结束后调用；_open() 里也会重置一次。
  void _resetSearch() {
    if (!mounted) return;
    if (_query.isEmpty && _highlightIndex == null) return;
    setState(() {
      _query = '';
      _highlightIndex = null;
    });
    _searchCtrl.clear();
  }

  /// PC 键盘导航：↑/↓ 移动高亮、Enter/Space 选中、Esc 关闭。
  ///
  /// Esc 必须返回 handled：否则按键会继续冒泡到 App 级的 DismissIntent，
  /// 把整个设置子页/对话框关掉，而不是只关这个浮层。
  KeyEventResult _onPanelKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    // 搜索模式下 Enter / Space 归搜索框：Space 是普通字符（要能打出
    // "deepseek chat" 这种带空格的词），Enter 交给 TextField.onSubmitted
    // 选中高亮项。这里必须放行 —— 面板的 Focus 是搜索框的**祖先**，而
    // 按键派发是「叶子 → 根」，不放行就会比 IME 更早吃掉按键：
    //   * Space → 静默选中第一条搜索结果并收起菜单；
    //   * Enter → 先按高亮项选中一次，再被 onSubmitted 用「清空过滤后的
    //     首项」覆盖一次，配置被改两次且最终值不是搜到的那条。
    if (widget.searchable &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.space)) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      final items = _visibleItems;
      final index = _highlightIndex;
      if (items.isEmpty) return KeyEventResult.handled;
      // 无高亮时回退到「当前选中项」而不是第 0 项 —— 用户反馈
      //「选择框默认框住第一个」：打开菜单直接回车不应误选首项。
      final fallback = _selectedIndex(items);
      _pick(
        items[(index == null || index < 0 || index >= items.length)
            ? (fallback >= 0 ? fallback : 0)
            : index],
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 移动键盘高亮；首次按键只把高亮显示出来（落在选中项上）。
  void _moveHighlight(int delta) {
    final items = _visibleItems;
    final count = items.length;
    if (count == 0) return;
    final selected = _selectedIndex(items);
    // 没有选中项时：↓ 从首项开始，↑ 从末项开始
    final start = selected >= 0 ? selected : (delta > 0 ? 0 : count - 1);
    final next = _highlightIndex == null
        ? start
        : (((_highlightIndex! + delta) % count) + count) % count;
    setState(() => _highlightIndex = next);
    // 高亮行可能在滚动区之外：等这一帧布局完成再把它滚进可视区。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureHighlightVisible();
    });
  }

  bool _selected(OptionItem<T> it) => it.value == widget.value;

  void _pick(OptionItem<T> it) {
    if (_selected(it)) {
      if (widget.expandable) _close();
      return;
    }
    widget.onChanged(it.value);
    if (widget.expandable) _close();
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅真正影响渲染的那个字段。
    //
    // 旧写法 `context.watch<AppState?>()` 是全量订阅：选中一项 -> onChanged ->
    // updateConfig -> notifyListeners，触发器与已经在场的浮层会一起重建，
    // 玻璃表面跟着重新采样 —— 视觉上就是「点一下闪一下」。
    _dropdownAppearance = context.select<AppState?, String>(
      (s) => s?.config.dropdownAppearance ?? 'theme',
    );
    // 「字体大小的调整不要应用于选项文字」（用户要求）：下拉按钮与分段药丸的宽度
    // 是固定的（设置页 _kMenuWidth = 116），字号一大框内文字就只剩省略号，
    // 而且「选中了什么」本身也会被字号变化搅乱。整棵控件退回到「只跟系统字号」：
    // 系统字体大小设置照旧生效（见 theme/app_text_scale.dart）。
    return withoutAppTextScale(context, Builder(builder: _buildControl));
  }

  Widget _buildControl(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = widget.items.where(_selected).firstOrNull;
    final trigger = BoxDecoration(
      color: neutralGray(scheme.surfaceContainerHighest).withAlpha(100),
      borderRadius: BorderRadius.circular(12),
    );

    if (!widget.expandable) {
      // ── 行内分段药丸：共享选中材质，2~4 个短选项 ──
      return Container(
        decoration: trigger.copyWith(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < widget.items.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Expanded(child: _pill(context, widget.items[i], compact: true)),
            ],
          ],
        ),
      );
    }

    // ── 按钮 + 浮层选项列表 ──
    //
    // 展开的选项列表不再用 AnimatedSize 在**行内**撑开（那会把宿主卡片一起撑高），
    // 而是用 OverlayPortal 弹出一层浮层 —— 宿主卡片高度在展开/收起时完全不变。
    // 浮层用 CompositedTransformFollower 绑定触发按钮：滚动时自动跟随，
    // 点浮层外 / Esc / 选中某项都会关闭；下方空间不足时自动向上弹出。
    return LayoutBuilder(
      builder: (context, cons) {
        _triggerWidth = cons.maxWidth.isFinite ? cons.maxWidth : 200;
        return CompositedTransformTarget(
          link: _link,
          child: OverlayPortal(
            controller: _portal,
            overlayChildBuilder: _buildOverlay,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                // Inherit the bounded soft press and keyboard focus from AppTheme.
                onTap: _toggle,
                child: Container(
                  constraints: BoxConstraints(minHeight: widget.triggerHeight),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: trigger,
                  child: Row(
                    children: [
                      if (widget.leadingWidget != null) ...[
                        widget.leadingWidget!,
                        const SizedBox(width: 7),
                      ] else if (widget.leadingIcon != null) ...[
                        Icon(
                          widget.leadingIcon,
                          size: 15,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 7),
                      ],
                      if (widget.label != null) ...[
                        Flexible(
                          child: Text(
                            widget.label!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      // 当前值：独占全部剩余宽度（Expanded），不与任何 Spacer 平分。
                      //
                      // 旧写法是 [const Spacer(), Flexible(Text)]，两者 flex 都是 1，
                      // 剩余宽度被平分成两半 —— 文字只拿到一半，于是 132px 的框里
                      // 「跟随主题色（纯色）」被截成「跟随 ...」。这里没有 label 时
                      // 只有一个弹性子项，文字自然占满整行；箭头固定在右端。
                      Expanded(
                        child: Text(
                          current?.label ?? '',
                          maxLines: widget.triggerMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: current?.fontWeight ?? FontWeight.w500,
                            color: current?.textColor ?? scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // 展开时箭头旋转 180°，与设置页二级菜单同一动画语言
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          Icons.expand_more,
                          size: 16,
                          color: scheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 浮层宽度：显式 OptionMenuBar.menuWidth 优先（模型列表要更宽），
  /// 否则跟随触发按钮；两者都夹在「屏幕宽度 - 24」以内。
  double _panelWidth(BuildContext overlayContext) {
    final screenW = MediaQuery.sizeOf(overlayContext).width;
    final maxW = math.max(120.0, screenW - 24);
    if (widget.menuWidth != null) {
      return math.min(widget.menuWidth!, maxW);
    }
    // 浮层宽度与选择框一致（用户反馈「下拉菜单与选择框大小差异明显」）；
    // 只有可搜索列表需要更宽的下限放搜索框。
    final minW = math.min(widget.searchable ? 200.0 : 96.0, maxW);
    return _triggerWidth.clamp(minW, math.min(360.0, maxW));
  }

  /// 浮层水平平移量：锚点恒为「触发钮左缘」，浮层向右铺 menuWidth。
  ///
  /// 触发钮本身靠右时（移动端 AI 设置的下拉是右对齐、浮层 220~260 宽），
  /// 右缘会跑出屏幕，勾选标记与长文案被裁掉。这里把浮层整体左移到屏幕内：
  /// 只平移、不翻转锚点方向（翻转会改变「从哪个角放大」的观感）。
  double _panelDx(BuildContext overlayContext, double panelW) {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return 0;
    final left = ro.localToGlobal(Offset.zero).dx;
    final screenW = MediaQuery.sizeOf(overlayContext).width;
    const margin = 12.0;
    final overflow = left + panelW + margin - screenW;
    if (overflow <= 0) return 0;
    // 面板比「屏幕 - 左右边距」还宽时，最多推到贴左边距，别把左缘推出屏幕。
    return -math.min(overflow, math.max(0.0, left - margin));
  }

  /// 浮层选项列表：挂在 Overlay 上，因此**不会**撑高宿主卡片。
  /// 高度上限 320 可滚动；点面板外（全屏透明遮罩）/ Esc / 选中某项都会关闭。
  Widget _buildOverlay(BuildContext overlayContext) {
    final visual = MobileVisualTheme.of(overlayContext);
    final scheme = visual.applyTo(Theme.of(overlayContext)).colorScheme;
    final media = MediaQuery.of(overlayContext);
    final ro = context.findRenderObject();
    final hasBox = ro is RenderBox && ro.hasSize;
    final triggerTop = hasBox ? ro.localToGlobal(Offset.zero).dy : 0.0;
    final triggerBottom = triggerTop + (hasBox ? ro.size.height : 0.0);
    final safeTop = media.padding.top + 8;
    final safeBottom = math.max(
      safeTop,
      media.size.height -
          math.max(media.padding.bottom, media.viewInsets.bottom) -
          8,
    );
    final aboveEnd = (triggerTop - 4).clamp(safeTop, safeBottom);
    final belowStart = (triggerBottom + 4).clamp(safeTop, safeBottom);
    final above = aboveEnd - safeTop;
    final below = safeBottom - belowStart;
    final openUp = below < 320 && above > below;
    final maxHeight = math.min(320.0, openUp ? above : below);
    final panelDy = openUp ? aboveEnd - triggerTop : belowStart - triggerBottom;
    final items = _visibleItems;
    // Keep one search field in the same element position when the IME opens.
    // A separate, bounded scroll area prevents tiny viewports from overflowing.
    final searchHeight = math.min(
      maxHeight * 0.6,
      32 + 16 * AppTextScale.systemScaleOf(overlayContext),
    );
    final appearance = MediaQuery.highContrastOf(overlayContext)
        ? 'theme'
        : _dropdownAppearance;
    final menuRadius = _effectiveMenuRadius(
      overlayContext,
      appearance,
      visual.menuRadius,
    );
    final list = Builder(
      builder: (listContext) => _MenuOptionList<T>(
        key: _listKey,
        items: items,
        menuRadius: menuRadius,
        selectedIndex: _selectedIndex(items),
        highlightedIndex: _highlightIndex,
        labelMaxLines: widget.itemLabelMaxLines,
        emptyLabel: widget.emptyLabel ?? '无匹配项',
        onPick: _pick,
      ),
    );
    final tuning = glassTuningOf(overlayContext);
    final gpu = gpuGlassEnabledOf(overlayContext);
    final panel = ValueListenableBuilder<bool>(
      valueListenable: _ovSettled,
      builder: (context, settled, content) {
        final panel = optionMenuPanel(
          context: overlayContext,
          scheme: scheme,
          appearance: appearance,
          tuning: tuning,
          radius: visual.menuRadius,
          gpuGlass: gpu,
          liveGlass: settled,
          child: content!,
        );
        return settled ? panel : RepaintBoundary(child: panel);
      },
      child: RepaintBoundary(
        key: _ovContentKey,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.searchable)
                SizedBox(
                  height: searchHeight,
                  child: ClipRect(
                    child: SingleChildScrollView(
                      child: _buildSearchField(overlayContext, scheme),
                    ),
                  ),
                ),
              Flexible(child: list),
            ],
          ),
        ),
      ),
    );
    return Positioned.fill(
      // 浮层挂在 Overlay 上（不在宿主卡片里），同样要退回到「只跟系统字号」，
      // 否则展开后的选项列表字号会和触发按钮对不上。
      // 注意：MediaQuery 必须包在 Stack **里面** —— Positioned 必须是 Overlay
      // 那个 Stack 的直接子节点，中间夹一层会触发 ParentDataWidget 报错。
      child: withoutAppTextScale(
        overlayContext,
        Stack(
          children: [
            // 全屏透明遮罩：点浮层以外任意位置关闭。用 opaque 命中，
            // 避免误触到底层控件（与系统下拉菜单的行为一致）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: const SizedBox.expand(),
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: openUp ? Alignment.topLeft : Alignment.bottomLeft,
              followerAnchor: openUp ? Alignment.bottomLeft : Alignment.topLeft,
              offset: Offset(
                _panelDx(overlayContext, _panelWidth(overlayContext)),
                panelDy,
              ),
              child: Align(
                alignment: openUp ? Alignment.bottomLeft : Alignment.topLeft,
                child: SizedBox(
                  width: _panelWidth(overlayContext),
                  child: Focus(
                    // 搜索模式下焦点归搜索框，这里只负责 Esc / 方向键兜底
                    canRequestFocus: !widget.searchable,
                    autofocus: !widget.searchable,
                    // PC 键盘：↑/↓ 移动高亮、Enter/Space 选中、Esc 关闭
                    onKeyEvent: _onPanelKey,
                    // Transform a stable panel; no opacity layer around its filter.
                    child: ScaleTransition(
                      // 锚点与弹出方向一致：向下弹从左上角放大，向上弹从左下角放大
                      scale: _ovScale,
                      alignment: openUp
                          ? Alignment.bottomLeft
                          : Alignment.topLeft,
                      child: panel,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 浮层内的搜索框（仅条目多的菜单开启）。
  Widget _buildSearchField(BuildContext context, ColorScheme scheme) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(90)),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
      child: TextField(
        controller: _searchCtrl,
        autofocus: true,
        style: const TextStyle(fontSize: 12.5),
        cursorHeight: 15,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withAlpha(120),
          hintText: widget.searchHint ?? '搜索',
          hintStyle: TextStyle(fontSize: 12.5, color: scheme.outline),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 16,
            color: scheme.outline,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除',
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() {
                      _query = '';
                      _highlightIndex = 0;
                    });
                  },
                  icon: Icon(Icons.close_rounded, color: scheme.outline),
                ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 30,
            minHeight: 30,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          border: border,
          enabledBorder: border,
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.primary.withAlpha(140)),
          ),
        ),
        onChanged: (value) {
          setState(() {
            _query = value;
            _highlightIndex = 0;
          });
        },
        onSubmitted: (_) {
          // 收起后（Esc / 点遮罩 / 选中项）迟到的 IME 提交不应再改配置：
          // 此时 _query 已被清空，_visibleItems 是全量列表，会误选第一项。
          if (!_expanded) return;
          final items = _visibleItems;
          if (items.isEmpty) return;
          final index = _highlightIndex;
          _pick(
            items[(index == null || index < 0 || index >= items.length)
                ? 0
                : index],
          );
        },
      ),
    );
  }

  /// 行内药丸（bar 模式条目）
  Widget _pill(BuildContext context, OptionItem<T> it, {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selected(it);
    final weight =
        Theme.of(context).textTheme.bodyMedium?.fontWeight ?? FontWeight.w400;
    return Semantics(
      selected: sel,
      button: true,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: sel
                ? const SelectionHighlight(radius: 10)
                : const SizedBox.shrink(),
          ),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _pick(it),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 6 : 10,
                  vertical: compact ? 5 : 7,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (it.leading != null) ...[
                      it.leading!,
                      const SizedBox(width: 4),
                    ] else
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (child, anim) =>
                            FadeTransition(opacity: anim, child: child),
                        child: it.icon == null
                            ? const SizedBox.shrink()
                            : Icon(
                                it.icon,
                                key: ValueKey(
                                  it.value.toString() + sel.toString(),
                                ),
                                size: 14,
                                color: sel
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                      ),
                    if (it.icon != null) const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        it.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: sel
                              ? FontWeight.values[(weight.value ~/ 100).clamp(
                                  0,
                                  8,
                                )]
                              : weight,
                          color: sel ? scheme.primary : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 图标触发的「动作菜单」按钮 —— 替代 PopupMenuButton。
///
/// 为什么不用 PopupMenuButton：系统菜单是「瞬间弹出 + 直角 + 阴影」，在玻璃主题
/// 里显得古老（用户反馈「单个模型右边的更多选项展开样式仍旧过于古老」）。
/// 这里复用 OptionMenuBar 的浮层面板外观：同一套圆角、选中药丸、180ms
/// 缩放展开动画、danger 色，并且**不受** App 字体缩放影响。
///
/// 用法示例（伪代码）：
///   ScaleMenuButton（泛型 T）(
///     icon: Icons.more_vert,
///     tooltip: '更多操作',
///     items: [OptionItem(Action.use, '设为当前模型'), ...],
///     onSelected: (a) => handle(a),
///   )
class ScaleMenuButton<T> extends StatefulWidget {
  final IconData icon;
  final String? tooltip;
  final double iconSize;

  /// 触发按钮边长（默认 30，与 IconButton 视觉一致）。
  final double size;
  final List<OptionItem<T>> items;
  final ValueChanged<T> onSelected;

  /// 浮层宽度（null = 220）。
  final double? menuWidth;
  final EdgeInsetsGeometry padding;

  const ScaleMenuButton({
    super.key,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.tooltip,
    this.iconSize = 18,
    this.size = 30,
    this.menuWidth,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<ScaleMenuButton<T>> createState() => _ScaleMenuButtonState<T>();
}

class _ScaleMenuButtonState<T> extends State<ScaleMenuButton<T>>
    with SingleTickerProviderStateMixin {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  bool _expanded = false;

  /// 键盘高亮行下标（null = 还没开始键盘导航）。
  ///
  /// 被替换掉的 PopupMenuButton 支持 Esc / ↑↓ / Enter；这里补齐同样的能力，
  /// 否则键盘用户在菜单打开后只能靠鼠标点空白处关闭。
  int? _highlightIndex;
  late final AnimationController _ctrl;

  /// A single curve transforms the stable menu without rebuilding its rows.
  late final CurvedAnimation _mountCurve;
  late final Animation<double> _mountScale;

  static const Duration _hideDelay = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _mountCurve = CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _mountScale = Tween<double>(begin: 0.97, end: 1.0).animate(_mountCurve);
    _ctrl.addStatusListener(_onMountStatus);
  }

  /// 动画落定才开启实时玻璃（同 OptionMenuBar）。
  final ValueNotifier<bool> _settled = ValueNotifier<bool>(false);
  final GlobalKey _contentKey = GlobalKey();

  void _onMountStatus(AnimationStatus status) {
    _settled.value = status == AnimationStatus.completed;
  }

  @override
  void dispose() {
    _mountCurve.dispose();
    _ctrl.dispose();
    _settled.dispose();
    super.dispose();
  }

  void _open() {
    if (widget.items.isEmpty) return;
    _portal.show();
    setState(() {
      _expanded = true;
      // 不预置高亮：打开就「框住」第一行会被误读为已选中
      // （用户反馈「选择框默认框住第一个」）。↑/↓ 才显示高亮。
      _highlightIndex = null;
    });
    _ctrl.forward(from: 0);
  }

  /// PC 键盘：Esc 关闭、↑/↓ 移动高亮、Enter/Space 选中。
  KeyEventResult _onPanelKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final count = widget.items.length;
      if (count == 0) return KeyEventResult.handled;
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final next = _highlightIndex == null
          ? (delta > 0 ? 0 : count - 1)
          : (((_highlightIndex! + delta) % count) + count) % count;
      setState(() => _highlightIndex = next);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      final index = _highlightIndex;
      if (index == null || index < 0 || index >= widget.items.length) {
        return KeyEventResult.handled;
      }
      final item = widget.items[index];
      _close();
      widget.onSelected(item.value);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _close() {
    if (!mounted) return;
    if (_expanded || _highlightIndex != null) {
      setState(() {
        _expanded = false;
        _highlightIndex = null;
      });
    }
    if (!_portal.isShowing) return;
    _ctrl.reverse();
    Future.delayed(_hideDelay, () {
      if (!mounted || _expanded) return;
      if (_portal.isShowing) _portal.hide();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return withoutAppTextScale(
      context,
      CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _buildOverlay,
          child: Tooltip(
            message: widget.tooltip ?? '',
            waitDuration: const Duration(milliseconds: 500),
            child: InkWell(
              borderRadius: BorderRadius.circular(widget.size / 2),
              onTap: _expanded ? _close : _open,
              child: Padding(
                padding: widget.padding,
                child: SizedBox(
                  width: widget.size,
                  height: widget.size,
                  child: Center(
                    child: Icon(
                      widget.icon,
                      size: widget.iconSize,
                      color: _expanded
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _panelDx(BuildContext overlayContext, double panelW) {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return 0;
    final right = ro.localToGlobal(Offset.zero).dx + ro.size.width;
    final screenW = MediaQuery.sizeOf(overlayContext).width;
    const margin = 12.0;
    final needed = panelW + margin - right;
    if (needed <= 0) return 0;
    return math.min(needed, math.max(0.0, screenW - margin - right));
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final visual = MobileVisualTheme.of(overlayContext);
    final scheme = visual.applyTo(Theme.of(overlayContext)).colorScheme;
    final media = MediaQuery.of(overlayContext);
    final width = math.min(
      widget.menuWidth ?? 220.0,
      math.max(140.0, media.size.width - 24),
    );
    final ro = context.findRenderObject();
    final hasBox = ro is RenderBox && ro.hasSize;
    final triggerTop = hasBox ? ro.localToGlobal(Offset.zero).dy : 0.0;
    final triggerBottom = triggerTop + (hasBox ? ro.size.height : 0.0);
    final safeTop = media.padding.top + 8;
    final safeBottom = math.max(
      safeTop,
      media.size.height -
          math.max(media.padding.bottom, media.viewInsets.bottom) -
          8,
    );
    final aboveEnd = (triggerTop - 4).clamp(safeTop, safeBottom);
    final belowStart = (triggerBottom + 4).clamp(safeTop, safeBottom);
    final above = aboveEnd - safeTop;
    final below = safeBottom - belowStart;
    final openUp = below < 320 && above > below;
    final maxHeight = math.min(320.0, openUp ? above : below);
    final panelDy = openUp ? aboveEnd - triggerTop : belowStart - triggerBottom;
    final tuning = glassTuningOf(overlayContext);
    final appearance = MediaQuery.highContrastOf(overlayContext)
        ? 'theme'
        : overlayContext.select<AppState?, String>(
            (s) => s?.config.dropdownAppearance ?? 'theme',
          );
    final gpu = gpuGlassEnabledOf(overlayContext);
    final panel = ValueListenableBuilder<bool>(
      valueListenable: _settled,
      builder: (context, settled, content) {
        final panel = optionMenuPanel(
          context: overlayContext,
          scheme: scheme,
          tuning: tuning,
          radius: visual.menuRadius,
          appearance: appearance,
          gpuGlass: gpu,
          liveGlass: settled,
          child: content!,
        );
        return settled ? panel : RepaintBoundary(child: panel);
      },
      child: RepaintBoundary(
        key: _contentKey,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Builder(
            builder: (context) => _MenuOptionList<T>(
              items: widget.items,
              menuRadius: _effectiveMenuRadius(
                overlayContext,
                appearance,
                visual.menuRadius,
              ),
              highlightedIndex: _highlightIndex,
              onPick: (item) {
                _close();
                widget.onSelected(item.value);
              },
            ),
          ),
        ),
      ),
    );
    return Positioned.fill(
      child: withoutAppTextScale(
        overlayContext,
        Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: const SizedBox.expand(),
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: openUp ? Alignment.topRight : Alignment.bottomRight,
              followerAnchor: openUp
                  ? Alignment.bottomRight
                  : Alignment.topRight,
              offset: Offset(_panelDx(overlayContext, width), panelDy),
              child: Align(
                alignment: openUp ? Alignment.bottomRight : Alignment.topRight,
                child: SizedBox(
                  width: width,
                  // 玻璃本体不做 opacity 动画（同 OptionMenuBar）：只缩放，
                  // 内容保持稳定，避免每帧重建或离屏透明度层。
                  child: ScaleTransition(
                    scale: _mountScale,
                    alignment: openUp
                        ? Alignment.bottomRight
                        : Alignment.topRight,
                    child: Focus(
                      autofocus: true,
                      onKeyEvent: _onPanelKey,
                      child: panel,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
