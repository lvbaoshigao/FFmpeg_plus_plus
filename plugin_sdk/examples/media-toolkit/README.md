# Media Toolkit: a multi-source C/C++ plugin

This example declares three independent media nodes. The plugin validates the
request, selects its own FFmpeg filters and returns output options; the host binds
input/output paths and runs its controlled FFmpeg pipeline.

| Node | Media | Parameters | Generated filter |
| --- | --- | --- | --- |
| `video_tone` | video → video | brightness [-1,1], contrast [0,2], saturation [0,3], grayscale boolean | `eq` and optional `hue=s=0` |
| `audio_normalize` | audio → audio | profile: podcast / broadcast / streaming | `loudnorm`, target -16 / -23 / -14 LUFS, true peak -1.5 dBTP, LRA 11 |
| `audio_waveform` | audio → image | integer width [64,4096], height [64,2160], color cyan / white / orange | `showwavespic`, mapped to one PNG frame |

The host supplies the manifest defaults in `params`. All parameters are required
and type checked by the plugin. Tone numbers use a plugin-owned decimal formatter,
rounded to three fractional digits. Free-form filters, file paths and arbitrary
color expressions are never accepted as parameters.

## Build and self-test

From the SDK root (`plugin_sdk/` in a checkout, or the extracted SDK directory),
with LLVM clang + wasm-ld, Python 3.9+ and Node.js:

```sh
python3 tools/build_plugin.py \
  --example examples/media-toolkit \
  --output dist/media-toolkit.fppplugin \
  --emit-wasm dist/media-toolkit.wasm \
  --self-test \
  --fixtures dist/media-toolkit-selftest.json
```

`build.json` compiles `plugin.cpp` as C++17 and `filters.c` as C11, then links
them into a freestanding WASM module. Neither source needs libc, WASI, a C++
standard library, RTTI or exceptions. Repeated `--source` arguments can override
the source list. The build tool automatically discovers `selftest.json`; use
`--test-cases` for an explicit suite. The suite covers all three nodes, typed
parameter failures, unknown IDs, host capability failures and old media fields.

Repository-only regression tests run from the repository root (they are not
included in an exported SDK):

```sh
python3 -m unittest plugin_sdk.tests.test_media_toolkit -v
```

The resulting fixtures can also be replayed by the native WAMR regression runner:

```sh
FFMPEGPP_PLUGIN_RUNTIME_TEST=/path/to/plugin_runtime_test \
  python3 -m unittest plugin_sdk.tests.test_media_toolkit -v
```

## Source responsibilities

- `plugin.cpp` uses the bounded JSON and FFmpeg SDK helpers for envelope/type
  validation, host capability checks, node dispatch and JSON plan construction.
- `filters.c` implements the actual business decisions: tone graphs, loudness
  targets, waveform dimensions/palette and number-to-string conversion.
- `manifest.json` owns each node's fields. `Basic_info` and `Node_info` return
  generated macros; no `Node_editor_add` export is needed.

`host.operations` must advertise `ffmpeg.execute`. When `host.ffmpeg` is
present, its API version, filter list and option list are checked.
An older operations-only host may omit that object. `media_type` remains the
input type. New `input_media_type` / `output_media_type` fields must match the
node declaration when present; missing new fields use the declared contract.

Video and audio effects only emit `-vf` or `-af`, allowing FFmpeg to choose a
compatible codec/container from the host output. The waveform plan emits exactly
`-filter_complex [0:a]showwavespic=s=WxH:colors=...[v] -map [v] -frames:v 1 -c:v png`
as separate argument strings. It contains no shell command, input or output path.
