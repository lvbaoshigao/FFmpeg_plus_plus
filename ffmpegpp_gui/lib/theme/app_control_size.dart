import 'package:flutter/material.dart';

/// 全应用「控件高度档位」令牌（桌面表单 / 移动表单 / 顶栏药丸共用）。
///
/// 存在的理由：改造前按钮高度散落成 28 / 30 / 32 / 34 / 36 / 40 / 42 / 44 七八档，
/// 同一张卡里并排就参差 —— 例如设置页 MCP 卡的「应用」按钮被 `SizedBox(height: 30)`
/// 压过，紧邻的输入框却是主题默认高度；移动端 AI 设置页同一页同时出现
/// 34 / 40 / 42 / 44 四档。这里固化成 4 档，并给出配套的 icon 尺寸 / 水平内边距 / 圆角。
///
/// 用法：
/// ```dart
/// FilledButton.icon(
///   style: AppControlSize.regular.buttonStyle(),
///   icon: Icon(Icons.refresh, size: AppControlSize.regular.iconSize),
///   label: const Text('应用'),
///   onPressed: onApply,
/// )
/// ```
///
/// 不要再写 `SizedBox(height: 30, child: FilledButton(...))` 这种压高度的写法：
/// 主题的 `filledButtonTheme` 带 `vertical: 12` 内边距，套一个 30 高的盒子会把内容
/// 顶出 / 裁掉，而且各处的 30 与 44 互不相等。要改高度请改这里的档位。
@immutable
class AppControlSize {
  const AppControlSize._(this.height, this.iconSize, this.padH, this.radius);

  /// 控件总高（px）。
  final double height;

  /// 控件内前置图标的尺寸（px）。
  final double iconSize;

  /// 水平内边距（px）。
  final double padH;

  /// 圆角半径（px）。
  final double radius;

  /// 紧凑：表格内联、次级动作（如设置页「更多选项」这类链接按钮）。
  static const AppControlSize compact = AppControlSize._(28, 14, 10, 8);

  /// 常规：顶栏药丸、桌面表单小按钮（如 MCP 卡的「应用」）。
  static const AppControlSize regular = AppControlSize._(32, 16, 12, 8);

  /// 舒适：移动端表单按钮、AI 面板的「批准 / 拒绝」。
  static const AppControlSize comfortable = AppControlSize._(36, 17, 14, 10);

  /// 大：全宽主行动按钮（如移动端 AI 设置页的「设为当前」）。
  static const AppControlSize large = AppControlSize._(44, 19, 18, 12);

  /// 表单行「标签列」的固定宽度。
  ///
  /// 够放「监听地址:」/「Bind host:」这类最长的标签；中英文切换、行与行之间
  /// 标签宽度不一致时，下面输入框的左边缘会跟着错开 —— 固定住才不会。
  /// 桌面设置页与移动端 AI 设置页共用同一个值。
  static const double labelW = 76;

  /// 表单行「动作列」的固定宽度。
  ///
  /// 够放「应用」/「Apply」；固定住可避免语言切换或按钮文案变长时整行重排。
  static const double actionW = 84;

  /// 映射成 Filled / Outlined / Text 通用的 [ButtonStyle]。
  ///
  /// 三处关键覆盖（缺一个就会与主题打架）：
  /// * `minimumSize` 撑起档位高度 —— 用样式而不是 `SizedBox` 压高度；
  /// * `vertical` 内边距归零，避免与主题的 `v12` 叠加把按钮撑高；
  /// * `tapTargetSize: shrinkWrap`，否则 Material 的 48×48 最小点击框会把行高顶开
  ///   （在密集表单里这是行高不齐最常见的根因）。
  ///
  /// [filled] 决定走 [FilledButton.styleFrom] 还是 [OutlinedButton.styleFrom]：
  /// 传 `true` 给 `FilledButton` / `FilledButton.tonal`，否则给 `OutlinedButton` /
  /// `TextButton` 之外的按钮。两条路径的圆角、内边距、最小高度完全一致，
  /// 并排不会出现高度 / 圆角对不上的问题。
  ///
  /// [foreground] / [background] **只在需要压掉主题色时才传**：不传则保留按钮
  /// 自身的 tonal / outlined 配色（这也是为什么默认值必须是 null —— 一旦写死颜色，
  /// 换主题色或换亮暗色时按钮就不跟着走了）。
  ButtonStyle buttonStyle({
    Color? foreground,
    Color? background,
    bool filled = false,
  }) {
    // 类型必须是 OutlinedBorder（而非 ShapeBorder）：FilledButton/OutlinedButton
    // 的 styleFrom 都把这个参数声明成 OutlinedBorder?，宽类型会被判不兼容。
    final OutlinedBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    const MaterialTapTargetSize tap = MaterialTapTargetSize.shrinkWrap;
    final EdgeInsets padding = EdgeInsets.symmetric(horizontal: padH);
    final Size minSize = Size(0, height);
    if (filled) {
      return FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        padding: padding,
        minimumSize: minSize,
        tapTargetSize: tap,
        shape: shape,
      );
    }
    return OutlinedButton.styleFrom(
      foregroundColor: foreground,
      padding: padding,
      minimumSize: minSize,
      tapTargetSize: tap,
      shape: shape,
    );
  }

  /// 输入框后缀图标（如显示/隐藏密码的「眼睛」）的约束盒。
  ///
  /// [InputDecorator] 默认给后缀图标 `BoxConstraints(48, 48)`（再按 `visualDensity`
  /// 折算），并且**把图标高度直接算进输入框高度**：
  /// `contentHeight = max(iconHeight, 纵向内边距 + 文字行盒)`。
  /// 后果就是带眼睛图标的字段比同卡其它字段高一截 —— 桌面端 40 vs 34、
  /// 移动端 48 vs 42，同一张卡里并排一眼能看出参差（API Key / 端口这类字段最多）。
  /// 压到本档位高度以下即可，图标本身只有 16，24 的点按区完全够用。
  static const BoxConstraints iconSlot = BoxConstraints(
    minWidth: 24,
    minHeight: 24,
  );

  /// 压平 `visualDensity`，让同一份 `contentPadding` 在桌面 / 移动端算出同样的高度。
  ///
  /// 桌面端 `ThemeData.visualDensity` 默认取 [VisualDensity.compact]（-2,-2），
  /// [InputDecorator] 会把 `baseSizeAdjustment.dy`（-8）直接加进输入框高度：
  /// 同一份 `contentPadding` 在桌面比移动端矮 8px。显式钉成 standard（0,0）即可
  /// 两端一致 —— 比「按平台补 8px」这种算法稳，也不会随主题配置漂移。
  static const VisualDensity fieldDensity = VisualDensity.standard;

  /// 单行文字行盒的估算高度（字号 13 时约 19px）。
  ///
  /// 仅用于估算 `contentPadding` 以尽量减少内部溢出；最终高度不靠它 ——
  /// 见 [fieldBox]。本应用允许用户换字体，行盒高度会变，所以不能拿它当唯一依据。
  static const double _kLineBox = 19;

  /// 档位对应的输入框内边距。
  ///
  /// 给「自己手写 `InputDecoration`（自带 border / fillColor）」的输入框复用 ——
  /// 那些输入框用不了 [denseInput]（会丢边框），但纵向内边距必须同源，
  /// 否则同页两种输入框高度会差 2~4px。用它的输入框别忘了同时带上 [fieldDensity]。
  EdgeInsets get fieldPadding => EdgeInsets.symmetric(
    horizontal: padH,
    vertical: ((height - _kLineBox) / 2).clamp(0.0, 20.0),
  );

  /// 把输入框钉死到档位高度。
  ///
  /// 不靠 `contentPadding` 去「凑」高度：行盒高度取决于实际字体（本应用允许用户换字体），
  /// 算出来的值必然有偏差。从外部给一个紧高度约束，[InputDecorator] 会把内部内容
  /// 垂直居中，得到与字体无关的稳定高度。
  Widget fieldBox(Widget child) => SizedBox(height: height, child: child);

  /// 与该档位等高的输入框装饰。
  ///
  /// 只覆盖 `isDense` / `contentPadding` / `suffixIconConstraints` / `visualDensity`：
  /// 边框、聚焦色、填充色仍继承主题。
  InputDecoration denseInput({
    String? hintText,
    String? labelText,
    TextStyle? hintStyle,
    TextStyle? labelStyle,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hintText,
      labelText: labelText,
      hintStyle: hintStyle,
      labelStyle: labelStyle,
      suffixIcon: suffixIcon,
      isDense: true,
      contentPadding: fieldPadding,
      suffixIconConstraints: iconSlot,
      visualDensity: fieldDensity,
    );
  }
}
