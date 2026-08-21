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

  static QuickFileType? fromName(String? name) => switch (name) {
        'video' => QuickFileType.video,
        'image' => QuickFileType.image,
        'audio' => QuickFileType.audio,
        _ => null,
      };
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
    return QuickConfig(
      id: json['id'] as String? ?? '',
      fileType: QuickFileType.fromName(json['file_type'] as String?) ??
          QuickFileType.video,
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      createdAt: created ?? DateTime.now(),
      updatedAt: updated ?? DateTime.now(),
      items: (json['items'] as List?)
              ?.map((e) => QuickConfigItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
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
