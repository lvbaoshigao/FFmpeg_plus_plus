#include "fppx_crypto.h"

#include <cstdio>
#include <cstring>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <bcrypt.h>
#else
#include <cstdio>
#endif

namespace ffmpegpp {
namespace fppx_crypto {

// ═══════════════════════════════════════════════
// SHA-256（FIPS 180-4）
// ═══════════════════════════════════════════════

namespace {

const uint32_t kSha256K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u,
    0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu,
    0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu,
    0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
    0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u,
    0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u,
    0xc67178f2u};

inline uint32_t rotr32(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

} // namespace

Sha256Ctx::Sha256Ctx() : bufLen_(0), totalLen_(0) {
    h_[0] = 0x6a09e667u;
    h_[1] = 0xbb67ae85u;
    h_[2] = 0x3c6ef372u;
    h_[3] = 0xa54ff53au;
    h_[4] = 0x510e527fu;
    h_[5] = 0x9b05688cu;
    h_[6] = 0x1f83d9abu;
    h_[7] = 0x5be0cd19u;
    std::memset(buf_, 0, sizeof(buf_));
}

void Sha256Ctx::transform(const uint8_t block[64]) {
    uint32_t w[64];
    for (int i = 0; i < 16; ++i) {
        w[i] = (static_cast<uint32_t>(block[i * 4]) << 24) |
               (static_cast<uint32_t>(block[i * 4 + 1]) << 16) |
               (static_cast<uint32_t>(block[i * 4 + 2]) << 8) |
               static_cast<uint32_t>(block[i * 4 + 3]);
    }
    for (int i = 16; i < 64; ++i) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3];
    uint32_t e = h_[4], f = h_[5], g = h_[6], h = h_[7];

    for (int i = 0; i < 64; ++i) {
        uint32_t S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + S1 + ch + kSha256K[i] + w[i];
        uint32_t S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    h_[0] += a;
    h_[1] += b;
    h_[2] += c;
    h_[3] += d;
    h_[4] += e;
    h_[5] += f;
    h_[6] += g;
    h_[7] += h;
}

void Sha256Ctx::update(const uint8_t* data, size_t len) {
    totalLen_ += len;
    size_t i = 0;
    if (bufLen_ > 0) {
        while (i < len && bufLen_ < 64) buf_[bufLen_++] = data[i++];
        if (bufLen_ == 64) {
            transform(buf_);
            bufLen_ = 0;
        }
    }
    while (i + 64 <= len) {
        transform(data + i);
        i += 64;
    }
    while (i < len) buf_[bufLen_++] = data[i++];
}

void Sha256Ctx::finish(uint8_t out[32]) {
    uint64_t bitLen = totalLen_ * 8ull;
    uint8_t pad = 0x80;
    update(&pad, 1);
    uint8_t zero = 0x00;
    while (bufLen_ != 56) update(&zero, 1);
    uint8_t lenBytes[8];
    for (int i = 0; i < 8; ++i) lenBytes[i] = static_cast<uint8_t>((bitLen >> (56 - 8 * i)) & 0xFF);
    // 直接写入长度（不再经过 update，避免 totalLen_ 继续累加影响后续）
    for (int i = 0; i < 8; ++i) buf_[bufLen_++] = lenBytes[i];
    transform(buf_);
    bufLen_ = 0;
    for (int i = 0; i < 8; ++i) {
        out[i * 4] = static_cast<uint8_t>((h_[i] >> 24) & 0xFF);
        out[i * 4 + 1] = static_cast<uint8_t>((h_[i] >> 16) & 0xFF);
        out[i * 4 + 2] = static_cast<uint8_t>((h_[i] >> 8) & 0xFF);
        out[i * 4 + 3] = static_cast<uint8_t>(h_[i] & 0xFF);
    }
}

void sha256(const uint8_t* data, size_t len, uint8_t out[32]) {
    Sha256Ctx ctx;
    ctx.update(data, len);
    ctx.finish(out);
}

// ═══════════════════════════════════════════════
// HMAC-SHA256（RFC 2104）
// ═══════════════════════════════════════════════

namespace {
constexpr size_t kSha256Block = 64;
}

void hmacSha256(const uint8_t* key, size_t keyLen, const uint8_t* msg, size_t msgLen,
                uint8_t out[32]) {
    uint8_t k0[kSha256Block];
    std::memset(k0, 0, sizeof(k0));
    if (keyLen > kSha256Block) {
        sha256(key, keyLen, k0); // 长密钥先哈希，其余补 0
    } else {
        std::memcpy(k0, key, keyLen);
    }

    uint8_t ipad[kSha256Block], opad[kSha256Block];
    for (size_t i = 0; i < kSha256Block; ++i) {
        ipad[i] = k0[i] ^ 0x36;
        opad[i] = k0[i] ^ 0x5c;
    }

    uint8_t inner[32];
    Sha256Ctx c1;
    c1.update(ipad, kSha256Block);
    c1.update(msg, msgLen);
    c1.finish(inner);

    Sha256Ctx c2;
    c2.update(opad, kSha256Block);
    c2.update(inner, 32);
    c2.finish(out);

    // 清零中间状态
    std::memset(k0, 0, sizeof(k0));
    std::memset(ipad, 0, sizeof(ipad));
    std::memset(opad, 0, sizeof(opad));
    std::memset(inner, 0, sizeof(inner));
}

// ═══════════════════════════════════════════════
// PBKDF2-HMAC-SHA256（RFC 8018）
// ═══════════════════════════════════════════════

std::vector<uint8_t> pbkdf2HmacSha256(const std::string& password, const uint8_t* salt,
                                      size_t saltLen, uint32_t iterations, size_t outLen) {
    std::vector<uint8_t> out;
    if (outLen == 0 || iterations == 0) return out;
    out.resize(outLen);

    const uint8_t* pw = reinterpret_cast<const uint8_t*>(password.data());
    size_t pwLen = password.size();

    constexpr size_t hLen = 32;
    uint32_t blocks = static_cast<uint32_t>((outLen + hLen - 1) / hLen);

    std::vector<uint8_t> saltBlock(saltLen + 4);
    if (saltLen > 0) std::memcpy(saltBlock.data(), salt, saltLen);

    for (uint32_t i = 1; i <= blocks; ++i) {
        saltBlock[saltLen] = static_cast<uint8_t>((i >> 24) & 0xFF);
        saltBlock[saltLen + 1] = static_cast<uint8_t>((i >> 16) & 0xFF);
        saltBlock[saltLen + 2] = static_cast<uint8_t>((i >> 8) & 0xFF);
        saltBlock[saltLen + 3] = static_cast<uint8_t>(i & 0xFF);

        uint8_t u[32], t[32];
        hmacSha256(pw, pwLen, saltBlock.data(), saltBlock.size(), u);
        std::memcpy(t, u, 32);
        for (uint32_t it = 1; it < iterations; ++it) {
            hmacSha256(pw, pwLen, u, 32, u);
            for (int k = 0; k < 32; ++k) t[k] ^= u[k];
        }
        size_t off = static_cast<size_t>(i - 1) * hLen;
        size_t n = outLen - off < hLen ? outLen - off : hLen;
        std::memcpy(out.data() + off, t, n);

        std::memset(u, 0, sizeof(u));
        std::memset(t, 0, sizeof(t));
    }

    // 清零中间状态
    if (!saltBlock.empty()) std::memset(saltBlock.data(), 0, saltBlock.size());
    return out;
}

// ═══════════════════════════════════════════════
// AES（FIPS-197）—— 128/256 位密钥，CBC 模式
// 状态平面布局与 FIPS 输入同序：index = 4*col + row
// ═══════════════════════════════════════════════

namespace {

const uint8_t kSbox[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab,
    0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4,
    0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71,
    0xd8, 0x31, 0x15, 0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
    0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6,
    0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb,
    0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf, 0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45,
    0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
    0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44,
    0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73, 0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a,
    0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49,
    0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
    0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08, 0xba, 0x78, 0x25,
    0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e,
    0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e, 0xe1,
    0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb,
    0x16};

const uint8_t kInvSbox[256] = {
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7,
    0xfb, 0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde,
    0xe9, 0xcb, 0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42,
    0xfa, 0xc3, 0x4e, 0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49,
    0x6d, 0x8b, 0xd1, 0x25, 0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c,
    0xcc, 0x5d, 0x65, 0xb6, 0x92, 0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15,
    0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84, 0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7,
    0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06, 0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02,
    0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b, 0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc,
    0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73, 0x96, 0xac, 0x74, 0x22, 0xe7, 0xad,
    0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e, 0x47, 0xf1, 0x1a, 0x71, 0x1d,
    0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b, 0xfc, 0x56, 0x3e, 0x4b,
    0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4, 0x1f, 0xdd, 0xa8,
    0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f, 0x60, 0x51,
    0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef, 0xa0,
    0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c,
    0x7d};

const uint8_t kRcon[11] = {0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36};

inline uint8_t xtime(uint8_t x) { return static_cast<uint8_t>((x << 1) ^ ((x >> 7) * 0x1b)); }

inline uint8_t gfMul(uint8_t a, uint8_t b) {
    uint8_t r = 0;
    while (b) {
        if (b & 1) r ^= a;
        a = xtime(a);
        b >>= 1;
    }
    return r;
}

struct AesKey {
    int nr = 0;                     // 轮数
    std::vector<uint8_t> rk;        // 16*(nr+1) 字节
};

AesKey expandKey(AesKeyBits bits, const uint8_t* key) {
    AesKey k;
    const int nk = (bits == AesKeyBits::Aes128) ? 4 : 8;
    k.nr = (bits == AesKeyBits::Aes128) ? 10 : 14;
    const int totalWords = 4 * (k.nr + 1);
    k.rk.assign(static_cast<size_t>(totalWords) * 4, 0);
    std::memcpy(k.rk.data(), key, static_cast<size_t>(nk) * 4);

    for (int i = nk; i < totalWords; ++i) {
        uint8_t temp[4];
        std::memcpy(temp, &k.rk[static_cast<size_t>(i - 1) * 4], 4);
        if (i % nk == 0) {
            uint8_t t0 = temp[0];
            temp[0] = temp[1];
            temp[1] = temp[2];
            temp[2] = temp[3];
            temp[3] = t0;
            for (int j = 0; j < 4; ++j) temp[j] = kSbox[temp[j]];
            temp[0] ^= kRcon[i / nk];
        } else if (nk > 6 && i % nk == 4) {
            for (int j = 0; j < 4; ++j) temp[j] = kSbox[temp[j]];
        }
        for (int j = 0; j < 4; ++j)
            k.rk[static_cast<size_t>(i) * 4 + j] =
                k.rk[static_cast<size_t>(i - nk) * 4 + j] ^ temp[j];
    }
    return k;
}

void addRoundKey(uint8_t s[16], const uint8_t* rk, int round) {
    const uint8_t* p = rk + static_cast<size_t>(round) * 16;
    for (int i = 0; i < 16; ++i) s[i] ^= p[i];
}

void subBytes(uint8_t s[16]) {
    for (int i = 0; i < 16; ++i) s[i] = kSbox[s[i]];
}

void invSubBytes(uint8_t s[16]) {
    for (int i = 0; i < 16; ++i) s[i] = kInvSbox[s[i]];
}

// shiftRows：行 r（平面下标 r + 4c）左移 r 列
void shiftRows(uint8_t s[16]) {
    uint8_t t[16];
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) t[r + 4 * c] = s[r + 4 * ((c + r) & 3)];
    std::memcpy(s, t, 16);
}

void invShiftRows(uint8_t s[16]) {
    uint8_t t[16];
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) t[r + 4 * c] = s[r + 4 * ((c - r + 4) & 3)];
    std::memcpy(s, t, 16);
}

void mixColumns(uint8_t s[16]) {
    for (int c = 0; c < 4; ++c) {
        uint8_t* p = s + 4 * c;
        uint8_t a0 = p[0], a1 = p[1], a2 = p[2], a3 = p[3];
        p[0] = static_cast<uint8_t>(xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3);
        p[1] = static_cast<uint8_t>(a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3);
        p[2] = static_cast<uint8_t>(a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3));
        p[3] = static_cast<uint8_t>((xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3));
    }
}

void invMixColumns(uint8_t s[16]) {
    for (int c = 0; c < 4; ++c) {
        uint8_t* p = s + 4 * c;
        uint8_t a0 = p[0], a1 = p[1], a2 = p[2], a3 = p[3];
        p[0] = static_cast<uint8_t>(gfMul(a0, 14) ^ gfMul(a1, 11) ^ gfMul(a2, 13) ^ gfMul(a3, 9));
        p[1] = static_cast<uint8_t>(gfMul(a0, 9) ^ gfMul(a1, 14) ^ gfMul(a2, 11) ^ gfMul(a3, 13));
        p[2] = static_cast<uint8_t>(gfMul(a0, 13) ^ gfMul(a1, 9) ^ gfMul(a2, 14) ^ gfMul(a3, 11));
        p[3] = static_cast<uint8_t>(gfMul(a0, 11) ^ gfMul(a1, 13) ^ gfMul(a2, 9) ^ gfMul(a3, 14));
    }
}

void encryptBlock(uint8_t s[16], const AesKey& k) {
    addRoundKey(s, k.rk.data(), 0);
    for (int round = 1; round < k.nr; ++round) {
        subBytes(s);
        shiftRows(s);
        mixColumns(s);
        addRoundKey(s, k.rk.data(), round);
    }
    subBytes(s);
    shiftRows(s);
    addRoundKey(s, k.rk.data(), k.nr);
}

void decryptBlock(uint8_t s[16], const AesKey& k) {
    addRoundKey(s, k.rk.data(), k.nr);
    for (int round = k.nr - 1; round >= 1; --round) {
        invShiftRows(s);
        invSubBytes(s);
        addRoundKey(s, k.rk.data(), round);
        invMixColumns(s);
    }
    invShiftRows(s);
    invSubBytes(s);
    addRoundKey(s, k.rk.data(), 0);
}

} // namespace

bool aesCbcEncrypt(AesKeyBits bits, const uint8_t* key, const uint8_t* iv, const uint8_t* plain,
                   size_t plainLen, std::vector<uint8_t>& out) {
    // PKCS#7：总是补 1..16 字节
    size_t padLen = 16 - (plainLen % 16);
    size_t total = plainLen + padLen;
    out.assign(total, 0);
    if (plainLen > 0) std::memcpy(out.data(), plain, plainLen);
    for (size_t i = plainLen; i < total; ++i) out[i] = static_cast<uint8_t>(padLen);

    AesKey k = expandKey(bits, key);
    uint8_t prev[16];
    std::memcpy(prev, iv, 16);

    for (size_t off = 0; off < total; off += 16) {
        uint8_t blk[16];
        for (int i = 0; i < 16; ++i) blk[i] = out[off + i] ^ prev[i];
        encryptBlock(blk, k);
        std::memcpy(out.data() + off, blk, 16);
        std::memcpy(prev, blk, 16);
    }
    // 清零轮密钥
    if (!k.rk.empty()) std::memset(k.rk.data(), 0, k.rk.size());
    std::memset(prev, 0, sizeof(prev));
    return true;
}

bool aesCbcDecrypt(AesKeyBits bits, const uint8_t* key, const uint8_t* iv, const uint8_t* cipher,
                   size_t cipherLen, std::vector<uint8_t>& out) {
    if (cipherLen == 0 || (cipherLen % 16) != 0) return false;
    if (cipherLen > (64ull << 20)) return false; // 64MB 上限，防异常分配

    AesKey k = expandKey(bits, key);
    uint8_t prev[16];
    std::memcpy(prev, iv, 16);

    out.assign(cipherLen, 0);
    for (size_t off = 0; off < cipherLen; off += 16) {
        uint8_t blk[16];
        std::memcpy(blk, cipher + off, 16);
        uint8_t cur[16];
        std::memcpy(cur, blk, 16);
        decryptBlock(blk, k);
        for (int i = 0; i < 16; ++i) out[off + i] = blk[i] ^ prev[i];
        std::memcpy(prev, cur, 16);
    }

    // 校验 PKCS#7 填充
    uint8_t padLen = out.back();
    if (padLen == 0 || padLen > 16 || static_cast<size_t>(padLen) > out.size()) {
        if (!k.rk.empty()) std::memset(k.rk.data(), 0, k.rk.size());
        std::memset(prev, 0, sizeof(prev));
        out.clear();
        return false;
    }
    for (size_t i = out.size() - padLen; i < out.size(); ++i) {
        if (out[i] != padLen) {
            if (!k.rk.empty()) std::memset(k.rk.data(), 0, k.rk.size());
            std::memset(prev, 0, sizeof(prev));
            out.clear();
            return false;
        }
    }
    out.resize(out.size() - padLen);
    if (!k.rk.empty()) std::memset(k.rk.data(), 0, k.rk.size());
    std::memset(prev, 0, sizeof(prev));
    return true;
}

// ═══════════════════════════════════════════════
// 工具
// ═══════════════════════════════════════════════

bool constantTimeEquals(const uint8_t* a, const uint8_t* b, size_t len) {
    uint8_t diff = 0;
    for (size_t i = 0; i < len; ++i) diff |= static_cast<uint8_t>(a[i] ^ b[i]);
    return diff == 0;
}

bool randomBytes(uint8_t* out, size_t len) {
    if (len == 0) return true;
#ifdef _WIN32
    NTSTATUS st = BCryptGenRandom(nullptr, out, static_cast<ULONG>(len),
                                  BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    return st == 0; // STATUS_SUCCESS
#else
    FILE* f = std::fopen("/dev/urandom", "rb");
    if (!f) return false;
    size_t got = std::fread(out, 1, len, f);
    std::fclose(f);
    return got == len;
#endif
}

std::string randomHex32() {
    uint8_t b[16];
    if (!randomBytes(b, sizeof(b))) return std::string();
    static const char* hex = "0123456789abcdef";
    std::string s;
    s.reserve(32);
    for (int i = 0; i < 16; ++i) {
        s.push_back(hex[b[i] >> 4]);
        s.push_back(hex[b[i] & 0x0F]);
    }
    return s;
}

} // namespace fppx_crypto
} // namespace ffmpegpp
