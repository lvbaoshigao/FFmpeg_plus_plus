import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_equalizer_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_fade_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_reverse_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_spectrum_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/audio_waveform_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/editor_kit.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/video_fade_step_editor.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/video_reverse_step_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

typedef _EditorBuilder =
    Widget Function(
      Map<String, dynamic> params,
      VoidCallback onChanged,
      bool isZh,
    );

final _editors = <String, _EditorBuilder>{
  'audio_spectrum': (params, onChanged, isZh) =>
      AudioSpectrumStepEditor(params: params, onChanged: onChanged, isZh: isZh),
  'audio_waveform': (params, onChanged, isZh) =>
      AudioWaveformStepEditor(params: params, onChanged: onChanged, isZh: isZh),
  'audio_reverse': (params, onChanged, isZh) =>
      AudioReverseStepEditor(params: params, onChanged: onChanged, isZh: isZh),
  'video_reverse': (params, onChanged, isZh) =>
      VideoReverseStepEditor(params: params, onChanged: onChanged, isZh: isZh),
  'audio_equalizer': (params, onChanged, isZh) => AudioEqualizerStepEditor(
    params: params,
    onChanged: onChanged,
    isZh: isZh,
  ),
  'video_fade': (params, onChanged, isZh) =>
      VideoFadeStepEditor(params: params, onChanged: onChanged, isZh: isZh),
};

Future<void> _pumpEditor(
  WidgetTester tester,
  Widget editor, {
  Size size = const Size(480, 760),
  double textScale = 1,
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(body: editor),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

Future<void> _edit(WidgetTester tester, String key, String value) async {
  final field = _field(key);
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, value);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _choose(WidgetTester tester, String key, String option) async {
  final menu = find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(OptionMenuBar<String>),
  );
  await tester.ensureVisible(menu);
  await tester.pumpAndSettle();
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  group('Audio visualization editors', () {
    for (final type in ['audio_spectrum', 'audio_waveform']) {
      testWidgets('$type should save bounded integer sizes and image formats', (
        tester,
      ) async {
        final params = <String, dynamic>{'common_property': 'preserved'};
        var commits = 0;
        await _pumpEditor(
          tester,
          _editors[type]!(params, () => commits++, false),
        );
        expect(params, {
          'common_property': 'preserved',
          'width': 1280,
          'height': 720,
          'output_format': 'png',
        });
        expect(commits, 0);
        await _edit(tester, '${type}_width', '63');
        expect(params['width'], 1280);
        expect(find.textContaining('Enter an integer'), findsOneWidget);
        await _edit(tester, '${type}_width', '1280.5');
        expect(params['width'], 1280);
        await _edit(tester, '${type}_width', '64');
        await _edit(tester, '${type}_height', '4096');
        expect(params['width'], 64);
        expect(params['width'], isA<int>());
        expect(params['height'], 4096);
        await _edit(tester, '${type}_height', '4097');
        expect(params['height'], 4096);
        await _choose(tester, '${type}_format', 'JPG');
        expect(params['output_format'], 'jpg');
        await _choose(tester, '${type}_format', 'WebP');
        expect(params['output_format'], 'webp');
        expect(params['common_property'], 'preserved');
        expect(commits, greaterThan(0));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('should normalize imported sizes and jpeg without extra keys', (
      tester,
    ) async {
      final params = <String, dynamic>{
        'width': double.nan,
        'height': 9000,
        'output_format': ' JPEG ',
        'metadata': true,
      };
      await _pumpEditor(
        tester,
        AudioSpectrumStepEditor(params: params, onChanged: () {}),
      );
      expect(params, {
        'width': 1280,
        'height': 4096,
        'output_format': 'jpg',
        'metadata': true,
      });
      expect(tester.takeException(), isNull);
    });
  });

  group('Reverse editors', () {
    for (final type in ['audio_reverse', 'video_reverse']) {
      testWidgets('$type should explain resource use without mutating params', (
        tester,
      ) async {
        final params = <String, dynamic>{'common_property': 'keep'};
        var commits = 0;
        await _pumpEditor(
          tester,
          _editors[type]!(params, () => commits++, false),
        );
        expect(params, {'common_property': 'keep'});
        expect(commits, 0);
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(AppSlider), findsNothing);
        expect(find.textContaining('memory'), findsOneWidget);
        expect(find.textContaining('No specific settings'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('AudioEqualizerStepEditor', () {
    testWidgets(
      'should update three bands and reset only equalizer parameters',
      (tester) async {
        final params = <String, dynamic>{'common_property': 'keep'};
        var commits = 0;
        await _pumpEditor(
          tester,
          AudioEqualizerStepEditor(
            params: params,
            onChanged: () => commits++,
            isZh: false,
          ),
        );
        expect(params['bass_db'], 0);
        expect(params['mid_db'], 0);
        expect(params['treble_db'], 0);
        expect(find.textContaining('100 Hz'), findsOneWidget);
        expect(find.textContaining('1 kHz'), findsOneWidget);
        expect(find.textContaining('8 kHz'), findsOneWidget);
        final values = [-12.0, 4.5, 12.0];
        var index = 0;
        for (final key in ['bass_db', 'mid_db', 'treble_db']) {
          final slider = find.descendant(
            of: find.byKey(ValueKey('equalizer_$key')),
            matching: find.byType(AppSlider),
          );
          final control = tester.widget<AppSlider>(slider);
          expect(control.min, -12);
          expect(control.max, 12);
          control.onChanged!(values[index++]);
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(params['bass_db'], -12);
        expect(params['mid_db'], 4.5);
        expect(params['treble_db'], 12);
        final reset = find.byKey(const ValueKey('equalizer_reset'));
        await tester.ensureVisible(reset);
        await tester.pumpAndSettle();
        await tester.tap(reset);
        await tester.pumpAndSettle();
        expect(params, {
          'common_property': 'keep',
          'bass_db': 0.0,
          'mid_db': 0.0,
          'treble_db': 0.0,
        });
        expect(commits, greaterThan(0));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('VideoFadeStepEditor', () {
    testWidgets(
      'should validate durations and preserve explicit start across modes',
      (tester) async {
        final params = <String, dynamic>{'common_property': 'keep'};
        var commits = 0;
        await _pumpEditor(
          tester,
          VideoFadeStepEditor(
            params: params,
            onChanged: () => commits++,
            isZh: false,
          ),
        );
        expect(params['fade_in'], 2);
        expect(params['fade_out'], 2);
        expect(params['fade_out_start'], 0);
        expect(
          find.byKey(const ValueKey('video_fade_out_start')),
          findsNothing,
        );
        await _edit(tester, 'video_fade_in', '-1');
        expect(params['fade_in'], 2);
        await _edit(tester, 'video_fade_in', '60.1');
        expect(params['fade_in'], 2);
        await _edit(tester, 'video_fade_in', '60');
        expect(params['fade_in'], 60);
        await _choose(tester, 'video_fade_start_mode', 'Set time');
        expect(params['fade_out_start'], greaterThan(0));
        await _edit(tester, 'video_fade_out_start', '95.25');
        expect(params['fade_out_start'], 95.25);
        await _edit(tester, 'video_fade_out_start', '0');
        expect(params['fade_out_start'], 95.25);
        await _edit(tester, 'video_fade_out_start', 'NaN');
        expect(params['fade_out_start'], 95.25);
        await _choose(tester, 'video_fade_start_mode', 'Automatic');
        expect(params['fade_out_start'], 0);
        expect(
          find.byKey(const ValueKey('video_fade_out_start')),
          findsNothing,
        );
        await _choose(tester, 'video_fade_start_mode', 'Set time');
        expect(params['fade_out_start'], 95.25);
        await _edit(tester, 'video_fade_out', '0');
        expect(params['fade_out'], 0);
        expect(
          find.byKey(const ValueKey('video_fade_start_mode')),
          findsNothing,
        );
        expect(params['fade_out_start'], 95.25);
        await _edit(tester, 'video_fade_in', '0');
        expect(params['fade_in'], 0);
        expect(params['common_property'], 'keep');
        expect(commits, greaterThan(0));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'should normalize imported duration limits and keep explicit offsets',
      (tester) async {
        final params = <String, dynamic>{
          'fade_in': -2,
          'fade_out': 90,
          'fade_out_start': 120,
        };
        await _pumpEditor(
          tester,
          VideoFadeStepEditor(params: params, onChanged: () {}),
        );
        expect(params['fade_in'], 0);
        expect(params['fade_out'], 60);
        expect(params['fade_out_start'], 120);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Numeric precision', () {
    testWidgets(
      'should preserve short fades and explicit offsets after remount',
      (tester) async {
        final params = <String, dynamic>{'fade_out_start': 1.23456};
        await _pumpEditor(
          tester,
          VideoFadeStepEditor(params: params, onChanged: () {}),
        );
        await _edit(tester, 'video_fade_in', '0.04');
        await _edit(tester, 'video_fade_out', '0.125');
        expect(params['fade_in'], 0.04);
        expect(params['fade_out'], 0.125);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await _pumpEditor(
          tester,
          VideoFadeStepEditor(params: params, onChanged: () {}),
        );
        expect(
          tester.widget<TextField>(_field('video_fade_in')).controller!.text,
          '0.04',
        );
        expect(
          tester.widget<TextField>(_field('video_fade_out')).controller!.text,
          '0.125',
        );
        expect(
          tester
              .widget<TextField>(_field('video_fade_out_start'))
              .controller!
              .text,
          '1.23456',
        );
        expect(params['fade_in'], 0.04);
        expect(params['fade_out_start'], 1.23456);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Node selection state', () {
    for (final (type, fieldKey, parameter, fallback) in const [
      ('audio_spectrum', 'audio_spectrum_width', 'width', 1280),
      ('audio_waveform', 'audio_waveform_width', 'width', 1280),
      ('video_fade', 'video_fade_in', 'fade_in', 2.0),
    ]) {
      testWidgets(
        '$type should discard invalid drafts when selecting another node',
        (tester) async {
          final first = <String, dynamic>{'node': 'first'};
          final firstEditor = _editors[type]!(first, () {}, false);
          await _pumpEditor(tester, firstEditor);
          final previousState = tester.state(
            find.byType(firstEditor.runtimeType),
          );
          final savedFirst = Map<String, dynamic>.of(first);
          await _edit(tester, fieldKey, 'NaN');
          expect(find.textContaining('Enter '), findsOneWidget);
          final second = <String, dynamic>{'node': 'second'};
          await _pumpEditor(tester, _editors[type]!(second, () {}, false));
          expect(
            tester.state(find.byType(firstEditor.runtimeType)),
            same(previousState),
          );
          expect(second[parameter], fallback);
          expect(
            tester.widget<TextField>(_field(fieldKey)).controller!.text,
            fallback == 2.0 ? '2' : fallback.toString(),
          );
          expect(find.textContaining('Enter '), findsNothing);
          await _edit(tester, fieldKey, type == 'video_fade' ? '3.5' : '256');
          expect(second[parameter], type == 'video_fade' ? 3.5 : 256);
          expect(first, savedFirst);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('equalizer should use the newly selected node parameter map', (
      tester,
    ) async {
      final first = <String, dynamic>{'bass_db': 6.0};
      await _pumpEditor(
        tester,
        AudioEqualizerStepEditor(params: first, onChanged: () {}),
      );
      final previousState = tester.state(find.byType(AudioEqualizerStepEditor));
      final second = <String, dynamic>{};
      await _pumpEditor(
        tester,
        AudioEqualizerStepEditor(params: second, onChanged: () {}),
      );
      expect(
        tester.state(find.byType(AudioEqualizerStepEditor)),
        same(previousState),
      );
      final bass = find.descendant(
        of: find.byKey(const ValueKey('equalizer_bass_db')),
        matching: find.byType(AppSlider),
      );
      expect(tester.widget<AppSlider>(bass).value, 0);
      tester.widget<AppSlider>(bass).onChanged!(-4);
      await tester.pump(const Duration(milliseconds: 100));
      expect(second['bass_db'], -4);
      expect(first['bass_db'], 6);
      expect(tester.takeException(), isNull);
    });
  });

  group('Responsive shared editor layout', () {
    for (final entry in _editors.entries) {
      testWidgets(
        '${entry.key} should reflow at 320dp with large text and keyboard',
        (tester) async {
          final params = <String, dynamic>{};
          await _pumpEditor(
            tester,
            entry.value(params, () {}, false),
            size: const Size(320, 640),
            textScale: 2,
            dark: true,
          );
          final heading = find.descendant(
            of: find.byType(StepEditorScaffold),
            matching: find.byType(Semantics),
          );
          expect(
            heading.evaluate().map(
              (element) => (element.widget as Semantics).properties.header,
            ),
            contains(true),
          );
          expect(tester.takeException(), isNull);
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          await tester.pumpAndSettle();
          final textFields = find.byType(TextField);
          if (textFields.evaluate().isNotEmpty) {
            await tester.ensureVisible(textFields.last);
            await tester.pumpAndSettle();
            expect(textFields.last.hitTestable(), findsOneWidget);
          }
          final info = find.byType(EditorInfoBox);
          await tester.ensureVisible(info);
          await tester.pumpAndSettle();
          expect(info.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('should preserve legacy audio fade parameter behavior', (
      tester,
    ) async {
      final params = <String, dynamic>{};
      var commits = 0;
      await _pumpEditor(
        tester,
        AudioFadeStepEditor(
          params: params,
          onChanged: () => commits++,
          isZh: false,
        ),
      );
      final slider = tester.widget<AppSlider>(find.byType(AppSlider).first);
      slider.onChanged!(0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(params['fade_in'], 0);
      expect(params['fade_out'], 2);
      expect(params['curve'], 'tri');
      expect(commits, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  });
}
