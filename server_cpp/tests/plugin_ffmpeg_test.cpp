#include "plugin_ffmpeg.h"
#include "ffmpegpp_exports.h"
#include "json_io.h"

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <thread>

using ffmpegpp::json;
namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
// Compile the production builder into this target for direct, platform-neutral
// tests; ABI integration below exercises the real shared-library implementation.
namespace ffmpegpp {
std::string getFFmpegPath() { return "ffmpeg"; }
void runFFmpegProcess(const std::string&, const std::vector<std::string>&, const CancelCheck&, const std::string&, bool) {
    throw std::runtime_error("unit-test process stub must not be called");
}
void JsonWriter::reply(const std::string&, bool, const json&, const std::string&) {
    throw std::runtime_error("unit-test reply stub must not be called");
}
}
static void require(bool ok, const std::string& text) { if (!ok) throw std::runtime_error(text); }
struct TempFiles {
    fs::path root = fs::temp_directory_path() / ("plugin-ffmpeg-test-" + std::to_string(Clock::now().time_since_epoch().count()));
    TempFiles() { fs::create_directories(root); }
    ~TempFiles() { std::error_code ec; fs::remove_all(root, ec); }
    std::string path(const std::string& filename) const { return (root / fs::u8path(filename)).u8string(); }
};
static int fakeTool(int argc, char** argv) {
    if (std::string(argv[1]) == "-v") {
        std::ofstream(fs::u8path(argv[argc - 1]).parent_path() / "ffprobe-called.marker") << "unexpected probe";
        std::cout << R"({"format":{"duration":"5.0","size":"10","format_name":"matroska"},"streams":[{"codec_type":"video","codec_name":"h264","width":32,"height":32,"pix_fmt":"yuv420p"},{"codec_type":"audio","codec_name":"pcm_s16le","sample_rate":"44100","channels":1}]})";
        return 0;
    }
    std::vector<std::string> args(argv + 1, argv + argc);
    require(std::count(args.begin(), args.end(), "-i") == 1, "fake tool observed multiple inputs");
    require(std::find(args.begin(), args.end(), "-nostdin") != args.end(), "stdin control missing");
    std::cerr << "  Duration: 00:00:05.00, start: 0.000000, bitrate: 10 kb/s\n";
    bool longRun = false, fail = false;
    for (size_t i = 0; i + 1 < args.size(); ++i) {
        if (args[i] == "-t" && args[i + 1] == "99") longRun = true;
        if (args[i] == "-crf" && args[i + 1] == "61") fail = true;
    }
    if (fail) { std::cerr << "controlled FFmpeg failure\n"; return 7; }
    for (int i = 0; i < (longRun ? 1000 : 4); ++i) {
        std::cerr << "frame= " << i + 1 << " fps=25 time=00:00:01.00 bitrate=10kbits/s speed=1.0x\r" << std::flush;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    std::ofstream out(fs::u8path(args.back()), std::ios::binary); out << "controlled output";
    return out.good() ? 0 : 8;
}
static std::vector<json> inbox;
static void collect() {
    while (char* p = ffmpegpp_poll()) {
        const std::string text(p); ffmpegpp_free(p); inbox.push_back(json::parse(text));
    }
}
static json waitFor(const std::function<bool(const json&)>& predicate) {
    const auto deadline = Clock::now() + std::chrono::seconds(5);
    while (Clock::now() < deadline) {
        collect();
        const auto found = std::find_if(inbox.begin(), inbox.end(), predicate);
        if (found != inbox.end()) { auto result = *found; inbox.erase(found); return result; }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    throw std::runtime_error("ABI event wait timed out");
}
static json reply(const std::string& id) {
    return waitFor([&](const json& j) { return j.value("id", "") == id && j.contains("success"); });
}
static void send(const std::string& id, const std::string& action, const json& params = json::object()) {
    const auto request = json{{"id", id}, {"action", action}, {"params", params}}.dump();
    require(ffmpegpp_request(request.c_str()) == 0, "ABI request rejected: " + action);
}
static void active(const std::string& id) {
    waitFor([&](const json& j) { return j.value("type", "") == "progress" && j.value("task_id", "") == id && j.value("progress", 0.0) > 0; });
}
int main(int argc, char** argv) {
    try {
        if (argc > 1 && (std::string(argv[1]) == "-nostdin" || std::string(argv[1]) == "-v")) return fakeTool(argc, argv);
        TempFiles files;
        const auto input = files.path("input ; literal file.mp4");
        const auto output = files.path("output ; literal file.mp4");
        std::ofstream(fs::u8path(input)) << "input";
        auto build = [&](const json& args, const std::string& type = "video", const std::string& target = "") {
            return ffmpegpp::buildPluginFFmpegCommand(input, target.empty() ? output : target, args, "video", type);
        };
        const auto command = build({"-vf", "eq=brightness=0.1:contrast=1.2:saturation=0.9,scale=1280:-2,transpose=1,setsar=1,setpts=PTS/2", "-c:v", "libx264", "-crf", "23", "-r", "30000/1001", "-c:a", "copy"});
        require(command.front() == "ffmpeg" && command.back() == output, "host binary/output binding changed");
        require(std::count(command.begin(), command.end(), "-i") == 1, "expected exactly one host input");
        const auto in = std::find(command.begin(), command.end(), "-i");
        require(in != command.end() && *std::next(in) == input, "input argv boundary changed");
        require(std::find(command.begin(), command.end(), "-protocol_whitelist") != command.end(), "protocol restrictions missing");
        require(std::find(command.begin(), command.end(), "-format_whitelist") != command.end(), "demuxer restrictions missing");
        build({"-af", "loudnorm=I=-16:TP=-1.5:LRA=11,atempo=1.1,afade=t=in:d=1,highpass=f=80,lowpass=f=16000,aformat=sample_fmts=fltp:channel_layouts=stereo", "-ar", "48000", "-ac", "2", "-b:a", "192k", "-c:a", "aac"}, "audio", files.path("audio.m4a"));
        build({"-filter_complex", "[0:v]split=2[a][b];[a]scale=320:240[x];[x][b]overlay=0:0[v]", "-map", "[v]", "-map", "0:a?"});
        const auto image = ffmpegpp::buildPluginFFmpegCommand(input, files.path("wave.png"),
            {"-filter_complex", "[0:a]showwavespic=s=640x120:colors=0x00ccff[v]", "-map", "[v]", "-frames:v", "1", "-c:v", "png"}, "audio", "image");
        require(image[image.size() - 3] == "-frames:v" && image[image.size() - 2] == "1", "single image guard missing");
        ffmpegpp::buildPluginFFmpegCommand(input, files.path("spectrum.png"), {"-filter_complex", "[0:a]showspectrumpic=s=640x480[v]", "-map", "[v]"}, "audio", "image");
        const auto caps = ffmpegpp::pluginFFmpegCapabilities();
        require(caps["api_version"] == 1 && caps["max_arguments"] == 128 && caps["max_argument_bytes"] == 8192 && caps["max_total_argument_bytes"] == 32768, "capability limits differ from contract");
        unsigned rejected = 0;
        auto reject = [&](const json& args) {
            bool failed = false; try { build(args); } catch (const std::exception&) { failed = true; }
            require(failed, "unsafe/malformed plan accepted: " + args.dump()); ++rejected;
        };
        for (const json& args : std::vector<json>{
            {"-i", "/etc/passwd"}, {"-vf", "null", "/tmp/other.mp4"}, {"-f", "hls"}, {"-f", "tee"}, {"-f", "segment"}, {"-f", "image2"},
            {"-report"}, {"-passlogfile", "/tmp/pass"}, {"-progress", "http://example.invalid"}, {"-filter_complex_script", "/tmp/graph"},
            {"-/vf", "/tmp/graph"}, {"-vf=movie=/etc/passwd"}, {"-filter:v", "null"}, {"-c:v", "libx264", "-c:v", "copy"},
            {"-vf", "movie=/etc/passwd"}, {"-af", "amovie=/etc/passwd"}, {"-vf", "drawtext=textfile=/etc/passwd"},
            {"-vf", "scale=/w=/etc/passwd"}, {"-vf", "scale=2:2,movie=/etc/passwd"}, {"-vf", "scale=2:2\\,movie=/etc/passwd"},
            {"-vf", "scale@alias=2:2"}, {"-vf", "scale=2:2;null"}, {"-vf", "scale=2:2,"}, {"-vf", "scale=2:2, null"}, {"-vf", "scale=w='iw':h=2"},
            {"-filter_complex", "[1:v]null[v]"}, {"-filter_complex", "[0:s]null[v]"}, {"-filter_complex", "[missing]null[v]"},
            {"-filter_complex", "null[v]"}, {"-filter_complex", "[0:v]split=17[a][b]"}, {"-filter_complex", "[0:v]split=2[a][a]"},
            {"-map", "[missing]"}, {"-map", "1:v"}, {"-map", "0:d"}, {"-map", "0"},
            {"-vf", "null", "-filter_complex", "[0:v]null[v]"}, {"-ar", "NaN"}, {"-ac", "-1"}, {"-r", "1/0"}, {"-t", "0"}, {"-crf"},
            {"-b:a", "999999999M"}, {"-vf", "null", "-an", "unexpected"}, json::object(), json::array({1}),
            json::array({"-vf", std::string("null\0,scale=1:1", 15)}), json::array({std::string(8193, 'x')})
        }) reject(args);
        reject(json(std::vector<std::string>(129, "-an")));
        reject(json(std::vector<std::string>(5, std::string(8192, 'x'))));
        std::string manyFilters = "null"; for (int i = 1; i < 65; ++i) manyFilters += ",null"; reject({"-vf", manyFilters});
        auto rejectPath = [&](const std::string& source, const std::string& target, const std::string& type) {
            bool failed = false; try { ffmpegpp::buildPluginFFmpegCommand(source, target, json::array(), "video", type); } catch (...) { failed = true; }
            require(failed, "unsafe host binding accepted"); ++rejected;
        };
        rejectPath("https://example.invalid/a.mp4", output, "video"); rejectPath("relative.mp4", output, "video");
        rejectPath(input, input, "video"); rejectPath(input, files.path("frames%03d.png"), "image");
        rejectPath(input, files.path("playlist.m3u8"), "video"); rejectPath(input, output, "unknown");
        bool badImage = false; try { build({"-frames:v", "2"}, "image", files.path("bad.png")); } catch (...) { badImage = true; } require(badImage, "multi-image output accepted");
        std::cout << "pure builder rejected " << rejected << " unsafe/malformed cases\n";

        require(ffmpegpp_init() == 0, "ABI init failed");
        struct Shutdown { ~Shutdown() { ffmpegpp_shutdown(); } } shutdown;
        const auto self = fs::canonical(fs::u8path(argv[0])).u8string();
        send("paths", "set_paths", {{"ffmpeg", self}, {"ffprobe", self}}); require(reply("paths")["success"] == true, "could not set fake executable");
        send("capabilities", "plugin_capabilities"); require(reply("capabilities")["data"]["ffmpeg"] == caps, "ABI FFmpeg capabilities differ");
        auto params = [&](const std::string& target, const json& args = json::array()) {
            return json{{"input", input}, {"output", files.path(target)}, {"arguments", args}, {"input_type", "video"}, {"output_type", "video"}};
        };
        send("malformed", "plugin_ffmpeg", params("invalid.mp4", {"-i", "/etc/passwd"})); require(!reply("malformed").value("success", true), "ABI accepted extra input");
        require(!fs::exists(fs::u8path(files.path("invalid.mp4"))), "invalid plan executed a process");
        send("success", "plugin_ffmpeg", params("successful output ; literal.mp4", {"-vf", "hflip", "-c:v", "libx264"}));
        const auto success = reply("success");
        require(success.value("success", false) && success["data"]["output_size"] == 17, "ABI normal FFmpeg task failed: " + success.dump());
        require(success["data"]["command"][0] == self, "plugin selected executable");
        require(!fs::exists(files.root / "ffprobe-called.marker"), "plugin action launched the uncancellable ffprobe");
        send("failure", "plugin_ffmpeg", params("failure.mp4", {"-crf", "61"})); const auto failure = reply("failure");
        require(!failure.value("success", true) && failure.value("error", "").find("controlled FFmpeg failure") != std::string::npos, "ABI process diagnostics lost");

        send("active", "plugin_ffmpeg", params("cancelled.mp4", {"-t", "99"})); active("active");
        send("queued", "plugin_ffmpeg", params("queued.mp4"));
        send("pause", "pause", {{"task_ids", {"active"}}}); require(reply("pause").value("success", false), "pause failed");
        std::this_thread::sleep_for(std::chrono::milliseconds(80));
        send("cancel", "cancel", {{"task_ids", {"active", "queued"}}}); reply("cancel");
        const auto cancelStart = Clock::now();
        require(!reply("active").value("success", true) && !reply("queued").value("success", true), "running/queued cancellation failed");
        require(Clock::now() - cancelStart < std::chrono::seconds(2), "paused task cancellation stalled");
        require(!fs::exists(fs::u8path(files.path("queued.mp4"))), "cancelled queued task executed");
        send("after-cancel", "plugin_ffmpeg", params("after-cancel.mp4")); require(reply("after-cancel").value("success", false), "pause/cancel state poisoned an unrelated task");

        send("all-active", "plugin_ffmpeg", params("all-cancelled.mp4", {"-t", "99"})); active("all-active");
        send("all-queued", "plugin_ffmpeg", params("all-queued.mp4"));
        send("cancel-all", "cancel"); reply("cancel-all");
        require(!reply("all-active").value("success", true) && !reply("all-queued").value("success", true), "global cancellation did not cover queue");
        require(!fs::exists(fs::u8path(files.path("all-queued.mp4"))), "global-cancelled queued task executed");
        send("after-all", "plugin_ffmpeg", params("after-all.mp4")); require(reply("after-all").value("success", false), "global cancellation poisoned new task");

        send("same", "plugin_ffmpeg", {{"input", input}, {"output", input}, {"arguments", json::array()}, {"input_type", "video"}, {"output_type", "video"}});
        require(!reply("same").value("success", true), "ABI allowed overwriting input");
#ifndef _WIN32
        fs::create_symlink(fs::u8path(input), fs::u8path(files.path("symlink.mp4")));
        send("symlink", "plugin_ffmpeg", params("symlink.mp4")); require(!reply("symlink").value("success", true), "ABI followed output symlink");
        fs::create_hard_link(fs::u8path(input), fs::u8path(files.path("hardlink.mp4")));
        send("hardlink", "plugin_ffmpeg", params("hardlink.mp4")); require(!reply("hardlink").value("success", true), "ABI followed same-file hardlink");
#endif
        require(!fs::exists(files.root / "ffprobe-called.marker"), "plugin action launched ffprobe during cancellation");
        std::cout << "ABI queue/progress/pause/cancel/global-cancel/path validation passed without ffprobe\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
