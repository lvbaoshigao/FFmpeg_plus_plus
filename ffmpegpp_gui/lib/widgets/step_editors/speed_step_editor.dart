import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'editor_kit.dart';

class SpeedStepEditor extends ParamsStepEditor {
  const SpeedStepEditor({super.key, required super.params, required super.onChanged, super.isZh = true});

  @override
  State<SpeedStepEditor> createState() => _SpeedStepEditorState();
}

class _SpeedStepEditorState extends State<SpeedStepEditor> with StepEditorState<SpeedStepEditor> {
  late TextEditingController _customCtrl;

  @override
  void initState() {
    super.initState();
    initDefaults(const {'speed': 1.0, 'custom_speed': false, 'custom_speed_value': 10.0});
    _customCtrl = TextEditingController(
      text: (p['custom_speed_value'] as num?)?.toStringAsFixed(1) ?? '10.0',
    );
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isCustom = p['custom_speed'] as bool? ?? false;
    final speed = isCustom
        ? (p['custom_speed_value'] as num?)?.toDouble() ?? 10.0
        : (p['speed'] as num?)?.toDouble() ?? 1.0;

    return StepEditorScaffold(
      title: zh ? '播放速度' : 'Playback Speed',
      infoText: zh ? '变速处理需要重新编码，不支持流复制。\n视频使用 setpts 滤镜，音频使用 atempo 滤镜。\n高倍速会导致文件体积增大。'
                   : 'Speed change requires re-encoding.\nVideo uses setpts filter, audio uses atempo filter.\nHigh speed increases file size.',
      children: [
        // Speed display
        Center(child: Text(
          speed == speed.roundToDouble() ? '${speed.toStringAsFixed(1)}x' : '${speed.toStringAsFixed(2)}x',
          style: TextStyle(fontSize: 36, fontWeight: FontWeight.w700, color: cs.primary),
        )),
        const SizedBox(height: 8),
        Center(child: Text(
          speed == 1.0 ? (zh ? '原速' : 'Normal')
              : speed > 1.0 ? (zh ? '快放' : 'Fast')
              : (zh ? '慢放' : 'Slow'),
          style: TextStyle(fontSize: 12, color: cs.outline),
        )),
        const SizedBox(height: 8),

        // Custom speed toggle
        Row(children: [
          Icon(Icons.tune, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(zh ? '自定义倍速' : 'Custom Speed',
              style: TextStyle(fontSize: 13, color: cs.onSurface))),
          Switch(
            value: isCustom,
            onChanged: (v) {
              update('custom_speed', v);
              if (v) {
                _customCtrl.text = (p['custom_speed_value'] as num?)?.toStringAsFixed(1) ?? '10.0';
              }
            },
          ),
        ]),
        const SizedBox(height: 8),

        if (isCustom) ...[
          // Custom input
          Row(children: [
            Expanded(child: TextField(
              controller: _customCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
              ],
              decoration: InputDecoration(
                labelText: zh ? '倍速值' : 'Speed Value',
                hintText: zh ? '输入倍速（如 100）' : 'Enter speed (e.g. 100)',
                suffixText: 'x',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: (v) {
                final parsed = double.tryParse(v);
                if (parsed != null && parsed > 0) {
                  update('custom_speed_value', parsed);
                }
              },
            )),
          ]),
          const SizedBox(height: 8),
          Text(zh ? '支持任意正数，例如 0.01x、100x、1000x' : 'Supports any positive number, e.g. 0.01x, 100x, 1000x',
              style: TextStyle(fontSize: 11, color: cs.outline)),
          const SizedBox(height: 8),

          // Quick presets for custom mode
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final preset in [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0])
              _customPresetChip(cs, preset, speed),
          ]),
        ] else ...[
          // Slider (preset mode)
          Row(children: [
            Text('0.25x', style: TextStyle(fontSize: 10, color: cs.outline)),
            Expanded(child: Slider(
              value: speed,
              min: 0.25,
              max: 4.0,
              divisions: 75,
              label: '${speed.toStringAsFixed(2)}x',
              onChanged: (v) => update('speed', double.parse(v.toStringAsFixed(2))),
            )),
            Text('4.0x', style: TextStyle(fontSize: 10, color: cs.outline)),
          ]),
          const SizedBox(height: 8),

          // Preset buttons
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final preset in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0])
              _presetChip(cs, preset, speed),
          ]),
        ],
      ],
    );
  }

  Widget _presetChip(ColorScheme cs, double preset, double current) {
    final selected = (current - preset).abs() < 0.01;
    return ChoiceChip(
      label: Text('${preset}x', style: TextStyle(fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
      selected: selected,
      onSelected: (_) => update('speed', preset),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _customPresetChip(ColorScheme cs, double preset, double current) {
    final selected = (current - preset).abs() < 0.1;
    return ChoiceChip(
      label: Text('${preset % 1 == 0 ? preset.toStringAsFixed(0) : preset.toStringAsFixed(1)}x', style: TextStyle(fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
      selected: selected,
      onSelected: (_) {
        update('custom_speed_value', preset);
        _customCtrl.text = preset.toStringAsFixed(1);
      },
      visualDensity: VisualDensity.compact,
    );
  }
}
