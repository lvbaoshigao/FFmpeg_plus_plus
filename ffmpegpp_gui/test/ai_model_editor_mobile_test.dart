import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_mobile_nav.dart';
import 'package:ffmpegpp_gui/widgets/liquid_modality_pills.dart';
import 'package:ffmpegpp_gui/widgets/model_editor_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _harness(
  AppState state,
  Widget child, {
  ThemeData? theme,
  TextScaler textScaler = TextScaler.noScaling,
}) => ChangeNotifierProvider<AppState>.value(
  value: state,
  child: MaterialApp(
    theme: theme ?? AppTheme.dark(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: Scaffold(body: child),
  ),
);

Finder _modelField(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

Future<void> _openEditor(
  WidgetTester tester,
  AppState state, {
  required AiModelEntry entry,
  required ValueChanged<AiModelEntry?> onResult,
  bool isZh = true,
  bool isNew = false,
  ThemeData? theme,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    _harness(
      state,
      Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const ValueKey('open_model_sheet'),
            onPressed: () async {
              onResult(
                await showModalBottomSheet<AiModelEntry>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => ModelEditorSheet(
                    entry: entry,
                    isNew: isNew,
                    defaultContextWindow: 128000,
                    defaultMaxTokens: 4096,
                    defaultTemperature: 0.3,
                    isZh: isZh,
                    cardStyle: 'gray',
                    pillStyle: 'gray',
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
      theme: theme,
      textScaler: textScaler,
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open_model_sheet')));
  await tester.pumpAndSettle();
}

Future<void> _flushSaveTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
}

/// 底栏标签的点击目标。
///
/// AppLiquidTabBar（liquid_glass_tab_bar）会把每个 item 绘制两次（未选中色
/// 与选中色两层，由滑动玻璃胶囊裁剪），所以 find.text 会命中 2 个 Text；
/// 这里限定在底栏内并取第一层，避免 tap 报 "ambiguously found"。
Finder _tabLabel(String label) => find
    .descendant(of: find.byType(AppLiquidTabBar), matching: find.text(label))
    .first;

void main() {
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
        containsAll(<String>[LiquidModalities.text, LiquidModalities.image]),
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

    testWidgets('should keep edits local when canceled from the footer', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      final entry = AiModelEntry(
        id: 'saved-model',
        displayName: 'Saved model',
        contextWindow: 32000,
        maxTokens: 1000,
        temperature: 0.7,
        topP: 0.8,
      );
      final original = entry.copy().toJson();
      var didClose = false;
      AiModelEntry? result;
      await _openEditor(
        tester,
        state,
        entry: entry,
        onResult: (value) {
          didClose = true;
          result = value;
        },
      );
      await tester.enterText(
        _modelField('model_sheet_display_name'),
        'Changed',
      );
      await tester.enterText(_modelField('model_sheet_id'), 'changed-model');
      final enabled = find.byKey(const ValueKey('model_sheet_enabled'));
      await tester.ensureVisible(enabled);
      await tester.pumpAndSettle();
      await tester.tap(enabled);
      final image = find.byKey(const ValueKey('model_sheet_input_image'));
      await tester.ensureVisible(image);
      await tester.pumpAndSettle();
      await tester.tap(image);
      final reset = find.byKey(const ValueKey('model_sheet_reset_defaults'));
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('model_sheet_cancel')));
      await tester.pumpAndSettle();
      expect(didClose, isTrue);
      expect(result, isNull);
      expect(entry.toJson(), original);
      expect(tester.takeException(), isNull);
      await _flushSaveTimers(tester);
    });

    testWidgets(
      'should reset advanced overrides without changing capabilities',
      (tester) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final state = AppState();
        addTearDown(state.dispose);
        final entry = AiModelEntry(
          id: 'saved-model',
          contextWindow: 32000,
          maxTokens: 1000,
          temperature: 0.7,
          topP: 0.8,
          capabilities: [AiModelCapability.chat, AiModelCapability.tools],
          inputModalities: [LiquidModalities.voice, LiquidModalities.text],
        );
        AiModelEntry? result;
        await _openEditor(
          tester,
          state,
          entry: entry,
          onResult: (value) => result = value,
        );
        final reset = find.byKey(const ValueKey('model_sheet_reset_defaults'));
        await tester.ensureVisible(reset);
        await tester.pumpAndSettle();
        await tester.tap(reset);
        await tester.pumpAndSettle();
        expect(tester.widget<TextButton>(reset).onPressed, isNull);
        expect(
          tester
              .widget<TextField>(_modelField('model_sheet_context'))
              .controller!
              .text,
          isEmpty,
        );
        expect(
          tester
              .widget<TextField>(_modelField('model_sheet_max_tokens'))
              .controller!
              .text,
          isEmpty,
        );
        expect(find.text('温度: 0.3'), findsOneWidget);
        expect(find.text('Top_P: 1.00'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('model_sheet_done')));
        await tester.pumpAndSettle();
        expect(result, isNotNull);
        expect(result!.contextWindow, isNull);
        expect(result!.maxTokens, isNull);
        expect(result!.temperature, isNull);
        expect(result!.topP, isNull);
        expect(result!.capabilities, entry.capabilities);
        expect(result!.inputModalities, entry.inputModalities);
        expect(entry.contextWindow, 32000);
        expect(entry.temperature, 0.7);
        expect(tester.takeException(), isNull);
        await _flushSaveTimers(tester);
      },
    );

    testWidgets(
      'should wrap capabilities and keep footer above a keyboard at 320dp',
      (tester) async {
        tester.view.physicalSize = const Size(320, 680);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final state = AppState();
        addTearDown(state.dispose);
        final entry = AiModelEntry(
          id: 'legacy-vision',
          capabilities: [AiModelCapability.chat, AiModelCapability.vision],
        );
        final theme = AppTheme.light();
        AiModelEntry? result;
        await _openEditor(
          tester,
          state,
          entry: entry,
          isZh: false,
          theme: theme,
          textScaler: const TextScaler.linear(2),
          onResult: (value) => result = value,
        );
        final material = tester.widget<Material>(
          find.byKey(const ValueKey('model_editor_sheet')),
        );
        expect(material.color, theme.bottomSheetTheme.backgroundColor);
        expect(material.shape, theme.bottomSheetTheme.shape);
        expect(
          tester.widget(find.byKey(const ValueKey('model_sheet_input'))),
          isA<Wrap>(),
        );
        final text = find.byKey(const ValueKey('model_sheet_input_text'));
        final image = find.byKey(const ValueKey('model_sheet_input_image'));
        final voice = find.byKey(const ValueKey('model_sheet_input_voice'));
        expect(
          tester.getTopLeft(voice).dy,
          greaterThan(tester.getTopLeft(text).dy),
        );
        final imageChip = find.descendant(
          of: image,
          matching: find.byType(FilterChip),
        );
        expect(tester.widget<FilterChip>(imageChip).selected, isTrue);
        await tester.ensureVisible(image);
        await tester.pumpAndSettle();
        await tester.tap(image);
        await tester.pump();
        expect(tester.widget<FilterChip>(imageChip).selected, isFalse);
        await tester.ensureVisible(voice);
        await tester.pumpAndSettle();
        for (var move = 0; move < 2; move++) {
          final reorder = tester
              .widget<Semantics>(voice)
              .properties
              .customSemanticsActions!;
          reorder.entries
              .singleWhere((entry) => entry.key.label == 'Move left')
              .value();
          await tester.pump();
        }
        await tester.ensureVisible(voice);
        await tester.pumpAndSettle();
        await tester.tap(voice);
        await tester.pumpAndSettle();

        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        final maxTokens = _modelField('model_sheet_max_tokens');
        await tester.ensureVisible(maxTokens);
        await tester.pumpAndSettle();
        await tester.enterText(maxTokens, '8192');
        await tester.pumpAndSettle();
        final done = find.byKey(const ValueKey('model_sheet_done'));
        final cancel = find.byKey(const ValueKey('model_sheet_cancel'));
        expect(tester.getRect(done).bottom, lessThanOrEqualTo(420));
        expect(tester.getSize(done).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
        expect(done.hitTestable(), findsOneWidget);
        expect(cancel.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(done);
        await tester.pumpAndSettle();
        expect(result!.maxTokens, 8192);
        expect(result!.contextWindow, isNull);
        expect(result!.temperature, isNull);
        expect(result!.topP, isNull);
        expect(result!.inputModalities, [
          LiquidModalities.voice,
          LiquidModalities.text,
        ]);
        expect(result!.capabilities, isNot(contains(AiModelCapability.vision)));
        expect(entry.capabilities, contains(AiModelCapability.vision));
        await _flushSaveTimers(tester);
      },
    );
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
        _harness(state, MobileAiProviderDetailPage(profileId: profile.id)),
      );
      await tester.pumpAndSettle();
      // 底栏统一为主界面同模块的 AppLiquidTabBar（liquid_glass_tab_bar）；
      // Key 保持不变以免其它用例漂移。
      expect(find.byType(AppLiquidTabBar), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai_provider_top_tabs')),
        findsOneWidget,
      );

      await tester.tap(_tabLabel('模型'));
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
      // 增 / 删 / 清空三个入口统一为底栏的圆形玻璃按钮（与「基本 / 模型」
      // 切换栏同一处），列表顶部原来的「从云端获取模型列表」大卡已按用户要求删除。
      expect(
        find.byKey(const ValueKey('provider_models_fetch_round')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('provider_models_add_round')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('provider_models_clear_round')),
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
      expect(find.byKey(const ValueKey('model_row_claude-opus')), findsNothing);
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
        _harness(state, MobileAiProviderDetailPage(profileId: profile.id)),
      );
      await tester.pumpAndSettle();
      await tester.tap(_tabLabel('模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('provider_models_add_round')));
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
