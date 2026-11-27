# FFmpeg++ Plugin SDK v1

This SDK builds a small, freestanding WebAssembly module. It does not bundle a compiler, Flutter, FFmpeg, libc, WASI or any platform credentials.

## Install a compiler

Start at the [WebAssembly developer guide](https://webassembly.org/getting-started/developers-guide/). WebAssembly is a target/specification, not one universal compiler installer. For C/C++ use LLVM clang plus wasm-ld, the official [WASI SDK releases](https://github.com/WebAssembly/wasi-sdk/releases), or the [Emscripten SDK installation guide](https://emscripten.org/docs/getting_started/downloads.html).

For WASI SDK set WASI_SDK_PATH to the extracted directory. For Emscripten run its documented emsdk installation/activation steps, then set EMSDK or pass its upstream/bin/clang executable. This SDK intentionally calls clang directly with --target=wasm32 -nostdlib: ordinary WASI executables, Emscripten JS glue, browser APIs, _start and _initialize are not part of FFmpeg++ Plugin ABI v1.

Python 3.9+ is needed for packaging. Node.js is optional and is only used by --self-test; it is not a runtime dependency of FFmpeg++.

## Compile, test and package

From this SDK directory:

~~~sh
python3 tools/build_plugin.py --self-test
~~~

Windows PowerShell:

~~~powershell
py -3 tools/build_plugin.py --clang "C:/tools/wasi-sdk/bin/clang.exe" --self-test
~~~

When LLVM exposes only a versioned linker, pass --wasm-ld /path/to/wasm-ld-19. Compiler paths are passed as process arguments, never shell commands. Builds fail on compiler/test errors; no downloads happen automatically.

Output: dist/audio-gain.fppplugin. The script generates metadata constants from examples/audio-gain/manifest.json in a temporary build directory, then removes that directory. To retain a raw module and requests:

~~~sh
python3 tools/build_plugin.py --output dist/audio-gain.fppplugin --emit-wasm dist/audio-gain.wasm --self-test --fixtures dist/selftest.json
~~~

The script's core flags are --target=wasm32 -nostdlib -fno-builtin with --no-entry, --export-memory, a bounded memory maximum and no automatic initializer export. Every business export is void(void). Only ffmpegpp.request_read and ffmpegpp.response_write imports are allowed. See include/ffmpegpp_plugin.h and schema/manifest.schema.json. Schema validation in an editor is useful; the application's stricter semantic validation is authoritative.

## Import and run

1. In FFmpeg++, enable Settings → Experimental features → Plugins.
2. Open Plugins from the desktop sidebar or mobile bottom navigation, and import dist/audio-gain.fppplugin.
3. Review the summary and preview stability warning, then enable the plugin. The example requests no file/network permissions.
4. Open the node editor, add Audio Gain, and connect an audio Start → Audio Gain → Output. Set Gain (dB) to -6, select an output file, and run through the normal task queue.
5. The WASM result is {"operation":"audio.volume","decibels":-6}; the host validates it and translates it to the existing audio processing mechanism. The plugin never receives a source/output path or arbitrary FFmpeg/shell access.

IsLogic=true permits the existing enable/status control connection; it does not turn this media node into a logic gate. v1 media nodes have one data input and one data output. Missing/disabled plugins retain graph data but cannot execute.

## Theme and AI data example

~~~sh
python3 tools/build_plugin.py --example examples/theme-ai --output dist/theme-ai.fppplugin
~~~

This data-only package has no module, needs no compiler, and requests no I/O permissions. Its theme declares host-whitelisted appearance values (including the existing liquid-glass style). Its AI catalog contains an explicitly fictitious api.example.org provider/model, for importing and editing a configuration only; replace the endpoint/model before use and enter credentials in the normal AI settings. Imported profiles are disabled initially. Applying a theme or importing AI data is an explicit preview/confirmation action; installing a package does not silently apply either contribution.

## Safety, compatibility and upgrades

Manifests carry format_version=1, api_version=1, an application version range and semantic Basic_info.Version. Dependencies use [{"id":"org.example.base","version":">=1.0.0 <2.0.0"}]. Install and enable required compatible dependencies first. The host rejects missing, disabled, incompatible and cyclic dependencies. Installing an upgrade does not automatically authorize new code or permissions; review and enable it again. Use the manager's rollback action to restore the retained previous package when available.

Default budgets: 16 MiB memory, 1000 ms and 1000000 fuel; host ceilings: 64 MiB, 5000 ms and 10000000 fuel. No guest threads, WASI or automatic start function. File reads/writes and exact HTTPS origins must be declared and explicitly granted. File capabilities are restricted to a private plugin data directory. Optional I/O uses bounded JSON host_request/continuation messages, not additional imports. Exceptions, traps and limits surface as plugin errors; they are not a general native-process security boundary.

Package limits: ZIP 16 MiB; total expanded data 32 MiB; each file/module 8 MiB; manifest/request/response JSON 256 KiB; 256 ZIP entries. Paths must be portable ASCII relative paths. Backslashes, dot segments, drive/UNC paths, Windows device names, case-insensitive duplicates, symlinks and special files are rejected.

Host I/O limits: 128 KiB content per request before Base64 encoding, 2 MiB per whole invocation, at most 16 uniquely identified requests. Private plugin data is limited to 16 MiB and 256 files. All guest restarts and I/O share one wall-clock time_ms budget. file.read returns {content_base64,bytes}; file.write returns {bytes}; http.get returns {status,content_base64,content_type}. HTTP redirects are not followed and ambient application credentials are not sent. Permission/path errors return host_response.ok=false; timeout, budget exhaustion and cancellation terminate the whole invocation.

Treat plugin data as untrusted. Keep credentials out of packages, declare only necessary capabilities, and handle host I/O rejection. Use the application runtime tests in addition to the Node smoke test before publishing.

## SDK source tests

From a repository checkout: python3 -m unittest discover -s plugin_sdk/tests -p 'test_*.py' -v. The Flutter SDK-export test lives in plugin_sdk/tests/sdk_export_test.dart and is run from ffmpegpp_gui. A downloaded SDK omits repository-only tests and asset synchronization tools.

The SDK sources use the repository's MIT license; see LICENSE.
