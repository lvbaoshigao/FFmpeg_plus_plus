# Vendored: liquid_glass_tab_bar 0.1.0-dev.10

Upstream: https://github.com/KananTaghili/liquid_glass_tab_bar (pub.dev
`liquid_glass_tab_bar` `0.1.0-dev.10`). Copied verbatim from the pub cache
(`lib/`, `pubspec.yaml`, `LICENSE`, `CHANGELOG.md`, `README.md`); the app
resolves it through a `dependency_overrides` path entry in `pubspec.yaml`.

## Why vendored

The upstream bar hard-codes iOS 26 neutral colors: bar glass
`white@0.68` / `black@0.35`, resting capsule `black@0.05` /
`0xFF909090@0.25`, lens `white`. The app's own liquid-glass theme
(`MobileGlassSurface`, `NavGlassShell`) instead uses the neutral glass
palette (`AppNeutralSurface` / `#FAFAFA`) and optionally follows the
theme seed color (`glassFollowTheme` + `useThemeColor`). With the hosted
bar, the mobile bottom-bar selection mask therefore did not match the
app's liquid glass theme.

## Patch (minimal, opt-in)

`LiquidGlassTabBarStyle` gains three nullable color fields:

- `barTint` — tint of the bar's own glass surface (`GlassSurface`),
- `capsuleTint` — fill of the resting selection capsule (below items),
- `lensTint` — tint of the interactive glass droplet lens (above items).

All three default to `null`, which keeps the exact upstream colors, so
existing users of the package are unaffected. `GlassSurface` accepts
optional `tint`/`rim`; `_restCapsule`/`_lens` in `tab_bar.dart` consume the
style fields. The app (`AppLiquidTabBar` in
`lib/widgets/liquid_glass_mobile_nav.dart`) fills them from the same
palette as the rest of the mobile glass UI.

Files touched: `lib/src/style.dart`, `lib/src/glass_surface.dart`,
`lib/src/tab_bar.dart`. No behavior change unless the new fields are set.

## Verify

```
cd ffmpegpp_gui
flutter pub get --offline
flutter analyze third_party/liquid_glass_tab_bar/lib lib/widgets/liquid_glass_mobile_nav.dart
flutter test test/mobile_glass_redesign_test.dart test/mobile_nav_drag_test.dart
```

`mobile liquid indicator keeps the hosted droplet bar` must still find
`LiquidGlassTabBar` (the droplet interaction is unchanged); tests in
`test/liquid_tab_bar_theme_test.dart` assert the themed colors are passed
when the app opts in.
