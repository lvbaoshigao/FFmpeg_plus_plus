import 'plugin_manifest.dart';

/// The sole executable boundary. Native backends enforce WASM memory/fuel/time.
abstract class PluginRuntime {
  Future<Map<String, dynamic>> invoke(
    String modulePath,
    String entry,
    Map<String, dynamic> request,
    PluginLimits limits,
  );
}

typedef PluginRuntimeCallback =
    Future<Map<String, dynamic>> Function(
      String modulePath,
      String entry,
      Map<String, dynamic> request,
      PluginLimits limits,
    );

class CallbackPluginRuntime implements PluginRuntime {
  final PluginRuntimeCallback callback;
  const CallbackPluginRuntime(this.callback);

  @override
  Future<Map<String, dynamic>> invoke(
    String modulePath,
    String entry,
    Map<String, dynamic> request,
    PluginLimits limits,
  ) => callback(modulePath, entry, request, limits);
}

/// Allows data-only packages to be used when a native runtime is unavailable.
class UnavailablePluginRuntime implements PluginRuntime {
  const UnavailablePluginRuntime();

  @override
  Future<Map<String, dynamic>> invoke(
    String modulePath,
    String entry,
    Map<String, dynamic> request,
    PluginLimits limits,
  ) async => throw const PluginException(
    'The WebAssembly runtime is unavailable on this platform.',
    code: 'runtime_unavailable',
  );
}

class PluginException implements Exception {
  final String message;
  final String code;
  const PluginException(this.message, {this.code = 'plugin_error'});

  @override
  String toString() => message;
}
