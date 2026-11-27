import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/config_library_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/backend_client.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/services/fppx2_service.dart';
import 'package:ffmpegpp_gui/services/native_process.dart';
import 'package:ffmpegpp_gui/services/quick_config_json_codec.dart';
import 'package:ffmpegpp_gui/services/quick_config_storage.dart';
import 'package:ffmpegpp_gui/services/saved_config_application.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

QuickConfig _fixture({bool legacy = false}) => QuickConfig(
  id: 'original-id',
  name: 'Audio preset',
  description: 'Public description',
  fileType: QuickFileType.audio,
  createdAt: DateTime.utc(2026, 1, 2),
  updatedAt: DateTime.utc(2026, 3, 4),
  items: [
    QuickConfigItem(
      key: 'bitrate',
      title: 'fallback',
      titleZh: '码率',
      titleEn: 'Bitrate',
      params: {
        'bitrate': 192,
        'nested': {
          'list': [1, true, null],
        },
      },
      enabled: false,
    ),
  ],
  nodes: legacy
      ? null
      : [
          PipelineNode(
            id: 'first',
            type: PipelineStepType.audioVolume,
            params: {
              'volume_db': -6.0,
              'nested': {
                'list': [1, 2],
              },
            },
            x: 34,
            y: 56,
          ),
          PipelineNode(
            id: 'second',
            type: PipelineStepType.audioVolume,
            params: {'volume_db': 3.0},
          ),
        ],
  inputParams: {'file_media_type': 'audio', 'filepath': '/private/input.wav'},
  outputParams: {
    'output_dir': '/keep/me',
    'format': 'flac',
    'naming_value': '_done',
  },
);

class _LibraryConfig extends ConfigService {
  @override
  Future<List<Map<String, dynamic>>> loadLibrary() async => [];
}

class _LibraryState extends AppState {
  final _settings = _LibraryConfig();
  @override
  ConfigService get configService => _settings;
}

final class _PickedFile extends PlatformFile {
  _PickedFile(this.file);
  final File file;
  @override
  String get name => file.uri.pathSegments.last;
  @override
  Uri get uri => Uri.parse('content://picker/import.JSON');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => file.lengthSync();
  @override
  Future<int?> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

class _Picker extends FilePickerPlatform {
  Uint8List? savedBytes;
  String? savedName;
  String? savedMime;
  PlatformFile? picked;
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
    savedBytes = bytes;
    savedMime = mimeType;
    return Uri.file('/export/$fileName');
  }

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
  }) async => picked;
}

void main() {
  late BackendClient backend;
  late QuickConfigJsonCodec codec;
  setUp(() {
    backend = BackendClient(NativeProcessManager());
    codec = QuickConfigJsonCodec(
      FppxService(backend),
      temporaryDirectory: () async =>
          throw StateError('Plain JSON must not use disk or native crypto'),
    );
  });
  tearDown(() => backend.dispose());

  for (final legacy in [false, true]) {
    test('plain JSON preserves every editable field, legacy=$legacy', () async {
      final fixture = _fixture(legacy: legacy);
      final encoded = await codec.encode(fixture);
      final restored = await codec.decode(encoded);
      expect(restored.toJson(), fixture.toJson());
      expect(restored.nodes == null, legacy);
      final imported = await codec.decode(encoded, id: 'new-import-id');
      expect(imported.toJson(), {...fixture.toJson(), 'id': 'new-import-id'});
      expect(fixture.id, 'original-id');
    });
  }

  test('raw local quick JSON and UTF-8 BOM remain importable', () async {
    final fixture = _fixture();
    expect(
      (await codec.decode('\uFEFF${jsonEncode(fixture.toJson())}')).toJson(),
      fixture.toJson(),
    );
  });

  test(
    'historical raw quick JSON infers missing file_type before application',
    () async {
      final restored = await codec.decode(
        jsonEncode({
          'id': 'legacy-image',
          'name': 'Legacy PNG export',
          'items': [
            {
              'key': 'convert_format',
              'params': {'format': 'png'},
            },
          ],
          'input_params': {
            'node_name': 'Historical image input',
            'filepath': '/author/old.jpg',
          },
          'output_params': {
            'output_dir': '/historical/exports',
            'naming_mode': 'suffix',
            'naming_value': '_png',
          },
        }),
      );
      expect(restored.fileType, QuickFileType.image);
      expect(restored.nodes, isNull);
      final applied = SavedConfigChoice.quick(
        restored,
      ).prepare(VideoFile.fromFilepath('/current/image.jpg'), isZh: false);
      expect(applied.nodes.first.params['file_media_type'], 'image');
      expect(applied.nodes.first.params['filepath'], isNull);
      expect(applied.nodes.last.params['output_dir'], '/historical/exports');
      expect(applied.nodes.last.params['naming_mode'], 'suffix');
      expect(applied.nodes.last.params['naming_value'], '_png');
    },
  );

  test(
    'explicit invalid raw file_type cannot silently fall back to inference',
    () async {
      for (final invalid in ['future-media', 99, null]) {
        await expectLater(
          codec.decode(
            jsonEncode({
              'file_type': invalid,
              'items': [
                {
                  'key': 'convert_format',
                  'params': {'format': 'png'},
                },
              ],
            }),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('malformed JSON cannot silently become a partial preset', () async {
    final badItems = _fixture().toJson()..['items'] = [42];
    final badParams = _fixture().toJson()
      ..['items'] = [
        {'key': 'bitrate', 'params': 42},
      ];
    final badNodes = _fixture().toJson()
      ..['nodes'] = [
        {'id': 'x', 'type': 'future-node'},
      ];
    for (final value in [
      [],
      {},
      {'format': QuickConfigJsonCodec.format, 'version': 99},
      badItems,
      badParams,
      badNodes,
      {
        'format': QuickConfigJsonCodec.format,
        'version': 1,
        'encrypted': true,
        'encoding': 'fppx2-base64',
        'payload': '%%%',
      },
    ]) {
      await expectLater(codec.decode(jsonEncode(value)), throwsFormatException);
    }
  });

  test('empty encryption password fails before invoking the backend', () async {
    await expectLater(
      codec.encode(_fixture(), encrypted: true),
      throwsFormatException,
    );
  });

  testWidgets('library exports JSON and imports a separate quick preset', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    final directory = Directory.systemTemp.createTempSync(
      'quick-json-library-',
    );
    final previousDirectory = QuickConfigStorage.directoryOverride;
    final previousPicker = FilePickerPlatform.instance;
    final picker = _Picker();
    FilePickerPlatform.instance = picker;
    QuickConfigStorage.directoryOverride = directory;
    final state = _LibraryState();
    state.config
      ..language = 'en'
      ..cardStyle = 'gray'
      ..pillStyle = 'gray'
      ..menuStyle = 'gray'
      ..glassEffect = 'gray';
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      FilePickerPlatform.instance = previousPicker;
      QuickConfigStorage.directoryOverride = previousDirectory;
      await directory.delete(recursive: true);
    });
    final fixture = _fixture();
    await tester.runAsync(() async {
      await QuickConfigStorage.save(fixture);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: ConfigLibraryPage())),
        ),
      );
      await QuickConfigStorage.loadAll(null);
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quick Config'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Export quick config (JSON / FPPX)'));
    await tester.pumpAndSettle();
    expect(find.text('JSON (.json)'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Export'));
    await tester.pumpAndSettle();
    expect(picker.savedName, 'Audio preset.json');
    expect(picker.savedMime, 'application/json');
    final encoded = utf8.decode(picker.savedBytes!);
    expect((await codec.decode(encoded)).toJson(), fixture.toJson());
    final file = File('${directory.path}/import.JSON');
    await tester.runAsync(() => file.writeAsString(encoded));
    picker.picked = _PickedFile(file);
    final action = tester.widget<MobileGlassPillAction>(
      find.byWidgetPredicate(
        (widget) =>
            widget is MobileGlassPillAction &&
            widget.tooltip == 'Import Config',
      ),
    );
    // Await the actual asynchronous button callback instead of racing file I/O
    // against fake-async pumpAndSettle.
    await tester.runAsync(() async {
      await Function.apply(action.onTap!, const []);
    });
    await tester.pumpAndSettle();
    final configs = await tester.runAsync(
      () => QuickConfigStorage.loadAll(null),
    );
    expect(configs, hasLength(2));
    expect(configs!.map((config) => config.id).toSet(), hasLength(2));
    final imported = configs.firstWhere((config) => config.id != fixture.id);
    expect(imported.toJson(), {...fixture.toJson(), 'id': imported.id});
    expect(find.text('Audio preset'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  const nativeLibrary = String.fromEnvironment('FFMPEGPP_TEST_LIBRARY');
  group(
    'native AES JSON envelopes',
    () {
      late NativeProcessManager process;
      late BackendClient nativeBackend;
      late QuickConfigJsonCodec encryptedCodec;
      late Directory directory;
      setUpAll(() async {
        directory = await Directory.systemTemp.createTemp('quick-json-aes-');
        process = NativeProcessManager();
        nativeBackend = BackendClient(process);
        encryptedCodec = QuickConfigJsonCodec(
          FppxService(nativeBackend),
          temporaryDirectory: () async => directory,
        );
        await process.start(nativeLibrary);
      });
      tearDownAll(() async {
        nativeBackend.dispose();
        process.dispose();
        await directory.delete(recursive: true);
      });
      for (final algorithm in [
        FppxService.algoAes128Cbc,
        FppxService.algoAes256Cbc,
      ]) {
        for (final legacy in [false, true]) {
          test(
            'AES $algorithm preserves fields and rejects wrong passwords, legacy=$legacy',
            () async {
              final fixture = _fixture(legacy: legacy);
              final encoded = await encryptedCodec.encode(
                fixture,
                encrypted: true,
                password: 'correct-password',
                encryptAlgo: algorithm,
              );
              final envelope = jsonDecode(encoded) as Map<String, dynamic>;
              expect(envelope['encrypted'], isTrue);
              expect(envelope.containsKey('config'), isFalse);
              expect(encoded, isNot(contains('/private/input.wav')));
              expect(encoded, isNot(contains('correct-password')));
              expect(encoded, isNot(contains('volume_db')));
              await expectLater(
                encryptedCodec.decode(encoded),
                throwsA(isA<QuickConfigJsonPasswordRequired>()),
              );
              await expectLater(
                encryptedCodec.decode(encoded, password: 'wrong-password'),
                throwsA(isA<QuickConfigJsonPasswordException>()),
              );
              final restored = await encryptedCodec.decode(
                encoded,
                password: 'correct-password',
              );
              expect(restored.toJson(), fixture.toJson());
              final payload = base64Decode(envelope['payload'] as String);
              payload[payload.length - 8] ^= 1;
              envelope['payload'] = base64Encode(payload);
              await expectLater(
                encryptedCodec.decode(
                  jsonEncode(envelope),
                  password: 'correct-password',
                ),
                throwsA(isA<QuickConfigJsonPasswordException>()),
              );
              expect(
                await directory.list().toList(),
                isEmpty,
                reason:
                    'temporary ciphertext must be cleaned after success and failure',
              );
            },
          );
        }
      }
    },
    skip: nativeLibrary.isEmpty
        ? 'Set FFMPEGPP_TEST_LIBRARY for native AES integration'
        : false,
  );
}
