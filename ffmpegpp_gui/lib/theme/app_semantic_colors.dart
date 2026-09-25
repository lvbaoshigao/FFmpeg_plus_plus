import 'package:flutter/material.dart';

/// 语义色（成功 / 警告 / 危险 / 信息 / 中性）。
///
/// ## 为什么需要这个文件
///
/// 全仓库原本直接写 `Colors.green` / `Colors.orange` / `Colors.red` / `Colors.amber`
/// 等 Material 调色板原色（约 100 处）。这些颜色**与主题种子色完全无关**：
///
/// - 用户换主题色（设置 → 外观 → 主题颜色）时，全应用都在变，只有这些图标/文字
///   仍是固定的 #4CAF50 / #FF9800，视觉上像「贴在界面上的补丁」；
/// - Android 开启 Monet 动态取色（`dynamicSeed` 覆盖种子色）后差距更明显；
/// - 深色主题下 `Colors.green`(#4CAF50) 与 `Colors.amber`(#FFC107) 是为浅色底
///   设计的 tone 50 饱和色，铺在深色玻璃面上过亮、刺眼；
/// - 同一个语义在不同文件里用了不同的原色（队列图例用 `Colors.grey.shade400`，
///   同一处的状态芯片却用 `scheme.outline`），属于「同一概念两套颜色」。
///
/// 解决方案对齐 Material 3 的「自定义色（custom colors）」规范：
/// **保留语义色的色相身份**（绿仍是绿、琥珀仍是琥珀），只把色相朝主题主色方向
/// 旋转最多 15°，再用 `ColorScheme.fromSeed` 生成完整的 tonal 阶梯，从而拿到
/// 明暗两套都正确的 tone（亮色主题 tone 40 深色文字、深色主题 tone 80 浅色文字）。
///
/// 危险色不再另造：`ColorScheme.error` 本身就是 Material 规范里的固定错误色，
/// 直接复用可以保证与框架组件（错误边框、SnackBar 等）完全一致。
///
/// ## 用法
///
/// ```dart
/// final sem = scheme.sem;               // 扩展 getter，内部有进程级缓存
/// Icon(Icons.check_circle, color: sem.success);
/// Container(color: sem.warningContainer);
/// ```
///
/// 主题层（`AppTheme._build`）已把它注入 `ThemeData.extensions`，
/// 因此也可以 `Theme.of(context).extension<AppSemantic>()` 取；扩展 getter
/// 在取不到时按 `ColorScheme` 现算（并缓存），不会退化成每帧重算。
///
/// ## 不使用本令牌的例外（有意为之）
///
/// - `image_channel_extract_step_editor` 的 R/G/B 通道芯片：红/绿/蓝是通道的
///   **物理含义**，被调和成主题色反而是 bug；
/// - 各处 `Colors.white` / `Colors.black` 的高光、阴影、遮罩：它们不是语义色，
///   是玻璃材质的光学参数；
/// - 桌面端 CSD 窗口关闭按钮的悬停红：Windows 系统级约定色。
@immutable
class AppSemantic extends ThemeExtension<AppSemantic> {
  const AppSemantic({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.danger,
    required this.onDanger,
    required this.dangerContainer,
    required this.onDangerContainer,
    required this.info,
    required this.onInfo,
    required this.infoContainer,
    required this.onInfoContainer,
    required this.neutral,
    required this.neutralContainer,
  });

  /// 成功 / 已完成 / 有效 / 已同步。
  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;

  /// 警告 / 处理中 / 未找到 / 已取消（非错误但非正常完成）。
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;

  /// 危险 / 失败 / 破坏性操作。等价于 `ColorScheme.error`。
  final Color danger;
  final Color onDanger;
  final Color dangerContainer;
  final Color onDangerContainer;

  /// 信息 / 进行中提示。等价于 `ColorScheme.primary`。
  final Color info;
  final Color onInfo;
  final Color infoContainer;
  final Color onInfoContainer;

  /// 中性：未开始 / 占位 / 无数据。等价于 `ColorScheme.outline`。
  final Color neutral;
  final Color neutralContainer;

  // ── 调和 ──────────────────────────────────────────────────────────────

  /// 语义色基色（未经调和）。深色主题用更亮的 tone 起点，浅色主题用更深的。
  static const Color _successLight = Color(0xFF2E7D32);
  static const Color _successDark = Color(0xFF66BB6A);
  static const Color _warningLight = Color(0xFFB26A00);
  static const Color _warningDark = Color(0xFFFFB300);

  /// 把 [c] 的色相朝主题主色 [source] 方向旋转，最大 [maxDeg] 度。
  ///
  /// 与 Material 的 `Blend.harmonize` 同思路（那边是在 HCT 空间里按
  /// `min(色相差 * amount, 15)` 旋转）：保留语义色的身份，只做有限度的靠近，
  /// 所以不会出现「选了紫色主题，绿色的成功图标变成紫色」这种语义失守。
  static Color _harmonize(
    Color c,
    Color source, {
    double amount = 0.5,
    double maxDeg = 15,
  }) {
    final a = HSLColor.fromColor(c);
    final b = HSLColor.fromColor(source);
    var diff = (b.hue - a.hue) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    final shift = (diff * amount).clamp(-maxDeg, maxDeg);
    return a.withHue((a.hue + shift) % 360).toColor();
  }

  // ── 缓存 ──────────────────────────────────────────────────────────────

  /// 进程级缓存：`ColorScheme.fromSeed` 内部要做 HCT 量化，单次约 1~3ms，
  /// 四次调用不能让它在每帧的热路径上跑。缓存键是「主色 + 明暗」——
  /// 语义色只依赖这两个输入（字号/字体/玻璃模式都不影响它）。
  static final Map<int, AppSemantic> _cache = <int, AppSemantic>{};

  /// 按 [scheme] 生成语义色（带缓存）。
  static AppSemantic ofScheme(ColorScheme scheme) {
    final key = Object.hash(scheme.primary.toARGB32(), scheme.brightness);
    final cached = _cache[key];
    if (cached != null) return cached;
    final built = _build(scheme);
    // 主题色切换是低频操作，缓存规模天然有界（不同种子数），无需淘汰。
    _cache[key] = built;
    return built;
  }

  static AppSemantic _build(ColorScheme scheme) {
    final bool isDark = scheme.brightness == Brightness.dark;
    final Color source = scheme.primary;

    final successScheme = ColorScheme.fromSeed(
      seedColor: _harmonize(isDark ? _successDark : _successLight, source),
      brightness: scheme.brightness,
    );
    final warningScheme = ColorScheme.fromSeed(
      seedColor: _harmonize(isDark ? _warningDark : _warningLight, source),
      brightness: scheme.brightness,
    );

    return AppSemantic(
      success: successScheme.primary,
      onSuccess: successScheme.onPrimary,
      successContainer: successScheme.primaryContainer,
      onSuccessContainer: successScheme.onPrimaryContainer,
      warning: warningScheme.primary,
      onWarning: warningScheme.onPrimary,
      warningContainer: warningScheme.primaryContainer,
      onWarningContainer: warningScheme.onPrimaryContainer,
      // 危险/信息/中性直接复用 ColorScheme：错误色是 Material 规范的固定色，
      // 主色与中性色本来就随主题生成，再调和一次只会引入偏差。
      danger: scheme.error,
      onDanger: scheme.onError,
      dangerContainer: scheme.errorContainer,
      onDangerContainer: scheme.onErrorContainer,
      info: scheme.primary,
      onInfo: scheme.onPrimary,
      infoContainer: scheme.primaryContainer,
      onInfoContainer: scheme.onPrimaryContainer,
      neutral: scheme.outline,
      neutralContainer: scheme.surfaceContainerHighest,
    );
  }

  // ── ThemeExtension ───────────────────────────────────────────────────

  @override
  AppSemantic copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? danger,
    Color? onDanger,
    Color? dangerContainer,
    Color? onDangerContainer,
    Color? info,
    Color? onInfo,
    Color? infoContainer,
    Color? onInfoContainer,
    Color? neutral,
    Color? neutralContainer,
  }) {
    return AppSemantic(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
      dangerContainer: dangerContainer ?? this.dangerContainer,
      onDangerContainer: onDangerContainer ?? this.onDangerContainer,
      info: info ?? this.info,
      onInfo: onInfo ?? this.onInfo,
      infoContainer: infoContainer ?? this.infoContainer,
      onInfoContainer: onInfoContainer ?? this.onInfoContainer,
      neutral: neutral ?? this.neutral,
      neutralContainer: neutralContainer ?? this.neutralContainer,
    );
  }

  @override
  AppSemantic lerp(ThemeExtension<AppSemantic>? other, double t) {
    if (other is! AppSemantic) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppSemantic(
      success: l(success, other.success),
      onSuccess: l(onSuccess, other.onSuccess),
      successContainer: l(successContainer, other.successContainer),
      onSuccessContainer: l(onSuccessContainer, other.onSuccessContainer),
      warning: l(warning, other.warning),
      onWarning: l(onWarning, other.onWarning),
      warningContainer: l(warningContainer, other.warningContainer),
      onWarningContainer: l(onWarningContainer, other.onWarningContainer),
      danger: l(danger, other.danger),
      onDanger: l(onDanger, other.onDanger),
      dangerContainer: l(dangerContainer, other.dangerContainer),
      onDangerContainer: l(onDangerContainer, other.onDangerContainer),
      info: l(info, other.info),
      onInfo: l(onInfo, other.onInfo),
      infoContainer: l(infoContainer, other.infoContainer),
      onInfoContainer: l(onInfoContainer, other.onInfoContainer),
      neutral: l(neutral, other.neutral),
      neutralContainer: l(neutralContainer, other.neutralContainer),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSemantic &&
      other.success == success &&
      other.onSuccess == onSuccess &&
      other.successContainer == successContainer &&
      other.onSuccessContainer == onSuccessContainer &&
      other.warning == warning &&
      other.onWarning == onWarning &&
      other.warningContainer == warningContainer &&
      other.onWarningContainer == onWarningContainer &&
      other.danger == danger &&
      other.onDanger == onDanger &&
      other.dangerContainer == dangerContainer &&
      other.onDangerContainer == onDangerContainer &&
      other.info == info &&
      other.onInfo == onInfo &&
      other.infoContainer == infoContainer &&
      other.onInfoContainer == onInfoContainer &&
      other.neutral == neutral &&
      other.neutralContainer == neutralContainer;

  @override
  int get hashCode => Object.hash(
    success,
    onSuccess,
    successContainer,
    onSuccessContainer,
    warning,
    onWarning,
    warningContainer,
    onWarningContainer,
    danger,
    onDanger,
    dangerContainer,
    onDangerContainer,
    info,
    onInfo,
    infoContainer,
    onInfoContainer,
    neutral,
    neutralContainer,
  );
}

/// 让 `scheme.sem.success` 这样直接取用，避免每个调用点都写一遍
/// `Theme.of(context).extension<AppSemantic>()!`（也就避免了 `!` 在
/// 主题未注入时崩溃 —— 这里带 scheme 兜底）。
extension AppSemanticOnScheme on ColorScheme {
  AppSemantic get sem => AppSemantic.ofScheme(this);
}

/// `context.sem.xxx`：适合「State 的辅助方法里没有 `ColorScheme` 参数、
/// 但有 `context`」的场景（编辑器里的 `_logicIconBtn` 之类）。
/// `State.context` 是成员，因此在 State 的任意实例方法里都可用。
extension AppSemanticOnContext on BuildContext {
  AppSemantic get sem => AppSemantic.ofScheme(Theme.of(this).colorScheme);
}
