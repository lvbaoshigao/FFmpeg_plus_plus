#pragma once
// gzip 封装（RFC1952）—— 旧版 FPPX 载荷是 gzip(JSON)，基于 vendored miniz 的
// 原始 deflate/inflate（不带 zlib 头），gzip 头/尾（CRC32、ISIZE）自行拼装。
// 压缩输出与 Dart 端 gzip.encode 互相可读（测试用 Python zlib 交叉验证）。

#include <cstdint>
#include <string>
#include <vector>

namespace ffmpegpp {

// 压缩为完整 gzip 流（含头尾）。失败返回空 vector。
std::vector<uint8_t> gzipCompress(const uint8_t* data, size_t len);

// 解压完整 gzip 流。失败时返回 false 并填充 error。
bool gzipDecompress(const uint8_t* data, size_t len, std::vector<uint8_t>& out,
                    std::string& error);

// IEEE CRC32（gzip 尾部与 FPPX v2 的 CRC32 模块共用同一实现）
uint32_t fppxCrc32(const uint8_t* data, size_t len);

} // namespace ffmpegpp
