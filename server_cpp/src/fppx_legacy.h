#pragma once
// 旧版 FPPX（魔数 + 版本字节 + gzip(JSON)）的导入/导出 —— 完整迁移自
// GUI 端 Dart 的 FppxExporter（lib/services/config_export.dart），行为保持一致：
//   * 导出布局：magic(4B) + configMajor(1B) + configMinor(1B)
//               + minSoftwareMajor(1B) + compatMajorCount(1B) + mode(1B)
//               + descLen(2B 大端) + 描述 + dataLen(4B 大端) + gzip(图 JSON)
//   * 导入校验：魔数、软件版本区间、更高配置版本警告、未知节点类型
// 兼容承诺：旧文件永远可读；GUI 端"新建旧版配置"导出的文件与本模块互认。

#include "fppx2.h"

namespace ffmpegpp {

// 旧格式常量（与 Dart config_export.dart 对齐）
inline constexpr uint8_t LEGACY_CONFIG_MAJOR = 1;
inline constexpr uint8_t LEGACY_CONFIG_MINOR = 2;
inline constexpr uint8_t LEGACY_MIN_SOFTWARE_MAJOR = 3;
inline constexpr uint8_t LEGACY_COMPAT_MAJOR_COUNT = 2;
inline constexpr int LEGACY_CURRENT_SOFTWARE_MAJOR = 5;
inline constexpr uint8_t LEGACY_MODE_NODE_EDITOR = 0x01;
inline constexpr uint8_t LEGACY_MODE_LEGACY = 0x02;

} // namespace ffmpegpp
