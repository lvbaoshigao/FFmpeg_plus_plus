#include "json_io.h"
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
std::atomic<bool> JsonWriter::_running{false};
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
    std::string line = obj.dump() + "\n";
    pushOutput(line);
}

#else

// EXE 模式：通过写入线程写 stdout（原有逻辑）
void JsonWriter::start() {
#ifdef _WIN32
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    _running.store(true);
    _writerThread = std::thread([hOut]() {
        while (_running.load()) {
            std::string line;
            {
                std::unique_lock<std::mutex> lock(_mutex);
                _cv.wait_for(lock, std::chrono::milliseconds(100), []() {
                    return !_queue.empty() || !_running.load();
                });
                if (_queue.empty()) continue;
                line = _queue.front();
                _queue.pop();
            }
            if (hOut != INVALID_HANDLE_VALUE && hOut != nullptr) {
                DWORD written;
                WriteFile(hOut, line.c_str(), (DWORD)line.size(), &written, nullptr);
                FlushFileBuffers(hOut);
            }
        }
    });
#else
    _running.store(true);
    _writerThread = std::thread([]() {
        while (_running.load()) {
            std::string line;
            {
                std::unique_lock<std::mutex> lock(_mutex);
                _cv.wait_for(lock, std::chrono::milliseconds(100), []() {
                    return !_queue.empty() || !_running.load();
                });
                if (_queue.empty()) continue;
                line = _queue.front();
                _queue.pop();
            }
            const char* p = line.c_str();
            size_t remaining = line.size();
            while (remaining > 0) {
                ssize_t written = write(STDOUT_FILENO, p, remaining);
                if (written <= 0) break;
                p += written;
                remaining -= written;
            }
            fsync(STDOUT_FILENO);
        }
    });
#endif
}

void JsonWriter::stop() {
    _running.store(false);
    _cv.notify_all();
    if (_writerThread.joinable()) _writerThread.join();
}

void JsonWriter::send(const json& obj) {
    std::string line = obj.dump() + "\n";
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _queue.push(line);
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

#ifndef FFMPEGPP_DLL_MODE

// EXE 模式才需要 stdin 读取
bool JsonReader::readLine(json& out) {
    static std::string buffer;
    char ch;
#ifdef _WIN32
    HANDLE hIn = GetStdHandle(STD_INPUT_HANDLE);
    if (hIn == INVALID_HANDLE_VALUE || hIn == nullptr) return false;

    while (true) {
        DWORD read;
        if (!ReadFile(hIn, &ch, 1, &read, nullptr) || read == 0) {
            return false;
        }
        if (ch == '\n') {
            std::string line = buffer;
            buffer.clear();
            if (line.empty()) continue;
            if (!line.empty() && line.back() == '\r') line.pop_back();
            try {
                out = json::parse(line);
                return true;
            } catch (...) {
                continue;
            }
        }
        buffer += ch;
    }
#else
    while (true) {
        ssize_t n = read(STDIN_FILENO, &ch, 1);
        if (n <= 0) return false;
        if (ch == '\n') {
            std::string line = buffer;
            buffer.clear();
            if (line.empty()) continue;
            if (!line.empty() && line.back() == '\r') line.pop_back();
            try {
                out = json::parse(line);
                return true;
            } catch (...) {
                continue;
            }
        }
        buffer += ch;
    }
#endif
}

#endif // !FFMPEGPP_DLL_MODE

} // namespace ffmpegpp
