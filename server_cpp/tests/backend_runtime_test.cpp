#include "ffmpegpp_exports.h"
#include "subprocess.h"
#include "message_queues.h"
#include "nlohmann/json.hpp"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <thread>
#include <vector>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

using namespace ffmpegpp;
using Clock = std::chrono::steady_clock;
static void require(bool ok, const char* message) {
    if (!ok) { std::cerr << message << '\n'; std::exit(1); }
}
static std::vector<nlohmann::json> pollAll() {
    std::vector<nlohmann::json> messages;
    while (char* p = ffmpegpp_poll()) {
        std::string text(p);
        ffmpegpp_free(p);
        messages.push_back(nlohmann::json::parse(text));
    }
    return messages;
}
int main() {
#ifdef __linux__
    // Reap test grandchildren explicitly; no background processes escape tests.
    prctl(PR_SET_CHILD_SUBREAPER, 1);
#endif
    auto start = Clock::now();
    auto r = Subprocess::runWithProgress({"/bin/sh", "-c", "sleep 10 & echo $!; printf 'first\\rsecond\\nlast' >&2"},
        [](const std::string&) {}, [] { return false; });
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
    require(r.exit_code == 0, "descendant parent exit status lost");
    require(elapsed < 1500, "progress join blocked on descendant pipe");
    int descendant = std::stoi(r.stdout_output);
    kill(descendant, SIGKILL);
    waitpid(descendant, nullptr, 0);
    std::cout << "descendant-held pipe returned in " << elapsed << " ms\n";

    std::vector<std::string> lines;
    r = Subprocess::runWithProgress({"/bin/sh", "-c", "printf 'abc'; printf 'first\\rsecond\\nlast' >&2"},
        [&](const std::string& line) { lines.push_back(line); }, [] { return false; });
    require(r.exit_code == 0 && r.stdout_output == "abc", "tail stdout lost");
    require(lines == std::vector<std::string>({"first", "second", "last"}), "stderr CR/LF or final line lost");
    r = Subprocess::runWithProgress({"/bin/sh", "-c", "printf final >&2"},
        [](const std::string&) { throw 1; }, [] { return false; });
    require(r.exit_code == 0, "callback exception escaped final flush");

    for (const char* stream : {"stdout", "stderr"}) {
        std::string script = "head -c 20000000 /dev/zero";
        if (std::string(stream) == "stderr") script += " >&2";
        size_t longest = 0;
        r = Subprocess::runWithProgress({"/bin/sh", "-c", script},
            [&](const std::string& line) { longest = std::max(longest, line.size()); }, [] { return false; });
        require(r.output_truncated && r.exit_code != 0, "oversize output accepted");
        require(r.stdout_output.size() <= kMaxOutputBytes && longest <= kMaxOutputBytes, "output memory cap exceeded");
        std::cout << stream << " capped at " << std::max(longest, r.stdout_output.size()) << " bytes\n";
    }
    start = Clock::now();
    r = Subprocess::runWithProgress({"/bin/sh", "-c", "exec sleep 10"}, {},
        [&] { return Clock::now() - start > std::chrono::milliseconds(100); });
    require(r.exit_code == -1 && Clock::now() - start < std::chrono::seconds(1), "cancel did not terminate promptly");

    require(ffmpegpp_init() == 0, "FFI init failed");
    pollAll();
    for (const char* invalid : {"[]", "{\"action\":5}", "{\"action\":\"probe\",\"id\":7}"})
        require(ffmpegpp_request(invalid) == -1, "invalid request shape accepted");
    require(ffmpegpp_request("{\"id\":\"ping\",\"action\":\"ping\"}") == 0, "ping failed");
    auto messages = pollAll();
    require(messages.back()["data"]["pong"] == true, "ping protocol changed");
    // Old output and queued requests must not cross a shutdown/init boundary.
    ffmpegpp_request("{\"id\":\"old\",\"action\":\"ping\"}");
    ffmpegpp_request("{\"action\":\"shutdown\"}");
    require(ffmpegpp_request("{\"action\":\"ping\"}") == -1, "request accepted after shutdown signal");
    std::thread a(ffmpegpp_shutdown), b(ffmpegpp_shutdown);
    a.join(); b.join();
    pushInput("{\"id\":\"stale\",\"action\":\"unknown\"}");
    ffmpegpp_init();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    messages = pollAll();
    require(messages.size() == 1 && messages[0]["type"] == "ready", "stale queue survived FFI restart");
    for (int i = 0; i < 25; ++i) {
        ffmpegpp_request("{\"id\":\"aux\",\"action\":\"fppx2_import\"}");
        std::thread request([] { ffmpegpp_request("{\"action\":\"ping\"}"); });
        std::thread stop1(ffmpegpp_shutdown), stop2(ffmpegpp_shutdown);
        request.join(); stop1.join(); stop2.join();
        ffmpegpp_init();
    }
    ffmpegpp_shutdown();
    std::cout << "FFI lifecycle, protocol, and malformed requests passed\n";
}
