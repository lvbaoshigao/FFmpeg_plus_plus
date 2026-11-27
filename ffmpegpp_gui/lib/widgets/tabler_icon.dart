import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Outline glyphs bundled from Tabler Icons.
enum TablerGlyph {
  adjustmentsHorizontal('adjustments-horizontal'),
  arrowsJoin('arrows-join'),
  arrowsMinimize('arrows-minimize'),
  aspectRatio('aspect-ratio'),
  brightness('brightness'),
  camera('camera'),
  chartLine('chart-line'),
  clockPlay('clock-play'),
  colorFilter('color-filter'),
  crop('crop'),
  equalizer('adjustments'),
  eraser('eraser'),
  fileExport('file-export'),
  fileMusic('file-music'),
  fileText('file-text'),
  focus2('focus-2'),
  folders('folders'),
  gauge('gauge'),
  grain('grain'),
  helpCircle('help-circle'),
  layersIntersect('layers-intersect'),
  lineHeight('line-height'),
  listDetails('list-details'),
  movie('movie'),
  music('music'),
  palette('palette'),
  photoCog('photo-cog'),
  resize('resize'),
  rotateClockwise('rotate-clockwise'),
  scissors('scissors'),
  settings('settings'),
  sparkles('sparkles'),
  subtitles('subtitles'),
  switchHorizontal('switch-horizontal'),
  tag('tag'),
  video('video'),
  volume('volume'),
  volume3('volume-3'),
  wand('wand'),
  waveSine('wave-sine'),
  waveSquare('wave-square');

  const TablerGlyph(this._fileName);

  final String _fileName;

  /// The SVG's path in the Flutter asset bundle.
  String get assetName => 'assets/tabler_icons/outline/$_fileName.svg';
}

/// A decorative Tabler SVG that inherits size, color and opacity from [IconTheme].
///
/// The enclosing control supplies the accessible label through text or a tooltip.
final class TablerIcon extends StatelessWidget {
  /// Displays a bundled [glyph] with optional overrides for [size] and [color].
  const TablerIcon(this.glyph, {super.key, this.size, this.color});

  /// The Tabler artwork to display.
  final TablerGlyph glyph;

  /// The icon's logical size, defaulting to the surrounding [IconTheme].
  final double? size;

  /// The stroke color, defaulting to the surrounding [IconTheme].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final baseSize = size ?? theme.size ?? 24.0;
    final iconSize = (theme.applyTextScaling ?? false)
        ? MediaQuery.textScalerOf(context).scale(baseSize)
        : baseSize;
    final baseColor = color ?? theme.color!;
    final opacity = theme.opacity ?? 1.0;
    final iconColor = opacity == 1
        ? baseColor
        : baseColor.withValues(alpha: baseColor.a * opacity);

    return SizedBox.square(
      dimension: iconSize,
      // Keep the artwork centered at its requested size inside a larger slot.
      child: Center(
        child: SvgPicture.asset(
          glyph.assetName,
          width: iconSize,
          height: iconSize,
          colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}
