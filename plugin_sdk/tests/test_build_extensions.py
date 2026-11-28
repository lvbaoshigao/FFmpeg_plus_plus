import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from test_build_plugin import build_plugin, ROOT

SDK_ROOT = ROOT
BUILDER = ROOT / "tools" / "build_plugin.py"


class BuildExtensionTests(unittest.TestCase):
    def make_example(self, directory, *, icon=False):
        example = Path(directory)
        example.mkdir(parents=True, exist_ok=True)
        nodes = [
            {"id": "tone_shift", "name": "Tone Shift", "fun": "Adjust tone", "IsLogic": True,
             "IO": {"inputs": 1, "outputs": 1}, "input_types": ["audio"], "output_type": "audio",
             "schema_version": 1, "fields": []},
            {"id": "frame_probe", "name": "Frame Probe", "fun": "Inspect frames", "IsLogic": True,
             "IO": {"inputs": 1, "outputs": 1}, "input_types": ["video"], "output_type": "video",
             "schema_version": 1, "fields": []},
        ]
        basic = {"Name": "Generic Multi-Source", "Version": "1.2.3", "IsPreview": True,
                 "Summary": "An arbitrary two-node test", "Author": "SDK test"}
        if icon:
            basic["Icon"] = "assets/icon.png"
            (example / "assets").mkdir()
            (example / "assets" / "icon.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"test")
        manifest = {"format_version": 1, "id": "org.example.generic", "api_version": 1,
                    "app_version": ">=6.0.0-beta2 <7.0.0", "Basic_info": basic,
                    "module": "plugin.wasm", "Node_info": nodes}
        (example / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        source_dir = example / "src"
        source_dir.mkdir()
        (source_dir / "filters.h").write_text(
            "#ifndef FILTERS_H\n#define FILTERS_H\n#define FILTER_SCORE 7\nint filter_score(void);\n#endif\n", encoding="utf-8")
        (source_dir / "filters.c").write_text(
            '#include "filters.h"\nint filter_score(void) { return FILTER_SCORE; }\n', encoding="utf-8")
        (source_dir / "plugin main.cpp").write_text(
            '#include "ffmpegpp_plugin.h"\n'
            '#include "manifest.generated.h"\n'
            'extern "C" int filter_score(void);\n'
            'template <class T> constexpr int marker() { if constexpr (sizeof(T) == 4) return 7; else return 0; }\n'
            'FPP_EXPORT(Basic_info) void Basic_info(void) { FPP_RESPOND_LITERAL(FPP_BASIC_JSON); }\n'
            'FPP_EXPORT(Node_info) void Node_info(void) { FPP_RESPOND_LITERAL(FPP_NODES_JSON); }\n'
            'static int invocation_count;\n'
            'FPP_EXPORT(Node_execute) void Node_execute(void) {\n'
            '  char request[256]; (void)fpp_read_json(request, (fpp_i32)sizeof(request));\n'
            '  int count = ++invocation_count;\n'
            '  if (filter_score() + marker<int>() == 14) {\n'
            '    if (count == 1) FPP_RESPOND_LITERAL("{\\"count\\":1}");\n'
            '    else FPP_RESPOND_LITERAL("{\\"count\\":2}");\n'
            '  }\n'
            '}\n', encoding="utf-8")
        (example / "build.json").write_text(json.dumps({"sources": ["src/plugin main.cpp", "src/filters.c"]}), encoding="utf-8")
        cases = [
            {"name": "metadata", "entry": "Basic_info", "request": {}, "response": basic},
            {"name": "all-nodes", "entry": "Node_info", "request": {}, "response": {"nodes": nodes}},
            {"name": "generic-execute", "entry": "Node_execute",
             "request": {"node_id": "frame_probe", "media_type": "video", "params": {}}, "response": {"count": 1}},
            {"name": "continuation-rounds", "steps": [
                {"entry": "Node_execute", "request": {"continuation": {"round": 1, "token": "alpha"}}, "response": {"count": 1}},
                {"entry": "Node_execute", "request": {"continuation": {"round": 2, "token": "beta"}}, "response": {"count": 1}},
            ]},
        ]
        (example / "selftest.json").write_text(json.dumps({"api_version": 1, "plugin_id": manifest["id"], "cases": cases}, indent=2), encoding="utf-8")
        return example, manifest, cases

    @unittest.skipUnless(shutil.which("clang") and shutil.which("wasm-ld") and shutil.which("node"),
                         "real C/C++ WASM build requires clang, wasm-ld and node")
    def test_build_config_auto_cases_and_real_mixed_cpp_c(self):
        with tempfile.TemporaryDirectory() as directory:
            example, manifest, cases = self.make_example(Path(directory) / "example", icon=True)
            package = Path(directory) / "demo.fppplugin"
            wasm = Path(directory) / "demo.wasm"
            fixture = Path(directory) / "native-fixtures.json"
            result = subprocess.run(
                [sys.executable, str(BUILDER), "--example", str(example), "--output", str(package),
                 "--emit-wasm", str(wasm), "--fixtures", str(fixture)],
                cwd=SDK_ROOT, check=True, capture_output=True, text=True, timeout=90)
            self.assertIn("PASS: 4 test cases", result.stdout)
            self.assertTrue(wasm.read_bytes().startswith(b"\0asm\x01\0\0\0"))
            fixture_data = json.loads(fixture.read_text(encoding="utf-8"))
            self.assertEqual(len(fixture_data["cases"]), 4)
            self.assertEqual(fixture_data["cases"][-1]["name"], "continuation-rounds")
            self.assertEqual([step["request"]["continuation"]["round"] for step in fixture_data["cases"][-1]["steps"]], [1, 2])
            with zipfile.ZipFile(package) as archive:
                self.assertEqual(archive.namelist(), ["assets/icon.png", "manifest.json", "plugin.wasm"])
                packaged_manifest = json.loads(archive.read("manifest.json"))
                self.assertEqual(packaged_manifest, manifest)
                self.assertEqual(archive.read("plugin.wasm"), wasm.read_bytes())
                self.assertEqual(archive.read("assets/icon.png"), b"\x89PNG\r\n\x1a\ntest")

    @unittest.skipUnless(shutil.which("clang") and shutil.which("wasm-ld") and shutil.which("node"),
                         "real C/C++ WASM build requires clang, wasm-ld and node")
    def test_cli_sources_override_config_and_accept_spaces(self):
        with tempfile.TemporaryDirectory() as directory:
            example, _, _ = self.make_example(Path(directory) / "example")
            # If --source were ignored, the invalid configured path would fail the build.
            (example / "build.json").write_text('{"sources":["does-not-exist.c"]}', encoding="utf-8")
            output = Path(directory) / "override.fppplugin"
            result = subprocess.run(
                [sys.executable, str(BUILDER), "--example", str(example), "--output", str(output),
                 "--source", "src/plugin main.cpp", "--source", "src/filters.c",
                 "--test-cases", str(example / "selftest.json")],
                cwd=SDK_ROOT, check=True, capture_output=True, text=True, timeout=90)
            self.assertIn("PASS: 4 test cases", result.stdout)
            self.assertTrue(output.read_bytes().startswith(b"PK"))

    @unittest.skipUnless(shutil.which("clang") and shutil.which("wasm-ld") and shutil.which("node"),
                         "auto self-test requires clang, wasm-ld and node")
    def test_selftest_json_runs_without_self_test_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            example, _, _ = self.make_example(Path(directory) / "example")
            output = Path(directory) / "automatic.fppplugin"
            result = subprocess.run(
                [sys.executable, str(BUILDER), "--example", str(example), "--output", str(output)],
                cwd=SDK_ROOT, check=True, capture_output=True, text=True, timeout=90)
            self.assertIn("PASS: 4 test cases", result.stdout)
            self.assertTrue(output.read_bytes().startswith(b"PK"))

    def test_source_path_validation_rejects_traversal_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            example, _, _ = self.make_example(Path(directory) / "example")
            for unsafe in ("../outside.c", "/tmp/outside.c", "src\\filters.c", "C:/outside.c", "src//filters.c"):
                with self.subTest(path=unsafe), self.assertRaises(ValueError):
                    build_plugin.resolve_sources(example, [unsafe])
            target = example / "src" / "filters.c"
            link = example / "src" / "linked.c"
            link.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "symlink"):
                build_plugin.resolve_sources(example, ["src/linked.c"])

    def test_oversized_icon_is_rejected_before_reading_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            example, manifest, _ = self.make_example(Path(directory) / "example", icon=True)
            icon = example / "assets" / "icon.png"
            icon.write_bytes(b"\x89PNG\r\n\x1a\n" + b"x" * (512 * 1024))
            with patch.object(Path, "read_bytes", side_effect=AssertionError("oversized icon was read")) as read_bytes:
                with self.assertRaisesRegex(ValueError, "512 KiB"):
                    build_plugin.read_icon(example, manifest)
                read_bytes.assert_not_called()

    def test_data_only_emit_wasm_does_not_publish_package(self):
        manifest_example = ROOT / "examples" / "theme-ai"
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "unchanged.fppplugin"
            package.write_bytes(b"old package")
            with self.assertRaisesRegex(ValueError, "data-only"):
                build_plugin.build(manifest_example, package, emit_wasm=Path(directory) / "theme.wasm")
            self.assertEqual(package.read_bytes(), b"old package")
            self.assertFalse((Path(directory) / "theme.wasm").exists())

    def test_output_aliases_are_rejected_before_any_build(self):
        with tempfile.TemporaryDirectory() as directory:
            example, _, _ = self.make_example(Path(directory) / "example")
            source = example / "src" / "plugin main.cpp"
            manifest = example / "manifest.json"
            test_cases = example / "selftest.json"
            for label, original in (("source", source), ("manifest", manifest), ("test case", test_cases)):
                alias = Path(directory) / (label.replace(" ", "-") + ".fppplugin")
                os.link(original, alias)
                before = original.read_bytes()
                with self.subTest(input=label), self.assertRaisesRegex(ValueError, "overwrite"):
                    build_plugin.build(example, alias)
                self.assertEqual(original.read_bytes(), before)
            package = Path(directory) / "same.fppplugin"
            package.write_bytes(b"not changed")
            with self.assertRaisesRegex(ValueError, "destinations must be different"):
                build_plugin.build(example, package, emit_wasm=package)
            self.assertEqual(package.read_bytes(), b"not changed")

            hardlink = Path(directory) / "same-hardlink.wasm"
            os.link(package, hardlink)
            with self.assertRaisesRegex(ValueError, "destinations must be different"):
                build_plugin.build(example, package, emit_wasm=hardlink)
            self.assertEqual(package.read_bytes(), b"not changed")

            manifest_alias = Path(directory) / "manifest-alias.wasm"
            os.link(example / "manifest.json", manifest_alias)
            with self.assertRaisesRegex(ValueError, "overwrite manifest"):
                build_plugin.build(example, Path(directory) / "fresh.fppplugin", emit_wasm=manifest_alias)
            self.assertTrue(manifest_alias.read_bytes().startswith(b"{"))

            testcase_alias = Path(directory) / "testcase-alias.json"
            os.link(example / "selftest.json", testcase_alias)
            with self.assertRaisesRegex(ValueError, "overwrite test cases"):
                build_plugin.build(example, Path(directory) / "other.fppplugin", fixtures=testcase_alias)
            self.assertTrue(testcase_alias.read_bytes().startswith(b"{"))

    def test_missing_test_case_path_fails_before_output_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            example, _, _ = self.make_example(Path(directory) / "example")
            output = Path(directory) / "existing.fppplugin"
            output.write_bytes(b"keep this package")
            with self.assertRaisesRegex(ValueError, "test case file not found"):
                build_plugin.build(example, output, test_cases=Path(directory) / "missing.json")
            self.assertEqual(output.read_bytes(), b"keep this package")

    @unittest.skipUnless(shutil.which("clang") and shutil.which("wasm-ld") and shutil.which("node"),
                         "metadata validation test requires clang, wasm-ld and node")
    def test_custom_metadata_expectation_cannot_override_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            example, manifest, cases = self.make_example(Path(directory) / "example")
            source = example / "src" / "plugin main.cpp"
            source_text = source.read_text(encoding="utf-8")
            source.write_text(source_text.replace(
                "FPP_RESPOND_LITERAL(FPP_BASIC_JSON);",
                r'FPP_RESPOND_LITERAL("{\"forged\":true}");'), encoding="utf-8")
            cases[0]["response"] = {"forged": True}
            (example / "selftest.json").write_text(json.dumps({"cases": cases}), encoding="utf-8")
            package = Path(directory) / "forged.fppplugin"
            with self.assertRaises(subprocess.CalledProcessError):
                build_plugin.build(example, package)
            self.assertFalse(package.exists())

    @unittest.skipUnless(shutil.which("clang") and shutil.which("wasm-ld") and shutil.which("node"),
                         "failure-preservation test requires clang, wasm-ld and node")
    def test_self_test_failure_preserves_all_existing_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            example, manifest, cases = self.make_example(Path(directory) / "example")
            cases[0]["response"] = {"not": "the metadata"}
            (example / "selftest.json").write_text(json.dumps({"cases": cases}), encoding="utf-8")
            package = Path(directory) / "old.fppplugin"
            wasm = Path(directory) / "old.wasm"
            fixtures = Path(directory) / "old-fixtures.json"
            package.write_bytes(b"previous package")
            wasm.write_bytes(b"previous wasm")
            fixtures.write_bytes(b"previous fixtures")
            with self.assertRaises(subprocess.CalledProcessError):
                build_plugin.build(example, package, emit_wasm=wasm, fixtures=fixtures)
            self.assertEqual(package.read_bytes(), b"previous package")
            self.assertEqual(wasm.read_bytes(), b"previous wasm")
            self.assertEqual(fixtures.read_bytes(), b"previous fixtures")


if __name__ == "__main__":
    unittest.main()
