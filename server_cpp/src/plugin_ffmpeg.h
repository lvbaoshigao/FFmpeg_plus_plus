#pragma once

#include <string>
#include <vector>
#include "handlers.h"

namespace ffmpegpp {

// A bounded, one-local-input / one-local-output FFmpeg plan. The executable,
// paths and process controls are always supplied by the host, never the guest.
json pluginFFmpegCapabilities();
std::vector<std::string> buildPluginFFmpegCommand(
    const std::string& input, const std::string& output, const json& arguments,
    const std::string& inputType, const std::string& outputType);
void handlePluginFFmpeg(const json& req, const CancelCheck& isCancelled);

} // namespace ffmpegpp
