import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_plugin", ROOT / "tools" / "build_plugin.py")
build_plugin = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_plugin)


class PluginSdkTests(unittest.TestCase):
    def test_metadata_generated_from_manifest(self):
        manifest = build_plugin.read_manifest(ROOT / "examples" / "audio-gain" / "manifest.json")
        defines = build_plugin.generated_header(manifest)
        for line in defines.splitlines()[1:]:
            name, literal = line.split(" ", 2)[1:]
            decoded = json.loads(json.loads(literal))
            if name == "FPP_BASIC_JSON":
                self.assertEqual(decoded, manifest["Basic_info"])
            elif name == "FPP_NODES_JSON":
                self.assertEqual(decoded, {"nodes": manifest["Node_info"]})
            elif name == "FPP_EDITOR_JSON":
                self.assertEqual(decoded, {"fields": manifest["Node_info"][0]["fields"]})
            else:
                self.fail("unexpected generated macro: " + name)

    def test_deterministic_data_only_package(self):
        manifest = build_plugin.read_manifest(ROOT / "examples" / "theme-ai" / "manifest.json")
        first = build_plugin.package_bytes(manifest)
        self.assertEqual(first, build_plugin.package_bytes(manifest))
        with zipfile.ZipFile(io.BytesIO(first)) as archive:
            self.assertEqual(archive.namelist(), ["manifest.json"])
            self.assertEqual(json.loads(archive.read("manifest.json")), manifest)
            self.assertEqual(archive.getinfo("manifest.json").date_time, (2026, 1, 1, 0, 0, 0))

    def test_reject_unsafe_module_paths(self):
        manifest = build_plugin.read_manifest(ROOT / "examples" / "audio-gain" / "manifest.json")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            for unsafe in ("../plugin.wasm", "/plugin.wasm", "C:/plugin.wasm", "a/../plugin.wasm", "a//plugin.wasm", "a\\plugin.wasm"):
                manifest["module"] = unsafe
                path.write_text(json.dumps(manifest), encoding="utf-8")
                with self.subTest(module=unsafe), self.assertRaises(ValueError):
                    build_plugin.read_manifest(path)

    def test_reject_non_finite_and_missing_module(self):
        manifest = build_plugin.read_manifest(ROOT / "examples" / "audio-gain" / "manifest.json")
        with self.assertRaises(ValueError):
            build_plugin.package_bytes(manifest, b"not a WASM module")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            manifest["limits"]["time_ms"] = float("nan")
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(ValueError):
                build_plugin.read_manifest(path)
            del manifest["limits"]
            del manifest["module"]
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(ValueError):
                build_plugin.read_manifest(path)

    def test_sdk_assets_match_sources(self):
        assets = ROOT.parent / "ffmpegpp_gui" / "assets" / "plugin_sdk"
        files = json.loads((assets / "files.json").read_text(encoding="utf-8"))
        self.assertTrue(files)
        self.assertEqual(len(files), len(set(files)))
        flat_names = [name.replace("/", "__") for name in files]
        self.assertEqual(len(flat_names), len(set(flat_names)))
        for name, flat in zip(files, flat_names):
            with self.subTest(file=name):
                self.assertEqual((ROOT / name).read_bytes(), (assets / flat).read_bytes())

    @unittest.skipUnless(shutil.which("clang") and shutil.which("node"), "real compilation requires clang, wasm-ld and node")
    def test_real_example_compiles_and_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "demo.fppplugin"
            wasm = Path(directory) / "demo.wasm"
            build_plugin.build(ROOT / "examples" / "audio-gain", output, emit_wasm=wasm, self_test=True)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(sorted(archive.namelist()), ["manifest.json", "plugin.wasm"])
                self.assertEqual(archive.read("plugin.wasm"), wasm.read_bytes())
                self.assertTrue(wasm.read_bytes().startswith(b"\0asm\x01\0\0\0"))

    @unittest.skipUnless(shutil.which("clang") and shutil.which("node"), "real compilation requires clang, wasm-ld and node")
    def test_video_flip_example_compiles_and_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "video-flip.fppplugin"
            wasm = Path(directory) / "video-flip.wasm"
            build_plugin.build(ROOT / "examples" / "video-flip", output, emit_wasm=wasm, self_test=True)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(sorted(archive.namelist()), ["manifest.json", "plugin.wasm"])
                manifest = json.loads(archive.read("manifest.json"))
                self.assertEqual(manifest["id"], "org.ffmpegpp.examples.video-flip")
                self.assertEqual(manifest["Node_info"][0]["output_type"], "video")
                self.assertEqual(archive.read("plugin.wasm"), wasm.read_bytes())
            self.assertTrue(wasm.read_bytes().startswith(b"\0asm\x01\0\0\0"))

    def test_shipped_requests_are_valid_complete_json(self):
        fixture = ROOT.parent / "docs" / "public" / "examples" / "plugin-fixtures" / "selftest.json"
        data = json.loads(fixture.read_text(encoding="utf-8"))
        self.assertEqual(len(data["cases"]), 16)
        self.assertEqual(len(data["cases"][-1]["request"]["padding"]), 17000)

    @unittest.skipUnless(shutil.which("node"), "fixture execution requires Node.js")
    def test_shipped_fixture_runs_with_current_manifest(self):
        # Verify behavior rather than assuming different compilers emit identical bytes.
        fixture = ROOT.parent / "docs" / "public" / "examples" / "plugin-demo.wasm"
        subprocess.run([shutil.which("node"), str(ROOT / "tools" / "self_test.mjs"), str(fixture),
                        str(ROOT / "examples" / "audio-gain" / "manifest.json")], check=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
