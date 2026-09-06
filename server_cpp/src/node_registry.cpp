#include "node_registry.h"

#include <cstdio>

namespace ffmpegpp {

NodeTypeId makeTypeId(uint64_t v) {
    NodeTypeId id{};
    for (int i = 15; i >= 0; --i) {
        id[i] = static_cast<uint8_t>(v & 0xFF);
        v >>= 8;
    }
    return id;
}

std::string typeIdToDec(const NodeTypeId& id) {
    unsigned long long v = 0;
    for (int i = 0; i < 16; ++i) v = (v << 8) | id[i];
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%llu", static_cast<unsigned long long>(v));
    return buf;
}

namespace {

// 通用媒体处理节点的参数键（所有节点都允许 node_name 显示别名）
#define COMMON_KEYS "node_name"

// ── 媒体处理节点（数据流）──────────────────────────────────────
const NodeTypeSpec kTypes[] = {
    // ID 按整数顺序分配；avProcess=0x1（历史约定），其余按 GUI 枚举序
    {makeTypeId(0x1), "avProcess", nullptr, "音视频处理",
     MK_VIDEO, MK_VIDEO, false, 0,
     {COMMON_KEYS, "video_codec", "audio_codec", "preset", "gpu", "resolution",
      "rate_mode", "crf", "video_bitrate", "vf_filters", "af_filters",
      "overwrite", "sample_rate"}},
    {makeTypeId(0x2), "subtitle", nullptr, "字幕烧录",
     MK_VIDEO, MK_VIDEO, false, 0, {COMMON_KEYS, "source"}},
    {makeTypeId(0x3), "clip", nullptr, "片段截取",
     MK_VIDEO, MK_VIDEO, false, 0, {COMMON_KEYS, "start_time", "end_time"}},
    {makeTypeId(0x4), "frame", nullptr, "帧提取",
     MK_VIDEO, MK_IMAGE, false, 0,
     {COMMON_KEYS, "extract_mode", "time", "range_start", "range_end", "fps_rate"}},
    {makeTypeId(0x5), "speed", nullptr, "变速",
     MK_VIDEO, MK_VIDEO, false, 0,
     {COMMON_KEYS, "speed", "custom_speed", "custom_speed_value"}},
    {makeTypeId(0x6), "imageConvert", nullptr, "图片转换",
     MK_IMAGE, MK_IMAGE, false, 0, {COMMON_KEYS, "output_format"}},
    {makeTypeId(0x7), "audioConvert", nullptr, "音频转换",
     MK_AUDIO, MK_AUDIO, false, 0, {COMMON_KEYS, "audio_codec", "output_format"}},
    {makeTypeId(0x8), "audioQuality", nullptr, "音质调整",
     MK_AUDIO, MK_AUDIO, false, 0, {COMMON_KEYS, "audio_bitrate", "sample_rate"}},
    {makeTypeId(0x9), "audioSpeed", nullptr, "调整速度",
     MK_AUDIO, MK_AUDIO, false, 0, {COMMON_KEYS, "atempo"}},
    {makeTypeId(0xA), "audioVolume", nullptr, "调整音量",
     MK_AUDIO, MK_AUDIO, false, 0, {COMMON_KEYS, "volume_db"}},
    {makeTypeId(0xB), "audioCompressor", nullptr, "压缩动态范围",
     MK_AUDIO, MK_AUDIO, false, 0, {COMMON_KEYS, "threshold", "ratio"}},
    {makeTypeId(0xC), "audioMetadata", nullptr, "元信息编辑",
     MK_AUDIO, MK_AUDIO, false, 0,
     {COMMON_KEYS, "cover_path", "lyrics_path", "remove_cover", "remove_lyrics"}},
    {makeTypeId(0xD), "extractAudio", nullptr, "提取音频",
     MK_VIDEO, MK_AUDIO, false, 0,
     {COMMON_KEYS, "extract_mode", "start_time", "end_time", "audio_codec",
      "output_format"}},
    {makeTypeId(0xE), "concatMedia", nullptr, "合并媒体",
     MK_VIDEO | MK_AUDIO, MK_VIDEO, false, 0, {COMMON_KEYS, "mode"}},
    {makeTypeId(0xF), "imageToVideo", nullptr, "图片合成视频",
     MK_IMAGE, MK_VIDEO, false, 0, {COMMON_KEYS, "framerate"}},
    {makeTypeId(0x10), "imageCrop", nullptr, "图片裁剪",
     MK_IMAGE, MK_IMAGE, false, 0,
     {COMMON_KEYS, "crop_w", "crop_h", "crop_x", "crop_y"}},
    {makeTypeId(0x11), "imageRotate", nullptr, "图片旋转",
     MK_IMAGE, MK_IMAGE, false, 0, {COMMON_KEYS, "angle"}},
    {makeTypeId(0x12), "imageScale", nullptr, "图片缩放",
     MK_IMAGE, MK_IMAGE, false, 0, {COMMON_KEYS, "scale_factor"}},
    {makeTypeId(0x13), "imageBrightness", nullptr, "图片亮度",
     MK_IMAGE, MK_IMAGE, false, 0, {COMMON_KEYS, "brightness"}},
    {makeTypeId(0x14), "imageNoise", nullptr, "图片噪声",
     MK_IMAGE, MK_IMAGE, false, 0, {COMMON_KEYS, "noise_strength"}},
    {makeTypeId(0x15), "imageSharpen", nullptr, "图片锐化",
     MK_IMAGE, MK_IMAGE, false, 0, {COMMON_KEYS, "sharpen_strength"}},
    {makeTypeId(0x16), "imageDenoise", nullptr, "图片降噪",
     MK_IMAGE, MK_IMAGE, false, 0, {COMMON_KEYS, "denoise_method"}},
    {makeTypeId(0x17), "imageChannelExtract", nullptr, "通道提取",
     MK_IMAGE, MK_IMAGE, false, 0, {COMMON_KEYS, "channel"}},
    {makeTypeId(0x18), "videoCrop", nullptr, "视频裁剪",
     MK_VIDEO, MK_VIDEO, false, 0,
     {COMMON_KEYS, "crop_w", "crop_h", "crop_x", "crop_y"}},
};

// ── 结构性节点（源/输出）──────────────────────────────────────
const NodeTypeSpec kStart{
    makeTypeId(0xF0), "start", nullptr, "源文件",
    MK_NONE, MK_VIDEO | MK_IMAGE | MK_AUDIO /*实际由 file_media_type 决定*/,
    false, 0, {COMMON_KEYS, "file_media_type", "filepath", "filename"}};

const NodeTypeSpec kOutput{
    makeTypeId(0xF1), "output", nullptr, "输出",
    MK_VIDEO | MK_IMAGE | MK_AUDIO, MK_NONE, false, 0, {COMMON_KEYS, "filename"}};

// ── 逻辑门（控制流节点；GUI 中 type 恒为 "start" + gate 字段）──
const NodeTypeSpec kGates[] = {
    {makeTypeId(0x101), "start", "and", "与门", MK_NONE, MK_NONE, true, 2, {COMMON_KEYS}},
    {makeTypeId(0x102), "start", "or", "或门", MK_NONE, MK_NONE, true, 2, {COMMON_KEYS}},
    {makeTypeId(0x103), "start", "not", "非门", MK_NONE, MK_NONE, true, 1, {COMMON_KEYS}},
    {makeTypeId(0x104), "start", "nand", "与非门", MK_NONE, MK_NONE, true, 2, {COMMON_KEYS}},
    {makeTypeId(0x105), "start", "nor", "或非门", MK_NONE, MK_NONE, true, 2, {COMMON_KEYS}},
    {makeTypeId(0x106), "start", "xor", "异或门", MK_NONE, MK_NONE, true, 2, {COMMON_KEYS}},
    {makeTypeId(0x107), "start", "xnor", "同或门", MK_NONE, MK_NONE, true, 2, {COMMON_KEYS}},
    {makeTypeId(0x108), "start", "const1", "恒 1", MK_NONE, MK_NONE, true, 0, {COMMON_KEYS}},
    {makeTypeId(0x109), "start", "const0", "恒 0", MK_NONE, MK_NONE, true, 0, {COMMON_KEYS}},
    {makeTypeId(0x10A), "start", "timeTrigger", "时间触发器", MK_NONE, MK_NONE, true, 0,
     {COMMON_KEYS, "date", "start_time", "end_time"}},
};

// ── 快速模式参数项 key 白名单（对应 GUI quick_config.dart 的 item key）──
const std::set<std::string> kQuickKeys = {
    // 视频
    "bitrate", "compress", "crop", "rotate", "subtitle", "watermark",
    // 图片
    "resize", "convert_format", "filters",
    // 音频
    "sample_rate", "channels", "normalize",
};

} // namespace

const NodeTypeSpec* findTypeByName(const std::string& name) {
    for (const auto& t : kTypes)
        if (name == t.name) return &t;
    if (name == kStart.name) return &kStart;
    if (name == kOutput.name) return &kOutput;
    return nullptr;
}

const NodeTypeSpec* findGateByName(const std::string& gateName) {
    for (const auto& g : kGates)
        if (gateName == g.gateName) return &g;
    return nullptr;
}

const NodeTypeSpec* findTypeById(const NodeTypeId& id) {
    for (const auto& t : kTypes)
        if (id == t.id) return &t;
    if (id == kStart.id) return &kStart;
    if (id == kOutput.id) return &kOutput;
    return nullptr;
}

const NodeTypeSpec* findGateById(const NodeTypeId& id) {
    for (const auto& g : kGates)
        if (id == g.id) return &g;
    return nullptr;
}

ParamKeyClass classifyParamKey(const std::string& key, const NodeTypeSpec* spec,
                               const char* gateName) {
    if (spec && spec->paramKeys.count(key)) return PKC_OK;
    // 门节点的键属于门自身，不算张冠李戴
    if (gateName) {
        const NodeTypeSpec* g = findGateByName(gateName);
        if (g && g->paramKeys.count(key)) return PKC_OK;
    }
    // 登记在其他节点名下 → 张冠李戴；完全未登记 → 新键（向前兼容）
    for (const auto& t : kTypes)
        if (t.paramKeys.count(key)) return PKC_MISMATCH;
    if (kStart.paramKeys.count(key) || kOutput.paramKeys.count(key)) return PKC_MISMATCH;
    for (const auto& g : kGates)
        if (g.paramKeys.count(key)) return PKC_MISMATCH;
    return PKC_UNLISTED;
}

bool isKnownQuickKey(const std::string& key) { return kQuickKeys.count(key) > 0; }

} // namespace ffmpegpp
