#include "ffmpeg_features.h"
#include "subprocess.h"
#include "installer.h"
#include <sstream>
#include <algorithm>

namespace ffmpegpp {

namespace {

// 解析 ffmpeg -encoders / -decoders 输出，按类型分类
// 格式: D/E A/V/S. ...  codec_name  description
std::vector<std::string> parseCodecsByType(const std::string& output, char mediaType, bool encodeOnly) {
    std::vector<std::string> result;
    std::istringstream iss(output);
    std::string line;
    bool started = false;
    while (std::getline(iss, line)) {
        // 去掉 \r
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!started) {
            if (line.find("------") != std::string::npos) started = true;
            continue;
        }
        if (line.empty() || line.size() < 7) continue;
        // line[0]=D(解码)/. line[1]=E(编码)/. line[2]=V/A/S/.  ...
        char enc = line[1];
        char media = line[2];
        if (media != mediaType) continue;
        if (encodeOnly && enc != 'E') continue;

        size_t name_start = line.find_first_not_of(" \t", 7);
        if (name_start == std::string::npos) continue;
        size_t name_end = line.find_first_of(" \t", name_start);
        if (name_end == std::string::npos) continue;
        result.push_back(line.substr(name_start, name_end - name_start));
    }
    return result;
}

// 解析 ffmpeg -formats 输出
// 格式: D/E.  fmt1,fmt2  description
std::vector<std::string> parseFormats(const std::string& output) {
    std::vector<std::string> result;
    std::istringstream iss(output);
    std::string line;
    bool started = false;
    while (std::getline(iss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!started) {
            if (line.find("------") != std::string::npos) started = true;
            continue;
        }
        if (line.empty() || line.size() < 4) continue;
        // 提取 format 名称（可能逗号分隔多个）
        size_t name_start = line.find_first_not_of(" \t", 3);
        if (name_start == std::string::npos) continue;
        size_t name_end = line.find_first_of(" \t", name_start);
        std::string names = (name_end != std::string::npos)
            ? line.substr(name_start, name_end - name_start)
            : line.substr(name_start);
        // 逗号分隔
        std::istringstream nss(names);
        std::string token;
        while (std::getline(nss, token, ',')) {
            if (!token.empty()) result.push_back(token);
        }
    }
    return result;
}

// 解析 ffmpeg -filters 输出
// 格式: T.S.  filter_name  ...  description
std::vector<std::string> parseFilters(const std::string& output) {
    std::vector<std::string> result;
    std::istringstream iss(output);
    std::string line;
    bool started = false;
    while (std::getline(iss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!started) {
            if (line.find("------") != std::string::npos || line.find("Filters:") == 0) started = true;
            continue;
        }
        if (line.empty()) continue;
        // 跳过标志位 (T.S./N.A./.. 等)
        size_t pos = 0;
        int spaceCount = 0;
        while (pos < line.size() && spaceCount < 3) {
            if (line[pos] == ' ') {
                spaceCount++;
                // 跳过连续空格
                while (pos < line.size() && line[pos] == ' ') pos++;
            } else {
                pos++;
            }
        }
        size_t name_start = line.find_first_not_of(" \t", pos);
        if (name_start == std::string::npos) continue;
        size_t name_end = line.find_first_of(" \t", name_start);
        if (name_end != std::string::npos) {
            result.push_back(line.substr(name_start, name_end - name_start));
        }
    }
    return result;
}

// 解析 ffmpeg -protocols 输出
std::vector<std::string> parseProtocols(const std::string& output) {
    std::vector<std::string> input, output_list;
    std::istringstream iss(output);
    std::string line;
    enum { NONE, INPUT, OUTPUT } section = NONE;
    while (std::getline(iss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.find("Input:") != std::string::npos) { section = INPUT; continue; }
        if (line.find("Output:") != std::string::npos) { section = OUTPUT; continue; }
        if (line.empty() || line.find("---") != std::string::npos) continue;

        size_t start = line.find_first_not_of(" \t");
        if (start == std::string::npos) continue;
        std::string name = line.substr(start);
        if (section == INPUT) input.push_back(name);
        else if (section == OUTPUT) output_list.push_back(name);
    }
    // 合并并标记
    std::vector<std::string> result;
    for (auto& s : input) result.push_back(s + " [input]");
    for (auto& s : output_list) result.push_back(s + " [output]");
    return result;
}

// 解析 ffmpeg -hwaccels 输出
std::vector<std::string> parseHwAccels(const std::string& output) {
    std::vector<std::string> result;
    std::istringstream iss(output);
    std::string line;
    bool started = false;
    while (std::getline(iss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!started) {
            // 第一行 "Hardware acceleration methods:" 后开始
            if (line.find("Hardware") != std::string::npos) { started = true; }
            continue;
        }
        size_t start = line.find_first_not_of(" \t");
        if (start == std::string::npos) continue;
        std::string name = line.substr(start);
        if (!name.empty() && name[0] != '-') result.push_back(name);
    }
    return result;
}

} // namespace

json queryFFmpegFeatures() {
    json result;

    // 使用 -encoders / -decoders（比 -codecs 更清晰）
    auto enc_pr = Subprocess::run({getFFmpegPath(), "-encoders"}, 10);
    if (enc_pr.exit_code == 0) {
        result["encoders_video"] = parseCodecsByType(enc_pr.stdout_output, 'V', true);
        result["encoders_audio"] = parseCodecsByType(enc_pr.stdout_output, 'A', true);
    }

    auto dec_pr = Subprocess::run({getFFmpegPath(), "-decoders"}, 10);
    if (dec_pr.exit_code == 0) {
        result["decoders_video"] = parseCodecsByType(dec_pr.stdout_output, 'V', false);
        result["decoders_audio"] = parseCodecsByType(dec_pr.stdout_output, 'A', false);
    }

    // 格式（容器）
    auto fmt_pr = Subprocess::run({getFFmpegPath(), "-formats"}, 10);
    if (fmt_pr.exit_code == 0) {
        result["formats"] = parseFormats(fmt_pr.stdout_output);
    }

    // 滤镜
    auto flt_pr = Subprocess::run({getFFmpegPath(), "-filters"}, 10);
    if (flt_pr.exit_code == 0) {
        result["filters"] = parseFilters(flt_pr.stdout_output);
    }

    // 协议
    auto pro_pr = Subprocess::run({getFFmpegPath(), "-protocols"}, 10);
    if (pro_pr.exit_code == 0) {
        result["protocols"] = parseProtocols(pro_pr.stdout_output);
    }

    // 硬件加速
    auto hw_pr = Subprocess::run({getFFmpegPath(), "-hwaccels"}, 10);
    if (hw_pr.exit_code == 0) {
        result["hwaccels"] = parseHwAccels(hw_pr.stdout_output);
    }

    return result;
}

} // namespace ffmpegpp
