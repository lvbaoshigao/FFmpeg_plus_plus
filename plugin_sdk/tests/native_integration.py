#!/usr/bin/env python3
"""Exercise compiled media-toolkit WASM through the native FFmpeg++ ABI.

This is deliberately standard-library-only. It drives the same queue/poll/free
ABI used by the GUI, so WAMR and the host FFmpeg action are both exercised.
"""

import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

SDK_ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = SDK_ROOT / "examples" / "media-toolkit"
BUILD_SCRIPT = SDK_ROOT / "tools" / "build_plugin.py"
REQUEST_TIMEOUT = 30.0
BUILD_TIMEOUT = 240.0
MEDIA_TIMEOUT = 45.0


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def encode_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def executable_path(value, label):
    candidate = shutil.which(value) or value
    path = Path(candidate).expanduser().resolve()
    if not path.is_file():
        raise RuntimeError("{} executable not found: {}".format(label, value))
    if os.name != "nt" and not os.access(str(path), os.X_OK):
        raise RuntimeError("{} is not executable: {}".format(label, path))
    return path


def find_ffmpeg(explicit):
    if explicit:
        return executable_path(explicit, "ffmpeg")
    found = shutil.which("ffmpeg")
    return executable_path(found, "ffmpeg") if found else None


def find_ffprobe(ffmpeg):
    suffix = ".exe" if os.name == "nt" else ""
    if ffmpeg:
        sibling = ffmpeg.with_name("ffprobe" + suffix)
        if sibling.is_file():
            return executable_path(str(sibling), "ffprobe")
    found = shutil.which("ffprobe")
    return executable_path(found, "ffprobe") if found else None


def run_bounded(argv, timeout, what):
    try:
        result = subprocess.run([str(part) for part in argv], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, encoding="utf-8", errors="replace", timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("{} timed out after {}s".format(what, timeout)) from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise RuntimeError("{} failed (exit {}): {}".format(what, result.returncode, detail[-6000:]))
    return result


class NativeABI:
    def __init__(self, library_path):
        # CDLL uses the C calling convention on POSIX and Windows.
        try:
            self.library = ctypes.CDLL(str(library_path))
        except OSError as exc:
            raise RuntimeError("cannot load native library {}: {}".format(library_path, exc)) from exc
        self.library.ffmpegpp_init.argtypes = []
        self.library.ffmpegpp_init.restype = ctypes.c_int
        self.library.ffmpegpp_request.argtypes = [ctypes.c_char_p]
        self.library.ffmpegpp_request.restype = ctypes.c_int
        self.library.ffmpegpp_poll.argtypes = []
        self.library.ffmpegpp_poll.restype = ctypes.c_void_p
        self.library.ffmpegpp_free.argtypes = [ctypes.c_void_p]
        self.library.ffmpegpp_free.restype = None
        self.library.ffmpegpp_shutdown.argtypes = []
        self.library.ffmpegpp_shutdown.restype = None
        self.counter = 0
        self.started = False
        self.pending_replies = {}
        self.pending_events = {}

    def init(self):
        code = self.library.ffmpegpp_init()
        require(code == 0, "ffmpegpp_init returned {}".format(code))
        self.started = True

    def close(self):
        if self.started:
            self.library.ffmpegpp_shutdown()
            self.started = False

    def poll(self):
        pointer = self.library.ffmpegpp_poll()
        if not pointer:
            return None
        try:
            raw = ctypes.string_at(pointer)
        finally:
            self.library.ffmpegpp_free(pointer)
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RuntimeError("native ABI returned invalid UTF-8 JSON: {}".format(exc)) from exc

    def send(self, action, params=None, request_id=None):
        if request_id is None:
            self.counter += 1
            request_id = "native-integration-{}-{}".format(os.getpid(), self.counter)
        payload = {"id": request_id, "action": action, "params": params or {}}
        code = self.library.ffmpegpp_request(encode_json(payload))
        require(code == 0, "ffmpegpp_request rejected action {} (return {})".format(action, code))
        return request_id

    def route(self, message, request_id=None, events=None):
        """Keep replies for other tasks instead of losing cross-task queue events."""
        task_id = message.get("task_id")
        if task_id:
            if task_id == request_id and events is not None:
                events.append(message)
            else:
                self.pending_events.setdefault(task_id, []).append(message)
        reply_id = message.get("id")
        if reply_id and "success" in message:
            if reply_id == request_id:
                return message
            self.pending_replies[reply_id] = message
        return None

    def wait_reply(self, request_id, timeout=REQUEST_TIMEOUT, events=None, on_message=None):
        if events is not None:
            events.extend(self.pending_events.pop(request_id, []))
        pending = self.pending_replies.pop(request_id, None)
        if pending is not None:
            return pending
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.poll()
            if message is None:
                time.sleep(0.005)
                continue
            if on_message is not None:
                on_message(message)
            reply = self.route(message, request_id=request_id, events=events)
            if reply is not None:
                return reply
        raise RuntimeError("backend reply timed out for {} after {}s".format(request_id, timeout))

    def request(self, action, params=None, timeout=REQUEST_TIMEOUT):
        request_id = self.send(action, params)
        return self.wait_reply(request_id, timeout=timeout)


def build_wasm(work_root):
    wasm = work_root / "plugin.wasm"
    package = work_root / "media-toolkit.fppplugin"
    fixtures_path = work_root / "selftest-fixtures.json"
    cases_path = EXAMPLE / "selftest.json"
    command = [sys.executable, str(BUILD_SCRIPT), "--example", str(EXAMPLE), "--output", str(package),
               "--emit-wasm", str(wasm), "--self-test", "--fixtures", str(fixtures_path),
               "--test-cases", str(cases_path)]
    result = run_bounded(command, BUILD_TIMEOUT, "media-toolkit build and SDK self-test")
    if result.stdout.strip():
        print(result.stdout.strip())
    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr)
    require(wasm.is_file() and wasm.stat().st_size > 8, "builder did not emit a WASM module")
    require(package.is_file(), "builder did not create the plugin package")
    require(fixtures_path.is_file(), "builder did not emit native self-test fixtures")
    with fixtures_path.open(encoding="utf-8") as stream:
        fixture_data = json.load(stream)
    cases = fixture_data.get("cases") if isinstance(fixture_data, dict) else None
    require(isinstance(cases, list) and cases, "fixture file has no cases array")
    return wasm, fixture_data, cases


def verify_capabilities(abi):
    reply = abi.request("plugin_capabilities")
    require(reply.get("success") is True, "plugin_capabilities failed: {}".format(reply))
    data = reply.get("data") or {}
    require(data.get("available") is True and data.get("runtime") == "WAMR",
            "native WAMR plugin runtime is unavailable: {}".format(data))
    ffmpeg = data.get("ffmpeg")
    require(isinstance(ffmpeg, dict) and ffmpeg.get("api_version") == 1,
            "plugin_capabilities.data.ffmpeg is missing or malformed: {}".format(ffmpeg))
    require("-filter_complex" in ffmpeg.get("options", []) and "loudnorm" in ffmpeg.get("filters", []),
            "FFmpeg capability options/filters are incomplete: {}".format(ffmpeg))
    print("PASS: native capabilities advertise WAMR and controlled FFmpeg")


def verify_wasm_fixtures(abi, root, wasm, fixture_data, cases):
    set_root = abi.request("plugin_set_root", {"root": str(root.resolve())})
    require(set_root.get("success") is True and (set_root.get("data") or {}).get("configured") is True,
            "plugin_set_root failed: {}".format(set_root))
    require(fixture_data.get("api_version") == 1, "unsupported native fixture api_version")
    actual_successes = {}
    for case in cases:
        name = case.get("name", "<unnamed>")
        require(case.get("entry") in {"Basic_info", "Node_info", "Node_editor_add", "Node_execute"},
                "unexpected fixture entry for {}".format(name))
        request = case.get("request")
        expected = case.get("response")
        require(isinstance(request, dict) and isinstance(expected, dict), "malformed fixture {}".format(name))
        reply = abi.request("plugin_invoke", {"module_path": str(wasm.resolve()), "entry": case["entry"], "request": request})
        require(reply.get("success") is True, "WAMR fixture {} failed: {}".format(name, reply))
        actual = reply.get("data")
        require(actual == expected, "WAMR fixture {} mismatch; expected {}, got {}".format(name, expected, actual))
        if case["entry"] == "Node_execute" and actual.get("operation") == "ffmpeg.execute":
            node_id = request.get("node_id")
            # Nodes may have several valid success fixtures; retain one executable plan.
            actual_successes.setdefault(node_id, (request, actual))
    expected_nodes = {"video_tone", "audio_normalize", "audio_waveform"}
    require(set(actual_successes) == expected_nodes,
            "expected successful Node_execute plans for {}, got {}".format(sorted(expected_nodes), sorted(actual_successes)))
    print("PASS: WAMR executed all {} self-test fixtures (including error responses)".format(len(cases)))
    return actual_successes


def set_paths(abi, ffmpeg, ffprobe):
    params = {}
    if ffmpeg:
        params["ffmpeg"] = str(ffmpeg.resolve())
    if ffprobe:
        params["ffprobe"] = str(ffprobe.resolve())
    reply = abi.request("set_paths", params)
    require(reply.get("success") is True, "set_paths failed: {}".format(reply))


def generate_inputs(ffmpeg, directory):
    audio = directory / "short-audio.wav"
    video = directory / "small-video.mkv"
    run_bounded([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                 "sine=frequency=440:sample_rate=44100:duration=1", "-ac", "1", "-ar", "44100", str(audio)],
                20, "generate one-second audio fixture")
    run_bounded([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                 "color=c=blue:s=64x64:r=12:d=1", "-an", "-c:v", "mpeg4", "-q:v", "5", str(video)],
                20, "generate small video fixture")
    require(audio.is_file() and audio.stat().st_size > 44, "audio fixture was not generated")
    require(video.is_file() and video.stat().st_size > 64, "video fixture was not generated")
    return audio, video


def validate_output(path, expected_type, ffprobe):
    require(path.is_file() and path.stat().st_size > 0, "FFmpeg output missing or empty: {}".format(path))
    with path.open("rb") as stream:
        signature = stream.read(12)
    suffix = path.suffix.lower()
    if expected_type == "audio":
        require(suffix == ".wav" and signature[:4] == b"RIFF" and signature[8:12] == b"WAVE",
                "audio_normalize output is not a WAV file")
        stream_type = "audio"
    elif expected_type == "image":
        require(suffix == ".png" and signature[:8] == b"\x89PNG\r\n\x1a\n",
                "audio_waveform output is not a PNG file")
        stream_type = "video"
    else:
        require(suffix == ".mkv" and signature[:4] == b"\x1aE\xdf\xa3",
                "video_tone output is not a Matroska video file")
        stream_type = "video"
    if ffprobe:
        result = run_bounded([ffprobe, "-v", "error", "-show_entries", "stream=codec_type", "-of", "json", str(path)],
                             10, "verify output media type with ffprobe")
        streams = json.loads(result.stdout).get("streams", [])
        require(any(stream.get("codec_type") == stream_type for stream in streams),
                "ffprobe did not find expected {} stream in {}".format(stream_type, path))


def verify_media_execution(abi, plans, directory, ffmpeg, ffprobe):
    set_paths(abi, ffmpeg, ffprobe)
    audio, video = generate_inputs(ffmpeg, directory)
    specs = {
        "video_tone": (video, ".mkv", "video"),
        "audio_normalize": (audio, ".wav", "audio"),
        "audio_waveform": (audio, ".png", "image"),
    }
    for node_id in ("video_tone", "audio_normalize", "audio_waveform"):
        request, wasm_response = plans[node_id]
        input_path, extension, output_type = specs[node_id]
        output = directory / (node_id + extension)
        require(wasm_response.get("operation") == "ffmpeg.execute", "{} did not return ffmpeg.execute".format(node_id))
        arguments = wasm_response.get("arguments")
        require(isinstance(arguments, list) and all(isinstance(item, str) for item in arguments),
                "{} returned malformed FFmpeg arguments".format(node_id))
        require(request.get("input_media_type") in ("audio", "video") and
                request.get("output_media_type") == output_type, "{} fixture media types are inconsistent".format(node_id))
        task_id = abi.send("plugin_ffmpeg", {"input": str(input_path.resolve()), "output": str(output.resolve()),
            "arguments": arguments, "input_type": request["input_media_type"], "output_type": request["output_media_type"]})
        events = []
        reply = abi.wait_reply(task_id, timeout=MEDIA_TIMEOUT, events=events)
        require(reply.get("success") is True, "plugin_ffmpeg {} failed: {}".format(node_id, reply))
        require(reply.get("data", {}).get("output_path") == str(output.resolve()),
                "plugin_ffmpeg {} returned an unexpected output path: {}".format(node_id, reply))
        require(any(event.get("type") == "progress" and "progress" in event for event in events),
                "plugin_ffmpeg {} did not publish progress".format(node_id))
        require(any(event.get("progress", -1) >= 100 for event in events),
                "plugin_ffmpeg {} did not publish completion progress".format(node_id))
        validate_output(output, output_type, ffprobe)
        print("PASS: {} Node_execute arguments produced {} ({} bytes)".format(node_id, output.name, output.stat().st_size))


def verify_dangerous_arguments(abi, directory):
    source = directory / "reject-input.wav"
    output = directory / "must-not-exist.wav"
    source.write_bytes(b"RIFF" + b"\0" * 40 + b"WAVE")
    reply = abi.request("plugin_ffmpeg", {"input": str(source.resolve()), "output": str(output.resolve()),
        "arguments": ["-y"], "input_type": "audio", "output_type": "audio"})
    require(reply.get("success") is False and reply.get("error"),
            "dangerous FFmpeg argument was not rejected: {}".format(reply))
    require(not output.exists(), "unsafe FFmpeg request created an output file")
    print("PASS: unsupported/dangerous FFmpeg argument rejected without output")


def verify_linux_cancellation(abi, directory, ffprobe):
    if not sys.platform.startswith("linux"):
        print("SKIP: fake-executable cancellation check is Linux-only")
        return
    marker = directory / "fake-ffmpeg-started"
    fake = directory / "fake-ffmpeg"
    script = "#!/usr/bin/env python3\nimport time\nfrom pathlib import Path\nPath({!r}).write_text('started', encoding='ascii')\ntime.sleep(20)\n".format(str(marker))
    fake.write_text(script, encoding="utf-8")
    fake.chmod(fake.stat().st_mode | 0o111)
    set_paths(abi, fake.resolve(), ffprobe)
    source = directory / "cancel-input.wav"
    source.write_bytes(b"RIFF" + b"\0" * 40 + b"WAVE")
    output = directory / "cancelled-output.wav"
    task_id = "native-integration-cancel-{}".format(os.getpid())
    abi.send("plugin_ffmpeg", {"input": str(source.resolve()), "output": str(output.resolve()),
        "arguments": ["-af", "anull"], "input_type": "audio", "output_type": "audio"}, request_id=task_id)
    early_reply = []
    deadline = time.monotonic() + 12.0
    while time.monotonic() < deadline and not marker.exists():
        message = abi.poll()
        if message:
            routed = abi.route(message, request_id=task_id)
            if routed is not None:
                early_reply.append(routed)
                break
        else:
            time.sleep(0.005)
    require(marker.exists(), "fake FFmpeg did not start before cancellation test timeout: {}".format(early_reply))
    cancel_id = abi.send("cancel", {"task_ids": [task_id]})
    cancel_reply = abi.wait_reply(cancel_id, timeout=REQUEST_TIMEOUT)
    require(cancel_reply.get("success") is True, "backend rejected cancellation request: {}".format(cancel_reply))
    reply = early_reply[0] if early_reply else abi.wait_reply(task_id, timeout=REQUEST_TIMEOUT)
    require(reply.get("success") is False, "cancelled backend FFmpeg task incorrectly succeeded: {}".format(reply))
    require(not output.exists(), "cancelled FFmpeg task left an output file")
    print("PASS: cancelling a running plugin_ffmpeg task returns failure, not success")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, help="path to the built FFmpeg++ shared library")
    parser.add_argument("--ffmpeg", help="FFmpeg executable; defaults to PATH, media checks skip if absent")
    args = parser.parse_args()
    library_path = Path(args.library).expanduser().resolve()
    require(library_path.is_file(), "native shared library not found: {}".format(library_path))
    ffmpeg = find_ffmpeg(args.ffmpeg)
    ffprobe = find_ffprobe(ffmpeg)

    with tempfile.TemporaryDirectory(prefix="ffmpegpp-native-integration-") as temp:
        root = Path(temp).resolve()
        wasm, fixture_data, cases = build_wasm(root)
        abi = NativeABI(library_path)
        try:
            abi.init()
            verify_capabilities(abi)
            plans = verify_wasm_fixtures(abi, root, wasm, fixture_data, cases)
            verify_dangerous_arguments(abi, root)
            if ffmpeg:
                verify_media_execution(abi, plans, root, ffmpeg, ffprobe)
            else:
                print("SKIP: FFmpeg was not found; real media execution skipped (WAMR fixtures still ran)")
            verify_linux_cancellation(abi, root, ffprobe)
        finally:
            abi.close()
    print("PASS: native WAMR-to-FFmpeg integration checks completed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print("FAIL: {}".format(exc), file=sys.stderr)
        sys.exit(1)
