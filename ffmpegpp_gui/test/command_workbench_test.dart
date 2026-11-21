import 'dart:io';

import 'package:ffmpegpp_gui/pages/command_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _CommandState extends AppState {
  final submitted = <({String input, String output, String command})>[];

  @override
  void addCustomTask({
    required String inputPath,
    required String outputPath,
    required String command,
    required String filename,
  }) => submitted.add((input: inputPath, output: outputPath, command: command));
}

void main() {
  group('CommandPage desktop workbench', () {
    late _CommandState state;

    setUp(() {
      state = _CommandState();
      state.config
        ..language = 'en'
        ..menuStyle = 'gray';
    });
    tearDown(() => state.dispose());

    Future<void> showPage(
      WidgetTester tester,
      Size size, {
      double textScale = 1,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                textScaler: TextScaler.linear(textScale),
              ),
              child: child!,
            ),
            home: const CommandPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'should insert a template, queue a command and clear activity',
      (tester) async {
        final temp = Directory.systemTemp.createTempSync('ffpp-command-');
        addTearDown(() => temp.deleteSync(recursive: true));
        final input = File.fromUri(temp.uri.resolve('input clip.mp4'))
          ..createSync();
        final output = File.fromUri(temp.uri.resolve('output clip.mp4'));
        final command = 'ffmpeg -i "${input.path}" -c:v copy "${output.path}"';
        await showPage(tester, const Size(1440, 880));

        final editor = find.byType(TextField);
        final template = find.text('H.264 Transcode');
        final reference = find.text('Option reference');
        expect(
          tester.getTopLeft(reference).dx,
          greaterThan(tester.getTopLeft(editor).dx),
        );
        expect(find.text('No command activity yet'), findsOneWidget);
        await tester.tap(template);
        await tester.pump();
        final field = tester.widget<TextField>(editor);
        expect(field.controller!.text, contains('-c:v libx264'));
        expect(field.focusNode!.hasFocus, isTrue);

        await tester.enterText(editor, 'ffmpeg -cr');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(field.controller!.text, 'ffmpeg -crf ');

        await tester.enterText(editor, command);
        await tester.tap(find.text('Add to queue'));
        await tester.pumpAndSettle();
        expect(state.submitted.single, (
          input: input.path,
          output: output.path,
          command: command,
        ));
        expect(find.textContaining('Queued: input clip.mp4'), findsWidgets);
        expect(field.controller!.text, isEmpty);

        await tester.tap(find.byTooltip('Clear activity'));
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.text('No command activity yet'), findsOneWidget);
      },
    );

    testWidgets('should stack controls in a narrow large-text window', (
      tester,
    ) async {
      await showPage(tester, const Size(340, 650), textScale: 2);
      final queue = find.text('Add to queue');
      final templates = find.text('Quick templates');
      expect(
        tester.getTopLeft(queue).dy,
        lessThan(tester.getTopLeft(templates).dy),
      );
      await tester.ensureVisible(find.text('Option reference'));
      await tester.pumpAndSettle();
      expect(find.text('Option reference').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
