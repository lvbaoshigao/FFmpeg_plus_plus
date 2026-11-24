#pragma once
#include <string>
#include <vector>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// JSON protocol messages are delivered through the C++ -> Dart memory queue.
class JsonWriter {
public:
    static void send(const json& obj);
    static void reply(const std::string& id, bool success,
                      const json& data = nullptr, const std::string& error = "");
    static void progress(const std::string& task_id, const json& stats);
    static void audit(const std::string& task_id, const std::vector<std::string>& warnings);
};

} // namespace ffmpegpp
