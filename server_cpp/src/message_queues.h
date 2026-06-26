#pragma once
#include <string>
#include <queue>
#include <mutex>
#include <condition_variable>

namespace ffmpegpp {

// C++ → Dart 输出队列
void pushOutput(const std::string& line);
std::string popOutput(); // 非阻塞，空时返回 ""

// Dart → C++ 输入队列
void pushInput(const std::string& line);
std::string popInput(bool& shutdown); // 阻塞等待，shutdown 信号时返回 ""
void wakeInput(); // 唤醒阻塞中的 popInput

} // namespace ffmpegpp
