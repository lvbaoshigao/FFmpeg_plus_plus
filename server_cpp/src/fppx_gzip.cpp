#include "fppx_gzip.h"

#include <cstdio>

#include "miniz/miniz_tdef.h"
#include "miniz/miniz_tinfl.h"

namespace ffmpegpp {

namespace {

// CRC32（IEEE 802.3，gzip 与 FPPX v2 的完整性校验共用同一种）
uint32_t crc32Bytes(const uint8_t* data, size_t len) {
    static uint32_t table[256];
    static bool inited = false;
    if (!inited) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k)
                c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            table[i] = c;
        }
        inited = true;
    }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; ++i)
        crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

} // namespace

uint32_t fppxCrc32(const uint8_t* data, size_t len) { return crc32Bytes(data, len); }

std::vector<uint8_t> gzipCompress(const uint8_t* data, size_t len) {
    // gzip 头：magic + deflate + 无 flags + mtime 0 + XFL 0 + OS=Unix(3)
    std::vector<uint8_t> out{0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03};

    // 原始 deflate 流（未设 TDEFL_WRITE_ZLIB_HEADER → raw）
    size_t defLen = 0;
    int flags = tdefl_create_comp_flags_from_zip_params(6 /*level*/, -15 /*raw*/, 0);
    void* def = tdefl_compress_mem_to_heap(data, len, &defLen, flags);
    if (!def) return {};
    const uint8_t* d = static_cast<const uint8_t*>(def);
    out.insert(out.end(), d, d + defLen);
    free(def);

    // gzip 尾：CRC32 + ISIZE（均小端）
    uint32_t crc = crc32Bytes(data, len);
    uint32_t isize = static_cast<uint32_t>(len & 0xFFFFFFFFu);
    for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>((crc >> (8 * i)) & 0xFF));
    for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>((isize >> (8 * i)) & 0xFF));
    return out;
}

bool gzipDecompress(const uint8_t* data, size_t len, std::vector<uint8_t>& out,
                    std::string& error) {
    if (len < 18 || data[0] != 0x1F || data[1] != 0x8B) {
        error = "不是有效的 gzip 数据";
        return false;
    }
    if (data[2] != 0x08) {
        error = "不支持的 gzip 压缩方法";
        return false;
    }
    uint8_t flg = data[3];
    size_t pos = 10; // 固定头 10 字节
    // FEXTRA(2B 长度+数据) / FNAME(0 结尾) / FCOMMENT(0 结尾) / FHCRC(2B)
    if (flg & 0x04) {
        if (pos + 2 > len) { error = "gzip 头不完整"; return false; }
        uint16_t xlen = static_cast<uint16_t>(data[pos] | (data[pos + 1] << 8));
        pos += 2 + xlen;
    }
    if (flg & 0x08) {
        while (pos < len && data[pos] != 0) ++pos;
        ++pos;
    }
    if (flg & 0x16) { // FCOMMENT (0x10) 与 FHCRC (0x02)
        if (flg & 0x10) {
            while (pos < len && data[pos] != 0) ++pos;
            ++pos;
        }
        if (flg & 0x02) pos += 2;
    }
    if (pos + 8 > len) { error = "gzip 头不完整"; return false; }

    // ISIZE 来自尾部（Dart gzip.encode 与常规工具都在最后 4 字节）
    uint32_t isize = 0;
    for (int i = 0; i < 4; ++i)
        isize |= static_cast<uint32_t>(data[len - 4 + i]) << (8 * i);
    if (isize > (512u << 20)) {
        error = "解压后数据过大";
        return false;
    }
    out.resize(isize);

    size_t consumed = tinfl_decompress_mem_to_mem(
        out.data(), out.size(), data + pos, len - pos - 8, 0 /* raw deflate */);
    if (consumed == TINFL_DECOMPRESS_MEM_TO_MEM_FAILED) {
        error = "gzip 数据损坏，解压失败";
        return false;
    }
    // 原始 deflate 流长度自校验：inflate 应恰好消费到 gzip 尾部
    // （tinfl 在流结束后可能不精确报告消费量，这里只做 CRC 终检）
    uint32_t crc = 0;
    for (int i = 0; i < 4; ++i)
        crc |= static_cast<uint32_t>(data[len - 8 + i]) << (8 * i);
    if (crc32Bytes(out.data(), out.size()) != crc) {
        error = "gzip CRC 校验失败，数据损坏";
        return false;
    }
    return true;
}

} // namespace ffmpegpp
