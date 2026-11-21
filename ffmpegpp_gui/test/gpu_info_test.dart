import 'dart:io';

import 'package:ffmpegpp_gui/services/gpu_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GpuInfo', () {
    for (final adapter in [
      'Microsoft Basic Display Adapter',
      'Microsoft Remote Desktop Adapter',
    ]) {
      test(
        'should fall back to CIM for $adapter when nvidia-smi is missing',
        () async {
          final executables = <String>[];
          final name = await GpuInfo.detectWindowsName(
            runner: (executable, arguments) async {
              executables.add(executable);
              if (executable == 'nvidia-smi') {
                throw ProcessException(
                  executable,
                  arguments,
                  'File not found',
                  2,
                );
              }
              expect(executable, 'powershell');
              expect(arguments, [
                '-NoProfile',
                '-Command',
                r'(Get-CimInstance Win32_VideoController).Name',
              ]);
              return ProcessResult(1, 0, '  $adapter\r\n', '');
            },
          );

          expect(executables, ['nvidia-smi', 'powershell']);
          expect(name, adapter);
          expect(GpuInfo.isSoftwareRendered(name), isTrue);
        },
      );
    }

    test('should avoid CIM when nvidia-smi succeeds', () async {
      final executables = <String>[];
      final name = await GpuInfo.detectWindowsName(
        runner: (executable, arguments) async {
          executables.add(executable);
          expect(executable, 'nvidia-smi');
          expect(arguments, [
            '--query-gpu=name',
            '--format=csv,noheader,nounits',
          ]);
          return ProcessResult(1, 0, ' NVIDIA GeForce RTX 4090\r\n', '');
        },
      );

      expect(executables, ['nvidia-smi']);
      expect(name, 'NVIDIA GeForce RTX 4090');
    });

    test(
      'should still fall back to CIM when nvidia-smi exits unsuccessfully',
      () async {
        final executables = <String>[];
        final name = await GpuInfo.detectWindowsName(
          runner: (executable, arguments) async {
            executables.add(executable);
            return executable == 'nvidia-smi'
                ? ProcessResult(1, 1, '', 'No NVIDIA GPU')
                : ProcessResult(2, 0, 'Microsoft Basic Render Driver\n', '');
          },
        );

        expect(executables, ['nvidia-smi', 'powershell']);
        expect(name, 'Microsoft Basic Render Driver');
      },
    );

    test('should return null when both Windows probes are missing', () async {
      final executables = <String>[];
      final name = await GpuInfo.detectWindowsName(
        runner: (executable, arguments) async {
          executables.add(executable);
          throw ProcessException(executable, arguments, 'File not found', 2);
        },
      );

      expect(executables, ['nvidia-smi', 'powershell']);
      expect(name, isNull);
    });
  });
}
