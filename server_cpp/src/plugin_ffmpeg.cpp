#include "plugin_ffmpeg.h"
#include "constants.h"
#include "installer.h"
#include "json_io.h"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <map>
#include <regex>
#include <set>
#include <stdexcept>

namespace ffmpegpp {
namespace {
constexpr size_t kMaxArguments = 128;
constexpr size_t kMaxArgumentBytes = 8192;
constexpr size_t kMaxTotalArgumentBytes = 32768;
constexpr size_t kMaxFilters = 64;
const std::set<std::string> kOptions = {
    "-c:v", "-c:a", "-b:v", "-b:a", "-crf", "-q:v", "-preset",
    "-pix_fmt", "-r", "-ar", "-ac", "-frames:v", "-t", "-ss",
    "-map", "-vf", "-af", "-filter_complex", "-f", "-an", "-vn", "-shortest"
};
const std::set<std::string> kVideoFilters = {
    "null", "scale", "crop", "pad", "hflip", "vflip", "transpose", "rotate",
    "format", "eq", "hue", "setsar", "setdar", "fps", "trim", "setpts",
    "split", "overlay", "fade", "unsharp", "boxblur", "gblur", "hqdn3d",
    "yadif", "bwdif", "reverse"
};
const std::set<std::string> kAudioFilters = {
    "anull", "volume", "atempo", "atrim", "asetpts", "afade", "aformat",
    "aresample", "loudnorm", "dynaudnorm", "highpass", "lowpass", "equalizer",
    "bass", "treble", "acompressor", "agate", "alimiter", "asplit", "amix",
    "amerge", "areverse"
};
const std::set<std::string> kVisualizers = {"showwavespic", "showspectrumpic"};
const std::set<std::string> kVideoCodecs = {
    "copy", "libx264", "libx265", "libvpx", "libvpx-vp9", "libaom-av1", "libsvtav1",
    "h264_nvenc", "hevc_nvenc", "av1_nvenc", "h264_amf", "hevc_amf", "av1_amf",
    "h264_qsv", "hevc_qsv", "av1_qsv", "h264_mediacodec", "hevc_mediacodec",
    "mpeg4", "mpeg2video", "ffv1", "png", "mjpeg", "bmp", "tiff", "libwebp", "gif"
};
const std::set<std::string> kAudioCodecs = {
    "copy", "aac", "libmp3lame", "libopus", "flac", "libfdk_aac", "ac3", "eac3",
    "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "libvorbis", "vorbis", "wmav2"
};
const std::set<std::string> kVideoMuxers = {"mp4", "mov", "matroska", "webm", "avi", "mpegts", "mpeg", "ogg"};
const std::set<std::string> kAudioMuxers = {"wav", "mp3", "flac", "ogg", "opus", "adts", "ipod", "mp4", "matroska"};
const std::set<std::string> kVideoExtensions = {".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi", ".ts", ".mpg", ".mpeg", ".ogv"};
const std::set<std::string> kAudioExtensions = {".wav", ".mp3", ".flac", ".ogg", ".opus", ".aac", ".m4a", ".mka"};
const std::set<std::string> kImageExtensions = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tif", ".tiff", ".gif"};
// Exclude playlist, concat, device and network demuxers: a single -i must not
// become permission to follow references to other media or network resources.
const char* kInputFormats = "mov,matroska,webm,avi,mpeg,mpegts,mp3,wav,flac,ogg,aac,ac3,eac3,aiff,asf,flv,ape,wv,tta,au,image2,png_pipe,jpeg_pipe,webp_pipe,bmp_pipe,tiff_pipe,gif";

[[noreturn]] void invalid(const std::string& message) {
    throw std::runtime_error("Plugin FFmpeg: " + message);
}
bool matches(const std::string& value, const char* pattern) {
    return std::regex_match(value, std::regex(pattern));
}
void checkType(const std::string& type) {
    if (type != "video" && type != "audio" && type != "image") invalid("invalid media type");
}
std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}
void checkLocalPath(const std::string& value) {
    if (value.size() > 32768 || !isPathSafe(value) || value.find("://") != std::string::npos ||
        value.find('%') != std::string::npos || !std::filesystem::u8path(value).is_absolute())
        invalid("media paths must be absolute local paths without patterns");
    for (unsigned char c : value) if (c < 32 || c == 127) invalid("invalid media path character");
    const auto path = std::filesystem::u8path(value);
    for (const auto& part : path) if (part == "..") invalid("media path traversal is not allowed");
    if (path.filename().empty() || path.filename() == "." || path.filename() == "..") invalid("invalid media filename");
#ifdef _WIN32
    // Win32 device names/alternate streams are not ordinary host output files.
    const auto filename = path.filename().u8string();
    if (filename.find(':') != std::string::npos || filename.back() == '.' || filename.back() == ' ') invalid("invalid Windows media filename");
    const auto stem = lower(filename.substr(0, filename.find('.')));
    if (matches(stem, "(con|prn|aux|nul|com[0-9]|lpt[0-9])")) invalid("Windows device path is not allowed");
#endif
}
void checkNumber(const std::string& value, double minimum, double maximum, bool integer = false) {
    if (value.size() > 16 || !matches(value, integer ? "[0-9]+" : "[0-9]+([.][0-9]+)?")) invalid("invalid numeric argument");
    double number;
    try { number = std::stod(value); } catch (...) { invalid("numeric argument is out of range"); }
    if (!std::isfinite(number) || number < minimum || number > maximum) invalid("numeric argument is out of range");
}
void checkRate(const std::string& value) {
    const auto slash = value.find('/');
    if (slash == std::string::npos) { checkNumber(value, 0.01, 1000); return; }
    const auto numerator = value.substr(0, slash), denominator = value.substr(slash + 1);
    checkNumber(numerator, 1, 1000000, true); checkNumber(denominator, 1, 1000000, true);
    const auto rate = std::stod(numerator) / std::stod(denominator);
    if (rate < 0.01 || rate > 1000) invalid("frame rate is out of range");
}
void checkBitrate(const std::string& value) {
    if (!matches(value, "[1-9][0-9]{0,8}([.][0-9]{1,3})?[kKmM]?")) invalid("invalid bitrate");
    std::string number = value;
    double multiplier = 1;
    const auto suffix = number.back();
    if (suffix == 'k' || suffix == 'K') { multiplier = 1000; number.pop_back(); }
    if (suffix == 'm' || suffix == 'M') { multiplier = 1000000; number.pop_back(); }
    const auto bitrate = std::stod(number) * multiplier;
    if (bitrate < 1 || bitrate > 1000000000) invalid("bitrate is out of range");
}

bool isHostLabel(const std::string& label) { return matches(label, "0:[va](:[0-9]{1,2})?"); }
bool isPrivateLabel(const std::string& label) { return matches(label, "[A-Za-z_][A-Za-z0-9_]{0,31}"); }
struct FilterLabels { std::set<std::string> defined, used; };
std::string readLabel(const std::string& text, size_t& pos) {
    const auto end = text.find(']', pos + 1);
    if (end == std::string::npos) invalid("unterminated filter label");
    const auto label = text.substr(pos + 1, end - pos - 1);
    if (!isHostLabel(label) && !isPrivateLabel(label)) invalid("only this input and local filter labels are allowed");
    pos = end + 1;
    return label;
}
FilterLabels checkFilters(const std::string& graph, const std::string& option) {
    if (graph.empty()) invalid("empty filter graph");
    // A deliberately small grammar. No quoting, escapes, instance identifiers or
    // file-loaded options: separators cannot be disguised from this validator.
    for (unsigned char c : graph) {
        if (c < 33 || c > 126 || c == '\'' || c == '"' || c == '\\' || c == '@')
            invalid("filter graph quoting, escaping, whitespace and instances are not supported");
    }
    FilterLabels labels;
    size_t start = 0, count = 0;
    bool chainStart = true;
    while (start < graph.size()) {
        const auto separator = graph.find_first_of(",;", start);
        const auto end = separator == std::string::npos ? graph.size() : separator;
        const auto node = graph.substr(start, end - start);
        if (node.empty() || ++count > kMaxFilters) invalid("empty or excessive filter graph");
        size_t pos = 0, inputs = 0;
        while (pos < node.size() && node[pos] == '[') {
            const auto label = readLabel(node, pos);
            if (option != "-filter_complex") invalid("labels require -filter_complex");
            if (!isHostLabel(label)) labels.used.insert(label);
            if (++inputs > 16) invalid("too many filter inputs");
        }
        if (option == "-filter_complex" && chainStart && !inputs) invalid("each complex filter chain needs a bound input label");
        const auto nameStart = pos;
        while (pos < node.size() && ((node[pos] >= 'a' && node[pos] <= 'z') ||
               (node[pos] >= '0' && node[pos] <= '9') || node[pos] == '_')) ++pos;
        const auto name = node.substr(nameStart, pos - nameStart);
        const bool video = kVideoFilters.count(name), audio = kAudioFilters.count(name);
        if ((!video && !audio && !kVisualizers.count(name)) ||
            (option == "-vf" && !video) || (option == "-af" && !audio)) invalid("unsupported filter: " + name);
        std::string options;
        if (pos < node.size() && node[pos] == '=') {
            const auto valueStart = ++pos;
            while (pos < node.size() && node[pos] != '[') ++pos;
            options = node.substr(valueStart, pos - valueStart);
            if (options.empty()) invalid("empty filter options");
            size_t fieldStart = 0;
            while (fieldStart <= options.size()) {
                auto fieldEnd = options.find(':', fieldStart);
                if (fieldEnd == std::string::npos) fieldEnd = options.size();
                const auto field = options.substr(fieldStart, fieldEnd - fieldStart);
                if (field.empty()) invalid("empty filter option");
                const auto equal = field.find('=');
                if (equal != std::string::npos && (equal > 64 || !matches(field.substr(0, equal), "[A-Za-z_][A-Za-z0-9_]*")))
                    invalid("invalid filter option name");
                const auto value = equal == std::string::npos ? field : field.substr(equal + 1);
                if (value.empty()) invalid("empty filter option value");
                for (unsigned char c : value) {
                    const bool alnum = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
                    if (!alnum && std::string("_+.*/%()<>!^#|?=~-").find(char(c)) == std::string::npos)
                        invalid("unsupported filter option syntax");
                }
                if (fieldEnd == options.size()) break;
                fieldStart = fieldEnd + 1;
            }
        }
        if ((name == "split" || name == "asplit") && !options.empty()) {
            auto outputs = options;
            if (outputs.rfind("outputs=", 0) == 0) outputs = outputs.substr(8);
            checkNumber(outputs, 1, 16, true);
        }
        size_t outputs = 0;
        while (pos < node.size() && node[pos] == '[') {
            const auto label = readLabel(node, pos);
            if (option != "-filter_complex" || !isPrivateLabel(label) || !labels.defined.insert(label).second)
                invalid("invalid or duplicate filter output label");
            if (++outputs > 16 || labels.defined.size() > 64) invalid("too many filter output labels");
        }
        if (pos != node.size()) invalid("unsupported filter syntax");
        if (separator == std::string::npos) break;
        if (graph[separator] == ';' && option != "-filter_complex") invalid("multiple chains require -filter_complex");
        chainStart = graph[separator] == ';';
        start = separator + 1;
        if (start == graph.size()) invalid("trailing filter separator");
    }
    for (const auto& label : labels.used) if (!labels.defined.count(label)) invalid("unknown filter input label");
    return labels;
}

std::pair<std::string, std::string> bindLocalFiles(const std::string& input, const std::string& output) {
    checkLocalPath(input); checkLocalPath(output);
    namespace fs = std::filesystem;
    std::error_code ec;
    const auto in = fs::canonical(fs::u8path(input), ec);
    if (ec || !fs::is_regular_file(in, ec) || ec) invalid("input must be an existing local regular file");
    const auto requestedOut = fs::u8path(output);
    const auto parent = fs::canonical(requestedOut.parent_path(), ec);
    if (ec || !fs::is_directory(parent, ec) || ec) invalid("output directory must already exist");
    const auto out = parent / requestedOut.filename();
    const auto status = fs::symlink_status(out, ec);
    if (ec && ec != std::errc::no_such_file_or_directory) invalid("cannot inspect output path");
    if (fs::is_symlink(status) || (fs::exists(status) && !fs::is_regular_file(status))) invalid("output must be a local regular file");
    if (in == out || (fs::exists(status) && fs::equivalent(in, out, ec))) invalid("input and output must be different files");
    return {in.u8string(), out.u8string()};
}
} // namespace

json pluginFFmpegCapabilities() {
    auto filters = kVideoFilters;
    filters.insert(kAudioFilters.begin(), kAudioFilters.end());
    filters.insert(kVisualizers.begin(), kVisualizers.end());
    return {{"api_version", 1}, {"max_arguments", kMaxArguments},
        {"max_argument_bytes", kMaxArgumentBytes}, {"max_total_argument_bytes", kMaxTotalArgumentBytes},
        {"options", kOptions}, {"filters", filters}};
}

std::vector<std::string> buildPluginFFmpegCommand(
    const std::string& input, const std::string& output, const json& arguments,
    const std::string& inputType, const std::string& outputType) {
    checkType(inputType); checkType(outputType); checkLocalPath(input); checkLocalPath(output);
    if (std::filesystem::u8path(input).lexically_normal() == std::filesystem::u8path(output).lexically_normal()) invalid("input and output must differ");
    const auto extension = lower(std::filesystem::u8path(output).extension().u8string());
    const auto& extensions = outputType == "image" ? kImageExtensions : outputType == "audio" ? kAudioExtensions : kVideoExtensions;
    if (!extensions.count(extension)) invalid("unsupported single-file output extension for media type");
    if (!arguments.is_array() || arguments.size() > kMaxArguments) invalid("arguments must be an array with at most 128 items");
    std::vector<std::string> args;
    size_t total = 0;
    for (const auto& item : arguments) {
        if (!item.is_string()) invalid("arguments must contain only strings");
        const auto value = item.get<std::string>();
        if (value.empty() || value.size() > kMaxArgumentBytes || (total += value.size()) > kMaxTotalArgumentBytes) invalid("argument byte limit exceeded");
        for (unsigned char c : value) if (c < 32 || c == 127) invalid("invalid argument character");
        args.push_back(value);
    }
    std::set<std::string> seen;
    std::vector<std::string> maps;
    FilterLabels labels;
    for (size_t i = 0; i < args.size(); ++i) {
        const auto& option = args[i];
        if (!kOptions.count(option)) invalid("unsupported option: " + option);
        if (option != "-map" && !seen.insert(option).second) invalid("duplicate option: " + option);
        if (option == "-an" || option == "-vn" || option == "-shortest") {
            if ((option == "-an" && outputType == "audio") || (option == "-vn" && outputType != "audio")) invalid("disabled required output stream");
            continue;
        }
        if (++i == args.size()) invalid("missing value for option: " + option);
        const auto& value = args[i];
        if (option == "-c:v") { if (!kVideoCodecs.count(value)) invalid("unsupported video encoder"); }
        else if (option == "-c:a") { if (!kAudioCodecs.count(value)) invalid("unsupported audio encoder"); }
        else if (option == "-b:v" || option == "-b:a") checkBitrate(value);
        else if (option == "-crf") checkNumber(value, 0, 63);
        else if (option == "-q:v") checkNumber(value, 1, 100);
        else if (option == "-preset") { if (!isInWhitelist(value, VALID_PRESETS)) invalid("unsupported encoding preset"); }
        else if (option == "-pix_fmt") { if (!isInWhitelist(value, VALID_PIX_FMTS)) invalid("unsupported pixel format"); }
        else if (option == "-r") checkRate(value);
        else if (option == "-ar") checkNumber(value, 8000, 384000, true);
        else if (option == "-ac") checkNumber(value, 1, 32, true);
        else if (option == "-frames:v") {
            checkNumber(value, 1, 10000000, true);
            if (outputType == "image" && std::stod(value) != 1) invalid("image output is exactly one frame");
        }
        else if (option == "-t" || option == "-ss") checkNumber(value, option == "-t" ? 0.001 : 0, 2678400);
        else if (option == "-map") {
            if (!matches(value, "0:[va](:[0-9]{1,2})?[?]?|\\[[A-Za-z_][A-Za-z0-9_]{0,31}\\]")) invalid("map must reference this input or a local filter label");
            if (maps.size() >= 16) invalid("too many stream maps");
            maps.push_back(value);
        }
        else if (option == "-vf" || option == "-af" || option == "-filter_complex") {
            const auto found = checkFilters(value, option);
            labels.defined.insert(found.defined.begin(), found.defined.end());
        }
        else if (option == "-f") {
            const auto& muxers = outputType == "audio" ? kAudioMuxers : kVideoMuxers;
            if (outputType == "image" || !muxers.count(value)) invalid("unsupported single-file output muxer");
        }
    }
    if (seen.count("-filter_complex") && (seen.count("-vf") || seen.count("-af"))) invalid("complex and simple filter options cannot be combined");
    for (const auto& map : maps) if (map.front() == '[' && !labels.defined.count(map.substr(1, map.size() - 2))) invalid("map references an unknown filter output");
    std::vector<std::string> command = {getFFmpegPath(), "-nostdin", "-hide_banner", "-y", "-stats",
        "-protocol_whitelist", "file", "-format_whitelist", kInputFormats, "-i", input};
    command.insert(command.end(), args.begin(), args.end());
    // Guest options never disable stats or override the media-chain binding.
    command.insert(command.end(), {"-sn", "-dn"});
    if (outputType == "audio") command.push_back("-vn");
    if (outputType == "image") command.insert(command.end(), {"-an", "-frames:v", "1"});
    command.push_back(output);
    return command;
}

void handlePluginFFmpeg(const json& req, const CancelCheck& isCancelled) {
    const auto id = req.at("id").get<std::string>();
    try {
        if (isCancelled && isCancelled()) { JsonWriter::reply(id, false, nullptr, "任务已取消"); return; }
        const auto& params = req.at("params");
        if (!params.is_object()) invalid("params must be an object");
        const std::set<std::string> keys = {"input", "output", "arguments", "input_type", "output_type"};
        for (auto it = params.begin(); it != params.end(); ++it) if (!keys.count(it.key())) invalid("unknown request parameter: " + it.key());
        const auto files = bindLocalFiles(params.at("input").get<std::string>(), params.at("output").get<std::string>());
        const auto command = buildPluginFFmpegCommand(files.first, files.second, params.at("arguments"),
            params.at("input_type").get<std::string>(), params.at("output_type").get<std::string>());
        if (isCancelled && isCancelled()) { JsonWriter::reply(id, false, nullptr, "任务已取消"); return; }
        runFFmpegProcess(id, command, isCancelled, files.second, false);
    } catch (const std::exception& e) { JsonWriter::reply(id, false, nullptr, e.what()); }
}
} // namespace ffmpegpp
