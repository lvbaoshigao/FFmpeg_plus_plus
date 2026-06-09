#pragma once
#include <string>
#include <mutex>
#include <queue>
#include <thread>
#include <atomic>
#include <condition_variable>
#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 异步 stdout JSON 输出（队列 + 写入线程，永不阻塞调用者）
class JsonWriter {
public:
    static void start();   // 启动写入线程（main 最早调用）
    static void stop();    // 停止写入线程
    static void send(const json& obj);
    static void reply(const std::string& id, bool success,
                      const json& data = nullptr, const std::string& error = "");
    static void progress(const std::string& task_id, const json& stats);
    static void audit(const std::string& task_id, const std::vector<std::string>& warnings);

private:
    static std::queue<std::string> _queue;
    static std::mutex _mutex;
    static std::condition_variable _cv;
    static std::atomic<bool> _running;
    static std::thread _writerThread;
};

// stdin JSON 行读取
class JsonReader {
public:
    static bool readLine(json& out);
};

} // namespace ffmpegpp
