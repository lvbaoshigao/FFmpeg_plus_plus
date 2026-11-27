import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'plugin_manifest.dart';
import 'plugin_runtime.dart';
import 'plugin_storage.dart';

/// A single stopwatch covers every guest restart and every host continuation.
class PluginInvocationBudget {
  final int timeMs;
  final int maxHostRequests;
  final int maxContentBytes;
  final Stopwatch _clock = Stopwatch()..start();
  final Set<String> _requestIds = {};
  int _requests = 0;
  int _contentBytes = 0;
  PluginInvocationBudget(
    this.timeMs, {
    this.maxHostRequests = 16,
    this.maxContentBytes = 16 * pluginMaxHostBytes,
  });

  int get remainingMs {
    final value = timeMs - _clock.elapsedMilliseconds;
    if (value <= 0) {
      throw const PluginException(
        'Plugin invocation timed out.',
        code: 'timeout',
      );
    }
    return value;
  }

  void check(void Function() checkActive) {
    checkActive();
    remainingMs;
  }

  void beginRequest(String id, void Function() checkActive) {
    check(checkActive);
    if (++_requests > maxHostRequests || !_requestIds.add(id)) {
      throw const PluginException(
        'Plugin host continuation limit exceeded or request ID repeated.',
        code: 'host_budget',
      );
    }
  }

  void consume(int bytes) {
    _contentBytes += bytes;
    if (bytes < 0 ||
        bytes > pluginMaxHostBytes ||
        _contentBytes > maxContentBytes) {
      throw const PluginException(
        'Plugin host content budget exceeded.',
        code: 'host_budget',
      );
    }
  }

  Future<T> wait<T>(Future<T> future, void Function() checkActive) async {
    check(checkActive);
    final result = await future.timeout(
      Duration(milliseconds: remainingMs),
      onTimeout: () {
        throw const PluginException(
          'Plugin invocation timed out.',
          code: 'timeout',
        );
      },
    );
    check(checkActive);
    return result;
  }
}

class PluginHttpResult {
  final int status;
  final Uint8List bytes;
  final String contentType;
  PluginHttpResult(this.status, this.bytes, {this.contentType = ''});
}

typedef PluginHttpGet =
    Future<PluginHttpResult> Function(Uri uri, Duration timeout);

/// Capabilities remain in the host. Guests receive no raw file descriptors,
/// network sockets, ambient credentials, cookies or arbitrary request headers.
class PluginPermissionHost {
  final PluginStorage storage;
  final PluginHttpGet? httpGet;
  PluginPermissionHost(this.storage, {this.httpGet});

  static Set<String> validateGrants(
    PluginPermissions requested,
    Set<String> granted,
  ) {
    if (!requested.grantKeys.containsAll(granted)) {
      throw const PluginException(
        'Undeclared plugin permissions cannot be granted.',
        code: 'permission_denied',
      );
    }
    return Set.unmodifiable(granted);
  }

  Future<Map<String, dynamic>> execute(
    String pluginId,
    Map<String, dynamic> request,
    PluginPermissions declared,
    Set<String> granted,
    PluginInvocationBudget budget,
    void Function() checkActive,
  ) async {
    final id = request['id'];
    final method = request['method'];
    if (id is! String || id.isEmpty || id.length > 128 || method is! String) {
      throw const PluginException(
        'Malformed plugin host request.',
        code: 'invalid_host_request',
      );
    }
    budget.beginRequest(id, checkActive);
    try {
      Object result;
      switch (method) {
        case 'file.read':
          _keys(request, const {'id', 'method', 'path'});
          _grant('files.read', declared, granted);
          final bytes = await budget.wait(
            storage.readData(pluginId, _text(request['path'], 'path', 240)),
            checkActive,
          );
          budget.consume(bytes.length);
          result = {
            'content_base64': base64.encode(bytes),
            'bytes': bytes.length,
          };
        case 'file.write':
          _keys(request, const {'id', 'method', 'path', 'content_base64'});
          _grant('files.write', declared, granted);
          final path = _text(request['path'], 'path', 240);
          final content = _text(
            request['content_base64'],
            'content_base64',
            ((pluginMaxHostBytes + 2) ~/ 3) * 4,
            allowEmpty: true,
          );
          final bytes = base64.decode(content);
          budget.consume(bytes.length);
          await budget.wait(
            storage.writeData(
              pluginId,
              path,
              bytes,
              checkActive: () => budget.check(checkActive),
            ),
            checkActive,
          );
          result = {'bytes': bytes.length};
        case 'http.get':
          _keys(request, const {'id', 'method', 'url'});
          final url = _text(request['url'], 'url', 4096);
          final uri = Uri.tryParse(url);
          if (uri == null ||
              uri.scheme != 'https' ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.hasFragment ||
              url.contains(r'\')) {
            throw const PluginException(
              'Host HTTP requests require an HTTPS URL without credentials.',
              code: 'permission_denied',
            );
          }
          final origin = canonicalPluginOrigin(uri.origin);
          _grant('network:$origin', declared, granted);
          final response = await budget.wait(
            httpGet == null
                ? _networkGet(uri, budget, checkActive)
                : httpGet!(uri, Duration(milliseconds: budget.remainingMs)),
            checkActive,
          );
          if (response.status >= 300 && response.status < 400) {
            throw const PluginException(
              'Plugin HTTP redirects are not followed.',
              code: 'redirect_denied',
            );
          }
          budget.consume(response.bytes.length);
          result = {
            'status': response.status,
            'content_base64': base64.encode(response.bytes),
            'content_type': response.contentType.substring(
              0,
              response.contentType.length.clamp(0, 256),
            ),
          };
        default:
          throw const PluginException(
            'Unknown plugin host method.',
            code: 'invalid_host_request',
          );
      }
      budget.check(checkActive);
      return {'id': id, 'ok': true, 'result': result};
    } on PluginException catch (error) {
      budget.check(checkActive);
      if (error.code == 'timeout' ||
          error.code == 'host_budget' ||
          error.code == 'cancelled') {
        rethrow;
      }
      return {'id': id, 'ok': false, 'error': error.message};
    } catch (_) {
      budget.check(checkActive);
      // No absolute paths, request credentials or native exception text leak out.
      return {'id': id, 'ok': false, 'error': 'The host operation failed.'};
    }
  }

  Future<PluginHttpResult> _networkGet(
    Uri uri,
    PluginInvocationBudget budget,
    void Function() checkActive,
  ) async {
    final client = HttpClient()..autoUncompress = false;
    client.connectionTimeout = Duration(milliseconds: budget.remainingMs);
    HttpClientRequest? request;
    try {
      final activeRequest = await budget.wait(client.getUrl(uri), checkActive);
      request = activeRequest;
      activeRequest.followRedirects = false;
      activeRequest.maxRedirects = 0;
      activeRequest.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await budget.wait(activeRequest.close(), checkActive);
      if (response.isRedirect ||
          (response.statusCode >= 300 && response.statusCode < 400)) {
        throw const PluginException(
          'Plugin HTTP redirects are not followed.',
          code: 'redirect_denied',
        );
      }
      if (response.contentLength > pluginMaxHostBytes) {
        throw const PluginException(
          'Plugin HTTP response exceeds the content limit.',
          code: 'host_budget',
        );
      }
      final bytes = BytesBuilder(copy: false);
      final iterator = StreamIterator<List<int>>(response);
      try {
        while (await budget.wait(iterator.moveNext(), checkActive)) {
          final chunk = iterator.current;
          if (bytes.length + chunk.length > pluginMaxHostBytes) {
            throw const PluginException(
              'Plugin HTTP response exceeds the content limit.',
              code: 'host_budget',
            );
          }
          bytes.add(chunk);
        }
      } finally {
        await iterator.cancel();
      }
      return PluginHttpResult(
        response.statusCode,
        bytes.takeBytes(),
        contentType: response.headers.contentType?.mimeType ?? '',
      );
    } finally {
      request?.abort();
      client.close(force: true);
    }
  }

  static void _grant(
    String key,
    PluginPermissions declared,
    Set<String> granted,
  ) {
    if (!declared.grantKeys.contains(key) || !granted.contains(key)) {
      throw PluginException(
        'Plugin permission denied: $key.',
        code: 'permission_denied',
      );
    }
  }

  static String _text(
    Object? value,
    String name,
    int max, {
    bool allowEmpty = false,
  }) {
    if (value is! String ||
        (!allowEmpty && value.isEmpty) ||
        value.length > max) {
      throw PluginException(
        'Invalid host request $name.',
        code: 'invalid_host_request',
      );
    }
    return value;
  }

  static void _keys(Map<String, dynamic> value, Set<String> allowed) {
    if (value.keys.any((key) => !allowed.contains(key))) {
      throw const PluginException(
        'Unknown host request field.',
        code: 'invalid_host_request',
      );
    }
  }
}
