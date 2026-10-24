import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/app_platform.dart';
import 'liquid_glass_fallback.dart';

/// ════════════════════════════════════════════════════════════════════
/// Linux 客户端修饰（CSD）统一实现
/// ════════════════════════════════════════════════════════════════════
///
/// 背景：Linux 走无边框窗口（main.dart 里 [TitleBarStyle.hidden]），窗口的
/// 拖动 / 缩放 / 最小化 / 最大化 / 关闭全部由 Flutter 自绘。此前主窗口
/// （app.dart）、节点编辑器（pipeline_editor_page.dart）、容器详情
/// （container_detail_page.dart）各写了一份几乎相同的 36px 玻璃标题栏，
/// 而**二级 / 三级全屏路由页**（设置子页、AI 配置子页、广告 / 致谢、
/// 命令 / 日志……）沿用了主窗口的 Navigator，路由盖住主窗口标题栏后
/// 整个页面既不能拖动也没有窗口按钮 —— 这就是「部分二级界面没有客户端修饰」。
///
/// 本文件是全应用唯一实现：
///  * [WindowChrome]  —— 给整页套上「顶部 36px 玻璃标题栏 + 四周缩放热区」，
///                       内容整体下移 36px，不会被标题栏盖住；
///  * [WindowChromeBar] —— 只渲染标题栏本身，供独立面板窗口这种用 Column
///                       自己排布内容、且 Windows/macOS 也要一条应用内
///                       标题栏的宿主复用；
///  * [WindowChromeButton] —— 46×36 的窗口按钮（悬停高亮，关闭键系统红）。
///
/// 非 Linux 平台一律 no-op / 不显示窗口按钮：Windows / macOS 有系统标题栏，
/// 移动端没有窗口概念。
/// ════════════════════════════════════════════════════════════════════

/// 自绘标题栏高度。与历史各处的 36px 完全一致，默认观感逐像素不变。
const double kWindowChromeHeight = 36;

/// 当前平台是否使用自绘窗口修饰。
bool get usesWindowChrome => isLinuxPlatform;

/// 把一个全屏页面包进 Linux 自绘窗口修饰里。
///
/// * 非 Linux → 原样返回 [child]（Windows/macOS 系统标题栏、移动端无窗口）。
/// * Linux → 顶部固定 [kWindowChromeHeight] 的玻璃标题栏 + 四边 6px 缩放热区，
///   [child] 从标题栏下方开始布局（不会被标题栏遮挡）。
///
/// [title] / [onBack] / [leading] / [trailing] 都是可选的：二级路由页通常
/// 自己已有返回栏与标题（MobileSubPageTopBar / GlassTopBar），此时只补窗口
/// 按钮即可，避免出现「两层返回 / 两个标题」。
class WindowChrome extends StatelessWidget {
  const WindowChrome({
    super.key,
    required this.child,
    this.title,
    this.onBack,
    this.leading = const <Widget>[],
    this.trailing = const <Widget>[],
    this.showWindowButtons = true,
    this.dragToMove = true,
    this.resizeEdgeSize = 6,
  });

  final Widget child;

  /// 标题栏左侧标题。为 null 时不显示标题（多数路由页由页面自身标题栏承担）。
  final Widget? title;

  /// 左侧返回按钮回调。为 null 时不显示。
  final VoidCallback? onBack;

  /// 左侧附加动作（在返回键与标题之间）。
  final List<Widget> leading;

  /// 右侧附加动作（在窗口按钮左侧）。
  final List<Widget> trailing;

  /// 是否显示最小化 / 最大化 / 关闭三颗窗口按钮。
  final bool showWindowButtons;

  /// 标题栏空白处是否可拖动窗口（独立面板窗口在系统已有标题栏时可关掉）。
  final bool dragToMove;

  /// 四边缩放热区宽度（逻辑像素）。
  final double resizeEdgeSize;

  @override
  Widget build(BuildContext context) {
    if (!usesWindowChrome) return child;
    return DragToResizeArea(
      resizeEdgeSize: resizeEdgeSize,
      child: Stack(
        children: [
          // 内容从标题栏下方开始：绝不能像旧版那样直接把页面铺满再用标题栏
          // 覆盖，否则路由页自己的返回栏 / 标题会被压掉 36px。
          Padding(
            padding: const EdgeInsets.only(top: kWindowChromeHeight),
            child: child,
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: WindowChromeBar(
              title: title,
              onBack: onBack,
              leading: leading,
              trailing: trailing,
              showWindowButtons: showWindowButtons,
              dragToMove: dragToMove,
            ),
          ),
        ],
      ),
    );
  }
}

/// 只渲染标题栏本身（36px 玻璃条 + 拖动区 + 窗口按钮）。
///
/// 用在「内容用 Column 排布、标题栏作为第一行」的宿主（如独立面板窗口）：
/// 它不负责给内容让位，也不包缩放热区，由宿主自行决定。
class WindowChromeBar extends StatefulWidget {
  const WindowChromeBar({
    super.key,
    this.title,
    this.onBack,
    this.leading = const <Widget>[],
    this.trailing = const <Widget>[],
    this.showWindowButtons = true,
    this.dragToMove = true,
  });

  final Widget? title;
  final VoidCallback? onBack;
  final List<Widget> leading;
  final List<Widget> trailing;
  final bool showWindowButtons;
  final bool dragToMove;

  @override
  State<WindowChromeBar> createState() => _WindowChromeBarState();
}

class _WindowChromeBarState extends State<WindowChromeBar>
    with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (usesWindowChrome) {
      windowManager.addListener(this);
      unawaited(_refreshMaximized());
    }
  }

  Future<void> _refreshMaximized() async {
    try {
      final value = await windowManager.isMaximized();
      if (mounted) setState(() => _maximized = value);
    } catch (_) {
      // 窗口管理器尚未就绪（例如首帧）：保持默认图标即可，下次事件会再同步。
    }
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  @override
  void dispose() {
    if (usesWindowChrome) windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _toggleMaximize() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {
      // 忽略：窗口已销毁 / 平台不支持时不影响 UI。
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 与旧版主窗口标题栏同一支玻璃画笔：σ18 / alpha 160|180 是历史基准，
    // 默认「玻璃细节」参数下逐像素一致。σ 走进程级缓存，避免每帧新建
    // 持有 native handle 的 ImageFilter。
    final tuning = glassTuningOf(context);
    final double sigma = tunedGlassSigma(18, tuning);

    final bar = Container(
      height: kWindowChromeHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.surface.withAlpha(
              tunedGlassAlpha(isDark ? 160 : 180, tuning),
            ),
            scheme.surface.withAlpha(
              tunedGlassAlpha(isDark ? 120 : 140, tuning),
            ),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withAlpha(isDark ? 60 : 80),
            width: 0.5,
          ),
        ),
      ),
      child: Stack(
        children: [
          // 拖动区铺满整条（窗口按钮 / 返回键是后面 Positioned 的子节点，
          // 命中测试优先于本层，不会「点按钮反而拖动窗口」）。
          if (widget.dragToMove)
            Positioned.fill(
              child: DragToMoveArea(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: usesWindowChrome ? _toggleMaximize : null,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          if (widget.onBack != null ||
              widget.leading.isNotEmpty ||
              widget.title != null)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onBack != null)
                    WindowChromeButton(
                      icon: Icons.arrow_back,
                      color: scheme.onSurfaceVariant,
                      onTap: widget.onBack!,
                    ),
                  ...widget.leading,
                  if (widget.title != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: DefaultTextStyle(
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: widget.title!,
                      ),
                    ),
                ],
              ),
            ),
          if (widget.trailing.isNotEmpty ||
              (widget.showWindowButtons && usesWindowChrome))
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...widget.trailing,
                  if (widget.showWindowButtons && usesWindowChrome) ...[
                    WindowChromeButton(
                      icon: Icons.remove,
                      color: scheme.onSurfaceVariant,
                      onTap: () => unawaited(windowManager.minimize()),
                    ),
                    WindowChromeButton(
                      icon: _maximized ? Icons.filter_none : Icons.crop_square,
                      color: scheme.onSurfaceVariant,
                      onTap: () => unawaited(_toggleMaximize()),
                    ),
                    WindowChromeButton(
                      icon: Icons.close,
                      color: scheme.onSurface,
                      // Windows 关闭按钮的系统约定红（#E81123）。窗口装饰不参与
                      // 主题化：用语义色在深色主题下会变成浅粉。
                      hoverColor: const Color(0xFFE81123),
                      onTap: () => unawaited(windowManager.close()),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );

    // 玻璃观感：标题栏透出下层页面 / 壁纸。非 Linux（独立窗口在
    // Windows/macOS 上仍显示应用内动作栏）也保持同一材质。
    return ClipRect(
      child: BackdropFilter(
        filter: cachedGlassBlur(sigma),
        child: bar,
      ),
    );
  }
}

/// 自绘标题栏上的紧凑窗口按钮（46×36，悬停高亮）。
///
/// 尺寸 / 悬停色与历史实现一致（主窗口、编辑器、容器详情、独立面板）。
class WindowChromeButton extends StatefulWidget {
  const WindowChromeButton({
    super.key,
    required this.icon,
    required this.color,
    required this.onTap,
    this.hoverColor,
  });

  final IconData icon;
  final Color color;

  /// 悬停背景色；给了同时把图标切成白色（用于关闭键的系统红）。
  final Color? hoverColor;
  final VoidCallback onTap;

  @override
  State<WindowChromeButton> createState() => _WindowChromeButtonState();
}

class _WindowChromeButtonState extends State<WindowChromeButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: kWindowChromeHeight,
          color: _hovering
              ? (widget.hoverColor ?? widget.color.withAlpha(30))
              : Colors.transparent,
          child: Icon(
            widget.icon,
            size: 16,
            color: _hovering && widget.hoverColor != null
                ? Colors.white
                : widget.color,
          ),
        ),
      ),
    );
  }
}
