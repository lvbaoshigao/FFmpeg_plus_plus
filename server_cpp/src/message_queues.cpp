#include "message_queues.h"

namespace ffmpegpp {

static std::queue<std::string> g_outputQueue;
static std::mutex g_outputMutex;

static std::queue<std::string> g_inputQueue;
static std::mutex g_inputMutex;
static std::condition_variable g_inputCv;
static bool g_inputWake = false;

void pushOutput(const std::string& line) {
    std::lock_guard<std::mutex> lock(g_outputMutex);
    g_outputQueue.push(line);
}

std::string popOutput() {
    std::lock_guard<std::mutex> lock(g_outputMutex);
    if (g_outputQueue.empty()) return "";
    std::string front = g_outputQueue.front();
    g_outputQueue.pop();
    return front;
}

void pushInput(const std::string& line) {
    {
        std::lock_guard<std::mutex> lock(g_inputMutex);
        g_inputQueue.push(line);
    }
    g_inputCv.notify_one();
}

std::string popInput(bool& shutdown) {
    std::unique_lock<std::mutex> lock(g_inputMutex);
    g_inputCv.wait(lock, [] {
        return !g_inputQueue.empty() || g_inputWake;
    });
    if (g_inputWake && g_inputQueue.empty()) {
        g_inputWake = false;  // 重置，防止 DLL 重新初始化后忙等
        shutdown = true;
        return "";
    }
    std::string front = g_inputQueue.front();
    g_inputQueue.pop();
    return front;
}

void wakeInput() {
    {
        std::lock_guard<std::mutex> lock(g_inputMutex);
        g_inputWake = true;
    }
    g_inputCv.notify_all();
}

} // namespace ffmpegpp
