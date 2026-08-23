import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models/quick_config.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/glass_panel.dart';

/// 预设选项：值 + 显示标签。
typedef _Preset = ({Object value, String label});

/// 快捷配置编辑器 —— 悬浮玻璃窗口（居中对话框），而非整页。
/// 左侧列配置项，右侧编辑参数；通过 showDialog 打开，onSave 回调保存更新后的配置。
class QuickConfigPage extends StatefulWidget {
  final QuickConfig config;
  final void Function(QuickConfig updated) onSave;

  const QuickConfigPage({
    super.key,
    required this.config,
    required this.onSave,
  });

  @override
  State<QuickConfigPage> createState() => _QuickConfigPageState();
}

class _QuickConfigPageState extends State<QuickConfigPage> {
  late QuickConfig _config;
  String? _selectedKey;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _config = _deepCopy(widget.config);
    if (_config.items.isNotEmpty) {
      _selectedKey = _config.items.first.key;
    }
  }

  /// 深拷贝一份工作副本，避免直接修改传入的配置对象。
  QuickConfig _deepCopy(QuickConfig src) {
    return QuickConfig(
      id: src.id,
      fileType: src.fileType,
      name: src.name,
      description: src.description,
      createdAt: src.createdAt,
      updatedAt: src.updatedAt,
      items: src.items
          .map((it) => QuickConfigItem(
                key: it.key,
                title: it.title,
                titleZh: it.titleZh,
                titleEn: it.titleEn,
                params: Map<String, dynamic>.from(it.params),
                enabled: it.enabled,
              ))
          .toList(),
    );
  }

  void _toggleItemEnabled(int index) {
    setState(() {
      _config.items[index].enabled = !_config.items[index].enabled;
      _dirty = true;
    });
  }

  void _updateParam(String itemKey, String paramKey, dynamic value) {
    final idx = _config.items.indexWhere((it) => it.key == itemKey);
    if (idx < 0) return;
    setState(() {
      _config.items[idx].params[paramKey] = value;
      _dirty = true;
    });
  }

  void _save() {
    widget.onSave(_config);
    setState(() => _dirty = false);
    Navigator.pop(context, _config);
  }

  Future<bool> _onWillPop() async {
    if (!_dirty) return true;
    final scheme = Theme.of(context).colorScheme;
    final isZh = AppStrings.of(context.read<AppState>().config.language).isZh;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          isZh ? '放弃更改?' : 'Discard changes?',
          style: TextStyle(color: scheme.onSurface),
        ),
        content: Text(
          isZh ? '你有未保存的更改，确定要退出吗？' : 'You have unsaved changes. Discard?',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isZh ? '放弃' : 'Discard'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ── 工具方法 ──

  /// snake_case → Title Case（未知键兜底显示）
  String _humanizeKey(String key) {
    return key
        .split('_')
        .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  /// 参数名本地化标签。
  String _paramLabel(String key, bool isZh) {
    switch (key) {
      case 'bitrate': return isZh ? '码率' : 'Bitrate';
      case 'crf': return 'CRF';
      case 'angle': return isZh ? '角度' : 'Angle';
      case 'subtitle_path':
      case 'subtitle_file': return isZh ? '字幕文件' : 'Subtitle File';
      case 'w': return isZh ? '宽度' : 'Width';
      case 'h': return isZh ? '高度' : 'Height';
      case 'x': return isZh ? 'X 偏移' : 'X Offset';
      case 'y': return isZh ? 'Y 偏移' : 'Y Offset';
      case 'quality': return isZh ? '质量' : 'Quality';
      case 'format': return isZh ? '格式' : 'Format';
      case 'codec': return isZh ? '编码器' : 'Codec';
      case 'preset': return isZh ? '预设' : 'Preset';
      case 'position': return isZh ? '位置' : 'Position';
      case 'image': return isZh ? '水印图片' : 'Watermark Image';
      case 'brightness': return isZh ? '亮度' : 'Brightness';
      case 'contrast': return isZh ? '对比度' : 'Contrast';
      case 'saturation': return isZh ? '饱和度' : 'Saturation';
      case 'fit': return isZh ? '适配' : 'Fit Mode';
      case 'rate': return isZh ? '采样率 (Hz)' : 'Sample Rate (Hz)';
      case 'count': return isZh ? '声道数' : 'Channels';
      case 'level': return isZh ? '目标响度 (LUFS)' : 'Level (LUFS)';
      case 'burn': return isZh ? '烧录字幕' : 'Burn Subtitles';
      default: return _humanizeKey(key);
    }
  }

  /// 左面板每项下方的简要参数描述（如 "码率 4M · CRF 23"）。
  String _itemSummary(QuickConfigItem item, bool isZh) {
    final parts = <String>[];
    item.params.forEach((k, v) {
      final label = _paramLabel(k, isZh);
      if (v is bool) {
        parts.add('$label${isZh ? (v ? '开启' : '关闭') : (v ? 'on' : 'off')}');
      } else if (v is num) {
        parts.add('$label $v');
      } else if (v is String && v.isNotEmpty) {
        final display = v.length > 16 ? '${v.substring(0, 16)}…' : v;
        parts.add('$label $display');
      } else if (v is List && v.isNotEmpty) {
        parts.add('$label ${v.join('/')}');
      }
    });
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// 常见参数的预设选项（供下拉框选择）。
  List<_Preset>? _presetsFor(String paramKey, QuickFileType ft, bool isZh) {
    switch (paramKey) {
      case 'position':
        return [
          (value: 'bottom_right', label: isZh ? '右下' : 'Bottom Right'),
          (value: 'bottom_left', label: isZh ? '左下' : 'Bottom Left'),
          (value: 'top_right', label: isZh ? '右上' : 'Top Right'),
          (value: 'top_left', label: isZh ? '左上' : 'Top Left'),
          (value: 'center', label: isZh ? '居中' : 'Center'),
        ];
      case 'preset':
        return <_Preset>[
          for (final e in const ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow', 'placebo'])
            (value: e, label: e),
        ];
      case 'codec':
        final list = ft == QuickFileType.audio
            ? const ['aac', 'mp3', 'opus', 'flac', 'pcm_s16le']
            : const ['h264', 'hevc', 'av1', 'vp9', 'mpeg4'];
        return <_Preset>[for (final e in list) (value: e, label: e)];
      case 'format':
        final list = switch (ft) {
          QuickFileType.video => const ['mp4', 'mkv', 'mov', 'avi', 'webm', 'mpeg'],
          QuickFileType.audio => const ['mp3', 'aac', 'wav', 'flac', 'ogg', 'm4a'],
          QuickFileType.image => const ['jpg', 'png', 'webp', 'bmp', 'tiff'],
        };
        return <_Preset>[for (final e in list) (value: e, label: e)];
      case 'fit':
        return [
          (value: 'contain', label: isZh ? '等比缩放' : 'Contain'),
          (value: 'cover', label: isZh ? '裁剪填充' : 'Cover'),
          (value: 'fill', label: isZh ? '拉伸' : 'Fill'),
          (value: 'inside', label: isZh ? '仅缩小' : 'Inside'),
          (value: 'outside', label: isZh ? '仅放大' : 'Outside'),
        ];
      case 'rate':
        return <_Preset>[for (final e in const [8000, 22050, 44100, 48000, 96000]) (value: e, label: '$e')];
      case 'count':
        return [
          (value: 1, label: isZh ? '单声道 (1)' : 'Mono (1)'),
          (value: 2, label: isZh ? '立体声 (2)' : 'Stereo (2)'),
          (value: 6, label: isZh ? '5.1 环绕 (6)' : '5.1 (6)'),
        ];
      case 'bitrate':
        final list = ft == QuickFileType.audio
            ? const ['64k', '128k', '192k', '256k', '320k']
            : const ['500k', '1M', '2M', '4M', '8M', '20M'];
        return <_Preset>[for (final e in list) (value: e, label: e)];
      case 'quality':
        return <_Preset>[for (final e in const [60, 70, 75, 80, 85, 90, 95]) (value: e, label: '$e')];
      case 'level':
        return <_Preset>[for (final e in const [-23, -20, -16, -14, -12]) (value: e, label: '$e LUFS')];
      default:
        return null;
    }
  }

  IconData _itemIcon(String key) {
    switch (key) {
      case 'bitrate': return Icons.speed;
      case 'subtitle': return Icons.subtitles;
      case 'crop': return Icons.crop;
      case 'rotate': return Icons.rotate_right;
      case 'watermark': return Icons.branding_watermark;
      case 'compress': return Icons.compress;
      case 'resize': return Icons.photo_size_select_large;
      case 'convert_format': return Icons.swap_horiz;
      case 'filters': return Icons.tune;
      case 'sample_rate': return Icons.multitrack_audio;
      case 'channels': return Icons.surround_sound;
      case 'normalize': return Icons.volume_up;
      default: return Icons.tune_outlined;
    }
  }

  Color _fileTypeColor(QuickFileType type, ColorScheme scheme) {
    switch (type) {
      case QuickFileType.video: return scheme.primary;
      case QuickFileType.audio: return scheme.tertiary;
      case QuickFileType.image: return scheme.secondary;
    }
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isZh = AppStrings.of(context.watch<AppState>().config.language).isZh;
    final media = MediaQuery.of(context);
    final narrow = media.size.width < 760;
    final winW = narrow ? media.size.width - 16 : math.min(960.0, media.size.width * 0.92);
    final winH = narrow ? media.size.height - 24 : math.min(700.0, media.size.height * 0.86);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _onWillPop() && nav.mounted) nav.pop();
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: SizedBox(
          width: winW,
          height: winH,
          child: GlassPanel(
            radius: 22,
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(scheme, isZh),
                Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
                Expanded(
                  child: LayoutBuilder(
                    builder: (_, constraints) {
                      if (constraints.maxWidth < 720) {
                        return _buildVerticalLayout(scheme, isZh);
                      }
                      return _buildHorizontalLayout(scheme, isZh);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 窗口顶栏：标题 + 文件类型徽章 + 保存/关闭。
  Widget _buildHeader(ColorScheme scheme, bool isZh) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _config.name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                if (_config.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    _config.description,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _fileTypeColor(_config.fileType, scheme).withAlpha(30),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _fileTypeColor(_config.fileType, scheme).withAlpha(80)),
            ),
            child: Text(
              _config.fileType.label(isZh),
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _fileTypeColor(_config.fileType, scheme)),
            ),
          ),
          if (_dirty) ...[
            const SizedBox(width: 8),
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(color: Colors.orangeAccent, shape: BoxShape.circle),
            ),
          ],
          const SizedBox(width: 8),
          FilledButton.icon(
            icon: const Icon(Icons.save_outlined, size: 16),
            label: Text(isZh ? '保存' : 'Save'),
            onPressed: _dirty ? _save : null,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: isZh ? '关闭' : 'Close',
            onPressed: () async {
              final nav = Navigator.of(context);
              if (await _onWillPop() && nav.mounted) nav.pop();
            },
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  Widget _buildHorizontalLayout(ColorScheme scheme, bool isZh) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 280, child: _buildLeftPanel(scheme, isZh)),
        VerticalDivider(width: 1, color: scheme.outlineVariant.withAlpha(60)),
        Expanded(child: _buildRightPanel(scheme, isZh)),
      ],
    );
  }

  Widget _buildVerticalLayout(ColorScheme scheme, bool isZh) {
    return Column(
      children: [
        SizedBox(height: 200, child: _buildLeftPanel(scheme, isZh)),
        Divider(height: 1, color: scheme.outlineVariant.withAlpha(60)),
        Expanded(child: _buildRightPanel(scheme, isZh)),
      ],
    );
  }

  // ── 左面板：配置项列表 ──

  Widget _buildLeftPanel(ColorScheme scheme, bool isZh) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              Icon(Icons.list, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  isZh ? '配置项' : 'Config Items',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.outline),
                ),
              ),
              Text('${_config.items.length}', style: TextStyle(fontSize: 11, color: scheme.outline.withAlpha(120))),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _config.items.isEmpty
              ? Center(
                  child: Text(
                    isZh ? '暂无配置项' : 'No items',
                    style: TextStyle(color: scheme.outline.withAlpha(100), fontSize: 13),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _config.items.length,
                  itemBuilder: (_, i) => _buildItemTile(_config.items[i], i, scheme, isZh),
                ),
        ),
      ],
    );
  }

  Widget _buildItemTile(QuickConfigItem item, int index, ColorScheme scheme, bool isZh) {
    final selected = _selectedKey == item.key;
    final title = item.titleFor(isZh);
    final summary = _itemSummary(item, isZh);

    return Material(
      color: selected ? scheme.primary.withAlpha(18) : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selectedKey = item.key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: selected ? Border(left: BorderSide(color: scheme.primary, width: 3)) : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 28, height: 28,
                child: Checkbox(
                  value: item.enabled,
                  onChanged: (_) => _toggleItemEnabled(index),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: item.enabled ? scheme.primaryContainer.withAlpha(120) : scheme.surfaceContainerHighest.withAlpha(80),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _itemIcon(item.key),
                  size: 16,
                  color: item.enabled ? scheme.onPrimaryContainer : scheme.outline.withAlpha(100),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: item.enabled ? scheme.onSurface : scheme.outline.withAlpha(120),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: item.enabled ? scheme.onSurfaceVariant : scheme.outline.withAlpha(80),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 右面板：参数编辑 ──

  Widget _buildRightPanel(ColorScheme scheme, bool isZh) {
    if (_selectedKey == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined, size: 44, color: scheme.outline.withAlpha(60)),
            const SizedBox(height: 12),
            Text(isZh ? '请从左侧选择一个配置项' : 'Select an item from the left',
                style: TextStyle(fontSize: 14, color: scheme.outline.withAlpha(120))),
          ],
        ),
      );
    }

    final idx = _config.items.indexWhere((it) => it.key == _selectedKey);
    if (idx < 0) {
      return Center(
        child: Text(isZh ? '配置项未找到' : 'Item not found',
            style: TextStyle(color: scheme.error, fontSize: 14)),
      );
    }

    final item = _config.items[idx];
    final title = item.titleFor(isZh);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_itemIcon(item.key), size: 20, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: scheme.onSurface),
                ),
              ),
              Switch(
                value: item.enabled,
                onChanged: (_) {
                  final idx2 = _config.items.indexWhere((it) => it.key == item.key);
                  if (idx2 >= 0) _toggleItemEnabled(idx2);
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isZh ? '键: ${item.key}' : 'Key: ${item.key}',
            style: TextStyle(fontSize: 11, color: scheme.outline.withAlpha(120)),
          ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 20),
          if (item.params.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  isZh ? '此配置项没有可编辑的参数' : 'No editable parameters',
                  style: TextStyle(fontSize: 13, color: scheme.outline.withAlpha(120)),
                ),
              ),
            )
          else
            ...item.params.entries.map((entry) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _buildParamField(item.key, entry.key, entry.value, _config.fileType, scheme, isZh),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildParamField(
    String itemKey,
    String paramKey,
    dynamic value,
    QuickFileType ft,
    ColorScheme scheme,
    bool isZh,
  ) {
    final label = _paramLabel(paramKey, isZh);

    if (value is bool) {
      return _BoolSwitch(
        key: ValueKey('$itemKey:$paramKey'),
        label: label,
        value: value,
        onChanged: (v) => _updateParam(itemKey, paramKey, v),
      );
    }

    // 角度等特殊键：int → 下拉框（90/180/270）
    if (value is int && paramKey.toLowerCase().contains('angle')) {
      return _NumberDropdown(
        key: ValueKey('$itemKey:$paramKey'),
        label: label,
        value: value,
        options: const [90, 180, 270],
        onChanged: (v) => _updateParam(itemKey, paramKey, v),
      );
    }

    // 有预设的常见参数（字符串或数字）→ 下拉框，提供可选项
    final presets = _presetsFor(paramKey, ft, isZh);
    if (presets != null && (value is String || value is num)) {
      return _PresetDropdown(
        key: ValueKey('$itemKey:$paramKey'),
        label: label,
        value: value,
        options: presets,
        onChanged: (v) => _updateParam(itemKey, paramKey, v),
      );
    }

    if (value is int) {
      return _NumberField(
        key: ValueKey('$itemKey:$paramKey'),
        label: label, value: value, isInt: true,
        onChanged: (v) => _updateParam(itemKey, paramKey, v),
      );
    }

    if (value is double) {
      return _NumberField(
        key: ValueKey('$itemKey:$paramKey'),
        label: label, value: value, isInt: false,
        onChanged: (v) => _updateParam(itemKey, paramKey, v),
      );
    }

    if (value is List) {
      return _DropdownField(
        key: ValueKey('$itemKey:$paramKey'),
        label: label,
        value: value.isNotEmpty ? value.first : null,
        options: value,
        onChanged: (v) => _updateParam(itemKey, paramKey, v),
      );
    }

    if (value is String) {
      final isNumeric = RegExp(r'^\d+$').hasMatch(value);
      final isPath = (paramKey == 'subtitle_path' ||
              paramKey == 'subtitle_file' ||
              paramKey == 'image') ||
          ((value.contains('/') || value.contains('.')) && !isNumeric);
      if (isPath) {
        return _PathField(
          key: ValueKey('$itemKey:$paramKey'),
          label: label, value: value, isZh: isZh,
          onChanged: (v) => _updateParam(itemKey, paramKey, v),
        );
      }
      return _TextField(
        key: ValueKey('$itemKey:$paramKey'),
        label: label, value: value,
        onChanged: (v) => _updateParam(itemKey, paramKey, v),
      );
    }

    return _TextField(
      key: ValueKey('$itemKey:$paramKey'),
      label: label, value: '$value',
      onChanged: (v) => _updateParam(itemKey, paramKey, v),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 参数编辑子组件
// ═══════════════════════════════════════════════════════════════

/// 数字输入框（int / double）
class _NumberField extends StatefulWidget {
  final String label;
  final num value;
  final bool isInt;
  final ValueChanged<num> onChanged;

  const _NumberField({
    super.key,
    required this.label,
    required this.value,
    required this.isInt,
    required this.onChanged,
  });

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late TextEditingController _controller;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && !_focusNode.hasFocus) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _applyValue() {
    final text = _controller.text.trim();
    if (widget.isInt) {
      final parsed = int.tryParse(text);
      if (parsed != null) widget.onChanged(parsed);
    } else {
      final parsed = double.tryParse(text);
      if (parsed != null) widget.onChanged(parsed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(widget.label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            keyboardType: TextInputType.number,
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              suffixIcon: IconButton(
                icon: const Icon(Icons.check, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: _applyValue,
              ),
            ),
            onSubmitted: (_) => _applyValue(),
          ),
        ),
      ],
    );
  }
}

/// 文本输入框
class _TextField extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  const _TextField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_TextField> createState() => _TextFieldState();
}

class _TextFieldState extends State<_TextField> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_TextField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(widget.label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: TextField(
            controller: _controller,
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              suffixIcon: IconButton(
                icon: const Icon(Icons.check, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => widget.onChanged(_controller.text),
              ),
            ),
            onSubmitted: (v) => widget.onChanged(v),
          ),
        ),
      ],
    );
  }
}

/// 文件路径输入框（带浏览按钮）
class _PathField extends StatefulWidget {
  final String label;
  final String value;
  final bool isZh;
  final ValueChanged<String> onChanged;

  const _PathField({
    super.key,
    required this.label,
    required this.value,
    required this.isZh,
    required this.onChanged,
  });

  @override
  State<_PathField> createState() => _PathFieldState();
}

class _PathFieldState extends State<_PathField> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_PathField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.isNotEmpty && result.files.first.path != null) {
      final path = result.files.first.path!;
      _controller.text = path;
      widget.onChanged(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(widget.label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: TextStyle(fontSize: 13, color: scheme.onSurface),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onSubmitted: (v) => widget.onChanged(v),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                tooltip: widget.isZh ? '浏览' : 'Browse',
                onPressed: _pickFile,
                style: IconButton.styleFrom(
                  backgroundColor: scheme.surfaceContainerHighest.withAlpha(100),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 布尔开关
class _BoolSwitch extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _BoolSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}

/// 数字下拉框（如角度 90/180/270）
class _NumberDropdown extends StatelessWidget {
  final String label;
  final int value;
  final List<int> options;
  final ValueChanged<int> onChanged;

  const _NumberDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: DropdownButtonFormField<int>(
            initialValue: options.contains(value) ? value : options.first,
            isDense: true,
            isExpanded: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
            items: options.map((v) => DropdownMenuItem(value: v, child: Text('$v°'))).toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }
}

/// 预设下拉框：值可为字符串或数字，显示本地化标签；当前值不在预设中时自动追加。
class _PresetDropdown extends StatelessWidget {
  final String label;
  final Object value;
  final List<_Preset> options;
  final ValueChanged<Object> onChanged;

  const _PresetDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = <_Preset>[...options];
    final hasCurrent = entries.any((e) => e.value == value);
    if (!hasCurrent && value.toString().isNotEmpty) {
      entries.insert(0, (value: value, label: '$value'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: DropdownButtonFormField<Object>(
            initialValue: value,
            isDense: true,
            isExpanded: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
            items: entries.map((e) => DropdownMenuItem(value: e.value, child: Text(e.label))).toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }
}

/// 通用下拉框（用于 List 类型参数）
class _DropdownField extends StatelessWidget {
  final String label;
  final dynamic value;
  final List<dynamic> options;
  final ValueChanged<dynamic> onChanged;

  const _DropdownField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: DropdownButtonFormField<dynamic>(
            initialValue: options.contains(value) ? value : options.firstOrNull,
            isDense: true,
            isExpanded: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
            items: options.map((v) => DropdownMenuItem(value: v, child: Text('$v'))).toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }
}