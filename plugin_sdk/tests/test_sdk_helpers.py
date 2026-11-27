import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SDK = Path(__file__).resolve().parents[1]
INCLUDE = SDK / "include"
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "sdk_helpers"


class SdkHelperTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("clang"), "freestanding header checks require clang")
    def test_headers_compile_as_freestanding_c_and_cpp(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "headers.c"
            source.write_text(
                '#include "ffmpegpp_plugin.h"\n'
                '#include "ffmpegpp_json.h"\n'
                '#include "ffmpegpp_ffmpeg.h"\n'
                'fpp_i32 c_smoke(void) { fpp_json_doc d; fpp_json_value v; '
                'fpp_ffmpeg_plan p; char b[128]; fpp_i32 n; '
                '(void)fpp_json_parse(&d, "{}", 2); (void)fpp_json_root(&d, &v); '
                '(void)fpp_ffmpeg_plan_init(&p, b, sizeof(b)); '
                '(void)fpp_ffmpeg_plan_write(&p, &n); return 0; }\n',
                encoding="ascii",
            )
            subprocess.run([
                shutil.which("clang"), "--target=wasm32", "-std=c11", "-nostdlib",
                "-fno-builtin", "-Wall", "-Wextra", "-Werror", "-I", str(INCLUDE),
                "-x", "c", "-fsyntax-only", str(source),
            ], check=True, timeout=30)
            cpp_source = source.with_suffix(".cpp")
            cpp_source.write_text(
                '#include "ffmpegpp_plugin.h"\n'
                '#include "ffmpegpp_json.h"\n'
                '#include "ffmpegpp_ffmpeg.h"\n'
                'fpp_i32 cpp_smoke() { fpp_json_doc d{}; fpp_json_value v{}; '
                'fpp_ffmpeg_plan p{}; char b[128]; fpp_i32 n = 0; '
                '(void)fpp_json_parse(&d, "{}", 2); (void)fpp_json_root(&d, &v); '
                '(void)fpp_ffmpeg_plan_init(&p, b, sizeof(b)); '
                '(void)fpp_ffmpeg_plan_write(&p, &n); return 0; }\n',
                encoding="ascii",
            )
            subprocess.run([
                shutil.which("clang++"), "--target=wasm32", "-std=c++17", "-nostdlib",
                "-fno-builtin", "-fno-exceptions", "-fno-rtti", "-Wall", "-Wextra",
                "-Werror", "-I", str(INCLUDE), "-x", "c++", "-fsyntax-only", str(cpp_source),
            ], check=True, timeout=30)

    @unittest.skipUnless(shutil.which("clang") and shutil.which("node"), "WASM helper execution requires clang and Node.js")
    def test_c_helpers_execute_bounds_and_response_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            wasm = Path(directory) / "sdk_helpers.wasm"
            subprocess.run([
                shutil.which("clang"), "--target=wasm32", "-std=c11", "-O1", "-nostdlib",
                "-fno-builtin", "-fvisibility=hidden", "-Wall", "-Wextra", "-Werror",
                "-I", str(INCLUDE), "-Wl,--no-entry,--export-memory,--initial-memory=131072",
                "-Wl,--max-memory=16777216,-z,stack-size=65536",
                str(FIXTURE / "helper_test.c"), "-o", str(wasm),
            ], check=True, timeout=60)
            subprocess.run([
                shutil.which("node"), str(FIXTURE / "run.mjs"), str(wasm),
            ], check=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
