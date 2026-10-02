#pragma once
// ═══════════════════════════════════════════════════════════════
// FPPX v2 加密原语 —— 自写实现，不依赖任何外部密码学库。
//
// 提供：SHA-256 / HMAC-SHA256 / PBKDF2-HMAC-SHA256 /
//       AES-128-CBC / AES-256-CBC（含 PKCS#7 填充）/
//       常数时间比较 / 平台 CSPRNG。
//
// 正确性由 tests/fppx_test.cpp 用公开测试向量自校：
//   AES 分组      FIPS-197 附录 B/C
//   AES-CBC       NIST SP 800-38A F.2.1 / F.2.5
//   SHA-256       FIPS 180-4 示例
//   HMAC-SHA256   RFC 4231 Test Case 1-7
//   PBKDF2        RFC 6070 系列的 SHA-256 变体
// ═══════════════════════════════════════════════════════════════

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace ffmpegpp {
namespace fppx_crypto {

// ── SHA-256 ──

struct Sha256Ctx {
    Sha256Ctx();
    void update(const uint8_t* data, size_t len);
    void finish(uint8_t out[32]);

private:
    void transform(const uint8_t block[64]);
    uint32_t h_[8];
    uint8_t buf_[64];
    size_t bufLen_;
    uint64_t totalLen_;
};

void sha256(const uint8_t* data, size_t len, uint8_t out[32]);

// ── HMAC-SHA256 ──

void hmacSha256(const uint8_t* key, size_t keyLen, const uint8_t* msg, size_t msgLen,
                uint8_t out[32]);

// ── PBKDF2-HMAC-SHA256 ──
// 输出 outLen 字节，写入 out（outLen<=0 或 password 为空由调用方保证）。
std::vector<uint8_t> pbkdf2HmacSha256(const std::string& password, const uint8_t* salt,
                                      size_t saltLen, uint32_t iterations, size_t outLen);

// ── AES-CBC ──

enum class AesKeyBits {
    Aes128 = 128,
    Aes256 = 256,
};

// 明文按 PKCS#7 填充到 16 字节整数倍后加密。out 为密文。
bool aesCbcEncrypt(AesKeyBits bits, const uint8_t* key, const uint8_t* iv, const uint8_t* plain,
                   size_t plainLen, std::vector<uint8_t>& out);

// 解密并校验/剥离 PKCS#7 填充。填充非法（长度非 16 倍数、填充值越界）返回 false。
bool aesCbcDecrypt(AesKeyBits bits, const uint8_t* key, const uint8_t* iv, const uint8_t* cipher,
                   size_t cipherLen, std::vector<uint8_t>& out);

// ── 工具 ──

// 常数时间等长比较（长度不同直接 false，不泄露差异位置）
bool constantTimeEquals(const uint8_t* a, const uint8_t* b, size_t len);

// 平台密码学安全随机数：Windows BCryptGenRandom / 其它平台 /dev/urandom
bool randomBytes(uint8_t* out, size_t len);

// 32 字节随机十六进制串（仅用于调试/日志；密钥材料不得使用）
std::string randomHex32();

} // namespace fppx_crypto
} // namespace ffmpegpp
