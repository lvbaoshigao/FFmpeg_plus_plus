"""Compile the real multi-source WASM example and exercise its public ABI.

Optional native replay: set FFMPEGPP_PLUGIN_RUNTIME_TEST to the compiled
server_cpp plugin_runtime_test executable. It accepts WASM and fixture paths,
so the same requests can run through native WAMR without test-only C++ edits.
"""
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

SDK = Path(__file__).resolve().parents[1]
EXAMPLE = SDK / "examples" / "media-toolkit"


class MediaToolkitMetadataTests(unittest.TestCase):
    def test_all_nodes_have_independent_fields_and_media_contracts(self):
        manifest = json.loads((EXAMPLE / "manifest.json").read_text(encoding="utf-8"))
        nodes = {node["id"]: node for node in manifest["Node_info"]}
        self.assertEqual(set(nodes), {"video_tone", "audio_normalize", "audio_waveform"})
        expected = {
            "video_tone": ("video", "video", {"brightness", "contrast", "saturation", "grayscale"}),
            "audio_normalize": ("audio", "audio", {"profile"}),
            "audio_waveform": ("audio", "image", {"width", "height", "color"}),
        }
        for node_id, (input_type, output_type, fields) in expected.items():
            with self.subTest(node=node_id):
                node = nodes[node_id]
                self.assertEqual(node["input_types"], [input_type])
                self.assertEqual(node["output_type"], output_type)
                self.assertEqual({field["key"] for field in node["fields"]}, fields)
        self.assertEqual(json.loads((EXAMPLE / "build.json").read_text())["sources"],
                         ["plugin.cpp", "filters.c"])

    def test_each_node_has_success_rejection_and_compatibility_cases(self):
        suite = json.loads((EXAMPLE / "selftest.json").read_text(encoding="utf-8"))
        cases = {case["name"]: case for case in suite["cases"]}
        for node in ("video_tone", "audio_normalize", "audio_waveform"):
            for suffix in ("success", "invalid-params", "unknown-node", "missing-operation",
                           "missing-filter", "legacy-media-fields", "wrong-input", "wrong-output"):
                self.assertIn(node + "-" + suffix, cases)
            result = cases[node + "-success"]["response"]
            self.assertEqual(set(result), {"operation", "arguments"})
            self.assertEqual(result["operation"], "ffmpeg.execute")
            self.assertTrue(all(isinstance(arg, str) for arg in result["arguments"]))
            self.assertNotIn("-i", result["arguments"])
            if node != "audio_waveform":
                self.assertEqual(len(result["arguments"]), 2)
                self.assertNotIn("-f", result["arguments"])
                self.assertNotIn("-c:v", result["arguments"])
                self.assertNotIn("-c:a", result["arguments"])
        self.assertEqual(cases["audio_waveform-success"]["response"]["arguments"], [
            "-filter_complex", "[0:a]showwavespic=s=1280x720:colors=0x00ccff[v]",
            "-map", "[v]", "-frames:v", "1", "-c:v", "png",
        ])


@unittest.skipUnless(shutil.which("clang") and shutil.which("node") and shutil.which("wasm-ld"),
                     "real WASM compilation requires clang, wasm-ld and Node.js")
class MediaToolkitWasmTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="media-toolkit-test-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.output = Path(cls.directory.name) / "media-toolkit.fppplugin"
        cls.wasm = Path(cls.directory.name) / "media-toolkit.wasm"
        cls.fixtures = Path(cls.directory.name) / "selftest.json"
        cls.command = [sys.executable, str(SDK / "tools" / "build_plugin.py"),
                       "--example", str(EXAMPLE), "--output", str(cls.output),
                       "--emit-wasm", str(cls.wasm), "--self-test", "--fixtures", str(cls.fixtures)]
        cls.build_result = subprocess.run(cls.command, text=True, capture_output=True, timeout=90)
        if cls.build_result.returncode:
            raise AssertionError("Real media-toolkit build failed:\n" +
                                 cls.build_result.stdout + cls.build_result.stderr)

    def test_real_multisource_build_packages_exact_manifest_and_wasm(self):
        self.assertIn("PASS", self.build_result.stdout)
        self.assertTrue(self.wasm.read_bytes().startswith(b"\0asm\x01\0\0\0"))
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(sorted(archive.namelist()), ["manifest.json", "plugin.wasm"])
            self.assertEqual(archive.read("plugin.wasm"), self.wasm.read_bytes())
            self.assertEqual(json.loads(archive.read("manifest.json")),
                             json.loads((EXAMPLE / "manifest.json").read_text()))

    def test_wasm_abi_has_no_libc_wasi_or_cpp_runtime_imports(self):
        script = """
const fs = require('node:fs');
const wasmModule = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
console.log(JSON.stringify({imports: WebAssembly.Module.imports(wasmModule),
                            exports: WebAssembly.Module.exports(wasmModule)}));
"""
        result = subprocess.run([shutil.which("node"), "-e", script, str(self.wasm)],
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        abi = json.loads(result.stdout)
        self.assertEqual(sorted(abi["imports"], key=lambda value: value["name"]), [
            {"module": "ffmpegpp", "name": "request_read", "kind": "function"},
            {"module": "ffmpegpp", "name": "response_write", "kind": "function"},
        ])
        self.assertEqual(sorted(abi["exports"], key=lambda value: value["name"]), [
            {"name": "Basic_info", "kind": "function"},
            {"name": "Node_execute", "kind": "function"},
            {"name": "Node_info", "kind": "function"},
            {"name": "memory", "kind": "memory"},
        ])

    def test_explicit_node_suite_and_native_compatible_fixtures(self):
        explicit = Path(self.directory.name) / "explicit-fixtures.json"
        result = subprocess.run([shutil.which("node"), str(SDK / "tools" / "self_test.mjs"),
                                 str(self.wasm), str(EXAMPLE / "manifest.json"),
                                 "--test-cases", str(EXAMPLE / "selftest.json"),
                                 "--fixtures", str(explicit)],
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        auto = json.loads(self.fixtures.read_text())
        self.assertEqual(json.loads(explicit.read_text()), auto)
        for case in auto["cases"]:
            self.assertIn("entry", case)
            self.assertIn("request", case)
            self.assertIn("response", case)
        self.assertGreaterEqual(len(auto["cases"]), 24)

    def test_invalid_json_and_oversized_requests_return_clear_errors(self):
        suite = json.loads((EXAMPLE / "selftest.json").read_text())
        request = next(case["request"] for case in suite["cases"]
                       if case["name"] == "video_tone-success")
        oversized = dict(request, padding="x" * 17000)
        raw_requests = ["{", json.dumps(request) + " trailing", "[]", json.dumps(oversized)]
        script = r"""
const fs = require('node:fs');
(async () => {
  const module = await WebAssembly.compile(fs.readFileSync(process.argv[1]));
  const requests = JSON.parse(process.argv[2]);
  const results = [];
  for (const raw of requests) {
    const bytes = Buffer.from(raw, 'utf8');
    let instance, response;
    instance = await WebAssembly.instantiate(module, {ffmpegpp: {
      request_read(pointer, capacity) {
        if (bytes.length > capacity) return -bytes.length;
        new Uint8Array(instance.exports.memory.buffer, pointer >>> 0, bytes.length).set(bytes);
        return bytes.length;
      },
      response_write(pointer, length) {
        if (response !== undefined) throw new Error('multiple responses');
        if (length < 1 || length > 2048) throw new Error('response outside bounds');
        response = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(
          new Uint8Array(instance.exports.memory.buffer, pointer >>> 0, length >>> 0)));
        return length;
      }
    }});
    instance.exports.Node_execute();
    if (response === undefined) throw new Error('missing response');
    results.push(response);
  }
  process.stdout.write(JSON.stringify(results));
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
        result = subprocess.run([shutil.which("node"), "-e", script, str(self.wasm),
                                 json.dumps(raw_requests)], text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), [
            {"error": "Invalid request: expected API v1 and plugin identity"}
        ] * len(raw_requests))

    @unittest.skipUnless(os.environ.get("FFMPEGPP_PLUGIN_RUNTIME_TEST"),
                         "set FFMPEGPP_PLUGIN_RUNTIME_TEST to replay through native WAMR")
    def test_same_cases_replay_through_native_wamr(self):
        result = subprocess.run([os.environ["FFMPEGPP_PLUGIN_RUNTIME_TEST"],
                                 str(self.wasm), str(self.fixtures)],
                                text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("compiled SDK cases", result.stdout)


@unittest.skipUnless(shutil.which("clang") and sys.platform.startswith("linux"),
                     "native C formatter checks require Linux clang")
class MediaToolkitCFilterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="media-toolkit-c-")
        cls.addClassCleanup(cls.directory.cleanup)
        library = Path(cls.directory.name) / "filters.so"
        result = subprocess.run([shutil.which("clang"), "-std=c11", "-shared", "-fPIC",
                                 "-ffreestanding", "-fno-builtin", "-Wall", "-Wextra", "-Werror",
                                 str(EXAMPLE / "filters.c"), "-o", str(library)],
                                text=True, capture_output=True, timeout=30)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        cls.library = ctypes.CDLL(str(library))
        cls.library.mt_video_filter.argtypes = [ctypes.c_char_p, ctypes.c_int,
                                                ctypes.c_double, ctypes.c_double,
                                                ctypes.c_double, ctypes.c_int]
        cls.library.mt_normalize_filter.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
        cls.library.mt_waveform_filter.argtypes = [ctypes.c_char_p, ctypes.c_int,
                                                  ctypes.c_int, ctypes.c_int, ctypes.c_int]

    def test_plugin_owned_decimal_precision_and_grayscale_branch(self):
        for brightness, expected in ((-0.0001, "0"), (0.0005, "0.001"),
                                     (-0.1236, "-0.124"), (1, "1")):
            with self.subTest(brightness=brightness):
                buffer = ctypes.create_string_buffer(256)
                count = self.library.mt_video_filter(buffer, len(buffer), brightness, 1.25, 2.5, 1)
                value = "eq=brightness=" + expected + ":contrast=1.25:saturation=2.5,hue=s=0"
                self.assertEqual(buffer.value.decode(), value)
                self.assertEqual(count, len(value))

    def test_bounded_builder_discards_truncated_output(self):
        for name, args in (("mt_video_filter", (0, 1, 1, 0)),
                           ("mt_normalize_filter", (0,)),
                           ("mt_waveform_filter", (1280, 720, 0))):
            with self.subTest(function=name):
                buffer = ctypes.create_string_buffer(8)
                self.assertEqual(getattr(self.library, name)(buffer, len(buffer), *args), -1)
                self.assertEqual(buffer.value, b"")

    def test_business_functions_reject_values_outside_their_contract(self):
        invalid = [
            ("mt_video_filter", (float("nan"), 1, 1, 0)),
            ("mt_video_filter", (0, float("inf"), 1, 0)),
            ("mt_video_filter", (0, 1, -0.001, 0)),
            ("mt_video_filter", (0, 1, 1, 2)),
            ("mt_normalize_filter", (-1,)),
            ("mt_normalize_filter", (3,)),
            ("mt_waveform_filter", (63, 720, 0)),
            ("mt_waveform_filter", (1280, 2161, 0)),
            ("mt_waveform_filter", (1280, 720, 3)),
        ]
        for name, args in invalid:
            with self.subTest(function=name, arguments=args):
                buffer = ctypes.create_string_buffer(256)
                self.assertEqual(getattr(self.library, name)(buffer, len(buffer), *args), -1)

    def test_loudness_profiles_and_waveform_palette_are_plugin_business(self):
        for profile, target in enumerate((-16, -23, -14)):
            buffer = ctypes.create_string_buffer(256)
            self.library.mt_normalize_filter(buffer, len(buffer), profile)
            self.assertEqual(buffer.value.decode(), "loudnorm=I=" + str(target) + ":TP=-1.5:LRA=11")
        for color, value in enumerate(("0x00ccff", "white", "0xff9900")):
            buffer = ctypes.create_string_buffer(256)
            self.library.mt_waveform_filter(buffer, len(buffer), 4096, 2160, color)
            self.assertEqual(buffer.value.decode(),
                             "[0:a]showwavespic=s=4096x2160:colors=" + value + "[v]")


if __name__ == "__main__":
    unittest.main()
