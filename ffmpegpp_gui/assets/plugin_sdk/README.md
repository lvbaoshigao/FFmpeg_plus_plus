# FFmpeg++ Plugin SDK v1

This SDK builds a small, freestanding WebAssembly module. It does not bundle a compiler, Flutter, FFmpeg, libc, WASI or any platform credentials.

## Install a compiler

Start at the [WebAssembly developer guide](https://webassembly.org/getting-started/developers-guide/). WebAssembly is a target/specification, not one universal compiler installer. For C/C++ use LLVM clang plus wasm-ld, the official [WASI SDK releases](https://github.com/WebAssembly/wasi-sdk/releases), or the [Emscripten SDK installation guide](https://emscripten.org/docs/getting_started/downloads.html).

For WASI SDK set WASI_SDK_PATH to the extracted directory. For Emscripten run its documented emsdk installation/activation steps, then set EMSDK or pass its upstream/bin/clang executable. This SDK intentionally calls clang directly with --target=wasm32 -nostdlib: ordinary WASI executables, Emscripten JS glue, browser APIs, _start and _initialize are not part of FFmpeg++ Plugin ABI v1.

Python 3.9+ is needed for packaging. Node.js is required when a build runs WebAssembly self-tests (explicitly or through an example's selftest.json); it is not needed for compilation-only builds and is never a runtime dependency of FFmpeg++.

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

The SDK also includes a Video Flip node that exercises the host's video.flip operation and a declarative select field:

~~~sh
python3 tools/build_plugin.py --example examples/video-flip --output dist/video-flip.fppplugin --self-test
~~~

The script's core flags are --target=wasm32 -nostdlib -fno-builtin with --no-entry, --export-memory, a bounded memory maximum and no automatic initializer export. Every business export is void(void). Only ffmpegpp.request_read and ffmpegpp.response_write imports are allowed. See include/ffmpegpp_plugin.h and schema/manifest.schema.json. Schema validation in an editor is useful; the application's stricter semantic validation is authoritative.

### Bounded JSON and FFmpeg-plan helpers

`include/ffmpegpp_json.h` provides bounded views over the caller-owned JSON buffer (`fpp_json_doc`, `fpp_json_value`): `fpp_json_parse`/`root`, object and dotted-path lookup, array accessors, and typed `i32`, `i64`, number, bool and UTF-8 string getters. Strings decode into a caller-owned buffer whose capacity includes the final NUL; invalid UTF-8 and embedded NUL are rejected. `fpp_host_capabilities_init` reads the request's host object; `fpp_host_supports_operation`, `fpp_host_supports_ffmpeg_option` and `fpp_host_supports_ffmpeg_filter` check the advertised lists.

`include/ffmpegpp_ffmpeg.h` writes the exact `ffmpeg.execute` JSON result into a caller-owned buffer. Initialize a plan, attach parsed host capabilities, then append argument strings or option/value pairs. `fpp_ffmpeg_plan_add_filter` is a convenience for simple video `-vf`; use `fpp_ffmpeg_plan_add_option` for audio `-af` or `-filter_complex` graphs. `fpp_ffmpeg_plan_write`/`end` return the JSON length, and `fpp_ffmpeg_plan_respond` writes it through the ABI. The helper bounds the caller buffer and argument count and offers capability prechecks; the backend remains authoritative for the complete filter grammar, UTF-8 capability byte limits and final validation. These plan APIs do not accept input/output paths; the host binds the single node-chain input and output. Keep filter construction and business behavior in your plugin source.

### C/C++ source files and self-tests

The builder accepts `.c`, `.cc`, `.cpp` and `.cxx` sources. C++ uses C++17 in freestanding mode without the C++ standard library, exceptions or RTTI; write plugin business logic in the WASM guest, not a native DLL/SO. Select sources with repeatable `--source <relative-path>` flags; if none are supplied, `build.json`'s `sources` list is used, falling back to `plugin.c` when no source list is configured. Explicit `--source` values override the configuration file. Source paths are relative to the selected example directory.

An example may include `selftest.json`; when present, the builder automatically selects and runs it. `--test-cases <json-path>` selects a different suite. The JSON may be a `cases` array or an object containing that array (up to 1 MiB, 1–1024 cases). A single-call case contains `name`, `entry`, `request` and expected `response` (`expected_response` is also accepted). A sequence case uses `name` and a `steps` array of 1–128 calls; each step has those call fields and may inherit `entry` from its case. Supply each continuation request explicitly: every call, including each sequence step, creates a fresh WebAssembly instance. Metadata is always checked independently against the manifest, even with a custom suite.

`--self-test` enables the ABI smoke test for examples without a case file. Node.js is required whenever a test suite runs, but not for compilation-only builds. `--fixtures <path>` saves the tested case set with `api_version` and `plugin_id` from the manifest for native runtime tests.

From the SDK directory, compile and test the bundled multi-node media example (the `build.json` and `selftest.json` are discovered automatically):

~~~sh
python3 tools/build_plugin.py --example examples/media-toolkit --output dist/media-toolkit.fppplugin --emit-wasm dist/media-toolkit.wasm --self-test --fixtures dist/media-toolkit-selftest.json
~~~

Repeat `--source plugin.cpp --source filters.c` to override the example's configured sources, or pass `--test-cases path/to/cases.json` to select an external JSON case file. See `examples/media-toolkit/` for `video_tone`, `audio_normalize` and `audio_waveform`.

### Plugin identity and icon

`Basic_info.Author` is an optional display name (up to 120 characters). `Basic_info.Icon` is an optional relative path to a package-owned PNG, JPEG, WebP or GIF image. Add that image inside the example directory; the builder includes it in the `.fppplugin` archive and rejects unsafe paths, symlinks, invalid image signatures, and files larger than 512 KiB. Keep artwork compact and square for the best result in the plugin manager. Example:

~~~json
{
  "Basic_info": {
    "Name": "My plugin",
    "Version": "1.0.0",
    "IsPreview": false,
    "Summary": "A short description.",
    "Author": "Example Studio",
    "Icon": "assets/plugin-icon.png"
  }
}
~~~

## Import and run

1. In FFmpeg++, enable Settings → Experimental features → Plugins.
2. Open Plugins from the desktop sidebar or mobile bottom navigation, and import dist/audio-gain.fppplugin.
3. Read the summary, the first-enable risk warning and, where applicable, the preview stability warning, then enable the plugin. The example requests no file/network permissions.
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

## SDK source tests and embedded assets

From the repository root, run the Python tests:

~~~sh
python3 -m unittest discover -s plugin_sdk/tests -p 'test_*.py' -v
~~~

After changing reviewed SDK sources, update the source list in `tools/sync_assets.py` when needed, then regenerate and verify the Flutter assets from the repository root:

~~~sh
python3 plugin_sdk/tools/sync_assets.py
python3 plugin_sdk/tools/sync_assets.py --check
~~~

The synchronizer copies the listed files byte for byte, flattens `/` to `__` for Flutter asset names, and generates `ffmpegpp_gui/assets/plugin_sdk/files.json` with the original SDK paths for ZIP export. Include new headers, example source files, build configurations and self-test suites in the list before synchronization. Edit the SDK sources rather than their generated asset copies.

From `ffmpegpp_gui`, verify the actual ZIP export with `flutter test --no-pub --reporter expanded ../plugin_sdk/tests/sdk_export_test.dart`. A downloaded SDK omits repository-only tests and asset synchronization tools; its bundled examples still compile and run their Node self-tests.

The SDK sources use the repository's MIT license; see LICENSE.
