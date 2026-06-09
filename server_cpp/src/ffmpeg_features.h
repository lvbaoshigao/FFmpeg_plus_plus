#pragma once
#include <string>
#include <vector>
#include <map>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 查询 ffmpeg 支持的功能
json queryFFmpegFeatures();

} // namespace ffmpegpp
