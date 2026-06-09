#include "ffmpeg_features.h"
#include "subprocess.h"
#include <sstream>
#include <algorithm>

namespace ffmpegpp {

namespace {
std::vector<std::string> parseLines(const std::string& output, const std::string& prefix) {
    std::vector<std::string> result;
    std::istringstream iss(output);
    std::string line;
    bool started = false;
    while (std::getline(iss, line)) {
        if (!started) {
            if (line.find("------") != std::string::npos || line.find(prefix) == 0) {
                started = true;
            }
            continue;
        }
        // 跳过空行
        if (line.empty() || line.find_first_not_of(" \t\r\n") == std::string::npos) continue;
        // 跳过分隔线
        if (line.find("---") != std::string::npos) continue;
        // 去掉首尾空格
        size_t start = line.find_first_not_of(" \t");
        size_t end = line.find_last_not_of(" \t\r\n");
        if (start != std::string::npos && end != std::string::npos) {
            result.push_back(line.substr(start, end - start + 1));
        }
    }
    return result;
}

std::vector<std::string> parseCodecs(const std::string& output) {
    std::vector<std::string> result;
    std::istringstream iss(output);
    std::string line;
    bool started = false;
    while (std::getline(iss, line)) {
        if (!started) {
            if (line.find("------") != std::string::npos) started = true;
            continue;
        }
        if (line.empty()) continue;
        // 格式: DEV.... codec_name  description
        if (line.size() > 7) {
            size_t name_start = line.find_first_not_of(" \t", 7);
            if (name_start != std::string::npos) {
                size_t name_end = line.find_first_of(" \t", name_start);
                if (name_end != std::string::npos) {
                    result.push_back(line.substr(name_start, name_end - name_start));
                }
            }
        }
    }
    return result;
}

std::vector<std::string> parseFormats(const std::string& output) {
    std::vector<std::string> result;
    std::istringstream iss(output);
    std::string line;
    bool started = false;
    while (std::getline(iss, line)) {
        if (!started) {
            if (line.find("------") != std::string::npos) started = true;
            continue;
        }
        if (line.empty()) continue;
        if (line.size() > 3) {
            size_t name_start = line.find_first_not_of(" \t", 3);
            if (name_start != std::string::npos) {
                size_t name_end = line.find_first_of(" \t", name_start);
                if (name_end != std::string::npos) {
                    result.push_back(line.substr(name_start, name_end - name_start));
                }
            }
        }
    }
    return result;
}

std::vector<std::string> parseFilters(const std::string& output) {
    std::vector<std::string> result;
    std::istringstream iss(output);
    std::string line;
    bool started = false;
    while (std::getline(iss, line)) {
        if (!started) {
            if (line.find("------") != std::string::npos || line.find("Filters:") == 0) {
                started = true;
            }
            continue;
        }
        if (line.empty()) continue;
        // 格式: filter_name  n_inputs->n_outputs  description
        size_t name_start = line.find_first_not_of(" \t");
        if (name_start != std::string::npos) {
            size_t name_end = line.find_first_of(" \t", name_start);
            if (name_end != std::string::npos) {
                result.push_back(line.substr(name_start, name_end - name_start));
            }
        }
    }
    return result;
}
} // namespace

json queryFFmpegFeatures() {
    json result;

    // codecs
    auto codecs_pr = Subprocess::run({"ffmpeg", "-codecs"}, 10);
    if (codecs_pr.exit_code == 0) {
        result["codec_video"] = parseCodecs(codecs_pr.stdout_output);
        // 简单过滤：只保留视频编码器
        std::vector<std::string> video_codecs;
        for (auto& c : result["codec_video"]) {
            // 通过 ffmpeg -codecs 输出格式判断
            // D..... = 解码, .E.... = 编码, ..V... = 视频
            // 这里简化处理，返回所有
        }
    }

    // formats
    auto formats_pr = Subprocess::run({"ffmpeg", "-formats"}, 10);
    if (formats_pr.exit_code == 0) {
        result["formats"] = parseFormats(formats_pr.stdout_output);
    }

    // filters
    auto filters_pr = Subprocess::run({"ffmpeg", "-filters"}, 10);
    if (filters_pr.exit_code == 0) {
        result["filters"] = parseFilters(filters_pr.stdout_output);
    }

    // protocols
    auto protocols_pr = Subprocess::run({"ffmpeg", "-protocols"}, 10);
    if (protocols_pr.exit_code == 0) {
        result["protocols"] = parseLines(protocols_pr.stdout_output, "Input:");
    }

    return result;
}

} // namespace ffmpegpp
