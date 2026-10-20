import 'dart:io';

import 'package:ffmpegpp_gui/services/panel_process_ipc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'requests and replies work in both directions over a Unix socket',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'panel-ipc-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final socketPath = '${directory.path}/p.sock';
      final server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      final accepted = server.first;
      final clientSocket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      final serverSocket = await accepted;
      final client = PanelProcessIpc(clientSocket);
      final host = PanelProcessIpc(serverSocket);
      client.onRequest = (method, args) => '$method:${args['value']}';
      host.onRequest = (method, args) => {
        'method': method,
        'value': args['value'],
      };

      expect(await client.invoke('guest.request', {'value': 7}), {
        'method': 'guest.request',
        'value': 7,
      });
      expect(
        await host.invoke('host.push', {'value': 'snapshot'}),
        'host.push:snapshot',
      );

      await client.close();
      await host.close();
      await server.close();
    },
    skip: !Platform.isLinux,
  );

  test('oversized requests are rejected before being sent', () async {
    final directory = await Directory.systemTemp.createTemp('panel-ipc-test-');
    addTearDown(() => directory.delete(recursive: true));
    final socketPath = '${directory.path}/p.sock';
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final accepted = server.first;
    final clientSocket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final serverSocket = await accepted;
    final client = PanelProcessIpc(clientSocket);
    final peer = PanelProcessIpc(serverSocket);

    await expectLater(
      client.invoke('oversized', {
        'payload': 'x' * PanelProcessIpc.maxMessageBytes,
      }),
      throwsA(isA<StateError>()),
    );

    await client.close();
    await peer.close();
    await server.close();
  }, skip: !Platform.isLinux);
}
