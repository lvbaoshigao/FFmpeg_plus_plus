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
    required_basic = {"Name", "Version", "IsPreview", "Summary"}
    allowed_basic = required_basic | {"Author", "Icon"}
    if not isinstance(basic, dict) or not required_basic <= set(basic) or set(basic) - allowed_basic:
        raise ValueError("Basic_info requires Name, Version, IsPreview and Summary; optional fields are Author and Icon")
    if not all(isinstance(basic[k], str) and basic[k] for k in ("Name", "Version", "Summary")) or type(basic["IsPreview"]) is not bool:
        raise ValueError("invalid Basic_info types")
    author = basic.get("Author")
    if author is not None and (not isinstance(author, str) or not author.strip() or len(author) > 120):
        raise ValueError("Author must be a non-empty string of at most 120 characters")
    icon = basic.get("Icon")
    if icon is not None:
        if not isinstance(icon, str) or not icon or "\\" in icon or ":" in icon:
            raise ValueError("Icon must be a relative package path")
        path = PurePosixPath(icon)
        if path.is_absolute() or any(part in ("", ".", "..") for part in icon.split("/")):
            raise ValueError("unsafe icon path")
        if path.suffix.lower() not in (".png", ".jpg", ".jpeg", ".webp", ".gif"):
            raise ValueError("Icon must use PNG, JPEG, WebP or GIF")
        if len(icon) > 240:
            raise ValueError("icon path is too long")
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
    if icon is not None and module is not None and icon.casefold() == module.casefold():
        raise ValueError("Icon and module paths must be different")
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


def valid_icon_bytes(path, data):
    if not isinstance(data, bytes) or not data or len(data) > 512 * 1024:
        return False
    suffix = PurePosixPath(path).suffix.lower()
    return {
        ".png": data.startswith(b"\x89PNG\r\n\x1a\n"),
        ".jpg": data.startswith(b"\xff\xd8\xff"),
        ".jpeg": data.startswith(b"\xff\xd8\xff"),
        ".gif": data.startswith((b"GIF87a", b"GIF89a")),
        ".webp": len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP",
    }.get(suffix, False)


def read_icon(example, manifest):
    icon = manifest["Basic_info"].get("Icon")
    if icon is None:
        return None
    root = Path(example).resolve()
    source = Path(example)
    for part in icon.split("/"):
        source = source / part
        if source.is_symlink():
            raise ValueError("icon assets cannot be symlinks")
    resolved = source.resolve()
    if root not in resolved.parents or not resolved.is_file():
        raise ValueError("icon asset must be a regular file inside the example directory")
    size = resolved.stat().st_size
    if size <= 0 or size > 512 * 1024:
        raise ValueError("icon asset is invalid or exceeds 512 KiB")
    data = resolved.read_bytes()
    if not valid_icon_bytes(icon, data):
        raise ValueError("icon asset is invalid or exceeds 512 KiB")
    return data


def package_bytes(manifest, wasm=None, icon_bytes=None):
    import io
    output = io.BytesIO()
    entries = {"manifest.json": (compact(manifest) + "\n").encode("utf-8")}
    if manifest.get("module"):
        if wasm is None or not wasm.startswith(b"\0asm\x01\0\0\0"):
            raise ValueError("compiled module is missing or is not WebAssembly version 1")
        entries[manifest["module"]] = wasm
    icon = manifest["Basic_info"].get("Icon")
    if icon is not None:
        if icon in entries or not valid_icon_bytes(icon, icon_bytes):
            raise ValueError("declared icon is missing, invalid, or exceeds 512 KiB")
        entries[icon] = icon_bytes
    elif icon_bytes is not None:
        raise ValueError("icon bytes supplied without a manifest icon path")
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, entries[name])
    return output.getvalue()


def _relative_file(example, value, label):
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise ValueError(label + " must be a relative POSIX path")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts) or PurePosixPath(value).is_absolute():
        raise ValueError("unsafe " + label + " path")
    root = Path(example).resolve()
    candidate = root
    for part in parts:
        candidate = candidate / part
        if candidate.is_symlink():
            raise ValueError(label + " paths cannot contain symlinks")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise ValueError(label + " file does not exist: " + value) from error
    if root not in resolved.parents or not resolved.is_file():
        raise ValueError(label + " must be a regular file inside the example directory")
    return resolved


def resolve_sources(example, sources=None):
    example = Path(example).resolve()
    if sources is not None:
        if isinstance(sources, (str, Path)):
            candidates = [str(sources)]
        elif isinstance(sources, (list, tuple)):
            candidates = list(sources)
        else:
            raise ValueError("sources must be a sequence of relative paths")
    else:
        config = example / "build.json"
        candidates = None
        if config.exists():
            if config.is_symlink() or not config.is_file():
                raise ValueError("build.json must be a regular file")
            if config.stat().st_size > 65536:
                raise ValueError("build.json exceeds 64 KiB")
            with config.open(encoding="utf-8") as stream:
                settings = json.load(stream)
            if not isinstance(settings, dict) or set(settings) - {"sources"}:
                raise ValueError("build.json must be an object containing only sources")
            if "sources" in settings:
                candidates = settings["sources"]
        if candidates is None:
            candidates = ["plugin.c"]
    if not isinstance(candidates, list) or not candidates:
        raise ValueError("at least one source file is required")
    if len(candidates) > 32:
        raise ValueError("at most 32 source files may be compiled")
    result = []
    seen = set()
    for value in candidates:
        source = _relative_file(example, value, "source")
        if source.stat().st_size > 8 * 1024 * 1024:
            raise ValueError("source file exceeds 8 MiB: " + str(value))
        identity = source.relative_to(example).as_posix().casefold()
        if identity in seen:
            raise ValueError("duplicate source file: " + str(value))
        seen.add(identity)
        suffix = source.suffix.lower()
        if source.suffix == ".C" or suffix in (".cc", ".cpp", ".cxx"):
            language = "c++"
        elif suffix == ".c":
            language = "c"
        else:
            raise ValueError("source files must use .c, .cc, .cpp or .cxx: " + str(value))
        result.append((source, language))
    return result


def resolve_test_cases(example, test_cases=None):
    if test_cases is not None:
        path = Path(test_cases).expanduser()
        if not path.is_file():
            raise ValueError("test case file not found: " + str(path))
        return path.resolve()
    automatic = Path(example) / "selftest.json"
    return automatic.resolve() if automatic.is_file() else None


def _paths_alias(left, right):
    if left == right:
        return True
    try:
        return os.path.samefile(left, right)
    except (OSError, ValueError):
        return False


def _validate_outputs(outputs, inputs):
    for index, (name, path) in enumerate(outputs):
        if path.exists() and path.is_dir():
            raise ValueError(name + " destination must be a file")
        for other_name, other_path in outputs[:index]:
            if _paths_alias(path, other_path):
                raise ValueError(name + " and " + other_name + " destinations must be different")
        for input_name, input_path in inputs:
            if _paths_alias(path, input_path):
                raise ValueError(name + " destination must not overwrite " + input_name)


def _atomic_write_files(files):
    staged = []
    try:
        for destination, data in files:
            destination.parent.mkdir(parents=True, exist_ok=True)
            descriptor, name = tempfile.mkstemp(prefix="." + destination.name + ".", suffix=".tmp",
                                                dir=str(destination.parent))
            staged_path = Path(name)
            staged.append((staged_path, destination))
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(staged_path, 0o644)
        for staged_path, destination in staged:
            os.replace(staged_path, destination)
    finally:
        for staged_path, _ in staged:
            try:
                staged_path.unlink()
            except FileNotFoundError:
                pass


def build(example, output, clang=None, wasm_ld=None, emit_wasm=None, self_test=False, fixtures=None,
          sources=None, test_cases=None):
    example = Path(example).expanduser().resolve()
    manifest_path = (example / "manifest.json").resolve()
    manifest = read_manifest(manifest_path)
    icon_bytes = read_icon(example, manifest)
    icon_path = example / manifest["Basic_info"]["Icon"] if manifest["Basic_info"].get("Icon") else None
    selected_sources = resolve_sources(example, sources) if manifest.get("module") else []
    selected_tests = resolve_test_cases(example, test_cases) if manifest.get("module") else None
    output = Path(output).expanduser().resolve()
    wasm_path = Path(emit_wasm).expanduser().resolve() if emit_wasm is not None else None
    fixtures_path = Path(fixtures).expanduser().resolve() if fixtures is not None else None
    if output.suffix != ".fppplugin":
        raise ValueError("output must use the .fppplugin extension")
    if wasm_path is not None and not manifest.get("module"):
        raise ValueError("data-only plugin has no WASM to emit")
    if fixtures_path is not None and not manifest.get("module"):
        raise ValueError("self-test fixtures require a compiled WASM module")
    inputs = [("manifest", manifest_path)]
    inputs.extend(("source", path) for path, _ in selected_sources)
    if selected_tests is not None:
        inputs.append(("test cases", selected_tests))
    if icon_path is not None:
        inputs.append(("icon", icon_path.resolve()))
    config_path = example / "build.json"
    if config_path.exists():
        inputs.append(("build configuration", config_path.resolve()))
    outputs = [("output", output)]
    if wasm_path is not None:
        outputs.append(("WASM", wasm_path))
    if fixtures_path is not None:
        outputs.append(("fixtures", fixtures_path))
    _validate_outputs(outputs, inputs)

    wasm = None
    fixture_data = None
    with tempfile.TemporaryDirectory(prefix="ffmpegpp-plugin-") as temp:
        temporary = Path(temp)
        if manifest.get("module"):
            compiler = find_compiler(clang)
            linker = find_linker(compiler, wasm_ld)
            (temporary / "manifest.generated.h").write_text(generated_header(manifest), encoding="ascii")
            target = temporary / "plugin.wasm"
            common = [compiler, "--target=wasm32", "-O2", "-nostdlib", "-fno-builtin", "-fvisibility=hidden",
                      "-mno-simd128", "-mno-atomics", "-mno-bulk-memory", "-mno-reference-types",
                      "-Werror", "-Wall", "-Wextra", "-I", str(SDK_ROOT / "include"), "-I", str(temporary)]
            objects = []
            for index, (source, language) in enumerate(selected_sources):
                object_file = temporary / ("source-" + str(index) + ".o")
                if language == "c++":
                    language_flags = ["-x", "c++", "-std=c++17", "-fno-exceptions", "-fno-rtti", "-nostdinc++"]
                else:
                    language_flags = ["-x", "c", "-std=c11"]
                command = common + language_flags + ["-c", str(source), "-o", str(object_file)]
                print("Compile:", subprocess.list2cmdline(command), flush=True)
                subprocess.run(command, check=True, timeout=60)
                objects.append(object_file)
            command = [compiler, "--target=wasm32", "-nostdlib", "-fuse-ld=" + str(linker),
                       "-Wl,--no-entry,--export-memory,--initial-memory=131072,--max-memory=16777216,--strip-all",
                       *map(str, objects), "-o", str(target)]
            print("Link:", subprocess.list2cmdline(command), flush=True)
            subprocess.run(command, check=True, timeout=60)
            if self_test or fixtures_path is not None or selected_tests is not None:
                node = shutil.which("node")
                if not node:
                    raise ValueError("self-testing requires Node.js; compilation itself does not")
                check = [node, str(SDK_ROOT / "tools" / "self_test.mjs"), str(target), str(manifest_path)]
                if selected_tests is not None:
                    check += ["--test-cases", str(selected_tests)]
                if fixtures_path is not None:
                    fixture_stage = temporary / "fixtures.json"
                    check += ["--fixtures", str(fixture_stage)]
                subprocess.run(check, check=True, timeout=30)
                if fixtures_path is not None:
                    fixture_data = fixture_stage.read_bytes()
            wasm = target.read_bytes()
        data = package_bytes(manifest, wasm, icon_bytes)
    writes = [(output, data)]
    if wasm_path is not None:
        writes.append((wasm_path, wasm))
    if fixtures_path is not None:
        writes.append((fixtures_path, fixture_data))
    _atomic_write_files(writes)
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
    parser.add_argument("--source", action="append", dest="sources", help="C/C++ source path relative to --example; repeatable")
    parser.add_argument("--test-cases", type=Path, help="JSON self-test cases; defaults to example/selftest.json when present")
    args = parser.parse_args()
    try:
        build(args.example, args.output, args.clang, args.wasm_ld, args.emit_wasm, args.self_test, args.fixtures,
              args.sources, args.test_cases)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("Build failed:", error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
