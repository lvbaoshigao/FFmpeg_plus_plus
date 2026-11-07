#include "json_io.h"
#include <algorithm>
#include <string>
#ifdef _WIN32
#include <windows.h>
#include <io.h>
#else
#include <unistd.h>
#endif

#ifdef FFMPEGPP_DLL_MODE
#include "message_queues.h"
#endif

namespace ffmpegpp {

std::queue<std::string> JsonWriter::_queue;
std::mutex JsonWriter::_mutex;
std::condition_variable JsonWriter::_cv;
std::condition_variable JsonWriter::_spaceAvailable;
std::atomic<bool> JsonWriter::_running{false};
std::size_t JsonWriter::_activeSenders = 0;
std::thread JsonWriter::_writerThread;

#ifdef FFMPEGPP_DLL_MODE

// DLL 模式：直接推入内存队列，无需写入线程
void JsonWriter::start() {
    _running.store(true);
}

void JsonWriter::stop() {
    _running.store(false);
}

void JsonWriter::send(const json& obj) {
    std::string line = obj.dump(-1, ' ', false, json::error_handler_t::replace) + "\n";
    pushOutput(line);
}

#else

// Bound queued lines while allowing the writer to finish its current blocking write.
static constexpr std::size_t kMaxQueuedLines = 256;

// EXE 模式：通过写入线程写 stdout。
void JsonWriter::start() {
#ifdef _WIN32
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    _running.store(true);
    _writerThread = std::thread([hOut]() {
        while (true) {
            std::string line;
            {
                std::unique_lock<std::mutex> lock(_mutex);
                _cv.wait(lock, []() {
                    return !_queue.empty() || (!_running.load() && _activeSenders == 0);
                });
                if (_queue.empty()) break;
                line = _queue.front();
                _queue.pop();
            }
            _spaceAvailable.notify_one();
            if (hOut != INVALID_HANDLE_VALUE && hOut != nullptr) {
                size_t offset = 0;
                while (offset < line.size()) {
                    const DWORD chunk = static_cast<DWORD>(
                        std::min<size_t>(line.size() - offset, MAXDWORD));
                    DWORD written = 0;
                    if (!WriteFile(hOut, line.data() + offset, chunk, &written, nullptr) ||
                        written == 0) {
                        break;
                    }
                    offset += written;
                }
                // 注意：不要 FlushFileBuffers —— 对管道/控制台是无操作（或拖慢性能），
                // 数据量小时系统自会刷出，FlushFileBuffers 只对磁盘文件有意义。
            }
        }
    });
#else
    _running.store(true);
    _writerThread = std::thread([]() {
        while (true) {
            std::string line;
            {
                std::unique_lock<std::mutex> lock(_mutex);
                _cv.wait(lock, []() {
                    return !_queue.empty() || (!_running.load() && _activeSenders == 0);
                });
                if (_queue.empty()) break;
                line = _queue.front();
                _queue.pop();
            }
            _spaceAvailable.notify_one();
            const char* p = line.c_str();
            size_t remaining = line.size();
            while (remaining > 0) {
                ssize_t written = write(STDOUT_FILENO, p, remaining);
                if (written <= 0) break;
                p += written;
                remaining -= written;
            }
            // 注意：不要 fsync —— 对管道返回 EINVAL 且无意义，纯属浪费系统调用。
        }
    });
#endif
}

void JsonWriter::stop() {
    _running.store(false);
    _cv.notify_all();
    _spaceAvailable.notify_all();
    if (_writerThread.joinable()) _writerThread.join();
}

void JsonWriter::send(const json& obj) {
    std::string line = obj.dump(-1, ' ', false, json::error_handler_t::replace) + "\n";
    {
        std::unique_lock<std::mutex> lock(_mutex);
        ++_activeSenders;
        _spaceAvailable.wait(lock, []() { return _queue.size() < kMaxQueuedLines; });
        try {
            _queue.push(std::move(line));
        } catch (...) {
            --_activeSenders;
            lock.unlock();
            _cv.notify_all();
            throw;
        }
        --_activeSenders;
    }
    _cv.notify_one();
}

#endif // FFMPEGPP_DLL_MODE

// 以下方法两种模式共用（都调用 send）
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
