import 'package:flutter/material.dart';

import 'app_alert_dialog.dart';
import 'app_slider.dart';

/// Opaque theme colors. A null second color represents a solid accent.
@immutable
class ThemeColorSelection {
  const ThemeColorSelection(this.c1, this.c2);

  final int c1;
  final int? c2;
}

/// Keeps every edit local to the modal until the user selects Apply.
Future<ThemeColorSelection?> showThemeColorPicker(
  BuildContext context, {
  required Color initial,
  Color? initial2,
  required bool isZh,
  bool useBottomSheet = false,
  bool allowGradient = true,
  String? title,
}) {
  Widget picker() => ThemeColorPicker(
    initial: initial,
    initial2: initial2,
    isZh: isZh,
    allowGradient: allowGradient,
    title: title,
  );

  if (useBottomSheet) {
    return showModalBottomSheet<ThemeColorSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(top: false, child: picker()),
      ),
    );
  }
  return showDialog<ThemeColorSelection>(
    context: context,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => AppModalSurface(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      constraints: const BoxConstraints(maxWidth: 620),
      child: picker(),
    ),
  );
}

/// A responsive editor shared by the theme accent and solid border picker.
class ThemeColorPicker extends StatefulWidget {
  const ThemeColorPicker({
    super.key,
    required this.initial,
    this.initial2,
    required this.isZh,
    this.allowGradient = true,
    this.title,
  });

  final Color initial;
  final Color? initial2;
  final bool isZh;
  final bool allowGradient;
  final String? title;

  @override
  State<ThemeColorPicker> createState() => _ThemeColorPickerState();
}

class _ThemeColorPickerState extends State<ThemeColorPicker> {
  late final List<Color> _colors;
  late final List<HSVColor> _hsv;
  late final List<TextEditingController> _hex;
  final _invalid = [false, false];
  late bool _gradient;
  int _active = 0;

  String _t(String zh, String en) => widget.isZh ? zh : en;
  Color get _color => _colors[_active];
  HSVColor get _current => _hsv[_active];
  bool get _canApply => !_invalid[0] && (!_gradient || !_invalid[1]);

  @override
  void initState() {
    super.initState();
    final first = widget.initial.withAlpha(255);
    final firstHsv = HSVColor.fromColor(first);
    // Wrap the hue: seeds near red must not generate a hue above 360.
    final second =
        widget.initial2?.withAlpha(255) ??
        firstHsv.withHue((firstHsv.hue + 35) % 360).toColor();
    _colors = [first, second];
    _hsv = [firstHsv, HSVColor.fromColor(second)];
    _hex = [
      TextEditingController(text: _formatHex(first)),
      TextEditingController(text: _formatHex(second)),
    ];
    _gradient = widget.allowGradient && widget.initial2 != null;
  }

  @override
  void dispose() {
    for (final controller in _hex) {
      controller.dispose();
    }
    super.dispose();
  }

  static String _formatHex(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static Color? _parseHex(String input) {
    var value = input.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (!RegExp(r'^(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').hasMatch(value)) {
      return null;
    }
    if (value.length == 3) {
      value = value.split('').map((digit) => '$digit$digit').join();
    }
    return Color(0xFF000000 | int.parse(value, radix: 16));
  }

  void _setColor(int index, Color color) {
    _colors[index] = color;
    _hsv[index] = HSVColor.fromColor(color);
    _invalid[index] = false;
    _hex[index].text = _formatHex(color);
  }

  void _setHsv(HSVColor color) {
    setState(() {
      _hsv[_active] = color;
      _colors[_active] = color.toColor();
      _invalid[_active] = false;
      _hex[_active].text = _formatHex(_color);
    });
  }

  void _onHexChanged(String value) {
    final color = _parseHex(value);
    setState(() {
      _invalid[_active] = color == null;
      if (color != null) {
        _colors[_active] = color;
        _hsv[_active] = HSVColor.fromColor(color);
      }
    });
  }

  void _setMode(bool gradient) {
    FocusScope.of(context).unfocus();
    setState(() {
      _gradient = gradient;
      if (!gradient) _active = 0;
    });
  }

  void _swap() {
    FocusScope.of(context).unfocus();
    setState(() {
      // Swap drafts too, so an invalid HEX value cannot silently be committed.
      final color = _colors[0];
      _colors[0] = _colors[1];
      _colors[1] = color;
      final hsv = _hsv[0];
      _hsv[0] = _hsv[1];
      _hsv[1] = hsv;
      final text = _hex[0].text;
      _hex[0].text = _hex[1].text;
      _hex[1].text = text;
      final invalid = _invalid[0];
      _invalid[0] = _invalid[1];
      _invalid[1] = invalid;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surface =
        theme.dialogTheme.backgroundColor ?? scheme.surfaceContainerHigh;
    return Material(
      color: MediaQuery.highContrastOf(context)
          ? surface.withAlpha(255)
          : surface,
      shape:
          theme.dialogTheme.shape ??
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: double.infinity,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 760),
          // One viewport also keeps the actions reachable with the keyboard open
          // or in a very short landscape window.
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.palette_outlined, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.title ?? _t('主题颜色', 'Theme color'),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('theme-color-close'),
                      tooltip: _t('关闭', 'Close'),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Text(
                  _t('实时预览，确认后应用。', 'Preview your changes, then apply.'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final wide =
                        constraints.maxWidth >= 520 &&
                        MediaQuery.textScalerOf(context).scale(14) <= 18;
                    final choices = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _preview(),
                        if (widget.allowGradient) ...[
                          const SizedBox(height: 16),
                          _modeSelector(),
                        ],
                        if (_gradient) ...[
                          const SizedBox(height: 16),
                          _endpoints(),
                        ],
                        if (wide) ...[const SizedBox(height: 20), _presets()],
                      ],
                    );
                    if (wide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 4, child: choices),
                          const SizedBox(width: 24),
                          Expanded(flex: 5, child: _editor()),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        choices,
                        const SizedBox(height: 20),
                        _editor(),
                        const SizedBox(height: 20),
                        _presets(),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
                _actions(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(_t('实时预览', 'Live preview')),
        const SizedBox(height: 8),
        Semantics(
          label: _t('所选颜色', 'Selected colors'),
          value:
              '${_formatHex(_colors[0])}${_gradient ? ' → ${_formatHex(_colors[1])}' : ''}',
          child: Container(
            key: const ValueKey('theme-color-preview'),
            height: 112,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _gradient ? null : _colors[0],
              gradient: _gradient
                  ? LinearGradient(
                      colors: [_colors[0], _colors[1]],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: scheme.outlineVariant),
            ),
            // A neutral label remains readable even over a black-to-white ramp.
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surface.withAlpha(242),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'Aa',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${_formatHex(_colors[0])}${_gradient ? ' → ${_formatHex(_colors[1])}' : ''}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _modeSelector() => Row(
    children: [
      Expanded(child: _modeButton(false, _t('纯色', 'Solid'))),
      const SizedBox(width: 8),
      Expanded(child: _modeButton(true, _t('渐变', 'Gradient'))),
    ],
  );

  Widget _modeButton(bool gradient, String label) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _gradient == gradient;
    return Semantics(
      selected: selected,
      child: TextButton(
        key: ValueKey(gradient ? 'theme-color-gradient' : 'theme-color-solid'),
        style: TextButton.styleFrom(
          foregroundColor: selected
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
          backgroundColor: selected
              ? scheme.secondaryContainer
              : scheme.surfaceContainerHighest,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: () => _setMode(gradient),
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }

  Widget _endpoints() => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(child: _endpoint(0, _t('起点', 'Start'))),
      IconButton(
        key: const ValueKey('theme-color-swap'),
        tooltip: _t('交换起止色', 'Swap start and end colors'),
        onPressed: _swap,
        icon: const Icon(Icons.swap_horiz, size: 20),
      ),
      Expanded(child: _endpoint(1, _t('终点', 'End'))),
    ],
  );

  Widget _endpoint(int index, String label) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _active == index;
    return Semantics(
      selected: selected,
      child: OutlinedButton(
        key: ValueKey('theme-color-endpoint-$index'),
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          backgroundColor: selected ? scheme.surfaceContainerHighest : null,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          minimumSize: const Size(0, 64),
          side: BorderSide(
            color: _invalid[index]
                ? scheme.error
                : selected
                ? scheme.primary
                : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: () {
          FocusScope.of(context).unfocus();
          setState(() => _active = index);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _swatch(_colors[index], size: 24),
            const SizedBox(height: 4),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _editor() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _swatch(_color, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: _sectionTitle(
                _gradient
                    ? (_active == 0
                          ? _t('编辑起点颜色', 'Edit start color')
                          : _t('编辑终点颜色', 'Edit end color'))
                    : _t('自定义颜色', 'Custom color'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _SaturationValueField(
          key: const ValueKey('theme-color-sv'),
          color: _current,
          label: _t('饱和度与亮度', 'Saturation and brightness'),
          onChanged: _setHsv,
        ),
        const SizedBox(height: 16),
        TextField(
          key: ValueKey('theme-color-hex-$_active'),
          controller: _hex[_active],
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: _t('HEX 颜色值', 'HEX color'),
            hintText: '#5E6AD2',
            helperText: _t('支持 #RGB、#RRGGBB', '#RGB or #RRGGBB'),
            helperMaxLines: 2,
            errorText: _invalid[_active]
                ? _t('请输入 3 位或 6 位十六进制颜色', 'Enter 3 or 6 hex digits')
                : null,
            errorMaxLines: 3,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: _onHexChanged,
          onSubmitted: (_) {
            if (!_invalid[_active]) _hex[_active].text = _formatHex(_color);
            FocusScope.of(context).unfocus();
          },
          onTapOutside: (_) => FocusScope.of(context).unfocus(),
        ),
        const SizedBox(height: 12),
        _control(
          id: 'hue',
          label: _t('色相', 'Hue'),
          value: _current.hue,
          max: 360,
          display: '${_current.hue.round()}°',
          color: HSVColor.fromAHSV(1, _current.hue, 0.8, 0.9).toColor(),
          onChanged: (value) => _setHsv(_current.withHue(value)),
        ),
        _control(
          id: 'saturation',
          label: _t('饱和度', 'Saturation'),
          value: _current.saturation,
          display: '${(_current.saturation * 100).round()}%',
          color: _current.withValue(0.85).toColor(),
          onChanged: (value) => _setHsv(_current.withSaturation(value)),
        ),
        _control(
          id: 'value',
          label: _t('亮度', 'Brightness'),
          value: _current.value,
          display: '${(_current.value * 100).round()}%',
          color: Color.alphaBlend(_color.withAlpha(180), scheme.primary),
          onChanged: (value) => _setHsv(_current.withValue(value)),
        ),
      ],
    );
  }

  Widget _control({
    required String id,
    required String label,
    required double value,
    double max = 1,
    required String display,
    required Color color,
    required ValueChanged<double> onChanged,
  }) => Semantics(
    label: label,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(display, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        AppSlider(
          key: ValueKey('theme-color-$id'),
          value: value,
          max: max,
          label: display,
          color: color,
          compact: true,
          particles: false,
          onChanged: onChanged,
        ),
      ],
    ),
  );

  Widget _presets() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sectionTitle(_t('常用配色', 'Color presets')),
      const SizedBox(height: 8),
      Wrap(
        spacing: 4,
        runSpacing: 4,
        children: _gradient
            ? [
                for (final preset in _gradientPresets)
                  _preset(
                    first: Color(preset.$1),
                    second: Color(preset.$2),
                    label: _t(preset.$3, preset.$4),
                  ),
              ]
            : [
                for (final color in _solidPresets)
                  _preset(first: Color(color), label: _formatHex(Color(color))),
              ],
      ),
    ],
  );

  Widget _preset({required Color first, Color? second, required String label}) {
    final scheme = Theme.of(context).colorScheme;
    final selected = second == null
        ? _color == first
        : _colors[0] == first && _colors[1] == second;
    final midpoint = second == null ? first : Color.lerp(first, second, 0.5)!;
    final foreground =
        ThemeData.estimateBrightnessForColor(midpoint) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Semantics(
      selected: selected,
      child: Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            FocusScope.of(context).unfocus();
            setState(() {
              if (second == null) {
                _setColor(_active, first);
              } else {
                _setColor(0, first);
                _setColor(1, second);
              }
            });
          },
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: second == null ? first : null,
                  gradient: second == null
                      ? null
                      : LinearGradient(
                          colors: [first, second],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check, size: 18, color: foreground)
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _swatch(Color color, {required double size}) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
  );

  Widget _sectionTitle(String title) => Text(
    title,
    style: Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _actions() {
    final cancel = AppDialogAction(
      role: AppDialogActionRole.cancel,
      child: TextButton(
        key: const ValueKey('theme-color-cancel'),
        onPressed: () => Navigator.pop(context),
        child: Text(_t('取消', 'Cancel')),
      ),
    );
    final apply = AppDialogAction(
      role: AppDialogActionRole.primary,
      child: FilledButton(
        key: const ValueKey('theme-color-apply'),
        onPressed: _canApply
            ? () => Navigator.pop(
                context,
                ThemeColorSelection(
                  _colors[0].toARGB32(),
                  _gradient ? _colors[1].toARGB32() : null,
                ),
              )
            : null,
        child: Text(_t('应用颜色', 'Apply color')),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <
            300 * MediaQuery.textScalerOf(context).scale(1)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [cancel, const SizedBox(height: 8), apply],
          );
        }
        return Row(
          children: [
            Expanded(child: cancel),
            const SizedBox(width: 8),
            Expanded(child: apply),
          ],
        );
      },
    );
  }
}

class _SaturationValueField extends StatelessWidget {
  const _SaturationValueField({
    super.key,
    required this.color,
    required this.label,
    required this.onChanged,
  });

  final HSVColor color;
  final String label;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    value:
        '${(color.saturation * 100).round()}%, ${(color.value * 100).round()}%',
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 148);
        void update(Offset position) {
          onChanged(
            color
                .withSaturation((position.dx / size.width).clamp(0, 1))
                .withValue((1 - position.dy / size.height).clamp(0, 1)),
          );
        }

        return MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTapDown: (details) => update(details.localPosition),
            onPanStart: (details) => update(details.localPosition),
            onPanUpdate: (details) => update(details.localPosition),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: CustomPaint(
                size: size,
                painter: _SaturationValuePainter(color),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _SaturationValuePainter extends CustomPainter {
  const _SaturationValuePainter(this.color);

  final HSVColor color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()..color = HSVColor.fromAHSV(1, color.hue, 1, 1).toColor(),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.white, Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    final marker = Offset(
      (color.saturation * size.width).clamp(8, size.width - 8),
      ((1 - color.value) * size.height).clamp(8, size.height - 8),
    );
    canvas.drawCircle(
      marker,
      7,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      marker,
      7,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_SaturationValuePainter oldDelegate) =>
      oldDelegate.color != color;
}

const _solidPresets = [
  0xFF5E6AD2,
  0xFF3B82F6,
  0xFF06B6D4,
  0xFF10B981,
  0xFF84CC16,
  0xFFF59E0B,
  0xFFF97316,
  0xFFEF4444,
  0xFFEC4899,
  0xFF8B5CF6,
  0xFF000000,
  0xFFFFFFFF,
];

const _gradientPresets = <(int, int, String, String)>[
  (0xFF5E6AD2, 0xFF8B5CF6, '紫罗兰', 'Violet'),
  (0xFF3B82F6, 0xFF06B6D4, '海洋', 'Ocean'),
  (0xFF10B981, 0xFF84CC16, '翡翠', 'Emerald'),
  (0xFFF59E0B, 0xFFEF4444, '熔岩', 'Lava'),
  (0xFFEC4899, 0xFFF97316, '日落', 'Sunset'),
  (0xFF8B5CF6, 0xFFEC4899, '霓虹', 'Neon'),
  (0xFF64748B, 0xFF0EA5E9, '钢蓝', 'Steel blue'),
  (0xFF111827, 0xFF5E6AD2, '夜幕', 'Nightfall'),
];
