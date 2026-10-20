import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import 'panel_process_ipc.dart';

/// ════════════════════════════════════════════════════════════════════════
/// 独立面板子窗口（真正脱离应用主窗口的系统窗口）
/// ════════════════════════════════════════════════════════════════════════
///
/// 背景：`desktop_multi_window` 创建的每个子窗口都是一个**独立的 Flutter
/// 引擎**。它与主窗口不共享任何 Dart 内存 —— 主窗口里的 `AppState`、画布
/// 节点图、选中态，在子窗口里一概看不到。因此所有数据都必须显式经方法通道
/// 或 Linux 本机 Unix socket 同步，这是本文件存在的唯一理由。
///
/// 两条链路：
///  * **子 → 主**：Windows/macOS 共用一条单向 [WindowMethodChannel]
///    （[kPanelHostChannel]）；Linux 独立进程使用受限 Unix socket。
///    单向模式「一个 handler、任意多个调用方」，正好对应「一个主窗口 + N 个
///    面板窗口」。主窗口在 `main()` 里调 [MultiWindowService.installHost]
///    注册唯一 handler。
///  * **主 → 子**：用 `WindowController.invokeMethod`，落到子窗口自己注册的
///    `mixin.one/window_controller/<windowId>` 通道（插件内部约定，子窗口用
///    [MultiWindowService.installGuest] 注册）。
///
/// 时序：子窗口就绪后主动调 [PanelMethod.ready] 向主窗口报到，主窗口把完整
/// 快照当作**该请求的返回值**回给子窗口 —— 不需要轮询、也不会推早了丢消息。

/// 独立面板的类型。
enum DetachedPanel {
  /// 元素 / 属性面板。
  props('props'),

  /// AI 助手面板。
  ai('ai');

  const DetachedPanel(this.id);

  final String id;

  static DetachedPanel? fromId(String? id) {
    if (id == null) return null;
    for (final p in DetachedPanel.values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// 子窗口的启动参数。
///
/// 跨引擎边界只能传一个字符串，所以统一 JSON 编码后塞进
/// [WindowConfiguration.arguments]；子窗口在 `main()` 里用 [tryParse] 解出来。
class DetachedWindowArgs {
  const DetachedWindowArgs({
    required this.panel,
    this.lang = 'zh',
    this.width = 0,
    this.height = 0,
    this.ipcSocketPath,
  });

  final DetachedPanel panel;
  final String lang;

  /// 期望的逻辑尺寸；0 表示由子窗口自己决定。
  final double width;
  final double height;
  final String? ipcSocketPath;

  /// 参数信封的标识，用来区分「本应用的面板窗口」与普通窗口/主窗口
  /// （主窗口的 windowArgument 是空串）。
  static const String _kind = 'ffmpegpp.panel.v1';

  String encode() => jsonEncode({
    'kind': _kind,
    'panel': panel.id,
    'lang': lang,
    'w': width,
    'h': height,
    if (ipcSocketPath != null) 'ipc': ipcSocketPath,
  });

  /// 解析子窗口参数；不是本应用的面板窗口时返回 null。
  static DetachedWindowArgs? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['kind'] != _kind) return null;
      final panel = DetachedPanel.fromId(decoded['panel'] as String?);
      if (panel == null) return null;
      final socketPath = decoded['ipc'] as String?;
      if (socketPath != null &&
          (!socketPath.startsWith('/') || socketPath.length > 100)) {
        return null;
      }
      return DetachedWindowArgs(
        panel: panel,
        lang: (decoded['lang'] as String?) ?? 'zh',
        width: (decoded['w'] as num?)?.toDouble() ?? 0,
        height: (decoded['h'] as num?)?.toDouble() ?? 0,
        ipcSocketPath: socketPath,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 子窗口 → 主窗口的请求方法名。
abstract final class PanelMethod {
  /// 子窗口就绪报到；主窗口把完整快照作为返回值回给子窗口。
  static const String ready = 'panel.ready';

  /// 吸附回主栏：主窗口把面板收回应用内，并关掉这个系统窗口。
  static const String dockBack = 'panel.dockBack';

  /// 系统窗口已被用户直接关闭（点标题栏的 X）。
  static const String closed = 'panel.closed';

  /// 主动索取一份最新快照。
  static const String refresh = 'state.refresh';

  static const String setParams = 'prop.setParams';
  static const String addNode = 'prop.addNode';
  static const String probe = 'media.probe';
  static const String updateConfig = 'config.update';

  static const String graphApply = 'graph.apply';
  static const String graphModify = 'graph.modify';
  static const String graphAddGate = 'graph.addGate';
  static const String graphSetGateParams = 'graph.setGateParams';
  static const String graphDeleteNode = 'graph.deleteNode';
  static const String graphConnect = 'graph.connect';
  static const String graphDisconnect = 'graph.disconnect';
  static const String graphClearAll = 'graph.clearAll';
  static const String graphUndo = 'graph.undo';
  static const String graphRedo = 'graph.redo';
  static const String graphSave = 'graph.save';
  static const String graphCancelTasks = 'graph.cancelTasks';

  static const String aiTitle = 'ai.title';
}

/// 主窗口 → 子窗口的推送方法名（走 `WindowController.invokeMethod`）。
abstract final class PanelPush {
  /// 全量快照：节点图 + 选中节点 + 配置 + 库数据 + 元素清单 + UI 主题。
  static const String snapshot = 'pushSnapshot';

  /// AI 会话消息（拖出 / 吸附时交接对话）。
  static const String aiSession = 'pushAiSession';

  /// 就地更新一个节点的参数（避免整图重发）。
  static const String nodeParams = 'pushNodeParams';

  /// 让子窗口执行关窗动作（主窗口无法从外部销毁子窗口的原生窗口）。
  static const String closeWindow = 'closeWindow';
  static const String suspend = 'suspendWindow';
  static const String reactivate = 'reactivateWindow';
  static const String showWindow = 'showWindow';
}

/// 主窗口侧的「面板宿主」。
///
/// 编辑器（`_PipelineEditorPageState`）把自己挂到
/// [MultiWindowService.delegate] 上，独立窗口发来的全部请求都转给它处理。
abstract class PanelHostDelegate {
  /// 处理子窗口请求；返回值的可序列化部分会原样回给子窗口。
  Future<dynamic> onPanelRequest(String method, Map<String, dynamic> args);

  /// 生成某个面板的完整快照（首次报到与 [PanelMethod.refresh] 都用它）。
  Map<String, dynamic> panelSnapshot(DetachedPanel panel);

  /// 子窗口消失（吸附回主栏 / 用户直接关窗）。
  void onPanelWindowGone(DetachedPanel panel);
}

/// 子 → 主 的共用通道名。
const String kPanelHostChannel = 'ffmpegpp.panel.host';

/// 独立面板窗口的总入口。桌面端生效；移动端全部是 no-op。
class MultiWindowService {
  MultiWindowService._();

  /// 主窗口侧注册的委托；未注册时子窗口的请求一律返回 null。
  static PanelHostDelegate? delegate;

  static const WindowMethodChannel _hostChannel = WindowMethodChannel(
    kPanelHostChannel,
    mode: ChannelMode.unidirectional,
  );

  static bool _hostInstalled = false;

  /// 已打开的面板窗口：panel → windowId。
  static final Map<DetachedPanel, String> _openWindows = {};
  static final Map<DetachedPanel, _LinuxPanelProcess> _linuxPanels = {};
  static ServerSocket? _linuxServer;
  static Directory? _linuxIpcDirectory;
  static Future<void>? _startingLinuxServer;
  static int _linuxConnections = 0;
  static String? _linuxSocketPath;
  static PanelProcessIpc? _linuxGuestConnection;
  static String? _linuxGuestSocketPath;
  static String? _linuxGuestToken;
  static const String linuxProcessArgument = 'ffmpegpp-panel-v1';
  static const String _linuxHandshakeMethod = 'ipc.handshake';

  static bool get supported => !isMobilePlatform;

  /// Linux runner 独立面板进程读取 stdin 后调用；认证 token 不放在 argv 中。
  static void configureLinuxGuest({
    required String socketPath,
    required String token,
  }) {
    if (!Platform.isLinux ||
        !socketPath.startsWith('/') ||
        socketPath.length > 100 ||
        !RegExp(r'^[A-Za-z0-9_-]{40,50}$').hasMatch(token)) {
      throw const FormatException('Invalid Linux panel process arguments');
    }
    _linuxGuestSocketPath = socketPath;
    _linuxGuestToken = token;
  }

  static Future<void> disconnectLinuxGuest() async {
    final connection = _linuxGuestConnection;
    _linuxGuestConnection = null;
    _linuxGuestSocketPath = null;
    _linuxGuestToken = null;
    await connection?.close();
  }

  static Future<String> readLinuxGuestToken() async {
    final token = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    if (!RegExp(r'^[A-Za-z0-9_-]{40,50}$').hasMatch(token)) {
      throw const FormatException('Invalid Linux panel IPC token');
    }
    return token;
  }

  /// 当前进程是不是「独立面板子窗口」；是则返回它的启动参数。
  ///
  /// 必须在 `main()` 的最前面调用：拿不到定义（插件没注册 / 移动端 / Web）
  /// 就按主窗口处理，绝不让它抛出去。
  static Future<DetachedWindowArgs?> currentWindowArgs() async {
    if (isMobilePlatform) return null;
    try {
      final controller = await WindowController.fromCurrentEngine();
      return DetachedWindowArgs.tryParse(controller.arguments);
    } catch (_) {
      return null;
    }
  }

  /// 主窗口调用一次：注册子窗口请求的唯一 handler。
  static Future<void> installHost() async {
    if (!supported || _hostInstalled) return;
    if (Platform.isLinux) {
      try {
        await _ensureLinuxHost();
        _hostInstalled = true;
      } catch (error, stack) {
        debugPrint('Could not start Linux panel IPC server: $error\n$stack');
      }
      return;
    }
    _hostInstalled = true;
    try {
      await _hostChannel.setMethodCallHandler((call) async {
        final raw = call.arguments;
        final args = raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
        final host = delegate;
        if (host == null) return null;
        if (call.method == PanelMethod.closed) {
          final panel = DetachedPanel.fromId(args['panel'] as String?);
          if (panel != null) {
            _openWindows.remove(panel);
            host.onPanelWindowGone(panel);
          }
          return null;
        }
        return await host.onPanelRequest(call.method, args);
      });
    } catch (_) {
      // 注册失败不该拖垮主窗口：独立窗口功能退化为不可用，其余功能照常。
      _hostInstalled = false;
    }
  }

  /// 子窗口调用：注册自己的方法 handler，返回「主窗口 → 本窗口」的推送入口。
  ///
  /// 返回值是主窗口用来推消息的 `WindowController`；子窗口自己一般不需要它。
  static Future<WindowController?> installGuest(
    Future<dynamic> Function(String method, Map<String, dynamic> args) onPush,
  ) async {
    if (!supported) return null;
    if (Platform.isLinux) {
      final path = _linuxGuestSocketPath;
      final token = _linuxGuestToken;
      if (path == null || token == null) return null;
      final socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 10),
      );
      final connection = PanelProcessIpc(socket);
      connection.onRequest = (method, args) => onPush(method, args);
      final authenticated = await connection.invoke(
        _linuxHandshakeMethod,
        <String, dynamic>{'token': token},
        const Duration(seconds: 10),
      );
      if (authenticated != true) {
        await connection.close();
        throw StateError('Linux panel IPC authentication failed');
      }
      _linuxGuestConnection = connection;
      return null;
    }
    try {
      final controller = await WindowController.fromCurrentEngine();
      await controller.setWindowMethodHandler((call) async {
        final raw = call.arguments;
        return await onPush(
          call.method,
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{},
        );
      });
      return controller;
    } catch (_) {
      return null;
    }
  }

  /// 子窗口调用：向主窗口发请求。
  static Future<dynamic> invokeHost(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (!supported) return null;
    if (Platform.isLinux) {
      final connection = _linuxGuestConnection;
      if (connection == null) return null;
      try {
        return await connection.invoke(method, args);
      } catch (error) {
        debugPrint('Linux panel IPC request failed ($method): $error');
        return null;
      }
    }
    try {
      return await _hostChannel
          .invokeMethod(method, args ?? const {})
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // 主窗口不在（例如主窗口已退出）时静默失败：子窗口不该因此崩溃。
      return null;
    }
  }

  /// 打开（或唤起）某个面板的系统窗口。
  ///
  /// 子窗口启动后通过 [PanelMethod.ready] 请求快照。Linux 使用独立进程与本机
  /// Unix socket；Windows/macOS 继续使用 desktop_multi_window 的第二引擎。
  static Future<String?> openPanel(
    DetachedPanel panel, {
    required String lang,
    double width = 0,
    double height = 0,
  }) async {
    if (!supported) return null;
    if (Platform.isLinux) {
      return _openLinuxPanel(panel, lang: lang, width: width, height: height);
    }
    final existing = _openWindows[panel];
    if (existing != null) {
      final controller = WindowController.fromWindowId(existing);
      try {
        if (Platform.isLinux) {
          await controller
              .invokeMethod(
                PanelPush.reactivate,
                delegate?.panelSnapshot(panel) ?? const {},
              )
              .timeout(const Duration(seconds: 5));
        }
        await controller.show();
      } catch (_) {
        _openWindows.remove(panel);
      }
      return _openWindows[panel];
    }
    try {
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: DetachedWindowArgs(
            panel: panel,
            lang: lang,
            width: width,
            height: height,
          ).encode(),
          hiddenAtLaunch: true,
        ),
      );
      _openWindows[panel] = controller.windowId;
      await controller.show();
      return controller.windowId;
    } catch (_) {
      return null;
    }
  }

  /// Linux 子进程在收回面板时关闭，避免保留无界面 Flutter 进程。
  static Future<void> parkPanel(DetachedPanel panel) async {
    if (Platform.isLinux) {
      await closePanel(panel);
      return;
    }
    final id = _openWindows[panel];
    if (id == null) return;
    final controller = WindowController.fromWindowId(id);
    try {
      await controller
          .invokeMethod(PanelPush.suspend)
          .timeout(const Duration(seconds: 5));
      await controller.hide().timeout(const Duration(seconds: 5));
    } catch (_) {
      await closePanel(panel);
    }
  }

  /// 关闭某个面板的系统窗口。
  ///
  /// Linux 向独立面板进程发关闭指令；Windows/macOS 由子引擎关闭自己的窗口。
  static Future<void> closePanel(DetachedPanel panel) async {
    if (!supported) return;
    if (Platform.isLinux) {
      final entry = _linuxPanels.remove(panel);
      if (entry == null) return;
      entry.expectedExit = true;
      final connection = entry.connection;
      if (connection != null) {
        try {
          await connection
              .invoke(PanelPush.closeWindow, const {})
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      } else {
        if (!entry.connectionReady.isCompleted) {
          entry.connectionReady.complete(null);
        }
      }
      final process = entry.process;
      if (process != null) {
        try {
          await process.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          process.kill();
          await process.exitCode.timeout(const Duration(seconds: 2));
        }
      }
      await connection?.close();
      return;
    }
    final id = _openWindows.remove(panel);
    if (id == null) return;
    try {
      await WindowController.fromWindowId(
        id,
      ).invokeMethod(PanelPush.closeWindow).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// 主窗口调用：把所有还开着的面板窗口都关掉（例如编辑器被关闭时）。
  ///
  /// 关的是「窗口」，面板本身由 [_PanelHostDelegate] 那边决定要不要显示回来；
  /// 这里只负责别留下孤儿窗口 —— 它们的宿主已经不存在了，再开着只会一直往一个
  /// 死掉的 State 发请求。
  static Future<void> closeAll() async {
    if (!supported) return;
    if (Platform.isLinux) {
      for (final panel in List<DetachedPanel>.from(_linuxPanels.keys)) {
        await closePanel(panel);
      }
      await _closeLinuxHost();
    }
    for (final panel in List<DetachedPanel>.from(_openWindows.keys)) {
      await closePanel(panel);
    }
  }

  /// 主窗口调用：把消息推给某个面板窗口。
  static Future<void> push(
    DetachedPanel panel,
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (!supported) return;
    if (Platform.isLinux) {
      final connection = _linuxPanels[panel]?.connection;
      if (connection == null) return;
      try {
        await connection
            .invoke(method, args)
            .timeout(const Duration(seconds: 5));
      } catch (error) {
        debugPrint('Linux panel push failed ($method): $error');
      }
      return;
    }
    final id = _openWindows[panel];
    if (id == null) return;
    try {
      await WindowController.fromWindowId(
        id,
      ).invokeMethod(method, args).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// 某个面板窗口是否已经打开。
  static bool isOpen(DetachedPanel panel) =>
      _openWindows.containsKey(panel) || _linuxPanels.containsKey(panel);

  /// 忘掉一个面板窗口（主窗口自己决定不再使用时调用）。
  static void forget(DetachedPanel panel) {
    _openWindows.remove(panel);
    _linuxPanels.remove(panel);
  }

  static Future<void> _ensureLinuxHost() async {
    if (_linuxServer != null) return;
    final pending = _startingLinuxServer;
    if (pending != null) {
      await pending;
      return;
    }
    final start = _startLinuxHost();
    _startingLinuxServer = start;
    try {
      await start;
    } finally {
      _startingLinuxServer = null;
    }
  }

  static Future<void> _startLinuxHost() async {
    final directory = await Directory.systemTemp.createTemp('ffmpegpp-panel-');
    final path = '${directory.path}/p.sock';
    if (utf8.encode(path).length >= 100) {
      await directory.delete(recursive: true);
      throw StateError('Linux panel IPC socket path is too long');
    }
    try {
      final server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      _linuxIpcDirectory = directory;
      _linuxSocketPath = path;
      _linuxServer = server;
      server.listen(
        _acceptLinuxPanel,
        onError: (Object error) {
          debugPrint('Linux panel IPC server failed: $error');
        },
      );
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  static void _acceptLinuxPanel(Socket socket) {
    if (_linuxConnections >= DetachedPanel.values.length) {
      socket.destroy();
      return;
    }
    _linuxConnections++;
    final connection = PanelProcessIpc(socket);
    _LinuxPanelProcess? entry;
    var authenticated = false;
    connection.onRequest = (method, args) async {
      if (!authenticated) {
        final token = args['token'];
        if (method != _linuxHandshakeMethod ||
            token is! String ||
            token.length > 50) {
          unawaited(Future<void>.delayed(Duration.zero, connection.close));
          return false;
        }
        entry = _linuxPanels.values
            .where((candidate) => _constantTimeEquals(candidate.token, token))
            .firstOrNull;
        final matched = entry;
        if (matched == null || matched.expectedExit) {
          unawaited(Future<void>.delayed(Duration.zero, connection.close));
          return false;
        }
        authenticated = true;
        matched.connection = connection;
        if (!matched.connectionReady.isCompleted) {
          matched.connectionReady.complete(connection);
        }
        return true;
      }

      final current = entry;
      if (current == null || current.expectedExit) {
        throw StateError('Linux panel process is no longer active');
      }
      if (!_linuxHostMethods.contains(method)) {
        throw StateError('Unsupported Linux panel method');
      }
      final requestPanel = args['panel'];
      if (requestPanel != null && requestPanel != current.panel.id) {
        throw StateError('Linux panel id mismatch');
      }
      final host = delegate;
      if (host == null) return null;
      final result = await host.onPanelRequest(method, args);
      if (method == PanelMethod.ready && !current.ready.isCompleted) {
        current.ready.complete(true);
      }
      if (method == PanelMethod.closed) {
        _linuxPanels.remove(current.panel);
        host.onPanelWindowGone(current.panel);
      }
      return result;
    };
    connection.onClosed = () {
      _linuxConnections = math.max(0, _linuxConnections - 1);
      final current = entry;
      if (current != null && identical(current.connection, connection)) {
        current.connection = null;
        if (!current.expectedExit) current.process?.kill();
      }
    };
  }

  static const Set<String> _linuxHostMethods = {
    _linuxHandshakeMethod,
    PanelMethod.ready,
    PanelMethod.refresh,
    PanelMethod.dockBack,
    PanelMethod.closed,
    PanelMethod.setParams,
    PanelMethod.addNode,
    PanelMethod.probe,
    PanelMethod.updateConfig,
    PanelMethod.graphApply,
    PanelMethod.graphModify,
    PanelMethod.graphAddGate,
    PanelMethod.graphSetGateParams,
    PanelMethod.graphDeleteNode,
    PanelMethod.graphConnect,
    PanelMethod.graphDisconnect,
    PanelMethod.graphClearAll,
    PanelMethod.graphUndo,
    PanelMethod.graphRedo,
    PanelMethod.graphSave,
    PanelMethod.graphCancelTasks,
    PanelMethod.aiTitle,
  };

  static bool _constantTimeEquals(String a, String b) {
    final aa = utf8.encode(a);
    final bb = utf8.encode(b);
    var difference = aa.length ^ bb.length;
    final length = math.max(aa.length, bb.length);
    for (var i = 0; i < length; i++) {
      difference |= (i < aa.length ? aa[i] : 0) ^ (i < bb.length ? bb[i] : 0);
    }
    return difference == 0;
  }

  static Future<String?> _openLinuxPanel(
    DetachedPanel panel, {
    required String lang,
    required double width,
    required double height,
  }) async {
    try {
      await _ensureLinuxHost();
      final existing = _linuxPanels[panel];
      if (existing != null && !existing.expectedExit) {
        final connection =
            existing.connection ??
            await existing.connectionReady.future.timeout(
              const Duration(seconds: 20),
            );
        if (connection == null ||
            !await existing.ready.future.timeout(const Duration(seconds: 25))) {
          await _abortLinuxPanelStart(panel, existing);
          return null;
        }
        await connection.invoke(
          PanelPush.reactivate,
          delegate?.panelSnapshot(panel) ?? const <String, dynamic>{},
        );
        await connection.invoke(PanelPush.showWindow);
        return panel.id;
      }

      final socketPath = _linuxSocketPath;
      if (socketPath == null) return null;
      final random = math.Random.secure();
      final token = base64Url
          .encode(List<int>.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', '');
      final entry = _LinuxPanelProcess(panel, token);
      _linuxPanels[panel] = entry;
      final args = DetachedWindowArgs(
        panel: panel,
        lang: lang,
        width: width,
        height: height,
        ipcSocketPath: socketPath,
      );
      final process = await Process.start(Platform.resolvedExecutable, [
        linuxProcessArgument,
        args.encode(),
      ], mode: ProcessStartMode.normal);
      if (entry.expectedExit || !identical(_linuxPanels[panel], entry)) {
        process.kill();
        return null;
      }
      entry.process = process;
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => debugPrint('[panel:${panel.id}] $line'));
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => debugPrint('[panel:${panel.id}] $line'));
      process.exitCode.then((code) {
        entry.exited = true;
        unawaited(entry.connection?.close());
        if (identical(_linuxPanels[panel], entry)) {
          _linuxPanels.remove(panel);
          if (!entry.expectedExit) delegate?.onPanelWindowGone(panel);
        }
        if (!entry.connectionReady.isCompleted) {
          entry.connectionReady.complete(null);
        }
        if (!entry.ready.isCompleted) {
          entry.ready.complete(false);
        }
      });
      process.stdin.writeln(token);
      await process.stdin.flush();
      await process.stdin.close();
      final connected = await entry.connectionReady.future.timeout(
        const Duration(seconds: 20),
      );
      if (connected == null ||
          !await entry.ready.future.timeout(const Duration(seconds: 25))) {
        await _abortLinuxPanelStart(panel, entry);
        return null;
      }
      return panel.id;
    } catch (error, stack) {
      debugPrint('Could not open Linux detached panel: $error\n$stack');
      final entry = _linuxPanels[panel];
      if (entry != null) await _abortLinuxPanelStart(panel, entry);
      return null;
    }
  }

  static Future<void> _abortLinuxPanelStart(
    DetachedPanel panel,
    _LinuxPanelProcess entry,
  ) async {
    if (identical(_linuxPanels[panel], entry)) {
      _linuxPanels.remove(panel);
    }
    entry.expectedExit = true;
    if (!entry.connectionReady.isCompleted) {
      entry.connectionReady.complete(null);
    }
    if (!entry.ready.isCompleted) {
      entry.ready.complete(false);
    }

    final process = entry.process;
    if (process != null && !entry.exited) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        debugPrint('Linux detached panel did not exit after being killed');
      }
    }
    await entry.connection?.close();
  }

  static Future<void> _closeLinuxHost() async {
    final server = _linuxServer;
    _linuxServer = null;
    _linuxSocketPath = null;
    if (server != null) await server.close();
    final directory = _linuxIpcDirectory;
    _linuxIpcDirectory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

class _LinuxPanelProcess {
  _LinuxPanelProcess(this.panel, this.token);

  final DetachedPanel panel;
  final String token;
  final Completer<PanelProcessIpc?> connectionReady =
      Completer<PanelProcessIpc?>();
  final Completer<bool> ready = Completer<bool>();
  Process? process;
  PanelProcessIpc? connection;
  bool expectedExit = false;
  bool exited = false;
}

/// ════════════════════════════════════════════════════════════════════════
/// 子窗口用的「镜像 AppState」
/// ════════════════════════════════════════════════════════════════════════
///
/// AI 面板（`AiPanelView`）是唯一一处会 `context.read<AppState>()` 的组件。
/// 为了在子窗口里**零改动复用**它，这里继承 `AppState` 并只覆写它实际读到的
/// 那些成员，数据全部由主窗口经方法通道喂入。
///
/// 三条红线：
///  1. **绝不调 `init()`** —— 那会 dlopen 第二份 C++ 后端、再起一个 Python
///     进程，与主窗口争抢同一份资源。
///  2. **绝不碰 `backend`** —— 它是 `late final`，一访问就会构造
///     `BackendClient` 并建立审计订阅。媒体探测改走 [probeMedia] 转发。
///  3. **绝不调 `super.dispose()`** —— `AppState.dispose` 里也有 `backend`。
class MirrorAppState extends AppState {
  MirrorAppState({required this.send});

  /// 向主窗口发请求（一般是 [MultiWindowService.invokeHost]）。
  final Future<dynamic> Function(String method, [Map<String, dynamic>? args])
  send;

  AppConfig _config = AppConfig();
  List<VideoFile> _videos = const <VideoFile>[];
  List<FileContainer> _containers = const <FileContainer>[];
  List<TaskInfo> _tasks = const <TaskInfo>[];
  List<LogEntry> _logs = const <LogEntry>[];

  /// 子窗口自己的运行日志（主窗口推来的历史日志也在里面）。
  static const int _maxLogs = 400;

  @override
  AppConfig get config => _config;

  @override
  List<VideoFile> get videos => _videos;

  @override
  List<FileContainer> get containers => _containers;

  @override
  List<TaskInfo> get tasks => _tasks;

  @override
  List<LogEntry> get logEntries => _logs;

  /// 用主窗口推来的快照刷新镜像数据。
  ///
  /// 只重建 AI 面板真正会读的字段（多数模型类没有 toJson，例如 `VideoFile`
  /// 只能靠探针结果构造），所以视频/日志这两项按需字段最小化重建。
  void hydrate(Map<String, dynamic> snapshot) {
    final cfg = snapshot['config'];
    if (cfg is Map) {
      try {
        _config = AppConfig.fromJson(Map<String, dynamic>.from(cfg));
      } catch (_) {}
    }
    final data = snapshot['appData'];
    if (data is Map) {
      final videos = data['videos'];
      if (videos is List) {
        _videos = [
          for (final item in videos)
            if (item is Map)
              VideoFile(
                id: (item['id'] as String?) ?? '',
                filename: (item['filename'] as String?) ?? '',
                sizeMb: (item['sizeMb'] as num?)?.toDouble() ?? 0,
                parsed: (item['parsed'] as bool?) ?? false,
              ),
        ];
      }
      final containers = data['containers'];
      if (containers is List) {
        final built = <FileContainer>[];
        for (final item in containers) {
          if (item is! Map) continue;
          try {
            built.add(FileContainer.fromJson(Map<String, dynamic>.from(item)));
          } catch (_) {}
        }
        _containers = built;
      }
      final tasks = data['tasks'];
      if (tasks is List) {
        final built = <TaskInfo>[];
        for (final item in tasks) {
          if (item is! Map) continue;
          try {
            built.add(TaskInfo.fromJson(Map<String, dynamic>.from(item)));
          } catch (_) {}
        }
        _tasks = built;
      }
      final logs = data['logs'];
      if (logs is List) {
        _logs = [
          for (final item in logs)
            if (item is Map)
              LogEntry(
                timestamp: DateTime.fromMillisecondsSinceEpoch(
                  (item['ts'] as num?)?.toInt() ?? 0,
                ),
                message: (item['msg'] as String?) ?? '',
                category: (item['cat'] as String?) ?? 'general',
              ),
        ];
      }
    }
    notifyListeners();
  }

  /// 只刷新配置（主窗口改了设置时推送，避免整份快照重发）。
  void hydrateConfig(Map<String, dynamic> json) {
    try {
      _config = AppConfig.fromJson(json);
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<void> updateConfig(AppConfig Function(AppConfig) f) async {
    _config = f(_config);
    notifyListeners();
    await send(PanelMethod.updateConfig, {'config': _config.toJson()});
  }

  @override
  Future<Map<String, dynamic>> probeMedia(String path) async {
    final resp = await send(PanelMethod.probe, {'path': path});
    if (resp is Map) return Map<String, dynamic>.from(resp);
    return <String, dynamic>{'success': false, 'error': 'host unavailable'};
  }

  @override
  void addLog(String message, {String category = 'general'}) {
    final next = <LogEntry>[
      ..._logs,
      LogEntry(timestamp: DateTime.now(), message: message, category: category),
    ];
    _logs = next.length > _maxLogs
        ? next.sublist(next.length - _maxLogs)
        : next;
    notifyListeners();
  }

  @override
  void logAiGraphApplied(int nodeCount, int connectionCount) {
    addLog('[AI] 图已应用：$nodeCount 个节点 / $connectionCount 条连线', category: 'info');
  }

  @override
  // ignore: must_call_super  有意不调 super，详见下方说明
  void dispose() {
    // 有意不调 super.dispose()：`AppState.dispose` 会访问 late final
    // `backend`（首次访问即构造后端）、并回收 configService / pythonProcess
    // ——这三样在子窗口里根本不存在，构造后端反而会 dlopen 一份多余的 C++ 库。
    // 子窗口进程随关窗销毁，无需在此回收资源。
  }
}
