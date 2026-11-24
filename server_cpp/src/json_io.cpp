#include "json_io.h"
#include "message_queues.h"

namespace ffmpegpp {

void JsonWriter::send(const json& obj) {
    std::string line = obj.dump(-1, ' ', false, json::error_handler_t::replace) + "\n";
    pushOutput(line);
}

void JsonWriter::reply(const std::string& id, bool success,
                       const json& data, const std::string& error) {
    json obj = {{"id", id}, {"success", success}};
    if (!data.is_null()) obj["data"] = data;
    if (!error.empty()) obj["error"] = error;
    send(obj);
}

void JsonWriter::progress(const std::string& task_id, const json& stats) {
    json obj = {{"type", "progress"}, {"task_id", task_id}};
    obj.update(stats);
    send(obj);
}

void JsonWriter::audit(const std::string& task_id, const std::vector<std::string>& warnings) {
    json obj = {{"type", "audit"}, {"task_id", task_id}, {"warnings", warnings}};
    send(obj);
}

} // namespace ffmpegpp
