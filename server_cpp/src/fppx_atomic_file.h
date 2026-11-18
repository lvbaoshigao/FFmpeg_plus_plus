#pragma once

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <mutex>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

#include "fppx_crypto.h"

namespace ffmpegpp::fppx_detail {

// Shared by legacy and v2: serialize publication even for differently spelled paths.
inline std::mutex& exportPublicationMutex() {
    static std::mutex mutex;
    return mutex;
}

// Owns only an exclusively created sibling file, never the destination.
class PendingExport {
public:
    explicit PendingExport(const std::filesystem::path& target) : target_(std::filesystem::absolute(target)) {}
    PendingExport(const PendingExport&) = delete;
    PendingExport& operator=(const PendingExport&) = delete;
    ~PendingExport() {
        closeFile();
        if (owned_) {
            std::error_code ignored;
            std::filesystem::remove(temp_, ignored);
        }
    }

    std::string path() const { return temp_.u8string(); }

    bool write(const std::vector<uint8_t>& data, std::string& err) {
        // Random names avoid collisions; exclusive creation establishes ownership.
        for (int attempt = 0; attempt < 32; ++attempt) {
            uint8_t random[16];
            if (!fppx_crypto::randomBytes(random, sizeof(random))) {
                err = "无法生成导出临时文件名，原文件未更改";
                return false;
            }
            std::string name = ".fppx-export-";
            constexpr char hex[] = "0123456789abcdef";
            for (uint8_t byte : random) {
                name += hex[byte >> 4];
                name += hex[byte & 15];
            }
            temp_ = target_.parent_path() / (name + ".tmp");
#ifdef _WIN32
            handle_ = CreateFileW(temp_.c_str(), GENERIC_WRITE, 0, nullptr,
                                  CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (handle_ == INVALID_HANDLE_VALUE) {
                const DWORD code = GetLastError();
                if (code == ERROR_FILE_EXISTS || code == ERROR_ALREADY_EXISTS) continue;
                err = "无法创建导出临时文件，原文件未更改";
                return false;
            }
#else
            handle_ = ::open(temp_.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
            if (handle_ < 0) {
                if (errno == EEXIST) continue;
                err = "无法创建导出临时文件，原文件未更改";
                return false;
            }
#endif
            owned_ = true;
            break;
        }
        if (!owned_) {
            err = "导出临时文件名冲突，原文件未更改";
            return false;
        }
        size_t offset = 0;
        while (offset < data.size()) {
            const size_t chunk = (std::min)(data.size() - offset, size_t(1 << 20));
#ifdef _WIN32
            DWORD written = 0;
            if (!WriteFile(handle_, data.data() + offset, static_cast<DWORD>(chunk),
                           &written, nullptr) || written == 0) {
#else
            const ssize_t written = ::write(handle_, data.data() + offset, chunk);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
#endif
                err = "导出临时文件写入失败，原文件未更改";
                return false;
            }
            offset += static_cast<size_t>(written);
        }
#ifdef _WIN32
        const bool flushed = FlushFileBuffers(handle_) != 0;
#else
        int syncResult;
        do { syncResult = ::fsync(handle_); } while (syncResult < 0 && errno == EINTR);
        const bool flushed = syncResult == 0;
#endif
        const bool closed = closeFile();
        if (!flushed || !closed) {
            err = "导出临时文件刷新或关闭失败，原文件未更改";
            return false;
        }
        return true;
    }

    bool commit(std::string& err) {
        // No remove(destination) fallback: failure must leave the old file intact.
        // A single same-directory rename also prevents cross-process partial files.
#ifdef _WIN32
        const bool replaced = MoveFileExW(temp_.c_str(), target_.c_str(),
                                          MOVEFILE_REPLACE_EXISTING) != 0;
#else
        const bool replaced = ::rename(temp_.c_str(), target_.c_str()) == 0;
#endif
        if (!replaced) {
            err = "无法替换导出目标（路径不可用或被占用），原文件未更改";
            return false;
        }
        owned_ = false;
        return true;
    }

private:
    bool closeFile() {
#ifdef _WIN32
        if (handle_ == INVALID_HANDLE_VALUE) return true;
        const HANDLE handle = handle_;
        handle_ = INVALID_HANDLE_VALUE;
        return CloseHandle(handle) != 0;
#else
        if (handle_ < 0) return true;
        const int handle = handle_;
        handle_ = -1;
        // Do not retry close(EINTR): the descriptor may already have been reused.
        return ::close(handle) == 0;
#endif
    }
    std::filesystem::path target_;
    std::filesystem::path temp_;
    bool owned_ = false;
#ifdef _WIN32
    HANDLE handle_ = INVALID_HANDLE_VALUE;
#else
    int handle_ = -1;
#endif
};


} // namespace ffmpegpp::fppx_detail
