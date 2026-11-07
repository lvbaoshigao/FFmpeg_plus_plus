#include "audit.h"
#include "constants.h"
#ifdef __cpp_lib_filesystem
#include <filesystem>
#endif

namespace ffmpegpp {

std::vector<std::string> auditCommand(const std::vector<std::string>& cmd) {
    std::vector<std::string> warnings;

    bool has_hwaccel = false, has_hwaccel_fmt = false, has_scale = false, has_nvenc = false;
    for (auto& a : cmd) {
        if (a == "-hwaccel") has_hwaccel = true;
        if (a == "-hwaccel_output_format") has_hwaccel_fmt = true;
        if (a == "-s" || a == "-vf" || a == "-filter_complex") has_scale = true;
        if (a.find("nvenc") != std::string::npos) has_nvenc = true;
    }

    if (has_hwaccel && has_hwaccel_fmt && has_scale) {
        warnings.push_back("CONFLICT: -hwaccel + -hwaccel_output_format keeps frames in GPU memory, "
                           "but -s/-vf filters require CPU memory. This will cause 'Impossible to convert' error.");
    }
    if (has_hwaccel && has_scale) {
        warnings.push_back("WARNING: -hwaccel with CPU scaling may cause format conversion errors.");
    }

    // 输入=输出检查
    std::vector<std::string> input_files;
    std::string output_file;
    for (size_t i = 0; i < cmd.size(); ++i) {
        if (cmd[i] == "-i" && i + 1 < cmd.size()) {
            std::string input = cmd[i + 1];
            // 跳过空路径和明显无效的路径
            if (!input.empty() && input[0] != '-') {
                input_files.push_back(input);
            }
        }
    }
    // 输出文件 = 命令中最后一个非 '-' 开头的 token（ffmpeg 以输出路径结尾）。
    // 注意：不能用 "find(\"ffmpeg\")" 排除可执行名——那会把路径里含 "ffmpeg" 字样的
    // 输出文件误跳过；可执行名只会出现在命令最前面，从后往前找不受影响。
    for (int i = (int)cmd.size() - 1; i >= 0; --i) {
        if (cmd[i].empty()) continue;
        if (cmd[i][0] != '-') {
            output_file = cmd[i];
            break;
        }
    }
    
    // 只有当输入和输出都非空时才进行比较
    if (!output_file.empty() && !input_files.empty()) {
        // 基本检查：先做字符串比较（快速排除）
        for (auto& f : input_files) {
            if (f == output_file) {
                warnings.push_back("ERROR: Output file is the same as input file. This would overwrite the source.");
                break;
            }
        }
        
        // 深度检查：尝试规范化路径后比较（处理符号链接和相对路径）
        // 注意：规范化可能失败（如路径不存在），此时跳过深度检查
#ifdef __cpp_lib_filesystem
        try {
            std::filesystem::path outPath = std::filesystem::canonical(output_file);
            for (auto& f : input_files) {
                try {
                    std::filesystem::path inPath = std::filesystem::canonical(f);
                    if (outPath == inPath) {
                        warnings.push_back("ERROR: Output file resolves to the same path as input file (after symlink resolution). This would overwrite the source.");
                        break;
                    }
                } catch (...) {
                    // 输入路径无法规范化，跳过
                }
            }
        } catch (...) {
            // 输出路径无法规范化，跳过深度检查
        }
#endif
    }

    if (has_nvenc && has_hwaccel_fmt) {
        warnings.push_back("INFO: hwaccel_output_format may cause issues with nvenc on some driver versions.");
    }

    return warnings;
}

} // namespace ffmpegpp
