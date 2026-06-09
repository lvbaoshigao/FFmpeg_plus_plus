#include "audit.h"
#include <algorithm>

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
        if (cmd[i] == "-i" && i + 1 < cmd.size()) input_files.push_back(cmd[i + 1]);
    }
    for (int i = (int)cmd.size() - 1; i >= 0; --i) {
        if (cmd[i][0] != '-' && cmd[i] != "ffmpeg") {
            output_file = cmd[i];
            break;
        }
    }
    if (!output_file.empty()) {
        for (auto& f : input_files) {
            if (f == output_file) {
                warnings.push_back("ERROR: Output file is the same as input file. This would overwrite the source.");
            }
        }
    }

    if (has_nvenc && has_hwaccel_fmt) {
        warnings.push_back("INFO: hwaccel_output_format may cause issues with nvenc on some driver versions.");
    }

    return warnings;
}

} // namespace ffmpegpp
