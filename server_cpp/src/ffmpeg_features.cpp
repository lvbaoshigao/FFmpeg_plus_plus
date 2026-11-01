#include "ffmpeg_features.h"
#include "subprocess.h"
#include "installer.h"
#include <sstream>
#include <mutex>

namespace ffmpegpp {

namespace {

// 解析 ffmpeg -encoders / -decoders 输出，按类型分类
// 格式: D/E A/V/S. ...  codec_name  description
std::vector<std::string> parseCodecsByType(const std::string& output, char mediaType) {
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
        // 真实输出形如 " V....D a64multi   Multicolor charset…"：
        //   第 0 列是空格，第 1 列是媒体类型（V/A/S），第 2~6 列是标志位
        //   （.F.... 帧级多线程 / .....D 直接渲染 等），下标 7 起是名字。
        // 旧实现把 line[1] 当成 D/E 列、line[2] 当成媒体类型，而 -encoders /
        // -decoders 输出里根本没有 D/E 列，于是 media 恒为 '.'，整张表被
        // continue 掉 —— encoders_*/decoders_* 永远是空数组。
        // 编解码器本来就分别由 -encoders / -decoders 取，无需再按列区分。
        if (line.empty() || line.size() < 8) continue;
        if (line.find('=') != std::string::npos) continue;  // 图例行 " V..... = Video"
        if (mediaType != 0 && line[1] != mediaType) continue;

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
            // 真实输出的分隔行是 " ---"（3 个横线），旧实现找 "------"（6 个），
            // 于是 started 永远为 false，formats 恒为空数组。
            if (line.find("---") != std::string::npos) started = true;
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
        // 真实输出形如 " TSC aap               AA->A      Apply Affine …"：
        // 第 1~3 列是标志位（T/S/C 或 '.'），第 5 列起是滤镜名，再后面是
        // "输入->输出" 列。
        // 旧实现「跳过 3 段空格」会落到第 4 列，也就是 "AA->A" 这个签名列，
        // 于是 filters 里全是 V->V / AA->A，连 scale 都没有。
        // 现在的规则：按空白切成 token，"X->Y" 签名前面那个 token 才是滤镜名
        // （标志位 "TSC"/"..." 也在签名前面，所以不能简单取第一个 token）。
        // 这样图例行（"T.. = Timeline support"）与分隔行会被自动跳过。
        std::istringstream tss(line);
        std::string t0, t1, t2;
        if (!(tss >> t0)) continue;
        if (!(tss >> t1)) continue;
        if (!(tss >> t2)) continue;
        std::string name;
        if (t2.find("->") != std::string::npos) {
            name = t1;                       // 有标志位列：flags name X->Y
        } else if (t1.find("->") != std::string::npos) {
            name = t0;                       // 无标志位列
        } else {
            continue;                        // 图例行/分隔行
        }
        if (name.empty() || name.find_first_not_of('-') == std::string::npos) continue;
        result.push_back(name);
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
    // 结果缓存：6 个子进程查询开销大，且同一 ffmpeg 版本下结果不变。
    // setFFmpegPaths 更换了二进制后，调用方重启进程即可（或后续按版本号失效）。
    static std::mutex cacheMutex;
    static json cached;
    static bool cachedReady = false;
    {
        std::lock_guard<std::mutex> lock(cacheMutex);
        if (cachedReady) return cached;
    }

    json result;

    // 使用 -encoders / -decoders（比 -codecs 更清晰）
    auto enc_pr = Subprocess::run({getFFmpegPath(), "-encoders"}, 10);
    if (enc_pr.exit_code == 0) {
        result["encoders_video"] = parseCodecsByType(enc_pr.stdout_output, 'V');
        result["encoders_audio"] = parseCodecsByType(enc_pr.stdout_output, 'A');
    }

    auto dec_pr = Subprocess::run({getFFmpegPath(), "-decoders"}, 10);
    if (dec_pr.exit_code == 0) {
        result["decoders_video"] = parseCodecsByType(dec_pr.stdout_output, 'V');
        result["decoders_audio"] = parseCodecsByType(dec_pr.stdout_output, 'A');
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

    {
        std::lock_guard<std::mutex> lock(cacheMutex);
        cached = result;
        cachedReady = true;
    }
    return result;
}

} // namespace ffmpegpp
