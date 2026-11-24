import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_mobile_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_tab_bar/liquid_glass_tab_bar.dart'
    show LiquidGlassTabBar;
import 'package:provider/provider.dart';

Widget _host(AppState? state, Widget child, {ThemeData? theme}) {
  final app = MaterialApp(
    theme: theme,
    home: Scaffold(body: Center(child: child)),
  );
  return state == null
      ? app
      : ChangeNotifierProvider<AppState>.value(value: state, child: app);
}

void main() {
  late AppState state;
  bool? previousMobileOverride;

  setUp(() {
    previousMobileOverride = debugIsMobilePlatformOverride;
    debugIsMobilePlatformOverride = true;
    state = AppState()..config.language = 'en';
    state.config.selectionIndicatorStyle = 'liquid';
  });

  tearDown(() {
    state.dispose();
    debugIsMobilePlatformOverride = previousMobileOverride;
  });

  AppLiquidTabBar bar() => AppLiquidTabBar(
        currentIndex: 0,
        onTap: (_) {},
        items: const [
          LiquidGlassTabItem(icon: Icon(Icons.folder), label: 'Projects'),
          LiquidGlassTabItem(icon: Icon(Icons.list), label: 'Queue'),
        ],
      );

  testWidgets('liquid mask follows the neutral app glass palette', (tester) async {
    await tester.pumpWidget(_host(state, SizedBox(width: 320, child: bar())));
    final hosted = tester.widget<LiquidGlassTabBar>(find.byType(LiquidGlassTabBar));
    // 默认不跟随主题色：底色为应用中性玻璃 #FAFAFA（亮色），而非上游 iOS 白。
    const neutral = Color(0xFFFAFAFA);
    expect(hosted.style.barTint, isNotNull);
    expect(hosted.style.barTint!.toARGB32() & 0xFFFFFF, neutral.toARGB32() & 0xFFFFFF);
    expect(hosted.style.capsuleTint, isNotNull);
    expect(hosted.style.capsuleTint!.toARGB32() & 0xFFFFFF, neutral.toARGB32() & 0xFFFFFF);
    expect(hosted.style.lensTint, isNotNull);
    expect(hosted.style.lensTint!.toARGB32() & 0xFFFFFF, neutral.toARGB32() & 0xFFFFFF);
    expect(hosted.style.barTint!.a, neutral.withValues(alpha: 0.68 * 0.7).a);
  });

  testWidgets('liquid mask tints with the theme seed when glass follows theme', (tester) async {
    state.config.glassFollowTheme = true;
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.purple),
    );
    await tester.pumpWidget(_host(state, SizedBox(width: 320, child: bar()), theme: theme));
    final hosted = tester.widget<LiquidGlassTabBar>(find.byType(LiquidGlassTabBar));
    expect(hosted.style.barTint, isNotNull);
    // 跟随主题色后，栏玻璃不再是中性 #FAFAFA，而是混入主题强调色。
    expect(hosted.style.barTint!.toARGB32() & 0xFFFFFF, isNot(const Color(0xFFFAFAFA).toARGB32() & 0xFFFFFF));
    expect(hosted.style.capsuleTint!.toARGB32() & 0xFFFFFF, isNot(const Color(0xFFFAFAFA).toARGB32() & 0xFFFFFF));
  });

  testWidgets('without AppState the bar falls back to the static themed track', (tester) async {
    await tester.pumpWidget(_host(null, SizedBox(width: 320, child: bar())));
    // 没有配置时遮罩默认主题色，走静态选中片而不是托管水滴栏。
    expect(find.byType(LiquidGlassTabBar), findsNothing);
    expect(find.byKey(const ValueKey('app-tab-selection')), findsOneWidget);
  });
}