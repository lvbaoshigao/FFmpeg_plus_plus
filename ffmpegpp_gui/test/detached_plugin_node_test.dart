import 'dart:convert';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/models/node_picker_options.dart';
import 'package:ffmpegpp_gui/pages/detached_window_page.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/plugins/plugin_node_catalog.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/multi_window.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/node_category_filter.dart';
import 'package:ffmpegpp_gui/widgets/plugin_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'plugin_node_test.dart' as fixture;

typedef HostCall = ({String method, Map<String, dynamic> args});
PanelWindowStore storeFor(
  List<HostCall> calls, {
  bool enabled = true,
  bool editable = true,
}) {
  final store = PanelWindowStore(
    const DetachedWindowArgs(panel: DetachedPanel.elements, lang: 'en'),
    send: (method, [args]) async {
      calls.add((
        method: method,
        args: Map<String, dynamic>.from(
          jsonDecode(jsonEncode(args ?? <String, dynamic>{})) as Map,
        ),
      ));
      return true;
    },
  );
  store.hydrate({
    "config":
        (AppConfig(pluginsEnabled: enabled)
              ..language = "en"
              ..cardStyle = "gray"
              ..menuStyle = "gray"
              ..pillStyle = "gray")
            .toJson(),
    'video': {'fileMediaType': 'audio'},
    'selection': fixture.pluginNode(fixture.fixture()).toJson(),
    'props': {'pluginEditable': editable},
    'toolbox': [
      {
        'kind': 'plugin',
        'id': 'plugin:org.ffmpegpp.volume/volume',
        'label': 'Volume plugin',
        'tag': 'audio',
      },
    ],
  });
  addTearDown(store.dispose);
  return store;
}

Future<void> mount(
  WidgetTester tester,
  PanelWindowStore store,
  Widget child,
) async {
  tester.view.physicalSize = const Size(600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: store.app,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => PluginNodeCatalog.instance.clear());
  tearDown(() => PluginNodeCatalog.instance.clear());
  testWidgets('disabled feature hides detached plugin category', (
    tester,
  ) async {
    final calls = <HostCall>[];
    final store = storeFor(calls, enabled: false);
    await mount(tester, store, DetachedNodeToolbox(store: store));
    final filter = tester.widget<NodeCategoryFilter>(
      find.byKey(const ValueKey('detached-node-category')),
    );
    expect(filter.categories, isNot(contains(NodePickerCategory.plugin)));
    expect(calls, isEmpty);
  });
  testWidgets(
    'detached plugin entry relays stable id without invoking runtime',
    (tester) async {
      final calls = <HostCall>[];
      final store = storeFor(calls);
      await mount(tester, store, DetachedNodeToolbox(store: store));
      await tester.tap(
        find.byKey(const ValueKey('detached-node-category-plugin')),
      );
      await tester.pumpAndSettle();
      final item = find.byKey(
        const ValueKey('detached-plugin-plugin:org.ffmpegpp.volume/volume'),
      );
      expect(item, findsOneWidget);
      await tester.tap(item);
      await tester.pump();
      expect(calls, hasLength(1));
      expect(calls.single.method, PanelMethod.addNode);
      expect(calls.single.args['typeId'], 'plugin:org.ffmpegpp.volume/volume');
      expect(calls.single.args['nodeId'], isA<String>());
      expect(PluginNodeCatalog.instance.entries, isEmpty);
    },
  );
  testWidgets(
    'missing plugin uses host-controlled read-only form and preserves data',
    (tester) async {
      final calls = <HostCall>[];
      final store = storeFor(calls, editable: false);
      final before = jsonEncode(store.selected!.toJson());
      await mount(
        tester,
        store,
        buildDetachedNodeEditor(store, store.selected!),
      );
      expect(
        tester.widget<PluginForm>(find.byType(PluginForm)).enabled,
        isFalse,
      );
      expect(calls, isEmpty);
      expect(jsonEncode(store.selected!.toJson()), before);
    },
  );
  testWidgets('main process validates detached create and parameter updates', (
    tester,
  ) async {
    const channel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final manifest = fixture.fixture();
    PluginNodeCatalog.instance.replaceAll([manifest]);
    final state = AppState();
    state.config
      ..pluginsEnabled = true
      ..aiEnabled = false
      ..language = 'en'
      ..cardStyle = 'gray'
      ..menuStyle = 'gray'
      ..pillStyle = 'gray';
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: PipelineEditorPage(
            video: VideoFile(id: 'plugin-host', filename: 'Template.wav'),
            onSave: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    final host =
        tester.state(find.byType(PipelineEditorPage)) as PanelHostDelegate;
    final created = await host.onPanelRequest(PanelMethod.addNode, {
      'typeId': 'plugin:org.ffmpegpp.volume/volume',
      'nodeId': 'client-plugin',
    });
    expect(created, 'client-plugin');
    final graph = host.panelSnapshot(DetachedPanel.ai)['graph'] as Map;
    final node = (graph['nodes'] as List).cast<Map>().singleWhere(
      (node) => node['id'] == 'client-plugin',
    );
    final params = PipelineNode.deepCopyMap(
      Map<String, dynamic>.from(node['params'] as Map),
    );
    (params['values'] as Map)['gain'] = -8;
    expect(
      await host.onPanelRequest(PanelMethod.setParams, {
        'nodeId': 'client-plugin',
        'params': params,
      }),
      isTrue,
    );
    (params['_plugin'] as Map)['id'] = 'org.attacker.changed';
    expect(
      await host.onPanelRequest(PanelMethod.setParams, {
        'nodeId': 'client-plugin',
        'params': params,
      }),
      isFalse,
    );
    state.config.pluginsEnabled = false;
    expect(
      await host.onPanelRequest(PanelMethod.addNode, {
        'typeId': 'plugin:org.ffmpegpp.volume/volume',
        'nodeId': 'disabled-plugin',
      }),
      isFalse,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
