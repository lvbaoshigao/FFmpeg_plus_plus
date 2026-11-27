#pragma once

#include <functional>
#include "nlohmann/json.hpp"

namespace ffmpegpp {
// These run on a backend auxiliary thread. invokePlugin throws std::exception
// on validation/trap/timeout failures; the existing dispatcher serializes errors.
nlohmann::json pluginCapabilities();
nlohmann::json configurePluginRoot(const nlohmann::json& params);
void clearPluginRoot();
nlohmann::json invokePlugin(const nlohmann::json& params,
                            const std::function<bool()>& isCancelled = {});
} // namespace ffmpegpp
