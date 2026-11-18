// ═══════════════════════════════════════════
// 快捷配置 (Quick Config)
// 面向常见任务的轻量参数模板：视频/图片/音频 三类，每类若干可开关的配置项。
// 配置库页负责新建/删除/展示，Quick Config 编辑器（另一模块）负责读写编辑。
// ═══════════════════════════════════════════

enum QuickFileType {
  video,
  image,
  audio;

  String get name => switch (this) {
        QuickFileType.video => 'video',
        QuickFileType.image => 'image',
        QuickFileType.audio => 'audio',
      };

  String label(bool isZh) => switch (this) {
        QuickFileType.video => isZh ? '视频' : 'Video',
        QuickFileType.image => isZh ? '图片' : 'Image',
        QuickFileType.audio => isZh ? '音频' : 'Audio',
      };

  /// 宽容解析历史文件里的 file_type：大小写/前后空格、常见别名、
  /// 以及旧版可能写成的数字索引（0=video, 1=image, 2=audio）。
  static QuickFileType? fromJson(Object? value) {
    if (value is num) {
      return switch (value.toInt()) {
        0 => QuickFileType.video,
        1 => QuickFileType.image,
        2 => QuickFileType.audio,
        _ => null,
      };
    }
    final name = value?.toString().trim().toLowerCase();
    return switch (name) {
      'video' || 'movie' || 'videos' => QuickFileType.video,
      'image' || 'photo' || 'picture' || 'images' => QuickFileType.image,
      'audio' || 'sound' || 'music' || 'audios' => QuickFileType.audio,
      _ => null,
    };
  }

  static QuickFileType? fromName(String? name) => fromJson(name);
}

/// 单条快捷配置项：一个可开关的常见操作及其参数。
class QuickConfigItem {
  /// 唯一键（如 'bitrate'、'crop'），供编辑器识别。
  final String key;

  /// 标题兜底显示（titleZh/titleEn 均未提供时使用）。
  final String title;
  final String titleZh;
  final String titleEn;

  final Map<String, dynamic> params;
  bool enabled;

  QuickConfigItem({
    required this.key,
    this.title = '',
    this.titleZh = '',
    this.titleEn = '',
    Map<String, dynamic>? params,
    this.enabled = true,
  }) : params = params ?? {};

  /// 按当前语言返回标题；缺省时回退到 [title]。
  String titleFor(bool isZh) {
    if (isZh && titleZh.isNotEmpty) return titleZh;
    if (!isZh && titleEn.isNotEmpty) return titleEn;
    return title;
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'title_zh': titleZh,
        'title_en': titleEn,
        'params': params,
        'enabled': enabled,
      };

  factory QuickConfigItem.fromJson(Map<String, dynamic> json) => QuickConfigItem(
        key: json['key'] as String? ?? '',
        title: json['title'] as String? ?? '',
        titleZh: json['title_zh'] as String? ?? '',
        titleEn: json['title_en'] as String? ?? '',
        params: (json['params'] as Map<String, dynamic>?) ?? {},
        enabled: json['enabled'] as bool? ?? true,
      );
}

/// 一份快捷配置：面向某类媒体（视频/图片/音频）的若干参数项组合。
class QuickConfig {
  final String id;
  QuickFileType fileType;
  String name;
  String description;
  DateTime createdAt;
  DateTime updatedAt;
  List<QuickConfigItem> items;

  QuickConfig({
    required this.id,
    required this.fileType,
    this.name = '',
    this.description = '',
    DateTime? createdAt,
    DateTime? updatedAt,
    List<QuickConfigItem>? items,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        items = items ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'file_type': fileType.name,
        'name': name,
        'description': description,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'items': items.map((i) => i.toJson()).toList(),
      };

  factory QuickConfig.fromJson(Map<String, dynamic> json) {
    final created = DateTime.tryParse(json['created_at'] as String? ?? '');
    final updated = DateTime.tryParse(json['updated_at'] as String? ?? '');
    // [FIX L-7] 过滤非 Map 元素，并对单条坏元素 try/catch 跳过，坏一条不影响其余
    final items = (json['items'] as List?)
            ?.whereType<Map>()
            .map((e) {
              try {
                return QuickConfigItem.fromJson(e as Map<String, dynamic>);
              } catch (_) {
                return null; // 单条解析失败：跳过而非整份配置崩溃
              }
            })
            .whereType<QuickConfigItem>()
            .toList() ??
        <QuickConfigItem>[];
    final explicitType = QuickFileType.fromJson(json['file_type']);
    return QuickConfig(
      id: json['id'] as String? ?? '',
      // 没有 file_type 的旧文件不能一律当视频：按参数 key 推断。
      fileType: explicitType ?? inferQuickFileTypeFromItems(items),
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      createdAt: created ?? DateTime.now(),
      updatedAt: updated ?? DateTime.now(),
      items: items,
    );
  }
}

/// 各文件类型的默认配置项模板（新建快捷配置时预填）。
/// 每一项含 key、中英标题与合理的默认参数。
List<QuickConfigItem> quickDefaultsFor(QuickFileType type) => switch (type) {
      QuickFileType.video => [
          QuickConfigItem(
            key: 'bitrate',
            titleZh: '码率控制',
            titleEn: 'Bitrate',
            params: {'bitrate': '4M', 'crf': 23},
          ),
          QuickConfigItem(
            key: 'subtitle',
            titleZh: '字幕',
            titleEn: 'Subtitle',
            params: {'subtitle_path': '', 'burn': true},
          ),
          QuickConfigItem(
            key: 'crop',
            titleZh: '裁剪',
            titleEn: 'Crop',
            params: {'w': 1920, 'h': 1080, 'x': 0, 'y': 0},
          ),
          QuickConfigItem(
            key: 'rotate',
            titleZh: '旋转',
            titleEn: 'Rotate',
            params: {'angle': 90},
          ),
          QuickConfigItem(
            key: 'watermark',
            titleZh: '水印',
            titleEn: 'Watermark',
            params: {'image': '', 'position': 'bottom_right'},
          ),
          QuickConfigItem(
            key: 'compress',
            titleZh: '压缩',
            titleEn: 'Compress',
            params: {'codec': 'h264', 'preset': 'medium'},
          ),
        ],
      QuickFileType.image => [
          QuickConfigItem(
            key: 'resize',
            titleZh: '缩放',
            titleEn: 'Resize',
            params: {'w': 1920, 'h': 1080, 'fit': 'contain'},
          ),
          QuickConfigItem(
            key: 'compress',
            titleZh: '压缩',
            titleEn: 'Compress',
            params: {'quality': 85, 'format': 'jpg'},
          ),
          QuickConfigItem(
            key: 'watermark',
            titleZh: '水印',
            titleEn: 'Watermark',
            params: {'image': '', 'position': 'bottom_right'},
          ),
          QuickConfigItem(
            key: 'convert_format',
            titleZh: '格式转换',
            titleEn: 'Convert Format',
            params: {'format': 'png'},
          ),
          QuickConfigItem(
            key: 'filters',
            titleZh: '滤镜',
            titleEn: 'Filters',
            params: {'brightness': 0, 'contrast': 1.0, 'saturation': 1.0},
          ),
        ],
      QuickFileType.audio => [
          QuickConfigItem(
            key: 'bitrate',
            titleZh: '码率',
            titleEn: 'Bitrate',
            params: {'bitrate': '192k'},
          ),
          QuickConfigItem(
            key: 'sample_rate',
            titleZh: '采样率',
            titleEn: 'Sample Rate',
            params: {'rate': 44100},
          ),
          QuickConfigItem(
            key: 'channels',
            titleZh: '声道',
            titleEn: 'Channels',
            params: {'count': 2},
          ),
          QuickConfigItem(
            key: 'normalize',
            titleZh: '音量归一化',
            titleEn: 'Normalize',
            params: {'level': -14},
          ),
          QuickConfigItem(
            key: 'convert_format',
            titleZh: '格式转换',
            titleEn: 'Convert Format',
            params: {'format': 'mp3'},
          ),
        ],
    };


/// 从快捷配置项推断文件类型。
///
/// 0x02 旧格式不保存 file_type，而 bitrate / compress / watermark 等 key
/// 在视频和图片里重名。这里优先看只在某一类出现的 key，再看 compress /
/// convert_format 的参数签名，最后才回退 video。
QuickFileType inferQuickFileTypeFromItems(Iterable<QuickConfigItem> items) {
  return inferQuickFileTypeFromMaps([
    for (final item in items)
      <String, dynamic>{'key': item.key, 'params': item.params},
  ]);
}

/// 从原始 JSON 快捷项（FPPX 导入 / 历史文件）推断文件类型。
QuickFileType inferQuickFileTypeFromMaps(List<Map<String, dynamic>> items) {
  final keys = <String>{};
  final signatures = <String>[];
  for (final item in items) {
    final key = (item['key'] as String? ?? '').trim().toLowerCase();
    if (key.isNotEmpty) keys.add(key);
    final params = item['params'];
    if (params is Map) {
      for (final entry in params.entries) {
        signatures.add('${entry.key}:${entry.value}'.toLowerCase());
      }
    }
  }
  final blob = signatures.join('|');

  // 音频专属字段最可靠：采样率 / 声道 / 响度归一化。
  if (keys.intersection({'sample_rate', 'channels', 'normalize'}).isNotEmpty) {
    return QuickFileType.audio;
  }

  // 图片专属：重采样与滤镜；resize 的 fit 参数视频侧没有。
  if (keys.contains('resize') || keys.contains('filters')) {
    return QuickFileType.image;
  }

  // 图片 compress：quality + 图片格式；视频 compress：codec/preset。
  if (keys.contains('compress')) {
    final imageCompress = blob.contains('quality:') ||
        blob.contains('format:jpg') ||
        blob.contains('format:jpeg') ||
        blob.contains('format:png') ||
        blob.contains('format:webp');
    final videoCompress = blob.contains('codec:') || blob.contains('preset:');
    if (imageCompress && !videoCompress) return QuickFileType.image;
    if (videoCompress) return QuickFileType.video;
  }

  // convert_format 的 format 是图片扩展名时按图片处理。
  if (keys.contains('convert_format') &&
      RegExp(r'format:(jpg|jpeg|png|webp|bmp|tiff|gif)').hasMatch(blob)) {
    return QuickFileType.image;
  }

  // 字幕 / 旋转 / 水印 / 码率+crf / 视频 compress 都是视频语义。
  if (keys.intersection({'subtitle', 'rotate', 'watermark'}).isNotEmpty ||
      blob.contains('crf:') ||
      blob.contains('codec:h264') ||
      blob.contains('codec:h265') ||
      blob.contains('codec:hevc')) {
    return QuickFileType.video;
  }

  // 仅有 bitrate 的旧文件无法区分视频/音频，维持历史默认视频。
  return QuickFileType.video;
}
