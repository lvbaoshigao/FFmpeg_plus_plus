import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpegpp_gui/plugins/plugin_manifest.dart';
import 'package:ffmpegpp_gui/plugins/plugin_permissions.dart';
import 'package:ffmpegpp_gui/plugins/plugin_runtime.dart';
import 'package:ffmpegpp_gui/plugins/plugin_storage.dart'
    hide validatePluginRelativePath;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late PluginStorage storage;
  late PluginPermissionHost host;
  late List<Uri> urls;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fpp-plugin-permissions-');
    storage = PluginStorage(root);
    await storage.initialize();
    urls = [];
    host = PluginPermissionHost(
      storage,
      httpGet: (uri, timeout) async {
        urls.add(uri);
        return PluginHttpResult(200, Uint8List.fromList(utf8.encode('ok')));
      },
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> run(
    Map<String, dynamic> request,
    PluginPermissions permissions, {
    Set<String> grants = const {},
    PluginInvocationBudget? budget,
  }) => host.execute(
    'org.example.test',
    request,
    permissions,
    grants,
    budget ?? PluginInvocationBudget(1000),
    () {},
  );

  test(
    'requested permissions alone never authorize file or network access',
    () async {
      const permissions = PluginPermissions(
        filesRead: true,
        filesWrite: true,
        network: ['https://example.org'],
      );
      for (final request in [
        {'id': 'read', 'method': 'file.read', 'path': 'state'},
        {
          'id': 'write',
          'method': 'file.write',
          'path': 'state',
          'content_base64': 'YQ==',
        },
        {'id': 'get', 'method': 'http.get', 'url': 'https://example.org/data'},
      ]) {
        expect((await run(request, permissions))['ok'], isFalse);
      }
      expect(urls, isEmpty);
      expect(await Directory('${root.path}/data').list().toList(), isEmpty);
    },
  );
  test(
    'read and write grants are independent and cannot grant undeclared capabilities',
    () async {
      const permissions = PluginPermissions(filesRead: true, filesWrite: true);
      final written = await run(
        {
          'id': 'write',
          'method': 'file.write',
          'path': 'state',
          'content_base64': 'YQ==',
        },
        permissions,
        grants: {'files.write'},
      );
      expect(written['ok'], isTrue);
      expect(
        (await run(
          {'id': 'read', 'method': 'file.read', 'path': 'state'},
          permissions,
          grants: {'files.write'},
        ))['ok'],
        isFalse,
      );
      expect(
        (await run(
          {'id': 'read', 'method': 'file.read', 'path': 'state'},
          permissions,
          grants: {'files.read'},
        ))['result']['content_base64'],
        'YQ==',
      );
      expect(
        () => PluginPermissionHost.validateGrants(const PluginPermissions(), {
          'files.write',
        }),
        throwsA(isA<PluginException>()),
      );
    },
  );
  test(
    'HTTP grant matches exact scheme host and port and sends no request to other origins',
    () async {
      const permissions = PluginPermissions(network: ['https://example.org']);
      for (final url in [
        'http://example.org/a',
        'https://example.org.evil/a',
        'https://example.org:444/a',
        'https://evil.example.org/a',
        'https://user:password@example.org/a',
        'https://example.org/a#secret',
      ]) {
        expect(
          (await run(
            {'id': 'get', 'method': 'http.get', 'url': url},
            permissions,
            grants: {'network:https://example.org'},
          ))['ok'],
          isFalse,
        );
      }
      expect(urls, isEmpty);
      expect(
        (await run(
          {
            'id': 'get',
            'method': 'http.get',
            'url': 'https://example.org/models',
          },
          permissions,
          grants: {'network:https://example.org'},
        ))['ok'],
        isTrue,
      );
      expect(urls.single.toString(), 'https://example.org/models');
    },
  );
  test('redirect responses cannot reach a second origin', () async {
    host = PluginPermissionHost(
      storage,
      httpGet: (uri, timeout) async {
        urls.add(uri);
        return PluginHttpResult(302, Uint8List(0));
      },
    );
    final result = await run(
      {'id': 'get', 'method': 'http.get', 'url': 'https://example.org/'},
      const PluginPermissions(network: ['https://example.org']),
      grants: {'network:https://example.org'},
    );
    expect(result['ok'], isFalse);
    expect(urls, hasLength(1));
  });
  test('file traversal and oversized writes have no side effects', () async {
    const permissions = PluginPermissions(filesWrite: true);
    expect(
      (await run(
        {
          'id': 'write',
          'method': 'file.write',
          'path': '../outside',
          'content_base64': 'YQ==',
        },
        permissions,
        grants: {'files.write'},
      ))['ok'],
      isFalse,
    );
    final request = {
      'id': 'write',
      'method': 'file.write',
      'path': 'large',
      'content_base64': base64.encode(Uint8List(pluginMaxHostBytes + 1)),
    };
    await expectLater(
      run(request, permissions, grants: {'files.write'}),
      throwsA(
        isA<PluginException>().having((e) => e.code, 'code', 'host_budget'),
      ),
    );
    expect(await Directory('${root.path}/data').list().toList(), isEmpty);
  });
  test(
    'response-content quota and aggregate quota cover network data',
    () async {
      host = PluginPermissionHost(
        storage,
        httpGet: (uri, timeout) async =>
            PluginHttpResult(200, Uint8List(pluginMaxHostBytes + 1)),
      );
      const permissions = PluginPermissions(network: ['https://example.org']);
      await expectLater(
        run(
          {'id': 'get', 'method': 'http.get', 'url': 'https://example.org/'},
          permissions,
          grants: {'network:https://example.org'},
        ),
        throwsA(
          isA<PluginException>().having((e) => e.code, 'code', 'host_budget'),
        ),
      );
      host = PluginPermissionHost(
        storage,
        httpGet: (uri, timeout) async => PluginHttpResult(200, Uint8List(64)),
      );
      final budget = PluginInvocationBudget(1000, maxContentBytes: 100);
      await run(
        {'id': 'a', 'method': 'http.get', 'url': 'https://example.org/'},
        permissions,
        grants: {'network:https://example.org'},
        budget: budget,
      );
      await expectLater(
        run(
          {'id': 'b', 'method': 'http.get', 'url': 'https://example.org/'},
          permissions,
          grants: {'network:https://example.org'},
          budget: budget,
        ),
        throwsA(isA<PluginException>()),
      );
    },
  );
  test(
    'repeated host request ids and unknown host methods are rejected',
    () async {
      final budget = PluginInvocationBudget(1000);
      const permissions = PluginPermissions();
      expect(
        (await run(
          {'id': 'x', 'method': 'shell.exec'},
          permissions,
          budget: budget,
        ))['ok'],
        isFalse,
      );
      await expectLater(
        run({'id': 'x', 'method': 'shell.exec'}, permissions, budget: budget),
        throwsA(isA<PluginException>()),
      );
    },
  );
  test(
    'active-generation check runs again after the asynchronous host response',
    () async {
      var active = true;
      host = PluginPermissionHost(
        storage,
        httpGet: (uri, timeout) async {
          active = false;
          return PluginHttpResult(200, Uint8List(0));
        },
      );
      await expectLater(
        host.execute(
          'org.example.test',
          {'id': 'get', 'method': 'http.get', 'url': 'https://example.org/'},
          const PluginPermissions(network: ['https://example.org']),
          {'network:https://example.org'},
          PluginInvocationBudget(1000),
          () {
            if (!active) {
              throw const PluginException('Disabled.', code: 'cancelled');
            }
          },
        ),
        throwsA(
          isA<PluginException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
    },
  );
}
