import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/liquid_modality_pills.dart';
import 'package:ffmpegpp_gui/widgets/liquid_stretch_tabs.dart';
import 'package:ffmpegpp_gui/widgets/model_editor_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _harness(AppState state, Widget child) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: child),
      ),
    );

Future<void> _flushSaveTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('LiquidStretchTabs', () {
    testWidgets('should stretch the selected indicator then settle', (
      tester,
    ) async {
      final state = AppState();
      state.updateConfig((c) => c..pillStyle = 'gray');
      var selected = 0;
      await tester.pumpWidget(
        _harness(
          state,
          StatefulBuilder(
            builder: (context, setState) => Center(
              child: SizedBox(
                width: 360,
                child: LiquidStretchTabs(
                  style: 'gray',
                  selectedIndex: selected,
                  onChanged: (index) => setState(() => selected = index),
                  tabs: const [
                    LiquidStretchTab(
                      icon: Icons.tune_rounded,
                      label: '基本',
                    ),
                    LiquidStretchTab(
                      icon: Icons.widgets_outlined,
                      label: '模型',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final finder = find.byKey(LiquidStretchTabs.indicatorKey);
      expect(finder, findsOneWidget);
      final initialWidth = tester.getSize(finder).width;

      await tester.tap(find.text('模型'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final stretchedWidth = tester.getSize(finder).width;
      expect(stretchedWidth, greaterThan(initialWidth + 2));

      await tester.pumpAndSettle();
      expect(tester.getSize(finder).width, closeTo(initialWidth, 1.5));
      await _flushSaveTimers(tester);
    });
  });

  group('ModelEditorSheet', () {
    testWidgets('should show all fields and sync image modality with vision', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      state.updateConfig(
        (c) => c
          ..language = 'zh'
          ..cardStyle = 'gray'
          ..pillStyle = 'gray',
      );
      final entry = AiModelEntry(
        id: 'gpt-6',
        displayName: 'GPT-6',
        contextWindow: 128000,
        temperature: 0.3,
        topP: 0.9,
      );
      AiModelEntry? result;

      await tester.pumpWidget(
        _harness(
          state,
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const ValueKey('open_model_sheet'),
                onPressed: () async {
                  result = await showModalBottomSheet<AiModelEntry>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => ChangeNotifierProvider<AppState>.value(
                      value: state,
                      child: ModelEditorSheet(
                        entry: entry,
                        isNew: false,
                        defaultContextWindow: 128000,
                        defaultMaxTokens: 4096,
                        defaultTemperature: 0.3,
                        isZh: true,
                        cardStyle: 'gray',
                        pillStyle: 'gray',
                        takenIds: const {'other-model'},
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open_model_sheet')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('model_editor_sheet')), findsOneWidget);
      expect(find.text('显示名称'), findsOneWidget);
      expect(find.text('模型 ID'), findsOneWidget);
      expect(find.text('是否启用'), findsOneWidget);
      expect(find.text('上下文'), findsOneWidget);
      expect(find.textContaining('温度'), findsWidgets);
      expect(find.textContaining('Top_P'), findsOneWidget);
      expect(find.text('支持输入'), findsOneWidget);
      expect(find.text('支持输出'), findsOneWidget);
      expect(find.byKey(const ValueKey('model_sheet_enabled')), findsOneWidget);

      // 模态切换：输入 image 同时把 vision 能力补上。
      final inputPills = find.byKey(const ValueKey('model_sheet_input'));
      expect(inputPills, findsOneWidget);
      expect(
        tester.widget<LiquidModalityPills>(inputPills).selected,
        contains(LiquidModalities.text),
      );
      final imagePill = find.byKey(const ValueKey('model_sheet_input_image'));
      await tester.ensureVisible(imagePill);
      await tester.pumpAndSettle();
      await tester.tap(imagePill);
      await tester.pumpAndSettle();
      expect(
        tester.widget<LiquidModalityPills>(inputPills).selected,
        containsAll(<String>[
          LiquidModalities.text,
          LiquidModalities.image,
        ]),
      );

      // ID 重复时不能关闭面板。
      final idField = find.descendant(
        of: find.byKey(const ValueKey('model_sheet_id')),
        matching: find.byType(TextField),
      );
      await tester.ensureVisible(idField);
      await tester.enterText(idField, 'other-model');
      await tester.tap(find.byKey(const ValueKey('model_sheet_done')));
      await tester.pumpAndSettle();
      expect(find.text('该模型已存在'), findsOneWidget);
      expect(result, isNull);

      await tester.enterText(idField, 'gpt-6');
      final nameField = find.descendant(
        of: find.byKey(const ValueKey('model_sheet_display_name')),
        matching: find.byType(TextField),
      );
      await tester.enterText(nameField, 'GPT-6 Turbo');
      await tester.tap(find.byKey(const ValueKey('model_sheet_done')));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.displayName, 'GPT-6 Turbo');
      expect(result!.inputModalities, contains(LiquidModalities.image));
      expect(result!.capabilities, contains(AiModelCapability.vision));
      expect(result!.topP, 0.9);
      await _flushSaveTimers(tester);
    });
  });

  group('MobileAiProviderDetailPage model tab', () {
    testWidgets('should render stretch tabs, dynamic rows and kebab delete', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      state.updateConfig(
        (c) => c
          ..language = 'zh'
          ..cardStyle = 'gray'
          ..pillStyle = 'gray'
          ..navStyle = 'gray',
      );
      final profile = AiProfile(name: 'OpenAI', provider: 'openai');
      profile.models.addAll([
        AiModelEntry(id: 'gpt-6', displayName: 'GPT-6'),
        AiModelEntry(id: 'claude-opus', displayName: 'Claude-opus'),
      ]);
      state.updateConfig((c) {
        c.aiProfiles.add(profile);
        c.activeAiProfileId = profile.id;
        return c;
      });

      await tester.pumpWidget(
        _harness(
          state,
          MobileAiProviderDetailPage(profileId: profile.id),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LiquidStretchTabs), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai_provider_top_tabs')),
        findsOneWidget,
      );

      await tester.tap(find.text('模型'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai_provider_models')), findsOneWidget);
      expect(find.byKey(const ValueKey('model_row_gpt-6')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('model_row_claude-opus')),
        findsOneWidget,
      );
      expect(find.text('GPT-6'), findsOneWidget);
      expect(find.text('gpt-6'), findsOneWidget);
      expect(find.text('Claude-opus'), findsOneWidget);
      expect(find.text('添加自定义模型'), findsOneWidget);
      expect(find.byKey(const ValueKey('add_custom_model')), findsOneWidget);
      // 模型页底部的两个圆形动作药丸（云端获取 / 添加自定义模型）。
      expect(
        find.byKey(const ValueKey('provider_models_fetch_round')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('provider_models_add_round')),
        findsOneWidget,
      );

      // 右上角搜索：输入即过滤，不再整页扫视上百个模型。
      await tester.tap(find.byKey(const ValueKey('provider_model_search')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('provider_model_search_field')),
        'claude',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('model_row_gpt-6')), findsNothing);
      expect(
        find.byKey(const ValueKey('model_row_claude-opus')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('provider_model_search_field')),
        '',
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('model_menu_claude-opus')));
      await tester.pumpAndSettle();
      expect(find.text('删除模型'), findsOneWidget);
      await tester.tap(find.text('删除模型'));
      await tester.pumpAndSettle();
      expect(find.text('删除模型？'), findsOneWidget);
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('model_row_claude-opus')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _flushSaveTimers(tester);
    });

    testWidgets('should add a custom model through the bottom sheet', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      state.updateConfig(
        (c) => c
          ..language = 'zh'
          ..cardStyle = 'gray'
          ..pillStyle = 'gray',
      );
      final profile = AiProfile(name: 'OpenAI', provider: 'openai');
      state.updateConfig((c) {
        c.aiProfiles.add(profile);
        c.activeAiProfileId = profile.id;
        return c;
      });
      await tester.pumpWidget(
        _harness(
          state,
          MobileAiProviderDetailPage(profileId: profile.id),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add_custom_model')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('model_editor_sheet')), findsOneWidget);

      final idField = find.descendant(
        of: find.byKey(const ValueKey('model_sheet_id')),
        matching: find.byType(TextField),
      );
      await tester.enterText(idField, 'gpt-6-mini');
      await tester.tap(find.byKey(const ValueKey('model_sheet_done')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('model_row_gpt-6-mini')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _flushSaveTimers(tester);
    });
  });
}
