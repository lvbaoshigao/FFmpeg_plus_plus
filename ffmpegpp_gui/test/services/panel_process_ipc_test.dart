import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  test(
    'receives coalesced replies when a frame crosses socket chunks',
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
      final requestBuffer = <int>[];
      final requestIds = <int>[];
      var replied = false;
      serverSocket.listen((bytes) {
        requestBuffer.addAll(bytes);
        var newline = requestBuffer.indexOf(10);
        while (newline >= 0) {
          final request =
              jsonDecode(utf8.decode(requestBuffer.sublist(0, newline))) as Map;
          requestIds.add(request['id'] as int);
          requestBuffer.removeRange(0, newline + 1);
          newline = requestBuffer.indexOf(10);
        }
        if (requestIds.length != 2 || replied) return;
        replied = true;
        final first = utf8.encode(
          '{"replyTo":${requestIds[0]},"result":"first"}\n',
        );
        final second = utf8.encode(
          '{"replyTo":${requestIds[1]},"result":"中文面板"}\n',
        );
        final split = second.indexOf(0xe4) + 1;
        serverSocket.add([...first, ...second.take(split)]);
        Future<void>.delayed(const Duration(milliseconds: 10), () {
          serverSocket.add(second.skip(split).toList());
        });
      });

      final replies = await Future.wait([
        client.invoke('first'),
        client.invoke('second'),
      ]).timeout(const Duration(seconds: 5));
      expect(replies, ['first', '中文面板']);

      await client.close();
      await serverSocket.close();
      await server.close();
    },
    skip: !Platform.isLinux,
  );

  test('closes the connection for an over-limit inbound frame', () async {
    final directory = await Directory.systemTemp.createTemp('panel-ipc-test-');
    addTearDown(() => directory.delete(recursive: true));
    final socketPath = '${directory.path}/p.sock';
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final accepted = server.first;
    final writer = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final receiver = PanelProcessIpc(await accepted);
    final closed = Completer<void>();
    receiver.onClosed = closed.complete;

    writer.add(Uint8List(PanelProcessIpc.maxMessageBytes + 1));
    await writer.flush();
    await closed.future.timeout(const Duration(seconds: 5));

    await writer.close();
    await server.close();
  }, skip: !Platform.isLinux);

  test('accepts consecutive inbound frames at the exact byte limit', () async {
    final directory = await Directory.systemTemp.createTemp('panel-ipc-test-');
    addTearDown(() => directory.delete(recursive: true));
    final server = await ServerSocket.bind(
      InternetAddress(
        '${directory.path}/p.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    addTearDown(server.close);
    final accepted = server.first;
    final writer = await Socket.connect(server.address, 0);
    addTearDown(writer.destroy);
    writer.listen((_) {});
    final receiver = PanelProcessIpc(await accepted);
    addTearDown(receiver.close);
    final complete = Completer<void>();
    final lengths = <int>[];
    receiver.onRequest = (method, args) {
      lengths.add((args['payload'] as String).length);
      if (lengths.length == 2) complete.complete();
      return null;
    };
    final envelope = jsonEncode({
      'id': 1,
      'method': 'limit',
      'args': {'payload': ''},
    });
    final payloadSize =
        PanelProcessIpc.maxMessageBytes - utf8.encode(envelope).length;
    final frame = utf8.encode(
      jsonEncode({
        'id': 1,
        'method': 'limit',
        'args': {'payload': 'x' * payloadSize},
      }),
    );
    expect(frame, hasLength(PanelProcessIpc.maxMessageBytes));
    for (var i = 0; i < 2; i++) {
      writer.add(frame);
      writer.add([10]);
    }
    await writer.flush();
    await complete.future.timeout(const Duration(seconds: 5));
    expect(lengths, [payloadSize, payloadSize]);
  }, skip: !Platform.isLinux);
}
