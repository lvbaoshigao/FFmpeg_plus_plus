import 'package:flutter/material.dart';

import 'editor_kit.dart';
import 'media_step_editor_controls.dart';

/// Configures black fades without changing the source audio.
class VideoFadeStepEditor extends ParamsStepEditor {
  const VideoFadeStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  });

  @override
  State<VideoFadeStepEditor> createState() => _VideoFadeStepEditorState();
}

class _VideoFadeStepEditorState extends State<VideoFadeStepEditor>
    with StepEditorState<VideoFadeStepEditor> {
  double _lastExplicitStart = 1;

  @override
  void initState() {
    super.initState();
    _prepareParams();
  }

  @override
  void didUpdateWidget(covariant VideoFadeStepEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.params, widget.params)) {
      _prepareParams();
    }
  }

  void _prepareParams() {
    _lastExplicitStart = 1;
    initDefaults(const {
      'fade_in': 2.0,
      'fade_out': 2.0,
      'fade_out_start': 0.0,
    });
    for (final key in ['fade_in', 'fade_out']) {
      p[key] = editorNumberInRange(p[key], fallback: 2, min: 0, max: 60);
    }
    p['fade_out_start'] = editorNumberInRange(
      p['fade_out_start'],
      fallback: 0,
      min: 0,
      max: 86400,
    );
    if ((p['fade_out_start'] as double) > 0) {
      _lastExplicitStart = p['fade_out_start'] as double;
    }
  }

  void _setStartMode(String mode) {
    if (mode == 'auto') {
      _lastExplicitStart = p['fade_out_start'] as double;
      update('fade_out_start', 0.0);
    } else {
      update(
        'fade_out_start',
        _lastExplicitStart > 0 ? _lastExplicitStart : 1.0,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final fadeOut = p['fade_out'] as double;
    final start = p['fade_out_start'] as double;
    return StepEditorScaffold(
      key: ObjectKey(p),
      title: zh ? '视频淡入淡出' : 'Video fade',
      description: zh
          ? '画面从黑色淡入，或逐渐淡出为黑色。原有音轨保持不变。'
          : 'Fade the picture in from black or out to black. The audio stays unchanged.',
      scrollable: true,
      infoText: zh
          ? '淡入从 0 秒开始。自动淡出按当前输入视频的时长推算，适用于前面已有裁剪或变速的管线。'
          : 'Fade-in starts at 0 seconds. Automatic fade-out uses the current input duration, including earlier trimming or speed changes.',
      children: [
        EditorFieldPair(
          first: EditorNumberField(
            key: const ValueKey('video_fade_in'),
            label: zh ? '淡入时长' : 'Fade-in duration',
            value: p['fade_in'] as double,
            min: 0,
            max: 60,
            unit: 's',
            helper: zh ? '0–60 秒，0 表示不淡入' : '0–60 seconds; 0 disables fade-in',
            isZh: zh,
            onChanged: (value) => update('fade_in', value.toDouble()),
          ),
          second: EditorNumberField(
            key: const ValueKey('video_fade_out'),
            label: zh ? '淡出时长' : 'Fade-out duration',
            value: fadeOut,
            min: 0,
            max: 60,
            unit: 's',
            helper: zh ? '0–60 秒，0 表示不淡出' : '0–60 seconds; 0 disables fade-out',
            isZh: zh,
            onChanged: (value) => update('fade_out', value.toDouble()),
          ),
        ),
        if (fadeOut > 0) ...[
          const SizedBox(height: 20),
          EditorChoiceField(
            key: const ValueKey('video_fade_start_mode'),
            label: zh ? '淡出位置' : 'Fade-out position',
            value: start == 0 ? 'auto' : 'explicit',
            items: [
              ('auto', zh ? '自动' : 'Automatic'),
              ('explicit', zh ? '指定时间' : 'Set time'),
            ],
            onChanged: _setStartMode,
          ),
          const SizedBox(height: 16),
          if (start > 0)
            EditorNumberField(
              key: const ValueKey('video_fade_out_start'),
              label: zh ? '开始时间' : 'Start time',
              value: start,
              min: 0.001,
              max: 86400,
              unit: 's',
              helper: zh
                  ? '相对当前输入视频开头的时间'
                  : 'Measured from the start of the current input',
              isZh: zh,
              onChanged: (value) {
                _lastExplicitStart = value.toDouble();
                update('fade_out_start', value.toDouble());
              },
            )
          else
            Text(
              zh
                  ? '在视频结束前，按淡出时长自动开始。'
                  : 'Starts one fade-out duration before the video ends.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ],
    );
  }
}
