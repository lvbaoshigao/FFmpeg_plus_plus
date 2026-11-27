#!/usr/bin/env python3
"""Compile the freestanding C example and make a deterministic .fppplugin ZIP.

Python 3.9+ standard library only; no shell invocation or automatic downloads.
The runtime/manager remain authoritative for ABI, permission and schema checks.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import zipfile

SDK_ROOT = Path(__file__).resolve().parents[1]
EXPORTS = ("Basic_info", "Node_info", "Node_editor_add", "Node_execute")


def compact(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), allow_nan=False)


def read_manifest(path):
    with Path(path).open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be an object")
    for key in ("format_version", "api_version"):
        if type(manifest.get(key)) is not int or manifest[key] != 1:
            raise ValueError(key + " must be integer 1")
    basic = manifest.get("Basic_info")
    if not isinstance(basic, dict) or set(basic) != {"Name", "Version", "IsPreview", "Summary"}:
        raise ValueError("Basic_info requires Name, Version, IsPreview and Summary")
    if not all(isinstance(basic[k], str) and basic[k] for k in ("Name", "Version", "Summary")) or type(basic["IsPreview"]) is not bool:
        raise ValueError("invalid Basic_info types")
    if not isinstance(manifest.get("id"), str) or not isinstance(manifest.get("app_version"), str):
        raise ValueError("id and app_version must be strings")
    module = manifest.get("module")
    if module is not None:
        if not isinstance(module, str) or not module or "\\" in module or ":" in module:
            raise ValueError("module must be a relative POSIX path")
        path = PurePosixPath(module)
        if path.is_absolute() or any(part in ("", ".", "..") for part in module.split("/")):
            raise ValueError("unsafe module path")
    if manifest.get("Node_info") and not module:
        raise ValueError("nodes require a WASM module")
    compact(manifest)  # Reject NaN/Infinity even though Python's JSON parser accepts them.
    return manifest


def find_compiler(explicit=None):
    if explicit:
        candidate = shutil.which(explicit) or str(Path(explicit).expanduser())
        if Path(candidate).is_file():
            return candidate
        raise ValueError("clang not found: " + explicit)
    names = []
    if os.environ.get("WASI_SDK_PATH"):
        names.append(str(Path(os.environ["WASI_SDK_PATH"]) / "bin" / ("clang.exe" if os.name == "nt" else "clang")))
    if os.environ.get("EMSDK"):
        names.append(str(Path(os.environ["EMSDK"]) / "upstream" / "bin" / ("clang.exe" if os.name == "nt" else "clang")))
    if os.environ.get("CLANG"):
        names.append(os.environ["CLANG"])
    names.append("clang")
    for name in names:
        candidate = shutil.which(name) or name
        if Path(candidate).is_file():
            return candidate
    raise ValueError("Install LLVM clang+wasm-ld, WASI SDK, or Emscripten; pass --clang or set WASI_SDK_PATH")


def find_linker(compiler, explicit=None):
    if explicit:
        candidate = shutil.which(explicit) or str(Path(explicit).expanduser())
        if Path(candidate).is_file():
            return candidate
        raise ValueError("wasm-ld not found: " + explicit)
    sibling = Path(compiler).resolve().parent / ("wasm-ld.exe" if os.name == "nt" else "wasm-ld")
    if sibling.is_file():
        return str(sibling)
    for name in ("wasm-ld", "wasm-ld-21", "wasm-ld-20", "wasm-ld-19", "wasm-ld-18", "wasm-ld-17"):
        candidate = shutil.which(name)
        if candidate:
            return candidate
    raise ValueError("wasm-ld missing; install the LLVM linker or pass --wasm-ld")


def generated_header(manifest):
    nodes = manifest.get("Node_info", [])
    fields = nodes[0].get("fields", []) if nodes else []
    data = {"FPP_BASIC_JSON": manifest["Basic_info"], "FPP_NODES_JSON": {"nodes": nodes}, "FPP_EDITOR_JSON": {"fields": fields}}
    return "/* Generated from manifest.json. Do not edit. */\n" + "".join(
        "#define " + key + " " + json.dumps(compact(value)) + "\n" for key, value in data.items()
    )


def package_bytes(manifest, wasm=None):
    import io
    output = io.BytesIO()
    entries = {"manifest.json": (compact(manifest) + "\n").encode("utf-8")}
    if manifest.get("module"):
        if wasm is None or not wasm.startswith(b"\0asm\x01\0\0\0"):
            raise ValueError("compiled module is missing or is not WebAssembly version 1")
        entries[manifest["module"]] = wasm
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, entries[name])
    return output.getvalue()


def build(example, output, clang=None, wasm_ld=None, emit_wasm=None, self_test=False, fixtures=None):
    example = Path(example).resolve()
    manifest = read_manifest(example / "manifest.json")
    output = Path(output).resolve()
    if output.suffix != ".fppplugin":
        raise ValueError("output must use the .fppplugin extension")
    wasm = None
    with tempfile.TemporaryDirectory(prefix="ffmpegpp-plugin-") as temp:
        temporary = Path(temp)
        if manifest.get("module"):
            compiler = find_compiler(clang)
            linker = find_linker(compiler, wasm_ld)
            (temporary / "manifest.generated.h").write_text(generated_header(manifest), encoding="ascii")
            target = temporary / "plugin.wasm"
            command = [compiler, "--target=wasm32", "-std=c11", "-O2", "-nostdlib", "-fno-builtin", "-fvisibility=hidden",
                       "-mno-simd128", "-mno-atomics", "-mno-bulk-memory", "-mno-reference-types", "-Werror", "-Wall", "-Wextra",
                       "-fuse-ld=" + str(linker), "-I", str(SDK_ROOT / "include"), "-I", str(temporary),
                       "-Wl,--no-entry,--export-memory,--initial-memory=131072,--max-memory=16777216,--strip-all",
                       str(example / "plugin.c"), "-o", str(target)]
            print("Compile:", subprocess.list2cmdline(command), flush=True)
            subprocess.run(command, check=True, timeout=60)
            if self_test or fixtures:
                node = shutil.which("node")
                if not node:
                    raise ValueError("--self-test/--fixtures requires Node.js; compilation itself does not")
                check = [node, str(SDK_ROOT / "tools" / "self_test.mjs"), str(target), str(example / "manifest.json")]
                if fixtures:
                    check += ["--fixtures", str(Path(fixtures).resolve())]
                subprocess.run(check, check=True, timeout=15)
            wasm = target.read_bytes()
        data = package_bytes(manifest, wasm)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    if emit_wasm:
        if wasm is None:
            raise ValueError("data-only plugin has no WASM to emit")
        wasm_path = Path(emit_wasm).resolve()
        wasm_path.parent.mkdir(parents=True, exist_ok=True)
        wasm_path.write_bytes(wasm)
    print("Package:", output, "(" + str(len(data)) + " bytes)", flush=True)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--example", type=Path, default=SDK_ROOT / "examples" / "audio-gain")
    parser.add_argument("--output", type=Path, default=SDK_ROOT / "dist" / "audio-gain.fppplugin")
    parser.add_argument("--clang", help="LLVM clang executable (not the emcc wrapper)")
    parser.add_argument("--wasm-ld", help="LLVM WASM linker executable")
    parser.add_argument("--emit-wasm", type=Path, help="also save the compiled .wasm fixture")
    parser.add_argument("--self-test", action="store_true", help="execute all four exports with Node.js")
    parser.add_argument("--fixtures", type=Path, help="save self-test requests/responses for native runtime tests")
    args = parser.parse_args()
    try:
        build(args.example, args.output, args.clang, args.wasm_ld, args.emit_wasm, args.self_test, args.fixtures)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("Build failed:", error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
