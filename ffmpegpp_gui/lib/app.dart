import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'models/models.dart';
import 'pages/command_page.dart';
import 'pages/config_library_page.dart';
import 'pages/log_page.dart';
import 'pages/project_page.dart';
import 'pages/queue_page.dart';
import 'pages/settings_page.dart';
import 'platform/app_platform.dart';
import 'providers/app_state.dart';
import 'services/android_platform.dart';
import 'services/image_memory_budget.dart';
import 'services/static_file_image.dart';
import 'services/update_service.dart' as updater;
import 'theme/app_motion.dart';
import 'theme/app_neutral_surface.dart';
import 'theme/app_page_transitions.dart';
import 'theme/app_press_feedback.dart';
import 'theme/app_semantic_colors.dart';
import 'theme/app_strings.dart';
import 'theme/app_text_scale.dart';
import 'theme/app_theme.dart';
import 'theme/mobile_visual_theme.dart';
import 'widgets/app_alert_dialog.dart';
import 'widgets/desktop_resize_scope.dart';
import 'widgets/liquid_glass_mobile_nav.dart';
import 'widgets/mobile_bottom_nav.dart';
// 生效的菜单栏位置下发（底部 ↔ 左右竖排导轨时，主 Tab 各页的底部留白随之切换）
import 'widgets/mobile_nav_scope.dart';
import 'widgets/polygon_morph_loader.dart';
import 'widgets/sidebar.dart';
import 'widgets/task_float_layer.dart';
import 'widgets/toast.dart';
// 与 wallpaper_background.dart 互为循环引用（它用本文件的
// wallpaperImageProvider，本文件用它的 WallpaperWindowScope），Dart 允许。
import 'widgets/wallpaper_background.dart';
import 'widgets/window_chrome.dart';

/// 构建壁纸解码用的 ImageProvider。
///
/// 关键修复：`Image` 若同时给定 `cacheWidth`/`cacheHeight`（`ResizeImage` 默认
/// `ResizeImagePolicy.exact`），会解码成「恰好 width×height」的矩形，不保持源图
/// 宽高比（等价 BoxFit.fill），导致壁纸被异常拉伸。这里改用 `ResizeImagePolicy.fit`
/// 按屏幕需求和固定像素预算等比缩放解码：
/// - 大图最多约 2MP，避免 4K / 高 DPR 为装饰壁纸保留数十 MB；
/// - 小图不放大（allowUpscaling 默认 false），不浪费内存、不产生伪清晰；
/// - 等比缩放，绝不拉伸变形。
ImageProvider<Object> wallpaperImageProvider(
  String path,
  double logicalWidth,
  double logicalHeight,
  double devicePixelRatio, {
  bool disableAnimations = false,
}) {
  final target = ImageMemoryBudget.wallpaperSize(
    logicalWidth,
    logicalHeight,
    devicePixelRatio,
  );
  return ResizeImage(
    disableAnimations ? StaticFileImage(File(path)) : FileImage(File(path)),
    width: target.width,
    height: target.height,
    policy: ResizeImagePolicy.fit,
  );
}

class FfmpegppApp extends StatefulWidget {
  const FfmpegppApp({super.key});
  @override
  State<FfmpegppApp> createState() => _FfmpegppAppState();
}

/// 全局滚动行为：去掉拉伸过滚动指示器（保留各平台默认滚动物理与拖拽设备配置）。
///
/// 为什么禁用：Android 12+ 的 StretchingOverscrollIndicator 在 Impeller 上通过
/// `ImageFiltered(ImageFilter.shader(...))` 实现——先把滚动内容整棵截进离屏纹理，
/// 再对纹理做拉伸形变。液态玻璃 / 毛玻璃（BackdropFilter）在被截获的纹理中
/// 采样不到真实背景，且内容被拉伸而场景坐标不变，导致玻璃错位、消失。
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

/// PageView 翻页门限：必须滑动一定距离（或明确甩动）才翻页，避免轻划误触。
class _SwipeGatePagePhysics extends PageScrollPhysics {
  const _SwipeGatePagePhysics({
    super.parent,
    required this.originPage,
    this.gateFraction = 0.30,
  });

  final double originPage;
  final double gateFraction;

  @override
  _SwipeGatePagePhysics applyTo(ScrollPhysics? ancestor) =>
      _SwipeGatePagePhysics(
        parent: buildParent(ancestor),
        originPage: originPage,
        gateFraction: gateFraction,
      );

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final page = position.pixels / position.viewportDimension;
    final dragged = page - originPage;
    // 需要约 3.5 倍默认甩动速度才触发「甩动翻页」，避免轻划误翻
    final tol = tolerance.velocity * 3.5;
    double targetPage;
    if (velocity.abs() > tol) {
      // 明确甩动：按方向翻一页
      targetPage = (velocity < 0 ? originPage - 1 : originPage + 1)
          .roundToDouble();
    } else if (dragged.abs() >= gateFraction) {
      // 拖拽距离超过门限 → 翻页
      targetPage = (dragged > 0 ? originPage + 1 : originPage - 1)
          .roundToDouble();
    } else {
      // 不足门限 → 回弹到当前页
      targetPage = originPage;
    }
    final maxPage = (position.maxScrollExtent / position.viewportDimension)
        .clamp(0.0, 1e9);
    targetPage = targetPage.clamp(0.0, maxPage);
    final target = targetPage * position.viewportDimension;
    if (target == position.pixels) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }
}

class _FfmpegppAppState extends State<FfmpegppApp> with WidgetsBindingObserver {
  /// Android Monet 动态取色的种子色（从系统壁纸读取；null = 不可用）
  int? _monetSeed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMonetSeed();
    // 启动时申请必要媒体权限（读取视频/音频/图片），首帧后再请求，
    // 确保 Activity 已 resumed，权限对话框能正常弹出。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _requestMediaPermissions(),
    );
    // ── 内存自检 ──
    // 每 60 秒把进程 RSS 与图片缓存占用记一条日志（debug 模式开启时可见，
    // 关闭 debug 模式则整类 info 日志不记录，零成本）。用途是**区分**两种
    // 完全不同的情况：
    //  - 常态化高水位（玻璃离屏纹理 / 引擎 / .so）：数字大但来回切换页面、
    //    反复进出编辑器时基本不涨 → 属渲染开销，只能用「少用玻璃」来换；
    //  - 真泄漏：数字只增不减，且与操作次数正相关（如进出编辑器 N 次涨 N 份）
    //    → 需要修代码。
    // 没有这行数字就只能靠猜，所以留着。
    _memProbe = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      final cache = PaintingBinding.instance.imageCache;
      context.read<AppState>().addLog(
        '[内存] RSS ${(ProcessInfo.currentRss / 1048576).toStringAsFixed(1)}MB · '
        '图片缓存 ${(cache.currentSizeBytes / 1048576).toStringAsFixed(1)}MB/'
        '${cache.currentSize}张（存活 ${cache.liveImageCount}）',
        category: 'info',
      );
    });
  }

  Timer? _memProbe;

  @override
  void dispose() {
    _memProbe?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Android onTrimMemory(level≥40) → Flutter memoryPressure：
  /// 系统内存吃紧时立刻释放图片缓存（壁纸/缩略图）与壁纸预模糊图，
  /// 把内存还给系统，降低被杀后台的概率。UI 侧图片会按需重新解码。
  @override
  void didHaveMemoryPressure() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    WallpaperBlurCache.release();
  }

  Future<void> _requestMediaPermissions() async {
    if (!isAndroidPlatform) return;
    await AndroidPlatformBridge.requestMediaPermissions();
  }

  Future<void> _loadMonetSeed() async {
    if (!isAndroidPlatform) return;
    final seed = await AndroidPlatformBridge.wallpaperPrimaryColor();
    if (mounted && seed != null) {
      setState(() => _monetSeed = seed);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 只用 select 订阅主题相关字段：进度/日志等高频 notify 不再重建 MaterialApp
    // 和两份 ThemeData。
    return Selector<AppState, _ThemeKey>(
      selector: (_, s) => _ThemeKey(
        lang: s.config.language,
        themeColor: s.config.themeColor,
        useThemeColor: s.config.useThemeColor,
        fontFamily: s.config.fontFamily,
        fontSize: s.config.fontSize,
        fontWeight: s.config.fontWeightValue,
        darkMode: s.darkMode,
        disableAnimations:
            s.config.disableAnimations || (!s.initialized && !s.configLoaded),
        initialized: s.initialized,
        useDynamicColor: isAndroidPlatform && s.config.useDynamicColor,
        predictiveBack: isAndroidPlatform && s.config.predictiveBack,
        glassEffect: s.config.glassEffect,
        mobileTheme: s.config.mobileTheme,
        monetSeed: _monetSeed,
      ),
      builder: (context, k, _) {
        // Monet 生效时用壁纸种子色覆盖用户主题色（tonalSpot 方案）
        final dynamicSeed = k.useDynamicColor
            ? (k.monetSeed ?? k.themeColor)
            : null;
        final mobileVisual = resolveMobileVisualTheme(
          k.mobileTheme,
          isMobile: isMobilePlatform,
        );
        // 必须走 applyTo，而不是「只把扩展塞进 extensions」：applyTo 才会把
        // surface / surfaceContainer* 换成中性灰，并同步 dialog / popupMenu /
        // bottomSheet 的底色。旧写法只在 extensions 里挂了一个 enabled 标记，
        // 主题层没有任何可见变化 —— 这就是「切到 ZeroUI 大部分界面纹丝不动」
        // 的根因（全站只有 AI 面板、移动 AI 弹层、下拉浮层自己调了 applyTo）。
        ThemeData withMobileVisual(ThemeData base) =>
            mobileVisual.enabled ? mobileVisual.applyTo(base) : base;
        return MaterialApp(
          key: const ValueKey('app'),
          title: 'FFmpeg++',
          themeAnimationDuration: k.disableAnimations
              ? Duration.zero
              : kThemeAnimationDuration,
          debugShowCheckedModeBanner: false,
          // 本地化支持：让 showDatePicker/showTimePicker 等系统组件跟随语言
          locale: Locale(k.lang == 'zh' ? 'zh' : 'en'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: withMobileVisual(
            AppTheme.light(
              seedColor: k.themeColor,
              useThemeColor: k.useThemeColor,
              fontFamily: k.fontFamily,
              fontSize: k.fontSize,
              fontWeight: k.fontWeight,
              dynamicSeed: dynamicSeed,
              predictiveBack: k.predictiveBack,
              glassEffect: k.glassEffect,
            ),
          ),
          darkTheme: withMobileVisual(
            AppTheme.dark(
              seedColor: k.themeColor,
              useThemeColor: k.useThemeColor,
              fontFamily: k.fontFamily,
              fontSize: k.fontSize,
              fontWeight: k.fontWeight,
              dynamicSeed: dynamicSeed,
              predictiveBack: k.predictiveBack,
              glassEffect: k.glassEffect,
            ),
          ),
          themeMode: k.darkMode ? ThemeMode.dark : ThemeMode.light,
          // 禁用 Android 12+ 的「拉伸过滚动」效果：它在 Impeller 下用
          // ImageFiltered(shader) 把整页内容截进离屏纹理再做形变——液态玻璃
          // （BackdropFilter shader）在被截获的纹理里采样不到真实背景，且几何
          // 被整体拉伸而 render 树坐标不变 → 过滚动时玻璃分层/整块消失。
          // 桌面端本来就没有过滚动指示器，此覆盖对桌面行为无影响。
          scrollBehavior: const _AppScrollBehavior(),
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            // 「应用内字号」（设置 → 字体 → 字号，基准 14）必须**乘**在系统字号上，
            // 不能覆盖：旧实现直接 `copyWith(textScaler: TextScaler.linear(fontSize/14))`，
            // 等价于把 Android「设置 → 显示 → 字体大小」整个丢掉 —— 系统里把字号调到
            // 最大/最小，应用内所有文字纹丝不动（用户反馈的「移动端字号无法调整」）。
            //
            // 取系统倍率用 scale(14)/14 而不是已废弃的 TextScaler.textScaleFactor：
            // Flutter 目前下发的系统缩放都是线性的（TextScaler.linear），二者等价，
            // 且不会因使用废弃 API 触发 analyzer 警告。
            final sysScale = mq.textScaler.scale(14.0) / 14.0;
            // 应用内倍率：设置里的字号（基准 14，默认 17）。
            final appScale = k.fontSize / 14.0;
            // 再钳到 0.5~2.6：系统 2.0 叠应用内 1.5 会到 3.0，移动端顶栏药丸/卡片
            // 的固定高度（MobileUi.pillHeight 等）撑不住，反而会溢出。
            final scale = (sysScale * appScale).clamp(
              AppTextScale.minScale,
              AppTextScale.maxScale,
            );
            // AppTextScale 把两个倍率**分别**暴露出去（不是只给乘积）：
            // 选项控件（OptionMenuBar）要「只跟系统、不跟应用内设置」的字号，
            // 见 theme/app_text_scale.dart 的 withoutAppTextScale。
            //
            // [FIX UI-返回黑闪] 在 Navigator **背后**垫一层不透明主题底色。
            // 为什么需要：本层 child 就是 Navigator，各路由是它的兄弟节点；
            // 路由切换（尤其是返回/pop）时存在「下层路由还没画出、上层路由已开始
            // 退场」的中间帧，此时这一帧没有任何路由覆盖 → 直接露出平台窗口背景。
            // Android 侧 NormalTheme 继承 Theme.Black.NoTitleBar 且
            // windowBackground=?android:colorBackground（夜里就是纯黑），于是
            // 用户看到的就是「返回时突然黑一下」。
            // AppShell 内部虽有同样的底色垫层，但 AppShell 只是 home 路由，
            // 覆盖不到「路由之间的空白帧」；只有垫在 Navigator 外面才真正兜住。
            // 取色用 Theme.of —— MaterialApp 内部专门用 Builder 包了 builder，
            // 保证此处 context 能解析到上面设置的 theme（见 _materialBuilder）。
            // 该图层只在「无路由绘制」时可见，有路由时被完全覆盖，不影响任何观感。
            final Color baseSurface = AppNeutralSurface.background(
              Theme.of(context).brightness,
            );
            return DesktopResizeScope(
              child: LinuxWindowFrame(
                child: AppTextScale(
                  systemScale: sysScale,
                  appScale: appScale,
                  child: MediaQuery(
                    data: mq.copyWith(textScaler: TextScaler.linear(scale)),
                    child: AppMotion(
                      disabled: k.disableAnimations,
                      child: AppPressTheme(
                        child: ColoredBox(color: baseSurface, child: child!),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
          home: k.initialized ? const AppShell() : const _SplashScreen(),
        );
      },
    );
  }
}

/// MaterialApp 重建所需的最小配置快照（相等比较避免无谓重建）。
class _ThemeKey {
  final String lang;
  final int themeColor;
  final bool useThemeColor;
  final String fontFamily;
  final double fontSize;
  final int fontWeight;
  final bool darkMode;
  final bool disableAnimations;
  final bool initialized;
  final bool useDynamicColor;
  final bool predictiveBack;
  final String glassEffect;
  final String mobileTheme;
  final int? monetSeed;
  const _ThemeKey({
    required this.lang,
    required this.themeColor,
    required this.useThemeColor,
    required this.fontFamily,
    required this.fontSize,
    required this.fontWeight,
    required this.darkMode,
    required this.disableAnimations,
    required this.initialized,
    required this.useDynamicColor,
    required this.predictiveBack,
    required this.glassEffect,
    required this.mobileTheme,
    required this.monetSeed,
  });

  @override
  bool operator ==(Object other) =>
      other is _ThemeKey &&
      other.lang == lang &&
      other.themeColor == themeColor &&
      other.useThemeColor == useThemeColor &&
      other.fontFamily == fontFamily &&
      other.fontSize == fontSize &&
      other.fontWeight == fontWeight &&
      other.darkMode == darkMode &&
      other.disableAnimations == disableAnimations &&
      other.initialized == initialized &&
      other.useDynamicColor == useDynamicColor &&
      other.predictiveBack == predictiveBack &&
      other.glassEffect == glassEffect &&
      other.mobileTheme == mobileTheme &&
      other.monetSeed == monetSeed;

  @override
  int get hashCode => Object.hash(
    lang,
    themeColor,
    useThemeColor,
    fontFamily,
    fontSize,
    fontWeight,
    darkMode,
    disableAnimations,
    initialized,
    useDynamicColor,
    predictiveBack,
    glassEffect,
    mobileTheme,
    monetSeed,
  );
}

/// 启动加载画面：空心多边形加载动画与软件名称。
/// 期间后台并行执行：后端启动、配置加载、字体/壁纸预加载（见 main.dart）。
class _SplashScreen extends StatefulWidget {
  const _SplashScreen();
  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppNeutralSurface.background(
        Theme.of(context).brightness,
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PolygonMorphLoader.hollow(size: 160),
            const SizedBox(height: 20),
            Text(
              'FFmpeg++',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Preserves page state while hidden pages stop ticking, painting, and relayout.
class CachedPageSlot extends StatefulWidget {
  const CachedPageSlot({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<CachedPageSlot> createState() => _CachedPageSlotState();
}

class _CachedPageSlotState extends State<CachedPageSlot> {
  Size? _lastActiveSize;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if ((widget.active || _lastActiveSize == null) &&
          constraints.hasBoundedWidth &&
          constraints.hasBoundedHeight) {
        _lastActiveSize = constraints.biggest;
      }
      final size = _lastActiveSize;
      return Offstage(
        offstage: !widget.active,
        child: ExcludeFocus(
          excluding: !widget.active,
          child: TickerMode(
            enabled: widget.active,
            child: size == null
                ? widget.child
                : OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: size.width,
                    maxWidth: size.width,
                    minHeight: size.height,
                    maxHeight: size.height,
                    child: widget.child,
                  ),
          ),
        ),
      );
    },
  );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.pageBuilder, this.mobile});

  /// Optional destination factory for focused page-lifecycle tests.
  final IndexedWidgetBuilder? pageBuilder;

  /// Overrides the platform layout in focused lifecycle tests.
  final bool? mobile;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with WindowListener, WidgetsBindingObserver {
  bool get _mobile => widget.mobile ?? isMobilePlatform;
  final _projectPageKey = GlobalKey<ProjectPageState>();

  /// 底部导航可见的页面索引，横向滑动按此顺序循环切换。
  static const List<int> _kMobileNavOrder = [0, 1, 3, 4];

  /// 移动端 Tab 翻页控制器：PageView 跟随手指（半程滑动即显示「各半张页面」）。
  late final PageController _mobilePageController;

  /// 底部菜单栏是否已被「滑动自动收起」隐藏（内容上滑收起、下滑展开）。
  /// 只在 config.navAutoHide 开启且菜单栏处于「底部」形态时为 true；
  /// 关闭开关 / 切到侧边导轨 / 下滑时复位（见 [_handleContentScroll]）。
  bool _navHiddenByScroll = false;

  /// 内容区滚动监听：上滑（scrollDelta > 0，元素向上移动）收起菜单栏，
  /// 下滑展开。只认垂直轴 —— 横向 PageView 翻页与横向 chips 列表都不触发。
  /// 用 ScrollUpdateNotification 而非 UserScrollNotification：fling 惯性
  /// 滑动期间同样持续产生 update 通知，跟手与惯性阶段行为一致。
  bool _handleContentScroll(ScrollNotification n, bool enabled) {
    if (n.metrics.axis == Axis.horizontal && n is ScrollEndNotification) {
      final page = n.metrics is PageMetrics
          ? (n.metrics as PageMetrics).page
          : null;
      if (page != null) {
        final index = page.round();
        if (index >= 0 && index < _kMobileNavOrder.length) {
          final target = _kMobileNavOrder[index];
          if (context.read<AppState>().selectedNav != target) {
            context.read<AppState>().selectNav(target);
          }
          _schedulePageEviction();
        }
      }
      return false;
    }
    if (!enabled) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    // scrollDelta 只存在于 ScrollUpdateNotification（基类没有该字段）
    final delta = n is ScrollUpdateNotification ? n.scrollDelta : null;
    if (delta == null || delta == 0) return false;
    final bool target = delta > 0; // 内容向上滚 = 收起
    if (target != _navHiddenByScroll) {
      setState(() => _navHiddenByScroll = target);
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mobilePageController = PageController(initialPage: 0);
    // 移动端没有窗口管理器，跳过窗口相关初始化。
    // 监听器只用于 onWindowClose（优雅关闭后端 / 子进程）；标题栏的
    // 最大化图标状态由 widgets/window_chrome.dart 自己维护。
    if (!_mobile) {
      windowManager.addListener(this);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<AppState>();
      state.onTaskFinished = _onTaskFinished;
      if (!_mobile) {
        _checkPostUpdate();
        _autoCheckUpdate();
      }
      // Only visited destinations are retained; startup does not prewarm pages.
      _lastNoPreload = state.config.noPreload;
      _lastNav = state.selectedNav;
      _listenedState = state;
      state.addListener(_onNoPreloadChanged);
      // 非底部导航触发的页面切换（全局搜索跳转、focusSettingsCard 等直接调用
      // selectNav）也必须让移动端 PageView 跟过去，否则底部导航高亮切走了、
      // 可见内容还停在旧 Tab。
      state.addListener(_onNavChanged);
    });
  }

  /// dispose 时用引用移除监听（dispose 里不能再走 context.lookup）。
  AppState? _listenedState;
  bool _lastNoPreload = false;

  /// 上一次已知的导航索引（用于识别「外部调用 selectNav」并同步 PageView）。
  int _lastNav = 0;

  void _onNoPreloadChanged() {
    if (!mounted) return;
    final state = context.read<AppState>();
    final now = state.config.noPreload;
    if (now == _lastNoPreload) return;
    _lastNoPreload = now;
    _schedulePageEviction();
  }

  @override
  void didHaveMemoryPressure() {
    if (!mounted) return;
    _pendingPageLimit = 1;
    _schedulePageEviction();
  }

  /// selectedNav 被外部改动（不经过底部导航）时，让移动端 PageView 滑动到对应 Tab。
  void _onNavChanged() {
    if (!mounted) return;
    final nav = context.read<AppState>().selectedNav;
    if (nav == _lastNav) return;
    _lastNav = nav;
    _pageLru.remove(nav);
    _pageLru.add(nav);
    _schedulePageEviction();
    if (!_mobile) return;
    final idx = _kMobileNavOrder.indexOf(nav);
    if (idx < 0) return;
    // 帧后再动 PageController：监听回调可能发生在 build/layout 阶段，
    // 此时直接 animateToPage 会与正在进行的布局冲突。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mobilePageController.hasClients) return;
      final current = _mobilePageController.page?.round() ?? idx;
      if (current == idx) return; // 已在该 Tab（底部导航点击路径）→ 无需重复动画
      _showMobilePage(idx);
    });
  }

  Future<void> _autoCheckUpdate() async {
    final state = context.read<AppState>();
    if (!state.config.autoCheckUpdate) return;
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    final isZh = state.config.language == 'zh';
    try {
      final result = await updater.checkForUpdate(preferLanzou: isZh);
      if (!mounted || !result.hasUpdate) return;
      final s = AppStrings.of(state.config.language);
      SettingsPage.showUpdateDialogStatic(context, s, result);
    } catch (_) {
      return;
    }
  }

  Future<void> _checkPostUpdate() async {
    final String? status;
    try {
      status = await updater.checkPostUpdateStatus();
    } catch (_) {
      return;
    }
    if (!mounted || status == null) return;
    if (status == 'updated') {
      final s = AppStrings.of(context.read<AppState>().config.language);
      final scheme = Theme.of(context).colorScheme;
      showDialog(
        context: context,
        animationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : null,
        builder: (_) => AppAlertDialog(
          icon: Icon(Icons.check_circle, color: scheme.sem.success, size: 32),
          title: Text(
            s.isZh ? '更新完成' : 'Update Complete',
            style: TextStyle(color: scheme.onSurface),
          ),
          content: Text(
            s.isZh
                ? 'FFmpeg++ 已更新到 v${updater.currentVersion}'
                : 'FFmpeg++ updated to v${updater.currentVersion}',
            style: TextStyle(fontSize: 13, color: scheme.onSurface),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(s.isZh ? '好的' : 'OK'),
            ),
          ],
        ),
      );
    }
    // 'downgraded' — silent, cache already updated
  }

  void _onTaskFinished(String filename, TaskStatus status) {
    if (!mounted) return;
    final s = AppStrings.of(context.read<AppState>().config.language);
    if (status == TaskStatus.completed) {
      showToast(
        context,
        s.isZh ? '$filename 已完成' : '$filename completed',
        type: ToastType.success,
      );
    } else if (status == TaskStatus.failed) {
      showToast(
        context,
        s.isZh ? '$filename 处理失败' : '$filename failed',
        type: ToastType.error,
      );
    }
    if (context.read<AppState>().config.enableSystemNotification) {
      _sendSystemNotification(filename, status);
    }
  }

  void _sendSystemNotification(String filename, TaskStatus status) {
    final isZh = context.read<AppState>().config.language == 'zh';
    const title = 'FFmpeg++';
    final body = status == TaskStatus.completed
        ? (isZh ? '$filename 已完成' : '$filename completed')
        : (isZh ? '$filename 处理失败' : '$filename failed');

    if (Platform.isWindows) {
      final icon = status == TaskStatus.completed ? 'Info' : 'Warning';
      // 文件名可能包含 ' " 等字符，拼接进 PowerShell 单引号字符串会提前终止或注入。
      // 用单引号内替换 '' 的方式转义：PowerShell 单引号字符串转义单引号需写成两个。
      final escTitle = title.replaceAll("'", "''");
      final escBody = body.replaceAll("'", "''");
      final ps =
          "Add-Type -AssemblyName System.Windows.Forms;"
          "Add-Type -AssemblyName System.Drawing;"
          "\$n=New-Object System.Windows.Forms.NotifyIcon;"
          "\$n.Icon=[System.Drawing.SystemIcons]::Information;"
          "\$n.BalloonTipIcon=[System.Windows.Forms.ToolTipIcon]::$icon;"
          "\$n.BalloonTipTitle='$escTitle';"
          "\$n.BalloonTipText='$escBody';"
          "\$n.Visible=\$true;"
          "\$n.ShowBalloonTip(3000);"
          "Start-Sleep -Milliseconds 3500;"
          "\$n.Dispose()";
      Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        ps,
      ]).ignore();
    } else if (Platform.isMacOS) {
      // macOS 没有 notify-send，用 osascript 发系统通知。
      // 文件名里的 " 或 \ 会破坏 AppleScript 字符串并可能注入，先转义。
      final escTitle = title.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final escBody = body.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final script = 'display notification "$escBody" with title "$escTitle"';
      Process.run('osascript', ['-e', script]).ignore();
    } else if (Platform.isAndroid) {
      // 安卓走原生通道：澎湃 OS（HyperOS 3 且应用开了焦点通知权限）会自动以
      // 「小米超级岛」展示，其余 ROM 退化为普通系统通知（见 HyperOsIsland.kt）。
      //
      // 返回 false = 没送达（Android 13+ 权限被拒 / 系统通知总开关关闭）。
      // 旧实现完全吞掉结果，用户只会看到「任务完成了但通知栏什么都没有」，
      // 这里明确提示一次并指路。
      AndroidPlatformBridge.notifyTaskDone(
        title: title,
        body: body,
        success: status == TaskStatus.completed,
      ).then((ok) {
        if (ok != false || !mounted) return;
        final isZh = context.read<AppState>().config.language == 'zh';
        showToast(
          context,
          isZh
              ? '系统通知未送达：请在 系统设置 → 通知 → FFmpeg++ 中允许通知'
              : 'Notification not delivered: allow notifications for FFmpeg++ '
                    'in System Settings → Notifications',
          type: ToastType.warning,
        );
      });
    } else {
      // notify-send 直接收独立 argv，无需 shell 拼接，天然安全。
      final urgency = status == TaskStatus.completed ? 'normal' : 'critical';
      Process.run('notify-send', ['-u', urgency, title, body]).ignore();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mobilePageController.dispose();
    for (final notifier in _pageKeepAlive) {
      notifier.dispose();
    }
    if (!_mobile) windowManager.removeListener(this);
    _listenedState?.removeListener(_onNoPreloadChanged);
    _listenedState?.removeListener(_onNavChanged);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    final state = context.read<AppState>();
    await state.shutdown();
    await windowManager.destroy();
  }

  static String? _modifierLabel(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.controlLeft ||
        k == LogicalKeyboardKey.controlRight) {
      return 'Control';
    }
    if (k == LogicalKeyboardKey.shiftLeft ||
        k == LogicalKeyboardKey.shiftRight) {
      return 'Shift';
    }
    if (k == LogicalKeyboardKey.altLeft || k == LogicalKeyboardKey.altRight) {
      return 'Alt';
    }
    if (k == LogicalKeyboardKey.metaLeft || k == LogicalKeyboardKey.metaRight) {
      return 'Meta';
    }
    return null;
  }

  bool _matchesBinding(KeyEvent event, List<String> binding) {
    if (event is! KeyDownEvent || binding.isEmpty) return false;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final heldModifiers = <String>{};
    for (final k in pressed) {
      final m = _modifierLabel(k);
      if (m != null) heldModifiers.add(m);
    }
    final bindingModifiers = binding
        .where((b) => const {'Control', 'Shift', 'Alt', 'Meta'}.contains(b))
        .toSet();
    final bindingKey = binding
        .where((b) => !const {'Control', 'Shift', 'Alt', 'Meta'}.contains(b))
        .join();
    if (heldModifiers.length != bindingModifiers.length) return false;
    if (!heldModifiers.containsAll(bindingModifiers)) return false;
    final eventLabel = event.logicalKey.keyLabel;
    return eventLabel.isNotEmpty &&
        eventLabel.toLowerCase() == bindingKey.toLowerCase();
  }

  /// 当前键盘焦点是否落在「可编辑文本」内。
  ///
  /// 必须有这个判断：本 Shell 的 [Focus] 是页内任何输入框的**祖先**，而真正处理
  /// Ctrl+A 的 DefaultTextEditingShortcuts 挂在 WidgetsApp 层（位于本 Focus 的
  /// 更上层）。按键冒泡顺序是「主焦点 → 逐级向上找 onKeyEvent」，所以本 Focus
  /// 会**先**拿到事件。不判断的后果：
  ///   · 在搜索框 / 命名框里按 Ctrl+A → 变成「全选所有项目」而不是选中文字；
  ///   · 一边打字一边误触 Ctrl+Shift+Delete → 一次清空整个项目列表。
  static bool _isTextEditingFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    // EditableText 的 Focus 是它自己 build 出来的子节点，所以从焦点 context
    // 向上找才能命中（widget 层与 State 层各查一次，覆盖 TextField/TextFormField
    // 以及裸用 EditableText 的情况）。
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null ||
        ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  KeyEventResult _handleGlobalKey(FocusNode node, KeyEvent event) {
    // 焦点在输入框内：一律放行给文本编辑快捷键（见 [_isTextEditingFocused]）
    if (_isTextEditingFocused()) return KeyEventResult.ignored;
    final state = context.read<AppState>();
    final bindings = state.config.keyBindings;
    final s = AppStrings.of(state.config.language);
    final nav = state.selectedNav;

    // Project page shortcuts (nav == 0)
    if (nav == 0) {
      final selectAllBinding =
          bindings['project_select_all'] ?? ['Control', 'A'];
      if (_matchesBinding(event, selectAllBinding)) {
        // 无可操作对象时不吞事件（否则 Ctrl+A 在空列表下也永远到不了输入框）
        if (state.videos.isEmpty) return KeyEventResult.ignored;
        _projectPageKey.currentState?.selectAll(state.videos);
        return KeyEventResult.handled;
      }

      final addAllBinding =
          bindings['queue_add_all'] ?? ['Control', 'Shift', 'A'];
      if (_matchesBinding(event, addAllBinding)) {
        final parsed = state.videos.where((v) => v.parsed).toList();
        if (parsed.isEmpty) return KeyEventResult.ignored;
        for (final v in parsed) {
          state.addTask(v.id);
        }
        showToast(
          context,
          s.isZh
              ? '已添加 ${parsed.length} 个任务到队列'
              : 'Added ${parsed.length} tasks to queue',
          type: ToastType.success,
        );
        return KeyEventResult.handled;
      }

      // 项目页搜索（默认 Ctrl+F）
      // [FIX C2] 该绑定此前没有任何消费者（只出现在默认表与快捷键设置页里）。
      final searchBinding = bindings['project_search'] ?? ['Control', 'F'];
      if (_matchesBinding(event, searchBinding)) {
        _projectPageKey.currentState?.openSearch();
        return KeyEventResult.handled;
      }

      final clearAllBinding =
          bindings['project_clear_all'] ?? ['Control', 'Shift', 'Delete'];
      if (_matchesBinding(event, clearAllBinding)) {
        if (state.videos.isEmpty) return KeyEventResult.ignored;
        // 破坏性操作必须先确认：项目页按钮走的是带确认的路径，快捷键不该绕过它
        _confirmClearAll(state, s);
        return KeyEventResult.handled;
      }
    }

    // 全局导航快捷键（任意页面可用）
    final navProjects = bindings['nav_projects'] ?? ['Control', '1'];
    if (_matchesBinding(event, navProjects)) {
      state.selectNav(0);
      return KeyEventResult.handled;
    }
    final navQueue = bindings['nav_queue'] ?? ['Control', '2'];
    if (_matchesBinding(event, navQueue)) {
      state.selectNav(1);
      return KeyEventResult.handled;
    }
    final navCommand = bindings['nav_command'] ?? ['Control', '3'];
    if (_matchesBinding(event, navCommand)) {
      state.selectNav(2);
      return KeyEventResult.handled;
    }
    final navSettings = bindings['nav_settings'] ?? ['Control', '4'];
    if (_matchesBinding(event, navSettings)) {
      state.selectNav(4);
      return KeyEventResult.handled;
    }

    // Queue page shortcuts (nav == 1)
    if (nav == 1) {
      final startAllBinding =
          bindings['queue_start_all'] ?? ['Control', 'Shift', 'S'];
      if (_matchesBinding(event, startAllBinding)) {
        final pendingCount = state.tasks
            .where((t) => t.status == TaskStatus.pending)
            .length;
        if (pendingCount > 0) {
          state.processAllTasks();
          showToast(
            context,
            s.isZh ? '已开始 $pendingCount 个任务' : 'Started $pendingCount tasks',
            type: ToastType.success,
          );
        }
        return KeyEventResult.handled;
      }

      final stopAllBinding =
          bindings['queue_stop_all'] ?? ['Control', 'Shift', 'X'];
      if (_matchesBinding(event, stopAllBinding)) {
        if (state.processing) {
          state.cancelProcessing();
          showToast(
            context,
            s.isZh ? '已停止所有任务' : 'All tasks stopped',
            type: ToastType.warning,
          );
        }
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  /// 快捷键触发「移除所有项目」前的二次确认。
  ///
  /// 保持同步签名：[_handleGlobalKey] 必须同步返回 [KeyEventResult]，所以这里
  /// 只负责弹窗，真正的清空放在 dialog 的回调里。
  void _confirmClearAll(AppState state, AppStrings s) {
    final zh = s.isZh;
    showDialog<bool>(
      context: context,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AppAlertDialog(
          title: Text(
            zh ? '移除所有项目？' : 'Remove all projects?',
            style: TextStyle(color: scheme.onSurface),
          ),
          content: Text(
            zh
                ? '将从项目列表移除全部 ${state.videos.length} 项（磁盘上的源文件不会被删除）。此操作无法撤销。'
                : 'This removes all ${state.videos.length} items from the project list '
                      '(source files on disk are kept). This cannot be undone.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(s.clearAll),
            ),
          ],
        );
      },
    ).then((ok) {
      if (ok != true || !mounted) return;
      state.clearAllVideos();
      _projectPageKey.currentState?.selectAll([]);
      showToast(
        context,
        s.isZh ? '已删除所有项目' : 'All projects deleted',
        type: ToastType.info,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // 用 select 只监听导航索引，避免任何进度/日志 notify 都重建整棵页面树。
    final nav = context.select<AppState, int>((s) => s.selectedNav);
    // 菜单栏位置设置（'auto' / 'bottom' / 'left' / 'right'）。必须在这里订阅：
    // 主壳原本只 select 了 selectedNav，不订阅本字段的话在设置里改方向不会重排
    // 布局。select 只在该值变化时触发重建，不引入额外重建开销。
    final placementCfg = context.select<AppState, String>(
      (s) => s.config.mobileNavPlacement,
    );
    // 滑动自动收起开关：必须在这里订阅 —— NotificationListener 的启用判定与
    // 传给导航栏的 hidden 都依赖它，漏订阅会「开关点了没反应」（契约 11 同根因）。
    final navAutoHide = context.select<AppState, bool>(
      (s) => s.config.navAutoHide,
    );
    final mobile = _mobile;

    // 桌面端：左侧边栏 + 页面；移动端页面在下方用 _mobilePageView（PageView）。
    Widget desktopPage() => Focus(
      autofocus: true,
      onKeyEvent: _handleGlobalKey,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
            child: Sidebar(
              selectedIndex: nav,
              onSelected: (i) => context.read<AppState>().selectNav(i),
            ),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _pageStack(nav),
                const Positioned.fill(child: TaskFloatLayer()),
              ],
            ),
          ),
        ],
      ),
    );

    final Widget body;
    if (mobile) {
      // ── 菜单栏位置（底部 / 左 / 右）──
      //
      // 位置来自「设置 → 外观 → 样式 → 菜单栏位置」，'auto'（默认）时按屏幕
      // 横纵比自动判定：宽屏（平板 / 横屏，宽 ≥ 高 × 1.25）→ 左侧竖排导轨，
      // 把纵向空间还给内容；手机竖屏仍是原来的悬浮底部胶囊。
      //
      // 判定必须在**这里**做：位置决定内容区让出多少空间、导航栏贴哪条边，
      // 导航栏自己看不到屏宽，所以它只接受一个已解析好的 placement。
      final size = MediaQuery.sizeOf(context);
      final placement = resolveMobileNavPlacement(
        placementCfg,
        size.width,
        size.height,
      );
      final navHidden =
          navAutoHide &&
          placement == MobileNavPlacement.bottom &&
          _navHiddenByScroll;
      // The package supplies the floating liquid-glass bar at the bottom;
      // keep the existing glass rail for the optional left/right placements.
      final navBar = placement == MobileNavPlacement.bottom
          ? LiquidGlassMobileNav(
              selectedIndex: nav,
              onSelected: _selectMobileNav,
              hidden: navHidden,
            )
          : MobileNavRail(
              placement: placement,
              selectedIndex: nav,
              onSelected: _selectMobileNav,
              pageController: _mobilePageController,
            );
      // ── 形态恒定：内容区与导航栏始终是同一个 Stack 的两个固定槽位 ──
      //
      // 为什么不能用「底部 = Stack / 侧边 = Row」两套父结构（原实现）：
      // RenderFlex ↔ RenderStack 是两个不同的 RenderObject 类型，切换时
      // framework 无法复用下面的 Element —— 整个 PageView 连同四个 Tab 页
      // 被卸载重建。后果有三条，用户看到的正是「横屏切竖屏整个界面变灰」：
      //   ① 页面 State（滚动位置、多选、展开态）全部丢失；
      //   ② 重建期间所有 Image/玻璃各走一次「重新 resolve + 回退渲染」；
      //   ③ 配合 WallpaperWindowScope 的 provider 尺寸变化 → 壁纸按新尺寸
      //      重新解码，那段时间界面只剩主题底色 + 遮罩 = 一片灰。
      // 现在 children 的数量与 runtimeType 恒定，形态差异只体现在 Positioned
      // 的位置参数与 Align 的对齐方向上（都是 parentData / 布局属性，不触发
      // 子树重建），页面的 Element 与 State 全程保留。
      final bool onBottom = placement == MobileNavPlacement.bottom;
      final bool onLeft = placement == MobileNavPlacement.left;
      // 侧边形态下内容区要让出「导航栏实际占用的宽度」= 外壳内边距 + 胶囊宽度。
      // 两者都取自同一处定义（shellPadding / kMobileNavRailExtent），避免各写
      // 一份后漂移成「导轨压住内容」或「内容左边多出一条缝」。
      final EdgeInsets shellPad = NavGlassShell.shellPadding(
        MediaQuery.paddingOf(context),
        placement,
      );
      final double sideInset = onBottom
          ? 0.0
          : shellPad.horizontal + kMobileNavRailExtent;
      final Widget mobileBody = Stack(
        children: [
          // 槽位 0：内容区。底部形态全屏铺满；侧边形态按方向让出侧向宽度。
          // 页面区用 PageView：[0,1,3,4] 四个 Tab 滑动全程跟随手指（拖到一半即
          // 「各展示一半」），松手由 PageView 决定回弹或翻页；底部导航点击时同步。
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              // 滑动自动收起的信号源：各 Tab 内部所有可滚动组件的通知都会冒泡
              // 到这里；只认垂直轴（横向 PageView 翻页 / 横向 chips 不触发）。
              onNotification: (n) =>
                  _handleContentScroll(n, navAutoHide && onBottom),
              child: Padding(
                padding: EdgeInsets.only(
                  left: onLeft ? sideInset : 0,
                  right: (!onBottom && !onLeft) ? sideInset : 0,
                ),
                child: _mobilePageView(),
              ),
            ),
          ),
          // 槽位 1：导航栏。底部形态贴底全宽悬浮叠加；侧边形态贴左 / 贴右，
          // 宽度固定为 sideInset，并由 Align 在纵轴上居中 —— 复现原 Row 的
          // 默认交叉轴对齐（center，一颗纵向居中的悬浮胶囊）行为。
          // 不能直接用 Center 替代：底部形态下导航栏拿到的是「宽 tight、高 loose」
          // 约束，Center 会把可用高度吃满，胶囊会被摆到屏幕垂直中央。
          Positioned(
            left: onBottom ? 0 : (onLeft ? 0 : null),
            right: onBottom ? 0 : (onLeft ? null : 0),
            top: onBottom ? null : 0,
            bottom: 0,
            // 侧边形态限定宽度；底部形态必须为 null（left+right 已定宽，
            // Positioned 同时给出 width 会断言失败）。
            width: onBottom ? null : sideInset,
            child: Align(
              alignment: onBottom
                  ? Alignment.bottomCenter
                  : (onLeft ? Alignment.centerLeft : Alignment.centerRight),
              // SizedBox(width:∞) 是**必需**的：Align 给 child 的是 loose 宽度约束
              // （`constraints.loosen()`），导航栏内部的横排布局依赖 maxWidth 均分
              // 药丸宽度，拿 loose 约束会缩成内容宽 —— 底部形态就再也贴不满屏宽了。
              // 填满上限后：底部 = Stack 宽；侧边 = Positioned 已定死的 sideInset。
              child: SizedBox(width: double.infinity, child: navBar),
            ),
          ),
        ],
      );
      // 把生效位置下发给主 Tab 各页：列表底部留白随之在 96 / 20 之间切换
      // （见 MobileUi.mainListPadding）。页面实例被 _pageCache 缓存并原样复用，
      // 上层重建不会触发它们 build —— 只有 InheritedWidget 的依赖关系能保证
      // 「位置一变，依赖它的页面下一帧就重建」。
      body = MobileNavPlacementScope(placement: placement, child: mobileBody);
    } else {
      // Windows / macOS 用系统标题栏（WindowChrome 内部自动 no-op）；
      // Linux 套上全应用统一的 36px 玻璃 CSD + 四边缩放热区。
      body = WindowChrome(child: desktopPage());
    }

    return WallpaperBackground(
      child: Scaffold(backgroundColor: Colors.transparent, body: body),
    );
  }

  /// 底部导航点击：切换选中页，并让 PageView 滑动到对应位置（带滑动动画）。
  void _selectMobileNav(int i) {
    context.read<AppState>().selectNav(i);
    final idx = _kMobileNavOrder.indexOf(i);
    if (idx >= 0 &&
        _mobilePageController.hasClients &&
        (_mobilePageController.page?.round() ?? idx) != idx) {
      _showMobilePage(idx);
    }
  }

  void _showMobilePage(int index) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _mobilePageController.jumpToPage(index);
    } else {
      _mobilePageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// The viewport requests destinations on demand instead of building all tabs.
  Widget _mobilePageView() {
    final nav = context.read<AppState>().selectedNav;
    final idx = _kMobileNavOrder.indexOf(nav);
    return PageView.builder(
      controller: _mobilePageController,
      physics: _SwipeGatePagePhysics(
        originPage: idx.toDouble(),
        gateFraction: 0.42,
      ),
      onPageChanged: (_) {},
      itemCount: _kMobileNavOrder.length,
      itemBuilder: (context, index) {
        final destination = _kMobileNavOrder[index];
        return _KeepAlive(
          key: ValueKey<int>(destination),
          keepAlive: _pageKeepAlive[destination],
          child: ExcludeFocus(
            excluding: destination != nav,
            child: TickerMode(
              enabled: destination == nav,
              child: _page(destination),
            ),
          ),
        );
      },
    );
  }

  static const int _kPageCount = 6;
  static const int _kMaxAlivePages = 2;
  final List<Widget?> _pageCache = List.filled(_kPageCount, null);
  final List<int> _pageLru = [];
  final List<ValueNotifier<bool>> _pageKeepAlive = List.generate(
    _kPageCount,
    (_) => ValueNotifier(false),
  );
  bool _evictScheduled = false;
  int? _pendingPageLimit;

  Widget _page(int index) {
    if (index == context.read<AppState>().selectedNav) {
      _pageLru.remove(index);
      _pageLru.add(index);
    } else if (!_pageLru.contains(index)) {
      _pageLru.insert(0, index);
    }
    final cached = _pageCache[index];
    if (cached != null) return cached;
    final page =
        widget.pageBuilder?.call(context, index) ??
        switch (index) {
          0 => ProjectPage(key: _projectPageKey),
          1 => const QueuePage(),
          2 => const CommandPage(),
          3 => const ConfigLibraryPage(),
          4 => const SettingsPage(),
          5 => const LogPage(embedded: true),
          _ => const SizedBox.shrink(),
        };
    _pageCache[index] = page;
    _schedulePageEviction();
    return page;
  }

  void _schedulePageEviction() {
    if (_evictScheduled) return;
    _evictScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _evictScheduled = false;
      if (mounted) _evictStalePages(context.read<AppState>().selectedNav);
    });
    // Memory pressure can arrive while the UI is idle with no queued frame.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _evictStalePages(int current) {
    // Both visible pages are needed until a swipe or programmatic slide settles.
    if (_mobile &&
        _mobilePageController.hasClients &&
        _mobilePageController.position.isScrollingNotifier.value) {
      return;
    }
    final noPreload = context.read<AppState>().config.noPreload;
    final capacity = _pendingPageLimit ?? (noPreload ? 1 : _kMaxAlivePages);
    _pendingPageLimit = null;
    var retained = _pageCache.where((page) => page != null).length;
    var evicted = false;
    for (final index in List<int>.of(_pageLru)) {
      if (retained <= capacity) break;
      if (index == current || _pageCache[index] == null) continue;
      _pageCache[index] = null;
      _pageLru.remove(index);
      retained--;
      evicted = true;
    }
    for (var index = 0; index < _kPageCount; index++) {
      _pageKeepAlive[index].value = !noPreload && _pageCache[index] != null;
    }
    // The mobile notifiers release the actual sliver keep-alive children.
    // Rebuilding its delegate here would immediately reconstruct stale slots.
    if (evicted && !_mobile && mounted) setState(() {});
  }

  Widget _pageStack(int current) => Stack(
    fit: StackFit.expand,
    children: [
      for (var index = 0; index < _kPageCount; index++)
        CachedPageSlot(
          key: ValueKey<int>(index),
          active: index == current,
          child: index == current
              ? _page(index)
              : (_pageCache[index] ?? const SizedBox.shrink()),
        ),
    ],
  );
}

/// 让 PageView 子页在滑出视口后保持状态（AutomaticKeepAlive）。
/// 否则左右滑动返回时页面会被重建，丢失滚动位置/输入状态。
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({super.key, required this.child, required this.keepAlive});

  final Widget child;
  final ValueNotifier<bool> keepAlive;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  void initState() {
    super.initState();
    widget.keepAlive.addListener(updateKeepAlive);
  }

  @override
  void didUpdateWidget(covariant _KeepAlive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keepAlive != widget.keepAlive) {
      oldWidget.keepAlive.removeListener(updateKeepAlive);
      widget.keepAlive.addListener(updateKeepAlive);
      updateKeepAlive();
    }
  }

  @override
  void dispose() {
    widget.keepAlive.removeListener(updateKeepAlive);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => widget.keepAlive.value;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 二级页面统一转场：纯位移，**不做页面级淡入**，并关闭 framework 的路由快照。
///
/// - 关闭快照（allowSnapshotting: false）：转场默认会把进入的路由光栅化成离屏快照，
///   而快照采不到 BackdropFilter 的 backdrop —— 玻璃区域会变黑、首帧整屏黑一下。
/// - 不再用 FadeTransition：整页一层 OpacityLayer 会让页内 BackdropFilter / 液态
///   玻璃 shader 在过渡期间采不到背景（下拉浮层「点一下闪一下」就是这个机制）。
///   这里与 `theme/app_page_transitions.dart` 里 Android 的转场同一套视觉：新页
///   从右侧 6% 滑入，全程无 opacity、无 surface 底板。
Route<T> smoothRoute<T>(Widget page) => AppPageRoute<T>(builder: (_) => page);
