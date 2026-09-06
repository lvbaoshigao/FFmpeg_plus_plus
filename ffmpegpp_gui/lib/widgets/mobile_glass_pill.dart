import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import 'app_card.dart' show SurfaceStyle;
import 'liquid_glass_fallback.dart';

/// 移动端「药丸」容器 —— 顶部菜单栏样式（AppConfig.pillStyle）由它接管。
///
/// 四种样式：
/// - liquid：oc_liquid_glass 液态玻璃（GPU fragment shader）
/// - blur：扁平高斯模糊（BackdropFilter）
/// - theme：跟随主题色（纯色药丸）
/// - gray：灰色（纯色药丸）
///
/// 供顶栏标题药丸、顶栏操作长药丸、搜索框药丸等复用。
///
/// [pressable] 为 true 时（用于「内部无可点击元素」的药丸，如左上角标题药丸），
/// 手指按下放大、按住保持、松手回弹，提供触觉反馈。
class MobileGlassPill extends StatefulWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final bool pressable;
  final VoidCallback? onTap;
  /// 固定药丸总高度（内容垂直居中）。顶栏里左右药丸高度不同（标题药丸因
  /// 字体行高约 38px、操作药丸约 44~50px）会造成视觉不一致；传 44 统一。
  final double? height;

  const MobileGlassPill({
    super.key,
    required this.child,
    this.radius = 18,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.margin,
    this.pressable = false,
    this.onTap,
    this.height,
  });

  @override
  State<MobileGlassPill> createState() => _MobileGlassPillState();
}

/// 药丸内紧凑圆形图标按钮（与项目页"+/导入/容器"等按钮一致的风格）。
///
/// 为什么不用 IconButton：Material IconButton 会按主题色渲染 splash/focus/hover，
/// 在液态玻璃药丸里会显示一片主题色块（特别是搜索→关闭切换瞬间的涟漪 + 蓝色边框）。
/// 这里手写一个透明 InkWell 的紧凑按钮：
/// - 默认无背景；[bg] 传入后变成实心主题色圆形（用于"+"加号 CTA）
/// - splash/highlight 都透明，避免蓝色涟漪
/// - 圆角半径 18、内边距 2、直径 34 —— 与 project_page _pillAction 完全一致
class MobileGlassPillAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color? color;
  final Color? bg;
  final VoidCallback? onTap;

  const MobileGlassPillAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
    this.bg,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 19, color: color),
          ),
        ),
      ),
    );
  }
}

/// 药丸样式渲染相关的"配置指纹"。只有它变化时玻璃节点才该重建。
@immutable
class _PillGlassKey {
  /// 顶部药丸样式（pillStyle 四值：theme/liquid/blur/gray）
  final String style;
  final double op;
  final int primary;
  final int second;
  const _PillGlassKey({
    required this.style,
    required this.op,
    required this.primary,
    required this.second,
  });

  @override
  bool operator ==(Object other) =>
      other is _PillGlassKey &&
      other.style == style &&
      other.op == op &&
      other.primary == primary &&
      other.second == second;

  @override
  int get hashCode => Object.hash(style, op, primary, second);
}

class _MobileGlassPillState extends State<MobileGlassPill> {
  bool _pressed = false;

  // 仅当这些字段变化时才重建 OCLiquidGlass 节点；
  // 关键修复：原代码用 context.watch<AppState>() 订阅整个 AppState，
  // 进度/日志/任务等高频 notify 会反复重建 OCLiquidGlassGroup + OCLiquidGlass，
  // 导致 GPU shader uniform 重新初始化 → 视觉上"液态玻璃来回跳跃"。
  // 改用 Selector 精细订阅 + 稳定 key 后，shader 内部状态得以保留。
  static const _liquidSettings = OCLiquidGlassSettings(
    // 3D 液态玻璃：u_size 修复后这些参数才真正生效。
    // refractStrength（负 = 凹透镜）给水滴折射；spec 给镜面高光；lightband 给光带。
    // 数值取中等：可见 3D，但不复现早期的「光污染/横线」。
    // specStrength 3.0→0.5、specPower 100→48：shader 的 L1/L2 两盏对向灯会在
    // 圆角的左上/右下角各打出一个镜面光点，原参数峰值 +2.5 直接过曝成明显白点；
    // 降低强度并放宽高光锐度后变成柔和的角部光泽，不再抢眼。
    //
    // blurRadiusPx 1.0→0：shader 的 radialBlur 每像素要采 1+4×12=49 次纹理，
    // 页面每个玻璃卡片都是独立 BackdropFilter 层，路由转场（如设置二级菜单
    // 返回）时所有层每帧全量重采样 → 移动端 GPU 过载掉帧。1px 模糊肉眼不可辨，
    // 置 0 后单采样直通，转场恢复流畅。
    //
    // lightbandStrength 0.35→0：光带按固定像素偏移绘制，在较「高」的内容
    // （设置项卡片等）上是一条横向亮带，把玻璃内容视觉截成两段，即「上下分层
    // 有分界」的来源之一；彻底关掉（下方注释原本就声明去掉它，数值却遗留了）。
    refractStrength: -0.10,
    blurRadiusPx: 0.0,
    specStrength: 0.5,
    specPower: 48,
    specWidth: 10,
    lightbandStrength: 0.0,
    lightbandColor: Colors.white,
  );

  void _set(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  /// 把玻璃渲染所需的所有字段打包成一个值。
  /// 只有这些字段变化时 Selector 才会重新构建 builder，避免 OCLiquidGlass
  /// 被无关的 notifyListeners()（日志/进度/任务状态等）反复销毁重建。
  static _PillGlassKey _keyOf(AppState s) {
    final cfg = s.config;
    return _PillGlassKey(
      style: cfg.pillStyle,
      op: cfg.cardOpacity,
      primary: cfg.themeColor,
      second: cfg.themeColor2,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final key = context.select<AppState, _PillGlassKey>(_keyOf);
    final style = key.style;
    final op = key.op.clamp(0.0, 1.0);
    // 玻璃样式（liquid/blur）的 tint 与底部导航栏对齐：* 255 无截断，
    // 让玻璃质感与底部栏一致；纯色样式（theme/gray）强制完全不透明（255）
    // ——纯色语义即实心，不再跟随 cardOpacity（此前 ~88% 保底仍透底）。
    final solid = style == SurfaceStyle.theme || style == SurfaceStyle.gray;
    final baseAlpha = solid ? 255 : (op * 255).round().clamp(0, 255);
    final baseColor = style == SurfaceStyle.theme
        ? scheme.primary
        : style == SurfaceStyle.gray
            ? scheme.surfaceContainerHigh
            : scheme.surface;
    final tint = baseColor.withAlpha(baseAlpha);

    // 关键修复：liquid 模式下 OCLiquidGlass 自身已经接收 color=tint 作为
    // 玻璃的 tint（GPU shader 内部叠加）；如果 inner Container 再额外叠一层
    // color=tint，相当于「主题色 + 主题色」双重染色，
    // 切换页面瞬间会出现「一大片主题色块」闪烁。
    // liquid 模式 inner 用透明，只保留边框；blur/theme/gray 模式保留 tint。
    final inner = Container(
      padding: widget.padding,
      decoration: BoxDecoration(
        color: style == SurfaceStyle.liquid ? Colors.transparent : tint,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(
          color: style == SurfaceStyle.blur
              ? scheme.outlineVariant.withAlpha(80)
              : Colors.white.withValues(alpha: isDark ? 0.12 : 0.18),
          width: style == SurfaceStyle.blur ? 0.5 : 0.7,
        ),
      ),
      // 固定总高度：把内容区压到 height - padding.vertical 并垂直居中，
      // 统一顶栏左右药丸的高度（否则标题药丸 ~38px、操作药丸 ~50px 参差不齐）。
      //
      // 关键修复（配置库/队列右上角操作药丸被拉得过长）：Center（Align）在
      // 收到「有限宽度」约束时会撑满最大宽度——队列页、配置库页顶栏右侧的
      // 操作药丸都包在 Flexible → Align 里，Flexible 给出的 loose-finite 宽度
      // 让 Center 一路膨胀到整行剩余宽度，玻璃底板于是远长于内部图标。
      // widthFactor: 1.0 让宽度始终收缩为子元素宽度，只保留垂直居中。
      child: widget.height == null
          ? widget.child
          : SizedBox(
              height: (widget.height! -
                      widget.padding.resolve(Directionality.of(context)).vertical)
                  .clamp(0.0, double.infinity),
              child: Center(widthFactor: 1.0, child: widget.child),
            ),
    );

    Widget pill;
    if (solid) {
      pill = inner;
    } else if (style == SurfaceStyle.blur) {
      // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
      pill = ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: inner,
        ),
      );
    } else if (shaderGlassSupported) {
      // liquid：液态玻璃 shader（Impeller 可用时）
      // 关闭高光带（lightband）与压低镜面高光：高光带按固定像素偏移绘制，
      // 在较「高」的内容（如设置项卡片）上会变成一条横向"分界线"，
      // 视觉上把内容截成两段 —— 这里去掉它，仅保留折射 + 柔和高光。
      //
      // 关键修复：
      // 1) 使用静态 const _liquidSettings（dark 差异化交给 tint + shadow），
      //    避免每次 build 都新建 OCLiquidGlassSettings 触发 shader uniform 重置；
      // 2) 给 OCLiquidGlassGroup 加 ValueKey(key)，仅当玻璃配置
      //    变化时才真的销毁/重建液态玻璃节点；普通 AppState notify（进度、
      //    日志、任务状态等）会让 key 不变，Element 复用，shader 内部状态稳定；
      // 3) OCLiquidGlass 使用独立 key（避免与父级 OCLiquidGlassGroup 重复）；
      // 4) RepaintBoundary 放在 OCLiquidGlassGroup 内部、OCLiquidGlass 外部，
      //    让 shader 能正确采样画布背景，同时隔离内部重绘。
      final glassKey = ValueKey<_PillGlassKey>(key);
      final innerKey = ValueKey<String>('${key.hashCode}_inner');
      pill = RepaintBoundary(
        child: OCLiquidGlassGroup(
          key: glassKey,
          settings: _liquidSettings,
          child: OCLiquidGlass(
            key: innerKey,
            borderRadius: widget.radius,
            color: tint,
            shadow: BoxShadow(
              color: Colors.black.withAlpha(isDark ? 60 : 22),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
            child: inner,
          ),
        ),
      );
    } else {
      // liquid 但无 Impeller（Windows 桌面端默认 Skia）：shader backdrop 会被
      // _RenderLiquidGlassGroup 整体跳过 → 玻璃完全不可见（此前配置库页签药丸
      // 就是这样「没渲染」的）。回退为高斯模糊 + 液态玻璃倒角高光，保证可见。
      // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
      pill = LiquidGlassBackdrop(
        borderRadius: BorderRadius.circular(widget.radius),
        sigma: 16,
        opacity: op,
        shadow: BoxShadow(
          color: Colors.black.withAlpha(isDark ? 60 : 22),
          blurRadius: 16,
          offset: const Offset(0, 5),
        ),
        child: inner,
      );
    }

    Widget result = pill;

    if (widget.pressable || widget.onTap != null) {
      // 按下放大、按住保持、松手回弹。
      result = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapUp: (_) {
          _set(false);
          widget.onTap?.call();
        },
        onTapCancel: () => _set(false),
        child: AnimatedScale(
          scale: _pressed ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: result,
        ),
      );
    }

    // 应用 margin
    if (widget.margin != null) {
      result = Padding(padding: widget.margin!, child: result);
    }

    return result;
  }
}
