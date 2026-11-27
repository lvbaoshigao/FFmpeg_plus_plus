import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/plugins_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/plugins/plugin_manager.dart';
import 'package:ffmpegpp_gui/plugins/plugin_manifest.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:ffmpegpp_gui/widgets/mobile_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _theme = <String, dynamic>{
  'kind': 'ffmpegpp.theme',
  'schema_version': 1,
  'id': 'smoke',
  'name': 'Smoke theme',
  'values': {'card_style': 'liquid'},
};
const _ai = <String, dynamic>{
  'kind': 'ffmpegpp.ai-config',
  'schema_version': 1,
  'bundle_id': 'example-ai',
  'name': 'Example models',
  'profiles': [
    {
      'source_id': 'example',
      'profile': {
        'name': 'Example provider',
        'provider': 'openai',
        'api_url': 'https://example.org/v1',
        'models': [
          {
            'id': 'example-model',
            'display_name': 'Example model',
            'capabilities': ['chat'],
          },
        ],
      },
    },
  ],
};

PluginManifest _manifest({bool preview = false, bool contributions = false}) =>
    PluginManifest.fromJson({
      'format_version': 1,
      'id': 'org.example.test',
      'api_version': 1,
      'app_version': '>=6.0.0-beta2 <7.0.0',
      'Basic_info': {
        'Name': 'Example plugin',
        'Version': '1.0.0',
        'IsPreview': preview,
        'Summary': 'Host integration test',
      },
      'permissions': {
        'files': {'read': true, 'write': true},
        'network': ['https://example.org'],
      },
      if (contributions) 'themes': [_theme],
      if (contributions) 'ai_configs': [_ai],
    });

final class _PickedPackage extends PlatformFile {
  final Uint8List bytes = Uint8List.fromList([1, 2, 3]);
  @override
  String get name => 'example.fppplugin';
  @override
  Uri get uri => Uri.parse('content://picker/example');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => bytes.length;
  @override
  Future<int?> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _Picker extends FilePickerPlatform {
  final saved = Completer<Uint8List>();
  String? savedName;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _PickedPackage();
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    savedName = fileName;
    saved.complete(bytes);
    return Uri.parse('content://saved/sdk.zip');
  }
}

class _Manager extends PluginManager {
  _Manager(InstalledPlugin plugin)
    : records = [plugin],
      super(
        root: Directory.systemTemp,
        runtime: const UnavailablePluginRuntime(),
        appVersion: '6.0.0-beta2',
      );
  final List<InstalledPlugin> records;
  final calls = <String>[];
  final inspected = Completer<void>();
  bool acknowledged = false;
  Set<String> granted = {};
  @override
  bool get featureEnabled => true;
  @override
  List<InstalledPlugin> get plugins => List.unmodifiable(records);
  @override
  InstalledPlugin? plugin(String id) =>
      records.where((record) => record.manifest.id == id).firstOrNull;
  @override
  Future<void> setEnabled(
    String id,
    bool enabled, {
    bool previewAcknowledged = false,
    Set<String> grantedPermissions = const {},
  }) async {
    calls.add('enabled:$enabled');
    acknowledged = previewAcknowledged;
    granted = grantedPermissions;
    final old = records.single;
    records[0] = InstalledPlugin(
      manifest: old.manifest,
      enabled: enabled,
      hasRollback: old.hasRollback,
      grantedPermissions: grantedPermissions,
    );
    notifyListeners();
  }

  @override
  Future<void> uninstall(String id) async {
    calls.add('uninstall');
    records.clear();
    notifyListeners();
  }

  @override
  Future<void> rollback(String id) async {
    calls.add('rollback');
  }

  @override
  Future<void> selfCheck(String id) async {
    calls.add('selfcheck');
  }

  @override
  Future<PluginPackageInspection> inspectPackage(Uint8List bytes) async {
    calls.add('inspect');
    inspected.complete();
    return PluginPackageInspection(
      manifest: records.single.manifest,
      filePaths: ['manifest.json'],
      hasModule: false,
      compressedSize: bytes.length,
      expandedSize: 100,
    );
  }

  @override
  Future<InstalledPlugin> installPackage(Uint8List bytes) async {
    calls.add('install');
    return records.single;
  }
}

class _PageState extends AppState {
  _PageState(this.manager);
  PluginManager? manager;
  AppConfig fixture = AppConfig()
    ..language = 'en'
    ..cardStyle = 'gray'
    ..menuStyle = 'gray'
    ..pillStyle = 'gray';
  int updates = 0;
  @override
  AppConfig get config => fixture;
  @override
  PluginManager? get plugins => manager;
  @override
  Future<void> updateConfig(AppConfig Function(AppConfig) change) async {
    fixture = change(fixture);
    updates++;
    notifyListeners();
  }
}

Widget _host(_PageState state, {double scale = 1}) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: const Scaffold(body: PluginsPage()),
      ),
    );

Future<void> _menu(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Plugin actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => debugIsMobilePlatformOverride = null);

  testWidgets('uninitialized manager shows a stable empty state', (
    tester,
  ) async {
    final state = _PageState(null);
    await tester.pumpWidget(_host(state));
    expect(find.text('Plugin manager is not initialized.'), findsOneWidget);
    final import = tester.widget<MobileGlassPillAction>(
      find.byWidgetPredicate(
        (widget) =>
            widget is MobileGlassPillAction &&
            widget.icon == Icons.file_download_outlined,
      ),
    );
    expect(import.onTap, isNull);
    final manager = _Manager(InstalledPlugin(manifest: _manifest()));
    state.manager = manager;
    await state.updateConfig((current) => current);
    await tester.pump();
    expect(find.text('Plugin manager is not initialized.'), findsNothing);
    expect(find.text('Example plugin'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    manager.dispose();
  });

  testWidgets(
    'preview acknowledgement gates enable and permissions start denied',
    (tester) async {
      final manager = _Manager(
        InstalledPlugin(manifest: _manifest(preview: true)),
      );
      final state = _PageState(manager);
      await tester.pumpWidget(_host(state));
      await tester.tap(
        find.byKey(const ValueKey('plugin_toggle_org.example.test')),
      );
      await tester.pumpAndSettle();
      final enable = find.widgetWithText(
        FilledButton,
        'Enable and verify metadata',
      );
      expect(tester.widget<FilledButton>(enable).onPressed, isNull);
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((tile) => tile.value == false),
        isTrue,
      );
      await tester.tap(find.text('I understand this preview may be unstable'));
      await tester.tap(find.text('Read private plugin data'));
      await tester.pump();
      expect(tester.widget<FilledButton>(enable).onPressed, isNotNull);
      await tester.tap(enable);
      await tester.pumpAndSettle();
      expect(manager.acknowledged, isTrue);
      expect(manager.granted, {'files.read'});
      expect(manager.calls, ['enabled:true']);
      await tester.tap(
        find.byKey(const ValueKey('plugin_toggle_org.example.test')),
      );
      await tester.pumpAndSettle();
      expect(manager.calls.last, 'enabled:false');
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      manager.dispose();
    },
  );

  testWidgets('cancelled enabling never changes plugin state', (tester) async {
    final manager = _Manager(InstalledPlugin(manifest: _manifest()));
    final state = _PageState(manager);
    await tester.pumpWidget(_host(state));
    await tester.tap(
      find.byKey(const ValueKey('plugin_toggle_org.example.test')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(manager.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    manager.dispose();
  });

  testWidgets(
    'metadata selfcheck and rollback route only to manager after confirmation',
    (tester) async {
      final manager = _Manager(
        InstalledPlugin(manifest: _manifest(), hasRollback: true),
      );
      final state = _PageState(manager);
      await tester.pumpWidget(_host(state));
      await _menu(tester, 'Verify metadata');
      expect(manager.calls, ['selfcheck']);
      await _menu(tester, 'Roll back');
      expect(manager.calls, ['selfcheck']);
      await tester.tap(find.widgetWithText(FilledButton, 'Roll back'));
      await tester.pumpAndSettle();
      expect(manager.calls, ['selfcheck', 'rollback']);
      await _menu(tester, 'Uninstall');
      expect(manager.calls, ['selfcheck', 'rollback']);
      await tester.tap(find.widgetWithText(FilledButton, 'Uninstall'));
      await tester.pumpAndSettle();
      expect(manager.calls.last, 'uninstall');
      expect(find.text('No plugins installed'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      manager.dispose();
    },
  );

  testWidgets('theme contribution is previewed then applied via updateConfig', (
    tester,
  ) async {
    final manager = _Manager(
      InstalledPlugin(manifest: _manifest(contributions: true), enabled: true),
    );
    final state = _PageState(manager);
    await tester.pumpWidget(_host(state));
    await tester.tap(find.text('Smoke theme'));
    await tester.pumpAndSettle();
    expect(find.text('Preview theme import'), findsOneWidget);
    expect(state.config.cardStyle, 'gray');
    expect(state.updates, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply theme settings'));
    await tester.pumpAndSettle();
    expect(state.config.cardStyle, 'liquid');
    expect(state.updates, 1);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    manager.dispose();
  });

  testWidgets(
    'AI import previews suppliers and adds disabled credential-free profiles',
    (tester) async {
      final manager = _Manager(
        InstalledPlugin(
          manifest: _manifest(contributions: true),
          enabled: true,
        ),
      );
      final state = _PageState(manager);
      await tester.pumpWidget(_host(state));
      await tester.tap(find.text('Example models'));
      await tester.pumpAndSettle();
      expect(find.text('Preview AI configuration import'), findsOneWidget);
      expect(find.text('https://example.org/v1'), findsOneWidget);
      expect(state.config.aiProfiles, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await tester.pumpAndSettle();
      expect(state.config.aiProfiles, hasLength(1));
      expect(state.config.aiProfiles.single.enabled, isFalse);
      expect(state.config.aiProfiles.single.apiKey, isEmpty);
      expect(state.config.aiProfiles.single.models.single.id, 'example-model');
      expect(state.config.activeAiProfileId, isEmpty);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      manager.dispose();
    },
  );

  testWidgets('package is inspected before an explicit disabled installation', (
    tester,
  ) async {
    final manager = _Manager(InstalledPlugin(manifest: _manifest()));
    final state = _PageState(manager);
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker();
    addTearDown(() => FilePickerPlatform.instance = previous);
    await tester.pumpWidget(_host(state));
    await tester.tap(find.byTooltip('Import plugin'));
    await tester.pumpAndSettle();
    expect(manager.calls, ['inspect']);
    expect(find.text('Install plugin preview'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Install disabled'));
    await tester.pumpAndSettle();
    expect(manager.calls, ['inspect', 'install']);
    expect(manager.plugins.single.enabled, isFalse);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    manager.dispose();
  });

  testWidgets('SDK export saves real archive bytes through the file picker', (
    tester,
  ) async {
    final state = _PageState(null);
    final picker = _Picker();
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    await tester.pumpWidget(_host(state));
    await tester.tap(find.byTooltip('New plugin · Export SDK'));
    await tester.pumpAndSettle();
    expect(picker.saved.isCompleted, isTrue);
    await tester.pumpAndSettle();
    final archive = ZipDecoder().decodeBytes(await picker.saved.future);
    expect(picker.savedName, 'ffmpegpp-plugin-sdk-v1.zip');
    expect(archive.findFile('include/ffmpegpp_plugin.h'), isNotNull);
    expect(archive.findFile('examples/audio-gain/plugin.c'), isNotNull);
    expect(archive.findFile('tools/build_plugin.py'), isNotNull);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('AI merge targets are explicit and preserve local credentials', (
    tester,
  ) async {
    final manager = _Manager(
      InstalledPlugin(manifest: _manifest(contributions: true), enabled: true),
    );
    final state = _PageState(manager);
    state.fixture.aiProfiles.add(
      AiProfile(
        id: 'local',
        name: 'Local provider',
        provider: 'openai',
        apiUrl: 'https://example.org/v1',
        apiKey: 'keep-secret',
        models: [AiModelEntry(id: 'local-model')],
      ),
    );
    state.fixture.activeAiProfileId = 'local';
    await tester.pumpWidget(_host(state));
    await tester.tap(find.text('Example models'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai_target_example')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge into Local provider').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(state.config.aiProfiles, hasLength(1));
    expect(state.config.aiProfiles.single.apiKey, 'keep-secret');
    expect(state.config.aiProfiles.single.models.map((model) => model.id), [
      'local-model',
      'example-model',
    ]);
    expect(state.config.activeAiProfileId, 'local');
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    manager.dispose();
  });

  testWidgets('contribution confirmation rechecks current plugin state', (
    tester,
  ) async {
    final manager = _Manager(
      InstalledPlugin(manifest: _manifest(contributions: true), enabled: true),
    );
    final state = _PageState(manager);
    await tester.pumpWidget(_host(state));
    await tester.tap(find.text('Smoke theme'));
    await tester.pumpAndSettle();
    await manager.setEnabled('org.example.test', false);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply theme settings'));
    await tester.pumpAndSettle();
    expect(state.updates, 0);
    expect(state.config.cardStyle, 'gray');
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    manager.dispose();
  });

  testWidgets('mobile compact page remains usable at large text scale', (
    tester,
  ) async {
    debugIsMobilePlatformOverride = true;
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final manager = _Manager(
      InstalledPlugin(manifest: _manifest(contributions: true)),
    );
    final state = _PageState(manager);
    await tester.pumpWidget(_host(state, scale: 1.6));
    expect(find.byType(MobilePillTopBar), findsOneWidget);
    expect(
      find.byKey(const ValueKey('plugin_toggle_org.example.test')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    manager.dispose();
  });
}
