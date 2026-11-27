# Embedded plugin runtime

This directory embeds WAMR 2.4.6 commit
0fa421193212b3fb45c7f59ec53662cc2851fcc7 into the existing ffmpegpp backend.
The upstream archive SHA256 is pinned in CMakeLists.txt. WAMR is licensed under
Apache-2.0 WITH LLVM-exception; retain LICENSE-WAMR with binary distributions.

Default builds fetch the pinned source at configure time. Offline builds can use
-DFFMPEGPP_WAMR_SOURCE_DIR=/absolute/path/to/verified/wamr (or CMake's
FETCHCONTENT_SOURCE_DIR_FFMPEGPP_WAMR). Source overrides must be independently
verified against the pinned archive/commit. Configure -DFFMPEGPP_ENABLE_PLUGINS=OFF
to build a backend without the runtime; plugin_capabilities then reports unavailable.
No runtime download occurs when the application starts.

The engine uses the fast interpreter, software bounds checks and instruction
metering. Guest WASI, filesystem, networking, native libraries, guest threads,
shared memory, AOT/JIT, memory64, multiple memories, SIMD and GC are disabled.
The only guest imports are ffmpegpp.request_read and ffmpegpp.response_write.
The host must configure plugin_set_root with an existing absolute private plugins
directory after each backend initialization. Invocation accepts only absolute
module paths beneath that retained directory; traversal and symlinks are rejected.
POSIX reads walk openat directory descriptors with O_NOFOLLOW; Windows verifies
the final opened handle path beneath the retained root handle. Requests cannot
override the root. Every invocation has a fresh instance and all guest execution occurs after the
instruction budget and watchdog are armed. Core start and automatic initializer
exports are rejected before instantiation. Declared initial/maximum memory,
tables, locals and module structure are checked before WAMR loads the module.

Memory budgets cap guest linear memory, not the application's entire RSS.
Fuel counts interpreter work, not milliseconds; a watchdog also requests
termination at the wall-clock deadline. This is cooperative engine interruption,
not a hard real-time guarantee. The watchdog is joined before instance teardown.
WAMR runs in the backend process: traps are isolated, but an engine defect,
native-host bug, allocator failure or process crash can still affect the app.
This is not OS process isolation. Host file/network permissions are separately
brokered by Dart and are never granted by importing WASI.

Linux x86_64 is exercised by plugin_runtime_test, including the actual compiled
SDK example. Windows/macOS/Android build wiring is present but needs release
platform verification. The app currently has no iOS runner; the fixed upstream
source does include an iOS interpreter example using its Darwin platform port,
but this application does not yet claim validated iOS support.

Build and run native regressions:

    cmake -S server_cpp -B /tmp/ffmpegpp-plugin-tests -DFFMPEGPP_BUILD_TESTS=ON
    cmake --build /tmp/ffmpegpp-plugin-tests
    ctest --test-dir /tmp/ffmpegpp-plugin-tests --output-on-failure

AddressSanitizer builds must run with ASAN_OPTIONS=detect_stack_use_after_return=0
because WAMR native-stack boundary detection expects real stack addresses. The
remaining ASan checks and leak detection can stay enabled.

The plugin test reads docs/public/examples/plugin-demo.wasm and
plugin-fixtures/selftest.json from the source tree; SDK source/build instructions
are in plugin_sdk and docs/plugins. No external runtime executable is needed.
