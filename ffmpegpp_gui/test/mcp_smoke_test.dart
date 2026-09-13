// MCP 服务协议冒烟测试。
//
// 覆盖 AppState 内嵌 MCP HTTP JSON-RPC 服务的协议行为：
//  - initialize 返回 protocolVersion / capabilities / serverInfo（含版本协商回显）
//  - ping 返回空 result（心跳，缺失会被客户端判定失联）
//  - JSON-RPC 通知（无 id，如 notifications/initialized）不得返回响应体
//  - 批量 JSON-RPC 数组：请求各得一条响应、通知不响应、全通知返回 202
//  - tools/list 每个工具都带 additionalProperties:false 的 inputSchema
//  - 未知方法返回 -32601
//  - 非 POST 返回 405
//  - 写操作在 mcpAllowWrite=false 时被拒绝（默认只读）
//  - 文件系统类工具在 mcpAllowFsAccess=false 时被拒绝
//
// 说明：这里不启动完整 App，直接用 AppState 暴露的 start/stopMcpServer，
// 通过真实 HTTP 请求验证；测试结束务必 stop，避免端口泄漏。
import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // AppState 包含 ChangeNotifier/平台相关服务，测试环境先初始化 Flutter binding，
  // 避免在真实 HTTP 冒烟测试启动 MCP 前因 WidgetsBinding 未初始化而失败。
  TestWidgetsFlutterBinding.ensureInitialized();
  // binding 会全局安装 _MockHttpOverrides（把进程内所有 HttpClient 换成
  // 返回 400 的假实现，本测试因此全部失败）。本测试需要真实回环 HTTP，
  // 这里恢复默认覆盖行为；每个测试文件运行在独立 isolate，不影响其他测试。
  HttpOverrides.global = null;

  late AppState state;
  late int port;

  /// 发送任意 JSON 负载（对象或批量数组；null 则不带 body，如 GET 405 探测），
  /// 返回 (状态码, 解码后的 body)。
  Future<(int, dynamic)> rpcAny(
    dynamic payload, {
    String method = 'POST',
  }) async {
    final client = HttpClient();
    try {
      final req = await client.open(method, '127.0.0.1', port, '/');
      if (payload != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(payload));
      }
      final resp = await req.close();
      final body = await utf8.decoder.bind(resp).join();
      if (body.trim().isEmpty) return (resp.statusCode, null);
      return (resp.statusCode, jsonDecode(body));
    } finally {
      client.close(force: true);
    }
  }

  /// 发一条 JSON-RPC 请求，返回 (状态码, 解码后的 body 或 null)。
  Future<(int, Map<String, dynamic>?)> rpc(
    Map<String, dynamic> payload, {
    String method = 'POST',
  }) async {
    final (code, dynamic body) = await rpcAny(payload, method: method);
    return (code, body as Map<String, dynamic>?);
  }

  setUp(() async {
    state = AppState();
    // 用一个不常用端口，避免与用户配置的默认端口冲突
    port = 39217;
    state.config.mcpPort = port;
    state.config.mcpHost = '127.0.0.1';
    state.config.mcpAllowWrite = false;
    final ok = await state.startMcpServer();
    expect(ok, isTrue, reason: 'MCP 服务应能在回环地址启动');
  });

  tearDown(() async {
    await state.stopMcpServer();
  });

  test('initialize 返回协议版本与服务器信息', () async {
    final (code, body) = await rpc({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {},
    });
    expect(code, 200);
    final result = body!['result'] as Map<String, dynamic>;
    expect(result['protocolVersion'], isNotEmpty);
    expect(result['capabilities'], contains('tools'));
    expect((result['serverInfo'] as Map)['name'], 'ffmpegpp');
  });

  test('ping 返回空 result', () async {
    final (code, body) = await rpc({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'ping',
    });
    expect(code, 200);
    expect(body!['result'], isEmpty);
    expect(body.containsKey('error'), isFalse);
  });

  test('通知（无 id）不返回 JSON-RPC 响应体', () async {
    // MCP 客户端收到带 id:null 的响应会当协议错误处理
    final (code, body) = await rpc({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    expect(code, HttpStatus.accepted);
    expect(body, isNull);
  });

  test('tools/list 的每个工具都有 schema 且禁止额外字段', () async {
    final (code, body) = await rpc({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/list',
    });
    expect(code, 200);
    final tools = (body!['result'] as Map)['tools'] as List;
    expect(tools, isNotEmpty);
    for (final t in tools) {
      final tool = t as Map<String, dynamic>;
      expect(tool['name'], isNotEmpty, reason: '工具必须有名字');
      expect(tool['description'], isNotEmpty, reason: '${tool['name']} 缺少描述');
      final schema = tool['inputSchema'] as Map<String, dynamic>;
      expect(schema['type'], 'object');
      expect(schema['additionalProperties'], isFalse,
          reason: '${tool['name']} 的 schema 应拒绝未定义字段');
    }
  });

  test('resources/list 返回已注册资源', () async {
    final (code, body) = await rpc({
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'resources/list',
    });
    expect(code, 200);
    final resources = (body!['result'] as Map)['resources'] as List;
    expect(resources.map((r) => (r as Map)['uri']),
        containsAll(['pipeline://current', 'tasks://all']));
  });

  test('未知方法返回 -32601', () async {
    final (code, body) = await rpc({
      'jsonrpc': '2.0',
      'id': 5,
      'method': 'no/such/method',
    });
    expect(code, 200);
    expect((body!['error'] as Map)['code'], -32601);
  });

  test('非 POST 请求返回 405', () async {
    final (code, _) = await rpcAny(null, method: 'GET');
    expect(code, HttpStatus.methodNotAllowed);
  });

  test('默认只读：写操作被拒绝', () async {
    final (code, body) = await rpc({
      'jsonrpc': '2.0',
      'id': 6,
      'method': 'tools/call',
      'params': {'name': 'clear_all', 'arguments': {}},
    });
    expect(code, 200);
    final result = body!['result'] as Map<String, dynamic>;
    expect(result['isError'], isTrue, reason: 'mcpAllowWrite=false 时写操作应失败');
    final text = ((result['content'] as List).first as Map)['text'] as String;
    expect(text, contains('write access is disabled'));
  });

  test('只读工具可用：get_node_types 返回节点类型列表', () async {
    final (code, body) = await rpc({
      'jsonrpc': '2.0',
      'id': 7,
      'method': 'tools/call',
      'params': {'name': 'get_node_types', 'arguments': {}},
    });
    expect(code, 200);
    final result = body!['result'] as Map<String, dynamic>;
    expect(result['isError'], isNull);
    final text = ((result['content'] as List).first as Map)['text'] as String;
    final types = jsonDecode(text) as List;
    expect(types, isNotEmpty);
    expect((types.first as Map).keys, containsAll(['name', 'label']));
  });

  test('initialize 回显客户端请求的支持版本', () async {
    // 支持集合内的版本 → 原样回显
    final (code, body) = await rpc({
      'jsonrpc': '2.0',
      'id': 8,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-06-18'},
    });
    expect(code, 200);
    expect((body!['result'] as Map)['protocolVersion'], '2025-06-18');

    // 不支持的版本 → 回退服务器基线版本
    final (code2, body2) = await rpc({
      'jsonrpc': '2.0',
      'id': 9,
      'method': 'initialize',
      'params': {'protocolVersion': '1999-01-01'},
    });
    expect(code2, 200);
    expect((body2!['result'] as Map)['protocolVersion'], '2024-11-05');
  });

  test('批量 JSON-RPC：请求各得一条响应，通知不产生响应', () async {
    final (code, body) = await rpcAny([
      {'jsonrpc': '2.0', 'id': 10, 'method': 'ping'},
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      {'jsonrpc': '2.0', 'id': 11, 'method': 'no/such/method'},
    ]);
    expect(code, 200);
    final list = body! as List;
    expect(list.length, 2, reason: '通知不应产生响应');
    expect((list[0] as Map)['id'], 10);
    expect((list[0] as Map)['result'], isEmpty);
    expect(((list[1] as Map)['error'] as Map)['code'], -32601);
  });

  test('批量全通知返回 202 空体', () async {
    final (code, body) = await rpcAny([
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      {'jsonrpc': '2.0', 'method': 'notifications/cancelled'},
    ]);
    expect(code, HttpStatus.accepted);
    expect(body, isNull);
  });

  test('关闭文件系统访问后 list_directory 被拒绝', () async {
    state.config.mcpAllowFsAccess = false;
    try {
      final (code, body) = await rpc({
        'jsonrpc': '2.0',
        'id': 12,
        'method': 'tools/call',
        'params': {'name': 'list_directory', 'arguments': {'path': '.'}},
      });
      expect(code, 200);
      final result = body!['result'] as Map<String, dynamic>;
      expect(result['isError'], isTrue);
      final text = ((result['content'] as List).first as Map)['text'] as String;
      expect(text, contains('file system access is disabled'));
    } finally {
      state.config.mcpAllowFsAccess = true;
    }
  });
}
