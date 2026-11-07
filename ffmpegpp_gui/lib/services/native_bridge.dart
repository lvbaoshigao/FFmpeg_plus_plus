import 'dart:ffi';
import 'package:ffi/ffi.dart';

// C 函数签名
typedef _InitC = Int32 Function();
typedef _InitDart = int Function();

typedef _RequestC = Int32 Function(Pointer<Utf8> json);
typedef _RequestDart = int Function(Pointer<Utf8> json);

typedef _PollC = Pointer<Utf8> Function();
typedef _PollDart = Pointer<Utf8> Function();

typedef _FreeC = Void Function(Pointer<Utf8> ptr);
typedef _FreeDart = void Function(Pointer<Utf8> ptr);

typedef _ShutdownC = Void Function();
typedef _ShutdownDart = void Function();

class NativeBridge {
  late final DynamicLibrary _lib;
  late final _InitDart _init;
  late final _RequestDart _request;
  late final _PollDart _poll;
  late final _FreeDart _free;
  late final _ShutdownDart _shutdown;

  NativeBridge(String dllPath) {
    _lib = DynamicLibrary.open(dllPath);
    _init = _lib.lookupFunction<_InitC, _InitDart>('ffmpegpp_init');
    _request = _lib.lookupFunction<_RequestC, _RequestDart>('ffmpegpp_request');
    _poll = _lib.lookupFunction<_PollC, _PollDart>('ffmpegpp_poll');
    _free = _lib.lookupFunction<_FreeC, _FreeDart>('ffmpegpp_free');
    _shutdown = _lib.lookupFunction<_ShutdownC, _ShutdownDart>('ffmpegpp_shutdown');
  }

  int init() => _init();

  int request(String json) {
    final ptr = json.toNativeUtf8();
    try {
      return _request(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  /// 非阻塞取下一条 JSON 响应，无数据时返回 null
  String? poll() {
    final ptr = _poll();
    if (ptr == nullptr) return null;
    try {
      return ptr.toDartString();
    } finally {
      _free(ptr);
    }
  }

  void shutdown() => _shutdown();
}
