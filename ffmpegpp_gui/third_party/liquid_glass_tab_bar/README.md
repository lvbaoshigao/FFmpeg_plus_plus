# liquid_glass_tab_bar

An iOS 26 style floating **liquid glass bottom navigation bar** for Flutter —
a drop-in tab bar / nav bar / bottom menu for `Scaffold.bottomNavigationBar`
that looks like Apple's Liquid Glass `UITabBar`.

At rest the selected tab sits in a soft capsule. Press, drag along the bar or
switch tabs and the capsule turns into a **real refracting glass droplet**: it
stretches with the finger's speed, wobbles into place, bends the icons
underneath, and the whole bar swells slightly — the way the native tab bar
does on iOS 26.

![Demo: the droplet follows the finger](https://raw.githubusercontent.com/KananTaghili/liquid_glass_tab_bar/main/doc/demo_bar.webp)

| Light & dark, with and without labels | Full screen demo |
| :---: | :---: |
| <img src="https://raw.githubusercontent.com/KananTaghili/liquid_glass_tab_bar/main/doc/screenshot.png" width="380"> | <img src="https://raw.githubusercontent.com/KananTaghili/liquid_glass_tab_bar/main/doc/demo.webp" width="240"> |

While you press or drag, the selection becomes a glass droplet:

<p>
  <img src="https://raw.githubusercontent.com/KananTaghili/liquid_glass_tab_bar/main/doc/droplet_light.png" width="32%">
  <img src="https://raw.githubusercontent.com/KananTaghili/liquid_glass_tab_bar/main/doc/droplet_hold_light.png" width="32%">
  <img src="https://raw.githubusercontent.com/KananTaghili/liquid_glass_tab_bar/main/doc/droplet_hold_dark.png" width="32%">
</p>

## Features

- Real refraction, chromatic edge and light via
  [`liquid_glass_renderer`](https://pub.dev/packages/liquid_glass_renderer)
  shaders — not just blur.
- Droplet physics: velocity-based stretch, overshoot on arrival, grows while
  pressed, shrinks back when the finger stops.
- Drag to select: slide along the bar, release over a tab.
- The selected color flows smoothly across icons as the droplet moves.
- Light and dark mode tuned against the native iOS 26 bar.
- Action items: intercept a tap (e.g. to open a sheet) without changing the
  selection.
- Works on iOS and Android.

## Requirements

- Flutter 3.32.4 or newer.
- **Impeller** (the default renderer on iOS and Android). Web and desktop
  are not supported yet.

## Install

```sh
flutter pub add liquid_glass_tab_bar
```

## Usage

```dart
import 'package:liquid_glass_tab_bar/liquid_glass_tab_bar.dart';

Scaffold(
  // Let the content scroll behind the glass.
  extendBody: true,
  body: pages[index],
  bottomNavigationBar: LiquidGlassTabBar(
    currentIndex: index,
    onTap: (i) => setState(() => index = i),
    items: const [
      LiquidGlassTabItem(icon: Icon(Icons.home_outlined), label: 'Home'),
      LiquidGlassTabItem(icon: Icon(Icons.search), label: 'Search'),
      LiquidGlassTabItem(icon: Icon(Icons.person_outline), label: 'Profile'),
    ],
  ),
);
```

Keep the last list item above the bar:

```dart
ListView(
  padding: EdgeInsets.only(bottom: LiquidGlassTabBar.heightOf(context)),
  children: [...],
);
```

### SVG or custom icons

Items are drawn twice (unselected, and selected clipped to the droplet), so
an icon must only differ by color. Use the builder for icons that take the
color explicitly:

```dart
LiquidGlassTabItem.builder(
  label: 'Home',
  iconBuilder: (color) => SvgPicture.asset(
    'assets/home.svg',
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
  ),
)
```

### Icon-only items

Leave out the label and give a `semanticLabel` for screen readers. A smaller
capsule usually looks better without text:

```dart
LiquidGlassTabBar(
  style: const LiquidGlassTabBarStyle(capsuleHeight: 44),
  items: const [
    LiquidGlassTabItem(icon: Icon(Icons.home_outlined), semanticLabel: 'Home'),
    LiquidGlassTabItem(icon: Icon(Icons.search), semanticLabel: 'Search'),
  ],
  // ...
)
```

### How many items?

At least 2. There is no hard upper limit, but each item gets an equal share
of the width, so 2–5 is recommended (the iOS guideline); with more, labels
are truncated on narrow phones.

### Action items

```dart
LiquidGlassTabBar(
  // ...
  onTapIntercept: (i) {
    if (i != 2) return false;
    showModalBottomSheet(context: context, builder: (_) => const NewPost());
    return true; // selection stays where it is
  },
)
```

### Colors and layout

```dart
LiquidGlassTabBar(
  selectedColor: Colors.teal,         // default: ColorScheme.primary
  unselectedColor: Colors.black87,    // default: iOS-like near black / near white
  style: const LiquidGlassTabBarStyle(
    capsuleHeight: 54,      // height of the selection capsule
    capsuleInset: 4,        // gap around the resting capsule
    capsuleOverhang: 6,     // how far the capsule reaches past its item
    horizontalMargin: 20,   // distance to the screen edges
    iconSize: 26,
    labelStyle: TextStyle(fontSize: 10.5),
  ),
  // ...
)
```

## Notes

- The glass effect samples what is behind the bar, so give it colorful
  content to bend (use `extendBody: true`).
- Android emulators render the shaders through a software / OpenGL path and
  may show color fringes that real devices do not.
- `liquid_glass_renderer` is still a pre-release (`0.2.0-dev`); its API may
  change.

## Credits

- Glass rendering: [`liquid_glass_renderer`](https://pub.dev/packages/liquid_glass_renderer)
  by Tim Lehmann / whynotmake.it (MIT).
- The bar's glass material values were first tuned after
  [`liquid_glass_bottom_nav`](https://pub.dev/packages/liquid_glass_bottom_nav)
  (MIT).

## License

MIT — see [LICENSE](LICENSE).
